-- Changing the download directory: validating the chosen folder, offering to
-- move cached books (never over existing data, failures stay in place),
-- rewriting the stored paths, and importing matching folders found in the
-- new directory after a shelf lookup.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local MemoryFs = require("spec.helpers.memory_fs")
local fs = MemoryFs.new()
local restore_fs = fs:install()

local shown, scheduled = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function() end,
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        isWidgetShown = function() return false end,
    }
end
local function run_scheduled()
    while #scheduled > 0 do table.remove(scheduled, 1)() end
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) options.kind = "confirm" return options end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/pathchooser"] = function()
    return { new = function(_self, options) options.kind = "path" return options end }
end
local warnings = {}
package.preload["weread.lib.logger"] = function()
    local function warn(...)
        local parts = {}
        for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
        warnings[#warnings + 1] = table.concat(parts, " ")
    end
    return { info = function() end, warn = warn, err = warn, dbg = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d)", function(index) return tostring(values[tonumber(index)]) end))
        end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return fs:is_file(path) end,
    }
end
local collection = { removed = {}, added = {}, writes = 0, members = {} }
package.preload["readcollection"] = function()
    return {
        coll = nil,
        _read = function(self) self.coll = { weread = {} } end,
        removeItem = function(_self, path, name, no_write)
            collection.removed[#collection.removed + 1] = { path = path, name = name, no_write = no_write }
        end,
        isFileInCollection = function(_self, path) return collection.members[path] == true end,
        addItem = function(_self, path, name)
            collection.added[#collection.added + 1] = { path = path, name = name }
        end,
        write = function() collection.writes = collection.writes + 1 end,
    }
end

local Cache = require("weread.ui.cache")

local books = {}
local store = { api_key = "", cache = { download_mp_images = true } }
local flushes = 0
local settings = {
    cache_dir = "/mnt/old",
    default_cache_dir = "/mnt/old",
    get = function(_self, key, default)
        if store[key] == nil then return default end
        return store[key]
    end,
    set = function(_self, key, value) store[key] = value end,
    flush = function() flushes = flushes + 1 end,
    get_download_dir = function(self) return self.cache_dir end,
    set_download_dir = function(self, path) self.cache_dir = path end,
    is_api_configured = function() return store.api_key ~= "" end,
    get_book = function(_self, id) return books[tostring(id)] end,
    get_books = function() return books end,
    put_book = function(_self, id, book) books[tostring(id)] = book end,
    delete_book = function(_self, id) books[tostring(id)] = nil end,
}

local infos, busy, refreshes = {}, {}, {}
local online = true
local shelf_calls, shelf_result, shelf_error = 0, nil, nil
local host = {
    settings = settings,
    client = {
        get_shelf = function()
            shelf_calls = shelf_calls + 1
            if shelf_error then error(shelf_error, 0) end
            return shelf_result
        end,
    },
    showInfo = function(_self, text) infos[#infos + 1] = text end,
    showBusy = function(_self, text) busy[#busy + 1] = text end,
    closeBusy = function() busy[#busy + 1] = "closed" end,
    isNetworkConnected = function() return online end,
    runOnlineTask = function(_self, _label, callback) callback() end,
    refreshCacheManagement = function(_self, message) refreshes[#refreshes + 1] = message end,
}
for key, value in pairs(Cache) do
    if host[key] == nil then host[key] = value end
end

local function last_shown() return shown[#shown] end
local function last_info() return infos[#infos] end

-- 1. Validating a chosen directory.
local ok, err = host:validateDownloadDir("")
expect(not ok and err == "Invalid path.", "empty path accepted")
expect(not host:validateDownloadDir(nil), "nil path accepted")
fs:mkdir("/mnt/new")
ok = host:validateDownloadDir("/mnt/new")
expect(ok == true and not fs:exists("/mnt/new/.weread_write_test"), "writable directory rejected or probe left behind")
-- A missing directory is created with a quoted shell argument, so "$" and
-- quotes in the name are not interpreted by the shell.
local odd = "/mnt/us/it's $HOME `x`"
ok = host:validateDownloadDir(odd)
expect(ok == true and fs:exists(odd), "missing directory was not created")
expect(fs.commands[#fs.commands]:find("mkdir -p '", 1, true) == 1, "mkdir argument was not single-quoted")
fs.mkdir_fails["/mnt/nowhere"] = true
ok, err = host:validateDownloadDir("/mnt/nowhere")
expect(not ok and err:find("could not be created", 1, true), "uncreatable directory accepted")
fs:mkdir("/mnt/ro")
fs.readonly["/mnt/ro"] = true
ok, err = host:validateDownloadDir("/mnt/ro")
expect(not ok and err:find("not writable", 1, true), "read-only directory accepted")

-- 2. The picker refuses an unusable folder and keeps the setting.
local menu_updates = 0
local touchmenu = { updateItems = function() menu_updates = menu_updates + 1 end }
host:showDownloadDirPicker(touchmenu)
local chooser = last_shown()
expect(chooser.kind == "path" and chooser.select_directory and not chooser.select_file
        and chooser.path == "/mnt/old",
    "path chooser not opened on the current directory")
chooser.onConfirm("/mnt/ro")
expect(settings.cache_dir == "/mnt/old" and menu_updates == 0, "unusable directory was saved")
expect(last_info():find("Cannot use this directory", 1, true) and last_info():find("not writable", 1, true),
    "unusable directory was not explained")
-- Re-choosing the same folder just confirms it (no move offer, no scan
-- without an API key).
fs:mkdir("/mnt/old")
chooser.onConfirm("/mnt/old")
expect(menu_updates == 1 and last_info() == "Download directory set to:\n/mnt/old", "same directory not confirmed")
expect(shelf_calls == 0, "shelf was fetched without an API key")

-- 3. Changing to a new folder offers to move only cached books whose
-- directory exists elsewhere.
fs:file("/mnt/old/111/book.epub", 10)
fs:file("/mnt/old/111/7.epub", 5)
fs:file("/mnt/old/MP_WXS_9/a.html", 5)
fs:file("/mnt/old/444/book.epub", 10)
fs:file("/mnt/new/444/user-data.txt", 1)
fs:file("/mnt/old/555/book.epub", 10)
fs:file("/mnt/new/333/book.epub", 10)
books["111"] = { title = "One", cache_dir = "/mnt/old/111", cached_file = "/mnt/old/111/book.epub",
    cached_full_book = "/mnt/old/111/book.epub", cached_chapters = { [7] = "/mnt/old/111/7.epub" } }
books.MP_WXS_9 = { title = "MP", cache_dir = "/mnt/old/MP_WXS_9" }
books["222"] = { title = "Gone", cache_dir = "/mnt/old/222" }
books["333"] = { title = "Already there", cache_dir = "/mnt/new/333" }
books["444"] = { title = "Clash", cache_dir = "/mnt/old/444", cached_file = "/mnt/old/444/book.epub" }
books["555"] = { title = "Stuck", cache_dir = "/mnt/old/555", cached_file = "/mnt/old/555/book.epub" }
fs.mv_fails["/mnt/old/555"] = true

chooser.onConfirm("/mnt/new")
expect(settings.cache_dir == "/mnt/new" and menu_updates == 2, "new directory was not saved")
local offer = last_shown()
expect(offer.kind == "confirm" and offer.text:find("Move 4 cached book(s)", 1, true) and offer.ok_text == "Move",
    "move offer did not count the movable books: " .. tostring(offer.text))
-- Keeping the old location moves nothing.
local commands_before = #fs.commands
offer.cancel_callback()
expect(#fs.commands == commands_before and fs:exists("/mnt/old/111/book.epub"), "keeping files still moved them")
expect(last_info():find("Existing downloads stay in the old location.", 1, true), "keep choice not confirmed")

-- 4. Moving is refused while a download runs.
host.downloader = { _active_job = { prefetch = false } }
offer.ok_callback()
expect(#scheduled == 0 and fs:exists("/mnt/old/111/book.epub") and last_info():find("download is in progress", 1, true),
    "books were moved during a download")
host.downloader = nil

-- 5. Moving: successful books follow their files, an existing target is
-- never overwritten, a failed move stays in place.
offer.ok_callback()
expect(busy[#busy] == "Moving cached books..." and #scheduled == 1, "move did not show a busy message first")
local flushes_before = flushes
local warnings_mark = #warnings
run_scheduled()
expect(busy[#busy] == "closed", "busy message stayed open")
expect(fs:is_file("/mnt/new/111/book.epub") and fs:is_file("/mnt/new/111/7.epub")
        and not fs:exists("/mnt/old/111"),
    "book directory was not moved")
expect(fs:is_file("/mnt/new/MP_WXS_9/a.html"), "MP directory was not moved")
expect(fs:is_file("/mnt/new/444/user-data.txt") and not fs:exists("/mnt/new/444/book.epub")
        and fs:is_file("/mnt/old/444/book.epub"),
    "an existing target directory was overwritten or merged")
expect(fs:is_file("/mnt/old/555/book.epub"), "failed move lost the book")
local one = books["111"]
expect(one.cache_dir == "/mnt/new/111" and one.cached_file == "/mnt/new/111/book.epub"
        and one.cached_full_book == "/mnt/new/111/book.epub" and one.cached_chapters[7] == "/mnt/new/111/7.epub",
    "moved book paths were not rewritten")
expect(books.MP_WXS_9.cache_dir == "/mnt/new/MP_WXS_9", "MP book dir was not rewritten")
expect(books["444"].cache_dir == "/mnt/old/444" and books["555"].cached_file == "/mnt/old/555/book.epub",
    "records of books left behind were rewritten")
expect(#collection.removed == 1 and collection.removed[1].path == "/mnt/old/111/book.epub"
        and #collection.added == 1 and collection.added[1].path == "/mnt/new/111/book.epub"
        and collection.writes == 1,
    "collection entry did not follow the moved book")
expect(flushes > flushes_before, "moved records were not saved")
expect(last_info():find("Moved 2 book(s). 1 skipped", 1, true) and last_info():find("1 failed", 1, true),
    "partial move was not reported: " .. last_info())
local function logged_since(mark, needle)
    for index = mark + 1, #warnings do
        if warnings[index]:find(needle, 1, true) then return true end
    end
    return false
end
expect(logged_since(warnings_mark, "skip move, target exists: /mnt/new/444"), "skipped move was not logged")
expect(logged_since(warnings_mark, "move book cache failed: /mnt/old/555"), "failed move was not logged")

-- A clean move reports the destination, and no collection write happens
-- when no book file moved.
books = { MP_WXS_8 = { title = "MP8", cache_dir = "/mnt/new/MP_WXS_8" } }
fs:file("/mnt/new/MP_WXS_8/a.html", 1)
host:moveBooksToNewDir({ { book_id = "MP_WXS_8", src = "/mnt/new/MP_WXS_8", dst = "/mnt/x/MP_WXS_8" } }, "/mnt/x")
run_scheduled()
expect(last_info() == "Moved 1 book(s) to:\n/mnt/x" and collection.writes == 1,
    "clean move was not reported or rewrote the collection")

-- 6. Path helpers.
expect(host:moveBookDir("/a", "/a") == true, "moving onto itself failed")
local quoted_src = "/mnt/old/it's"
fs:file(quoted_src .. "/f.epub", 1)
expect(host:moveBookDir(quoted_src, "/mnt/q/it's") == true and fs:is_file("/mnt/q/it's/f.epub"),
    "a path with a quote was not moved")
expect(host:remapCachedPath(nil, "/d") == nil and host:remapCachedPath(5, "/d") == 5, "non-string path rewritten")
expect(host:remapCachedPath("/old/x/file.epub", "/d") == "/d/file.epub", "path not remapped")
expect(host:remapCachedPath("/old/x/", "/d") == "/old/x/", "directory path remapped to a bogus file")

-- 7. With nothing movable the new folder is confirmed directly.
books = {}
host:offerMoveBooksToNewDir("/mnt/old", "/mnt/new")
expect(last_info() == "Download directory set to:\n/mnt/new", "no-op move asked for confirmation")

-- 8. Importing folders found in the new directory needs an API key and a
-- network; without them the plain message is shown and nothing is fetched.
store.api_key = "key"
online = false
host:offerScanNewDir("/mnt/scan", "BASE")
expect(last_info() == "BASE" and shelf_calls == 0, "scan ran offline")
online = true

fs:file("/mnt/scan/900/book.epub", 100)
fs:file("/mnt/scan/901/new.epub", 100)
fs:file("/mnt/scan/unrelated/book.epub", 100)
fs:file("/mnt/scan/MP_WXS_5/a.html", 1)
books = { ["901"] = { title = "Stale", cache_dir = "/mnt/gone/901", cached_file = "/mnt/gone/901/old.epub" } }
shelf_result = { books = {
    { bookId = "900", title = "Nine Hundred", author = "Au" },
    { bookId = "901", title = "Nine-o-one" },
    { title = "no id" },
} }
host:offerScanNewDir("/mnt/scan", "BASE")
local import = last_shown()
expect(import.kind == "confirm" and import.text:find("Found 1 new and 1 outdated", 1, true),
    "import offer did not count new and outdated items: " .. tostring(import.text))
expect(books["900"] == nil and books["901"].cache_dir == "/mnt/gone/901", "dry run changed records")
-- Skipping keeps records as they were.
import.cancel_callback()
expect(last_info() == "BASE" and books["900"] == nil, "skipping still imported")
flushes_before = flushes
import.ok_callback()
expect(last_info() == "Imported 1 new and 1 updated item(s).", "import result not reported: " .. last_info())
expect(books["900"] and books["900"].cache_dir == "/mnt/scan/900" and books["900"].title == "Nine Hundred"
        and books["900"].author == "Au" and books["900"].cached_file == "/mnt/scan/900/book.epub",
    "new folder was not imported")
expect(books["901"].cache_dir == "/mnt/scan/901" and books["901"].cached_file == "/mnt/scan/901/new.epub",
    "stale record was not rebound")
expect(books.unrelated == nil and books.MP_WXS_5 == nil, "folder not on the shelf was imported")
expect(flushes > flushes_before, "import was not saved")
-- Nothing left to import: plain message.
host:offerScanNewDir("/mnt/scan", "BASE")
expect(last_info() == "BASE", "empty import still asked")
-- A failing shelf request falls back to the plain message.
shelf_error = "HTTP 500"
local warn_count = #warnings
host:offerScanNewDir("/mnt/scan", "BASE")
expect(last_info() == "BASE" and #warnings == warn_count + 1 and warnings[#warnings]:find("HTTP 500", 1, true),
    "shelf failure was not tolerated")

-- 9. Scanning from the cache page.
store.api_key = ""
local calls = shelf_calls
host:confirmScanLocalCache()
expect(last_info():find("requires the official API key", 1, true) and shelf_calls == calls,
    "scan without an API key reached the network")
store.api_key = "key"
host:confirmScanLocalCache()
expect(busy[#busy] == "closed" and last_info():find("Scan and match local books failed", 1, true)
        and last_info():find("HTTP 500", 1, true),
    "shelf failure during a scan was not shown")
shelf_error = nil
settings.cache_dir = "/mnt/scan"
books = {}
host:confirmScanLocalCache()
expect(busy[#busy - 1] == "Scanning local cache..." and busy[#busy] == "closed", "scan busy message missing")
expect(refreshes[#refreshes] == "Scan complete. 2 added, 0 updated.", "scan result wrong: " .. tostring(refreshes[#refreshes]))
expect(books["900"] and books["901"], "scan did not register matching folders")
-- A dry run never writes.
books = {}
local added, updated = host:scanLocalCache("/mnt/scan", host:fetchShelfAllowedMap(), true)
expect(added == 2 and updated == 0 and next(books) == nil, "dry-run scan wrote records")

-- 10. Shelf lookups tolerate malformed responses and sanitize ids.
shelf_result = nil
expect(next(host:fetchShelfAllowedMap()) == nil, "nil shelf produced entries")
shelf_result = { books = "oops" }
expect(next(host:fetchShelfAllowedMap()) == nil, "malformed shelf produced entries")
shelf_result = { books = { { bookId = "a/b", title = "Slash" } } }
local allowed = host:fetchShelfAllowedMap()
expect(allowed["a_b"] and allowed["a_b"].book_id == "a/b" and allowed["a/b"] == nil, "book id not sanitized")

-- 11. The MP image download switch is stored as a strict boolean.
flushes_before = flushes
host:setMPImageDownload("yes")
expect(store.cache.download_mp_images == false and flushes == flushes_before + 1, "truthy non-boolean enabled images")
host:setMPImageDownload(true)
expect(store.cache.download_mp_images == true, "image download was not enabled")

restore_fs()
print(("cache_ui_download_dir_spec: %d checks"):format(checks))
