-- weread.lib.protocol with the real crypto module: success detection, URL
-- encoding, the Web Reader id hash e(), request signing, UTF-8 safe
-- truncation, content/read payloads and reader URLs. Expected hashes were
-- cross-checked against an independent Python implementation.
package.path = "./?.lua;./?/init.lua;" .. package.path

local WeRead = require("weread.lib.protocol")
local Crypto = require("weread.lib.crypto")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end
local function eq(got, want, label)
    expect(got == want, ("%s: got %s, want %s"):format(label, tostring(got), tostring(want)))
end

-- is_success_response()
expect(WeRead.is_success_response({ succ = 1 }) and WeRead.is_success_response({ succ = "1" })
    and WeRead.is_success_response({ succ = true }), "succ=1/\"1\"/true must be success")
expect(not WeRead.is_success_response({ succ = 0 }) and not WeRead.is_success_response({ succ = "true" })
    and not WeRead.is_success_response({}) and not WeRead.is_success_response(nil)
    and not WeRead.is_success_response("succ=1"), "non-success shapes accepted")
expect(WeRead.is_success_response({ ok = 1, succ = 0 }, "ok") and not WeRead.is_success_response({ succ = 1 }, "ok"),
    "custom success field ignored")

-- urlencode(): RFC 3986 unreserved kept, JS-style scalars
eq(WeRead.urlencode("a b/c~d-e_f.g"), "a%20b%2Fc~d-e_f.g", "urlencode reserved chars")
eq(WeRead.urlencode("书"), "%E4%B9%A6", "urlencode UTF-8 bytes")
eq(WeRead.urlencode(true), "true", "urlencode true")
eq(WeRead.urlencode(false), "false", "urlencode false")
eq(WeRead.urlencode(nil), "null", "urlencode nil")
eq(WeRead.urlencode(12), "12", "urlencode number")

-- sorted_query(): sorted keys, "s" excluded, values encoded
eq(WeRead.sorted_query({ c = "x y", a = 1, s = "sig", b = false }), "a=1&b=false&c=x%20y", "sorted_query")
eq(WeRead.sorted_query({}), "", "sorted_query empty")

-- sign() / e() / web_app_id(): fixed vectors
eq(WeRead.sign("a=1&b=2"), "2a0a2922", "sign short query")
eq(WeRead.sign("bookId=123&chapterUid=4"), "3840d476", "sign odd-length query")
eq(WeRead.sign("x"), "2a0a2a0a", "sign single char")
eq(Crypto.md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72", "md5 sanity")
eq(WeRead.e("abc"), "900427206616263900156d7", "e() text is hex bytes padded to 20 chars")
eq(WeRead.e("书"), "2f3426106e4b9a62f370c5b", "e() multibyte text")
eq(WeRead.e("1700000000"), "24932c107a21fe80g010f72", "e() 10-digit number splits into 9-digit chunks")
eq(WeRead.e(12345678901), "bfd32730775bcd15g011abd", "e() numeric argument")
eq(WeRead.e("3300080166"), "e8032880813ab85d0g016722", "e() book id")
eq(WeRead.web_app_id("A BB CCC"), "wb123h1244206010", "web_app_id custom UA")
expect(WeRead.web_app_id():match("^wb%d+h%d+$") and WeRead.web_app_id() == WeRead.web_app_id(WeRead.USER_AGENT),
    "web_app_id default UA")
eq(#WeRead.web_app_id(string.rep("a ", 20)):match("^wb(%d+)h"), 12, "web_app_id uses at most 12 UA tokens")

-- utf8_substr(): never cuts or emits invalid sequences
local utf8_cases = {
    { "hello", 3, "hel", "ASCII" },
    { "éa", 1, "é", "2-byte" },
    { "中文", 1, "中", "3-byte E1-EC" },
    { "\224\164\133x", 1, "\224\164\133", "3-byte E0" },
    { "\237\159\191x", 1, "\237\159\191", "3-byte ED below surrogates" },
    { "\239\188\129x", 1, "\239\188\129", "3-byte EE-EF" },
    { "😀x", 1, "😀", "4-byte F0" },
    { "\243\160\128\129x", 1, "\243\160\128\129", "4-byte F1-F3" },
    { "\244\143\191\191x", 1, "\244\143\191\191", "4-byte F4 max" },
    { "a\237\160\128", 5, "a", "UTF-16 surrogate rejected" },
    { "a\244\144\128\128", 5, "a", "above U+10FFFF rejected" },
    { "a\224\128\128", 5, "a", "overlong E0 rejected" },
    { "a\240\128\128\128", 5, "a", "overlong F0 rejected" },
    { "a\192\128", 5, "a", "overlong C0 rejected" },
    { "a\128", 5, "a", "stray continuation byte" },
    { "a\228\184", 5, "a", "truncated 3-byte sequence" },
    { "a\228\184A", 5, "a", "bad continuation byte" },
    { "a\240\159\152", 5, "a", "truncated 4-byte sequence" },
    { "a\195", 5, "a", "truncated 2-byte sequence" },
    { "abc", nil, "", "nil limit" },
    { "abc", -1, "", "negative limit" },
    { "abc", 2.9, "ab", "fractional limit" },
    { "abc", "2", "ab", "string limit" },
    { nil, 3, "", "nil value" },
    { 12345, 2, "12", "number value" },
}
for _, case in ipairs(utf8_cases) do
    eq(WeRead.utf8_substr(case[1], case[2]), case[3], "utf8_substr " .. case[4])
end

-- make_content_params()
do
    local params = WeRead.make_content_params("3300080166", 5, "ps-token", { ct = 1700000000, sc = 2, style = true })
    eq(params.b, WeRead.e("3300080166"), "content b")
    eq(params.c, WeRead.e(5), "content c")
    eq(params.ct, "1700000000", "content ct")
    eq(params.pc, WeRead.e(1700000000), "content pc")
    eq(params.ps, "ps-token", "content ps")
    eq(params.sc, 2, "content sc")
    eq(params.st, 1, "content st with style")
    eq(params.prevChapter, false, "content prevChapter")
    local r = tonumber(params.r)
    expect(r and r >= 0 and r <= 9999 ^ 2 and math.sqrt(r) == math.floor(math.sqrt(r)), "content r must be a square")
    eq(params.s, WeRead.sign(WeRead.sorted_query(params)), "content signature covers all other fields")

    local defaults = WeRead.make_content_params("b", 1, "p", { ct = 10 })
    eq(defaults.sc, 1, "content default sc")
    eq(defaults.st, 0, "content default st")

    -- pc must differ from the server-issued psvts; ct is bumped on collision.
    local collided = WeRead.make_content_params("b", 1, WeRead.e(1700000000), { ct = 1700000000 })
    eq(collided.ct, "1700000001", "content ct bumped on psvts collision")
    expect(collided.pc ~= collided.ps, "content pc still equals psvts")
end

-- make_enter_read_payload() / make_read_payload() edge cases
do
    local base = { book_id = "b1", chapter_uid = 3, now = 1000, app_id = "wbX", summary = "abc" }
    local enter = WeRead.make_enter_read_payload(base)
    eq(enter.pc, WeRead.e(1000), "missing pc defaults to e(now)")
    eq(enter.appId, "wbX", "explicit appId kept")
    eq(enter.ps, "", "missing psvts sent as empty")
    eq(enter.s, WeRead.sign(WeRead.sorted_query(enter)), "enter signature")

    local zero_pc = WeRead.make_enter_read_payload({ book_id = "b1", now = 1000, pclts = "0", progress = 250,
        chapter_offset = -5 })
    eq(zero_pc.pc, WeRead.e(1000), "pc \"0\" replaced by e(now)")
    eq(zero_pc.c, WeRead.e(0), "missing chapter encodes 0")
    eq(zero_pc.pr, 100, "progress clamped to 100")
    eq(zero_pc.co, 0, "negative offset clamped to 0")
    eq(WeRead.make_enter_read_payload({ book_id = "b", now = 1, progress = -3 }).pr, 0, "progress clamped to 0")

    local report = WeRead.make_read_payload({ book_id = "b1", now = 1000, ts = 5, rn = 6, token = "",
        elapsed_seconds = -10 })
    eq(report.sg, Crypto.sha256_hex("56" .. WeRead.DEFAULT_READER_TOKEN), "empty token uses the default reader token")
    eq(report.rt, 0, "negative elapsed time clamped")
    local custom = WeRead.make_read_payload({ book_id = "b1", now = 1000, ts = 5, rn = 6, token = "tok",
        elapsed_seconds = 31.7 })
    eq(custom.sg, Crypto.sha256_hex("56tok"), "explicit token signs ts..rn..token")
    eq(custom.rt, 31, "elapsed seconds floored")
    eq(custom.s, WeRead.sign(WeRead.sorted_query(custom)), "report signature")
    local generated = WeRead.make_read_payload({ book_id = "b1", now = 1000 })
    expect(generated.ts >= 1000000 and generated.ts <= 1000999 and generated.rn >= 0 and generated.rn <= 999,
        "generated ts/rn out of range")
end

-- Book kinds, reader URLs and cover URLs
expect(WeRead.is_mp_book("MP_WXS_3901") and not WeRead.is_mp_book("3300080166")
    and not WeRead.is_mp_book(nil) and not WeRead.is_mp_book("mp_wxs_1"), "is_mp_book")
eq(WeRead.reader_url("3300080166"), "https://weread.qq.com/web/reader/" .. WeRead.e("3300080166"), "reader_url book")
eq(WeRead.reader_url("3300080166", 5),
    "https://weread.qq.com/web/reader/" .. WeRead.e("3300080166") .. "k" .. WeRead.e(5), "reader_url chapter")
eq(WeRead.mp_reader_url("MP_WXS_1"), "https://weread.qq.com/web/mp/reader/" .. WeRead.e("MP_WXS_1"), "mp_reader_url")
eq(WeRead.normalize_cover_url("https://cdn.weread.qq.com/weread/cover/1/YueWen_1/t6_YueWen_1.jpg"),
    "https://cdn.weread.qq.com/weread/cover/1/YueWen_1/t9_YueWen_1.jpg", "cover t6 -> t9")
eq(WeRead.normalize_cover_url("https://cdn.weread.qq.com/cover/s_abc.jpg"),
    "https://cdn.weread.qq.com/cover/t9_abc.jpg", "cover s_ -> t9")
eq(WeRead.normalize_cover_url(""), "", "cover empty")
eq(WeRead.normalize_cover_url(nil), nil, "cover nil")

print(("protocol_spec: %d checks"):format(checks))
