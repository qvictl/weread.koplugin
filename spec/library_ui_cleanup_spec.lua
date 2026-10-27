-- Regression coverage for full-screen WeRead views left in UIManager's stack.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local closed = {}
local closed_set = {}
package.preload["ui/uimanager"] = function()
    return {
        close = function(_self, view)
            closed[#closed + 1] = view
            closed_set[view] = true
        end,
        isWidgetShown = function(_self, view) return not closed_set[view] end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end

for _, name in ipairs({
    "ui/widget/buttondialog",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
    "ui/widget/inputdialog",
    "ui/widget/progressbardialog",
    "ui/widget/textviewer",
}) do
    package.preload[name] = function() return {} end
end
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
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end

local detail_view = { id = "detail" }
local chapter_view = { id = "chapters" }
local detail_callbacks, chapter_callbacks
package.preload["weread.ui.book_detail_view"] = function()
    return { show = function(_data, callbacks) detail_callbacks = callbacks return detail_view end }
end
package.preload["weread.ui.chapter_list_view"] = function()
    return { show = function(_data, callbacks) chapter_callbacks = callbacks return chapter_view end }
end

local Library = require("weread.ui.library")
local books = {}
local opened
local host = {
    settings = require("spec.helpers.book_settings").install({
        get = function(_self, _key, default) return default end,
    }, books),
    ui = {
        openFile = function(_self, path) opened = path end,
    },
    getFullBookCachePath = function() return "/missing.epub" end,
    bookRecordHasDownload = function() return false end,
    safeCallback = function(_self, _label, callback) return callback end,
    showInfo = function() end,
    loadChapters = function(_self, _book, callback)
        callback({ { chapterUid = 1, title = "One", wordCount = 10 } })
    end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

local book = { book_id = "book", title = "Book", chapters = {} }
host:showBookMenu(book)
expect(host._book_detail_view == detail_view,
    "book detail view was not tracked")

host:showChapterList(book)
expect(host._chapter_list_view == chapter_view,
    "chapter list view was not tracked")

local shelf_view = { id = "shelf" }
host.shelf_view = shelf_view
-- Windows without a plugin field (list menus, reviews, statistics) are
-- registered when shown and closed as well, newest first.
local WindowRegistry = require("weread.ui.window_registry")
local search_menu = { id = "search" }
host.showList = function() return search_menu end
expect(host:showTrackedList("Search", { {} }) == search_menu, "tracked list did not return its menu")
local reviews_view = WindowRegistry.track({ id = "reviews" })
local user_closed = WindowRegistry.track({ id = "closed by user" })
closed_set[user_closed] = true
host:openFile("/cache/book.epub")
expect(opened == "/cache/book.epub", "document was not opened")
expect(#closed == 5
        and closed[1] == chapter_view
        and closed[2] == detail_view
        and closed[3] == shelf_view
        and closed[4] == reviews_view
        and closed[5] == search_menu,
    "WeRead views were not all closed from topmost to bottommost")
expect(host._chapter_list_view == nil
        and host._book_detail_view == nil
        and host.shelf_view == nil,
    "closed WeRead view references were retained")

closed = {}
closed_set = {}
host.shelf_view = shelf_view
host:openFile(nil)
expect(#closed == 0 and host.shelf_view == shelf_view,
    "invalid open request unexpectedly closed the bookshelf")

-- Closing a view releases the plugin's reference to it.
closed, closed_set = {}, {}
host:showBookMenu(book)
host:showChapterList(book)
chapter_callbacks.on_closed(chapter_view)
detail_callbacks.on_closed(detail_view)
expect(host._chapter_list_view == nil and host._book_detail_view == nil,
    "closed views stayed referenced by the plugin")

-- A scan started from the settings menu reports its result without
-- opening the cache management page; an open page is rebuilt.
package.preload["ui/widget/pathchooser"] = function() return {} end
package.preload["weread.lib.scan"] = function() return {} end
host.refreshCacheManagement = require("weread.ui.cache").refreshCacheManagement
local cache_pages, messages = 0, {}
host.showCacheManagement = function(self)
    cache_pages = cache_pages + 1
    self.cache_menu = { id = "cache page " .. cache_pages }
end
host.showTransientInfo = function(_self, text) messages[#messages + 1] = text end
host:refreshCacheManagement("Scan complete")
expect(cache_pages == 0 and messages[1] == "Scan complete",
    "scan result opened a cache page the user never opened")
host:showCacheManagement()
host:refreshCacheManagement("Cache cleared")
expect(cache_pages == 2 and closed[#closed].id == "cache page 1",
    "open cache page was not rebuilt")
closed_set[host.cache_menu] = true
host:refreshCacheManagement("Cache cleared")
expect(cache_pages == 2 and host.cache_menu == nil, "closed cache page was reopened")

print(("library_ui_cleanup_spec: %d checks"):format(checks))
