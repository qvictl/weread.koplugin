-- Public-account (MP) article path of weread/lib/content.lua: review parsing,
-- body extraction, reader-hostile style/blank-block cleanup, saved HTML, the
-- candidate/renew/source-url fetch fallbacks and image file handling.
-- Run with: luajit spec/content_mp_articles_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function has(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
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
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id) return "https://weread.qq.com/web/reader/" .. tostring(book_id) end,
        mp_reader_url = function(book_id) return "https://weread.qq.com/web/mp/" .. tostring(book_id) end,
    }
end

local Content = require("weread.lib.content")

local PNG = "\137PNG\r\n\026\n"

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

local function settings_with(cache)
    return {
        cache_dir = root,
        get = function(_self, key, default)
            if key == "cache" then return cache or default end
            return default
        end,
    }
end

local function last_warn()
    for index = #logs, 1, -1 do
        if logs[index].level == "warn" then return logs[index].text end
    end
end

-- ------------------------------------------------------ parse_mp_articles --

do
    local articles = Content.parse_mp_articles({ reviews = {
        { subReviews = {
            { reviewId = "S1", review = { reviewId = "R1", belongBookId = "MPB", createTime = 5,
                mpInfo = { originalId = "R1", title = "Nested", pic_url = "https://p/1",
                    content_url = "https://mp.weixin.qq.com/s/1", url = "ignored" } } },
            { reviewId = "S2", mpInfo = { originalId = "O2", title = "Flat", url = "https://u/2" } },
            { review = { reviewId = "R3", contentUrl = "https://c/3" } },
        } },
        { title = "group without sub reviews" },
    } })
    expect(#articles == 3, "every sub review must become one article")
    local first = articles[1]
    expect(first.reviewId == "R1" and table.concat(first.reviewIds, ",") == "S1,R1"
            and first.originalId == "R1" and first.bookId == "MPB" and first.createTime == 5,
        "nested review ids were not collected without duplicates")
    expect(first.sourceUrl == "https://mp.weixin.qq.com/s/1" and first.title == "Nested" and first.pic_url == "https://p/1",
        "the MP content URL was not preferred as source URL")
    local flat = articles[2]
    expect(flat.reviewId == "S2" and table.concat(flat.reviewIds, ",") == "S2,O2" and flat.sourceUrl == "https://u/2"
            and flat.bookId == "" and flat.createTime == 0, "a flat sub review was not parsed")
    local bare = articles[3]
    expect(bare.reviewId == "R3" and bare.sourceUrl == "https://c/3" and bare.title == "" and bare.originalId == ""
            and bare.pic_url == "", "a review without MP info did not get defaults")
    expect(#Content.parse_mp_articles({}) == 0, "an empty review payload must yield no articles")
end

-- ------------------------------------------------- extract / strip images --

do
    local body = Content.extract_mp_body('<html><div class="c" id="js_content" style="x"> <p>Hi</p>'
        .. '<script>evil()</script><style>.a{}</style><img data-src="https://mmbiz.qpic.cn/a" src=""/>'
        .. "<img data-src='https://mmbiz.qpic.cn/b' src=''/></div>\n<script>tail()</script>")
    expect(body == ' <p>Hi</p><img src="https://mmbiz.qpic.cn/a"/>' .. "<img src='https://mmbiz.qpic.cn/b'/>",
        "js_content body was not cleaned: " .. tostring(body))
    expect(Content.extract_mp_body('<div class="rich_media_content js_x" data-a="1"><p>R</p></div>\n<script>')
            == "<p>R</p>", "rich_media_content fallback was not used")
    expect(Content.extract_mp_body('<div id="js_content"><p>cut off') == "<p>cut off",
        "an unterminated js_content body was not accepted")
    expect(Content.extract_mp_body(nil) == nil and Content.extract_mp_body("") == nil
            and Content.extract_mp_body("<html>login</html>") == nil
            and Content.extract_mp_body('<div id="js_content"></div> <script>') == nil,
        "pages without article body must yield nil")

    local stripped = Content.strip_mp_images('<p>a<PICTURE media="x"><source srcset="x"><img src="y"></PICTURE>'
        .. 'b<IMG src="z"/></img><SOURCE src="s">c</p>')
    expect(stripped == "<p>abc</p>", "images were not stripped: " .. stripped)
    expect(Content.strip_mp_images(nil) == "", "nil html must strip to empty")
end

-- ------------------------------------------ article paths and cache lookup --

do
    local book = { book_id = "MPB", cache_dir = root }
    expect(Content.mp_article_path(nil, book, { title = 'A/B:  "C"?' }) == root .. '/A_B_ _C__.html',
        "unsafe title characters were not replaced in the article file name")
    expect(Content.mp_article_path(nil, book, {}) == root .. "/article.html", "untitled article path is wrong")
    expect(Content.mp_article_path(nil, book, { title = "  " }) == root .. "/weread.html",
        "blank title did not fall back to a safe file name")
    local settings = settings_with({})
    local unpinned = Content.mp_article_path(settings, { book_id = "B/1" }, { title = "T" })
    expect(unpinned == root .. "/B_1/T.html", "article of an unpinned book was not placed under the cache dir")

    local article = { title = "Cached" }
    expect(Content.mp_article_cached_path(settings, book, article) == nil, "a missing article was reported cached")
    write_file(root .. "/Cached.epub", "epub")
    expect(Content.mp_article_cached_path(settings, book, article) == root .. "/Cached.epub",
        "an EPUB copy of the article was not found")
    write_file(root .. "/Cached.html", "html")
    expect(Content.mp_article_cached_path(settings, book, article) == root .. "/Cached.html",
        "the HTML copy was not preferred over the EPUB copy")
end

-- ---------------------------------------------------- save_mp_article_html --

do
    local book = { book_id = "SaveBook" }
    local body = table.concat({
        '<p style="font-size: 20px; color: red; margin: 1em">Big</p>',
        '<span style="font-size:14px;font-family:serif">small</span>',
        "<h2 style='font-size: 14pt'>pt</h2><h3 style='font-size:12pt'>tiny pt</h3>",
        '<b style="font-size:1.5rem">rem</b><i style="font-size:1.2em">em</i><u style="font-size:1em">same</u>',
        '<s style="font-size:150%">pct</s><s style="font-size:100%">pct same</s>',
        '<q style="font-size: x-large">kw</q><q style="font-size: small">kw small</q>',
        '<em style="font-size: 20px !important">imp</em>',
        '<div style="Color: red; line-height: 2; opacity: .5; -webkit-text-fill-color: red; text-align: center; junk">c</div>',
        "<p> <br> </p><section>&nbsp;</section><span></span><div><p>\194\160</p></div>",
        '<mp-common-profile data-id="1">profile card</mp-common-profile>',
        "<p>a<br><br/>  <br /></p>\n\n\n\n<p>end</p>",
    })
    local path = Content.save_mp_article_html(settings_with({}), book, { title = "A & <B>" }, body)
    expect(path == root .. "/SaveBook/A & _B_.html" and book.cache_dir == root .. "/SaveBook",
        "article was not saved in the book directory or the directory was not pinned")
    local html = read_file(path)
    expect(html ~= nil, "article html was not written")
    local page = html
    html = page:match("<body>(.*)</body>") or ""
    expect(has(page, "<title>A &amp; &lt;B&gt;</title>") and has(html, "<h1>A &amp; &lt;B&gt;</h1>"),
        "article title was not escaped")
    expect(has(html, '<p style="font-size: 1.25em; margin: 1em">Big</p>'),
        "a heading-sized px font was not made relative or colors survived")
    expect(has(html, ">small</span>") and not has(html, "font-family") and not has(html, "14px"),
        "body-sized font or font family survived")
    expect(has(html, "<h2 style='font-size: 1.17em'>pt</h2>") and has(html, ">tiny pt</h3>")
            and not has(html, "12pt"), "pt sizes were not converted or filtered")
    expect(has(html, '<b style="font-size: 1.50em">rem</b><i style="font-size: 1.20em">em</i>')
            and has(html, ">same</u>") and not has(html, "1em\">same"), "rem/em sizes were not handled")
    expect(has(html, '<s style="font-size: 150%">pct</s>') and has(html, ">pct same</s>")
            and not has(html, "100%\">"), "percent sizes were not handled")
    expect(has(html, '<q style="font-size: x-large">kw</q>') and has(html, ">kw small</q>")
            and not has(html, "font-size: small"), "keyword sizes were not handled")
    expect(has(html, '<em style="font-size: 1.25em">imp</em>'), "!important heading size was not converted")
    expect(has(html, '<div style="text-align: center">c</div>'),
        "reader-hostile properties were not removed case-insensitively")
    expect(not has(html, "<section") and not has(html, "<span></span>") and not has(html, "<p> ")
            and not has(html, "&nbsp;") and not has(html, "profile card"), "blank blocks or profile cards survived")
    expect(has(html, "<p>a<br/></p>\n\n<p>end</p>"), "line breaks or blank lines were not collapsed")
    local _, style_count = page:gsub("color: #000 !important", "")
    expect(style_count == 1 and has(page, '<html lang="zh-CN">'), "the reader stylesheet was not embedded")
end

-- --------------------------------------------------------- fetch_mp_article --

local function mp_client(script)
    local client = { mp_calls = {}, renews = 0, public = {}, downloads = {} }
    function client:get_mp_content(review_id, opts)
        self.mp_calls[#self.mp_calls + 1] = { id = review_id, opts = opts, renewed = self.renews > 0 }
        return script.mp(review_id, self.renews > 0)
    end
    function client:renew_cookie()
        self.renews = self.renews + 1
        if script.renew_fails then error("renew failed") end
        return true
    end
    function client:get_public_text(url)
        self.public[#self.public + 1] = url
        if not script.public then error("HTTP 403") end
        return script.public(url)
    end
    function client:download_to_file(url, path, opts)
        self.downloads[#self.downloads + 1] = { url = url, opts = opts }
        local data = script.files and script.files[url]
        if not data then error("HTTP 404") end
        write_file(path, data)
        return path
    end
    function client:ids()
        local ids = {}
        for _, call in ipairs(self.mp_calls) do ids[#ids + 1] = call.id end
        return table.concat(ids, ",")
    end
    return client
end

local ARTICLE_HTML = '<div id="js_content"><p>Body text</p><img src="https://mmbiz.qpic.cn/x.png"/></div><script>'

do
    -- First candidate blank, second fails, third has the article.
    local client = mp_client({ mp = function(id)
        if id == "MP_WXS_123_abc" then return "   ", { length = 3 } end
        if id == "R2" then error("HTTP 500") end
        return ARTICLE_HTML, { length = #ARTICLE_HTML, content_type = "text/html" }
    end })
    local book = { book_id = "MPB", cache_dir = root }
    local article = { reviewId = "MP_WXS_123_abc", reviewIds = { "MP_WXS_123_abc", "R2" }, originalId = "O3",
        bookId = "", title = "First" }
    local path = Content.fetch_mp_article_html(client, settings_with({}), book, article)
    expect(client:ids() == "MP_WXS_123_abc,R2,O3", "candidates were not tried in order until one had content: "
        .. client:ids())
    expect(client.mp_calls[1].opts.referer == "https://weread.qq.com/web/mp/MPB"
            and not client.mp_calls[1].opts.skip_mp_auth_headers, "first round used a wrong referer or headers")
    expect(client.renews == 0 and #client.public == 0, "a successful candidate still renewed or used the source URL")
    local html = read_file(path)
    expect(path == root .. "/First.html" and has(html, "<p>Body text</p>") and not has(html, "<img"),
        "article was not saved with images stripped")

    -- Every candidate blank: renew the cookie, retry without MP auth headers.
    local renewed = mp_client({ mp = function(id, after_renew)
        if after_renew and id == "R9" then return ARTICLE_HTML end
        return ""
    end })
    local renewed_path = Content.fetch_mp_article_html(renewed, settings_with({}), book,
        { reviewId = "R9", bookId = "ARTB", title = "Renewed" })
    expect(renewed.renews == 1 and #renewed.mp_calls == 2 and renewed.mp_calls[2].opts.skip_mp_auth_headers == true,
        "an empty answer did not trigger exactly one cookie renewal and retry")
    expect(renewed.mp_calls[1].opts.referer == "https://weread.qq.com/web/mp/ARTB",
        "the article's own book id was not used for the referer")
    expect(has(read_file(renewed_path), "Body text"), "renewed article content was not saved")

    -- Renewal fails: fall back to the public mp.weixin.qq.com page.
    local public = mp_client({ renew_fails = true, mp = function() return nil end,
        public = function() return ARTICLE_HTML, { length = 1 } end })
    local public_path = Content.fetch_mp_article_html(public, settings_with({}), { book_id = "MPB", cache_dir = root },
        { reviewId = "R1", title = "Public", sourceUrl = "https://mp.weixin.qq.com/s/xyz" })
    expect(public.renews == 1 and #public.mp_calls == 1 and public.public[1] == "https://mp.weixin.qq.com/s/xyz",
        "a failed renewal must skip the retry and use the public source URL")
    expect(has(read_file(public_path), "Body text"), "public page article was not saved")
end

do
    -- Nothing anywhere: empty-response error with diagnostics in the log.
    logs = {}
    local client = mp_client({ mp = function() return " \n" end })
    local ok, err = pcall(Content.fetch_mp_article_html, client, settings_with({}), { book_id = "MPB", cache_dir = root },
        { reviewId = "R1", originalId = "O1", title = "Gone", sourceUrl = "https://example.com/post" })
    expect(not ok and has(tostring(err), "empty"), "an empty article response was not reported: " .. tostring(err))
    expect(#client.public == 0, "a non-MP source URL must not be fetched")
    local warn = last_warn() or ""
    expect(has(warn, "empty_response") and has(warn, "candidate_count= 2") and has(warn, "renew:ok")
            and has(warn, "renewed:2:2") and has(warn, "has_source_url= yes"),
        "empty response diagnostics are incomplete: " .. warn)
    expect(read_file(root .. "/Gone.html") == nil, "a failed article left an html file")

    -- Source URL also fails.
    logs = {}
    local failing = mp_client({ mp = function() error("socket") end })
    local ok2 = pcall(Content.fetch_mp_article_html, failing, settings_with({}), { book_id = "MPB", cache_dir = root },
        { reviewId = "R1", title = "Gone2", sourceUrl = "http://mp.weixin.qq.com/s/a" })
    local warn2 = last_warn() or ""
    expect(not ok2 and failing.public[1] == "http://mp.weixin.qq.com/s/a" and has(warn2, "1:error")
            and has(warn2, "source_url:error") and has(warn2, "empty_response"),
        "failed candidates and source URL were not recorded: " .. warn2)

    -- A page without article body (e.g. a login page) is a different failure.
    logs = {}
    local login = mp_client({ mp = function() return "<html>please log in</html>", { length = 26, content_type = "text/html" } end })
    local ok3 = pcall(Content.fetch_mp_article_html, login, settings_with({}), { book_id = "MPB", cache_dir = root },
        { reviewId = "R1", title = "Login" })
    local warn3 = last_warn() or ""
    expect(not ok3 and has(warn3, "missing_body") and has(warn3, "used_candidate= yes")
            and has(warn3, "content_type= text/html") and login.renews == 0,
        "a page without article body was not reported as missing body: " .. warn3)
end

do
    -- Images enabled: stored as files next to the article with progress.
    local client = mp_client({
        mp = function() return ARTICLE_HTML end,
        files = { ["https://mmbiz.qpic.cn/x.png"] = PNG .. "img" },
    })
    local progress = {}
    local path = Content.fetch_mp_article_html(client, settings_with({ download_mp_images = true }),
        { book_id = "MPB", cache_dir = root }, { reviewId = "R/7", title = "Pics" },
        { progress = function(i, n) progress[#progress + 1] = i .. "/" .. n end })
    local html = read_file(path)
    expect(has(html, 'src=".weread-mp-R_7-assets/img-0001.png"') and #progress == 1 and progress[1] == "1/1",
        "MP image was not stored next to the article")
    expect(read_file(root .. "/.weread-mp-R_7-assets/img-0001.png") == PNG .. "img", "MP image bytes are wrong")
end

do
    -- download_mp_images_to_files: rejected responses and commit failures keep
    -- the remote source and leave no partial files; asset dir name fallbacks.
    local client = mp_client({ mp = function() end, files = {
        ["https://mmbiz.qpic.cn/page"] = "<html>blocked</html>",
        ["https://mmbiz.qpic.cn/ok.png"] = PNG .. "ok",
    } })
    local book = { book_id = "BookKey", cache_dir = root }
    local body = '<img src="https://mmbiz.qpic.cn/page"/><img src="https://mmbiz.qpic.cn/page"/>'
        .. '<img src="https://mmbiz.qpic.cn/ok.png"/>'
    local asset_dir = root .. "/.weread-mp-BookKey-assets"
    -- Occupy the final name of the second image with a non-empty directory.
    assert(os.execute("mkdir -p " .. string.format("%q", asset_dir .. "/img-0002.png")))
    write_file(asset_dir .. "/img-0002.png/keep", "x")
    local out = Content.download_mp_images_to_files(client, nil, book, { title = "NoIds" }, body)
    expect(out == body, "rejected or uncommitted MP images must keep their remote sources: " .. out)
    expect(#client.downloads == 2, "a rejected MP image URL was downloaded again")
    expect(read_file(asset_dir .. "/img-0001.download") == nil and read_file(asset_dir .. "/img-0002.download") == nil
            and read_file(asset_dir .. "/img-0001.bin") == nil, "rejected MP image downloads left files behind")

    local by_title = Content.download_mp_images_to_files(client, nil, { cache_dir = root }, { title = "Only Title" },
        '<img src="https://mmbiz.qpic.cn/ok.png"/>')
    expect(by_title == '<img src=".weread-mp-Only_Title-assets/img-0001.png"/>',
        "asset directory did not fall back to the article title: " .. by_title)
    local by_original = Content.download_mp_images_to_files(client, nil, book, { originalId = "orig:1" },
        '<img src="https://mmbiz.qpic.cn/ok.png"/>')
    expect(by_original == '<img src=".weread-mp-orig_1-assets/img-0001.png"/>',
        "asset directory did not use the original id: " .. by_original)
    local untouched = Content.download_mp_images_to_files(client, nil, book, { reviewId = "r" }, nil)
    expect(untouched == "", "nil MP body must produce an empty body")
end

os.execute("rm -rf " .. string.format("%q", root))
print(("content_mp_articles_spec: %d checks"):format(checks))
