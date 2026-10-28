-- Book, chapter and public-account (mp) actions in weread/ui/library.lua,
-- run with the real login/network gating from weread/ui/common.lua:
-- record reuse across accounts, book-info refresh (logged out, offline,
-- failure, success), the detail page actions, reviews, mp article lists and
-- downloads, chapter catalog loading and offline reading fallbacks.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local shown, closed, scheduled = {}, {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function(_self, widget)
            if not widget then return end
            closed[widget] = true
            if widget.on_closed then widget.on_closed(widget) end
        end,
        isWidgetShown = function(_self, widget) return widget ~= nil and not closed[widget] end,
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
    }
end
local function drain()
    while #scheduled > 0 do table.remove(scheduled, 1)() end
end

local net = { online = true, connected = true }
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return net.online end,
        isConnected = function() return net.connected end,
    }
end

local function widget_class(kind, extra)
    return function()
        return {
            new = function(_self, data)
                data._kind = kind
                for key, value in pairs(extra or {}) do data[key] = value end
                return data
            end,
        }
    end
end
local progress_reports = {}
package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/infomessage"] = widget_class("info")
package.preload["ui/widget/menu"] = widget_class("menu")
package.preload["ui/widget/confirmbox"] = widget_class("confirm", { movable = { {} } })
package.preload["ui/widget/inputdialog"] = widget_class("input")
package.preload["ui/widget/textviewer"] = widget_class("textviewer")
package.preload["ui/widget/progressbardialog"] = widget_class("progress", {
    show = function(self) shown[#shown + 1] = self end,
    reportProgress = function(_self, value) progress_reports[#progress_reports + 1] = value end,
    close = function(self) closed[self] = true end,
})
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(id) return tostring(id or ""):sub(1, 7) == "MP_WXS_" end }
end
local files = {}
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return path ~= nil and files[path] == true end,
        unpack_args = unpack,
    }
end

local content = { saves = 0, save_ok = true, fetches = 0, mp_cached = {} }
package.preload["weread.lib.content"] = function()
    return {
        book_resolved_dir = function(_settings, id, book) return book.cache_dir or "/cache/" .. tostring(id) end,
        create_download_workspace = function(_settings, book) return { path = "/stage/" .. tostring(book.book_id) } end,
        cleanup_download_workspace = function() return true end,
        commit_catalog_cache = function(_settings, book) book.cache_dir = "/cache/" .. tostring(book.book_id) return true end,
        load_catalog_cache = function() return content.legacy end,
        catalog_cache_path = function(_settings, book)
            return "/catalog/" .. tostring(book.book_id or book.bookId) .. ".json"
        end,
        save_catalog_cache = function()
            content.saves = content.saves + 1
            if content.save_ok then return true end
            return false, "disk full"
        end,
        ensure_reader_state = function() return {} end,
        fetch_catalog = function()
            content.fetches = content.fetches + 1
            if content.fetch_error then error(content.fetch_error) end
            return content.remote_catalog
        end,
        parse_mp_articles = function(result) return result.articles end,
        mp_article_cached_path = function(_settings, _book, article) return content.mp_cached[article.id] end,
        fetch_mp_article_html = function(_client, _settings, book, article, options)
            if content.mp_error then error(content.mp_error) end
            for _, step in ipairs(content.mp_progress or {}) do options.progress(step, 3) end
            book.cache_dir = "/mp/" .. tostring(book.bookId)
            return "/mp/" .. tostring(article.id) .. ".html"
        end,
    }
end

local detail_pages, chapter_pages, review_pages = {}, {}, {}
local function page_stub(list)
    return function()
        return {
            show = function(data, callbacks)
                local view = { data = data, callbacks = callbacks, on_closed = callbacks.on_closed }
                list[#list + 1] = view
                return view
            end,
        }
    end
end
package.preload["weread.ui.book_detail_view"] = page_stub(detail_pages)
package.preload["weread.ui.chapter_list_view"] = page_stub(chapter_pages)
package.preload["weread.ui.book_reviews_view"] = page_stub(review_pages)

local Common = require("weread.ui.common")
local Library = require("weread.ui.library")

local function last_of(kind)
    for index = #shown, 1, -1 do
        if shown[index]._kind == kind then return shown[index] end
    end
end
local function last_message() local info = last_of("info") return info and info.text or "" end
-- Text of the latest info message shown after `mark` (#shown before the action).
local function message_since(mark)
    for index = #shown, mark + 1, -1 do
        if shown[index]._kind == "info" then return shown[index].text or "" end
    end
    return ""
end
local function has(text, needle) return type(text) == "string" and text:find(needle, 1, true) ~= nil end

local records = {}
local store = { cache = { download_mp_images = true } }
local login = { cookie = true, api = true }
local puts = 0
local settings = require("spec.helpers.book_settings").install({
    get = function(_self, key, default)
        if store[key] == nil then return default end
        return store[key]
    end,
    set = function(_self, key, value) store[key] = value end,
    flush = function() end,
    is_cookie_configured = function() return login.cookie end,
    is_api_configured = function() return login.api end,
}, records)
local raw_put = settings.put_book
settings.put_book = function(...) puts = puts + 1 return raw_put(...) end

local db = { details = {}, chapter_puts = 0, book_puts = {}, chapters = {} }
function db.accountKey() return db.account end
function db.getBook(_self, id) return db.details[id] end
function db.putBook(_self, book) db.book_puts[#db.book_puts + 1] = book return true end
function db.getChapters(_self, id) return db.chapters[id] end
function db.putChapters() db.chapter_puts = db.chapter_puts + 1 return true end
function db.countChapters() return 0 end

local client = { calls = {} }
local function record_call(name, ...) client.calls[#client.calls + 1] = { name, ... } end
local function calls_named(name)
    local count = 0
    for _, call in ipairs(client.calls) do if call[1] == name then count = count + 1 end end
    return count
end

local downloads, opened = {}, {}
local host = {
    settings = settings,
    client = client,
    library_db = db,
    qr_login = { start = function() end },
    ui = {
        openFile = function(_self, path) opened[#opened + 1] = path end,
        switchDocument = function(_self, path) opened[#opened + 1] = "switch:" .. path end,
    },
    downloader = {
        start = function(_self, book, chapters, suffix, options)
            downloads[#downloads + 1] = { book = book, chapters = chapters, suffix = suffix, options = options }
        end,
        promotePrefetch = function(_self, _book, chapter) return chapter.prefetching == true end,
    },
    getFullBookCachePath = function(_self, book) return book.full_path end,
    bookRecordHasDownload = function(_self, book) return book.has_download == true end,
}
for _, module in ipairs({ Library, Common }) do
    for key, value in pairs(module) do
        if host[key] == nil then host[key] = value end
    end
end
host._runNetworkRequest = require("spec.helpers.immediate_network_request")

local real = {}
for _, name in ipairs({ "showBookMenu", "showMPAccount", "refreshBookRecord", "openBookForReading" }) do
    real[name] = host[name]
end
local captured = {}
local function capture(name)
    host[name] = function(_self, ...) captured[#captured + 1] = { name, ... } end
end
local function restore() for name, fn in pairs(real) do host[name] = fn end captured = {} end

-- 1. Opening records: public accounts are routed, an id-less entry is
-- ignored, a record from another account keeps only its local cache.
capture("showMPAccount")
capture("showBookMenu")
capture("refreshBookRecord")
host:showBookRecord({ bookId = "MP_WXS_9", title = "Account" })
expect(captured[1][1] == "showMPAccount" and puts == 0, "public account opened as a book")
host:showBookRecord({ title = "No id" })
expect(#captured == 1 and puts == 0, "entry without an id was opened or stored")

db.account = "acct-new"
records["10"] = {
    title = "Old", progress = 55, private_note = "old account",
    cache_dir = "/books/10", cached_chapters = { ["1"] = "/books/10/1.epub" },
    _library_account_key = "acct-old",
}
db.details["10"] = { book_id = "10", intro = "Intro", detail_updated_at = 5,
    chapters = { { chapterUid = 1 } } }
host:showBookRecord({ bookId = "10", title = "New title", _cached = true })
local switched = records["10"]
expect(puts == 1 and switched.title == "New title" and switched.intro == "Intro",
    "book opened under a new account was not stored")
expect(switched.progress == nil and switched.private_note == nil,
    "previous account's record data leaked into the new account")
expect(switched.cache_dir == "/books/10" and switched.cached_chapters["1"] == "/books/10/1.epub",
    "account switch dropped the local cache paths")
expect(switched._library_account_key == "acct-new" and switched.chapters == nil and switched._cached == nil,
    "account key, stale catalog or transient flag handled wrongly")
expect(captured[2][1] == "showBookMenu", "book with cached details was refreshed instead of shown")

-- Nested values compare by content: an equal record is not rewritten, a
-- changed nested value is.
db.details["11"] = { publisher = "Pub" }
records["11"] = { book_id = "11", bookId = "11", title = "T", publisher = "Pub",
    tags = { "a", { "b" } }, _library_account_key = "acct-new", updated_at = 1 }
puts = 0
host:showBookRecord({ bookId = "11", title = "T", tags = { "a", { "b" } } })
expect(puts == 0 and captured[3][1] == "showBookMenu", "unchanged nested record was rewritten")
host:showBookRecord({ bookId = "11", title = "T", tags = { "a", { "c" } } })
expect(puts == 1 and records["11"].tags[2][1] == "c", "changed nested record was not stored")
restore()

-- 2. Book-info refresh: logged out and offline still show the page from
-- local data without any request; failures are reported.
capture("showBookMenu")
local book = { book_id = "20", title = "Refresh me" }
login.api = false
host:refreshBookRecord(book, nil, { automatic = true })
expect(#captured == 1 and #client.calls == 0, "logged-out refresh did not fall back to the page")
expect(has(last_message(), "log in"), "logged-out refresh did not ask for a login")
drain()
login.api = true
net.connected = false
host:refreshBookRecord(book, nil, { automatic = true })
expect(#captured == 2 and #client.calls == 0 and #scheduled == 0, "offline refresh blocked or requested")
expect(has(last_message(), "Book info failed") and has(last_message(), "No network"),
    "offline refresh did not explain the missing network")
host:refreshBookRecord(book)
expect(#captured == 2, "manual offline refresh re-opened the page")
net.connected = true
net.online, net.connected = false, false
host:refreshBookRecord(book, nil, { automatic = true })
expect(#captured == 3 and #scheduled == 0, "disconnected refresh did not fall back to the page")
net.online, net.connected = true, true

function client.get_book_info(_self, id)
    record_call("info", id)
    if client.info_error then error(client.info_error) end
    return { title = "Fresh", category = "Novel", intro = "New intro" }
end
function client.get_progress(_self, id)
    record_call("progress", id)
    return { book = { progress = 42, chapterUid = 77, chapterIdx = "5", chapterOffset = "120" } }
end
client.info_error = "HTTP 503 Service Unavailable"
host:refreshBookRecord(book, nil, { automatic = true })
drain()
expect(#captured == 4 and has(last_message(), "Book info failed") and has(last_message(), "HTTP 503"),
    "failed refresh was not reported or left no page")
expect(host.busy_message == nil and records["20"] == nil, "failed refresh left busy UI or stored data")
client.info_error = nil
host:refreshBookRecord(book, nil, { automatic = true })
drain()
expect(book.title == "Fresh" and book.categoryName == "Novel" and book.progress == 42
        and book.chapter_uid == 77 and book.chapter_idx == 5 and book.chapter_offset == 120,
    "refreshed info or cloud progress was not merged")
expect(book.reported_local == false and book.detail_updated_at and book._library_account_key == "acct-new",
    "refreshed record lost its provenance fields")
expect(records["20"] == book and db.book_puts[#db.book_puts] == book, "refreshed record not persisted")
expect(#captured == 5 and last_message() == "Book information updated.", "refresh did not re-show the page")
local old_page = { id = "old page" }
host:refreshBookRecord(book, old_page)
drain()
expect(closed[old_page] and #captured == 6, "refresh did not replace the open page")
local left_page = { id = "left page" }
closed[left_page] = true
book.title = "Stale"
host:refreshBookRecord(book, left_page)
drain()
expect(#captured == 6 and book.title == "Fresh", "refresh re-opened a page the user had left")
local original_info, cancel_notices = host.showInfo, 0
host.showInfo = function() cancel_notices = cancel_notices + 1 end
host.cancel_network_request = true
host:refreshBookRecord(book, old_page)
drain()
expect(#captured == 6 and cancel_notices == 0 and host.busy_message == nil,
    "manual refresh cancellation opened a new view, reported an error or kept busy state")
host:refreshBookRecord(book, nil, { automatic = true })
drain()
expect(#captured == 7 and captured[7][2] == book and cancel_notices == 0 and host.busy_message == nil,
    "automatic refresh cancellation did not show the cached book without an error")
host.network_cancel_reason = "account_changed"
host:refreshBookRecord(book, nil, { automatic = true })
drain()
expect(#captured == 7 and cancel_notices == 0 and host.busy_message == nil,
    "discarded account response reopened the previous account's cached book")
host.network_cancel_reason = nil
host.cancel_network_request, host.showInfo = false, original_info
restore()

-- 3. The detail page: legacy catalog import, status and metadata rows,
-- cache-clear, download-all, read, chapter list and reviews actions.
content.legacy = { { chapterUid = 1 }, { chapterUid = 2 }, { chapterUid = 3 } }
files["/b30/1.epub"] = true
local detail_book = {
    book_id = "30", title = "Detail", author = "Liu", translator = "Ken", progress = 12,
    publisher = "Press", publishTime = "2020-1-2", categoryName = "SF", wordCount = 123456,
    isbn = "978", newRating = 860, newRatingCount = 40, has_download = true,
    cached_chapters = { ["1"] = "/b30/1.epub", ["2"] = "/b30/missing.epub" },
}
local chapter_puts = db.chapter_puts
host:showBookMenu(detail_book)
local page = detail_pages[#detail_pages]
local data = page.data
expect(detail_book.chapters == content.legacy and db.chapter_puts == chapter_puts + 1,
    "legacy catalog was not imported into the database")
expect(data.author_line == "Liu  ·  Translated by Ken", "author line wrong: " .. data.author_line)
expect(data.status_line == "Progress 12%  ·  Cached 1/3 chapters", "status line wrong: " .. data.status_line)
expect(data.metadata[1].left == "Publisher: Press" and data.metadata[1].right == "Publication date: 2020-01-02"
        and data.metadata[2].text == "Category: SF" and data.metadata[3].text == "Word count: 12.3w words"
        and data.metadata[4].left == "ISBN: 978" and data.metadata[4].right == "Rating: 8.6 (40 ratings)",
    "detail metadata rows wrong")
expect(data.refresh_date == "Never updated" and data.bottom_actions[3].enabled == true
        and data.actions[1].text == "Clear book cache", "cache actions missing")
expect(host._book_detail_view == page, "detail page not tracked")

local clear_done
host.confirmClearBookCache = function(_self, id, title, done)
    expect(id == "30" and title == "Detail", "cache clear asked for the wrong book")
    clear_done = done
end
data.actions[1].callback()
clear_done()
expect(detail_book.cached_chapters == nil and detail_book.cached_full_book == nil
        and closed[page] and #detail_pages == 2, "cleared cache did not rebuild the page")
page = detail_pages[2]

page.data.bottom_actions[1].callback()
local confirm = last_of("confirm")
expect(confirm.text == "Download all 3 chapters as one EPUB?", "download-all confirmation wrong")
confirm.ok_callback()
expect(downloads[1].suffix == "full" and downloads[1].chapters == content.legacy
        and downloads[1].book == detail_book, "download-all did not start the full download")

capture("openBookForReading")
page.data.bottom_actions[3].callback()
capture("refreshBookRecord")
page.callbacks.on_refresh()
expect(captured[1][1] == "openBookForReading" and captured[2][1] == "refreshBookRecord"
        and captured[2][3] == page, "read or refresh action misrouted")
restore()

page.data.bottom_actions[2].callback()
local chapters_page = chapter_pages[#chapter_pages]
expect(chapters_page and #chapters_page.data.chapters == 3, "chapter list did not open")
chapters_page.callbacks.on_close()
expect(closed[page] and #detail_pages == 3, "closing the chapter list did not refresh the detail page")
local current_page = detail_pages[3]
closed[current_page] = true
chapters_page.callbacks.on_close()
expect(#detail_pages == 3, "chapter list close re-opened a detail page the user left")

files["/b31/full.epub"] = true
host:showBookMenu({ book_id = "31", title = "Full", full_path = "/b31/full.epub",
    chapters = { {}, {} }, detail_updated_at = 1 })
data = detail_pages[#detail_pages].data
expect(data.status_line == "Cached 2/2 chapters" and data.bottom_actions[3].enabled == false
        and #data.actions == 0 and #data.metadata == 0, "full-book page state wrong")

-- 4. Reviews: login gate, per-mode request, mode cache, detail, failure.
local review_payload = { reviews = {
    { review = { reviewId = "r1", author = { nick = "" }, content = "", star = 45,
        createTime = 1700000000, isFinish = 1 } },
} }
function client.get_book_reviews(_self, id, list_type, count)
    record_call("reviews", id, list_type, count)
    if client.reviews_error then error(client.reviews_error) end
    return review_payload
end
login.api = false
host:showBookReviews(detail_book)
drain()
expect(calls_named("reviews") == 0, "reviews loaded without a login")
login.api = true
host:showBookReviews(detail_book)
drain()
local last_call = client.calls[#client.calls]
expect(last_call[2] == "30" and last_call[3] == 1 and last_call[4] == 20, "recommended reviews request wrong")
local reviews = review_pages[#review_pages]
expect(reviews.data.mode == "recommended" and #reviews.data.result.items == 1, "reviews not shown")
reviews.callbacks.on_switch("latest")
drain()
expect(client.calls[#client.calls][3] == 3 and closed[reviews], "latest reviews request wrong")
review_pages[#review_pages].callbacks.on_switch("recommended")
expect(calls_named("reviews") == 2 and review_pages[#review_pages].data.mode == "recommended",
    "cached review mode was requested again")
review_pages[#review_pages].callbacks.on_select(reviews.data.result.items[1], "latest")
local viewer = last_of("textviewer")
expect(viewer.title == "Latest review" and has(viewer.text, "《Detail》") and has(viewer.text, "Anonymous")
        and has(viewer.text, "Score 4.5") and has(viewer.text, os.date("%Y-%m-%d", 1700000000))
        and has(viewer.text, "Finished") and has(viewer.text, "No review content."),
    "review detail text wrong: " .. tostring(viewer.text))
client.reviews_error = "HTTP 429"
host:showBookReviews(detail_book)
drain()
expect(has(last_message(), "Book reviews failed") and has(last_message(), "HTTP 429"),
    "review failure not reported")

-- 5. Public accounts: cached list without network, cookie gate, credential
-- renewal, rejections, error codes, article open/download.
local mp_result = { code = nil, error = nil, renew_ok = true }
local articles = {
    { id = "a1", title = "Cached post", createTime = 1700000000 },
    { id = "a2", title = "New post" },
}
function client.get_mp_articles(_self, id, offset, count, ticket)
    record_call("mp", id, offset, count, ticket)
    if mp_result.error then error(mp_result.error) end
    local queued = mp_result.queue and table.remove(mp_result.queue, 1)
    if queued then return nil, queued end
    if mp_result.code then return nil, mp_result.code end
    return { articles = articles }
end
function client.renew_cookie()
    record_call("renew")
    if not mp_result.renew_ok then error("renew failed") end
    return true
end
records["MP_WXS_1"] = { book_id = "MP_WXS_1", title = "News", author = "Ed",
    mp_articles = { { id = "a1", title = "Old" } } }
puts = 0
net.online = false
host:showMPAccount({ bookId = "MP_WXS_1", title = "News", author = "Ed" })
local list = last_of("menu")
expect(list.title == "News" and #list.item_table == 2 and puts == 0,
    "cached mp articles were not listed offline")
expect(calls_named("mp") == 0, "cached mp account requested articles")
net.online = true

login.cookie = false
host:showMPAccount({ bookId = "MP_WXS_2", title = "Fresh account" })
drain()
expect(puts == 1 and records["MP_WXS_2"].title == "Fresh account" and calls_named("mp") == 0,
    "new mp account without a cookie was requested or not remembered")
login.cookie = true

local account = { bookId = "MP_WXS_2", title = "Fresh account" }
store.wr_ticket = "TICKET"
mp_result.queue = { -2041 }
host:showMPAccount(account)
drain()
expect(calls_named("renew") == 1 and calls_named("mp") == 2 and client.calls[#client.calls][5] == "TICKET",
    "rejected mp credential was not renewed and retried with the ticket")
expect(records["MP_WXS_2"].mp_articles == articles and records["MP_WXS_2"].mp_articles_time,
    "fetched mp articles were not cached")
content.mp_cached.a1 = "/mp/a1.html"
host:showMPArticleList(account, articles)
list = last_of("menu")
expect(list.item_table[1].mandatory == "Cached" and list.item_table[1].post_text == os.date("%Y-%m-%d", 1700000000)
        and list.item_table[2].mandatory == "" and list.item_table[2].post_text == ""
        and list.item_table[3].text == "Refresh article list", "mp article rows wrong")

mp_result.queue, mp_result.renew_ok = { -2012 }, false
host:fetchMPArticles(account)
drain()
expect(calls_named("mp") == 3 and has(last_message(), "scan the QR code again"),
    "failed credential renewal was not reported")
mp_result.queue, mp_result.renew_ok = { -2041, -2041 }, true
local mark = #shown
host:fetchMPArticles(account)
drain()
expect(has(message_since(mark), "scan the QR code again"), "repeated mp rejection was not reported")
mp_result.code = -5
host:fetchMPArticles(account)
drain()
expect(has(last_message(), "errCode -5"), "mp error code was not reported")
mp_result.code, mp_result.error = nil, "socket timeout"
host:fetchMPArticles(account)
drain()
expect(has(last_message(), "Load articles failed") and has(last_message(), "socket timeout")
        and host.busy_message == nil, "mp request failure was not reported")
mp_result.error = nil
local mp_calls = calls_named("mp")
list.item_table[3].callback()
drain()
expect(calls_named("mp") == mp_calls + 1, "refresh row did not reload the articles")

list.item_table[1].callback()
expect(opened[#opened] == "/mp/a1.html", "cached article did not open")
content.mp_progress = { 1, 3 }
list.item_table[2].callback()
drain()
local bar = last_of("progress")
expect(bar and bar.progress_max == 3 and closed[bar] and progress_reports[1] == 1 and progress_reports[2] == 3,
    "article image progress was not shown and closed")
expect(opened[#opened] == "/mp/a2.html" and records["MP_WXS_2"].cache_dir == "/mp/MP_WXS_2",
    "downloaded article did not open or persist its directory")
content.mp_progress, content.mp_error = nil, "HTTP 404"
local opened_count = #opened
host:downloadMPArticleAndRead(account, articles[2])
drain()
expect(#opened == opened_count and has(last_message(), "Download failed") and has(last_message(), "HTTP 404")
        and host.busy_message == nil, "article download failure was not reported")
content.mp_error = nil
login.cookie = false
host:downloadMPArticleAndRead(account, articles[2])
expect(#scheduled == 1 and #opened == opened_count, "article download ran without the cookie login")
drain()
login.cookie = true

-- 6. Chapter catalogs: login gate, fetch failure, failed local backfill.
content.legacy = nil
local delivered
local function deliver(chapters) delivered = chapters end
login.cookie = false
host:loadChapters({ book_id = "40" }, deliver)
drain()
expect(delivered == nil and content.fetches == 0, "catalog was fetched without the cookie login")
login.cookie = true
content.fetch_error = "HTTP 500"
host:loadChapters({ book_id = "40" }, deliver)
drain()
expect(delivered == nil and has(last_message(), "Load chapters failed") and host.busy_message == nil,
    "catalog fetch failure was not reported")
content.fetch_error, content.save_ok = nil, false
content.remote_catalog = { { chapterUid = 1 } }
host:loadChapters({ book_id = "40" }, deliver, true)
drain()
expect(delivered == content.remote_catalog and records["40"], "failed catalog.json save blocked the catalog")
local known = { book_id = "41", chapters = { { chapterUid = 9 } } }
chapter_puts, delivered = db.chapter_puts, nil
host:loadChapters(known, deliver)
host:loadChapters(known, deliver)
expect(delivered == known.chapters and db.chapter_puts == chapter_puts + 1,
    "known catalog was written more than once")
db.chapters["42"] = { { chapterUid = 2 } }
host:loadChapters({ book_id = "42" }, deliver)
expect(delivered == db.chapters["42"], "database catalog was not used when the backfill failed")
content.save_ok = true
content.legacy = { { chapterUid = 3 } }
chapter_puts = db.chapter_puts
host:loadChapters({ book_id = "43" }, deliver)
expect(delivered == content.legacy and db.chapter_puts == chapter_puts + 1,
    "legacy catalog was not imported on load")
content.legacy = nil

-- 7. Offline reading fallbacks and opening files.
for _, path in ipairs({ "/r/1", "/r/2", "/r/4", "/r/a", "/r/b" }) do files[path] = true end
db.chapters["50"] = {
    { chapterUid = 1, chapterIdx = 1 }, { chapterUid = 2, chapterIdx = 2 },
    { chapterUid = 3, chapterIdx = 3 }, { chapterUid = 4, chapterIdx = 4 },
}
local reading = { book_id = "50", chapter_idx = 4, cached_chapters = { ["1"] = "/r/1", ["2"] = "/r/2" } }
expect(host:openBookForReading(reading) == true and opened[#opened] == "/r/2"
        and reading.chapters == db.chapters["50"], "chapter index target did not pick the nearest cache")
reading = { book_id = "50", progress = 100, cached_chapters = { ["1"] = "/r/1", ["4"] = "/r/4" } }
host:openBookForReading(reading)
expect(opened[#opened] == "/r/4", "progress target did not pick the last cached chapter")
local saved_db = host.library_db
host.library_db = nil
expect(host:openBookForReading({ book_id = "51", cached_chapters = { b = "/r/b", a = "/r/a" } })
        and opened[#opened] == "/r/a", "catalog-less fallback did not open the first cached chapter")
expect(host:openBookForReading({ book_id = "52" }) == false and last_message() == "No cached file.",
    "missing cache was not reported")
host.library_db = saved_db
mark = #shown
host:openFile("")
expect(message_since(mark) == "No cached file.", "empty path was opened")
host.ui.document = {}
host:openCachedBook({ full_path = "/b31/full.epub" })
expect(opened[#opened] == "switch:/b31/full.epub", "open document was not switched")
host.ui.document = nil

-- 8. Chapter opening and cloud-progress target chapters.
local chapter_book = { book_id = "60", cached_chapters = { ["1"] = "/r/1" } }
host:openChapter(chapter_book, { chapterUid = 1 })
expect(opened[#opened] == "/r/1", "cached chapter did not open")
local download_count, shown_count = #downloads, #shown
host:openChapter(chapter_book, { chapterUid = 2, prefetching = true })
expect(#downloads == download_count and #shown == shown_count, "promoted prefetch started another download")
local after_download
host:openChapter(chapter_book, { chapterUid = 3 }, function(path) after_download = path end)
confirm = last_of("confirm")
expect(confirm.text == "Download 1 selected chapter(s)?", "single chapter confirmation wrong")
confirm.ok_callback()
local started = downloads[#downloads]
expect(started.suffix == "chapter" and started.options.single_chapter and started.chapters[1].chapterUid == 3,
    "chapter download options wrong")
started.options.on_complete(false)
expect(after_download == nil, "failed chapter download notified the list")
started.options.on_complete(true, "/r/3")
expect(after_download == "/r/3", "chapter download did not notify the list")

local ok, reason = host:openProgressTargetChapter(nil, {})
expect(ok == false and reason == "target_chapter_unavailable", "invalid progress target accepted")
expect(host:openProgressTargetChapter(chapter_book, { chapterUid = 1 }) == true and opened[#opened] == "/r/1",
    "cached progress target did not open")
local cancelled = {}
host.progress_sync = { cancel_pending_jump = function(_self, why) cancelled[#cancelled + 1] = why end }
host:openProgressTargetChapter(chapter_book, { chapterUid = 8, title = "Eight" })
confirm = last_of("confirm")
expect(has(confirm.text, "Eight"), "progress target confirmation does not name the chapter")
confirm.ok_callback()
started = downloads[#downloads]
expect(closed[confirm] and started.options.open_on_complete and started.options.single_chapter,
    "progress target download does not open on completion")
started.options.on_complete(true)
started.options.on_complete(false, "network_error")
expect(#cancelled == 1 and cancelled[1] == "network_error", "failed target download kept the pending jump")
confirm.cancel_callback()
expect(cancelled[2] == "target_chapter_download_cancelled", "cancelling kept the pending jump")
host.progress_sync = nil
host:openProgressTargetChapter(chapter_book, { chapterId = 9 })
last_of("confirm").cancel_callback()

local old_mp_list, old_info = host.showMPArticleList, host.showInfo
local cancelled_mp_lists, cancelled_mp_notices = 0, 0
host.showMPArticleList = function() cancelled_mp_lists = cancelled_mp_lists + 1 end
host.showInfo = function() cancelled_mp_notices = cancelled_mp_notices + 1 end
host.cancel_network_request, login.cookie = true, true
host:fetchMPArticles({ book_id = "MP_WXS_1" })
drain()
expect(cancelled_mp_lists == 0 and cancelled_mp_notices == 0 and host.busy_message == nil,
    "cancelled article list opened UI, showed an error or kept busy state")
host.cancel_network_request = false
host.showMPArticleList, host.showInfo = old_mp_list, old_info

print(("library_book_actions_spec: %d checks"):format(checks))
