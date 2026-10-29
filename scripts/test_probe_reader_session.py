#!/usr/bin/env python3
"""Offline protocol/equality and privacy checks for the reader-session probe."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.parse
import urllib.request
import zipfile

import fetch_weread_epub as protocol
from mock_weread import shards
import probe_reader_session as probe


class ScriptedClient:
    def __init__(self):
        self.pages = 0
        self.requests = []

    def get_text(self, url, **_options):
        probe.check_scope(url, "GET")
        self.pages += 1
        state = {"reader": {"bookInfo": {"bookId": "900001", "title": "private-title-sentinel"},
                            "psvts": f"XXX-session-{self.pages}"}}
        return "<script>window.__INITIAL_STATE__=" + json.dumps(state) + ";(function(){});</script>"

    def post_json(self, url, data, **_options):
        probe.check_scope(url, "POST")
        return {"data": [{"bookId": data["bookIds"][0], "updated": [
            {"chapterUid": index, "wordCount": 100, "title": "private-chapter-sentinel",
             "tar": "https://images.invalid/never-fetch.tar"} for index in (1, 2)]}]}

    def request(self, url, *, method, data, **_options):
        probe.check_scope(url, method)
        self.requests.append((url, data))
        chapter = next(index for index in (1, 2) if protocol.weread_e(index) == data["c"])
        endpoint = urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1]
        if endpoint == "e_2":
            return shards("p { color: black; }", 1)[0].encode()
        content = f"<html><body><p>synthetic private content {chapter}</p></body></html>"
        return shards(content)[["e_0", "e_1", "e_3"].index(endpoint)].encode()


class ProbeTests(unittest.TestCase):
    def test_no_implicit_live_reads(self):
        with mock.patch.object(probe, "read_cookies") as cookies, mock.patch.object(probe, "ScopedClient") as client:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(probe.main([]), 0)
            cookies.assert_not_called()
            client.assert_not_called()
            self.assertEqual(json.loads(output.getvalue()), {"outcome": "live_not_requested"})

    def test_bad_arguments_and_missing_private_inputs_are_redacted(self):
        for arguments in [["--live"], ["--unknown", "private-value-sentinel"], ["--rounds", "99"]]:
            output = io.StringIO()
            with self.subTest(arguments=arguments), contextlib.redirect_stdout(output):
                self.assertEqual(probe.main(arguments), 1)
            self.assertEqual(json.loads(output.getvalue()),
                             {"outcome": "probe_failed", "error_class": "ConfigurationError"})

    def test_cookie_parser_is_scoped_data_only_and_accepts_numeric_uid(self):
        source = 'return { wr_skey="ignored", cookies={wr_skey="XXX-synthetic", wr_vid=123, other="ignored"} }'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.lua"
            path.write_text(source)
            self.assertEqual(probe.read_cookies(path), {"wr_skey": "XXX-synthetic", "wr_vid": "123"})
            self.assertEqual(path.read_text(), source)
            for value in ['"bad;cookie"', '"bad\\nheader"']:
                path.write_text('return {cookies={wr_skey=' + value + ',wr_vid="XXX-id"}}')
                with self.assertRaises(probe.ConfigurationError):
                    probe.read_cookies(path)

    def test_reader_reference_is_from_explicit_local_epub(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "book.epub"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("OEBPS/content.opf", '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
                                 '<dc:source>https://weread.qq.com/web/reader/XXXsynthetic</dc:source>'
                                 '<dc:source>https://example.invalid/unrelated</dc:source></metadata>')
            self.assertEqual(probe.reader_reference(path), "https://weread.qq.com/web/reader/XXXsynthetic")

    def test_scope_refuses_mutation_and_external_requests_before_network(self):
        client = probe.ScopedClient({"wr_vid": "XXX-id", "wr_skey": "XXX-synthetic"})
        self.assertIsNone(client.save_cookies)
        for url, method in [
            ("http://weread.qq.com/web/reader/XXX", "GET"),
            ("https://elsewhere.invalid/web/reader/XXX", "GET"),
            ("https://weread.qq.com/web/login/renewal", "POST"),
            ("https://weread.qq.com/web/book/read", "POST"),
            ("https://weread.qq.com/web/book/getProgress", "POST"),
        ]:
            with self.subTest(url=url), mock.patch.object(client.opener, "open") as opened:
                with self.assertRaises(probe.RequestScopeError):
                    client.request(url, method=method)
                opened.assert_not_called()

    def test_redirect_cannot_escape_tls_or_allowed_hosts(self):
        request = urllib.request.Request("https://weread.qq.com/web/reader/XXX")
        for target in ["http://weread.qq.com/web/reader/XXX", "https://elsewhere.invalid/web/reader/XXX"]:
            with self.subTest(target=target), self.assertRaises(probe.RequestScopeError):
                probe.ScopedRedirect().redirect_request(request, None, 302, "", {}, target)

    def test_real_decoder_compares_two_chapters_in_alternating_order_without_images(self):
        client = ScriptedClient()
        result = probe.compare(client, "https://weread.qq.com/web/reader/XXXsynthetic", rounds=3)
        self.assertTrue(result["sample_verified"])
        self.assertEqual(len(result["comparisons"]), 6)
        self.assertEqual(client.pages, 7)
        self.assertEqual(len(client.requests), 48)
        self.assertEqual(set(row["ordinal"] for row in result["comparisons"]), {1, 2})
        serialized = json.dumps(result)
        for private in ["900001", "private-title-sentinel", "private-chapter-sentinel", "synthetic private content", "XXX-session"]:
            self.assertNotIn(private, serialized)

    def test_failure_messages_cannot_expose_private_content_or_urls(self):
        client = ScriptedClient()
        client.request = mock.Mock(side_effect=RuntimeError("private URL cookie book-id content sentinel"))
        result = probe.compare(client, "https://weread.qq.com/web/reader/XXXsynthetic")
        self.assertFalse(result["sample_verified"])
        for row in result["comparisons"]:
            self.assertEqual(row["fresh"], {"ok": False, "error_class": "RuntimeError"})
            self.assertEqual(row["reused"], {"ok": False, "error_class": "RuntimeError"})
        self.assertNotIn("sentinel", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
