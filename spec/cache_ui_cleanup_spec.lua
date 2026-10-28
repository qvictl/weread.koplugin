-- Cache management page: sizes listed per book, confirm dialogs, which
-- directories each cleanup deletes (and that nothing outside per-book
-- directories is touched), refusal while a download runs, annotation data
-- cleanup, and failures while deleting.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local MemoryFs = require("spec.helpers.memory_fs")
local fs = MemoryFs.new()
local restore_fs = fs:install()

-- UIManager: dialogs are recorded, scheduled callbacks run on demand.
local shown, scheduled, closed = {}, {}, {}
local visible = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function(_self, widget) closed[#closed + 1] = widget visible[widget] = nil end,
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
        isWidgetShown = function(_self, widget) return visible[widget] == true end,
    }
end
local function run_scheduled()
    local count = 0
    while #scheduled > 0 do
        table.remove(scheduled, 1)()
        count = count + 1
    end
    return count
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) options.kind = "confirm" return options end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_self, options) options.kind = "buttons" return options end }
end
package.preload["ui/widget/pathchooser"] = function()
    return { new = function(_self, options) options.kind = "path" return options end }
end
-- A clock that advances 0.3 s per read: every book exceeds the 0.25 s slice.
local clock = 0
package.preload["ui/time"] = function()
    return {
        now = function() clock = clock + 0.3 return clock end,
        to_s = function(value) return value end,
    }
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

-- KOReader's collection: removals are recorded per path.
local collection = { removed = {}, writes = 0, reads = 0 }
package.preload["readcollection"] = function()
    return {
        coll = nil,
        _read = function(self) collection.reads = collection.reads + 1 self.coll = { weread = {} } end,
        removeItem = function(_self, path, name, no_write)
            collection.removed[#collection.removed + 1] = { path = path, name = name, no_write = no_write }
        end,
        write = function(_self, names)
            assert(names.weread, "wrong collection written")
            collection.writes = collection.writes + 1
        end,
    }
end

local Cache = require("weread.ui.cache")

-- Fake filesystem: the plugin download root holds per-book directories plus a
-- folder of the user's own; one MP book still sits under an old download
-- root; one record points straight into a user library folder.
local ROOT = "/mnt/us/weread"
fs:file(ROOT .. "/100/book.epub", 600000)
fs:file(ROOT .. "/100/chapters/1.html", 2048)
fs:file(ROOT .. "/MP_WXS_1/a.html", 1024 * 1024)
fs:file(ROOT .. "/MP_WXS_1/b.html", 1024)
fs:file(ROOT .. "/notes/keep.txt", 10)
fs:mkdir(ROOT .. "/300")
fs:file(ROOT .. "/400/secret.epub", 50)
fs.unreadable[ROOT .. "/400"] = true
fs:file("/old/root/MP_WXS_2/x.html", 2048)
fs:file("/mnt/us/documents/Some.epub", 700)
fs:file("/mnt/us/documents/keep.pdf", 900)

local books
local function reset_books()
    books = {
        ["100"] = { title = "beta", cache_dir = ROOT .. "/100",
            cached_file = ROOT .. "/100/book.epub",
            cached_chapters = { [1] = ROOT .. "/100/chapters/1.html" },
            annotation_documents = { ["/mnt/us/weread/100/book.epub"] = true, ["/legacy/doc.epub"] = true } },
        MP_WXS_1 = { title = "MP one", cache_dir = ROOT .. "/MP_WXS_1",
            cached_file = ROOT .. "/MP_WXS_1/a.html" },
        MP_WXS_2 = { title = "mp two", cache_dir = "/old/root/MP_WXS_2" },
        ["200"] = { title = "Alpha", cached_file = "/mnt/us/documents/Some.epub" },
        ["300"] = { title = "empty", cache_dir = ROOT .. "/300" },
        ["400"] = { title = "unreadable", cache_dir = ROOT .. "/400" },
    }
end
reset_books()

local flushes = 0
-- Per-book settings accessors over the current `books` table (which the
-- spec replaces between scenarios).
local settings = {
    cache_dir = ROOT,
    default_cache_dir = "/data/weread",
    get = function(_self, _key, default) return default end,
    flush = function() flushes = flushes + 1 end,
    get_book = function(_self, id) return books[tostring(id)] end,
    get_books = function() return books end,
    put_book = function(_self, id, book) books[tostring(id)] = book end,
    delete_book = function(_self, id) books[tostring(id)] = nil end,
}

local infos, transients, busy, lists = {}, {}, {}, {}
local shelf_refreshes = 0
local annotation_clears, legacy_clears = {}, {}
local annotation_store = {
    fail = nil,
    clearBook = function(self, book_id)
        if self.fail then return nil, self.fail end
        annotation_clears[#annotation_clears + 1] = book_id
        return true
    end,
}
local legacy_db = {
    fail = nil,
    clearDocument = function(self, path)
        if self.fail then return nil, self.fail end
        legacy_clears[#legacy_clears + 1] = path
        return true
    end,
}
local host = {
    settings = settings,
    annotation_store = annotation_store,
    external_annotations_db = legacy_db,
    showInfo = function(_self, text) infos[#infos + 1] = text end,
    showTransientInfo = function(_self, text) transients[#transients + 1] = text end,
    showBusy = function(_self, text) busy[#busy + 1] = text end,
    closeBusy = function() busy[#busy + 1] = "closed" end,
    safeCallback = function(_self, _label, callback) return callback end,
    refreshShelfCacheIndicators = function() shelf_refreshes = shelf_refreshes + 1 end,
    showTrackedList = function(_self, title, items, empty_text)
        local menu = { title = title, items = items, empty_text = empty_text }
        lists[#lists + 1] = menu
        visible[menu] = true
        return menu
    end,
}
for key, value in pairs(Cache) do host[key] = value end

local function snapshot()
    local copy = {}
    for path, node in pairs(fs.nodes) do copy[path] = node.mode end
    return copy
end
local function count(t)
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n
end
-- Every path removed since `mark` lies inside one of the allowed directories.
local function removed_only_within(mark, dirs)
    for index = mark + 1, #fs.removed do
        local path, inside = fs.removed[index], false
        for _i, dir in ipairs(dirs) do
            if path == dir or path:sub(1, #dir + 1) == dir .. "/" then inside = true end
        end
        if not inside then return false, path end
    end
    return true
end
local function warned_since(mark, text)
    for index = mark + 1, #warnings do
        if warnings[index]:find(text, 1, true) then return true end
    end
    return false
end
local function find_item(menu, text)
    for _i, item in ipairs(menu.items) do
        if item.text == text then return item end
    end
end
local function last_shown() return shown[#shown] end

-- 1. The page lists tracked books with their sizes, measured one book per
-- time slice, and never lists folders the plugin does not track.
host:showCacheManagement()
expect(#lists == 0 and busy[1] == "Calculating cache size..." and #scheduled == 1,
    "cache page was built before the busy message")
local slices = run_scheduled()
expect(slices == 6, "six books were not measured one per time slice: " .. slices)
local page = lists[1]
expect(page and page.title == "Cache management" and page.empty_text == "No cached items",
    "cache page was not shown")
expect(#page.items == 6, "unexpected number of cache page rows: " .. #page.items)
expect(page.items[1].text == "[Cleanup] Clear all public account cache (1.0 MB)",
    "public account total wrong: " .. page.items[1].text)
expect(page.items[2].text == "[Cleanup] Clear all cache (1.6 MB)" and page.items[2].separator,
    "overall total wrong: " .. page.items[2].text)
local expected_rows = {
    { "MP one", "2 files, 1.0 MB", "Public Account" },
    { "mp two", "1 files, 2 KB", "Public Account" },
    { "Alpha", "2 files, 2 KB", "" },
    { "beta", "2 files, 588 KB", "" },
}
for index, row in ipairs(expected_rows) do
    local item = page.items[index + 2]
    expect(item.text == row[1] and item.post_text == row[2] and item.mandatory == row[3],
        ("row %d is %s / %s / %s"):format(index, tostring(item.text), tostring(item.post_text),
            tostring(item.mandatory)))
end
expect(not find_item(page, "notes") and not find_item(page, "empty") and not find_item(page, "unreadable"),
    "untracked, empty or unreadable directories were listed")

-- 2. Opening a confirm dialog and cancelling it deletes nothing.
local before = snapshot()
local removed_mark = #fs.removed
find_item(page, "beta").callback()
local confirm = last_shown()
expect(confirm.kind == "confirm" and confirm.text:find("\"beta\"", 1, true) and confirm.ok_text == "Clear",
    "book cleanup did not ask for confirmation")
page.items[1].callback()
expect(last_shown().text:find("public account cache", 1, true), "MP cleanup did not ask for confirmation")
page.items[2].callback()
expect(last_shown().text:find("Clear all cache?", 1, true), "full cleanup did not ask for confirmation")
-- KOReader's ConfirmBox closes itself on cancel; none of these dialogs has a
-- cancel action of its own, so cancelling leaves everything in place.
expect(confirm.cancel_callback == nil and last_shown().cancel_callback == nil,
    "cleanup confirm has a cancel action")
expect(#scheduled == 0 and #fs.removed == removed_mark and count(books) == 6,
    "showing a cleanup confirm already deleted something")
for path in pairs(before) do expect(fs:exists(path), "cancelled cleanup removed " .. path) end

-- 3. While a download runs every cleanup is refused; a background prefetch
-- is asked to stop, a user download is not cancelled.
local cancelled = {}
host.downloader = {
    _active_job = { prefetch = true },
    cancelPrefetch = function(_self, reason) cancelled[#cancelled + 1] = reason end,
}
page.items[2].callback()
last_shown().ok_callback()
expect(cancelled[1] == "cache_cleanup", "background prefetch was not cancelled")
expect(infos[#infos]:find("download is in progress", 1, true), "refusal was not explained")
expect(#scheduled == 0 and busy[#busy] == "closed", "refused cleanup still started")
host.downloader._active_job = { prefetch = false }
local info_count = #infos
expect(host:clearBookCache("100") == false, "book cleanup ran during a download")
expect(host:clearAllMPCache() == false, "MP cleanup ran during a download")
expect(host:clearAllCache() == false, "full cleanup ran during a download")
expect(#cancelled == 1, "a user download was cancelled by a cleanup")
expect(#infos == info_count + 3, "each refused cleanup did not explain itself")
-- A download starting between confirm and the deferred task is still caught.
host.downloader._active_job = nil
find_item(page, "beta").callback()
last_shown().ok_callback()
expect(busy[#busy] == "Clearing cache..." and #scheduled == 1, "confirmed cleanup did not start")
host.downloader._active_job = { prefetch = false }
run_scheduled()
expect(busy[#busy] == "closed" and #transients == 0, "refused deferred cleanup reported success")
expect(#fs.removed == removed_mark and count(books) == 6 and #annotation_clears == 0,
    "cleanup deleted data while a download was running")
host.downloader = nil

-- 4. Clearing one book removes exactly its directory, record, collection
-- entry and annotation data, then rebuilds the open page.
local flushes_before = flushes
find_item(page, "beta").callback()
last_shown().ok_callback()
run_scheduled()
expect(not fs:exists(ROOT .. "/100") and fs:exists(ROOT) and fs:exists(ROOT .. "/notes/keep.txt"),
    "book directory was not removed cleanly")
local ok_scope, outside = removed_only_within(removed_mark, { ROOT .. "/100" })
expect(ok_scope, "book cleanup deleted outside its directory: " .. tostring(outside))
expect(books["100"] == nil and count(books) == 5 and flushes > flushes_before,
    "book record was not removed alone and persisted")
expect(collection.removed[1].path == ROOT .. "/100/book.epub" and collection.removed[1].name == "weread",
    "collection entry was not removed")
expect(annotation_clears[1] == "100", "annotation database was not cleared")
local legacy_set = {}
for _i, path in ipairs(legacy_clears) do legacy_set[path] = (legacy_set[path] or 0) + 1 end
expect(legacy_set[ROOT .. "/100/book.epub"] == 1 and legacy_set[ROOT .. "/100/chapters/1.html"] == 1
        and legacy_set["/legacy/doc.epub"] == 1 and #legacy_clears == 3,
    "legacy annotation documents were not each cleared once")
expect(shelf_refreshes == 1 and transients[#transients] == "Cache cleared", "cleanup was not reported")
expect(closed[#closed] == page and #lists == 2 and not find_item(lists[2], "beta"),
    "cache page was not rebuilt without the cleared book")
page = lists[2]

-- 5. A record whose files sit in a user library folder never deletes it.
removed_mark = #fs.removed
expect(host:clearBookCache("200") == true, "book cleanup failed")
expect(fs:exists("/mnt/us/documents/Some.epub") and fs:exists("/mnt/us/documents/keep.pdf")
        and #fs.removed == removed_mark,
    "a user library folder was deleted")
expect(warnings[#warnings]:find("not a per-book directory", 1, true), "refused deletion was not logged")

-- 6. Clearing from another page reports through its callback instead of
-- rebuilding the cache page.
local cleared_cb = 0
local lists_before = #lists
host:confirmClearBookCache("300", "empty", function() cleared_cb = cleared_cb + 1 end)
last_shown().ok_callback()
run_scheduled()
expect(cleared_cb == 1 and transients[#transients] == "Cache cleared" and #lists == lists_before,
    "on_cleared callback was not used")
expect(not fs:exists(ROOT .. "/300") and books["300"] == nil, "empty book directory was not removed")

-- 7. Clearing all public account cache removes every MP book wherever it
-- lives, and only MP books.
removed_mark = #fs.removed
collection.removed = {}
local writes = collection.writes
page.items[1].callback()
last_shown().ok_callback()
run_scheduled()
expect(not fs:exists(ROOT .. "/MP_WXS_1") and not fs:exists("/old/root/MP_WXS_2"),
    "MP directories were not removed")
expect(fs:exists("/old/root") and fs:exists(ROOT .. "/notes/keep.txt") and fs:exists(ROOT .. "/400/secret.epub"),
    "MP cleanup removed a parent or a non-MP directory")
ok_scope, outside = removed_only_within(removed_mark, { ROOT .. "/MP_WXS_1", "/old/root/MP_WXS_2" })
expect(ok_scope, "MP cleanup deleted outside MP directories: " .. tostring(outside))
expect(books.MP_WXS_1 == nil and books.MP_WXS_2 == nil and books["400"] ~= nil,
    "MP cleanup removed the wrong records")
expect(#collection.removed == 1 and collection.removed[1].path == ROOT .. "/MP_WXS_1/a.html"
        and collection.removed[1].no_write == true and collection.writes == writes + 1,
    "MP collection entries were not removed in one write")
expect(transients[#transients] == "Public account cache cleared", "MP cleanup was not reported")
page = lists[#lists]

-- 8. Clearing all cache removes every per-book directory and record but
-- keeps the download root, the user's folders and unreadable directories
-- it cannot walk.
reset_books()
books.MP_WXS_1, books.MP_WXS_2, books["300"] = nil, nil, nil
fs:file(ROOT .. "/100/book.epub", 600000)
removed_mark = #fs.removed
local warn_mark = #warnings
annotation_clears = {}
page.items[2].callback()
last_shown().ok_callback()
run_scheduled()
expect(not fs:exists(ROOT .. "/100") and fs:exists(ROOT) and fs:exists(ROOT .. "/notes/keep.txt")
        and fs:exists("/mnt/us/documents/keep.pdf"),
    "full cleanup removed the wrong directories")
expect(fs:exists(ROOT .. "/400/secret.epub"), "an unreadable directory was partly deleted")
ok_scope, outside = removed_only_within(removed_mark, { ROOT .. "/100", ROOT .. "/400" })
expect(ok_scope, "full cleanup deleted outside book directories: " .. tostring(outside))
expect(count(books) == 0, "full cleanup left book records")
expect(#annotation_clears == 3, "full cleanup did not clear annotations of every book")
expect(warned_since(warn_mark, "not fully removed") and warned_since(warn_mark, "not a per-book directory"),
    "partial or refused deletion was not logged")
expect(transients[#transients] == "Cache cleared", "full cleanup was not reported")

-- 9. Two records sharing one directory are listed and counted once.
books = {
    d1 = { title = "Shared", cache_dir = ROOT .. "/shared" },
    d2 = { title = "Shared", cache_dir = ROOT .. "/shared" },
}
fs:file(ROOT .. "/shared/s.epub", 4096)
host.cache_menu = nil
host:showCacheManagement()
run_scheduled()
expect(#lists[#lists].items == 3 and lists[#lists].items[2].text == "[Cleanup] Clear all cache (4 KB)",
    "a shared directory was listed or counted twice")

-- 10. Deleting stops short on failures but keeps going for siblings and
-- reports the result.
fs:file(ROOT .. "/700/a.epub", 1)
fs:file(ROOT .. "/700/b.epub", 1)
fs:file(ROOT .. "/700/sub/c.html", 1)
fs.fail_remove[ROOT .. "/700/a.epub"] = "Permission denied"
expect(host:removeBookDir("700", { cache_dir = ROOT .. "/700" }) == false, "failed delete reported success")
expect(fs:exists(ROOT .. "/700/a.epub") and not fs:exists(ROOT .. "/700/b.epub")
        and not fs:exists(ROOT .. "/700/sub"),
    "a failing file stopped the deletion of its siblings")
expect(warnings[#warnings]:find("Permission denied", 1, true), "delete error was not logged")
fs.fail_remove[ROOT .. "/700/a.epub"] = nil
fs.fail_remove[ROOT .. "/700"] = "Device busy"
expect(host:removeBookDir("700", { cache_dir = ROOT .. "/700" }) == false, "failed rmdir reported success")
expect(fs:exists(ROOT .. "/700") and not fs:exists(ROOT .. "/700/a.epub"), "rmdir failure not reported")
fs.fail_remove[ROOT .. "/700"] = nil
expect(host:removeBookDir("700", { cache_dir = ROOT .. "/700" }) == true and not fs:exists(ROOT .. "/700"),
    "retried delete did not finish")
expect(host:removeBookDir("700", { cache_dir = ROOT .. "/700" }) == true, "deleting a gone directory failed")

-- 11. A cleanup task that raises closes the busy message and shows the error.
host:runCacheTask("Clearing cache...", function() error("disk on fire") end)
run_scheduled()
expect(busy[#busy] == "closed", "failed cleanup left the busy message")
expect(infos[#infos]:find("Clearing cache... failed", 1, true) and infos[#infos]:find("disk on fire", 1, true),
    "failed cleanup did not show its error")
expect(warnings[#warnings]:find("cache task failed", 1, true), "failed cleanup was not logged")

-- 12. Annotation cleanup: only the cleared book's sync and pending prefetch
-- are dropped; failures keep the reader state and return the error.
local sync_cancels = 0
local overlay_records
host._cancelUnifiedAnnotationSync = function() sync_cancels = sync_cancels + 1 end
host._external_annotation_sync = { context = { book_id = 42 } }
host._annotation_pending_prefetch = { context = { book_id = "43" } }
host._annotation_context = { book_id = "42" }
host._unified_annotations_active = true
host._xpointer_overlay = { setRecords = function(_self, records) overlay_records = records end }
annotation_store.fail = "database is locked"
local ok, err = host:clearBookAnnotationData("42", { cached_file = "/x.epub" })
expect(ok == false and err:find("database is locked", 1, true), "annotation failure was not returned")
expect(sync_cancels == 1, "running sync of the cleared book was not cancelled")
expect(host._annotation_pending_prefetch ~= nil, "another book's pending prefetch was dropped")
expect(host._annotation_context ~= nil and overlay_records == nil, "reader state was reset after a failed cleanup")
annotation_store.fail = nil
legacy_db.fail = "legacy db read-only"
ok, err = host:clearBookAnnotationData("42", { cached_file = "/x.epub" })
expect(ok == false and err:find("legacy db read-only", 1, true), "legacy annotation failure was not returned")
legacy_db.fail = nil
host._annotation_pending_prefetch = { context = { book_id = 42 } }
ok = host:clearBookAnnotationData(42, { cached_file = "/x.epub", cached_full_book = "/x.epub" })
expect(ok == true and host._annotation_pending_prefetch == nil, "pending prefetch of the book was kept")
expect(host._annotation_context == nil and host._unified_annotations_active == nil
        and type(overlay_records) == "table" and #overlay_records == 0,
    "reader annotation state of the cleared book was kept")
expect(legacy_clears[#legacy_clears] == "/x.epub" and legacy_clears[#legacy_clears - 1] ~= "/x.epub",
    "a document path was cleared twice")
-- Without an injected store one is created from the settings.
local created_with
package.preload["weread.lib.annotation_store"] = function()
    return { new = function(_self, given) created_with = given return annotation_store end }
end
host.annotation_store, host.external_annotations_db = nil, nil
expect(host:clearBookAnnotationData("9", nil) == true and created_with == settings,
    "annotation store was not created on demand")

-- 13. Missing collection support does not stop a cleanup.
package.loaded["readcollection"] = nil
package.preload["readcollection"] = function() error("no collections") end
books = { ["800"] = { title = "x", cache_dir = ROOT .. "/800", cached_file = ROOT .. "/800/x.epub" } }
fs:file(ROOT .. "/800/x.epub", 1)
expect(host:clearAllCache() == true and not fs:exists(ROOT .. "/800") and books["800"] == nil,
    "cleanup failed without collection support")
expect(host:clearBookCache("missing") == true, "clearing an unknown book failed")

restore_fs()
print(("cache_ui_cleanup_spec: %d checks"):format(checks))
