#!/usr/bin/env python3
"""Compare fresh and reused reader sessions for two chapters of a local EPUB.

Live reads require --live, an explicit private settings file and a local EPUB.
Credentials and decoded content remain in memory. Only ordinal measurements,
byte counts, equality and error classes are printed; nothing is renewed,
reported, downloaded as an image, or saved back to the private inputs.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from time import perf_counter
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

import fetch_weread_epub as protocol
from verify_progress_sync import _find_table, _lua_string


class ConfigurationError(ValueError):
    pass


class RequestScopeError(ValueError):
    pass


COOKIE_NAMES = ("wr_skey", "wr_vid", "wr_rt", "wr_gid", "wr_fp", "wr_ticket", "web_cid")


def read_cookies(path):
    # Reuse the data-only Lua table parser; never evaluate a settings file.
    source = _find_table(Path(path).read_text(encoding="utf-8"), "cookies")
    cookies = {name: _lua_string(source, name) for name in COOKIE_NAMES}
    if not cookies["wr_vid"]:
        match = re.search(r'(?:\["wr_vid"\]|wr_vid)\s*=\s*(\d+)', source)
        if match:
            cookies["wr_vid"] = match[1]
    cookies = {name: value for name, value in cookies.items() if value}
    if not all(cookies.get(name) for name in ("wr_vid", "wr_skey")):
        raise ConfigurationError()
    if any(re.search(r"[;\r\n]", value) for value in cookies.values()):
        raise ConfigurationError()
    return cookies


def check_scope(url, method):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or parsed.hostname not in {"weread.qq.com", "i.weread.qq.com"}
            or parsed.port not in (None, 443) or parsed.username or parsed.password):
        raise RequestScopeError()
    reader = method == "GET" and parsed.path.startswith("/web/reader/")
    content = method == "POST" and (parsed.path == "/web/book/chapterInfos"
        or re.fullmatch(r"/web/book/chapter/(?:e_[0123]|t_[01])", parsed.path))
    if not reader and not content:
        raise RequestScopeError()


def reader_reference(epub):
    references = set()
    with zipfile.ZipFile(epub) as archive:
        for entry in archive.infolist():
            if not entry.filename.endswith(".opf") or entry.file_size > 2 * 1024 * 1024:
                continue
            for node in ET.fromstring(archive.read(entry)).iter("{http://purl.org/dc/elements/1.1/}source"):
                value = (node.text or "").strip()
                try:
                    check_scope(value, "GET")
                except ValueError:
                    continue
                references.add(value)
    if len(references) != 1:
        raise ConfigurationError()
    return references.pop()


class ScopedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, *args):
        redirected = super().redirect_request(request, *args)
        if redirected is not None:
            check_scope(redirected.full_url, redirected.get_method())
        return redirected


class ScopedClient(protocol.WeReadClient):
    def __init__(self, cookies):
        super().__init__(cookie_file=None, cookie_string="; ".join(f"{k}={v}" for k, v in cookies.items()),
                         save_cookies=None)
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookie_jar), ScopedRedirect())

        class BoundedOpener:
            def open(self, request, timeout=30):
                return opener.open(request, timeout=min(timeout, 12))

        self.opener = BoundedOpener()

    def request(self, url, *, method="GET", **options):
        check_scope(url, method)
        return super().request(url, method=method, **options)


class ReusedReader:
    def __init__(self, client, html):
        self.client, self.html = client, html

    def get_text(self, url, **options):
        check_scope(url, "GET")
        return self.html

    def __getattr__(self, key):
        return getattr(self.client, key)


def fetch_sample(client, book_id, chapter):
    started = perf_counter()
    try:
        # The comparison is text/CSS only. Images stay referenced, not fetched.
        sample = dict(chapter, tar=None)
        result = protocol.fetch_chapter(client, book_id=book_id, chapter=sample,
                                        sleep_seconds=0, content_format=["auto"])
        return result[1:3], {"ok": True, "xhtml_bytes": len(result[1].encode()),
                             "css_bytes": len(result[2].encode()), "ms": round((perf_counter() - started) * 1000, 1)}
    except Exception as error:
        return None, {"ok": False, "error_class": type(error).__name__}


def compare(client, reference, rounds=1):
    html = client.get_text(reference, referer=reference)
    state = protocol.read_reader_state(html)
    if not state.psvts:
        raise ConfigurationError()
    catalog = client.post_json("https://weread.qq.com/web/book/chapterInfos",
                               {"bookIds": [state.book_id]}, referer=reference)
    _, chapters = protocol.normalize_chapter_infos(catalog, state.book_id)
    selected = [chapter for chapter in chapters
                if int(chapter.get("wordCount") or 0) > 0 and chapter.get("title") != "封面"][:2]
    if len(selected) != 2:
        raise ConfigurationError()
    comparisons = []
    sources = {"reused": ReusedReader(client, html), "fresh": client}
    for round_number in range(1, rounds + 1):
        order = ("reused", "fresh") if round_number % 2 else ("fresh", "reused")
        for ordinal, chapter in enumerate(selected, 1):
            values = {}
            row = {"round": round_number, "ordinal": ordinal}
            for variant in order:
                values[variant], row[variant] = fetch_sample(sources[variant], state.book_id, chapter)
            row["identical_decoded_content"] = values["fresh"] is not None and values["fresh"] == values["reused"]
            comparisons.append(row)
    return {"outcome": "sample_verification_complete", "reader_page_bytes": len(html.encode()),
            "comparisons": comparisons,
            "sample_verified": all(row["identical_decoded_content"] for row in comparisons)}


class Arguments(argparse.ArgumentParser):
    def error(self, _message):
        # Do not echo arbitrary arguments or private input paths on errors.
        raise ConfigurationError()


def main(argv):
    try:
        parser = Arguments(description=__doc__)
        parser.add_argument("--live", action="store_true")
        parser.add_argument("--settings", type=Path)
        parser.add_argument("--epub", type=Path)
        parser.add_argument("--rounds", type=int, choices=(1, 2, 3), default=1)
        args = parser.parse_args(argv)
        if not args.live:
            print(json.dumps({"outcome": "live_not_requested"}))
            return 0
        if args.settings is None or args.epub is None:
            raise ConfigurationError()
        client = ScopedClient(read_cookies(args.settings))
        result = compare(client, reader_reference(args.epub), args.rounds)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["sample_verified"] else 1
    except (Exception, KeyboardInterrupt) as error:
        print(json.dumps({"outcome": "probe_failed", "error_class": type(error).__name__}))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
