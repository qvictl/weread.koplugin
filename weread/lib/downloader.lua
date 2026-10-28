-- Book/chapter download engine.
--
-- Extracted from main.lua as an independent, dependency-injected object so the
-- plugin entry point keeps only thin menu wrappers. The host injects the API
-- client, settings, and a small set of UI/framework callbacks; the engine owns
-- the whole async download state machine and the device standby guard.
--
-- Standby guard: long downloads must not let the device suspend mid-transfer.
-- Every scheduled step runs through _scheduleGuarded, which wraps the step in
-- xpcall and always releases the guard (and closes the dialog + reports the
-- error) if the step throws. This is critical: a bare UIManager:scheduleIn that
-- threw would leak the guard and leave the device unable to sleep until reboot.

local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")
local time = require("ui/time")
local T = require("ffi/util").template

local Content = require("weread.lib.content")
local DownloadDialog = require("weread.ui.download_dialog")
local ErrorText = require("weread.lib.error_text")
local Footnotes = require("weread.lib.footnotes")
local I18n = require("weread.lib.i18n")
local MemoryGate = require("weread.lib.memory_gate")
local StandbyGuard = require("weread.lib.standby_guard")
local WeRead = require("weread.lib.protocol")
local WorkerSettings = require("weread.lib.worker_settings")

local function _(text)
    return I18n.tr(text)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

-- Never shows a Lua source position ("content.lua:1699: ") to the user.
local display_error = ErrorText.display

local READER_BOOK_FIELDS = {
    "book_id", "title", "author", "psvts", "pclts", "token", "reader_url",
    "chapter_uid", "chapter_idx", "chapter_offset", "progress", "summary",
    "_content_format", "cache_dir",
}

local function reader_book(book)
    local snapshot = {}
    for _, key in ipairs(READER_BOOK_FIELDS) do snapshot[key] = book[key] end
    return snapshot
end

local function apply_reader_book(book, updated)
    -- Include nil values when a fresh reader session drops old credentials.
    for _, key in ipairs(READER_BOOK_FIELDS) do book[key] = updated[key] end
end

local function account_id(settings)
    if not settings or type(settings.get) ~= "function" then return "" end
    local account = settings:get("account", {})
    return type(account) == "table" and tostring(account.user_vid or "") or ""
end

local Downloader = {}
Downloader.__index = Downloader
-- Finalize pipeline (footnote rescan and transform of every chapter before
-- the EPUB is built) runs in time-budgeted batches: one UI step processes
-- chapters until FINALIZE_BATCH_BUDGET_MS has elapsed (at least one chapter
-- per step), then yields to the UI loop for FINALIZE_YIELD_S so taps (Cancel)
-- and repaints get through. There is no per-chapter sleep: waiting 0.1 s per
-- chapter cost a 200-chapter book ~25 s of idle time.
-- The yield must be a real delay, not nextTick/scheduleIn(0): UIManager keeps
-- running due tasks and repainting while its task queue is dirty and polls
-- input only afterwards, so a chain of zero-delay steps starves input until
-- the chain ends. KOReader's Trapper:info uses 0.05-0.1 s for the same reason
-- ("0.01 is too fast").
local FINALIZE_BATCH_BUDGET_MS = 200
local FINALIZE_YIELD_S = 0.05
Downloader.FINALIZE_BATCH_BUDGET_MS = FINALIZE_BATCH_BUDGET_MS
Downloader.FINALIZE_YIELD_S = FINALIZE_YIELD_S
-- Re-download passes for chapters that fail the final checkpoint check.
local MAX_VERIFY_REDOWNLOAD_PASSES = 2
-- Before each worker fork, wait (with backoff, yielding to the UI) for memory
-- to free up, then stop the job instead of forking into a thrash. A full-book
-- download keeps its checkpoint and can be resumed. Waiting is not a chapter
-- failure. Total wait: about 2 minutes.
local MEMORY_WAIT_SCHEDULE = { 10, 15, 20, 25, 30, 30 }
-- Machine-readable marker; never shown to the user.
local LOW_MEMORY_ERROR = "weread_low_memory"

local function is_low_memory_error(err)
    return tostring(err):find(LOW_MEMORY_ERROR, 1, true) ~= nil
end

-- Raised before forking when the device reports no network link. Shown to
-- the user as the "last error" of a network pause.
local NETWORK_UNAVAILABLE_ERROR = "network is not connected"
-- Resumable jobs pause instead of marching through the remaining chapters
-- (one worker fork per attempt) while the network is gone (F3).
local TRANSPORT_FAILURES_BEFORE_PAUSE = 2
local CHAPTER_FAILURES_BEFORE_PAUSE = 3
local TRANSPORT_ERROR_PATTERNS = {
    NETWORK_UNAVAILABLE_ERROR, "http nil", "http unknown", "timeout",
    "wantread", "wantwrite", "closed", "connection refused",
    "connection reset", "address family not supported", "host not found",
    "name resolution", "network is unreachable", "no route to host",
    "broken pipe",
}

local function is_transport_error(err)
    -- Only the message: worker errors carry a traceback whose frame names
    -- (e.g. "set_timeout") must not count.
    local text = (tostring(err or ""):match("^[^\n]*") or ""):lower()
    for _i, pattern in ipairs(TRANSPORT_ERROR_PATTERNS) do
        if text:find(pattern, 1, true) then return true end
    end
    return false
end

local function kb_to_mb(kb)
    return tostring(math.floor((tonumber(kb) or 0) / 1024 + 0.5))
end

-- o = {
--   client, settings,                       -- injected dependencies
--   show_info(text), show_transient(text, timeout),
--   refresh_ui(), refresh_shelf(),
--   open_file(path), safe_callback(label, fn),
--   require_login(cookie, api_key), run_online_task(label, fn),
--   background_worker,                         -- host framework
--   read_meminfo(), read_self_status(),        -- optional, for specs
--   clock(),                                   -- optional, for specs: ui/time
--                                              -- style now() for batch budgets
-- }
function Downloader:new(o)
    o = o or {}
    -- function() -> ok, available_kb, required_kb; checked before every
    -- worker fork. Collects garbage in the parent first.
    o.memory_gate = o.memory_gate or function()
        return MemoryGate.check_fork(o.read_meminfo)
    end
    setmetatable(o, self)
    return o
end

-- Every forked child starts with the parent's PRNG state; without a reseed
-- each worker draws the same "random" request parameters (F12).
local function reseed_child_random()
    local pid = 0
    pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, "int getpid(void);")
        pid = tonumber(ffi.C.getpid()) or 0
    end)
    local now = tonumber(time.now()) or 0
    math.randomseed(os.time() + pid * 7919 + now % 1000003)
    return pid
end

-- Runs first in every download worker child (see _runInterruptible).
local function prepare_worker_child()
    reseed_child_random()
    MemoryGate.defer_child_gc()
end

-- Per-book persistence. Newer settings expose get_book/put_book and refuse
-- the whole-map "books" key; older ones only have the map.
local function load_book_record(settings, book_id, numeric_fallback)
    if settings.get_book then
        local record = settings:get_book(book_id)
        if not record and numeric_fallback and tonumber(book_id) then
            record = settings:get_book(tonumber(book_id))
        end
        return record
    end
    local books = settings:get("books", {}) or {}
    local record = books[book_id]
    if not record and numeric_fallback then record = books[tonumber(book_id)] end
    return record, books
end

local function save_book_record(settings, book_id, record, books)
    if settings.put_book then
        settings:put_book(book_id, record)
    else
        books = books or settings:get("books", {}) or {}
        books[book_id] = record
        settings:set("books", books)
    end
    if settings.flush then settings:flush() end
end

-- MemAvailable and this process' VmRSS for the per-chapter log line.
function Downloader:_memorySnapshot()
    local read_meminfo = self.read_meminfo or MemoryGate.read_meminfo
    local read_status = self.read_self_status or MemoryGate.read_self_status
    local ok_avail, available = pcall(function()
        return MemoryGate.parse_available_kb(read_meminfo())
    end)
    local ok_rss, rss = pcall(function()
        return MemoryGate.parse_rss_kb(read_status())
    end)
    return ok_avail and available or nil, ok_rss and rss or nil
end

function Downloader:recover()
    -- A SIGKILL/OOM cannot run the normal finally path. A fresh plugin process
    -- owns no active download, so it is safe to clear the persistent Kindle
    -- powerd flag and remove disk artifacts left by the previous process.
    StandbyGuard.recover()
    local ok, removed = pcall(Content.cleanup_stale_downloads, self.settings)
    if not ok then
        logger.warn("stale download recovery failed:", log_error(removed))
        return false
    end
    if tonumber(removed) and removed > 0 then
        logger.info("stale download artifacts removed:", tostring(removed))
    end
    return true
end

function Downloader:_cleanupWorkspace(dl)
    if not dl or not dl.workspace then return end
    local workspace = dl.workspace
    dl.workspace = nil
    if dl.state then dl.state.workspace = nil end
    Content.cleanup_download_workspace(workspace)
end

-- A resumable full-book workspace is intentionally retained after a failure,
-- cancellation or crash.  It only contains downloaded book material under the
-- cache directory; credentials and settings remain untouched.
function Downloader:_preserveWorkspace(dl, reason)
    self:_releaseStandby(dl)
    if dl and dl.progress_dialog then
        dl.progress_dialog:close()
        dl.progress_dialog = nil
    end
    logger.info("full-book download checkpoint retained:",
        "reason=", tostring(reason or "paused"),
        "completed=", tostring(dl and dl.completed_count or 0),
        "total=", tostring(dl and dl.total or 0))
    self:_notifyCompletion(dl, false, reason or "paused")
    self:_finishJob(dl)
end

function Downloader:_restoreFullDownloadCheckpoint(dl)
    local completed = Content.full_download_completed_chapters(
        dl.workspace, dl.chapters)
    local selected = {}
    local completed_count = 0
    for chapter_index, chapter in ipairs(dl.chapters) do
        if completed[chapter_index] then
            table.insert(selected, chapter)
            completed_count = completed_count + 1
        end
    end
    dl.completed = completed
    dl.selected = selected
    dl.completed_count = completed_count
    return completed_count
end

-- Keep the device awake during long book downloads (reference counted so
-- multiple concurrent jobs share a single guard).
function Downloader:_beginStandby()
    self._standby_ref = (self._standby_ref or 0) + 1
    if self._standby_ref == 1 then
        self._standby_token = StandbyGuard.acquire()
    end
end

function Downloader:_endStandby()
    local ref = self._standby_ref or 0
    if ref <= 0 then
        return
    end
    self._standby_ref = ref - 1
    if self._standby_ref == 0 then
        StandbyGuard.release(self._standby_token)
        self._standby_token = nil
    end
end

function Downloader:_releaseStandby(dl)
    if dl and dl.standby_guard then
        dl.standby_guard = nil
        self:_endStandby()
    end
end

function Downloader:_notifyCompletion(dl, ok, value)
    if not dl or dl.completion_notified then return end
    dl.completion_notified = true
    if type(dl.on_complete) ~= "function" then return end
    local called, err = pcall(dl.on_complete, ok == true, value)
    if not called then
        logger.warn("download completion callback failed:",
            log_error(err))
    end
end

function Downloader:_finishJob(dl)
    if self._active_job == dl then
        self._active_job = nil
    end
    local pending = self._pending_start
    if pending and not self._active_job then
        self._pending_start = nil
        local scheduled = { pending = pending }
        self._scheduled_start = scheduled
        UIManager:scheduleIn(0.1, function()
            if self._scheduled_start ~= scheduled then return end
            self._scheduled_start = nil
            if pending.options and (pending.options.prefetch or pending.options.mp_article)
                and pending.account_id ~= account_id(self.settings) then
                if type(pending.options.on_complete) == "function" then
                    pcall(pending.options.on_complete, false, "account_changed")
                end
                return
            end
            self:start(pending.book, pending.chapters, pending.suffix, pending.options)
        end)
    end
end

function Downloader:_cancelScheduledPrefetch(reason)
    local scheduled = self._scheduled_start
    local pending = scheduled and scheduled.pending
    if not pending or not pending.options or not pending.options.prefetch then
        return false
    end
    self._scheduled_start = nil
    local book = pending.book or {}
    local chapter = pending.chapters and pending.chapters[1] or {}
    logger.info("scheduled prefetch cancelled:",
        "book_id=", tostring(book.book_id or book.bookId or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(reason or "cancelled"))
    return true
end

function Downloader:getActivePrefetch()
    local job = self._active_job
    if job and job.prefetch and not job.cancelled then
        return job
    end
end

function Downloader:cancelPrefetch(reason)
    local cancelled_scheduled = self:_cancelScheduledPrefetch(reason)
    if self._pending_start and self._pending_start.options
        and self._pending_start.options.prefetch then
        local pending = self._pending_start
        local pending_book = pending.book or {}
        local pending_chapter = pending.chapters and pending.chapters[1] or {}
        logger.info("pending prefetch cancelled:",
            "book_id=", tostring(pending_book.book_id or pending_book.bookId or ""),
            "chapter_uid=", tostring(pending_chapter.chapterUid
                or pending_chapter.chapterId or ""),
            "reason=", tostring(reason or "cancelled"))
        self._pending_start = nil
    end
    local job = self:getActivePrefetch()
    if not job then return cancelled_scheduled end
    job.cancelled = true
    job.cancel_reason = reason or "cancelled"
    if job.worker_handle and self.background_worker then
        self.background_worker:cancel(job.worker_handle, job.cancel_reason)
    end
    local chapter = job.chapters and job.chapters[1] or {}
    logger.info("active prefetch cancelled:",
        "book_id=", tostring(job.book
            and (job.book.book_id or job.book.bookId) or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(job.cancel_reason))
    if job.progress_dialog then
        job.progress_dialog:close()
        job.progress_dialog = nil
    end
    return true
end

function Downloader:isPrefetching(book, chapter)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    return job ~= nil
        and tostring(job_book_id or "") == tostring(book_id or "")
        and tostring(target_uid or "") == tostring(chapter_uid or "")
end

function Downloader:promotePrefetch(book, chapter)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    if tostring(job_book_id or "") ~= tostring(book_id or "")
        or tostring(target_uid or "") ~= tostring(chapter_uid or "") then
        return false
    end
    job.open_on_complete = true
    job.promoted = true
    self:_ensureProgressDialog(job)
    return true
end

function Downloader:isPromotedPrefetch(book, chapter)
    return self:isPrefetching(book, chapter)
        and self._active_job.promoted == true
end

function Downloader:_ensureProgressDialog(dl)
    if dl.progress_dialog then return dl.progress_dialog end
    local progress_dialog = DownloadDialog:new{
        title = dl.stage_title or T(_("Downloading: %1"), dl.book.title or ""),
        description = dl.resumable and _("You can cancel at any time. Completed chapters are kept.\nChoose Download full book again to resume.") or nil,
        progress_max = dl.total,
        buttons = {{
            {
                text = _("Cancel download"),
                callback = function()
                    local dismiss = dl.progress_dialog and dl.progress_dialog.dismiss_callback
                    if dl.prefetch then
                        self:cancelPrefetch("cancelled")
                    else
                        dl.cancelled = true
                        dl.cancel_reason = dl.cancel_reason or "cancelled"
                        if dl.mp_article and dl.worker_handle and self.background_worker then
                            self.background_worker:cancel(dl.worker_handle, "cancelled")
                        end
                    end
                    if dl.progress_dialog then
                        dl.progress_dialog:close()
                        dl.progress_dialog = nil
                    end
                    -- Trapper resumes the suspended download and kills its child.
                    if dismiss then dismiss() end
                end,
            },
        }},
    }
    dl.progress_dialog = progress_dialog
    progress_dialog:show()
    if dl.stage_progress then
        progress_dialog:reportProgress(dl.stage_progress)
    end
    self.refresh_ui()
    return progress_dialog
end

local function file_exists(path)
    if not path then return false end
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

function Downloader:_prefetchStage(dl, state)
    local stage = state and state.stage
    local title
    if stage == "reader" then
        title = T(_("Preparing chapter %1/%2"), "1", "1")
    elseif stage == "source" then
        local attempt = tonumber(state.attempt) or 1
        if attempt > 1 then
            title = T(_("Retrying chapter %1/%2 · attempt %3"), "1", "1",
                tostring(attempt - 1))
        else
            local chapter = dl.chapters[1] or {}
            title = T(_("Downloading chapter %1/%2: %3"), "1", "1",
                chapter.title or tostring(chapter.chapterUid or ""))
        end
    elseif stage == "images" then
        title = T(_("Downloading images · chapter %1/%2"), "1", "1")
    elseif stage == "footnotes" then
        title = T(_("Processing footnotes · chapter %1/%2"), "1", "1")
    elseif stage == "epub" then
        title = _("Building EPUB...")
    else
        title = T(_("Processing chapter %1/%2"), "1", "1")
    end
    self:_setStage(dl, title, stage == "epub" and 1 or 0)
end

function Downloader:_applyPrefetchResult(dl, result)
    self:_releaseStandby(dl)
    dl.worker_handle = nil
    if dl.progress_dialog then
        dl.progress_dialog:close()
        dl.progress_dialog = nil
    end
    if self._active_job ~= dl then return end
    if dl.account_id ~= account_id(self.settings) then
        self:_notifyCompletion(dl, false, "account_changed")
        self:_finishJob(dl)
        return
    end
    if dl.cancelled then
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        return
    end
    if type(result) ~= "table" or result.ok ~= true
        or type(result.value) ~= "table" or not file_exists(result.value.path) then
        local reason = type(result) == "table" and result.error or "worker_no_result"
        self:_notifyCompletion(dl, false, reason)
        self:_finishJob(dl)
        return
    end

    local value = result.value
    local book_id = tostring(dl.book.book_id or dl.book.bookId or "")
    local chapter = dl.chapters[1] or {}
    local uid = tostring(value.chapter_uid or chapter.chapterUid
        or chapter.chapterId or "1")
    local persisted, persist_err = pcall(function()
        if value.auth and not WorkerSettings.merge(self.settings,
            dl.auth_fingerprint, value.auth) then
            logger.info("skip worker auth write-back: parent auth changed")
        end
        local record, books = load_book_record(self.settings, book_id, true)
        record = record or {}
        local function apply(target)
            target.cached_chapters = target.cached_chapters or {}
            target.cached_chapters[uid] = value.path
            target.cache_dir = value.cache_dir or target.cache_dir
            target.reader_url = target.reader_url or value.reader_url
            if value.annotation_document then
                target.annotation_documents = target.annotation_documents or {}
                target.annotation_documents[value.path] = value.annotation_document
            end
        end
        apply(dl.book)
        if record ~= dl.book then apply(record) end
        record.book_id = record.book_id or dl.book.book_id or dl.book.bookId
        save_book_record(self.settings, book_id, record, books)
    end)
    if not persisted then
        logger.err("prefetch result persistence failed:", log_error(persist_err))
        self:_notifyCompletion(dl, false, persist_err)
        self:_finishJob(dl)
        return
    end
    local refreshed, refresh_err = pcall(self.refresh_shelf)
    if not refreshed then
        logger.warn("shelf refresh after prefetch failed:", log_error(refresh_err))
    end
    logger.info("prefetch worker completed:", "book_id=", book_id,
        "chapter_uid=", uid, "path=", value.path)
    self:_notifyCompletion(dl, true, value.path)
    self:_finishJob(dl)
    if dl.open_on_complete then self.open_file(value.path) end
end

function Downloader:_startPrefetchWorker(dl)
    if dl.account_id ~= account_id(self.settings) then
        self:_applyPrefetchResult(dl, { ok = false, error = "account_changed" })
        return false
    end
    local worker = self.background_worker
    if not worker or not worker:available() then
        self:_applyPrefetchResult(dl, {
            ok = false, error = "worker_unavailable",
        })
        return false
    end
    local ChapterWorker = require("weread.lib.chapter_prefetch_worker")
    local ok, handle = worker:start {
        kind = "chapter",
        queue = true,
        replace_active = true,
        timeout = 180,
        task = function(context)
            -- The shared worker can launch this queued request after login.
            if dl.account_id ~= account_id(self.settings) then error("account_changed", 0) end
            return ChapterWorker.run(self.settings, self.client, dl.book,
                dl.chapters[1], context)
        end,
        on_launch = function(pid, available_kb)
            if self._active_job ~= dl then return end
            self:_beginStandby()
            dl.standby_guard = true
            logger.info("prefetch worker started:", "pid=", tostring(pid),
                "available_kb=", tostring(available_kb or "unknown"))
        end,
        on_progress = function(state)
            if self._active_job == dl then self:_prefetchStage(dl, state) end
        end,
        on_done = function(result)
            self:_applyPrefetchResult(dl, result)
        end,
    }
    if ok then
        dl.worker_handle = handle
        return true
    end
    return false
end

-- Sleep inside the Trapper coroutine: yields back to the UI loop, and the
-- progress dialog's cancel button wakes the sleeper immediately. Returns false
-- when not running in a coroutine (nothing to yield to).
function Downloader:_sleepInJob(dl, seconds)
    local co = coroutine.running()
    if not co then return false end
    local woken = false
    local function wake()
        if woken then return end
        woken = true
        coroutine.resume(co)
    end
    local dialog = dl.progress_dialog
    if dialog then dialog.dismiss_callback = wake end
    UIManager:scheduleIn(seconds, wake)
    coroutine.yield()
    -- Whichever of timer/cancel fired first won; the other must stay a no-op.
    woken = true
    if UIManager.unschedule then UIManager:unschedule(wake) end
    if dialog and dialog.dismiss_callback == wake then dialog.dismiss_callback = nil end
    return true
end

-- Raises a LOW_MEMORY_ERROR when memory does not recover; callers route it to
-- _stopForLowMemory instead of counting a chapter failure.
function Downloader:_waitForMemory(dl)
    local ok, available, required = self.memory_gate()
    if ok then return end
    local previous_title, previous_progress = dl.stage_title, dl.stage_progress
    for attempt, delay in ipairs(MEMORY_WAIT_SCHEDULE) do
        if dl.cancelled then return end
        logger.warn("download waiting for free memory:",
            "available_kb=", tostring(available),
            "required_kb=", tostring(required),
            "lua_kb=", string.format("%.1f", collectgarbage("count")),
            "attempt=", tostring(attempt) .. "/" .. tostring(#MEMORY_WAIT_SCHEDULE),
            "delay_s=", tostring(delay))
        self:_setStage(dl, T(_("Waiting for free memory... %1 MB free, %2 MB needed"),
            kb_to_mb(available), kb_to_mb(required)), previous_progress)
        if not self:_sleepInJob(dl, delay) then break end
        if dl.cancelled then return end
        ok, available, required = self.memory_gate()
        if ok then
            logger.info("download memory recovered:",
                "available_kb=", tostring(available),
                "required_kb=", tostring(required))
            if previous_title then self:_setStage(dl, previous_title, previous_progress) end
            return
        end
    end
    if dl.cancelled then return end
    error(string.format("%s: available_kb=%s required_kb=%s", LOW_MEMORY_ERROR,
        tostring(available), tostring(required)), 0)
end

-- Not enough memory to fork safely, even after waiting. Resumable jobs keep
-- their checkpoint; others stop cleanly. Never skips or fails a chapter.
function Downloader:_stopForLowMemory(dl, err)
    logger.warn("download stopped for low memory:", log_error(err),
        "resumable=", tostring(dl.resumable == true),
        "completed=", tostring(dl.completed_count or #(dl.selected or {})),
        "total=", tostring(dl.total))
    local message
    if dl.resumable and dl.workspace then
        self:_preserveWorkspace(dl, "low_memory")
        message = _("Download paused: not enough free memory.\n\nCompleted chapters were kept. Close the open book or restart KOReader, then choose Download full book again to continue.")
    else
        self:_releaseStandby(dl)
        self:_cleanupWorkspace(dl)
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_notifyCompletion(dl, false, "low_memory")
        self:_finishJob(dl)
        message = _("Download stopped: not enough free memory.\n\nClose the open book or restart KOReader, then try again.")
    end
    if not dl.prefetch then self.show_info(message) end
end

function Downloader:_runInterruptible(dl, task)
    if dl.cancelled then return nil end
    if not dl.trapper then return task() end
    -- No point forking a worker (and paying its memory) without a link.
    if self.is_connected and not self.is_connected() then
        error(NETWORK_UNAVAILABLE_ERROR, 0)
    end
    self:_waitForMemory(dl)
    if dl.cancelled then return nil end
    local dialog = dl.progress_dialog
    local fingerprint = WorkerSettings.fingerprint(self.settings)
    local prepare_child = self.prepare_worker_child or prepare_worker_child
    local completed, result = dl.trapper:dismissableRunInSubprocess(function()
        pcall(prepare_child)
        local auth_result = WorkerSettings.capture(self.settings)
        local ok, value = xpcall(task, debug.traceback)
        return { ok = ok, value = value, auth = auth_result() }
    end, dialog)
    if dialog then dialog.dismiss_callback = nil end
    if dl.cancelled then return nil end
    if not completed then error("could not start download worker") end
    if not result then error("download worker returned no result") end
    if result.auth then WorkerSettings.merge(self.settings, fingerprint, result.auth) end
    if not result.ok then error(result.value, 0) end
    return result.value
end

-- Schedule any download step behind xpcall so an uncaught error always releases
-- the standby guard, closes the progress dialog, and reports the failure.
-- Errors are never swallowed: even when the guard is already released (e.g. a
-- throw while persisting the result), a job that is still active or has not
-- reported completion is finished, so _active_job cannot stay stuck (F6).
function Downloader:_scheduleGuarded(dl, step_fn, delay)
    UIManager:scheduleIn(delay or 0.1, function()
        local function run()
            local ok, err = xpcall(step_fn, debug.traceback)
            if ok then return end
            logger.err("download step failed:", log_error(err))
            if self._active_job ~= dl and dl.completion_notified then return end
            local handled, handle_err = pcall(function()
                if is_low_memory_error(err) then
                    self:_stopForLowMemory(dl, err)
                    return
                end
                if dl.resumable and dl.workspace then
                    self:_preserveWorkspace(dl, err)
                else
                    self:_releaseStandby(dl)
                    self:_cleanupWorkspace(dl)
                    if dl.progress_dialog then
                        dl.progress_dialog:close()
                        dl.progress_dialog = nil
                    end
                    self:_notifyCompletion(dl, false, err)
                    self:_finishJob(dl)
                end
                if not dl.prefetch then
                    self.show_info(T(_("Download failed:\n%1"), display_error(err)))
                end
            end)
            if not handled then
                logger.err("download failure cleanup failed:", log_error(handle_err))
                self:_releaseStandby(dl)
                if dl.progress_dialog then
                    pcall(dl.progress_dialog.close, dl.progress_dialog)
                    dl.progress_dialog = nil
                end
                self:_notifyCompletion(dl, false, err)
                self:_finishJob(dl)
            end
        end
        if dl.trapper then dl.trapper:wrap(run) else run() end
    end)
end

-- Public entry: start downloading the given chapters as one EPUB.
function Downloader:start(book, chapters, suffix, options)
    options = options or {}
    chapters = type(chapters) == "table" and chapters or {}
    if options.prefetch and self.is_connected and not self.is_connected() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "offline")
        end
        return false
    end
    if options.prefetch and self.settings.is_cookie_configured
        and not self.settings:is_cookie_configured() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end
    if not options.prefetch and not self.require_login(true, false) then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end

    local scheduled = self._scheduled_start
    if scheduled then
        local scheduled_prefetch = scheduled.pending
            and scheduled.pending.options
            and scheduled.pending.options.prefetch == true
        if scheduled_prefetch then
            self:_cancelScheduledPrefetch(
                options.prefetch and "replaced" or "manual_download")
        else
            if not options.prefetch then
                self.show_transient(_("Another download is already in progress."), 1)
            end
            return false
        end
    end
    -- Same rule while the manual download still waits for the prefetch
    -- worker to stop: it must not be overwritten (and silently lost).
    local pending = self._pending_start
    if pending and not (pending.options and pending.options.prefetch) then
        if not options.prefetch then
            self.show_transient(_("Another download is already in progress."), 1)
        end
        return false
    end

    local active = self._active_job
    if active then
        if options.prefetch then
            if active.prefetch then
                self:cancelPrefetch("replaced")
                self._pending_start = {
                    book = book,
                    chapters = chapters,
                    suffix = suffix,
                    options = options,
                    account_id = account_id(self.settings),
                }
                return true
            end
            return false
        end
        if active.prefetch then
            self:cancelPrefetch("manual_download")
            self._pending_start = {
                book = book,
                chapters = chapters,
                suffix = suffix,
                options = options,
                account_id = account_id(self.settings),
            }
            return true
        end
        self.show_transient(_("Another download is already in progress."), 1)
        return false
    end

    local total = #chapters
    local resumable = (suffix or "book") == "full"
        and not options.single_chapter
        and not options.separate_chapters
    local dl = {
        book = book,
        chapters = chapters,
        suffix = suffix or "book",
        index = 1,
        cancelled = false,
        selected = {},
        bodies = {},
        assets = {},
        assets_by_uid = {},
        state = {},
        total = total,
        failed = {},
        resumable = resumable,
        completed = {},
        completed_count = 0,
        annotation_failed_batches = 0,
        footnote_scans = {},
        footnote_stats = {
            candidates = 0,
            converted = 0,
            image_notes = 0,
            backlinks = 0,
            removed_note_blocks = 0,
            unresolved = 0,
            fallback = 0,
        },
        single_chapter = options.single_chapter == true,
        mp_article = options.mp_article == true,
        separate_chapters = options.separate_chapters == true,
        include_annotations = false,
        open_on_complete = options.open_on_complete == true,
        offer_read = options.offer_read ~= false,
        silent_completion = options.silent_completion == true,
        prefetch = options.prefetch == true,
        start_delay = tonumber(options.start_delay) or 0,
        on_start = options.on_start,
        on_complete = options.on_complete,
        started_at = time.now(),
        auth_fingerprint = WorkerSettings.fingerprint(self.settings),
        account_id = account_id(self.settings),
    }
    self._active_job = dl

    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    local task_runner = function(callback)
        return self.run_online_task(task_label, callback)
    end
    local function notifyStart()
        if dl.start_notified or type(dl.on_start) ~= "function" then return end
        dl.start_notified = true
        local called, start_err = pcall(dl.on_start)
        if not called then
            logger.warn("download start callback failed:", log_error(start_err))
        end
    end
    if dl.mp_article then
        if self.is_connected and not self.is_connected() then
            self:_notifyCompletion(dl, false, "offline")
            self:_finishJob(dl)
            self.show_info(_("No network connection. Please connect Wi-Fi and try again."))
            return false
        end
        dl.stage_title = T(_("Downloading article: %1"), chapters[1] and chapters[1].title or "")
        self:_ensureProgressDialog(dl)
        self:_scheduleGuarded(dl, function()
            if self._active_job ~= dl then return end
            if dl.cancelled then
                self:_notifyCompletion(dl, false, "cancelled")
                self:_finishJob(dl)
                return
            end
            require("weread.lib.mp_article_download").start(self, dl)
        end)
        return true
    end
    if dl.prefetch then
        notifyStart()
        UIManager:scheduleIn(math.max(0.1, dl.start_delay), function()
            if self._active_job ~= dl then return end
            if dl.cancelled then
                self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
                self:_finishJob(dl)
                return
            end
            self:_startPrefetchWorker(dl)
        end)
        return true
    end
    local function initializeDownload()
        if dl.cancelled then
            self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
            self:_finishJob(dl)
            return
        end
        local ok_init, err_init = pcall(function()
            self:_setStage(dl, _("Connecting to WeRead..."))
            local updated = self:_runInterruptible(dl, function()
                Content.ensure_reader_state(self.client, book)
                return reader_book(book)
            end)
            if dl.cancelled then return end
            apply_reader_book(book, updated)
            self:_setStage(dl, _("Preparing download..."))
            local cache = self.settings.get
                and self.settings:get("cache", {}) or {}
            if dl.resumable and Content.open_full_download_workspace then
                dl.workspace = Content.open_full_download_workspace(
                    self.settings, book)
                dl.state.workspace = dl.workspace
                dl.state.css = Content.load_full_download_css(dl.workspace)
                dl.saved_css = dl.state.css
                dl.state.used_asset_names = Content.full_download_workspace_used_asset_names(
                    dl.workspace)
                self:_restoreFullDownloadCheckpoint(dl)
            elseif cache.download_book_images and Content.create_download_workspace then
                dl.workspace = Content.create_download_workspace(
                    self.settings, book)
                dl.state.workspace = dl.workspace
            end
        end)
        if dl.cancelled then self:_step(dl); return end
        if not ok_init then
            logger.err("initialize book download failed:", log_error(err_init))
            self:_cleanupWorkspace(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            local low_memory = is_low_memory_error(err_init)
            if type(options.on_complete) == "function" then
                pcall(options.on_complete, false, low_memory and "low_memory" or err_init)
            end
            dl.completion_notified = true
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(low_memory
                    and _("Download stopped: not enough free memory.\n\nClose the open book or restart KOReader, then try again.")
                    or T(_("Download failed:\n%1"), display_error(err_init)))
            end
            return
        end

        self:_beginStandby()
        dl.standby_guard = true
        notifyStart()

        self:_scheduleGuarded(dl, function() self:_step(dl) end)
    end
    -- Paint before run_online_task checks connectivity (which may resolve DNS)
    -- and before initializeDownload opens the reader session or local cache.
    dl.stage_title = _("Checking network...")
    self:_ensureProgressDialog(dl)
    local ffiutil = require("ffi/util")
    if type(ffiutil.runInSubProcess) == "function" then
        local ok, trapper = pcall(require, "ui/trapper")
        if ok then dl.trapper = trapper end
    end
    local started = task_runner(function()
        if dl.trapper then dl.trapper:wrap(initializeDownload) else initializeDownload() end
    end)
    if started == false then
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_notifyCompletion(dl, false, "offline")
        self:_finishJob(dl)
    end
    return started ~= false
end

function Downloader:_setStage(dl, title, progress)
    dl.stage_title = title
    dl.stage_progress = progress
    if not dl.progress_dialog then return end
    dl.progress_dialog:setTitle(title)
    if progress then
        dl.progress_dialog:reportProgress(progress)
    end
end

-- Clock for finalize batch budgets (ui/time units); injectable for specs.
function Downloader:_now()
    if self.clock then return self.clock() end
    return time.now()
end

-- True once the finalize batch that started at `batch_started` has used up
-- its time budget and the next chapter must wait for the next UI step.
function Downloader:_batchSpent(batch_started)
    return tonumber(self:_now() - batch_started) / 1000 >= FINALIZE_BATCH_BUDGET_MS
end

-- End the current finalize batch: let the UI loop poll input and repaint,
-- then continue with step_fn (guarded like every download step).
function Downloader:_yieldFinalize(dl, step_fn)
    dl.finalize_yields = (dl.finalize_yields or 0) + 1
    self:_scheduleGuarded(dl, step_fn, FINALIZE_YIELD_S)
end

function Downloader:_perf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info("download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

-- Count one failed chapter attempt. Returns true when a resumable job was
-- paused because the network looks gone (TRANSPORT_FAILURES_BEFORE_PAUSE
-- transport errors in a row) or chapters keep failing
-- (CHAPTER_FAILURES_BEFORE_PAUSE given-up chapters in a row). A successful
-- chapter resets both counters.
function Downloader:_recordFailure(dl, err, chapter_given_up)
    if is_transport_error(err) then
        dl.consecutive_transport_failures = (dl.consecutive_transport_failures or 0) + 1
    else
        dl.consecutive_transport_failures = 0
    end
    if chapter_given_up then
        dl.consecutive_chapter_failures = (dl.consecutive_chapter_failures or 0) + 1
    end
    if not dl.resumable then return false end
    local network = dl.consecutive_transport_failures >= TRANSPORT_FAILURES_BEFORE_PAUSE
    local repeated = (dl.consecutive_chapter_failures or 0) >= CHAPTER_FAILURES_BEFORE_PAUSE
    if not network and not repeated then return false end
    local reason = network and "network_unavailable" or "repeated_failures"
    logger.warn("full-book download paused after repeated failures:",
        "reason=", reason,
        "transport_failures=", tostring(dl.consecutive_transport_failures),
        "chapter_failures=", tostring(dl.consecutive_chapter_failures or 0),
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "error=", log_error(err))
    self:_preserveWorkspace(dl, reason)
    if not dl.prefetch then
        local message = network
            and _("Full-book download paused: the network seems to be unavailable.\n\nCompleted chapters were kept. Choose Download full book again to continue when the connection is back.\n\nLast error: %1")
            or _("Full-book download paused: several chapters in a row failed.\n\nCompleted chapters were kept. Choose Download full book again to continue later.\n\nLast error: %1")
        self.show_info(T(message, display_error(err)))
    end
    return true
end

function Downloader:_failChapter(dl, err)
    if is_low_memory_error(err) then return self:_stopForLowMemory(dl, err) end
    if self:_recordFailure(dl, err, true) then return end
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    table.insert(dl.failed, uid)
    if dl.footnote_scans then
        dl.footnote_scans[uid] = nil
    end
    logger.warn("chapter download failed:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_skipCompletedChapterBatch(dl)
    local first_index = dl.index
    local skipped = 0
    local batch_started = self:_now()
    while dl.index <= dl.total and dl.completed[dl.index] do
        dl.index = dl.index + 1
        skipped = skipped + 1
        if self:_batchSpent(batch_started) then break end
    end
    if skipped == 0 then return false end
    self:_setStage(dl,
        T(_("Resuming downloaded chapter %1/%2"),
            tostring(dl.index - 1), tostring(dl.total)), dl.index - 1)
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    logger.info("resumed completed chapter batch:",
        "first=", tostring(first_index), "count=", tostring(skipped),
        "total=", tostring(dl.total))
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
    return true
end

function Downloader:_retryChapterSource(dl, err)
    -- Not a chapter problem: stop the job, so no chapter is skipped and a
    -- full-book download keeps its checkpoint.
    if is_low_memory_error(err) then
        self:_stopForLowMemory(dl, err)
        return false
    end
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    dl.chapter_source_retries = dl.chapter_source_retries or {}
    local attempt = (dl.chapter_source_retries[uid] or 0) + 1
    dl.chapter_source_retries[uid] = attempt
    if attempt > 2 then
        dl.chapter_source_retries[uid] = nil
        self:_failChapter(dl, err)
        return false
    end
    if self:_recordFailure(dl, err, false) then return false end
    logger.warn("chapter source download failed; retrying:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "attempt=", tostring(attempt),
        "error=", log_error(err))
    self:_setStage(dl,
        T(_("Retrying chapter %1/%2 · attempt %3"),
            tostring(dl.index), tostring(dl.total), tostring(attempt)),
        dl.index - 1)
    self:_scheduleGuarded(dl, function() self:_step(dl) end, 0.8 * attempt)
    return true
end

local function add_footnote_stats(total, current)
    for _i, key in ipairs({
        "candidates", "converted", "image_notes", "backlinks",
        "removed_note_blocks", "unresolved",
    }) do
        total[key] = (tonumber(total[key]) or 0) + (tonumber(current and current[key]) or 0)
    end
end

function Downloader:_stopCancelled(dl)
    if dl.resumable then
        self:_preserveWorkspace(dl, dl.cancel_reason or "cancelled")
    else
        self:_releaseStandby(dl)
        self:_cleanupWorkspace(dl)
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
    end
    if not dl.prefetch then
        self.show_transient(_("Download cancelled"), 2)
    end
end

-- Transform one chapter's footnotes with the book-wide index. A failed or
-- invalid transform keeps the original chapter (counted as a fallback).
function Downloader:_transformFootnoteChapter(dl, job, chapter)
    local uid = tostring(chapter.chapterUid or job.index)
    local original = dl.bodies[uid]
    if dl.resumable then
        original = Content.load_full_download_chapter(
            dl.workspace, chapter, job.index)
    end
    local started = time.now()
    local ok, transformed, stats = pcall(Footnotes.transform_chapter,
        original, dl.footnote_scans[uid], job.index_data)
    if ok then
        local valid, validation_error = Footnotes.validate(transformed)
        if valid then
            if dl.resumable then
                Content.save_full_download_rendered_chapter(
                    dl.workspace, chapter, job.index, transformed)
            else
                dl.bodies[uid] = transformed
            end
            add_footnote_stats(dl.footnote_stats, stats)
            if Footnotes.has_converted(stats) then job.css_needed = true end
        else
            dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
            logger.warn("footnote transform validation failed; keeping original chapter:",
                "chapter_uid=", uid, "error=", log_error(validation_error))
            if dl.resumable then
                Content.save_full_download_rendered_chapter(
                    dl.workspace, chapter, job.index, original)
            else
                dl.bodies[uid] = original
            end
        end
    else
        dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
        logger.warn("footnote transform failed; keeping original chapter:",
            "chapter_uid=", uid, "error=", log_error(transformed))
        if dl.resumable then
            Content.save_full_download_rendered_chapter(
                dl.workspace, chapter, job.index, original)
        else
            dl.bodies[uid] = original
        end
    end
    self:_perf(dl, "footnotes", started, "chapter_uid=", uid,
        "ok=", tostring(ok), "fallback=", tostring(not ok))
end

-- Transform phase of the finalize pipeline: chapters in order, as many per
-- UI step as fit in FINALIZE_BATCH_BUDGET_MS. `batch_started` continues the
-- batch of the scan phase; a scheduled step starts a new batch.
function Downloader:_footnoteStep(dl, batch_started)
    if dl.cancelled then
        self:_stopCancelled(dl)
        return
    end
    local job = dl.footnote_job
    if not job then
        dl.footnotes_done = true
        self:_yieldFinalize(dl, function() self:_step(dl) end)
        return
    end
    batch_started = batch_started or self:_now()
    local chapters = job.chapters or dl.selected
    local total = #dl.selected
    local function report()
        self:_setStage(dl,
            T(_("Processing footnotes · chapter %1/%2"),
                tostring(job.index - 1), tostring(total)), dl.total)
    end
    while job.index <= total do
        self:_transformFootnoteChapter(dl, job, chapters[job.index])
        job.index = job.index + 1
        if job.index <= total and self:_batchSpent(batch_started) then
            report()
            self:_yieldFinalize(dl, function() self:_footnoteStep(dl) end)
            return
        end
    end
    report()
    dl.footnotes_done = true
    dl.footnote_job = nil
    if job.css_needed then
        dl.state.css = (dl.state.css or "") .. "\n"
            .. Footnotes.FOOTNOTES_CSS
    end
    logger.info("book footnotes processed:",
        "candidates=", tostring(dl.footnote_stats.candidates),
        "converted=", tostring(dl.footnote_stats.converted),
        "images=", tostring(dl.footnote_stats.image_notes),
        "backlinks=", tostring(dl.footnote_stats.backlinks),
        "removed_note_blocks=", tostring(dl.footnote_stats.removed_note_blocks),
        "unresolved=", tostring(dl.footnote_stats.unresolved),
        "fallback=", tostring(dl.footnote_stats.fallback),
        "ui_yields=", tostring(dl.finalize_yields or 0))
    self:_yieldFinalize(dl, function() self:_step(dl) end)
end

function Downloader:_startFootnotes(dl)
    dl.footnote_scans = dl.footnote_scans or {}
    dl.footnote_stats = dl.footnote_stats or {
        candidates = 0,
        converted = 0,
        image_notes = 0,
        backlinks = 0,
        removed_note_blocks = 0,
        unresolved = 0,
        fallback = 0,
    }
    dl.finalize_yields = 0
    local selected = dl.resumable and dl.chapters or dl.selected
    dl.footnote_scan_job = { index = 1, chapters = selected or {}, scans = {} }
    if dl.resumable then
        -- Keep source checkpoints pristine. Footnote conversion removes
        -- consumed definitions, so its output belongs in a disposable
        -- rendering directory that can be rebuilt after an interrupted run.
        Content.reset_full_download_rendered_text(dl.workspace)
        -- Rescanning every checkpoint from disk is too slow for one UI step
        -- on a large book; it runs in budgeted batches from the next step.
        self:_yieldFinalize(dl, function() self:_footnoteScanStep(dl) end)
        return
    end
    -- Other jobs scanned each chapter while downloading it.
    self:_footnoteScanStep(dl)
end

-- Scan phase of the finalize pipeline: collect the per-chapter footnote scans
-- for the book-wide index. Resumable jobs read and scan their checkpoints
-- here (the download loop skips it) and yield to the UI whenever a batch
-- has used FINALIZE_BATCH_BUDGET_MS. The transform phase continues in the
-- same batch while its budget lasts.
function Downloader:_footnoteScanStep(dl)
    if dl.cancelled then
        self:_stopCancelled(dl)
        return
    end
    local job = dl.footnote_scan_job
    local chapters = job.chapters
    local total = #chapters
    local batch_started = self:_now()
    while job.index <= total do
        local chapter_index = job.index
        local chapter = chapters[chapter_index]
        local uid = tostring(chapter.chapterUid or chapter_index)
        if dl.resumable then
            local body = Content.load_full_download_chapter(
                dl.workspace, chapter, chapter_index)
            local scan_ok, scan = pcall(Footnotes.scan_chapter, body, chapter)
            if scan_ok then
                dl.footnote_scans[uid] = scan
            else
                logger.warn("checkpoint footnote scan failed; keeping original chapter:",
                    "chapter_uid=", uid, "error=", log_error(scan))
            end
        end
        if dl.footnote_scans[uid] then
            job.scans[uid] = dl.footnote_scans[uid]
        end
        job.index = chapter_index + 1
        if dl.resumable and job.index <= total and self:_batchSpent(batch_started) then
            self:_setStage(dl,
                T(_("Scanning footnotes · chapter %1/%2"),
                    tostring(job.index - 1), tostring(total)), dl.total)
            self:_yieldFinalize(dl, function() self:_footnoteScanStep(dl) end)
            return
        end
    end
    dl.footnote_scan_job = nil
    dl.footnote_job = {
        index = 1,
        chapters = chapters,
        index_data = Footnotes.build_book_index(job.scans, chapters),
        css_needed = false,
    }
    if self:_batchSpent(batch_started) then
        self:_yieldFinalize(dl, function() self:_footnoteStep(dl) end)
        return
    end
    self:_footnoteStep(dl, batch_started)
end

function Downloader:_finishChapter(dl)
    if dl.cancelled then self:_step(dl); return end
    if not dl.current then return end
    local chapter = dl.current.chapter
    local ok, result
    if dl.current.finalized then
        -- The worker already fetched the images together with the text.
        ok, result = true, {
            xhtml = dl.current.xhtml, assets = dl.current.assets, state = dl.state,
        }
    else
        local cache = self.settings:get("cache") or {}
        local stage_text
        if cache.download_book_images then
            stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
        else
            stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
        end
        self:_setStage(dl,
            stage_text, dl.index - 0.1)
        local started = time.now()
        ok, result = pcall(function()
            local function finalize()
                local xhtml, assets = Content.finalize_single_chapter_content(
                    self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state)
                return { xhtml = xhtml, assets = assets, state = dl.state }
            end
            -- Only reached when images were enabled after the source was
            -- fetched without them; the normal image path never forks here.
            if cache.download_book_images then return self:_runInterruptible(dl, finalize) end
            return finalize()
        end)
        if dl.cancelled then self:_step(dl); return end
        self:_perf(dl, "images_and_finalize", started, "ok=", tostring(ok))
        if not ok then
            self:_failChapter(dl, result)
            return
        end
    end
    local xhtml, chapter_assets = result.xhtml, result.assets
    dl.state = result.state
    local uid = tostring(chapter.chapterUid or dl.index)
    if dl.resumable then
        -- The stylesheet comes with the first chapter; rewrite it only when
        -- it changed instead of once per chapter.
        if dl.state.css ~= dl.saved_css then
            Content.save_full_download_css(dl.workspace, dl.state.css)
            dl.saved_css = dl.state.css
        end
        Content.save_full_download_chapter(dl.workspace, chapter, dl.index, xhtml)
        dl.completed[dl.index] = true
        dl.completed_count = dl.completed_count + 1
    else
        dl.bodies[uid] = xhtml
    end
    dl.assets_by_uid = dl.assets_by_uid or {}
    dl.assets_by_uid[uid] = chapter_assets or {}
    table.insert(dl.selected, chapter)
    if not dl.resumable then
        for _i, asset in ipairs(chapter_assets or {}) do
            table.insert(dl.assets, asset)
            dl.asset_bytes = (dl.asset_bytes or 0) + (tonumber(asset.size) or 0)
        end
    end
    local mem_available_kb, rss_kb = self:_memorySnapshot()
    logger.info("download assets staged:",
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_assets=", tostring(#(chapter_assets or {})),
        "total_asset_bytes=", tostring(dl.asset_bytes or 0),
        "lua_kb=", string.format("%.1f", collectgarbage("count")),
        "mem_available_kb=", tostring(mem_available_kb or "unknown"),
        "rss_kb=", tostring(rss_kb or "unknown"))
    dl.current = nil
    dl.annotation = nil
    dl.consecutive_transport_failures = 0
    dl.consecutive_chapter_failures = 0
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    -- Trapper already yielded to the real UI loop while waiting for this
    -- chapter's worker (at least its 125 ms poll interval). Starting the next
    -- worker in the same coroutine avoids another idle 100 ms per chapter.
    -- Tail calls here and in _step keep the coroutine stack bounded.
    local co, is_main = coroutine.running()
    if dl.trapper and co and not is_main then return self:_step(dl) end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

-- Record the downloaded EPUB(s) on the book. Runs under pcall in _step.
function Downloader:_persistDownloadResult(dl, ok, path, chapter_paths)
    local book_id = dl.book.book_id or dl.book.bookId
    if not book_id then return end
    local record, books = load_book_record(self.settings, book_id, false)
    if not record then
        record = {}
        for key, value in pairs(dl.book) do record[key] = value end
    end
    local function apply_cache_result(target)
        target.annotation_documents = dl.book.annotation_documents or target.annotation_documents
        target.cached_chapters = target.cached_chapters or {}
        if not ok then return end
        if dl.single_chapter then
            local chapter = dl.selected[1]
            target.cached_chapters[tostring(chapter.chapterUid or 1)] = path
        elseif dl.separate_chapters then
            for chapter_index, chapter in ipairs(dl.selected) do
                local uid = tostring(chapter.chapterUid or chapter_index)
                target.cached_chapters[uid] = chapter_paths[uid]
            end
        else
            local previous_full = target.cached_full_book
                or target.cached_file
            for uid, cached_path in pairs(target.cached_chapters) do
                if cached_path == previous_full or cached_path == path then
                    target.cached_chapters[uid] = nil
                end
            end
            target.cached_full_book = path
            -- Keep cached_file as a compatibility alias for existing
            -- installs and cache-management code. Single/partial
            -- downloads must never overwrite it.
            target.cached_file = path
        end
    end

    apply_cache_result(dl.book)
    if record ~= dl.book then apply_cache_result(record) end
    record.cache_dir = dl.book.cache_dir or record.cache_dir
    record.reader_url = record.reader_url
        or dl.book.reader_url or WeRead.reader_url(book_id)
    dl.book.reader_url = dl.book.reader_url or record.reader_url
    save_book_record(self.settings, book_id, record, books)
end

function Downloader:_step(dl)
    if dl.cancelled then
        self:_stopCancelled(dl)
        return
    end

    if dl.index > dl.total then
        if #dl.selected == 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            logger.err("book download failed: no chapters downloaded")
            self:_notifyCompletion(dl, false, "no_chapters_downloaded")
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(_("No chapters were downloaded."))
            end
            return
        end
        -- A full-book cache must be complete. Saving the chapters that happened
        -- to succeed under the stable `full.epub` path makes KOReader present a
        -- structurally valid but truncated book and replaces any previous good
        -- cache. Explicit single- or multi-chapter jobs remain best-effort.
        if dl.suffix == "full" and #dl.failed > 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            if dl.resumable then
                self:_preserveWorkspace(dl, "incomplete_full_book")
            else
                self:_releaseStandby(dl)
                self:_cleanupWorkspace(dl)
            end
            logger.warn(
                "full-book download aborted after chapter failures:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed),
                "total=", tostring(dl.total)
            )
            if not dl.resumable then
                self:_notifyCompletion(dl, false, "incomplete_full_book")
                self:_finishJob(dl)
            end
            if not dl.prefetch then
                local message = dl.resumable
                    and "Full-book download paused: %1 of %2 chapters failed.\n\nCompleted chapters were kept. Choose Download full book again to continue."
                    or "Full-book download stopped: %1 of %2 chapters failed.\n\nNo incomplete EPUB was saved. Please retry the download."
                self.show_info(T(_(message), tostring(#dl.failed), tostring(dl.total)))
            end
            return
        end
        -- The in-memory completion map is only an optimization for skipping
        -- chapters. Before packaging, read every checkpoint marker again so a
        -- partially written or externally removed chapter can never result in
        -- a truncated EPUB.
        if dl.resumable and not dl.workspace_verified then
            local completed_count = self:_restoreFullDownloadCheckpoint(dl)
            if completed_count < dl.total then
                -- A chapter that keeps "saving" without verifying (full
                -- storage, broken directory entry, ...) would otherwise be
                -- downloaded again forever (F11).
                dl.verify_passes = (dl.verify_passes or 0) + 1
                if dl.verify_passes > MAX_VERIFY_REDOWNLOAD_PASSES then
                    logger.warn("full-book download paused: chapters do not verify:",
                        "completed=", tostring(completed_count),
                        "total=", tostring(dl.total),
                        "passes=", tostring(dl.verify_passes - 1))
                    self:_preserveWorkspace(dl, "verification_failed")
                    if not dl.prefetch then
                        self.show_info(T(_("Full-book download paused: %1 of %2 chapters could not be verified after downloading them again.\n\nCompleted chapters were kept. Choose Download full book again to retry."),
                            tostring(dl.total - completed_count), tostring(dl.total)))
                    end
                    return
                end
                for chapter_index = 1, dl.total do
                    if not dl.completed[chapter_index] then
                        dl.index = chapter_index
                        break
                    end
                end
                dl.footnote_scans = {}
                dl.footnotes_done = false
                self:_setStage(dl,
                    T(_("Verifying downloaded chapters %1/%2"),
                        tostring(completed_count), tostring(dl.total)),
                    completed_count)
                self:_scheduleGuarded(dl, function() self:_step(dl) end)
                return
            end
            dl.workspace_verified = true
        end
        if dl.footnote_scans and not dl.footnotes_done then
            self:_startFootnotes(dl)
            return
        end
        self:_setStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local ok, path, chapter_paths = pcall(function()
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, dl.bodies[uid],
                    (dl.assets_by_uid and dl.assets_by_uid[uid]) or dl.assets,
                    dl.state.css
                )
            end
            if dl.separate_chapters then
                local paths = {}
                for chapter_index, chapter in ipairs(dl.selected) do
                    local uid = tostring(chapter.chapterUid or chapter_index)
                    paths[uid] = Content.save_chapter_epub(
                        self.settings, dl.book, chapter, dl.bodies[uid],
                        (dl.assets_by_uid and dl.assets_by_uid[uid]) or {},
                        dl.state.css
                    )
                end
                return paths[tostring(dl.selected[1].chapterUid or 1)], paths
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function()
                    cover_data = self:_runInterruptible(dl, function()
                        return self.client:get_binary(cover_url)
                    end)
                end)
            end
            if dl.cancelled then return end
            if dl.resumable then
                for chapter_index, chapter in ipairs(dl.chapters) do
                    if not Content.full_download_rendered_chapter_exists(
                        dl.workspace, chapter, chapter_index) then
                        error("missing rendered chapter " .. tostring(chapter_index))
                    end
                end
            end
            return Content.save_book_epub(
                self.settings, dl.book,
                dl.resumable and dl.chapters or dl.selected,
                dl.resumable and { __workspace_text_dir = dl.workspace.rendered_text_dir } or dl.bodies,
                dl.suffix,
                dl.resumable and Content.full_download_workspace_assets(dl.workspace) or dl.assets,
                dl.state.css, cover_data
            )
        end)
        if dl.cancelled then self:_step(dl); return end
        if ok then
            self:_cleanupWorkspace(dl)
        end
        self:_perf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        -- Persist first and release the standby guard afterwards. A throw
        -- while saving the book record or refreshing the shelf must not stop
        -- the job from reporting completion (_active_job would stay set).
        local persisted, persist_err = pcall(self._persistDownloadResult,
            self, dl, ok, path, chapter_paths)
        if not persisted then
            logger.err("download result persistence failed:", log_error(persist_err))
        end
        local refreshed, refresh_err = pcall(self.refresh_shelf)
        if not refreshed then
            logger.warn("shelf refresh after download failed:", log_error(refresh_err))
        end
        self:_releaseStandby(dl)
        if not ok then
            logger.err("save downloaded book failed:", log_error(path))
            self:_notifyCompletion(dl, false, path)
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(path)))
            end
            return
        end
        -- Add only a combined full-book EPUB to the local collection. In
        -- separate-chapter mode `path` is an individual chapter EPUB.
        if not dl.single_chapter and not dl.separate_chapters then
            pcall(function()
                local ReadCollection = require("readcollection")
                local COLLECTION_NAME = self.settings.collection_name or "weread"
                if not ReadCollection.coll then
                    ReadCollection:_read()
                end
                if not ReadCollection.coll[COLLECTION_NAME] then
                    ReadCollection:addCollection(COLLECTION_NAME)
                end
                if not ReadCollection:isFileInCollection(path, COLLECTION_NAME) then
                    ReadCollection:addItem(path, COLLECTION_NAME)
                    ReadCollection:write({ [COLLECTION_NAME] = true })
                end
            end)
        end
        if #dl.failed > 0 then
            logger.warn(
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info("book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end
        if dl.footnote_stats and dl.footnote_stats.unresolved > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 footnote reference(s) could not be resolved and were kept as original links."),
                tostring(dl.footnote_stats.unresolved)
            )
        end
        if dl.footnote_stats and dl.footnote_stats.fallback > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 chapter(s) kept their original footnote markup after validation fallback."),
                tostring(dl.footnote_stats.fallback)
            )
        end
        self:_perf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches),
            "footnotes_converted=", tostring(dl.footnote_stats and dl.footnote_stats.converted or 0),
            "footnotes_unresolved=", tostring(dl.footnote_stats and dl.footnote_stats.unresolved or 0))
        if dl.open_on_complete then
            self:_notifyCompletion(dl, true, path)
            self:_finishJob(dl)
            self.open_file(path)
            return
        end
        self:_notifyCompletion(dl, true, path)
        self:_finishJob(dl)
        if dl.silent_completion then
            return
        end
        if not dl.offer_read then
            self.show_transient(
                T(_("Downloaded %1 chapters."), tostring(#dl.selected)), 2)
            return
        end
        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = self.safe_callback(_("Read now"), function()
                self.open_file(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    if dl.resumable and self:_skipCompletedChapterBatch(dl) then return end

    local chapter = dl.chapters[dl.index]
    local cache = self.settings.get and self.settings:get("cache", {}) or {}
    local with_images = cache.download_book_images and true or false
    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)
    local started = time.now()
    local ok, result = pcall(function()
        return self:_runInterruptible(dl, function()
            local xhtml = Content.fetch_single_chapter_source(
                self.client, self.settings, dl.book, chapter, dl.state)
            local value = { xhtml = xhtml, state = dl.state, book = reader_book(dl.book) }
            if with_images then
                -- Fetch the images in the same worker: one fork per chapter
                -- instead of two, and the source text never crosses the pipe.
                value.xhtml, value.assets = Content.finalize_single_chapter_content(
                    self.client, self.settings, dl.book, chapter, xhtml, dl.state)
                value.finalized = true
            end
            return value
        end)
    end)
    if dl.cancelled then self:_step(dl); return end
    self:_perf(dl, with_images and "chapter_source_and_images" or "chapter_source",
        started, "ok=", tostring(ok))
    if not ok then
        self:_retryChapterSource(dl, result)
        return
    end
    local xhtml = result.xhtml
    dl.state = result.state
    apply_reader_book(dl.book, result.book)
    if dl.chapter_source_retries then
        dl.chapter_source_retries[tostring(chapter.chapterUid or dl.index)] = nil
    end
    -- Resumable jobs rescan every checkpoint from disk in _startFootnotes, so
    -- scanning here on the UI loop would only be thrown away.
    if not dl.resumable then
        local uid = tostring(chapter.chapterUid or dl.index)
        local scan_ok, scan = pcall(Footnotes.scan_chapter, xhtml, chapter)
        dl.footnote_scans = dl.footnote_scans or {}
        if scan_ok then
            dl.footnote_scans[uid] = scan
        else
            logger.warn("footnote scan failed; chapter will keep original footnote markup:",
                "chapter_uid=", uid, "error=", log_error(scan))
        end
    end
    dl.current = {
        chapter = chapter,
        xhtml = xhtml,
        assets = result.assets,
        finalized = result.finalized == true,
    }
    return self:_finishChapter(dl)
end

return Downloader
