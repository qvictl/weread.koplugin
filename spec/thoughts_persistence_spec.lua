package.path = "./?.lua;./?/init.lua;" .. package.path

-- Chapter thought pipeline (weread.lib.thoughts): preference / cookie gating,
-- underline fetch, review fetch, HTML injection and the per-book thoughts.db
-- written through ThoughtDB on a real SQLite file.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local SQ = require("spec.helpers.ljsqlite3_ffi")
package.preload["lua-ljsqlite3/init"] = function() return { open = SQ.open } end
package.preload["libs/libkoreader-lfs"] = function() return SQ.lfs() end
package.preload["weread.lib.logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

local Thoughts = require("weread.lib.thoughts")
local ThoughtDB = require("weread.lib.thought_db")

local root = SQ.tempdir()
-- Settings creates the cache root at startup; book directories go one level below.
assert(SQ.lfs().mkdir(root .. "/cache"))

local function make_settings(opts)
    opts = opts or {}
    return {
        cache_dir = root .. "/cache",
        get = function(_self, key, default)
            if key == "cache" then
                return { download_underlines_and_thoughts = opts.enabled }
            end
            return default
        end,
        is_cookie_configured = function() return opts.cookie ~= false end,
    }
end

local function make_client(opts)
    local client = { underline_calls = {}, review_calls = {} }
    function client:get_chapter_underlines(book_id, chapter_uid)
        self.underline_calls[#self.underline_calls + 1] = { book_id, chapter_uid }
        if opts.underlines_error then return false, nil, opts.underlines_error end
        if opts.underlines == "not-a-table" then return true, "garbage" end
        return true, opts.underlines
    end
    function client:get_chapter_reviews(book_id, chapter_uid, ranges)
        self.review_calls[#self.review_calls + 1] = { book_id, chapter_uid, ranges }
        if opts.reviews_error then return false, nil end
        return true, opts.reviews
    end
    return client
end

local function stored_items(dir, chapter_uid, range)
    local db = ThoughtDB.open(dir)
    local items = ThoughtDB.getReviewItems(db, chapter_uid, range)
    ThoughtDB.close(db)
    return items
end

-- ── collect_ranges ──────────────────────────────────────────────────────────
expect(#Thoughts.collect_ranges(nil) == 0 and #Thoughts.collect_ranges("x") == 0,
    "non-table underline data must yield no ranges")
expect(#Thoughts.collect_ranges({}) == 0, "missing underlines list must yield no ranges")
local ranges = Thoughts.collect_ranges({ underlines = {
    { range = "3-8" }, { note = "no range" }, { range = "10-12" },
} })
expect(#ranges == 2 and ranges[1] == "3-8" and ranges[2] == "10-12",
    "ranges not collected in order / entries without range not skipped")

-- ── is_download_enabled ─────────────────────────────────────────────────────
expect(Thoughts.is_download_enabled(make_settings({ enabled = true })) == true, "enabled flag")
expect(Thoughts.is_download_enabled(make_settings({ enabled = false })) == false, "disabled flag")
expect(Thoughts.is_download_enabled(make_settings({})) == false, "missing flag must be disabled")
local truthy = make_settings({ enabled = "yes" })
expect(Thoughts.is_download_enabled(truthy) == false, "only boolean true enables downloads")

-- ── fetch_underlines ────────────────────────────────────────────────────────
local client = make_client({ underlines = { underlines = { { range = "3-8" } } } })
local ok, data, got_ranges, err = Thoughts.fetch_underlines(
    client, make_settings({ enabled = true, cookie = false }), "book", 7)
expect(ok == false and data == nil and #got_ranges == 0 and err == "cookie not configured",
    "missing cookie must fail before any request")
expect(#client.underline_calls == 0, "request sent without a cookie")

client = make_client({ underlines_error = "HTTP 500" })
ok, data, got_ranges, err = Thoughts.fetch_underlines(client, make_settings({ enabled = true }), "b", 7)
expect(ok == false and data == nil and #got_ranges == 0 and err == "HTTP 500",
    "client error not propagated")

client = make_client({ underlines = "not-a-table" })
ok, data, got_ranges, err = Thoughts.fetch_underlines(client, make_settings({ enabled = true }), "b", 7)
expect(ok == false and data == nil and #got_ranges == 0
    and tostring(err):find("no underline data", 1, true),
    "non-table underline payload must fail")

local payload = { underlines = { { range = "3-8" }, { range = "20-25" } } }
client = make_client({ underlines = payload })
ok, data, got_ranges = Thoughts.fetch_underlines(client, make_settings({ enabled = true }), "b", 7)
expect(ok and data == payload and data.chapterUid == 7, "chapter uid not stamped on the payload")
expect(#got_ranges == 2 and got_ranges[2] == "20-25", "ranges not returned")
expect(client.underline_calls[1][1] == "b" and client.underline_calls[1][2] == 7,
    "request arguments")

-- ── apply_data: HTML + thoughts.db ──────────────────────────────────────────
local settings = make_settings({ enabled = true })
local book_dir = root .. "/explicit-book"
local book = { cache_dir = book_dir }
local html = "<p>hello world</p>"
local underline_data = { underlines = { { range = "3-8" }, { range = "9-14" } } }
local reviews = {
    { range = "3-8", pageReviews = {
        { likesCount = 4, review = { content = "nice", author = { nick = "Ann" }, abstract = "hello" } },
    } },
}
local processed, css = Thoughts.apply_data(settings, "book-1", 11, html, underline_data, reviews, book)
expect(processed ~= html and processed:find("wr%-underline"), "underlines were not injected")
expect(processed:find("wr%-thought%-link"), "thought link was not injected")
expect(css:find(".wr-thought-link", 1, true), "thought CSS missing")
expect(underline_data.chapterUid == 11, "chapter uid not stamped before processing")
local items = stored_items(book_dir, 11, "3-8")
expect(#items == 1 and items[1].content == "nice" and items[1].author == "Ann"
    and items[1].abstract == "hello" and tonumber(items[1].likes_count) == 4,
    "thought not persisted to the book's thoughts.db")
expect(SQ.exists(book_dir .. "/thoughts.db"), "database not created in book.cache_dir")

-- A second chapter accumulates in the same database.
Thoughts.apply_data(settings, "book-1", 12, html, { underlines = { { range = "3-8" } } }, {
    { range = "3-8", pageReviews = { { review = { content = "second" } } } },
}, book)
expect(stored_items(book_dir, 12, "3-8")[1].content == "second", "second chapter not stored")
expect(#stored_items(book_dir, 11, "3-8") == 1, "second chapter clobbered the first")

-- No reviews and no rebuild: database untouched and HTML still underlined.
processed, css = Thoughts.apply_data(settings, "book-1", 11, html,
    { underlines = { { range = "3-8" } } }, nil, book)
expect(processed:find("wr%-underline") and not processed:find("wr%-thought%-link"),
    "underline-only chapter rendered a thought link")
expect(css ~= "" and not css:find(".wr-thought-link", 1, true), "underline-only CSS")
expect(#stored_items(book_dir, 11, "3-8") == 1, "nil reviews must not clear stored thoughts")

-- Rebuild: drops every chapter, then writes only the current one.
Thoughts.apply_data(settings, "book-1", 13, html, { underlines = { { range = "3-8" } } }, {
    { range = "3-8", pageReviews = { { review = { content = "rebuilt" } } } },
}, book, { rebuild_thought_db = true })
expect(stored_items(book_dir, 13, "3-8")[1].content == "rebuilt", "rebuild did not write")
expect(#stored_items(book_dir, 11, "3-8") == 0 and #stored_items(book_dir, 12, "3-8") == 0,
    "rebuild kept stale chapters")

-- Rebuild without reviews only deletes the database.
Thoughts.apply_data(settings, "book-1", 13, html, nil, nil, book, { rebuild_thought_db = true })
expect(not SQ.exists(book_dir .. "/thoughts.db"), "rebuild without reviews kept the database")

-- Non-table underline data: HTML unchanged, CSS empty, reviews still stored.
processed, css = Thoughts.apply_data(settings, "book-1", 14, html, "junk", {
    { range = "1-2", pageReviews = { { review = { content = "kept" } } } },
}, book)
expect(processed == html and css == "", "junk underline data changed the document")
expect(stored_items(book_dir, 14, "1-2")[1].content == "kept", "reviews dropped with junk underlines")

-- Directory resolution falls back to the stored cached_file location.
local file_dir = root .. "/from-cached-file"
Thoughts.apply_data(settings, "book-2", 1, html, {}, {
    { range = "1-2", pageReviews = { { review = { content = "file dir" } } } },
}, { cached_file = file_dir .. "/book.epub" })
expect(stored_items(file_dir, 1, "1-2")[1].content == "file dir",
    "thoughts.db not placed next to cached_file")

-- ── apply: gating ───────────────────────────────────────────────────────────
client = make_client({ underlines = payload })
local function apply_with(apply_settings, book_id, chapter_uid, xhtml)
    return Thoughts.apply(client, apply_settings, book_id, chapter_uid, xhtml)
end
for _, case in ipairs({
    { settings, "b", 1, nil, "nil xhtml" },
    { settings, "b", 1, "", "empty xhtml" },
    { make_settings({ enabled = false }), "b", 1, html, "disabled" },
    { make_settings({ enabled = true, cookie = false }), "b", 1, html, "no cookie" },
    { settings, nil, 1, html, "no book id" },
    { settings, "b", nil, html, "no chapter uid" },
}) do
    local out, out_css = apply_with(case[1], case[2], case[3], case[4])
    expect(out == case[4] and out_css == "", "apply did not short-circuit: " .. case[5])
end
expect(#client.underline_calls == 0 and #client.review_calls == 0,
    "gated apply sent requests")

-- Underline fetch failure: original HTML returned.
client = make_client({ underlines_error = "timeout" })
local out, out_css = Thoughts.apply(client, settings, "b", 1, html)
expect(out == html and out_css == "" and #client.review_calls == 0, "underline failure")

-- No underlines: no review request and nothing injected.
client = make_client({ underlines = { underlines = {} } })
out, out_css = Thoughts.apply(client, settings, "b", 1, html)
expect(out == html and out_css == "" and #client.review_calls == 0,
    "review request sent without ranges")

-- Review fetch failure or empty reviews: underlines still injected, no database.
for _, opts in ipairs({
    { reviews_error = true },
    { reviews = { reviews = {} } },
    { reviews = "bogus" },
}) do
    opts.underlines = { underlines = { { range = "3-8" } } }
    client = make_client(opts)
    out, out_css = Thoughts.apply(client, settings, "no-thoughts", 5, html)
    expect(#client.review_calls == 1 and client.review_calls[1][3][1] == "3-8",
        "reviews not requested for the collected ranges")
    expect(out:find("wr%-underline") and not out:find("wr%-thought%-link") and out_css ~= "",
        "underlines lost when reviews are unavailable")
end
expect(not SQ.exists(settings.cache_dir .. "/no-thoughts/thoughts.db"),
    "database created without reviews")

-- Full path: reviews persisted under settings.cache_dir/<sanitized book id>.
client = make_client({
    underlines = { underlines = { { range = "3-8" } } },
    reviews = { reviews = {
        { range = "3-8", pageReviews = { { review = { content = "online" } } } },
    } },
})
out, out_css = Thoughts.apply(client, settings, "book/9", 21, html)
expect(out:find("wr%-thought%-link") and out_css:find(".wr-thought-link", 1, true),
    "thought link not injected on the online path")
local online_dir = settings.cache_dir .. "/book_9"
expect(stored_items(online_dir, 21, "3-8")[1].content == "online",
    "online thoughts not persisted under the sanitized book directory")

-- ── merge_css ───────────────────────────────────────────────────────────────
expect(Thoughts.merge_css("base", nil) == "base" and Thoughts.merge_css("base", "") == "base",
    "empty annotation CSS must keep the base")
expect(Thoughts.merge_css(nil, nil) == nil, "nil base with no annotations")
expect(Thoughts.merge_css("base", "extra") == "base\nextra", "CSS not appended")
local merged = Thoughts.merge_css(nil, "extra")
expect(merged:find("line-height", 1, true) and merged:sub(-6) == "\nextra",
    "default base CSS not used")

SQ.rmtree(root)
print(("thoughts_persistence_spec: %d checks"):format(checks))
