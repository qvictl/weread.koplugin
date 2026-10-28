-- Edge paths of the download engine: prefetch scheduling conflicts, worker
-- results/failures, guarded-step failure handling, chapter failure and
-- cancellation at every phase, footnote fallbacks, completion reporting and
-- legacy book-record persistence. Run from the repo root with:
--   luajit spec/downloader_edge_paths_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local scheduled = {}
local shown = {}
local dialogs = {}
local standby = { prevented = 0, allowed = 0 }

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
        unschedule = function() end,
        show = function(_self, widget) shown[#shown + 1] = widget end,
        preventStandby = function() standby.prevented = standby.prevented + 1 end,
        allowStandby = function() standby.allowed = standby.allowed + 1 end,
    }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
    }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            local dialog = {
                options = options,
                title = options.title,
                titles = { options.title },
                progress = {},
                closes = 0,
            }
            function dialog:show() self.visible = true end
            function dialog:close()
                self.closes = self.closes + 1
                self.visible = false
                if self.fail_close then error("dialog widget already freed") end
            end
            function dialog:setTitle(title)
                self.title = title
                self.titles[#self.titles + 1] = title
            end
            function dialog:reportProgress(value) self.progress[#self.progress + 1] = value end
            dialogs[#dialogs + 1] = dialog
            return dialog
        end,
    }
end

local Footnotes = { FOOTNOTES_CSS = "/*footnotes*/" }
package.preload["weread.lib.footnotes"] = function() return Footnotes end
local function reset_footnotes()
    Footnotes.scan_chapter = function(_body, chapter) return { uid = chapter.chapterUid } end
    Footnotes.transform_chapter = function(body) return body, { converted = 0 } end
    Footnotes.validate = function() return true end
    Footnotes.has_converted = function(stats) return (stats and stats.converted or 0) > 0 end
    Footnotes.build_book_index = function(scans) return { scans = scans } end
end
reset_footnotes()

local chapter_worker_calls = {}
package.preload["weread.lib.chapter_prefetch_worker"] = function()
    return {
        run = function(settings, client, book, chapter, context)
            chapter_worker_calls[#chapter_worker_calls + 1] = {
                settings = settings, client = client, book = book,
                chapter = chapter, context = context,
            }
            return { path = "/from/worker.epub" }
        end,
    }
end

local Content = {}
package.preload["weread.lib.content"] = function() return Content end
local cleaned_workspaces = {}
local function reset_content()
    for key in pairs(Content) do Content[key] = nil end
    cleaned_workspaces = {}
    Content.ensure_reader_state = function() end
    Content.cleanup_download_workspace = function(workspace)
        cleaned_workspaces[#cleaned_workspaces + 1] = workspace
    end
    Content.create_download_workspace = function() return { kind = "plain" } end
    Content.fetch_single_chapter_source = function(_client, _settings, _book, chapter)
        return "<p>" .. tostring(chapter.chapterUid) .. "</p>"
    end
    Content.finalize_single_chapter_content = function(_c, _s, _b, _chapter, xhtml)
        return xhtml, {}
    end
    Content.save_chapter_epub = function(_settings, _book, chapter)
        return "/cache/book/chapter-" .. tostring(chapter.chapterUid) .. ".epub"
    end
end
reset_content()

local Downloader = require("weread.lib.downloader")

local function run_scheduled()
    local entry = table.remove(scheduled, 1)
    if entry then entry.callback() end
    return entry
end
local function drain(limit)
    local steps = 0
    while #scheduled > 0 and steps < (limit or 200) do
        steps = steps + 1
        run_scheduled()
    end
    return steps
end

local function legacy_settings(values)
    values = values or {}
    values.books = values.books or {}
    values.cache = values.cache or {}
    local settings = { values = values, flushes = 0 }
    function settings:get(key, default)
        local value = values[key]
        if value == nil then return default end
        return value
    end
    function settings:set(key, value) values[key] = value end
    function settings:flush() self.flushes = self.flushes + 1 end
    return settings
end

local function fake_worker()
    local worker = { starts = {}, cancels = {}, is_available = true }
    function worker:available() return self.is_available end
    function worker:start(options)
        local handle = { options = options }
        self.starts[#self.starts + 1] = handle
        if self.refuse then
            options.on_done { ok = false, error = self.refuse }
            return false, self.refuse
        end
        if options.on_launch then options.on_launch(4242, 128 * 1024) end
        return true, handle
    end
    function worker:cancel(handle, reason)
        self.cancels[#self.cancels + 1] = { handle = handle, reason = reason }
        return true
    end
    return worker
end

local messages, transients, opened, online_labels
local function new_downloader(overrides)
    messages, transients, opened, online_labels = {}, {}, {}, {}
    local options = {
        client = { name = "client" },
        settings = legacy_settings(),
        is_connected = function() return true end,
        require_login = function() return true end,
        run_online_task = function(label, callback)
            online_labels[#online_labels + 1] = label
            callback()
            return true
        end,
        show_info = function(text) messages[#messages + 1] = text end,
        show_transient = function(text) transients[#transients + 1] = text end,
        refresh_ui = function() end,
        refresh_shelf = function() end,
        open_file = function(path) opened[#opened + 1] = path end,
        safe_callback = function(_label, callback) return callback end,
    }
    for key, value in pairs(overrides or {}) do options[key] = value end
    return Downloader:new(options)
end

local function recorder()
    local calls = {}
    return calls, function(ok, value) calls[#calls + 1] = { ok = ok, value = value } end
end

local book = { book_id = "book", title = "Book" }
local ch1 = { chapterUid = 1, title = "One" }
local ch2 = { chapterUid = 2, title = "Two" }
local ch3 = { chapterUid = 3, title = "Three" }

local function start_prefetch(d, chapter, options)
    options = options or {}
    options.prefetch = true
    options.single_chapter = true
    local started = d:start(options.book or book, { chapter }, "chapter", options)
    run_scheduled()
    return started
end

---------------------------------------------------------------------------
-- Prefetch start guards: offline and logged-out prefetches never start.
do
    scheduled = {}
    local d = new_downloader { is_connected = function() return false end }
    local calls, on_complete = recorder()
    expect(d:start(book, { ch2 }, "chapter", {
        prefetch = true, on_complete = on_complete,
    }) == false, "offline prefetch started")
    expect(#calls == 1 and calls[1].ok == false and calls[1].value == "offline",
        "offline prefetch did not report offline")
    expect(d._active_job == nil and #scheduled == 0, "offline prefetch left work behind")

    d = new_downloader()
    d.settings.is_cookie_configured = function() return false end
    calls, on_complete = recorder()
    expect(d:start(book, { ch2 }, "chapter", {
        prefetch = true, on_complete = on_complete,
    }) == false, "logged-out prefetch started")
    expect(calls[1] and calls[1].value == "authentication_required",
        "logged-out prefetch did not ask for authentication")
    expect(d._active_job == nil and #scheduled == 0 and #messages == 0,
        "logged-out prefetch left work behind or bothered the user")

    -- A throwing on_start must not stop the prefetch from being scheduled.
    d = new_downloader { background_worker = fake_worker() }
    expect(d:start(book, { ch2 }, "chapter", {
        prefetch = true, on_start = function() error("notice widget gone") end,
    }) == true and #scheduled == 1, "throwing on_start blocked the prefetch")
    expect(d._active_job.start_notified == true, "start notice was not recorded")
    scheduled = {}
end

---------------------------------------------------------------------------
-- A manual download pre-empts an active prefetch and runs once it stops.
do
    scheduled = {}
    local worker = fake_worker()
    local d = new_downloader { background_worker = worker }
    local labels_after_init
    d.run_online_task = function(label, callback)
        online_labels[#online_labels + 1] = label
        labels_after_init = callback
        return true
    end
    local prefetch_calls, prefetch_done = recorder()
    start_prefetch(d, ch2, { on_complete = prefetch_done })
    expect(#worker.starts == 1 and d._standby_ref == 1, "prefetch worker did not launch")

    local manual_calls, manual_done = recorder()
    expect(d:start(book, { ch1, ch2 }, "full", { on_complete = manual_done }) == true,
        "manual download was not queued behind the prefetch")
    expect(worker.cancels[1] and worker.cancels[1].reason == "manual_download",
        "active prefetch worker was not cancelled for the manual download")
    expect(d._active_job.cancelled and d._pending_start
        and d._pending_start.suffix == "full", "manual download was not left pending")
    expect(#online_labels == 0, "manual download started before the prefetch stopped")

    worker.starts[1].options.on_done { ok = false, cancelled = true, error = "manual_download" }
    expect(prefetch_calls[1] and prefetch_calls[1].ok == false
        and prefetch_calls[1].value == "manual_download",
        "pre-empted prefetch did not report why it stopped")
    expect(d._active_job == nil and d._scheduled_start ~= nil and d._standby_ref == 0,
        "pre-empted prefetch did not hand over to the manual download")

    -- While the manual download sits in the start slot, others are refused.
    expect(d:start(book, { ch3 }, "chapter", {}) == false
        and transients[#transients]:find("already in progress", 1, true),
        "second manual download was not refused while one is scheduled")
    local transients_before = #transients
    expect(d:start(book, { ch3 }, "chapter", { prefetch = true }) == false
        and #transients == transients_before,
        "prefetch was not silently refused while a manual download is scheduled")

    run_scheduled()
    expect(#online_labels == 1 and d._active_job and not d._active_job.prefetch
        and d._active_job.suffix == "full", "scheduled manual download did not start")

    -- A prefetch while a manual download runs is refused and not queued.
    expect(d:start(book, { ch3 }, "chapter", { prefetch = true }) == false
        and d._pending_start == nil, "prefetch was queued behind a manual download")

    -- Cancel the manual download before its initialization runs.
    local job = d._active_job
    job.progress_dialog.options.buttons[1][1].callback()
    labels_after_init()
    expect(manual_calls[1] and manual_calls[1].ok == false
        and manual_calls[1].value == "cancelled" and d._active_job == nil,
        "manual download cancelled before initialization was not finished")
    expect(#manual_calls == 1, "cancelled manual download reported twice")
    scheduled = {}
end

---------------------------------------------------------------------------
-- A scheduled prefetch is dropped when a manual download starts, and a
-- document close drops a pending prefetch that never launched.
do
    scheduled = {}
    local worker = fake_worker()
    local d = new_downloader { background_worker = worker }
    d.run_online_task = function(label) online_labels[#online_labels + 1] = label; return true end
    start_prefetch(d, ch2)
    expect(d:start(book, { ch3 }, "chapter", { prefetch = true, single_chapter = true }),
        "replacement prefetch was not accepted")
    expect(worker.cancels[1].reason == "replaced", "old prefetch was not replaced")
    worker.starts[1].options.on_done { ok = false, cancelled = true, error = "replaced" }
    expect(d._scheduled_start and d._scheduled_start.pending.chapters[1] == ch3,
        "replacement prefetch was not scheduled")

    expect(d:start(book, { ch1 }, "chapter", { single_chapter = true }) == true,
        "manual download did not displace the scheduled prefetch")
    expect(d._scheduled_start == nil and d._active_job and not d._active_job.prefetch,
        "scheduled prefetch survived the manual download")
    drain()
    expect(#worker.starts == 1, "dropped prefetch still launched a worker")
    expect(online_labels[1] == "Download chapter and read",
        "single-chapter download used the wrong task label")

    scheduled = {}
    worker = fake_worker()
    d = new_downloader { background_worker = worker }
    start_prefetch(d, ch2)
    d:start(book, { ch3 }, "chapter", { prefetch = true, single_chapter = true })
    expect(d._pending_start ~= nil, "replacement prefetch was not pending")
    d:cancelPrefetch("document_closed")
    expect(d._pending_start == nil, "document close kept the pending prefetch")
    worker.starts[1].options.on_done { ok = false, cancelled = true, error = "replaced" }
    expect(d._active_job == nil and d._scheduled_start == nil and #scheduled == 0,
        "pending prefetch restarted after the document was closed")
    expect(#worker.starts == 1, "a worker launched for a dropped prefetch")
end

---------------------------------------------------------------------------
-- Worker wiring: unavailable/refused workers, task arguments, progress
-- stages, stale callbacks and the promoted-dialog cancel button.
do
    scheduled = {}
    local worker = fake_worker()
    worker.is_available = false
    local d = new_downloader { background_worker = worker }
    local calls, on_complete = recorder()
    start_prefetch(d, ch2, { on_complete = on_complete })
    expect(calls[1] and calls[1].value == "worker_unavailable" and d._active_job == nil,
        "missing worker was not reported")
    expect(#worker.starts == 0, "unavailable worker was started")

    worker = fake_worker()
    worker.refuse = "low_memory"
    d = new_downloader { background_worker = worker }
    calls, on_complete = recorder()
    start_prefetch(d, ch2, { on_complete = on_complete })
    expect(calls[1] and calls[1].ok == false and calls[1].value == "low_memory",
        "refused worker launch was not reported")
    expect(d._active_job == nil and (d._standby_ref or 0) == 0,
        "refused worker launch left the job or standby guard behind")

    worker = fake_worker()
    d = new_downloader { background_worker = worker }
    calls, on_complete = recorder()
    start_prefetch(d, ch2, { on_complete = on_complete })
    local handle = worker.starts[1]
    local options = handle.options
    expect(options.kind == "chapter" and options.queue == true and options.timeout == 180,
        "chapter worker options changed")
    local context = { token = "t" }
    expect(options.task(context).path == "/from/worker.epub", "task result was not returned")
    local call = chapter_worker_calls[#chapter_worker_calls]
    expect(call.settings == d.settings and call.client == d.client
        and call.book.book_id == "book" and call.chapter == ch2 and call.context == context,
        "chapter worker did not receive the job's settings/client/book/chapter/context")

    -- Progress before promotion is remembered and painted on promotion.
    local job = d._active_job
    options.on_progress { stage = "reader" }
    expect(job.stage_title == "Preparing chapter 1/1", "reader stage title: " .. tostring(job.stage_title))
    options.on_progress { stage = "source" }
    expect(job.stage_title == "Downloading chapter 1/1: Two", "source stage title: " .. tostring(job.stage_title))
    options.on_progress { stage = "source", attempt = 3 }
    expect(job.stage_title == "Retrying chapter 1/1 · attempt 2", "retry stage title: " .. tostring(job.stage_title))
    options.on_progress { stage = "images" }
    expect(job.stage_title:find("Downloading images", 1, true), "images stage title")
    options.on_progress { stage = "footnotes" }
    expect(job.stage_title:find("Processing footnotes", 1, true), "footnotes stage title")
    options.on_progress { stage = "mystery" }
    expect(job.stage_title == "Processing chapter 1/1" and job.stage_progress == 0,
        "unknown stage did not fall back to a generic title")
    options.on_progress { stage = "epub" }
    expect(job.stage_title == "Building EPUB..." and job.stage_progress == 1,
        "epub stage did not report completion progress")
    expect(job.progress_dialog == nil, "background prefetch opened a dialog")
    expect(d:promotePrefetch(book, ch2), "matching prefetch did not promote")
    local dialog = job.progress_dialog
    expect(dialog.title == "Building EPUB..." and dialog.progress[1] == 1,
        "promoted dialog did not show the current stage and progress")
    options.on_progress { stage = "images" }
    expect(dialog.title:find("Downloading images", 1, true),
        "progress after promotion did not update the dialog")

    -- The promoted dialog's cancel button cancels the prefetch worker.
    dialog.options.buttons[1][1].callback()
    expect(job.cancelled and job.cancel_reason == "cancelled",
        "dialog cancel did not cancel the prefetch")
    expect(worker.cancels[1] and worker.cancels[1].handle == handle
        and worker.cancels[1].reason == "cancelled", "dialog cancel did not stop the worker")
    expect(not dialog.visible and job.progress_dialog == nil, "dialog stayed open after cancel")
    options.on_done { ok = false, cancelled = true, error = "cancelled" }
    expect(calls[1] and calls[1].ok == false and calls[1].value == "cancelled",
        "cancelled promoted prefetch did not report cancellation")
    expect(#opened == 0 and d._active_job == nil and d._standby_ref == 0,
        "cancelled promoted prefetch opened a file or leaked state")

    -- Callbacks from a superseded worker must not touch the new state.
    local before_titles = job.stage_title
    options.on_progress { stage = "reader" }
    expect(job.stage_title == before_titles, "stale progress updated a finished job")
    options.on_launch(9999, 1)
    expect(d._standby_ref == 0, "stale launch acquired the standby guard")
    options.on_done { ok = true, value = { path = "/late.epub" } }
    expect(#calls == 1 and #opened == 0, "stale result was reported twice")
end

---------------------------------------------------------------------------
-- Worker results: success persists the chapter (legacy settings map with a
-- numeric book key), failures and timeouts are reported without writes.
do
    scheduled = {}
    local path = os.tmpname()
    local handle = assert(io.open(path, "wb"))
    handle:write("epub")
    handle:close()

    local auth_updates = {}
    local settings = legacy_settings {
        books = { [123] = { book_id = 123, title = "Stored", progress = 40,
            cached_chapters = { ["1"] = "/old/1.epub" } } },
        cookies = { wr_skey = "parent" },
    }
    settings.update_auth = function(_self, auth, opts)
        auth_updates[#auth_updates + 1] = { auth = auth, opts = opts }
    end
    local worker = fake_worker()
    local shelf_refreshes = 0
    local d = new_downloader {
        background_worker = worker, settings = settings,
        refresh_shelf = function() shelf_refreshes = shelf_refreshes + 1 end,
    }
    local numeric_book = { book_id = "123", title = "Numeric" }
    local calls, on_complete = recorder()
    start_prefetch(d, ch2, { book = numeric_book, on_complete = on_complete })
    expect(d:promotePrefetch(numeric_book, ch2), "numeric prefetch did not promote")
    local dialog = d._active_job.progress_dialog
    worker.starts[1].options.on_done {
        ok = true,
        value = {
            path = path, chapter_uid = "2", cache_dir = "/cache/123",
            reader_url = "https://reader/123",
            annotation_document = { marks = 3 },
            auth = { cookies = { wr_skey = "fresh" } },
        },
    }
    local stored = settings.values.books["123"]
    expect(stored and stored.title == "Stored" and stored.progress == 40,
        "numeric-keyed legacy record was not reused")
    expect(stored.cached_chapters["2"] == path and stored.cached_chapters["1"] == "/old/1.epub",
        "prefetched chapter was not added to the stored record")
    expect(stored.cache_dir == "/cache/123" and stored.reader_url == "https://reader/123"
        and stored.annotation_documents[path].marks == 3,
        "worker metadata was not persisted")
    expect(numeric_book.cached_chapters["2"] == path, "live book was not updated")
    expect(settings.flushes >= 1 and shelf_refreshes == 1, "result was not flushed or shown")
    expect(#auth_updates == 1 and auth_updates[1].auth.cookies.wr_skey == "fresh"
        and auth_updates[1].opts.replace_cookies == true,
        "refreshed worker credentials were not written back")
    expect(calls[1] and calls[1].ok == true and calls[1].value == path,
        "successful prefetch did not report its path")
    expect(opened[1] == path and not dialog.visible, "promoted prefetch did not open the chapter")
    expect(d._active_job == nil and d._standby_ref == 0, "successful prefetch leaked state")

    -- Parent credentials changed while the worker ran: keep the parent's.
    start_prefetch(d, ch3, { book = numeric_book })
    settings.values.cookies = { wr_skey = "parent-relogin" }
    worker.starts[2].options.on_done {
        ok = true, value = { path = path, auth = { cookies = { wr_skey = "stale" } } },
    }
    expect(#auth_updates == 1, "stale worker credentials overwrote a newer login")
    expect(settings.values.books["123"].cached_chapters["3"] == path,
        "chapter uid did not fall back to the requested chapter")

    -- Failures: nothing is written, the reason is reported.
    local function failing(result)
        local before_flushes = settings.flushes
        local failure_calls, failure_done = recorder()
        start_prefetch(d, ch1, { book = numeric_book, on_complete = failure_done })
        worker.starts[#worker.starts].options.on_done(result)
        expect(settings.flushes == before_flushes, "failed prefetch wrote settings")
        expect(d._active_job == nil and d._standby_ref == 0, "failed prefetch leaked state")
        return failure_calls[1]
    end
    local timeout = failing { ok = false, error = "worker_timeout" }
    expect(timeout.ok == false and timeout.value == "worker_timeout", "timeout was not reported")
    local no_result = failing(nil)
    expect(no_result.ok == false and no_result.value == "worker_no_result",
        "missing worker result was not reported")
    local missing_file = failing { ok = true, value = { path = path .. ".missing" } }
    expect(missing_file.ok == false, "a result whose file is missing was accepted")
    local bad_value = failing { ok = true, value = "not a table" }
    expect(bad_value.ok == false, "malformed worker value was accepted")
    expect(numeric_book.cached_chapters["1"] == nil, "failed prefetch was cached")

    -- A completion callback that throws does not wedge the downloader.
    start_prefetch(d, ch1, { book = numeric_book,
        on_complete = function() error("listener gone") end })
    worker.starts[#worker.starts].options.on_done { ok = false, error = "worker_timeout" }
    expect(d._active_job == nil, "throwing completion callback left the job active")
    local launched = #worker.starts
    expect(start_prefetch(d, ch2, { book = numeric_book }) == true
        and #worker.starts == launched + 1,
        "downloader did not accept new work after a throwing callback")
    worker.starts[launched + 1].options.on_done { ok = false, error = "x" }
    os.remove(path)

    -- Per-book settings API: a numeric key is found through the fallback.
    local put = {}
    local per_book = {
        get = function(_self, _key, default) return default end,
        get_book = function(_self, id) return put[id] end,
        put_book = function(_self, id, record) put[id] = record end,
    }
    put[77] = { book_id = 77, title = "PerBook" }
    path = os.tmpname()
    handle = assert(io.open(path, "wb")); handle:write("x"); handle:close()
    worker = fake_worker()
    d = new_downloader { background_worker = worker, settings = per_book }
    start_prefetch(d, ch2, { book = { book_id = "77" } })
    worker.starts[1].options.on_done { ok = true, value = { path = path } }
    expect(put["77"] and put["77"].title == "PerBook" and put["77"].cached_chapters["2"] == path,
        "per-book numeric fallback did not reuse the stored record")
    os.remove(path)
end

---------------------------------------------------------------------------
-- Guarded step failures: low memory stops cleanly, resumable jobs keep their
-- checkpoint, and a failing cleanup still finishes the job.
do
    scheduled = {}
    local d = new_downloader()
    local function guarded_job(fields)
        local calls, on_complete = recorder()
        local dl = { book = book, chapters = { ch1 }, total = 1, index = 1, failed = {},
            selected = {}, standby_guard = true, on_complete = on_complete }
        for key, value in pairs(fields or {}) do dl[key] = value end
        d._active_job = dl
        d:_beginStandby()
        d:_ensureProgressDialog(dl)
        return dl, calls
    end

    local dl, calls = guarded_job { workspace = { kind = "plain" } }
    local dialog = dl.progress_dialog
    d:_scheduleGuarded(dl, function()
        error("weread_low_memory: available_kb=1 required_kb=2", 0)
    end)
    run_scheduled()
    expect(calls[1] and calls[1].ok == false and calls[1].value == "low_memory",
        "low memory in a step was not reported as low_memory")
    expect(not dialog.visible and d._active_job == nil and d._standby_ref == 0,
        "low-memory stop leaked the dialog, job or standby guard")
    expect(#cleaned_workspaces == 1, "low-memory stop kept a non-resumable workspace")
    expect(messages[#messages]:find("not enough free memory", 1, true),
        "low-memory stop was not explained")

    local workspace = { kind = "resumable" }
    dl, calls = guarded_job { resumable = true, workspace = workspace, completed_count = 3 }
    dialog = dl.progress_dialog
    d:_scheduleGuarded(dl, function() error("HTTP 500 from chapter endpoint") end)
    run_scheduled()
    expect(calls[1] and calls[1].ok == false
        and tostring(calls[1].value):find("HTTP 500", 1, true),
        "resumable step failure did not report the error")
    expect(#cleaned_workspaces == 1 and dl.workspace == workspace,
        "resumable step failure removed the checkpoint")
    expect(not dialog.visible and d._active_job == nil and d._standby_ref == 0,
        "resumable step failure leaked state")
    expect(messages[#messages]:find("HTTP 500", 1, true), "step failure was not shown")

    -- Long multi-line errors are shown as one bounded line.
    dl, calls = guarded_job()
    local long = ("x"):rep(700) .. "\nSECOND LINE"
    d:_scheduleGuarded(dl, function() error(long, 0) end)
    run_scheduled()
    local shown_text = messages[#messages]
    expect(not shown_text:find("SECOND LINE", 1, true) and #shown_text < 400
        and shown_text:find("xxxx", 1, true), "long error was not shortened for display")
    expect(tostring(calls[1].value):find(long, 1, true) == 1,
        "completion lost the full error")

    -- The cleanup itself throws (dialog already freed): still finish once.
    dl, calls = guarded_job()
    dialog = dl.progress_dialog
    dialog.fail_close = true
    d:_scheduleGuarded(dl, function() error("boom") end)
    run_scheduled()
    expect(#calls == 1 and calls[1].ok == false, "failed cleanup did not notify exactly once")
    expect(dl.progress_dialog == nil and dialog.closes == 2,
        "failed cleanup did not retry closing the dialog")
    expect(d._active_job == nil and d._standby_ref == 0,
        "failed cleanup left the job active or the device awake")

    -- Prefetch failures are silent.
    local before = #messages
    dl, calls = guarded_job { prefetch = true }
    d:_scheduleGuarded(dl, function() error("silent") end)
    run_scheduled()
    expect(#messages == before and calls[1].ok == false, "prefetch failure bothered the user")
end

---------------------------------------------------------------------------
-- Initialization failure reports through on_complete and the UI.
do
    scheduled = {}
    reset_content()
    Content.ensure_reader_state = function() error("reader session: HTTP 500") end
    local d = new_downloader()
    local calls, on_complete = recorder()
    expect(d:start(book, { ch1 }, "book", { on_complete = on_complete }) == true,
        "download did not start")
    expect(calls[1] and calls[1].ok == false
        and tostring(calls[1].value):find("HTTP 500", 1, true),
        "initialization failure was not reported")
    expect(#calls == 1 and d._active_job == nil and d._standby_ref == nil and #scheduled == 0,
        "initialization failure left work behind")
    expect(messages[1]:find("HTTP 500", 1, true) and not dialogs[#dialogs].visible,
        "initialization failure was not shown or left the dialog")
    reset_content()
end

---------------------------------------------------------------------------
-- Single-chapter download: a server error is retried, then the chapter is
-- given up, nothing is packaged and the image workspace is cleaned up.
do
    scheduled = {}
    reset_content()
    local fetches = 0
    Content.fetch_single_chapter_source = function()
        fetches = fetches + 1
        error("chapter endpoint: HTTP 500")
    end
    local packaged = 0
    Content.save_chapter_epub = function() packaged = packaged + 1 end
    local settings = legacy_settings { cache = { download_book_images = true } }
    local d = new_downloader { settings = settings }
    local calls, on_complete = recorder()
    expect(d:start(book, { ch2 }, "chapter", {
        single_chapter = true, open_on_complete = true, on_complete = on_complete,
    }), "single-chapter download did not start")
    local job = d._active_job
    local dialog = job.progress_dialog
    expect(job.workspace and job.workspace.kind == "plain", "image workspace was not created")
    local delays = {}
    while #scheduled > 0 do
        local entry = table.remove(scheduled, 1)
        delays[#delays + 1] = entry.delay
        entry.callback()
    end
    expect(fetches == 3, "server error was not retried twice: " .. fetches)
    expect(delays[2] < delays[3], "retry delay did not back off")
    expect(job.failed[1] == "2" and dialog.progress[#dialog.progress] == 1,
        "given-up chapter was not recorded in the progress")
    expect(packaged == 0 and #opened == 0, "an empty download was packaged or opened")
    expect(calls[1] and calls[1].ok == false and calls[1].value == "no_chapters_downloaded",
        "empty download did not report no_chapters_downloaded")
    expect(#cleaned_workspaces == 1 and cleaned_workspaces[1].kind == "plain",
        "failed download did not clean its workspace")
    expect(messages[#messages] == "No chapters were downloaded."
        and not dialog.visible and d._active_job == nil and d._standby_ref == 0,
        "empty download was not explained or leaked state")
    reset_content()
end

---------------------------------------------------------------------------
-- Resumable full book: one given-up chapter among successes pauses the job
-- with the checkpoint kept instead of packaging a truncated book.
do
    scheduled = {}
    reset_content()
    local saved = {}
    local workspace = { rendered_text_dir = "/ws/rendered" }
    Content.open_full_download_workspace = function() return workspace end
    Content.load_full_download_css = function() return "" end
    Content.full_download_workspace_used_asset_names = function() return {} end
    Content.full_download_completed_chapters = function() return {} end
    Content.save_full_download_chapter = function(_ws, _chapter, index) saved[#saved + 1] = index end
    Content.fetch_single_chapter_source = function(_c, _s, _b, chapter)
        if chapter.chapterUid == 2 then error("HTTP 500 server error") end
        return "<p>" .. chapter.chapterUid .. "</p>"
    end
    local packaged = 0
    Content.save_book_epub = function() packaged = packaged + 1 end
    local d = new_downloader()
    local calls, on_complete = recorder()
    expect(d:start(book, { ch1, ch2, ch3 }, "full", { on_complete = on_complete }),
        "resumable download did not start")
    drain()
    expect(#saved == 2 and saved[1] == 1 and saved[2] == 3,
        "successful chapters around the failure were not checkpointed")
    expect(packaged == 0, "truncated full book was packaged")
    expect(calls[1] and calls[1].value == "incomplete_full_book" and #calls == 1,
        "incomplete full book was not reported once")
    expect(#cleaned_workspaces == 0, "resumable checkpoint was removed")
    expect(messages[#messages]:find("paused", 1, true)
        and messages[#messages]:find("1 of 3", 1, true), "pause was not explained")
    expect(d._active_job == nil and d._standby_ref == 0, "paused job leaked state")
    reset_content()
end

---------------------------------------------------------------------------
-- Cancellation in the footnote phases.
do
    scheduled = {}
    reset_content()
    local d = new_downloader()
    local function footnote_job(fields)
        local calls, on_complete = recorder()
        local dl = { book = book, chapters = { ch1, ch2 }, total = 2, index = 3,
            selected = { ch1, ch2 }, bodies = {}, failed = {}, state = {},
            standby_guard = true, on_complete = on_complete,
            footnote_scans = {}, footnote_stats = { fallback = 0, unresolved = 0 } }
        for key, value in pairs(fields) do dl[key] = value end
        d._active_job = dl
        d:_beginStandby()
        return dl, calls
    end
    local workspace = { kind = "resumable" }
    local dl, calls = footnote_job { resumable = true, workspace = workspace, cancelled = true }
    d:_ensureProgressDialog(dl)
    local dialog = dl.progress_dialog
    d:_footnoteStep(dl)
    expect(calls[1] and calls[1].value == "cancelled" and #cleaned_workspaces == 0,
        "cancel during footnotes removed the checkpoint")
    expect(not dialog.visible and transients[#transients] == "Download cancelled"
        and d._standby_ref == 0, "cancel during footnotes was not finished")

    dl, calls = footnote_job { workspace = { kind = "plain" }, cancelled = true,
        cancel_reason = "cache_cleanup", footnote_scan_job = { index = 1, chapters = {}, scans = {} } }
    d:_footnoteScanStep(dl)
    expect(calls[1] and calls[1].value == "cache_cleanup" and #cleaned_workspaces == 1,
        "cancel during the footnote scan did not clean up with the cancel reason")
    expect(d._active_job == nil and d._standby_ref == 0, "cancelled scan leaked state")

    -- No footnote job: footnotes are marked done and the step continues.
    dl = footnote_job {}
    d:_footnoteStep(dl)
    expect(dl.footnotes_done == true and #scheduled == 1, "missing footnote job stalled")
    scheduled = {}
    d._active_job = nil
    d:_endStandby()
end

---------------------------------------------------------------------------
-- Footnote fallbacks keep the original chapter markup.
do
    scheduled = {}
    reset_content()
    local d = new_downloader()
    -- Non-resumable: transform throws for chapter 1, validation fails for 2.
    Footnotes.transform_chapter = function(body, scan)
        if scan.uid == 1 then error("bad footnote anchor") end
        return body .. "<broken>", { converted = 1 }
    end
    Footnotes.validate = function() return false, "unbalanced" end
    local dl = { book = book, chapters = { ch1, ch2 }, selected = { ch1, ch2 },
        bodies = { ["1"] = "<p>1</p>", ["2"] = "<p>2</p>" }, state = { css = "base" },
        total = 2, index = 3, failed = {},
        footnote_scans = { ["1"] = { uid = 1 }, ["2"] = { uid = 2 } },
        footnote_stats = { candidates = 0, converted = 0, image_notes = 0, backlinks = 0,
            removed_note_blocks = 0, unresolved = 0, fallback = 0 } }
    d:_startFootnotes(dl)
    drain(20)
    expect(dl.bodies["1"] == "<p>1</p>" and dl.bodies["2"] == "<p>2</p>",
        "failed footnote transforms changed the chapter bodies")
    expect(dl.footnote_stats.fallback == 2 and dl.footnotes_done == true,
        "footnote fallbacks were not counted")
    expect(dl.state.css == "base", "footnote CSS added although nothing converted")
    reset_footnotes()

    -- Resumable: a checkpoint that cannot be scanned is left out of the index.
    local indexed
    Footnotes.scan_chapter = function(body, chapter)
        if chapter.chapterUid == 2 then error("unparseable checkpoint") end
        return { body = body }
    end
    Footnotes.build_book_index = function(scans) indexed = scans; return {} end
    Content.reset_full_download_rendered_text = function() end
    Content.load_full_download_chapter = function(_ws, chapter)
        return "<p>cp " .. chapter.chapterUid .. "</p>"
    end
    local rendered = {}
    Content.save_full_download_rendered_chapter = function(_ws, chapter, _index, body)
        rendered[chapter.chapterUid] = body
    end
    dl = { book = book, chapters = { ch1, ch2, ch3 }, selected = { ch1, ch2, ch3 },
        bodies = {}, state = {}, total = 3, index = 4, failed = {}, resumable = true,
        workspace = { kind = "resumable" } }
    d:_startFootnotes(dl)
    drain(20)
    expect(indexed and indexed["1"] and indexed["3"] and indexed["2"] == nil,
        "unscannable checkpoint was not skipped in the footnote index")
    expect(rendered[1] == "<p>cp 1</p>" and rendered[2] == "<p>cp 2</p>"
        and rendered[3] == "<p>cp 3</p>", "checkpoints were not rendered")
    reset_footnotes()

    -- Download time: a chapter whose footnote scan fails is still staged.
    Footnotes.scan_chapter = function() error("scan crashed") end
    dl = { book = book, chapters = { ch1 }, selected = {}, bodies = {}, assets = {},
        state = {}, total = 1, index = 1, failed = {}, footnote_scans = {} }
    d:_step(dl)
    expect(dl.bodies["1"] == "<p>1</p>" and dl.index == 2 and dl.footnote_scans["1"] == nil,
        "scan failure dropped the chapter")
    scheduled = {}
    reset_footnotes()
end

---------------------------------------------------------------------------
-- Completion reporting for best-effort chapter downloads.
do
    scheduled = {}
    shown = {}
    reset_content()
    local d = new_downloader()
    local function finished(fields)
        local calls, on_complete = recorder()
        local dl = { book = { book_id = "book", title = "Book" }, chapters = { ch1, ch2, ch3 },
            selected = { ch1, ch2 }, bodies = { ["1"] = "1", ["2"] = "2" }, assets = {},
            assets_by_uid = {}, state = { css = "" }, suffix = "chapters", index = 4,
            total = 3, failed = { "3" }, separate_chapters = true, offer_read = true,
            annotation_failed_batches = 0, started_at = 1000, on_complete = on_complete,
            footnote_stats = { unresolved = 0, fallback = 0, converted = 0 } }
        for key, value in pairs(fields or {}) do dl[key] = value end
        d._active_job = dl
        return dl, calls
    end
    local dl, calls = finished { annotation_failed_batches = 2,
        footnote_stats = { unresolved = 4, fallback = 1, converted = 3 } }
    d:_step(dl)
    local box = shown[#shown]
    expect(calls[1] and calls[1].ok == true and calls[1].value == "/cache/book/chapter-1.epub",
        "partial download did not report success with the first chapter")
    expect(box and box.text:find("Downloaded 2 chapters; 1 failed", 1, true),
        "skipped chapter count missing from the completion dialog")
    expect(box.text:find("2 thought batch", 1, true)
        and box.text:find("4 footnote reference", 1, true)
        and box.text:find("1 chapter(s) kept their original footnote", 1, true),
        "completion dialog omitted thought/footnote warnings")
    box.ok_callback()
    expect(opened[1] == "/cache/book/chapter-1.epub", "Read now did not open the book")
    expect(d._active_job == nil, "completed job stayed active")

    dl, calls = finished { failed = {}, offer_read = false }
    local shown_before = #shown
    d:_step(dl)
    expect(#shown == shown_before and transients[#transients] == "Downloaded 2 chapters.",
        "offer_read=false still asked to read")
    expect(calls[1] and calls[1].ok == true, "quiet completion was not reported")
end

---------------------------------------------------------------------------
-- Recovery after a crash removes stale artifacts and survives failures.
do
    reset_content()
    local seen
    Content.cleanup_stale_downloads = function(settings) seen = settings; return 3 end
    local d = new_downloader()
    expect(d:recover() == true and seen == d.settings, "stale download recovery failed")
    Content.cleanup_stale_downloads = function() return 0 end
    expect(d:recover() == true, "nothing-to-clean recovery failed")
    Content.cleanup_stale_downloads = function() error("permission denied") end
    expect(d:recover() == false, "failing recovery reported success")
    reset_content()
end

print(("downloader_edge_paths_spec: %d checks"):format(checks))
