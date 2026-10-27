-- Opening a book page or chapter list must not decode or rewrite a large
-- catalog that the library database already holds.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function empty_module() return {} end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
for _i, name in ipairs({
    "weread.ui.book_reviews_view", "ui/widget/confirmbox",
    "ui/widget/inputdialog", "ui/widget/progressbardialog", "ui/widget/textviewer",
}) do
    package.preload[name] = empty_module
end
package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function() return nil end,
        load_catalog_cache = function() return nil end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end, close = function() end,
        nextTick = function(_self, callback) callback() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
        isWidgetShown = function(_self, widget) return not widget.closed end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end
local detail_data
package.preload["weread.ui.book_detail_view"] = function()
    return { show = function(data) detail_data = data return {} end }
end
local catalog_views, list_views = {}, {}
package.preload["weread.ui.chapter_list_view"] = function()
    return { show = function(data, callbacks)
        catalog_views[#catalog_views + 1] = data
        local view = { page = 1, callbacks = callbacks, updates = 0 }
        function view:setChapters(rows) self.updates = self.updates + 1 self.rows = rows end
        list_views[#list_views + 1] = view
        return view
    end }
end

local Library = require("weread.ui.library")

local catalog = {}
for index = 1, 811 do catalog[index] = { chapterUid = index, title = "C" .. index } end

local db = {
    puts = 0, gets = 0, counts = 0,
    putChapters = function(self) self.puts = self.puts + 1 return true end,
    getChapters = function(self)
        self.gets = self.gets + 1
        local copy = {}
        for index, chapter in ipairs(catalog) do copy[index] = chapter end
        return copy
    end,
    countChapters = function(self) self.counts = self.counts + 1 return #catalog end,
    putBook = function() return true end,
}

local host = {
    settings = {
        get = function(_self, _key, default) return default end,
        get_book = function() return nil end,
        put_book = function() end,
        flush = function() end,
    },
    library_db = db,
    safeCallback = function(_self, _label, callback) return callback end,
    getFullBookCachePath = function() return nil end,
    bookRecordHasDownload = function() return false end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

-- The book page shows the chapter count without decoding the catalog.
local book = { bookId = "long", title = "Long" }
host:showBookMenu(book)
expect(db.counts == 1 and db.gets == 0, "book page decoded the catalog to count it")
expect(detail_data.status_line:find("0/811", 1, true) ~= nil,
    "book page lost the chapter count: " .. tostring(detail_data.status_line))
expect(book.chapters == nil, "book page attached a catalog it did not need")

-- Opening the chapter list loads the catalog once and never rewrites it.
host:showChapterList(book)
host:showChapterList(book)
expect(db.gets == 1, "chapter list decoded the catalog again on reopen")
expect(db.puts == 0, "chapter list rewrote a catalog read from the database")
expect(#catalog_views == 2 and #catalog_views[2].chapters == 811, "chapter list did not show the catalog")

-- A catalog that did not come from the database is stored once.
local fresh = { bookId = "fresh", chapters = { { chapterUid = 1 }, { chapterUid = 2 } } }
host:loadChapters(fresh, function() end)
host:loadChapters(fresh, function() end)
expect(db.puts == 1, "an unchanged catalog was stored on every open")

-- The chapter list opens on the page of the current reading chapter.
book.chapter_uid = 700
catalog_views = {}
host:showChapterList(book)
expect(catalog_views[1].focus_index == 700, "chapter list did not focus the reading chapter")

-- A finished download refreshes the list in place while it is shown, and
-- leaves the user alone once they left it.
local downloaded
host.openChapter = function(_self, _book, _chapter, on_downloaded) downloaded = on_downloaded end
local view = list_views[#list_views]
local shown_before = #catalog_views
view.callbacks.on_select(catalog[1])
downloaded()
expect(view.updates == 1 and #catalog_views == shown_before,
    "download completion re-showed the list instead of updating it")
view.closed = true
downloaded()
expect(view.updates == 1 and #catalog_views == shown_before,
    "download completion touched or re-opened a closed chapter list")

print(("catalog_persistence_spec: %d checks"):format(checks))
