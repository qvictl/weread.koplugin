-- Book taps read and write only the tapped book's record, and only when it
-- changed. Works with both the per-book Settings API and the legacy
-- collection-wide get/set("books").

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function empty_module() return {} end
for _i, name in ipairs({
    "weread.lib.book_reviews", "weread.ui.book_reviews_view", "ui/widget/confirmbox",
    "weread.lib.content", "ui/widget/inputdialog", "ui/widget/progressbardialog",
    "ui/widget/textviewer", "ui/widget/buttondialog", "ui/widget/pathchooser",
    "weread.lib.scan",
}) do
    package.preload[name] = empty_module
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(id) return tostring(id):match("^MP_WXS_") ~= nil end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end, close = function() end,
        nextTick = function(_self, callback) callback() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
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

local BookRecords = require("weread.lib.book_records")
local Library = require("weread.ui.library")

-- Per-book settings: collection calls are forbidden, like upstream's API.
local function per_book_settings(records)
    local stats = { gets = 0, puts = 0, deletes = 0, flushes = 0 }
    local settings = {
        stats = stats,
        get = function(_self, key, default)
            assert(key ~= "books", "collection read of books")
            return default
        end,
        set = function(_self, key)
            assert(key ~= "books", "collection write of books")
        end,
        flush = function() stats.flushes = stats.flushes + 1 end,
        get_book = function(_self, id)
            stats.gets = stats.gets + 1
            local record = records[id]
            if not record then return nil end
            local copy = {}
            for key, value in pairs(record) do copy[key] = value end
            return copy
        end,
        get_books = function() return records end,
        put_book = function(_self, id, record)
            stats.puts = stats.puts + 1
            records[id] = record
        end,
        delete_book = function(_self, id)
            stats.deletes = stats.deletes + 1
            records[id] = nil
        end,
    }
    return settings
end

-- Legacy settings: only the collection calls exist.
local function legacy_settings(records)
    local stats = { reads = 0, writes = 0, flushes = 0 }
    return {
        stats = stats,
        get = function(_self, key, default)
            if key == "books" then
                stats.reads = stats.reads + 1
                return records
            end
            return default
        end,
        set = function(_self, key, value)
            if key == "books" then
                stats.writes = stats.writes + 1
                records = value
            end
        end,
        flush = function() stats.flushes = stats.flushes + 1 end,
        records = function() return records end,
    }
end

-- BookRecords helper, both layouts.
do
    local records = { a = { title = "A" } }
    local settings = per_book_settings(records)
    expect(BookRecords.get(settings, "a").title == "A", "per-book get")
    BookRecords.put(settings, "b", { title = "B" })
    expect(records.b.title == "B" and settings.stats.puts == 1, "per-book put")
    BookRecords.delete(settings, "a")
    expect(records.a == nil and settings.stats.deletes == 1, "per-book delete")
    BookRecords.put_many(settings, { c = { title = "C" } }, { "b" })
    expect(records.c and records.b == nil, "per-book put_many writes and deletes")

    local legacy = legacy_settings({ a = { title = "A" } })
    expect(BookRecords.get(legacy, "a").title == "A", "legacy get")
    BookRecords.put(legacy, "b", { title = "B" })
    expect(legacy.records().b.title == "B", "legacy put")
    BookRecords.delete(legacy, "a")
    expect(legacy.records().a == nil, "legacy delete")
    local writes = legacy.stats.writes
    BookRecords.put_many(legacy, { x = {}, y = {} })
    expect(legacy.stats.writes == writes + 1, "legacy put_many writes the collection once")
end

local function make_host(settings, db_book)
    local host = {
        settings = settings,
        shown_menus = {},
        library_db = {
            accountKey = function() return "acct" end,
            getBook = function() return db_book end,
            getChapters = function() return nil end,
            puts = 0,
            putBook = function(self) self.puts = self.puts + 1 end,
        },
        showBookMenu = function(self, book) self.shown_menus[#self.shown_menus + 1] = book end,
        refreshBookRecord = function(self, book) self:showBookMenu(book) end,
    }
    for key, value in pairs(Library) do
        if host[key] == nil then host[key] = value end
    end
    return host
end

-- First tap persists a new record once; repeat taps write nothing.
do
    local records = {}
    local settings = per_book_settings(records)
    local db_book = { bookId = "b1", title = "Title", intro = "Intro", detail_updated_at = 5 }
    local host = make_host(settings, db_book)
    local shelf_book = { bookId = "b1", title = "Title", _cached = true, author = "Au" }
    host:showBookRecord(shelf_book)
    expect(settings.stats.puts == 1 and settings.stats.flushes == 1,
        "new book was not persisted exactly once")
    expect(host.library_db.puts == 1, "new book was not cached in the library database")
    expect(records.b1 and records.b1._cached == nil, "transient shelf flag leaked into the record")
    host:showBookRecord(shelf_book)
    host:showBookRecord(shelf_book)
    expect(settings.stats.puts == 1 and settings.stats.flushes == 1,
        "re-opening an unchanged book rewrote its record")
    expect(host.library_db.puts == 1, "re-opening an unchanged book rewrote the library database")
    expect(#host.shown_menus == 3, "book detail was not shown on every tap")

    shelf_book.title = "Renamed"
    host:showBookRecord(shelf_book)
    expect(settings.stats.puts == 2 and records.b1.title == "Renamed",
        "a changed shelf entry was not persisted")
end

-- Legacy layout keeps working.
do
    local settings = legacy_settings({})
    local host = make_host(settings, { bookId = "b2", intro = "x" })
    host:showBookRecord({ bookId = "b2", title = "T" })
    expect(settings.records().b2 and settings.records().b2.title == "T", "legacy record not saved")
    local writes = settings.stats.writes
    host:showBookRecord({ bookId = "b2", title = "T" })
    expect(settings.stats.writes == writes, "legacy layout rewrote an unchanged book")
end

-- Public-account taps only write when the account record changes.
do
    local records = { MP_WXS_1 = { book_id = "MP_WXS_1", title = "Acc", mp_articles = { { title = "a" } } } }
    local settings = per_book_settings(records)
    local host = make_host(settings)
    local listed
    host.showMPArticleList = function(_self, _book, articles) listed = articles end
    host:showMPAccount({ bookId = "MP_WXS_1", title = "Acc" })
    expect(listed and #listed == 1, "cached articles were not shown")
    expect(settings.stats.puts == 0 and settings.stats.flushes == 0,
        "opening a known account rewrote its record")
    expect(settings.stats.gets == 1, "account tap read the record more than once")
end

print(("book_record_access_spec: %d checks"):format(checks))
