#!/usr/bin/env python3
"""Run with python3 scripts/test_mock_weread.py; no KOReader or network account."""
import json
import threading
import time
import unittest
from http.client import RemoteDisconnected
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener

from fetch_weread_epub import decode_content_shards, decode_style_shard, weread_e
from mock_weread import (BIG_BOOK_ID, BIG_CHAPTER_COUNT, BOOK_ID, BOOKS, CHAPTERS, MockServer, annotation,
                         chapter_html, shards)


class ObservedGate:
    """Expose wait entry/return, optionally pausing before the underlying wait."""
    def __init__(self, event, pause=False):
        self.event = event
        self.entered = threading.Event()
        self.returned = threading.Event()
        self.resume = threading.Event()
        if not pause:
            self.resume.set()

    def wait(self, timeout=None):
        self.entered.set()
        try:
            if not self.resume.wait(timeout):
                return False
            return self.event.wait(timeout)
        finally:
            self.returned.set()

    def set(self):
        self.event.set()

    def clear(self):
        self.event.clear()


class MockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = MockServer(0, now=lambda: 1710343800)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.opener = build_opener(ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, path, data=None):
        request = Request(self.base + path, data=None if data is None else json.dumps(data).encode(),
                          headers={"Content-Type": "application/json"})
        try:
            response = self.opener.open(request, timeout=3)
        except HTTPError as exc:
            response = exc
        with response:
            body = response.read()
            if response.headers["Content-Type"] == "application/json":
                body = json.loads(body)
            return response.status, body

    def gateway(self, api, **params):
        return self.request("/api/agent/gateway", dict(api_name=api, **params))

    def setUp(self):
        self.request("/__control", dict(delay=0, match="", status=503, times=0, drop=False,
                                        empty_shelf=False, empty_annotations=False, shelf_idless_entry=False, hold_response=False,
                                        qr_mode="succeed", qr_delay=0))

    def test_read_statistics_view_fixture(self):
        status, data = self.gateway("/readdata/detail", mode="monthly")
        self.assertEqual(status, 200)
        self.assertEqual(data["totalReadTime"], 7200)
        self.assertEqual(sum(data["readTimes"].values()), 7200)
        self.assertEqual(data["baseTime"], 1709222400)  # Current injected month: March 2024
        self.assertEqual(self.gateway("/readdata/detail", mode="weekly")[1]["baseTime"], 1710086400)
        self.assertEqual(self.gateway("/readdata/detail", mode="annually")[1]["baseTime"], 1704038400)
        self.assertEqual(self.gateway("/readdata/detail", mode="monthly", baseTime=1790784000)[1]["baseTime"],
                         1790784000)  # Explicit period overrides the injected clock
        self.assertEqual(self.gateway("/readdata/detail", mode="weekly", baseTime=1790784000)[1]["baseTime"],
                         1790524800)  # Monday 2026-09-28, Beijing midnight
        self.assertEqual(self.gateway("/readdata/detail", mode="annually", baseTime=1790784000)[1]["baseTime"],
                         1767196800)  # 2026-01-01, Beijing midnight
        _, overall = self.gateway("/readdata/detail", mode="overall")
        self.assertEqual(overall["baseTime"], 0)
        self.assertEqual(overall["readTimes"], {"1704038400": 7200})  # Injected current year: 2024
        self.assertEqual(self.gateway("/readdata/detail", mode="invalid")[0], 400)

    def test_synthetic_mp_content_and_bounded_image_host(self):
        status, html = self.request("/web/mp/content?reviewId=mock-mp-article")
        self.assertEqual(status, 200)
        self.assertIn(b"Synthetic article body.", html)
        self.assertIn(b"https://mmbiz.qpic.cn/mock/illustration.png", html)
        status, image = self.request("/__proxy?url=https%3A%2F%2Fmmbiz.qpic.cn%2Fmock%2Fillustration.png")
        self.assertEqual(status, 200)
        self.assertTrue(image.startswith(b"\x89PNG"))
        self.assertEqual(self.request("/web/mp/content?reviewId=unknown")[0], 400)
        self.assertEqual(self.request("/__proxy?url=https%3A%2F%2Fmmbiz.qpic.cn%2Fapi%2FuserInfo")[0], 501)

    def test_synthetic_mp_article_list(self):
        before = self.request("/__state")[1]["started_counts"].get("/web/mp/articles", 0)
        status, result = self.request("/web/mp/articles?bookId=MP_WXS_900000&maxIdx=0&count=100")
        self.assertEqual(status, 200)
        article = result["reviews"][0]["subReviews"][0]["review"]
        self.assertEqual(article["reviewId"], "mock-mp-article")
        self.assertEqual(article["belongBookId"], "MP_WXS_900000")
        self.assertEqual(article["mpInfo"]["title"], "合成公众号文章")
        self.assertEqual(self.request("/__state")[1]["started_counts"]["/web/mp/articles"], before + 1)
        self.assertEqual(self.request("/web/mp/articles?bookId=unknown")[0], 400)

    def test_contract_and_real_reference_decoder(self):
        status, shelf = self.gateway("/shelf/sync")
        self.assertEqual(status, 200)
        self.assertEqual(len(shelf["books"]), 26)
        self.assertEqual(len(shelf["archive"]), 3)
        _, catalog = self.request("/web/book/chapterInfos", dict(bookIds=[BOOK_ID]))
        self.assertEqual(catalog["data"][0]["updated"], CHAPTERS)
        for uid in range(1, 7):
            params = dict(b=weread_e(BOOK_ID), c=weread_e(uid))
            parts = [self.request("/web/book/chapter/" + part, params)[1].decode()
                     for part in ("e_0", "e_1", "e_3")]
            self.assertEqual(decode_content_shards(*parts), chapter_html(uid))
            mark = annotation(uid)
            begin, end = map(int, mark["range"].split("-"))
            self.assertEqual(chapter_html(uid)[begin:end], mark["markText"])
        self.assertIn("line-height", decode_style_shard(self.request("/web/book/chapter/e_2", params)[1].decode()))
        for text in ("", "a", "你好", "🌿" * 31, "abcdef" * 103):
            self.assertEqual(decode_content_shards(*shards(text)), text)

    def test_annotations_and_progress_write_read(self):
        _, result = self.gateway("/book/underlines", bookId=BOOK_ID, chapterUid=2)
        mark = result["underlines"][0]
        self.assertIn("metadata", mark)
        self.assertIsNone(mark["metadata"])
        _, thoughts = self.gateway("/book/readreviews", bookId=BOOK_ID, chapterUid=2, reviews=[dict(range=mark["range"])])
        self.assertEqual(thoughts["reviews"][0]["range"], mark["range"])
        self.assertIn("metadata", thoughts["reviews"][0])
        self.assertIsNone(thoughts["reviews"][0]["metadata"])
        self.assertGreater(len(thoughts["reviews"][0]["pageReviews"][0]["review"]["content"]), 100)
        self.request("/web/book/read", dict(b=weread_e(BOOK_ID), c=weread_e(2), ci=2, co=120, pr=25))
        _, progress = self.gateway("/book/getprogress", bookId=BOOK_ID)
        self.assertEqual(progress["book"]["chapterOffset"], 120)

    def test_explicit_response_gate(self):
        endpoint = "/book/getprogress"
        self.assertEqual(self.request("/__control", dict(match=endpoint, hold_response=True))[0], 200)
        with self.server.lock:
            gate = ObservedGate(self.server.response_gate)
            self.server.response_gate = gate
        results, done = [], threading.Event()

        def fetch():
            try:
                results.append(self.gateway(endpoint, bookId=BOOK_ID))
            finally:
                done.set()

        thread = threading.Thread(target=fetch)
        thread.start()
        try:
            self.assertTrue(gate.entered.wait(timeout=2), "request never called gate.wait")
            self.assertFalse(gate.returned.is_set(), "gate.wait returned before explicit release")
            self.assertFalse(done.is_set(), "held response finished before explicit release")
        finally:
            self.request("/__control", dict(hold_response=False))
            thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(results[0][0], 200)
        self.assertEqual(self.request("/__control", dict(hold_response=1))[0], 400)

    def test_released_request_cannot_be_captured_by_the_next_gate(self):
        endpoint = "/book/getprogress"
        self.request("/__control", dict(match=endpoint, hold_response=True))
        with self.server.lock:
            old_gate = ObservedGate(self.server.response_gate, pause=True)
            self.server.response_gate = old_gate
        results, done = [], threading.Event()

        def fetch():
            try:
                results.append(self.gateway(endpoint, bookId=BOOK_ID))
            finally:
                done.set()

        thread = threading.Thread(target=fetch)
        thread.start()
        try:
            self.assertTrue(old_gate.entered.wait(timeout=2))
            self.request("/__control", dict(hold_response=False))
            self.request("/__control", dict(hold_response=True))
            old_gate.resume.set()
            self.assertTrue(done.wait(timeout=2), "next gate recaptured an already released request")
            self.assertEqual(results[0][0], 200)
            self.assertFalse(self.server.response_gate.is_set(), "old request released the next round")
        finally:
            old_gate.resume.set()
            self.request("/__control", dict(hold_response=False))
            thread.join(timeout=3)
        self.assertFalse(thread.is_alive())

    def test_fault_once_delay_and_recovery(self):
        self.request("/__control", dict(match="/book/info", times=1, status=503, delay=0.02))
        start = time.monotonic()
        self.assertEqual(self.gateway("/book/info", bookId=BOOK_ID)[0], 503)
        self.assertGreaterEqual(time.monotonic() - start, 0.02)
        self.assertEqual(self.gateway("/book/info", bookId=BOOK_ID)[0], 200)
        self.assertEqual(self.gateway("/shelf/sync")[0], 200)
        self.request("/__control", dict(shelf_idless_entry=True))
        books = self.gateway("/shelf/sync")[1]["books"]
        self.assertEqual(len(books), len(BOOKS) + 1)
        self.assertNotIn("bookId", books[-1])
        self.assertEqual(self.request("/__control", dict(shelf_idless_entry=1))[0], 400)
        self.request("/__control", dict(shelf_idless_entry=False, empty_shelf=True, empty_annotations=True))
        self.assertEqual(self.gateway("/shelf/sync")[1]["books"], [])
        self.assertEqual(self.gateway("/book/underlines", bookId=BOOK_ID, chapterUid=1)[1]["underlines"], [])

    def test_downgrade_redirect_and_request_log(self):
        import urllib.parse
        import urllib.request

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *_args, **_kwargs):
                return None  # never follow: the target is a real http URL

        self.addCleanup(self.request, "/__control", dict(downgrade_path=""))
        self.request("/__control", dict(downgrade_path="/web/book/getProgress"))
        opener = build_opener(ProxyHandler({}), NoRedirect)
        target = "https://weread.qq.com/web/book/getProgress?bookId=" + BOOK_ID
        with self.assertRaises(HTTPError) as caught:
            opener.open(self.base + "/__proxy?url=" + urllib.parse.quote(target, safe=""), timeout=3)
        self.assertEqual(caught.exception.code, 302)
        self.assertEqual(caught.exception.headers["Location"], "http://weread.qq.com/web/book/getProgress?bookId="
                         + BOOK_ID)
        plain = "http://weread.qq.com/web/book/getProgress?bookId=" + BOOK_ID
        self.assertEqual(self.request("/__proxy?url=" + urllib.parse.quote(plain, safe=""))[0], 200,
                         "plain http is answered (only https redirects)")
        events = self.request("/__state")[1]["requests"][-2:]
        self.assertEqual([(e["scheme"], e["status"], e["cookie"]) for e in events],
                         [("https", 302, False), ("http", 200, False)])
        self.assertEqual(self.request("/__control", dict(downgrade_path=1))[0], 400)
        # Positive control for the cookie flag: a request that carries one.
        with self.opener.open(Request(self.base + "/__proxy?url=" + urllib.parse.quote(plain, safe=""),
                                      headers={"Cookie": "wr_vid=XXX-synthetic"}), timeout=3) as response:
            self.assertEqual(response.status, 200)
        last = self.request("/__state")[1]["requests"][-1]
        self.assertEqual((last["scheme"], last["cookie"]), ("http", True))

    def test_drop_closes_the_connection_without_a_response(self):
        self.request("/__control", dict(match="/api/userInfo", times=1, drop=True))
        with self.assertRaises((RemoteDisconnected, ConnectionError, URLError)):
            self.request("/api/userInfo")
        self.assertEqual(self.request("/api/userInfo")[0], 200, "times=1 drops only the next request")
        events = [e for e in self.request("/__state")[1]["requests"] if e["path"] == "/api/userInfo"]
        self.assertEqual([e["status"] for e in events][-2:], [0, 200])
        self.assertEqual(self.request("/__control", dict(drop="yes"))[0], 400)

    def test_synthetic_cookie_renewal(self):
        status, result = self.request("/web/login/renewal", {"rq": "%2Fweb%2Fbook%2Fread", "ql": False})
        self.assertEqual(status, 200)
        self.assertEqual(result, {"succ": 1})
        self.assertEqual(self.request("/web/login/renewal", {"rq": "wrong", "ql": False})[0], 400)
        self.assertEqual(self.request("/web/login/renewal", {"rq": "%2Fweb%2Fbook%2Fread", "ql": True})[0], 400)

    def test_qr_login_modes(self):
        status, page = self.request("/__proxy?url=https%3A%2F%2Fweread.qq.com%2Fr%2Fweread-skills")
        self.assertEqual(status, 200)
        _, uid = self.request("/api/auth/getLoginUid")
        info = "/api/auth/getLoginInfo?uid=" + uid["uid"] + "&otp="
        self.assertTrue(self.request(info)[1]["succeed"])
        self.request("/__control", dict(qr_mode="otp"))
        self.assertEqual(self.request(info)[1]["logicCode"], "NEED_OTP")
        self.assertEqual(self.request(info + "0000")[1]["logicCode"], "OTP_NOT_MATCH")
        self.assertTrue(self.request(info + "1234")[1]["succeed"])
        self.request("/__control", dict(qr_mode="expire"))
        self.assertEqual(self.request(info)[1]["logicCode"], "LOGIN_TIMEOUT")
        self.assertEqual(self.request("/api/skills/apikeyGet?only_show=1")[1]["apikey"], "mock-qr-api-key")
        self.assertEqual(self.request("/__control", dict(qr_mode="bogus"))[0], 400)

    def test_big_book_progress_control_and_github_release(self):
        _, catalog = self.request("/web/book/chapterInfos", dict(bookIds=[BIG_BOOK_ID]))
        self.assertEqual(len(catalog["data"][0]["updated"]), BIG_CHAPTER_COUNT)
        params = dict(b=weread_e(BIG_BOOK_ID), c=weread_e(BIG_CHAPTER_COUNT))
        parts = [self.request("/web/book/chapter/" + part, params)[1].decode() for part in ("e_0", "e_1", "e_3")]
        self.assertIn(f"第{BIG_CHAPTER_COUNT}章", decode_content_shards(*parts))
        self.assertEqual(len(self.gateway("/shelf/sync")[1]["books"]), 26)
        self.request("/__progress", dict(bookId=BOOK_ID, chapterUid=3, chapterOffset=50, progress=40))
        _, progress = self.gateway("/book/getprogress", bookId=BOOK_ID)
        self.assertEqual(progress["book"]["chapterUid"], 3)
        _, state = self.request("/__state")
        self.assertEqual(state["progress_history"][-1]["source"], "control")
        self.assertEqual(self.request("/github/api/releases/latest")[0], 404)
        self.server.github_release = dict(version="9999.9.1", files={"weread.koplugin-v9999.9.1.zip": b"PK"})
        _, release = self.request("/github/api/releases/latest")
        self.assertEqual(release["tag_name"], "v9999.9.1")
        url = release["assets"][0]["browser_download_url"]
        self.assertEqual(self.request(url[len(self.base):])[1], b"PK")
        self.assertEqual(self.request("/github/download/v9999.9.1/weread.koplugin-v9999.9.1.zip.sha256.corrupt")[0], 404)
        self.server.github_release["files"]["weread.koplugin-v9999.9.1.zip.sha256"] = b"ab  x.zip\n"
        status, corrupt = self.request("/github/download/v9999.9.1/weread.koplugin-v9999.9.1.zip.sha256.corrupt")
        self.assertEqual((status, corrupt), (200, b"0" * 64 + b"  weread.koplugin-v9999.9.1.zip\n"))
        self.server.github_release = None

    def test_unknown_routes_and_malformed_control_fail(self):
        with self.assertRaises(ValueError):
            MockServer(0, bind="8.8.8.8")
        lan_server = MockServer(0, bind="0.0.0.0")
        self.assertEqual(lan_server.server_address[0], "0.0.0.0")
        lan_server.server_close()
        self.assertEqual(self.request("/unknown")[0], 501)
        self.assertEqual(self.request("/__proxy?url=https%3A%2F%2Fexample.invalid%2Fx")[0], 501)
        self.assertEqual(self.gateway("/unknown")[0], 501)
        self.assertEqual(self.gateway("/book/info", bookId="unknown")[0], 400)
        self.assertEqual(self.gateway("/book/underlines", chapterUid=1)[0], 400)
        self.assertEqual(self.request("/web/book/chapterInfos", dict(bookIds=["unknown"]))[0], 400)
        self.assertEqual(self.request("/__control", dict(delay=-1))[0], 400)
        self.assertEqual(self.request("/__control", dict(times="forever"))[0], 400)
        self.assertEqual(self.request("/__control", dict(unknown=True))[0], 400)
        self.assertEqual(self.request("/web/book/chapter/e_0", dict(b="unknown", c="bad"))[0], 400)
        self.assertEqual(self.request("/__control", [1, 2])[0], 400)
        self.assertEqual(self.request("/__proxy?url=http%3A%2F%2F%5Bbad")[0], 400)
        _, state = self.request("/__state")
        self.assertTrue(any(event["status"] == 501 for event in state["requests"]))
        self.assertTrue(all("headers" not in event for event in state["requests"]))


if __name__ == "__main__":
    unittest.main()
