-- Bookshelf controller flows in weread/ui/library.lua, run together with the
-- real network/login gating from weread/ui/common.lua: opening the shelf
-- offline, sync failures, overlapping refreshes, shelf search, sorting,
-- groups, store search and the small network actions. Opening the shelf
-- without network once froze the device, so every offline path here also
-- checks that nothing blocking or deferred is left behind.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

-- UIManager: shown widgets are recorded, deferred work is queued and only
-- runs when the spec drains it.
local shown, closed, close_counts, scheduled = {}, {}, {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function(_self, widget)
            if not widget then return end
            closed[widget] = true
            close_counts[widget] = (close_counts[widget] or 0) + 1
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

local net = { online = true, connected = true, online_checks = 0 }
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function()
            net.online_checks = net.online_checks + 1
            return net.online
        end,
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
package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/infomessage"] = widget_class("info")
package.preload["ui/widget/menu"] = widget_class("menu")
package.preload["ui/widget/confirmbox"] = widget_class("confirm", { movable = { {} } })
package.preload["ui/widget/inputdialog"] = widget_class("input", {
    getInputText = function(self) return self.text_value or self.input end,
})
package.preload["ui/widget/progressbardialog"] = widget_class("progress")
package.preload["ui/widget/textviewer"] = widget_class("textviewer")
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = function() return {} end
package.preload["weread.lib.content"] = function()
    return { load_catalog_cache = function() return nil end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(id) return tostring(id or ""):sub(1, 7) == "MP_WXS_" end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
        unpack_args = unpack,
    }
end
local cover_cache = {
    pathFor = function() return nil end,
    sourcePathFor = function() return nil end,
}
package.preload["weread.lib.cover_cache"] = function()
    return { new = function() return cover_cache end }
end

local views = {}
package.preload["weread.ui.library_view"] = function()
    return {
        getLayout = function() return { page_size = 10 } end,
        show = function(data, callbacks)
            local view = {
                data = data,
                callbacks = callbacks,
                page = data.page or 1,
                on_closed = callbacks.on_closed,
                setRefreshing = function(self, busy) self.refreshing = busy end,
                getScrollOffset = function() return { x = 0, y = 40 } end,
            }
            views[#views + 1] = view
            return view
        end,
    }
end

local Common = require("weread.ui.common")
local Library = require("weread.ui.library")

local function last_view() return views[#views] end
local function last_of(kind)
    for index = #shown, 1, -1 do
        if shown[index]._kind == kind then return shown[index] end
    end
end
local function last_message() local info = last_of("info") return info and info.text or "" end
local function has(text, needle) return type(text) == "string" and text:find(needle, 1, true) ~= nil end
local function titles(list)
    local result = {}
    for index, book in ipairs(list or {}) do result[index] = book.title end
    return table.concat(result, ",")
end

local records = {}
local store = { shelf = { sort_order = "default", paginated = true, view_mode = "list" } }
local login = { cookie = true, api = true }
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

local remote = {
    books = {
        { bookId = "1", title = "Alpha Story", author = "Ann", readUpdateTime = 30 },
        { bookId = "2", title = "Beta", author = "Zed Writer", readUpdateTime = 10 },
        { bookId = "CB_xyz", title = "Gamma", author = "Cy", readUpdateTime = 20 },
        { bookId = "MP_WXS_1", title = "Account News", author = "" },
    },
    archive = { { archiveId = 5, name = "Fav", bookIds = { "2" } } },
}
local client = { shelf_calls = 0, requests = {} }
function client.get_shelf()
    client.shelf_calls = client.shelf_calls + 1
    if client.shelf_error then error(client.shelf_error) end
    return { books = remote.books, archive = remote.archive }
end
local db = { cache_writes = 0 }
function db.getShelf() return db.shelf end
function db.getShelfArchives() return db.archives end
function db.cacheShelf(_self, books, archives)
    db.cache_writes = db.cache_writes + 1
    db.cached_books, db.cached_archives = books, archives
end

local qr_starts = 0
local host = {
    settings = settings,
    client = client,
    library_db = db,
    qr_login = { start = function() qr_starts = qr_starts + 1 end },
    bookMatchesFilters = function() return true end,
    isBookDownloaded = function() return false end,
    shelfSortSummary = function() return "sort" end,
    shelfFilterSummary = function() return "filter" end,
    showShelfSortOptions = function(_self, callback) callback() end,
    showShelfFilterOptions = function(_self, callback) callback() end,
}
for _, module in ipairs({ Library, Common }) do
    for key, value in pairs(module) do
        if host[key] == nil then host[key] = value end
    end
end

-- 1. First open without a cached shelf and without a login: no request,
-- no lock left behind, the QR login is offered.
db.shelf, db.archives = {}, nil
login.api = false
host:showBookshelf()
expect(#views == 0 and client.shelf_calls == 0, "logged-out shelf open started a sync")
expect(host.shelf_refreshing == nil, "logged-out shelf open left the refresh lock set")
expect(has(last_message(), "log in"), "logged-out shelf open did not ask for a login")
drain()
expect(qr_starts == 1, "logged-out shelf open did not start the QR login")

-- 2. Logged in but offline: the online check fails, the busy message is
-- closed, nothing is deferred and the lock is released at once.
login.api = true
net.online = false
host:showBookshelf()
local busy = last_of("info")
expect(#scheduled == 0, "offline shelf open queued deferred work")
expect(client.shelf_calls == 0 and #views == 0, "offline shelf open requested or showed a shelf")
expect(host.shelf_refreshing == nil, "offline shelf open stayed locked")
expect(host.busy_message == nil, "offline shelf open left the busy message up")
expect(has(busy.text, "Bookshelf failed") and has(busy.text, "No network connection"),
    "offline shelf open did not explain the missing network: " .. tostring(busy.text))
local busy_closed = false
for widget in pairs(closed) do
    if widget._kind == "info" and widget.dismissable == false then busy_closed = true end
end
expect(busy_closed, "offline shelf open never closed its busy message")

-- 3. Back online: the request runs deferred, off the caller's stack, and
-- the result is cached, split into books/public accounts and shown.
net.online = true
host:showBookshelf()
expect(host.shelf_refreshing == true and host.busy_message ~= nil and client.shelf_calls == 0,
    "online shelf open ran the request synchronously")
drain()
expect(client.shelf_calls == 1 and db.cache_writes == 1 and #db.cached_books == 4
        and db.cached_archives[1].archiveId == 5, "synced shelf was not cached")
expect(host.shelf_refreshing == nil and host.busy_message == nil, "sync did not release the lock")
local view = last_view()
expect(view and view.data.mode == "books" and titles(view.data.books) == "Alpha Story,Beta,Gamma",
    "synced shelf did not list the regular books")
expect(#view.data.accounts == 1 and view.data.accounts[1].bookId == "MP_WXS_1",
    "public-account entry was not separated from books")
expect(host.shelf_view == view, "synced shelf was not registered")

-- 4. A cached shelf opens without any online check or deferred work, even
-- offline and in cover mode (which only reads the link state).
db.shelf, db.archives = remote.books, remote.archive
net.online, net.connected, net.online_checks = false, false, 0
store.shelf.view_mode = "cover"
remote.books[1].cover = "https://cdn.example/alpha.jpg"
local views_before = #views
host:showBookshelf()
expect(#views == views_before + 1 and #scheduled == 0 and net.online_checks == 0,
    "cached offline shelf open ran a blocking online check or deferred work")
expect(client.shelf_calls == 1, "cached offline shelf open requested the shelf")
view = last_view()
expect(view.data.cover_mode == true and view.data.cover_loading[remote.books[1]] == false,
    "offline cover without a local source was shown as loading")
expect(#view.data.groups == 2 and view.data.groups[1].label == "Fav",
    "cached shelf lost its groups")
store.shelf.view_mode = "list"
remote.books[1].cover = nil
net.online, net.connected = true, true
host:showBookshelf()
view = last_view()

-- 5. Refresh while a sync is running: one request only, the view shows the
-- refreshing state until the result replaces it.
view.callbacks.on_refresh()
view.callbacks.on_refresh()
host:refreshBookshelf()
expect(#scheduled == 1 and view.refreshing == true, "overlapping refreshes were not coalesced")
drain()
expect(client.shelf_calls == 2, "overlapping refreshes sent more than one request")
expect(view.refreshing == false and closed[view] and last_view() ~= view,
    "finished refresh did not replace the refreshing view")
expect(last_view().data.scroll_offset.y == 40, "refresh lost the scroll position")
view = last_view()

-- 6. Sync failure: the old shelf and its cache stay, the message names the
-- error and the search fallback, and the next refresh works again.
client.shelf_error = "HTTP 500 Internal Server Error"
local writes_before, regular_before = db.cache_writes, host.shelf_regular
views_before = #views
view.callbacks.on_refresh()
drain()
local failure = last_message()
expect(has(failure, "Load bookshelf failed") and has(failure, "HTTP 500") and has(failure, "Search"),
    "sync failure message was not shown: " .. failure)
expect(#views == views_before and not closed[view] and view.refreshing == false,
    "failed sync replaced or kept locking the shelf")
expect(db.cache_writes == writes_before and host.shelf_regular == regular_before,
    "failed sync overwrote the cached shelf")
expect(host.shelf_refreshing == nil and host.busy_message == nil, "failed sync stayed locked")

-- Offline refresh from the open shelf: the refreshing state is cleared.
client.shelf_error = nil
net.online = false
view.callbacks.on_refresh()
expect(view.refreshing == false and host.shelf_refreshing == nil and #scheduled == 0,
    "offline refresh kept the shelf in the refreshing state")
expect(has(last_message(), "No network connection"), "offline refresh was silent")
net.online = true
view.callbacks.on_refresh()
drain()
expect(client.shelf_calls == 4 and last_view() ~= view, "refresh after a failure did not recover")
view = last_view()

-- 7. Shelf search: title, author and book id, case-insensitive; Search with
-- empty text and Clear both drop the keyword; pages restart at one.
host.shelf_view_pages.books = 3
view.callbacks.on_search()
local dialog = last_of("input")
expect(dialog.title == "Search shelf" and dialog.input == "", "shelf search dialog not shown")
dialog.text_value = "WRITER"
dialog.buttons[1][2].callback()
view = last_view()
expect(closed[dialog] and view.data.keyword == "WRITER" and titles(view.data.books) == "Beta",
    "shelf search did not match the author case-insensitively")
expect(host.shelf_view_pages.books == 1 and view.data.page == 1, "shelf search kept the old page")
view.callbacks.on_search()
dialog = last_of("input")
expect(dialog.input == "WRITER", "shelf search dialog lost the current keyword")
dialog.text_value = "cb_x"
dialog.buttons[1][2].callback()
view = last_view()
expect(titles(view.data.books) == "Gamma" and #view.data.accounts == 0,
    "shelf search did not match the book id")
view.callbacks.on_search()
dialog = last_of("input")
dialog.text_value = "news"
dialog.buttons[1][2].callback()
view = last_view()
expect(#view.data.books == 0 and #view.data.accounts == 1, "shelf search skipped public accounts")
view.callbacks.on_search()
dialog = last_of("input")
dialog.text_value = ""
dialog.buttons[1][2].callback()
view = last_view()
expect(view.data.keyword == nil and #view.data.books == 3, "empty shelf search kept a filter")
view.callbacks.on_search()
dialog = last_of("input")
dialog.text_value = "nothing matches"
dialog.buttons[1][1].callback()
view = last_view()
expect(closed[dialog] and view.data.keyword == nil and #view.data.books == 3,
    "clearing the shelf search did not show the whole shelf")

-- 8. Sorting copies the shelf and orders it; the cached snapshot keeps its
-- original order.
store.shelf.sort_order = "time_asc"
view.callbacks.on_sort()
view = last_view()
expect(titles(view.data.books) == "Beta,Gamma,Alpha Story", "time_asc sort order wrong")
store.shelf.sort_order = "name_desc"
view.callbacks.on_sort()
view = last_view()
expect(titles(view.data.books) == "Gamma,Beta,Alpha Story", "name_desc sort order wrong")
store.shelf.sort_order = "unknown"
view.callbacks.on_sort()
view = last_view()
expect(titles(view.data.books) == "Alpha Story,Beta,Gamma", "unknown sort order reordered books")
expect(titles(host.shelf_regular) == "Alpha Story,Beta,Gamma", "sorting mutated the shelf snapshot")
store.shelf.sort_order = "default"

-- 9. Groups: an unknown group is ignored, a group narrows books and the
-- search, nil returns to the whole shelf.
views_before = #views
view.callbacks.on_select_group("archive:404")
expect(#views == views_before and not closed[view], "unknown group re-rendered the shelf")
view.callbacks.on_select_group("archive:5")
view = last_view()
expect(view.data.group_label == "Fav" and titles(view.data.books) == "Beta" and view.data.page == 1,
    "group selection did not narrow the shelf")
view.callbacks.on_search()
dialog = last_of("input")
dialog.text_value = "alpha"
dialog.buttons[1][2].callback()
view = last_view()
expect(#view.data.books == 0 and view.data.group_key == "archive:5",
    "shelf search escaped the selected group")
view.callbacks.on_select_group(nil)
view = last_view()
expect(host.shelf_group_key == nil and view.data.group_label == nil,
    "clearing the group did not return to all books")

-- 10. Selecting entries routes books, public accounts and caller overrides.
local routed = {}
host.showBookRecord = function(_self, book) routed[#routed + 1] = "book:" .. book.bookId end
host.showMPAccount = function(_self, book) routed[#routed + 1] = "mp:" .. book.bookId end
view = last_view()
view.callbacks.on_select(remote.books[1], "books")
view.callbacks.on_select(remote.books[4], "public_account")
expect(routed[1] == "book:1" and routed[2] == "mp:MP_WXS_1", "shelf selection was misrouted")
local picked
host:showShelfView("books", nil, view, {
    on_select = function(book, mode, from_view) picked = { book, mode, from_view } end,
})
local picker = last_view()
picker.callbacks.on_select(remote.books[2], "books")
expect(picked and picked[1] == remote.books[2] and picked[3] == picker and #routed == 2,
    "custom shelf selection handler was bypassed")
host.showBookRecord, host.showMPAccount = Library.showBookRecord, Library.showMPAccount

-- 11. Closing releases each WeRead view once; an account switch drops the
-- search, group and page state.
local detail = { id = "detail" }
host._book_detail_view = detail
host.cache_menu = detail
host.shelf_view = picker
host.shelf_search_keyword = "x"
host:onWeReadAccountChanged()
expect(close_counts[detail] == 1 and closed[picker], "closing did not close each view exactly once")
expect(host.shelf_view == nil and host._book_detail_view == nil and host.cache_menu == nil,
    "closed views stayed referenced")
expect(host.shelf_regular == nil and host.shelf_mp == nil and host.shelf_search_keyword == nil
        and host.shelf_view_pages == nil, "account switch kept the previous account's shelf")

-- 12. Store search: login and network gating, results, selection, errors.
local search_results
function client.gateway(_self, path, params)
    client.requests[#client.requests + 1] = { path = path, params = params }
    if client.gateway_error then error(client.gateway_error) end
    return search_results
end
login.api = false
local shown_before = #shown
host:showSearch()
expect(last_of("input") == dialog and #shown == shown_before + 1, "store search opened without a login")
drain()
expect(qr_starts == 2, "store search without a login did not start the QR login")
login.api = true
host:showSearch()
dialog = last_of("input")
expect(dialog.title == "Search WeRead", "store search dialog not shown")
dialog.buttons[1][1].callback()
expect(closed[dialog] and #scheduled == 0, "cancelled store search ran a request")
host:searchWithUI("")
host:searchWithUI(nil)
expect(#scheduled == 0 and #client.requests == 0, "empty store search ran a request")
net.online = false
host:searchWithUI("three body")
expect(#scheduled == 0 and #client.requests == 0 and has(last_message(), "Search failed"),
    "offline store search did not fail fast")
net.online = true
search_results = { results = {
    { books = {
        { bookInfo = { bookId = "b1", title = "Three Body", author = "Liu", category = "SF" } },
        { bookId = "b2" },
    } },
    { books = {} },
} }
host:showSearch()
dialog = last_of("input")
dialog.text_value = "three body"
dialog.buttons[1][2].callback()
drain()
expect(client.requests[1].path == "/store/search" and client.requests[1].params.keyword == "three body"
        and client.requests[1].params.count == 10, "store search request malformed")
local menu = last_of("menu")
expect(menu and menu.title == "Search: three body" and #menu.item_table == 2,
    "store search results were not listed")
expect(menu.item_table[1].text == "Three Body" and menu.item_table[1].post_text == "Liu"
        and menu.item_table[1].mandatory == "SF" and menu.item_table[2].text == "b2",
    "store search rows lost title, author or category")
local opened_book
host.showBookRecord = function(_self, book) opened_book = book end
menu.item_table[1].callback()
expect(opened_book == search_results.results[1].books[1].bookInfo, "search result did not open its book")
host.showBookRecord = Library.showBookRecord
search_results = { results = {} }
host:searchWithUI("nothing")
drain()
expect(last_message() == "No search results.", "empty store search showed no notice")
client.gateway_error = "HTTP 502 Bad Gateway"
host:searchWithUI("broken")
drain()
expect(has(last_message(), "Search failed") and has(last_message(), "HTTP 502"),
    "store search failure was not reported")
client.gateway_error = nil

-- 13. Pull progress, reader URL parsing and the current-book shortcut.
function client.get_progress(_self, book_id)
    if book_id == "bad" then error("HTTP 401") end
    return { book = { progress = 37 } }
end
host:pullProgressWithUI("b1")
drain()
expect(last_message() == "Remote progress: 37%", "pulled progress was not shown")
host:pullProgressWithUI("bad")
drain()
expect(has(last_message(), "Pull progress failed") and has(last_message(), "HTTP 401"),
    "progress pull failure was not reported")

local html
function client.get_text(_self, url, options)
    client.requests[#client.requests + 1] = { url = url, referer = options.referer }
    return html
end
login.cookie = false
local request_count = #client.requests
host:parseReaderURLWithUI("https://weread.qq.com/web/reader/abc")
drain()
expect(#client.requests == request_count, "reader URL parsing ran without the cookie login")
login.cookie = true
html = [[{"bookId":"9001","title":"Parsed Book","psvts":"P1","pclts":"C1","token":"TK"}]]
host:parseReaderURLWithUI("https://weread.qq.com/web/reader/abc")
drain()
local parsed = records["9001"]
expect(parsed and parsed.title == "Parsed Book" and parsed.psvts == "P1" and parsed.pclts == "C1"
        and parsed.token == "TK" and parsed.reader_url == "https://weread.qq.com/web/reader/abc",
    "parsed reader URL was not stored")
expect(client.requests[#client.requests].referer == "https://weread.qq.com/web/reader/abc",
    "reader URL request lost its referer")
expect(has(last_message(), "Parsed Book") and has(last_message(), "9001"), "parse result not shown")
html = "<html>no data</html>"
host:parseReaderURLWithUI("https://weread.qq.com/web/reader/zzz")
drain()
expect(has(last_message(), "bookId was not found"), "missing bookId was not reported")

host:showPasteReaderURL()
dialog = last_of("input")
expect(dialog.input == "https://weread.qq.com/web/reader/", "reader URL dialog prefill missing")
html = [["bookId": 4242, "title":"Numeric"]]
dialog.text_value = "https://weread.qq.com/web/reader/num"
dialog.buttons[1][2].callback()
drain()
expect(closed[dialog] and records["4242"] and records["4242"].title == "Numeric",
    "pasted reader URL with a numeric bookId was not parsed")

host.detectWeReadBook = function() return nil end
host:showCurrentBookDetails()
expect(has(last_message(), "not a WeRead cached book"), "non-WeRead document was not reported")
records["7"] = { title = "Current" }
host.detectWeReadBook = function() return "7" end
host.showBookRecord = function(_self, book) opened_book = book end
host:showCurrentBookDetails()
expect(opened_book == records["7"] and opened_book.book_id == "7",
    "current book details did not open the stored record")

print(("library_shelf_sync_spec: %d checks"):format(checks))
