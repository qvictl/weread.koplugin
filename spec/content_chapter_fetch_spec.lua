-- Chapter download path of weread/lib/content.lua against a scripted client:
-- shard checksum/decoding, reader-state session handling, catalog parsing,
-- shard requests and their failure modes, TXT/EPUB format detection, book css
-- sanitizing, chapter image assets (TAR/ZIP/remote, in memory and on disk) and
-- the chapter/book fetch flows that glue them together.
-- Run with: luajit spec/content_chapter_fetch_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function has(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

local function expect_error(fn, needle, message)
    local ok, err = pcall(fn)
    expect(not ok, message .. " (no error raised)")
    expect(has(tostring(err), needle), message .. " (got: " .. tostring(err) .. ")")
    return tostring(err)
end

local logs = {}
package.preload["weread.lib.logger"] = function()
    local function sink(level)
        return function(...)
            local parts = {}
            for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
            logs[#logs + 1] = { level = level, text = table.concat(parts, " ") }
        end
    end
    return { info = sink("info"), warn = sink("warn"), err = sink("err"), dbg = sink("dbg") }
end

local content_params = {}
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/web/reader/" .. tostring(book_id)
                .. (chapter_uid and ("k" .. tostring(chapter_uid)) or "")
        end,
        mp_reader_url = function(book_id) return "https://weread.qq.com/mp/" .. tostring(book_id) end,
        make_content_params = function(book_id, chapter_uid, psvts, opts)
            local params = { b = book_id, c = chapter_uid, ps = psvts, sc = opts.sc, st = opts.style and 1 or 0 }
            content_params[#content_params + 1] = params
            return params
        end,
    }
end

local annotation_puts = {}
local annotation_store_fails = false
package.preload["weread.lib.annotation_source"] = function()
    return {
        plain = function(text) return "plain:" .. text end,
        index = function(xhtml) return "index:" .. xhtml end,
    }
end
package.preload["weread.lib.annotation_store"] = function()
    return {
        new = function(_self, settings)
            return {
                put = function(_store, book_id, kind, chapter_key, source, chapter_id)
                    if annotation_store_fails then error("disk full") end
                    annotation_puts[#annotation_puts + 1] = {
                        settings = settings, book_id = book_id, kind = kind,
                        chapter = chapter_key, source = source, chapter_id = chapter_id,
                    }
                end,
            }
        end,
    }
end

-- Scripted ffi/archiver reader for ZIP chapter resources.
local zip_script
package.preload["ffi/archiver"] = function()
    local Reader = {}
    function Reader:new() return setmetatable({ closed = false }, { __index = self }) end
    function Reader:open(path)
        zip_script.opened = path
        if zip_script.open_fails then
            self.err = zip_script.open_err
            return false
        end
        return true
    end
    function Reader:iterate()
        local index = 0
        return function()
            index = index + 1
            return zip_script.entries[index]
        end
    end
    function Reader:extractToMemory(path)
        local data = zip_script.data[path]
        if not data then self.err = zip_script.extract_err end
        return data
    end
    function Reader:close() zip_script.closed = true end
    return { Reader = Reader }
end

local Content = require("weread.lib.content")

local PNG = "\137PNG\r\n\026\n"
local JPEG = "\255\216\255\224"

-- Golden shards produced by the repo's reference encoder
-- (scripts/mock_weread.py: shards(text, count)).
local SHARDS = {
    hi = { "E3AA4A980962F3719A0AFE0956C0072B0HAP", "F7FD7BBE961EDE2FDA7FB3D4DE7AB745-GkS",
        "FB1A86BCFC32815068270BD10DF952F68L3A-" },
    utf8 = "29305A14726D0091DDD5C46B06498E1F0PHeiY2xhc3MGAgEuZuW-ruS_oVSvuIm5piBjaGFwd9-yIG9iPTwvcD4",
    short = "2B35CBFF799297D55A38E48D555C8E610khSG",
    css = "A9D7992CB81DDD7217C0F79C7F1C188B0aHRtbfSib2R5e2tcbnQtc2l6ZTowO21hcmd2ljorex5pb2ZvbnQZvwC6ZTowfQ",
    important_css = "78DF54300406CCE240D9A222EC30340D0Ym9keY2mb250LXwMemU6MHB4ICFpbXBvcnRH0nQsbt9hb3I6IzANp7XueHtmb250LXNpemU6MC41cmVtfQ",
    tiny = "168DFEC6019E47CA2252F109B3219E7E0QQ",
    plain_css = "CB011E5AAA96788C5EB15D08CDBD273F03Ib7Y296cLsmtmVkfQ",
    txt_split = { "339AA2C8BFE283036FB460C871719AA80TDQuZSBBDYQp",
        "DCF62D1A7C6573C7BC55DD2F53DB09B0ICGlPEgCM-oNCg" },
    txt_whole = "D76DC4F654CB8F95CBF26838DA55F3F80TDQuZSBBDYQpICGlPEgCM-oNCg",
    images = { "FA0CCB1478858ED13B18BAE3BF9FF0F10PHA-PGltZyBzcmyBInBpYy5wb9H_dj0x",
        "B47657D78C9B8355148A29E8A2B98225Ii8zcGlcB0d-PmM9ImhMmtZzOi8vaW1nL",
        "D1287A5CB0D87881ADDEB2EB55E329C0nRlc3Qvci9yZW1vdGUuanBnIi8-PC9wPg" },
    second = "8A38CC8AE85B4E1CB4143DBDB168DBCE0Cjb-c2V9APHkP25wPg",
}
local TEXT = {
    images = '<p><img src="pic.png?v=1"/><img src="https://img.test/r/remote.jpg"/></p>',
    second = "<p>second</p>",
    txt = "Line A\r\nB & <C>\r\n\r\n",
}

-- ---------------------------------------------------------------- helpers --

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/incoming")))
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/assets")))
local workspace = { incoming_dir = root .. "/incoming", asset_dir = root .. "/assets" }

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function tar_entry(name, data, typeflag, prefix, magic)
    local header = name .. string.rep("\0", 100 - #name)
        .. string.rep("\0", 24)
        .. string.format("%011o\0", #data)
        .. string.rep("\0", 20)
        .. (typeflag or "0")
    header = header .. string.rep("\0", 512 - #header)
    if prefix ~= nil then
        header = header:sub(1, 257) .. (magic or "ustar\0") .. "00"
            .. header:sub(266, 345) .. prefix .. string.rep("\0", 155 - #prefix) .. header:sub(501)
    end
    return header .. data .. string.rep("\0", (512 - #data % 512) % 512)
end
local TAR_END = string.rep("\0", 1024)

local function settings_with(cache)
    return {
        cache_dir = root,
        get = function(_self, key, default)
            if key == "cache" then return cache or default end
            return default
        end,
    }
end

local function reader_page(fields)
    local parts = {}
    for key, value in pairs(fields) do parts[#parts + 1] = string.format('"%s":"%s"', key, value) end
    return "<html><script>var reader={" .. table.concat(parts, ",") .. "}</script></html>"
end

-- A fake client that records every request. `routes.shard(endpoint, uid)`
-- answers chapter shard POSTs with text, code, status.
local function new_client(routes)
    routes = routes or {}
    local client = { requests = {}, pages = 0 }
    local function record(kind, url, opts, extra)
        client.requests[#client.requests + 1] = { kind = kind, url = url, opts = opts, extra = extra }
    end
    function client:get_text(url, opts)
        record("get_text", url, opts)
        self.pages = self.pages + 1
        return routes.page and routes.page(url, self.pages)
            or reader_page({ psvts = "PS" .. self.pages, token = "tok", bookId = "B1" })
    end
    function client:json_decode(encoded)
        record("json_decode", encoded)
        return routes.json and routes.json(encoded)
    end
    function client:json_encode(params)
        self.last_params = params
        return "json:" .. tostring(params.c)
    end
    function client:request(req)
        record("request", req.url, req)
        local endpoint = req.url:gsub("^https://weread%.qq%.com", "")
        return routes.shard(endpoint, self.last_params and self.last_params.c, req)
    end
    function client:post_json(url, body, opts)
        record("post_json", url, opts, body)
        return routes.catalog(body)
    end
    function client:get_binary(url, opts)
        record("get_binary", url, opts)
        local data = routes.binary[url]
        if type(data) == "function" then return data() end
        return data
    end
    function client:download_to_file(url, path, opts)
        record("download", url, opts, path)
        local data = routes.files[url]
        if type(data) == "function" then data = data() end
        if data == nil then error("HTTP 404 for " .. url) end
        local file = assert(io.open(path, "wb"))
        file:write(data)
        file:close()
        return path
    end
    function client:count(kind, pattern)
        local total = 0
        for _, req in ipairs(self.requests) do
            if req.kind == kind and (not pattern or tostring(req.url):find(pattern, 1, true)) then
                total = total + 1
            end
        end
        return total
    end
    return client
end

local function ok_shard(text) return text, 200, {}, "HTTP/1.1 200 OK" end

-- ------------------------------------------------- checksum and decoding --

expect(Content.decode_content_shards(SHARDS.hi[1], SHARDS.hi[2], SHARDS.hi[3]) == "<p>Hi</p>",
    "three checked shards did not decode to the chapter text")
expect(Content.decode_content_shard(SHARDS.utf8) == '<p class="a">微信读书 chapter one</p>',
    "URL-safe shard with multi-byte text did not decode")
expect(Content.decode_content_shard(SHARDS.short) == "Hi!",
    "short payload (fixed 0/2 swap) did not decode")
expect(Content.decode_content_shard(SHARDS.tiny) == "A",
    "a payload too short to carry swap positions was not decoded as plain base64")
expect(Content.decode_content_shards(SHARDS.txt_split[1], SHARDS.txt_split[2], "") == TEXT.txt,
    "missing third shard must decode as empty")
expect(Content.decode_content_shard("") == "" and Content.decode_content_shard(nil) == "",
    "empty response must decode to empty text")
expect(Content.decode_content_shard(string.rep("A", 32)) == "",
    "a bare 32-byte checksum without body must decode to empty text")
expect_error(function()
    Content.decode_content_shard("00000000000000000000000000000000" .. SHARDS.short:sub(33))
end, "MD5", "a shard whose checksum does not match its body was accepted")
expect_error(function()
    Content.decode_content_shards(SHARDS.hi[1], SHARDS.hi[2]:sub(1, -2) .. "x", SHARDS.hi[3])
end, "MD5", "a corrupted middle shard was accepted")

-- ------------------------------------------------------ catalog parsing --

local chapters_payload = { data = {
    { bookId = "other", updated = { { chapterUid = 99 } } },
    { bookId = 42, updated = { { chapterUid = 1, title = "封面", wordCount = 10 },
        { chapterUid = 2, title = "Preface", wordCount = 0 },
        { chapterUid = 3, title = "One", wordCount = "120" },
        { chapterUid = 4, title = "Two", wordCount = 5 } } },
} }
local normalized = Content.normalize_chapters(chapters_payload, "42")
expect(#normalized == 4 and normalized[1].chapterUid == 1,
    "catalog record of the requested book was not selected by string-compared id")
expect(Content.normalize_chapters({ bookId = "7", chapterInfos = { { chapterUid = 5 } } }, 7)[1].chapterUid == 5,
    "a single unwrapped record with chapterInfos was not accepted")
expect(Content.normalize_chapters({ data = { bookId = "7", chapters = { { chapterUid = 6 } } } }, "7")[1].chapterUid
        == 6, "a single record under data with chapters was not accepted")
expect(#Content.normalize_chapters({ data = { { bookId = "7" } } }, "7") == 0,
    "a matching record without chapter list must yield no chapters")
expect(#Content.normalize_chapters(chapters_payload, "missing") == 0, "unknown book must yield no chapters")
expect(#Content.normalize_chapters("{}", "42") == 0 and #Content.normalize_chapters(nil, "42") == 0,
    "non-table catalog payloads must yield no chapters")
local readable = Content.readable_chapters(normalized)
expect(#readable == 2 and readable[1].chapterUid == 3 and readable[2].chapterUid == 4,
    "cover and empty chapters were not filtered out of the readable list")
expect(Content.first_readable_chapter(normalized).chapterUid == 3, "first readable chapter skipped the wrong ones")
expect(Content.first_readable_chapter({ { title = "封面", wordCount = 3 } }) == nil
        and Content.first_readable_chapter(nil) == nil and #Content.readable_chapters(nil) == 0,
    "catalogs without readable chapters must yield nothing")

-- ------------------------------------------------- reader state session --

do
    local client = new_client()
    local book = { bookId = "B1", pclts = "stale-pclts", title = "Kept title" }
    local state = Content.ensure_reader_state(client, book)
    expect(state.psvts == "PS1" and book.psvts == "PS1" and book.token == "tok",
        "reader session values were not taken from the reader page")
    expect(book.pclts == nil, "a pclts cached from an older reader session survived a fresh reader page")
    expect(book.title == "Kept title" and book.book_id == "B1", "known book fields were overwritten")
    expect(book.reader_url == "https://weread.qq.com/web/reader/B1"
            and client.requests[1].opts.referer == book.reader_url
            and type(client.requests[1].opts.timeout) == "table",
        "reader page was not requested at the book reader URL with a bounded timeout")

    -- The embedded initial state is decoded through the client's JSON decoder.
    local json_client = new_client({
        page = function()
            return 'x window.__INITIAL_STATE__ = {"r":1}; (function(){})'
        end,
        json = function() return { reader = { psvts = "JSON-PS", pclts = "JSON-PC",
            bookInfo = { bookId = "B9", title = "From JSON", author = "A" } } }
        end,
    })
    local fresh = {}
    fresh.bookId = "B9"
    Content.ensure_reader_state(json_client, fresh)
    expect(json_client:count("json_decode") == 1 and fresh.psvts == "JSON-PS" and fresh.pclts == "JSON-PC"
            and fresh.title == "From JSON" and fresh.author == "A",
        "initial state JSON was not decoded via the client")

    local no_psvts = new_client({ page = function() return reader_page({ token = "t" }) end })
    expect_error(function() Content.ensure_reader_state(no_psvts, { bookId = "B1" }) end, "psvts",
        "a reader page without psvts must fail the session")

    local refresh = new_client()
    local refreshed = { book_id = "B1", psvts = "old", reader_url = "https://weread.qq.com/web/reader/B1kOLD" }
    Content.refresh_reader_state(refresh, refreshed, { chapterUid = 8 })
    expect(refresh.requests[1].url == "https://weread.qq.com/web/reader/B1k8" and refreshed.psvts == "PS1",
        "refresh did not reopen the reader at the chapter URL")
    Content.refresh_reader_state(refresh, refreshed, nil)
    expect(refresh.requests[2].url == "https://weread.qq.com/web/reader/B1k8" and refreshed.psvts == "PS2",
        "refresh without chapter did not reuse the current reader URL")
end

-- ---------------------------------------------------------- fetch_catalog --

do
    local client = new_client({ catalog = function() return chapters_payload end })
    local book = { book_id = 42 }
    local chapters = Content.fetch_catalog(client, book)
    local req = client.requests[1]
    expect(req.kind == "post_json" and has(req.url, "/web/book/chapterInfos")
            and req.extra.bookIds[1] == "42" and req.opts.referer == "https://weread.qq.com/web/reader/42",
        "catalog request did not post the stringified book id with the reader referer")
    expect(#chapters == 2 and book.chapters == chapters, "readable catalog was not stored on the book")
    local empty = new_client({ catalog = function() return {} end })
    expect(#Content.fetch_catalog(empty, { book_id = 42 }) == 0, "an empty catalog answer must yield no chapters")
end

-- ---------------------------------------------------- fetch_chapter_shard --

do
    local answers = {}
    local client = new_client({ shard = function(endpoint) return answers[endpoint]() end })
    local book = { book_id = "B1", psvts = "PSV" }
    local chapter = { chapterUid = 12 }
    answers["/web/book/chapter/e_0"] = function() return ok_shard("BODY") end
    expect(Content.fetch_chapter_shard(client, nil, book, chapter, "/web/book/chapter/e_0") == "BODY",
        "successful shard text was not returned")
    local req = client.requests[1].opts
    expect(req.method == "POST" and req.headers.Referer == "https://weread.qq.com/web/reader/B1k12"
            and req.headers.Origin == "https://weread.qq.com" and req.body == "json:12"
            and type(req.timeout) == "table",
        "shard request did not carry method, referer, origin and encoded params")
    local params = content_params[#content_params]
    expect(params.ps == "PSV" and params.st == 0 and params.sc == 1, "text shard params were wrong")
    answers["/web/book/chapter/e_2"] = function() return ok_shard("CSS") end
    Content.fetch_chapter_shard(client, nil, book, chapter, "/web/book/chapter/e_2")
    expect(content_params[#content_params].st == 1, "style shard was not requested in style mode")
    expect(client:count("get_text") == 0, "a known psvts must not reopen the reader page")

    answers["/web/book/chapter/e_1"] = function() return "oops", 500, {}, "HTTP/1.1 500" end
    expect_error(function() Content.fetch_chapter_shard(client, nil, book, chapter, "/web/book/chapter/e_1") end,
        "HTTP 500", "an HTTP error status was not reported")
    answers["/web/book/chapter/e_1"] = function() return "", 302, {}, "HTTP/1.1 302" end
    expect_error(function() Content.fetch_chapter_shard(client, nil, book, chapter, "/web/book/chapter/e_1") end,
        "302", "a redirect status must not count as success")
    answers["/web/book/chapter/e_1"] = function() return nil, nil, nil, "timeout" end
    expect_error(function() Content.fetch_chapter_shard(client, nil, book, chapter, "/web/book/chapter/e_1") end,
        "timeout", "the transport status of a failed request was dropped")
    answers["/web/book/chapter/e_3"] = function() return ok_shard("{}") end
    expect_error(function() Content.fetch_chapter_shard(client, nil, book, chapter, "/web/book/chapter/e_3") end,
        "e_3", "an empty JSON object answer was accepted as a shard")
    expect_error(function() Content.fetch_chapter_shard(client, nil, book, nil, "/web/book/chapter/e_0") end,
        "chapter", "a missing chapter was not rejected")

    local cold = new_client({ shard = function() return ok_shard("X") end })
    local cold_book = { bookId = "B1" }
    expect(Content.fetch_chapter_shard(cold, nil, cold_book, chapter, "/web/book/chapter/e_0") == "X"
            and cold:count("get_text") == 1 and content_params[#content_params].ps == "PS1",
        "a book without psvts did not open the reader session before the shard request")
end

-- ------------------------------------------ TXT/EPUB detection and xhtml --

do
    local xhtml = Content.txt_to_xhtml("a < b\r\n\r\n  \r  trailing   \nlast")
    expect(has(xhtml, "<p>a &lt; b</p>\n<p>  trailing</p>\n<p>last</p>"),
        "plain text lines were not escaped/trimmed into paragraphs: " .. xhtml)
    expect(has(xhtml, '<html xmlns="http://www.w3.org/1999/xhtml">') and not has(xhtml, "<p></p>"),
        "txt xhtml lacks the XHTML namespace or kept blank paragraphs")
end

local function shard_router(by_endpoint)
    return function(endpoint, uid)
        local answer = by_endpoint[endpoint]
        if type(answer) == "table" then answer = answer[uid] end
        if type(answer) == "function" then return answer(uid) end
        if answer == nil then return "missing", 404, {}, "HTTP/1.1 404" end
        return ok_shard(answer)
    end
end

do
    -- EPUB chapter: three shards decoded after a per-chapter reader refresh.
    annotation_puts = {}
    local client = new_client({ shard = shard_router({
        ["/web/book/chapter/e_0"] = SHARDS.hi[1],
        ["/web/book/chapter/e_1"] = SHARDS.hi[2],
        ["/web/book/chapter/e_3"] = SHARDS.hi[3],
    }) })
    local book = { book_id = "B1", psvts = "stale" }
    local text = Content.fetch_chapter_xhtml(client, settings_with({}), book, { chapterUid = 3 })
    expect(text == "<p>Hi</p>" and book._content_format == "epub", "EPUB chapter was not decoded")
    expect(client.requests[1].kind == "get_text" and client.requests[1].url == "https://weread.qq.com/web/reader/B1k3",
        "chapter fetch did not refresh the reader session first")
    expect(content_params[#content_params].ps == "PS1", "shards were requested with a stale psvts")

    -- A JSON e_0 answer marks the book as TXT; the t_1 shard is optional.
    annotation_puts = {}
    local txt_client = new_client({ shard = shard_router({
        ["/web/book/chapter/e_0"] = '{"bookId":"T1","format":"txt"}',
        ["/web/book/chapter/t_0"] = SHARDS.txt_whole,
        ["/web/book/chapter/t_1"] = function() return "", 500, {}, "HTTP/1.1 500" end,
    }) })
    local txt_book = { book_id = "T1" }
    local settings = settings_with({})
    local txt = Content.fetch_chapter_xhtml(txt_client, settings, txt_book, { chapterUid = 1 })
    expect(txt_book._content_format == "txt" and has(txt, "<p>Line A</p>\n<p>B &amp; &lt;C&gt;</p>"),
        "TXT chapter was not converted to xhtml")
    expect(#annotation_puts == 1 and annotation_puts[1].source == "plain:" .. TEXT.txt
            and annotation_puts[1].book_id == "T1" and annotation_puts[1].chapter == "1"
            and annotation_puts[1].kind == "original",
        "raw TXT text was not cached as the annotation source")
    -- Once known as TXT, later chapters go straight to the t_* shards.
    local before = txt_client:count("request", "/e_0")
    txt_client.requests = {}
    Content.fetch_chapter_xhtml(txt_client, settings, txt_book, { chapterUid = 2 })
    expect(txt_client:count("request", "/e_0") == 0 and txt_client:count("request", "/t_0") == 1 and before == 1,
        "a known TXT book still probed the EPUB shard")
    -- Split t_0 + t_1 shards are joined.
    local split_client = new_client({ shard = shard_router({
        ["/web/book/chapter/t_0"] = SHARDS.txt_split[1],
        ["/web/book/chapter/t_1"] = SHARDS.txt_split[2],
    }) })
    local split = Content.fetch_txt_as_xhtml(split_client, settings, { book_id = "T1", psvts = "p",
        _content_format = "txt" }, { chapterUid = 5 })
    expect(has(split, "<p>B &amp; &lt;C&gt;</p>"), "TXT text split across t_0 and t_1 was not joined")
    -- A failing t_0 fails the chapter.
    local broken_txt = new_client({ shard = shard_router({}) })
    expect_error(function()
        Content.fetch_chapter_xhtml(broken_txt, settings, { book_id = "T1", _content_format = "txt" }, { chapterUid = 1 })
    end, "HTTP 404", "a failing t_0 shard did not fail the TXT chapter")

    -- e_0 failure is surfaced and the format stays unknown.
    local failing = new_client({ shard = shard_router({
        ["/web/book/chapter/e_0"] = function() return nil, nil, nil, "wantread" end,
    }) })
    local failing_book = { book_id = "B1" }
    expect_error(function() Content.fetch_chapter_xhtml(failing, settings, failing_book, { chapterUid = 3 }) end,
        "wantread", "e_0 transport failure was not surfaced")
    expect(failing_book._content_format == nil, "a failed probe must not decide the book format")
    -- e_1 failure after a good e_0 fails the chapter too.
    local half = new_client({ shard = shard_router({
        ["/web/book/chapter/e_0"] = SHARDS.hi[1],
        ["/web/book/chapter/e_1"] = function() return "", 503, {}, "HTTP/1.1 503" end,
    }) })
    expect_error(function() Content.fetch_chapter_xhtml(half, settings, { book_id = "B1" }, { chapterUid = 3 }) end,
        "HTTP 503", "a failing e_1 shard did not fail the chapter")
end

-- A caller must explicitly opt in to an already accepted job's session.
do
    local parts = { ["/web/book/chapter/e_0"] = SHARDS.hi[1],
        ["/web/book/chapter/e_1"] = SHARDS.hi[2], ["/web/book/chapter/e_3"] = SHARDS.hi[3] }
    local client = new_client({ shard = shard_router(parts) })
    local book, settings = { book_id = "B1" }, settings_with({})
    local options = { reuse_reader_state = true }
    expect(Content.fetch_chapter_xhtml(client, settings, book, { chapterUid = 1, chapterIdx = 1 }, options) == "<p>Hi</p>"
        and client.pages == 1, "reuse without a session must still start fresh")
    expect(Content.fetch_chapter_xhtml(client, settings, book, { chapterUid = 2, chapterIdx = 2 }, options) == "<p>Hi</p>"
        and client.pages == 1, "accepted session was not reused")
    expect(book.reader_url == "https://weread.qq.com/web/reader/B1k2"
        and content_params[#content_params].ps == "PS1", "reuse lost the current chapter referer or accepted session")
    local positioned = { book_id = "B1", psvts = "accepted", pclts = "clock", token = "token",
        chapter_uid = 1, chapter_idx = 1, chapter_offset = 17, progress = 35, summary = "cached summary" }
    Content.fetch_chapter_xhtml(client, settings, positioned, { chapterUid = 5, chapterIdx = "12" }, options)
    expect(positioned.chapter_uid == 5 and positioned.chapter_idx == 12 and positioned.chapter_offset == 17,
        "reused reader metadata did not follow its current catalog chapter")
    expect(positioned.progress == 35 and positioned.summary == "cached summary" and positioned.psvts == "accepted"
        and positioned.pclts == "clock" and positioned.token == "token" and client.pages == 1,
        "catalog metadata update changed cached progress, credentials or reader request count")
    Content.fetch_chapter_xhtml(client, settings, positioned, { chapterUid = 6, chapterIdx = 13, chapterOffset = 0 }, options)
    expect(positioned.chapter_uid == 6 and positioned.chapter_idx == 13 and positioned.chapter_offset == 0
        and positioned.progress == 35 and positioned.summary == "cached summary",
        "catalog metadata update lost supplied index or explicit zero offset")
    local authoritative_uid
    local missing_index = new_client({
        shard = shard_router(parts),
        page = function(url)
            authoritative_uid = tonumber(url:match("k(%d+)$"))
            return 'window.__INITIAL_STATE__={};(function(){})();'
        end,
        json = function()
            return { reader = {
                bookInfo = { bookId = "B1" }, psvts = "fresh-" .. authoritative_uid,
                currentChapter = { chapterUid = authoritative_uid, chapterIdx = authoritative_uid + 8 },
                progress = { book = { chapterOffset = 17, progress = 35, summary = "cloud summary" } },
            } }
        end,
    })
    for index, chapter in ipairs({ { chapterUid = 6 }, { chapterUid = 7, chapterIdx = "unknown" } }) do
        local stale = { book_id = "B1", psvts = "accepted", chapter_uid = 1, chapter_idx = 1,
            progress = 35, summary = "cached summary" }
        Content.fetch_chapter_xhtml(missing_index, settings, stale, chapter, options)
        expect(missing_index.pages == index and stale.chapter_uid == chapter.chapterUid
            and stale.chapter_idx == chapter.chapterUid + 8 and stale.psvts == "fresh-" .. chapter.chapterUid,
            "missing/invalid catalog index reused a stale reader position instead of authoritative fresh state")
        expect(stale.chapter_offset == 17 and stale.progress == 35 and stale.summary == "cloud summary",
            "fresh metadata fallback discarded authoritative reader progress")
    end
    Content.fetch_chapter_xhtml(client, settings, book, { chapterUid = 3, chapterIdx = 3 })
    Content.fetch_chapter_xhtml(client, settings, book, { chapterUid = 4, chapterIdx = 4 }, { reuse_reader_state = false })
    expect(client.pages == 3 and book.psvts == "PS3", "raw/default callers must keep per-chapter refresh")

    local old = { book_id = "B1", psvts = "accepted", pclts = "old-clock", token = "old-token" }
    local rejected
    rejected = new_client({ shard = function(endpoint)
        if rejected.pages == 0 then return ok_shard("{}") end
        return ok_shard(parts[endpoint])
    end })
    expect(Content.fetch_chapter_xhtml(rejected, settings, old, { chapterUid = 9, chapterIdx = 9 }, options) == "<p>Hi</p>",
        "explicit context rejection did not refresh the accepted session")
    expect(rejected.pages == 1 and rejected:count("request", "/e_0") == 2,
        "context rejection must get exactly one fresh attempt")
    expect(old.psvts == "PS1" and old.pclts == nil and old.token == "tok",
        "fallback retained credentials omitted by the fresh reader")

    local permanent = new_client({ shard = function() return ok_shard("{}") end })
    expect_error(function()
        Content.fetch_chapter_xhtml(permanent, settings, { book_id = "B1", psvts = "accepted" }, { chapterUid = 1, chapterIdx = 1 }, options)
    end, "returned empty object", "permanent context refusal must fail")
    expect(permanent.pages == 1 and permanent:count("request") == 2,
        "a rejected fresh attempt must not loop or perform another reader refresh")

    local checksum
    checksum = new_client({ shard = function(endpoint)
        if checksum.pages == 0 and endpoint == "/web/book/chapter/e_1" then
            return ok_shard(string.rep("0", 32) .. "invalid-checked-shard")
        end
        return ok_shard(parts[endpoint])
    end })
    expect(Content.fetch_chapter_xhtml(checksum, settings, { book_id = "B1", psvts = "accepted" },
        { chapterUid = 1, chapterIdx = 1 }, options) == "<p>Hi</p>" and checksum.pages == 1,
        "a cached shard checksum rejection did not get one fresh attempt")

    for _, failure in ipairs({ "transport", "http" }) do
        local failed = new_client({ shard = function()
            if failure == "transport" then return nil, nil, {}, "wantread" end
            return "unavailable", 503, {}, "HTTP/1.1 503"
        end })
        expect_error(function()
            Content.fetch_chapter_xhtml(failed, settings, { book_id = "B1", psvts = "accepted" }, { chapterUid = 1, chapterIdx = 1 }, options)
        end, failure == "transport" and "wantread" or "HTTP 503", "cached request failure changed")
        expect(failed.pages == 0 and failed:count("request") == 1,
            "transport/HTTP failure must keep the outer downloader's retry policy")
    end
    local exception = { reason = "worker aborted" }
    local throws = new_client({ shard = function() error(exception, 0) end })
    local ok, err = pcall(Content.fetch_chapter_xhtml, throws, settings,
        { book_id = "B1", psvts = "accepted" }, { chapterUid = 1, chapterIdx = 1 }, options)
    expect(not ok and err == exception and throws.pages == 0, "non-string errors must propagate without a fresh attempt")

    local txt_client = new_client({ shard = shard_router({
        ["/web/book/chapter/t_0"] = SHARDS.txt_whole, ["/web/book/chapter/t_1"] = "",
    }) })
    expect(has(Content.fetch_chapter_xhtml(txt_client, settings,
        { book_id = "B1", psvts = "accepted", _content_format = "txt" }, { chapterUid = 1, chapterIdx = 1 }, options), "<p>Line A</p>")
        and txt_client.pages == 0, "known TXT chapters must retain the opt-in reuse behavior")

    local source_client = new_client({ shard = shard_router(parts) })
    local state = { css = "accepted stylesheet" }
    expect(Content.fetch_single_chapter_source(source_client, settings, { book_id = "B1", psvts = "accepted" },
        { chapterUid = 2, chapterIdx = 2 }, state, options) == "<p>Hi</p>" and source_client.pages == 0
        and state.css == "accepted stylesheet", "chapter source did not forward its job's reuse option")
end

-- ------------------------------------------------------- fetch_chapter_css --

do
    logs = {}
    local client = new_client({ shard = shard_router({ ["/web/book/chapter/e_2"] = SHARDS.css }) })
    local css = Content.fetch_chapter_css(client, nil, { book_id = "B1", psvts = "p" }, { chapterUid = 1 })
    expect(css == "html,body{margin:0}.k{font-size:0}",
        "root font-size:0 was not removed or a non-root rule was touched: " .. tostring(css))
    local warned = false
    for _, entry in ipairs(logs) do
        if entry.level == "warn" and has(entry.text, "font-size") then warned = true end
    end
    expect(warned, "removing hostile css declarations was not logged")
    logs = {}
    local plain = new_client({ shard = shard_router({ ["/web/book/chapter/e_2"] = SHARDS.plain_css }) })
    expect(Content.fetch_chapter_css(plain, nil, { book_id = "B1", psvts = "p" }, { chapterUid = 1 })
            == ".k{color:red}" and #logs == 0, "clean css was changed or logged")
    local important = new_client({ shard = shard_router({ ["/web/book/chapter/e_2"] = SHARDS.important_css }) })
    expect(Content.fetch_chapter_css(important, nil, { book_id = "B1", psvts = "p" }, { chapterUid = 1 })
            == "body{color:#000}.x{font-size:0.5rem}",
        "an !important zero root font size was kept or a fractional size was removed")
    local missing = new_client({ shard = shard_router({}) })
    expect(Content.fetch_chapter_css(missing, nil, { book_id = "B1", psvts = "p" }, { chapterUid = 1 }) == nil,
        "a failing style shard must yield no css instead of failing the chapter")
    local empty = new_client({ shard = shard_router({ ["/web/book/chapter/e_2"] = "{}" }) })
    expect(Content.fetch_chapter_css(empty, nil, { book_id = "B1", psvts = "p" }, { chapterUid = 1 }) == nil,
        "an empty style shard answer must yield no css")
end

-- ------------------------------------------------- rewrite_image_sources --

do
    local xhtml = '<img src="a.png?x=1&amp;y=2"/><img src=\'dir/b.jpg#f\'/><img src="keep.gif"/>'
    local out = Content.rewrite_image_sources(xhtml, { ["a.png"] = "../images/a.png", ["b.jpg"] = "../images/b-2.jpg" })
    expect(out == '<img src="../images/a.png"/><img src=\'../images/b-2.jpg\'/><img src="keep.gif"/>',
        "image sources were not mapped by basename: " .. out)
    expect(Content.rewrite_image_sources(xhtml, {}) == xhtml and Content.rewrite_image_sources(xhtml, nil) == xhtml,
        "an empty source map must leave the xhtml untouched")
end

-- ----------------------------------------------- download_remote_images --

do
    local calls = 0
    local client = new_client({ binary = {
        ["https://cdn.test/a/photo.png"] = PNG .. "one",
        ["https://other.test/b/photo.png"] = PNG .. "two",
        ["https://cdn.test/broken.png"] = function() error("socket closed") end,
        ["https://cdn.test/page.html"] = "<html>not an image</html>",
        ["https://cdn.test/empty.png"] = "",
        ["http://cdn.test/"] = function() calls = calls + 1; return JPEG .. "root" end,
    } })
    local xhtml = table.concat({
        '<img src="//cdn.test/a/photo.png"/>',
        '<img src="https://other.test/b/photo.png"/>',
        "<img src='https://cdn.test/a/photo.png'/>",
        '<img src="../images/local.png"/>',
        '<img src="https://cdn.test/broken.png"/>',
        '<img src="https://cdn.test/page.html"/>',
        '<img src="https://cdn.test/empty.png"/>',
        '<img src="http://cdn.test/"/>',
    })
    local used = {}
    local progress = {}
    local out, assets = Content.download_remote_images(client, xhtml, used, function(index, total)
        progress[#progress + 1] = index .. "/" .. total
    end)
    expect(#assets == 3, "expected three downloaded remote images, got " .. #assets)
    expect(assets[1].href == "images/photo.png" and assets[2].href == "images/photo-2.png"
            and assets[1].data == PNG .. "one" and assets[2].media_type == "image/png",
        "duplicate remote image names were not made unique")
    expect(assets[3].href:match("^images/[%w%._-]+%.jpg$") and calls == 1,
        "an URL without file name did not get a usable image name: " .. tostring(assets[3].href))
    expect(has(out, '<img src="../images/photo.png"/><img src="../images/photo-2.png"/>'
            .. "<img src='../images/photo.png'/>"), "remote sources were not rewritten: " .. out)
    expect(client:count("get_binary", "cdn.test/a/photo.png") == 1, "a repeated image URL was downloaded twice")
    expect(has(out, '<img src="../images/local.png"/><img src="https://cdn.test/broken.png"/>'
            .. '<img src="https://cdn.test/page.html"/><img src="https://cdn.test/empty.png"/>'),
        "failed, non-image or local sources must stay unchanged: " .. out)
    expect(#progress == 7 and progress[1] == "1/7" and progress[7] == "7/7", "image progress was not reported")
    expect(client.requests[1].opts.referer == "https://weread.qq.com/" and type(client.requests[1].opts.timeout) == "table",
        "remote images were requested without referer or timeout")

    -- A later chapter sharing the used-name table reuses already stored images.
    local again, again_assets = Content.download_remote_images(client, '<img src="https://other.test/b/photo.png"/>', used)
    expect(again == '<img src="../images/photo-2.png"/>' and #again_assets == 0
            and client:count("get_binary", "other.test") == 1,
        "an image already stored for this book was downloaded again")

    local untouched_client = new_client({ binary = {} })
    local plain, none = Content.download_remote_images(untouched_client, '<img src="x.png"/>', nil, function()
        error("progress must not be reported without remote images")
    end)
    expect(plain == '<img src="x.png"/>' and #none == 0 and #untouched_client.requests == 0,
        "xhtml without remote images must be returned untouched")
end

-- ----------------------------------------------- download_chapter_assets --

do
    local tar = tar_entry("img/pic.png", PNG .. "a")
        .. tar_entry("other/pic.png", PNG .. "b")
        .. tar_entry("img/cover.jpg", JPEG .. "c")
        .. tar_entry("img/", "", "5")
        .. tar_entry("notes.txt", "hello world")
        .. tar_entry("link.png", PNG, "2")
        .. TAR_END
    local client = new_client({ binary = { ["https://res.test/1.tar"] = tar,
        ["https://weread.qq.com/tar/2"] = TAR_END, ["https://cdn.test/3.tar"] = "" } })
    local used = {}
    local assets, src_map = Content.download_chapter_assets(client, { bookId = "B1" },
        { chapterUid = 4, tar = "https://res.test/1.tar" }, used)
    expect(#assets == 3, "expected three image entries from the TAR, got " .. #assets)
    expect(assets[1].href == "images/pic.png" and assets[2].href == "images/pic-2.png"
            and assets[2].data == PNG .. "b", "duplicate TAR image names were not made unique")
    expect(assets[3].href == "images/cover-2.jpg" and assets[3].media_type == "image/jpeg",
        "the reserved cover name was handed to a chapter image: " .. tostring(assets[3].href))
    expect(Content.rewrite_image_sources('<img src="cover.jpg"/><img src="unmatched/cover.jpg"/>', src_map)
            == '<img src="../images/cover-2.jpg"/><img src="../images/cover-2.jpg"/>',
        "unique basename fallback was not retained")
    expect(Content.rewrite_image_sources('<img src="pic.png"/><img src="unmatched/pic.png"/>', src_map)
            == '<img src="pic.png"/><img src="unmatched/pic.png"/>',
        "an ambiguous basename was silently mapped to an unrelated image")
    expect(Content.rewrite_image_sources('<img src="./img/pic.png?x=1&amp;y=2"/><img src=\'other/pic.png#f\'/>', src_map)
            == '<img src="../images/pic.png"/><img src=\'../images/pic-2.png\'/>',
        "exact source paths with dot prefix, query or fragment were not mapped")
    expect(Content.rewrite_image_sources('<img src="img/pic.png"/><img src="other/pic.png"/>', src_map)
        == '<img src="../images/pic.png"/><img src="../images/pic-2.png"/>',
        "distinct archive paths were aliased to the last basename match")
    expect(client.requests[1].opts.referer == "https://weread.qq.com/web/reader/B1k4",
        "chapter resources were requested without the chapter referer")

    local long_prefix = string.rep("a", 155)
    local long_name = string.rep("b", 96) .. ".png"
    local ustar = tar_entry("pic.png", PNG .. "first", nil, "first")
        .. tar_entry("pic.png", PNG .. "second", nil, "second ")
        .. tar_entry("pic.png ", PNG .. "spaced-name", nil, "first")
        .. tar_entry(long_name, PNG .. "long", nil, long_prefix)
        .. tar_entry("plain.png", PNG .. "plain", nil, "")
        .. tar_entry("gnu.png", PNG .. "gnu", nil, "not-a-prefix", "ustar ") .. TAR_END
    local ustar_client = new_client({ binary = { ["https://res.test/ustar.tar"] = ustar } })
    local ustar_assets, ustar_map = Content.download_chapter_assets(ustar_client, { book_id = "B1" },
        { chapterUid = 9, tar = "https://res.test/ustar.tar" }, {})
    local ustar_data = {}
    for _, asset in ipairs(ustar_assets) do ustar_data["../" .. asset.href] = asset.data end
    for source, payload in pairs({ ["first/pic.png"] = "first", ["second /pic.png"] = "second",
        ["first/pic.png "] = "spaced-name",
        [long_prefix .. "/" .. long_name] = "long", ["plain.png"] = "plain", ["gnu.png"] = "gnu" }) do
        local rewritten = Content.rewrite_image_sources('<img src="' .. source .. '"/>', ustar_map)
        expect(ustar_data[rewritten:match('src="(.-)"')] == PNG .. payload,
            "USTAR source path did not select its own image: " .. source)
    end
    expect(Content.rewrite_image_sources('<img src="pic.png"/>', ustar_map) == '<img src="pic.png"/>',
        "USTAR prefixed entries incorrectly claimed a bare source path")
    expect(ustar_map.paths[long_prefix .. "/" .. long_name],
        "full-width USTAR prefix or name was truncated")
    expect(ustar_map.paths["gnu.png"] and not ustar_map.paths["not-a-prefix/gnu.png"],
        "old GNU header extension bytes were interpreted as a POSIX prefix")

    -- Root entries must win over ambiguous basename fallback. A generated
    -- suffix must never steal an actual source name, in either archive order.
    for _, reverse in ipairs({ false, true }) do
        local entries = { tar_entry("./dir/pic.png", PNG .. "nested"),
            tar_entry("pic.png", PNG .. "root"), tar_entry("pic-2.png", PNG .. "suffix") }
        if reverse then entries[1], entries[3] = entries[3], entries[1] end
        local collision_client = new_client({ binary = { ["https://res.test/names.tar"] = table.concat(entries) .. TAR_END } })
        local mapped, mapping = Content.download_chapter_assets(collision_client, { book_id = "B1" },
            { chapterUid = 8, tar = "https://res.test/names.tar" }, {})
        local data_by_href = {}
        for _, asset in ipairs(mapped) do data_by_href["../" .. asset.href] = asset.data end
        for source, payload in pairs({ ["dir/pic.png"] = "nested", ["pic.png"] = "root", ["pic-2.png"] = "suffix" }) do
            local rewritten = Content.rewrite_image_sources('<img src="' .. source .. '"/>', mapping)
            expect(data_by_href[rewritten:match('src="(.-)"')] == PNG .. payload,
                "source identity changed with root-name or generated-suffix collision: " .. source)
        end
    end

    Content.download_chapter_assets(client, { book_id = "B1" }, { chapterUid = 5, tar = "/tar/2" }, used)
    expect(client.requests[2].url == "https://weread.qq.com/tar/2", "site-relative TAR URL was not resolved")
    local none = Content.download_chapter_assets(client, { book_id = "B1" }, { chapterUid = 6, tar = "//cdn.test/3.tar" })
    expect(client.requests[3].url == "https://cdn.test/3.tar" and #none == 0,
        "protocol-relative TAR URL was not resolved or an empty archive produced assets")
    local before = #client.requests
    local a, m = Content.download_chapter_assets(client, { book_id = "B1" }, { chapterUid = 7, tar = "" })
    local b = Content.download_chapter_assets(client, { book_id = "B1" }, nil)
    expect(#a == 0 and next(m) == nil and #b == 0 and #client.requests == before,
        "chapters without resources must not issue requests")
end

-- -------------------------------------- download_chapter_assets_to_files --

do
    local files = {}
    local client = new_client({ files = files })
    local book = { book_id = "B1" }
    local function fetch(tar_bytes, uid, used)
        files["https://res.test/" .. uid .. ".tar"] = tar_bytes
        return Content.download_chapter_assets_to_files(client, book,
            { chapterUid = uid, tar = "https://res.test/" .. uid .. ".tar" }, used or {}, workspace)
    end

    local used = {}
    local assets, src_map = fetch(tar_entry("a/fig.png", PNG .. "123")
        .. tar_entry("b/fig.png", PNG .. "4567") .. tar_entry("readme", "text") .. TAR_END, "c1", used)
    expect(#assets == 2 and assets[2].href == "images/fig-2.png" and assets[2].store == true
            and assets[2].size == #PNG + 4 and read_file(assets[2].path) == PNG .. "4567",
        "TAR images were not streamed to unique files")
    expect(Content.rewrite_image_sources('<img src="a/fig.png"/><img src="b/fig.png"/><img src="fig.png"/>', src_map)
            == '<img src="../images/fig.png"/><img src="../images/fig-2.png"/><img src="fig.png"/>',
        "streamed TAR source paths were conflated or an ambiguous basename was guessed")
    expect(read_file(workspace.incoming_dir .. "/chapter-c1.tar") == nil, "downloaded archive was not removed")
    expect(client.requests[1].opts.max_bytes and type(client.requests[1].opts.timeout) == "table",
        "archive download was not bounded")

    local prefixed, prefixed_map = fetch(tar_entry("pic.png", PNG .. "first", nil, "first")
        .. tar_entry("pic.png", PNG .. "second", nil, "second")
        .. tar_entry("pic.png ", PNG .. "spaced-name", nil, "first")
        .. tar_entry("plain.png", PNG .. "plain", nil, "")
        .. tar_entry("gnu.png", PNG .. "gnu", nil, "not-a-prefix", "ustar ") .. TAR_END, "ustar")
    expect(#prefixed == 5 and read_file(prefixed[1].path) == PNG .. "first"
        and read_file(prefixed[2].path) == PNG .. "second", "USTAR bytes changed during streaming")
    expect(Content.rewrite_image_sources('<img src="first/pic.png"/><img src="second/pic.png"/><img src="pic.png"/>', prefixed_map)
        == '<img src="../images/pic.png"/><img src="../images/pic-2.png"/><img src="pic.png"/>',
        "streamed USTAR source paths were conflated or claimed a bare source path")
    expect(Content.rewrite_image_sources('<img src="first/pic.png "/>', prefixed_map)
        == '<img src="../' .. prefixed[3].href .. '"/>'
        and read_file(prefixed[3].path) == PNG .. "spaced-name",
        "streamed USTAR name whitespace aliased distinct image sources")
    expect(prefixed_map.paths["plain.png"] and prefixed_map.paths["gnu.png"]
        and not prefixed_map.paths["not-a-prefix/gnu.png"], "streamed TAR format detection changed legacy names")

    -- A TAR that ends without the zero trailer is still accepted.
    local open_ended = fetch(tar_entry("x.jpg", JPEG .. "z"), "c2")
    expect(#open_ended == 1 and open_ended[1].media_type == "image/jpeg",
        "a TAR without end-of-archive blocks lost its entries")

    local function malformed(bytes, uid, needle, message)
        expect_error(function() fetch(bytes, uid) end, needle, message)
        expect(read_file(workspace.incoming_dir .. "/chapter-" .. uid .. ".tar") == nil,
            message .. ": archive was left behind")
    end
    local good = tar_entry("p.png", PNG .. string.rep("p", 600))
    malformed(good:sub(1, 300), "m1", "TAR header", "a truncated TAR header was accepted")
    malformed(good:sub(1, 512 + 400), "m2", "TAR entry", "a truncated TAR entry was accepted")
    malformed(good:sub(1, 512 + 6), "m3", "TAR entry", "a TAR entry cut inside its first bytes was accepted")
    malformed(good:sub(1, 512 + #PNG + 600 + 10), "m4", "TAR padding", "truncated TAR padding was accepted")
    expect(read_file(workspace.asset_dir .. "/p.png") == nil,
        "a failed TAR extraction left a partial image on disk")
    local failed_names = { ["fig.png"] = true }
    expect_error(function()
        fetch(tar_entry("complete.png", PNG .. "complete") .. good:sub(1, 512 + 400), "m6", failed_names)
    end, "TAR entry", "a late TAR failure was accepted")
    expect(read_file(workspace.asset_dir .. "/complete.png") == nil
            and read_file(workspace.asset_dir .. "/p.png") == nil,
        "a late TAR failure did not remove every image from that attempt")
    expect(failed_names["complete.png"] == nil and failed_names["p.png"] == nil and failed_names["fig.png"],
        "a failed TAR extraction retained new names or removed previous reservations")
    expect(read_file(assets[1].path) == PNG .. "123", "rollback removed a previously extracted chapter asset")
    local retried = fetch(tar_entry("complete.png", PNG .. "complete") .. good .. TAR_END, "m6", failed_names)
    expect(#retried == 2 and retried[1].href == "images/complete.png" and retried[2].href == "images/p.png",
        "retry after a failed TAR did not reuse its original asset names")
    local collided_names = { ["fig.png"] = true }
    expect_error(function()
        fetch(tar_entry("a/fig.png", PNG .. "new")
            .. tar_entry("b/fig.png", PNG .. string.rep("p", 600)):sub(1, 512 + 400),
            "collision-retry", collided_names)
    end, "TAR entry", "a colliding partial TAR was accepted")
    local collided_retry = fetch(tar_entry("a/fig.png", PNG .. "new")
        .. tar_entry("b/fig.png", PNG .. "second") .. TAR_END, "collision-retry", collided_names)
    expect(collided_retry[1].href == "images/fig-2.png" and collided_retry[2].href == "images/fig-3.png",
        "rolled-back suffixes must be reused on retry")
    local bad_size = tar_entry("p.png", "data")
    bad_size = bad_size:sub(1, 124) .. "zzzzzzzzzzz\0" .. bad_size:sub(137)
    malformed(bad_size, "m5", "TAR entry size", "a non-octal TAR size was accepted")
    expect_error(function()
        Content.download_chapter_assets_to_files(client, book, { chapterUid = "gone", tar = "/gone" }, {}, workspace)
    end, "404", "a failed archive download was not reported")
    expect(client.requests[#client.requests].url == "https://weread.qq.com/gone",
        "site-relative archive URL was not resolved")
    files["https://cdn.test/rel.tar"] = TAR_END
    local rel = Content.download_chapter_assets_to_files(client, book,
        { chapterUid = "r", tar = "//cdn.test/rel.tar" }, nil, workspace)
    expect(#rel == 0 and client.requests[#client.requests].url == "https://cdn.test/rel.tar",
        "protocol-relative archive URL was not resolved")
    local count = #client.requests
    local nothing = Content.download_chapter_assets_to_files(client, book, { chapterUid = 1 }, {}, workspace)
    expect(#nothing == 0 and #client.requests == count, "a chapter without resources issued a request")

    -- ZIP resources (PK signature) go through libarchive.
    zip_script = {
        entries = { { path = "pages/p1.jpg", mode = "file", size = 5 },
            { path = "pages/", mode = "directory", size = 0 },
            { path = "meta.json", mode = "file", size = 2 },
            { path = "other/p1.jpg", mode = "file", size = 5 } },
        data = { ["pages/p1.jpg"] = JPEG .. "1", ["meta.json"] = "{}", ["other/p1.jpg"] = JPEG .. "2" },
    }
    local zip_assets, zip_map = fetch("PK\3\4zipdata", "z1")
    expect(#zip_assets == 2 and zip_assets[2].href == "images/p1-2.jpg"
            and read_file(zip_assets[2].path) == JPEG .. "2" and zip_script.closed,
        "ZIP images were not extracted to unique files")
    expect(Content.rewrite_image_sources('<img src="pages/p1.jpg"/><img src="other/p1.jpg"/><img src="p1.jpg"/>', zip_map)
            == '<img src="../images/p1.jpg"/><img src="../images/p1-2.jpg"/><img src="p1.jpg"/>',
        "ZIP source paths were conflated or an ambiguous basename was guessed")
    -- Without an asset directory the images stay in memory.
    zip_script.closed = false
    files["https://res.test/z2.tar"] = "PK\3\4zipdata"
    local mem_assets = Content.download_chapter_assets_to_files(client, book,
        { chapterUid = "z2", tar = "https://res.test/z2.tar" }, {}, { incoming_dir = workspace.incoming_dir })
    expect(#mem_assets == 2 and mem_assets[1].data == JPEG .. "1" and mem_assets[1].path == nil,
        "ZIP images without asset directory were not kept in memory")

    zip_script = { entries = {}, data = {}, open_fails = true, open_err = "unsupported format" }
    malformed("PK\3\4", "z3", "unsupported format", "an unreadable ZIP was not reported")
    expect(zip_script.closed, "the archive reader was not closed after a failure")
    zip_script = { entries = { { path = "huge.png", mode = "file", size = 600 * 1024 * 1024 } }, data = {} }
    malformed("PK\3\4", "z4", "too large", "an oversized ZIP entry was accepted")
    zip_script = { entries = { { path = "x.png", mode = "file", size = 3 } }, data = {}, extract_err = "crc error" }
    malformed("PK\3\4", "z5", "crc error", "a ZIP entry that failed to extract was accepted")
    zip_script = {
        entries = { { path = "zip-good.png", mode = "file", size = #PNG + 1 },
            { path = "bad.png", mode = "file", size = 3 } },
        data = { ["zip-good.png"] = PNG .. "z" }, extract_err = "crc error",
    }
    local zip_names = { ["fig.png"] = true }
    expect_error(function() fetch("PK\3\4", "z6", zip_names) end, "crc error", "late ZIP failure was accepted")
    expect(zip_script.closed and read_file(workspace.asset_dir .. "/zip-good.png") == nil
            and zip_names["zip-good.png"] == nil and zip_names["fig.png"],
        "a failed ZIP did not close its reader and roll back its images and names")
end

-- -------------------------------------- download_remote_images_to_files --

do
    local files = {
        ["https://cdn.test/a/pic.png"] = PNG .. "A",
        ["https://other.test/pic.png"] = PNG .. "BB",
        ["https://cdn.test/page"] = "<html>",
    }
    local client = new_client({ files = files })
    local used = {}
    local progress = {}
    local xhtml = '<img src="//cdn.test/a/pic.png"/><img src="https://other.test/pic.png"/>'
        .. '<img src="https://cdn.test/a/pic.png"/><img src="https://cdn.test/missing.png"/>'
        .. '<img src="https://cdn.test/page"/><img src="local.png"/>'
    local out, assets = Content.download_remote_images_to_files(client, xhtml, used, workspace,
        function(index, total) progress[#progress + 1] = index .. "/" .. total end)
    expect(#assets == 2 and assets[1].href == "images/pic.png" and assets[2].href == "images/pic-2.png",
        "remote images on disk did not get unique names")
    expect(assets[2].size == #PNG + 2 and read_file(assets[2].path) == PNG .. "BB" and assets[2].store,
        "remote image file asset has wrong size or content")
    expect(out == '<img src="../images/pic.png"/><img src="../images/pic-2.png"/><img src="../images/pic.png"/>'
            .. '<img src="https://cdn.test/missing.png"/><img src="https://cdn.test/page"/><img src="local.png"/>',
        "remote sources were not rewritten correctly: " .. out)
    expect(client:count("download", "cdn.test/a/pic.png") == 1, "a repeated image was downloaded twice")
    expect(#progress == 5 and progress[5] == "5/5", "progress did not count remote images")
    expect(read_file(workspace.incoming_dir .. "/remote-000004.bin") == nil
            and read_file(workspace.incoming_dir .. "/remote-000005.bin") == nil,
        "failed or rejected downloads left incoming files behind")

    -- If the image cannot be moved into the asset directory it stays remote.
    local broken_ws = { incoming_dir = workspace.incoming_dir, asset_dir = root .. "/no-such-dir" }
    local kept, none = Content.download_remote_images_to_files(new_client({ files = files }),
        '<img src="https://other.test/pic.png"/>', {}, broken_ws)
    expect(kept == '<img src="https://other.test/pic.png"/>' and #none == 0
            and read_file(workspace.incoming_dir .. "/remote-000001.bin") == nil,
        "an image that could not be committed was referenced or left behind")
end

-- ---------------------------------------------- chapter and book flows --

local function book_client(extra)
    local routes = {
        shard = shard_router({
            ["/web/book/chapter/e_0"] = { [1] = SHARDS.images[1], [2] = SHARDS.second },
            ["/web/book/chapter/e_1"] = { [1] = SHARDS.images[2], [2] = "" },
            ["/web/book/chapter/e_3"] = { [1] = SHARDS.images[3], [2] = "" },
            ["/web/book/chapter/e_2"] = SHARDS.plain_css,
        }),
        binary = {
            ["https://res.test/1.tar"] = tar_entry("pic.png", PNG .. "tar") .. TAR_END,
            ["https://img.test/r/remote.jpg"] = JPEG .. "remote",
        },
        files = {
            ["https://res.test/1.tar"] = tar_entry("pic.png", PNG .. "tar") .. TAR_END,
            ["https://img.test/r/remote.jpg"] = JPEG .. "remote",
        },
        catalog = function() return chapters_payload end,
    }
    for key, value in pairs(extra or {}) do routes[key] = value end
    return new_client(routes)
end
local CH1 = { chapterUid = 1, chapterIdx = 1, title = "One", tar = "https://res.test/1.tar", wordCount = 9 }
local CH2 = { chapterUid = 2, chapterIdx = 2, title = "Two", wordCount = 9 }

local saved = {}
local real_save_chapter, real_save_book = Content.save_chapter_epub, Content.save_book_epub
Content.save_chapter_epub = function(settings, book, chapter, xhtml, assets, css)
    saved[#saved + 1] = { kind = "chapter", chapter = chapter, xhtml = xhtml, assets = assets, css = css }
    return root .. "/chapter-" .. tostring(chapter.chapterUid) .. ".epub"
end
Content.save_book_epub = function(settings, book, chapters, bodies, suffix, assets, css)
    saved[#saved + 1] = { kind = "book", chapters = chapters, bodies = bodies, suffix = suffix,
        assets = assets, css = css }
    return root .. "/book-" .. suffix .. ".epub"
end

do
    -- Single chapter EPUB with images enabled.
    annotation_puts = {}
    local client = book_client()
    local book = { book_id = "B1" }
    local path, chapter = Content.fetch_chapter_epub(client, settings_with({ download_book_images = true }), book, CH1)
    local entry = saved[#saved]
    expect(path == root .. "/chapter-1.epub" and chapter == CH1, "chapter EPUB path was not returned")
    expect(entry.xhtml == '<p><img src="../images/pic.png"/><img src="../images/remote.jpg"/></p>',
        "chapter images were not rewritten to packaged assets: " .. entry.xhtml)
    expect(#entry.assets == 2 and entry.assets[1].data == PNG .. "tar" and entry.assets[2].data == JPEG .. "remote",
        "TAR and remote image assets were not both packaged")
    expect(entry.css == ".k{color:red}", "chapter css was not packaged")
    expect(book.cached_chapters["1"] == path and book.cached_file == path and book.chapter_uid == 1
            and book.chapter_idx == 1 and book.reader_url, "book record was not updated with the chapter file")
    expect(#annotation_puts == 1 and annotation_puts[1].source == "index:" .. TEXT.images,
        "EPUB chapter text was not indexed as the annotation source")

    -- Images disabled: no resource requests and the original sources stay.
    local plain_client = book_client()
    Content.fetch_chapter_epub(plain_client, settings_with({}), { book_id = "B1" }, CH1)
    expect(saved[#saved].xhtml == TEXT.images and #saved[#saved].assets == 0
            and plain_client:count("get_binary") == 0, "images were downloaded although disabled")

    -- A failing annotation cache must not fail the download.
    annotation_store_fails = true
    logs = {}
    local cache_client = book_client()
    Content.fetch_chapter_epub(cache_client, settings_with({}), { book_id = "B1" }, CH2)
    annotation_store_fails = false
    expect(saved[#saved].xhtml == TEXT.second, "annotation cache failure broke the chapter download")
    local logged = false
    for _, item in ipairs(logs) do if item.level == "warn" and has(item.text, "disk full") then logged = true end end
    expect(logged, "annotation cache failure was not logged")
end

do
    -- fetch_single_chapter_content: css fetched once per state, shared names.
    local client = book_client()
    local state = {}
    local settings = settings_with({ download_book_images = true })
    local xhtml, assets = Content.fetch_single_chapter_content(client, settings, { book_id = "B1" }, CH1, state)
    expect(xhtml == '<p><img src="../images/pic.png"/><img src="../images/remote.jpg"/></p>' and #assets == 2,
        "single chapter content lost its images")
    expect(state.css == ".k{color:red}" and state.used_asset_names["pic.png"], "chapter state was not populated")
    local again, again_assets = Content.fetch_single_chapter_content(client, settings, { book_id = "B1" }, CH1, state)
    expect(client:count("request", "/e_2") == 1, "css was fetched again for the same download state")
    expect(has(again, "../images/pic-2.png") and has(again, "../images/remote.jpg") and #again_assets == 1,
        "a second chapter in the same state reused TAR names or downloaded a known remote image again")
    local bare = Content.fetch_single_chapter_content(book_client(), settings_with({}), { book_id = "B1" }, CH2)
    expect(bare == TEXT.second, "single chapter content without images changed the text")

    -- source + finalize split, in memory and on disk.
    local split_client = book_client()
    local split_state = { image_progress = function() end }
    local source = Content.fetch_single_chapter_source(split_client, settings, { book_id = "B1" }, CH1, split_state)
    expect(source == TEXT.images and split_state.css == ".k{color:red}", "chapter source was not fetched")
    Content.fetch_single_chapter_source(split_client, settings, { book_id = "B1" }, CH2, split_state)
    expect(split_client:count("request", "/e_2") == 1, "css was refetched for the split download state")
    expect(Content.fetch_single_chapter_source(book_client(), settings, { book_id = "B1" }, CH2) == TEXT.second,
        "chapter source without state failed")
    local mem_xhtml, mem_assets = Content.finalize_single_chapter_content(split_client, settings, { book_id = "B1" },
        CH1, source, split_state)
    expect(mem_xhtml == '<p><img src="../images/pic.png"/><img src="../images/remote.jpg"/></p>'
            and #mem_assets == 2 and mem_assets[1].data, "in-memory chapter finalize lost its images")
    local disk_progress = {}
    local disk_state = { workspace = workspace, image_progress = function(i, n) disk_progress[#disk_progress + 1] = i .. "/" .. n end }
    local disk_client = book_client()
    local disk_xhtml, disk_assets = Content.finalize_single_chapter_content(disk_client, settings, { book_id = "B1" },
        CH1, source, disk_state)
    expect(disk_xhtml == '<p><img src="../images/pic.png"/><img src="../images/remote.jpg"/></p>'
            and #disk_assets == 2 and disk_assets[1].store and disk_assets[2].store
            and read_file(disk_assets[2].path) == JPEG .. "remote", "on-disk chapter finalize lost its images")
    expect(#disk_progress == 1 and disk_progress[1] == "1/1" and disk_client:count("get_binary") == 0,
        "on-disk finalize buffered images or skipped progress")
    local untouched, no_assets = Content.finalize_single_chapter_content(disk_client, settings_with({}),
        { book_id = "B1" }, CH1, source)
    expect(untouched == source and #no_assets == 0, "finalize without image download changed the chapter")
end

do
    -- Whole selection EPUB.
    local client = book_client()
    local events = {}
    local book = { book_id = "B1" }
    local path, selected = Content.fetch_chapters_epub(client, settings_with({ download_book_images = true }), book,
        { CH1, CH2 }, { suffix = "range", progress = function(i, n, chapter, phase)
            events[#events + 1] = i .. "/" .. n .. ":" .. tostring(chapter.chapterUid) .. ":" .. phase
        end })
    local entry = saved[#saved]
    expect(path == root .. "/book-range.epub" and #selected == 2 and entry.kind == "book",
        "book EPUB was not saved with the requested suffix")
    expect(table.concat(events, ",") == "1/2:1:text,1/2:1:images,2/2:2:text,2/2:2:images",
        "book download progress phases were wrong: " .. table.concat(events, ","))
    expect(entry.bodies["1"] == '<p><img src="../images/pic.png"/><img src="../images/remote.jpg"/></p>'
            and entry.bodies["2"] == TEXT.second and #entry.assets == 2 and entry.css == ".k{color:red}",
        "book bodies, assets or css were wrong")
    expect(client:count("request", "/e_2") == 1, "book css was fetched for every chapter")
    expect(book.cached_chapters["1"] == path and book.cached_chapters["2"] == path and book.cached_file == path
            and book.reader_url == "https://weread.qq.com/web/reader/B1k2",
        "book record does not point all chapters at the book file")
    local default_path = Content.fetch_chapters_epub(book_client(), settings_with({}), { book_id = "B1" }, { CH2 })
    expect(default_path == root .. "/book-book.epub" and #saved[#saved].assets == 0, "default book suffix was not used")
    expect_error(function() Content.fetch_chapters_epub(client, settings_with({}), { book_id = "B1" }, {}) end,
        "No readable chapter", "an empty selection produced a book")
    expect_error(function() Content.fetch_chapters_epub(client, settings_with({}), { book_id = "B1" }, nil) end,
        "No readable chapter", "a missing selection produced a book")
end

do
    -- First chapter: reader session, catalog cache miss, catalog fetch and save.
    local real_load, real_save = Content.load_catalog_cache, Content.save_catalog_cache
    local cache_saved
    Content.load_catalog_cache = function() return nil end
    Content.save_catalog_cache = function(_client, _settings, _book, chapters) cache_saved = chapters end
    local shard = shard_router({
        ["/web/book/chapter/e_0"] = SHARDS.second, ["/web/book/chapter/e_1"] = "",
        ["/web/book/chapter/e_3"] = "", ["/web/book/chapter/e_2"] = SHARDS.plain_css,
    })
    local client = book_client({ shard = shard })
    local book = { book_id = 42 }
    local path, chapter = Content.fetch_first_chapter(client, settings_with({}), book)
    expect(chapter.chapterUid == 3 and path == root .. "/chapter-3.epub", "first readable chapter was not downloaded")
    expect(cache_saved and #cache_saved == 2 and client:count("post_json") == 1,
        "a missing catalog cache was not fetched and saved")
    -- Known chapters skip the catalog entirely.
    local known = book_client({ shard = shard })
    Content.fetch_first_chapter(known, settings_with({}), { book_id = 42, chapters = { CH2 } })
    expect(known:count("post_json") == 0 and saved[#saved].chapter == CH2, "a known catalog was fetched again")
    -- Cached catalog with nothing readable.
    Content.load_catalog_cache = function() return { { chapterUid = 1, title = "封面", wordCount = 1 } } end
    expect_error(function() Content.fetch_first_chapter(book_client({ shard = shard }), settings_with({}), { book_id = 42 }) end,
        "No readable chapter", "a catalog without readable chapters produced a download")
    Content.load_catalog_cache, Content.save_catalog_cache = real_load, real_save
end

Content.save_chapter_epub, Content.save_book_epub = real_save_chapter, real_save_book
os.execute("rm -rf " .. string.format("%q", root))
print(("content_chapter_fetch_spec: %d checks"):format(checks))
