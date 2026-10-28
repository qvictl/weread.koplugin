-- Cache settings, directory selection, scanning, and cleanup UI.
local BookRecords = require("weread.lib.book_records")
local BookStore = require("weread.lib.book_store")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")
local PathChooser = require("ui/widget/pathchooser")
local Scan = require("weread.lib.scan")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists

local M = {}

-- Deleting or moving a book's directory under a running download makes the
-- job write into a stale path, and its completion brings the record back.
-- A background prefetch has no cancel button, so stop it here; the user can
-- retry as soon as its worker has exited.
function M:refuseWhileDownloading()
    local downloader = self.downloader
    if downloader and downloader._active_job then
        if downloader._active_job.prefetch and downloader.cancelPrefetch then
            downloader:cancelPrefetch("cache_cleanup")
        end
        self:showInfo(_("A download is in progress. Cancel it or wait for it to finish first."))
        return true
    end
    return false
end

-- POSIX single-quote a shell argument. string.format("%q") is Lua quoting,
-- not shell quoting: "$" and backticks still expand inside its double quotes.
local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function normalize_dir(path)
    return (tostring(path or ""):gsub("/+$", ""))
end

-- Delete `path` recursively without a shell. Symbolic links are removed
-- themselves and never followed, so a link inside a book directory cannot
-- take files outside it along.
local function delete_tree(lfs, path)
    local stat = lfs.symlinkattributes or lfs.attributes
    local attr = stat(path)
    if not attr then return true end
    if attr.mode ~= "directory" then
        local ok, err = os.remove(path)
        return ok ~= nil, err
    end
    local ok_iter, iter, dir_obj = pcall(lfs.dir, path)
    if not ok_iter then return false, iter end
    local failure
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local ok, err = delete_tree(lfs, path .. "/" .. entry)
            if not ok then failure = failure or err or "delete failed" end
        end
    end
    local removed, err = (lfs.rmdir or os.remove)(path)
    if not removed then return false, failure or err end
    return failure == nil, failure
end

-- Remove a book's cache directory. The directory is resolved from stored
-- paths and may be anything a record points at, so only a per-book directory
-- is deleted: it must be named after the book id, must not be a download
-- root, and must not contain relative components. A record whose files sit
-- directly in the download root or in a user library folder is left alone.
function M:removeBookDir(book_id, book)
    local dir = normalize_dir(Content.book_resolved_dir(self.settings, book_id, book))
    local name = dir:match("([^/]+)$")
    local is_root = dir == normalize_dir(self.settings.cache_dir)
        or (self.settings.default_cache_dir ~= nil
            and dir == normalize_dir(self.settings.default_cache_dir))
    if dir == "" or dir:sub(1, 1) ~= "/" or is_root
        or name ~= Content.book_dir_name(book_id)
        or dir:find("/%.%.?/") then
        logger.warn("book cache not removed: not a per-book directory:", dir)
        return false
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return true end
    local ok, err = delete_tree(lfs, dir)
    if not ok then logger.warn("book cache not fully removed:", dir, tostring(err)) end
    return ok
end

function M:setMPImageDownload(enabled)
    local cache = self.settings:get("cache")
    cache.download_mp_images = enabled == true
    self.settings:set("cache", cache)
    self.settings:flush()
    logger.info(
        "image download setting changed:",
        "target=mp",
        "enabled=", tostring(cache.download_mp_images)
    )
end

-- Returns true if the directory is usable (creatable and writable), else false + message.
function M:validateDownloadDir(path)
    local lfs = require("libs/libkoreader-lfs")
    if type(path) ~= "string" or path == "" then
        return false, _("Invalid path.")
    end
    if not lfs.attributes(path, "mode") then
        os.execute("mkdir -p " .. shell_quote(path))
        if not lfs.attributes(path, "mode") then
            return false, _("Directory does not exist and could not be created.")
        end
    end
    local test_file = path .. "/.weread_write_test"
    local f = io.open(test_file, "w")
    if not f then
        return false, _("Directory is not writable.")
    end
    f:close()
    os.remove(test_file)
    return true
end

function M:showDownloadDirPicker(touchmenu_instance)
    local current = self.settings:get_download_dir()
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = current,
        onConfirm = function(path)
            local ok, err = self:validateDownloadDir(path)
            if not ok then
                self:showInfo(T(_("Cannot use this directory: %1"), err))
                return
            end
            local old_dir = self.settings:get_download_dir()
            self.settings:set_download_dir(path)
            logger.info("download directory changed:", path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            self:offerMoveBooksToNewDir(old_dir, path)
        end,
    }
    UIManager:show(path_chooser)
end

-- After the download directory changes, offer to move already-cached books from
-- their old locations into the new directory. Without this, old files stay behind
-- as orphans (still reachable via the stored paths, but not under the new root).
function M:offerMoveBooksToNewDir(old_dir, new_dir)
    if old_dir == new_dir then
        self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local books = BookRecords.all(self.settings)
    local movable = {}
    for book_id, book in pairs(books) do
        local src = Content.book_resolved_dir(self.settings, book_id, book)
        local dst = Content.book_cache_dir(self.settings, book_id)
        if src ~= dst then
            local attr = lfs.attributes(src)
            if attr and attr.mode == "directory" then
                table.insert(movable, { book_id = book_id, src = src, dst = dst })
            end
        end
    end
    if #movable == 0 then
        self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download directory changed. Move %1 cached book(s) to the new location?"), tostring(#movable)),
        ok_text = _("Move"),
        ok_callback = function()
            self:moveBooksToNewDir(movable, new_dir)
        end,
        cancel_text = _("Keep"),
        cancel_callback = function()
            self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1\nExisting downloads stay in the old location."), new_dir))
        end,
    })
end

function M:moveBooksToNewDir(movable, new_dir)
    if self:refuseWhileDownloading() then return end
    self:showBusy(_("Moving cached books..."))
    UIManager:scheduleIn(0.1, function()
        local books = BookRecords.all(self.settings)
        local moved, skipped, failed = 0, 0, 0
        local collection_updates = {}
        for _i, m in ipairs(movable) do
            local ok, reason = self:moveBookDir(m.src, m.dst)
            if ok then
                local book = books[m.book_id]
                if book then
                    local old_cached_full_book = book.cached_full_book or book.cached_file
                    book.cache_dir = m.dst
                    book.cached_file = self:remapCachedPath(book.cached_file, m.dst)
                    book.cached_full_book = self:remapCachedPath(
                        book.cached_full_book, m.dst)
                    local new_cached_full_book = book.cached_full_book or book.cached_file
                    if old_cached_full_book and new_cached_full_book ~= old_cached_full_book then
                        table.insert(collection_updates, {
                            old_path = old_cached_full_book,
                            new_path = new_cached_full_book,
                        })
                    end
                    if type(book.cached_chapters) == "table" then
                        for uid, path in pairs(book.cached_chapters) do
                            book.cached_chapters[uid] = self:remapCachedPath(path, m.dst)
                        end
                    end
                end
                moved = moved + 1
            elseif reason == "target_exists" then
                skipped = skipped + 1
                logger.warn("skip move, target exists:", m.dst)
            else
                failed = failed + 1
                logger.err("move book cache failed:", m.src, "->", m.dst)
            end
        end
        if #collection_updates > 0 then
            -- After mv, updateItem may miss the old key (realpath fails).
            -- remove + add is more reliable while the new file is on disk.
            pcall(function()
                local ReadCollection = require("readcollection")
                local name = self.settings.collection_name or "weread"
                if not ReadCollection.coll then
                    ReadCollection:_read()
                end
                for _i, update in ipairs(collection_updates) do
                    ReadCollection:removeItem(update.old_path, name, true)
                    if file_exists(update.new_path)
                        and not ReadCollection:isFileInCollection(update.new_path, name) then
                        ReadCollection:addItem(update.new_path, name)
                    end
                end
                ReadCollection:write({ [name] = true })
            end)
        end
        BookRecords.put_many(self.settings, books)
        self.settings:flush()
        self:closeBusy()
        local message
        if skipped == 0 and failed == 0 then
            message = T(_("Moved %1 book(s) to:\n%2"), tostring(moved), new_dir)
        else
            message = T(_("Moved %1 book(s). %2 skipped (target already exists), %3 failed. These stay in the old location."), tostring(moved), tostring(skipped), tostring(failed))
        end
        self:offerScanNewDir(new_dir, message)
    end)
end

-- Move one book directory to dst. Uses `mv`, which (unlike os.rename) handles
-- moves across filesystems, e.g. internal storage to an SD card. Returns
-- true on success, or false plus a reason ("target_exists" / "move_failed").
function M:moveBookDir(src, dst)
    if src == dst then
        return true
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dst) then
        -- The target already exists. Since the new directory is user-selected, it
        -- may be unrelated user data that only happens to share the sanitized name.
        -- Never delete it; leave the book in its old location instead.
        return false, "target_exists"
    end
    local parent = dst:match("^(.*)/[^/]+$")
    if parent then
        os.execute("mkdir -p " .. shell_quote(parent))
    end
    local status = os.execute("mv -f " .. shell_quote(src) .. " " .. shell_quote(dst))
    if status == true or status == 0 then
        return true
    end
    return false, "move_failed"
end

-- Rewrite a stored absolute file path to sit under the new book directory,
-- keeping the original filename.
function M:remapCachedPath(path, dst)
    if type(path) ~= "string" then
        return path
    end
    local name = path:match("[^/]+$")
    if not name then
        return path
    end
    return dst .. "/" .. name
end

local SHELF_SORT_OPTIONS = {
    { key = "time_desc", label = _("Last read time (newest first)"), short = _("Newest") },
    { key = "time_asc",  label = _("Last read time (oldest first)"), short = _("Oldest") },
    { key = "default",   label = _("Default order"), short = _("Default") },
    { key = "name_asc",  label = _("Title A-Z"), short = "A–Z" },
    { key = "name_desc", label = _("Title Z-A"), short = "Z–A" },
}

function M:shelfSortSummary()
    local sort_key = self.settings:get("shelf").sort_order
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        if opt.key == sort_key then return opt.short end
    end
    return SHELF_SORT_OPTIONS[1].short
end

local SHELF_FILTER_OPTIONS = {
    { dim = "reading",  value = "finished",       label = _("Only show finished books"),       short = _("Finished") },
    { dim = "reading",  value = "unfinished",     label = _("Only show unfinished books"),     short = _("Unfinished") },
    { dim = "download", value = "downloaded",     label = _("Only show downloaded books"),     short = _("Downloaded") },
    { dim = "download", value = "not_downloaded", label = _("Only show not-downloaded books"), short = _("Not downloaded") },
}

function M:shelfFilterSummary()
    local filters = self.shelf_filters
    local parts = {}
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        if filters[opt.dim] == opt.value then
            table.insert(parts, opt.short)
        end
    end
    if #parts == 0 then
        return _("All")
    end
    return table.concat(parts, " / ")
end

function M:saveShelfFilters()
    local shelf = self.settings:get("shelf")
    shelf.filter_reading = self.shelf_filters.reading
    shelf.filter_download = self.shelf_filters.download
    self.settings:set("shelf", shelf)
    self.settings:flush()
end

function M:bookMatchesFilters(book, saved_books, downloaded_cache)
    local filters = self.shelf_filters or {}
    if filters.reading == "finished" and book.finishReading ~= 1 then return false end
    if filters.reading == "unfinished" and book.finishReading == 1 then return false end
    if filters.download then
        local is_downloaded = self:isBookDownloaded(book, saved_books, downloaded_cache)
        if filters.download == "downloaded" and not is_downloaded then return false end
        if filters.download == "not_downloaded" and is_downloaded then return false end
    end
    return true
end

function M:showShelfSortOptions(on_sorted)
    local dialog
    local current_sort = self.settings:get("shelf").sort_order or "default"
    local buttons = {}
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        table.insert(buttons, {
            {
                text = opt.label,
                checked_func = function()
                    return opt.key == current_sort
                end,
                -- Defer close+refresh so Button's post-tap checkmark repaint runs
                -- against the still-shown dialog (avoids a ghost label on close).
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        local shelf = self.settings:get("shelf")
                        shelf.sort_order = opt.key
                        self.settings:set("shelf", shelf)
                        self.settings:flush()
                        on_sorted()
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Sort by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:showShelfFilterOptions(on_changed)
    local dialog
    local filters = self.shelf_filters
    local buttons = {
        {
            {
                text = _("All"),
                checked_func = function()
                    return filters.reading == nil and filters.download == nil
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        filters.reading = nil
                        filters.download = nil
                        self:saveShelfFilters()
                        on_changed()
                    end)
                end,
            },
        },
    }
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        table.insert(buttons, {
            {
                text = opt.label,
                checked_func = function()
                    return filters[opt.dim] == opt.value
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        -- Toggle within the dimension: re-tapping clears it, else select.
                        -- (`cond and nil or v` would always yield v.)
                        if filters[opt.dim] == opt.value then
                            filters[opt.dim] = nil
                        else
                            filters[opt.dim] = opt.value
                        end
                        self:saveShelfFilters()
                        on_changed()
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Filter by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:bookRecordHasDownload(record)
    if type(record) ~= "table" then return false end
    if file_exists(record.cached_full_book) or file_exists(record.cached_file) then
        return true
    end
    for _uid, path in pairs(record.cached_chapters or {}) do
        if file_exists(path) then return true end
    end
    return false
end

function M:isBookDownloaded(book, saved_books, downloaded_cache)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return false
    end
    if downloaded_cache and downloaded_cache[book_id] ~= nil then
        return downloaded_cache[book_id]
    end
    local record
    if saved_books then
        record = saved_books[book_id]
    else
        record = BookRecords.get(self.settings, book_id)
    end
    local is_downloaded = self:bookRecordHasDownload(record)
    if downloaded_cache then
        downloaded_cache[book_id] = is_downloaded
    end
    return is_downloaded
end

-- Monotonic seconds for time-slicing long cache walks; nil when KOReader's
-- clock is unavailable (slices then fall back to a fixed number of books).
local function monotonic_seconds()
    local ok, time = pcall(require, "ui/time")
    if not ok or type(time) ~= "table" or not time.now or not time.to_s then return nil end
    return time.to_s(time.now())
end

local CACHE_SCAN_SLICE_SECONDS = 0.25
local CACHE_SCAN_SLICE_BOOKS = 8

-- Run a slow cache operation after a busy message has been painted.
function M:runCacheTask(text, task)
    self:showBusy(text)
    UIManager:scheduleIn(0.1, function()
        local ok, err = pcall(task)
        self:closeBusy()
        if not ok then
            logger.warn("cache task failed:", log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), text, display_error(err)))
        end
    end)
end

-- Measuring the cache walks every file of every book. With hundreds of
-- books (and hundreds of chapter files each) that froze the UI before the
-- page appeared, so walk the books in time-limited slices behind a busy
-- message and show the page when done.
function M:showCacheManagement()
    if self._cache_scan then return end
    local lfs = require("libs/libkoreader-lfs")
    local books = BookRecords.all(self.settings)
    local items = {}
    local entries = {}
    local seen_dirs = {}
    local total_size = 0
    local mp_total_size = 0

    local function directory_stats(path)
        local size = 0
        local file_count = 0
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then
            return size, file_count
        end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local child = path .. "/" .. entry
                local attr = lfs.attributes(child)
                if attr and attr.mode == "file" then
                    size = size + (attr.size or 0)
                    file_count = file_count + 1
                elseif attr and attr.mode == "directory" then
                    local child_size, child_count = directory_stats(child)
                    size = size + child_size
                    file_count = file_count + child_count
                end
            end
        end
        return size, file_count
    end

    local function add_cache_entry(book_id, title, book_dir)
        if seen_dirs[book_dir] then
            return
        end
        seen_dirs[book_dir] = true
        local size, file_count = directory_stats(book_dir)
        if file_count == 0 then
            return
        end
        local is_mp = WeRead.is_mp_book(book_id)
        total_size = total_size + size
        if is_mp then
            mp_total_size = mp_total_size + size
        end
        table.insert(entries, {
            book_id = book_id,
            title = title or book_id,
            size = size,
            file_count = file_count,
            is_mp = is_mp,
        })
    end

    -- Only list plugin-owned entries tracked in the books table. Scanning the
    -- filesystem would list unrelated subfolders when cache_dir is a user-selected
    -- library directory, and deleting one would rm -rf a non-WeRead folder.
    local queue = {}
    for book_id, book in pairs(books) do
        queue[#queue + 1] = { book_id = book_id, book = book }
    end
    local scan = { index = 1 }
    self._cache_scan = scan

    local finish
    local function step()
        if self._cache_scan ~= scan then return end
        local started = monotonic_seconds()
        local processed = 0
        while scan.index <= #queue do
            local item = queue[scan.index]
            scan.index = scan.index + 1
            add_cache_entry(item.book_id, item.book.title,
                Content.book_resolved_dir(self.settings, item.book_id, item.book))
            processed = processed + 1
            local now = started and monotonic_seconds()
            if scan.index <= #queue and ((now and now - started >= CACHE_SCAN_SLICE_SECONDS)
                    or (not now and processed >= CACHE_SCAN_SLICE_BOOKS)) then
                UIManager:scheduleIn(0.1, step)
                return
            end
        end
        self._cache_scan = nil
        self:closeBusy()
        finish()
    end
    self:showBusy(_("Calculating cache size..."))
    UIManager:scheduleIn(0.1, step)

    finish = function()

        table.sort(entries, function(a, b)
            if a.is_mp ~= b.is_mp then
                return a.is_mp
            end
            return tostring(a.title):lower() < tostring(b.title):lower()
        end)

        local total_str = total_size < 1024 * 1024
            and string.format("%.0f KB", total_size / 1024)
            or string.format("%.1f MB", total_size / 1024 / 1024)
        local mp_total_str = mp_total_size < 1024 * 1024
            and string.format("%.0f KB", mp_total_size / 1024)
            or string.format("%.1f MB", mp_total_size / 1024 / 1024)
        table.insert(items, {
            text = T(_("[Cleanup] Clear all public account cache (%1)"), mp_total_str),
            callback = self:safeCallback(_("Clear all public account cache"), function()
                UIManager:show(ConfirmBox:new{
                    text = _("Clear all public account cache? Downloaded articles and cached article lists will be deleted."),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        if self:refuseWhileDownloading() then return end
                        self:runCacheTask(_("Clearing cache..."), function()
                            if not self:clearAllMPCache() then return end
                            self:refreshCacheManagement(_("Public account cache cleared"))
                        end)
                    end,
                })
            end),
        })
        table.insert(items, {
            text = T(_("[Cleanup] Clear all cache (%1)"), total_str),
            separator = true,
            callback = self:safeCallback(_("Clear all cache"), function()
                UIManager:show(ConfirmBox:new{
                    text = _("Clear all cache? Downloaded books and articles, underlines, thoughts, and matching progress will be deleted."),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        if self:refuseWhileDownloading() then return end
                        self:runCacheTask(_("Clearing cache..."), function()
                            if not self:clearAllCache() then return end
                            self:refreshCacheManagement(_("Cache cleared"))
                        end)
                    end,
                })
            end),
        })

        for entry_index, entry in ipairs(entries) do
            local size_str = entry.size < 1024 * 1024
                and string.format("%.0f KB", entry.size / 1024)
                or string.format("%.1f MB", entry.size / 1024 / 1024)
            table.insert(items, {
                text = entry.title,
                post_text = T(_("%1 files, %2"), tostring(entry.file_count), size_str),
                mandatory = entry.is_mp and _("Public Account") or "",
                callback = self:safeCallback(entry.title, function()
                    self:confirmClearBookCache(entry.book_id, entry.title)
                end),
            })
        end

        self.cache_menu = self:showTrackedList(_("Cache management"), items, _("No cached items"))
    end
end

-- Rebuild the cache management page if it is open. A scan or cleanup run
-- from elsewhere (the settings menu) only reports its result: it must not
-- open a page the user never asked for.
function M:refreshCacheManagement(message)
    local menu = self.cache_menu
    self.cache_menu = nil
    if menu and UIManager:isWidgetShown(menu) then
        UIManager:close(menu)
        self:showCacheManagement()
    end
    if message then
        self:showTransientInfo(message)
    end
end

-- Register manually copied content under a download root into the books table.
-- Only directories whose name matches a shelf book id in `allowed` are imported
-- (see weread/lib/scan.lua), so unrelated folders in a user-selected download dir can
-- never be registered and later removed by cache cleanup.
function M:scanLocalCache(root, allowed, dry_run)
    local lfs = require("libs/libkoreader-lfs")
    local books = BookRecords.all(self.settings)
    local added, updated = Scan.scan_root({
        root = root,
        fs = lfs,
        books = books,
        allowed = allowed,
        is_mp = WeRead.is_mp_book,
        dry_run = dry_run,
        now = os.time(),
    })
    if not dry_run and (added or 0) + (updated or 0) > 0 then
        BookRecords.put_many(self.settings, books)
        self.settings:flush()
    end
    return added, updated
end

local function scan_account(settings)
    local account = settings:get("account", {})
    return type(account) == "table" and tostring(account.user_vid or "") or ""
end

function M:refuseWhileScanning()
    if not self._cache_import then return false end
    self:showInfo(_("A local cache scan is already running."))
    return true
end

-- Import one record at a time and yield by elapsed work, not per file. The
-- lazy lookup avoids retaining a second copy of every book/chapter record.
function M:scanLocalCacheAsync(root, allowed, dry_run, on_done, on_error)
    if self:refuseWhileScanning() then return false end
    local scan = {}
    local cache_mark = BookStore.cache_mark(self.settings)
    self._cache_import = scan
    local original_account = scan_account(self.settings)
    local function account_matches() return scan_account(self.settings) == original_account end
    local has_time, time = pcall(require, "ui/time")
    local clock = has_time and type(time) == "table" and time.now and time.to_s
        and function() return time.to_s(time.now()) end or nil
    local started, visited
    local function checkpoint()
        visited = visited + 1
        local now = clock and clock()
        if now and now - started >= CACHE_SCAN_SLICE_SECONDS or not now and visited >= 64 then
            coroutine.yield()
        end
    end
    local co = coroutine.create(function()
        local books = setmetatable({}, { __index = function(_table, id)
            checkpoint()
            return BookRecords.get(self.settings, id)
        end })
        local added, updated = Scan.scan_root{
            root = root, fs = require("libs/libkoreader-lfs"), books = books, allowed = allowed,
            is_mp = WeRead.is_mp_book, dry_run = dry_run, now = os.time(), checkpoint = checkpoint,
            on_change = function(id, record)
                checkpoint()
                if self.library_db and (not self.library_db.accountKey or self.library_db:accountKey()) then
                    if self.library_db:putBook(record) == false then error("could not save imported book to SQLite", 0) end
                end
                BookRecords.put(self.settings, id, record)
                rawset(books, id, nil)
                BookStore.release_cache_since(self.settings, cache_mark)
            end,
        }
        checkpoint()
        if not dry_run and added + updated > 0 then self.settings:flush() end
        return added, updated
    end)
    local function step()
        if self._cache_import ~= scan then return end
        if not account_matches() then
            self._cache_import = nil
            on_error(nil, true)
            return
        end
        started, visited = clock and clock(), 0
        local ok, added, updated = coroutine.resume(co)
        BookStore.release_cache_since(self.settings, cache_mark)
        if not ok then
            self._cache_import = nil
            on_error(added)
        elseif coroutine.status(co) == "dead" then
            self._cache_import = nil
            local delivered, err = pcall(on_done, added, updated)
            if not delivered then on_error(err) end
        else
            UIManager:scheduleIn(0.1, step)
        end
    end
    self:showBusy(_("Scanning local cache..."))
    step()
    return true
end

local function scan_error(self, err, cancelled)
    self:closeBusy()
    if cancelled then return end
    logger.warn("local cache scan failed:", log_error(err))
    self:showInfo(T(_("%1 failed:\n%2"), _("Scan and match local books"), display_error(err)))
end

-- Build the set of importable directory names from the user's WeRead shelf.
-- Must be called from an online context; raises on API failure.
function M:fetchShelfAllowedMap()
    local result = self.client:get_shelf()
    local allowed = {}
    local books = type(result) == "table"
        and type(result.books) == "table"
        and result.books
        or {}
    for _i, book in ipairs(books) do
        if book.bookId then
            allowed[Content.book_dir_name(book.bookId)] = {
                book_id = book.bookId,
                title = book.title,
                author = book.author,
            }
        end
    end
    return allowed
end

function M:confirmScanLocalCache()
    if self:refuseWhileScanning() then return end
    if not self.settings:is_api_configured() then
        self:showInfo(_("Scanning requires the official API key to match folders against your WeRead shelf."))
        return
    end
    self:runOnlineTask(_("Scan and match local books"), function()
        if self:refuseWhileScanning() then return end
        self:showBusy(_("Scanning local cache..."))
        self:_runNetworkRequest(_("Scanning local cache..."), _("Scan and match local books"), function()
            return self:fetchShelfAllowedMap()
        end, function(allowed)
            self:scanLocalCacheAsync(self.settings.cache_dir, allowed, false, function(added, updated)
                self:closeBusy()
                self:refreshCacheManagement(T(_("Scan complete. %1 added, %2 updated."),
                    tostring(added), tostring(updated)))
            end, function(err, cancelled) scan_error(self, err, cancelled) end)
        end, function(err, cancelled)
            self:closeBusy()
            if cancelled then return end
            logger.err("scan shelf fetch failed:", log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), _("Scan and match local books"), display_error(err)))
        end)
    end, 0.1, { link_only = true })
end

-- After the download directory changes, offer to register untracked items
-- already sitting in the new directory (e.g. manually copied in), as well as
-- known books whose stored paths became stale and need rebinding to the files
-- found here. base_message is shown when there is nothing to import or the user
-- skips. Importing requires matching against the shelf, so without an API key
-- or network the scan is silently skipped; it can be run later from Cache
-- management.
function M:offerScanNewDir(new_dir, base_message)
    if self:refuseWhileScanning() then return end
    if not self.settings:is_api_configured() or not self:isNetworkConnected() then
        self:showInfo(base_message)
        return
    end
    self:runOnlineTask(_("Scan and match local books"), function()
        if self:refuseWhileScanning() then return end
        self:_runNetworkRequest(_("Scanning local cache..."), _("Scan and match local books"), function()
            return self:fetchShelfAllowedMap()
        end, function(allowed)
            local original_account = scan_account(self.settings)
            self:scanLocalCacheAsync(new_dir, allowed, true, function(pending_added, pending_updated)
                self:closeBusy()
                if pending_added + pending_updated == 0 then self:showInfo(base_message); return end
                UIManager:show(ConfirmBox:new{
                    text = T(_("Found %1 new and %2 outdated item(s) in the new directory. Import them?"),
                        tostring(pending_added), tostring(pending_updated)),
                    ok_text = _("Import"),
                    ok_callback = function()
                        if self:refuseWhileScanning() then return end
                        if scan_account(self.settings) ~= original_account then return end
                        self:scanLocalCacheAsync(new_dir, allowed, false, function(added, updated)
                            self:closeBusy()
                            self:showInfo(T(_("Imported %1 new and %2 updated item(s)."),
                                tostring(added), tostring(updated)))
                        end, function(err, cancelled) scan_error(self, err, cancelled) end)
                    end,
                    cancel_text = _("Skip"), cancel_callback = function() self:showInfo(base_message) end,
                })
            end, function(err, cancelled) scan_error(self, err, cancelled) end)
        end, function(err, cancelled)
            if cancelled then return end
            logger.warn("skip scan, shelf fetch failed:", log_error(err))
            self:showInfo(base_message)
        end)
    end, 0.1, { link_only = true })
end

function M:confirmClearBookCache(book_id, title, on_cleared)
    UIManager:show(ConfirmBox:new{
        text = T(_("Clear cache for \"%1\"?\nDownloaded files, underlines, thoughts, and matching progress will be deleted."), title),
        ok_text = _("Clear"),
        ok_callback = function()
            if self:refuseWhileDownloading() then return end
            self:runCacheTask(_("Clearing cache..."), function()
                if not self:clearBookCache(book_id) then return end
                if on_cleared then
                    on_cleared()
                    self:showTransientInfo(_("Cache cleared"))
                else
                    self:refreshCacheManagement(_("Cache cleared"))
                end
            end)
        end,
    })
end

local function annotation_document_paths(book)
    local paths, seen = {}, {}
    local function add(path)
        if type(path) == "string" and path ~= "" and not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
        end
    end
    if type(book) ~= "table" then return paths end
    add(book.cached_file)
    add(book.cached_full_book)
    for _, path in pairs(book.cached_chapters or {}) do add(path) end
    for path in pairs(book.annotation_documents or {}) do add(path) end
    return paths
end

function M:clearBookAnnotationData(book_id, book)
    local request = self._external_annotation_sync
    if request and request.context
        and tostring(request.context.book_id) == tostring(book_id)
        and self._cancelUnifiedAnnotationSync then
        self:_cancelUnifiedAnnotationSync()
    end
    local pending = self._annotation_pending_prefetch
    if pending and pending.context
        and tostring(pending.context.book_id) == tostring(book_id) then
        self._annotation_pending_prefetch = nil
    end

    local ok, clear_err = pcall(function()
        local store = self.annotation_store
            or require("weread.lib.annotation_store"):new(self.settings)
        local cleared, err = store:clearBook(book_id)
        if not cleared then error(err or "annotation database delete failed") end
        local legacy = self.external_annotations_db
        if legacy then
            for _, path in ipairs(annotation_document_paths(book)) do
                local removed, legacy_err = legacy:clearDocument(path)
                if not removed then error(legacy_err or "legacy annotation database delete failed") end
            end
        end
    end)
    if not ok then
        logger.warn("annotation cache cleanup failed:", tostring(clear_err))
        return false, tostring(clear_err)
    end

    if self._annotation_context
        and tostring(self._annotation_context.book_id) == tostring(book_id) then
        self._annotation_context = nil
        self._unified_annotations_active = nil
        if self._xpointer_overlay then self._xpointer_overlay:setRecords({}) end
    end
    return true
end

function M:clearBookCache(book_id)
    if self:refuseWhileDownloading() then return false end
    local book = BookRecords.get(self.settings, book_id)
    local path_to_remove = book and (book.cached_full_book or book.cached_file)
    self:clearBookAnnotationData(book_id, book)
    self:removeBookDir(book_id, book)
    if book then
        BookRecords.delete(self.settings, book_id)
        self.settings:flush()
    end
    if path_to_remove then
        pcall(function()
            local ReadCollection = require("readcollection")
            local name = self.settings.collection_name or "weread"
            if not ReadCollection.coll then
                ReadCollection:_read()
            end
            ReadCollection:removeItem(path_to_remove, name)
        end)
    end
    self:refreshShelfCacheIndicators()
    return true
end

function M:clearAllMPCache()
    if self:refuseWhileDownloading() then return false end
    -- Delete each MP book's real directory (which may sit under an old download
    -- root) rather than scanning only the current cache_dir, and only touch
    -- plugin-owned entries tracked in the books table.
    local books = BookRecords.all(self.settings)
    pcall(function()
        local ReadCollection = require("readcollection")
        local name = self.settings.collection_name or "weread"
        if not ReadCollection.coll then
            ReadCollection:_read()
        end
        for book_id, book in pairs(books) do
            if WeRead.is_mp_book(book_id) and book then
                local path = book.cached_full_book or book.cached_file
                if path then
                    ReadCollection:removeItem(path, name, true)
                end
            end
        end
        ReadCollection:write({ [name] = true })
    end)
    local deleted = {}
    for book_id, book in pairs(books) do
        if WeRead.is_mp_book(book_id) then
            self:removeBookDir(book_id, book)
            deleted[#deleted + 1] = book_id
        end
    end
    for _i, book_id in ipairs(deleted) do
        BookRecords.delete(self.settings, book_id)
    end
    self.settings:flush()
    self:refreshShelfCacheIndicators()
    return true
end

function M:clearAllCache()
    if self:refuseWhileDownloading() then return false end
    local books = BookRecords.all(self.settings)
    pcall(function()
        local ReadCollection = require("readcollection")
        local name = self.settings.collection_name or "weread"
        if not ReadCollection.coll then
            ReadCollection:_read()
        end
        for _id, book in pairs(books) do
            if book then
                local path = book.cached_full_book or book.cached_file
                if path then
                    ReadCollection:removeItem(path, name, true)
                end
            end
        end
        ReadCollection:write({ [name] = true })
    end)
    for book_id, book in pairs(books) do
        self:clearBookAnnotationData(book_id, book)
        self:removeBookDir(book_id, book)
    end
    local ids = {}
    for book_id in pairs(books) do ids[#ids + 1] = book_id end
    BookRecords.put_many(self.settings, {}, ids)
    self.settings:flush()
    self:refreshShelfCacheIndicators()
    return true
end

return M
