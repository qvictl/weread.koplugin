package.path = "./?.lua;" .. package.path

local existing_paths = {}
local catalog_save_count = 0
local staged_id, committed_id, target_directory
local function empty_module() return {} end
package.preload["util"] = function() return { makePath = function(path) target_directory = path; return true end } end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
package.preload["ui/widget/confirmbox"] = empty_module
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = empty_module
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self, _delay, callback) callback() end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return existing_paths[path] == true end,
    }
end

local fetched_chapters = { { chapterUid = 7, title = "Cached chapter" } }
package.preload["weread.lib.content"] = function()
    return {
        book_resolved_dir = function(_settings, id, book) return book.cache_dir or "/cache/" .. tostring(id) end,
        create_download_workspace = function(_settings, book) return { path = "/stage/" .. tostring(book.book_id) } end,
        cleanup_download_workspace = function() return true end,
        commit_catalog_cache = function(_settings, book) committed_id = book.book_id; book.cache_dir = "/cache/" .. tostring(book.book_id) return true end,
        ensure_reader_state = function(_client, book)
            book.reader_url = "https://weread.qq.com/web/reader/synthetic"
            return { book_id = "42", psvts = "synthetic-session", token = "synthetic-token",
                current_chapter = { chapterUid = 7, chapterIdx = 1, chapterOffset = 20 },
                progress = { progress = 19 } }
        end,
        fetch_catalog = function() return fetched_chapters end,
        catalog_cache_path = function() return "/cache/42/catalog.json" end,
        save_catalog_cache = function(_client, _settings, staged)
            staged_id = staged.book_id
            catalog_save_count = catalog_save_count + 1
            return true
        end,
        load_catalog_cache = function() return nil end,
    }
end

local Library = require("weread.ui.library")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local books = {}
local db_detail
local written_book
local written_chapters
local db_chapters
local auto_refresh
local shown_book
local opened_path
local single_download_options
local single_download_refreshed = false
local host = {
    _runNetworkRequest = require("spec.helpers.immediate_network_request"),
    settings = require("spec.helpers.book_settings").install({
        get = function(_self, _key, default) return default end,
        flush = function() end,
    }, books),
    library_db = {
        accountKey = function() return "account-a" end,
        getBook = function() return db_detail end,
        putBook = function(_self, book) written_book = book return true end,
        getChapters = function() return db_chapters end,
        putChapters = function(_self, _book_id, chapters)
            written_chapters = chapters
            return true
        end,
    },
    refreshBookRecord = function(_self, book, _old, options)
        auto_refresh = options and options.automatic and book
    end,
    showBookMenu = function(_self, book) shown_book = book end,
    getFullBookCachePath = function(_self, book) return book.full_path end,
    openFile = function(_self, path) opened_path = path end,
    confirmAndDownloadChapters = function(_self, _book, _chapters, _suffix, options)
        single_download_options = options
    end,
    showInfo = function() end,
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback() return true end,
    showBusy = function() end,
    closeBusy = function() end,
    client = {},
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

host:showBookRecord({ bookId = "42", title = "First open" })
expect(auto_refresh and auto_refresh.book_id == "42",
    "first open without a detail snapshot did not auto-refresh")
expect(written_book and written_book.title == "First open",
    "first-open basic metadata was not written to SQLite")

auto_refresh, shown_book = nil, nil
db_detail = { book_id = "42", title = "Cached", detail_updated_at = 123 }
host:showBookRecord({ bookId = "42", title = "Shelf title" })
expect(shown_book and not auto_refresh,
    "cached detail unexpectedly triggered an automatic refresh")

local callback_chapters
local refreshed_book = { book_id = "42", title = "Catalog", pclts = "stale" }
host:loadChapters(refreshed_book, function(chapters)
    callback_chapters = chapters
end, true)
expect(written_chapters == fetched_chapters,
    "fetched chapter catalog was not written to SQLite")
expect(callback_chapters == fetched_chapters,
    "chapter callback did not receive the fetched catalog")
expect(refreshed_book.psvts == "synthetic-session" and refreshed_book.token == "synthetic-token"
        and refreshed_book.pclts == nil and refreshed_book.chapter_uid == 7
        and refreshed_book.chapter_offset == 20 and refreshed_book.progress == 19
        and refreshed_book.chapters == fetched_chapters and refreshed_book.reported_local == false,
    "catalog response did not apply the fresh reader session in the parent")

local url_only = { reader_url = "https://weread.qq.com/web/reader/synthetic" }
host:loadChapters(url_only, function(chapters) callback_chapters = chapters end, true)
expect(url_only.book_id == "42" and staged_id == "42" and committed_id == "42"
    and target_directory == "/cache/42" and callback_chapters == fetched_chapters,
    "reader-url-only input did not stage/publish under the resolved book ID")

db_chapters = { { chapterUid = 8, title = "Database chapter" } }
callback_chapters = nil
local db_book = { book_id = "42", title = "Database catalog" }
host:loadChapters(db_book, function(chapters)
    callback_chapters = chapters
end)
expect(callback_chapters == db_chapters and db_book.chapters == db_chapters,
    "SQLite chapter hit was not returned")
expect(catalog_save_count == 3,
    "SQLite chapter hit did not backfill missing catalog.json")

local partial = {
    book_id = "42",
    chapter_uid = 3,
    chapters = {
        { chapterUid = 1 }, { chapterUid = 2 }, { chapterUid = 3 },
        { chapterUid = 4 }, { chapterUid = 5 },
    },
    cached_chapters = { ["2"] = "/cache/2.epub", ["4"] = "/cache/4.epub" },
}
existing_paths["/cache/2.epub"] = true
existing_paths["/cache/4.epub"] = true
host:openBookForReading(partial)
expect(opened_path == "/cache/2.epub",
    "equal-distance cached chapter did not prefer the preceding chapter")

partial.chapter_uid = 4
host:openBookForReading(partial)
expect(opened_path == "/cache/4.epub",
    "exact cached progress chapter was not selected")

partial.full_path = "/cache/full.epub"
existing_paths[partial.full_path] = true
host:openBookForReading(partial)
expect(opened_path == partial.full_path,
    "complete cached book did not take priority over chapter caches")

host:downloadChapterAndRead(partial, partial.chapters[3], function()
    single_download_refreshed = true
end)
expect(single_download_options and single_download_options.single_chapter == true,
    "single chapter download keeps single-chapter mode")
single_download_options.on_complete(true, "/cache/3.epub")
expect(single_download_refreshed,
    "single chapter completion did not notify the chapter list")

print(("library_cache_flow_spec: %d checks"):format(checks))
