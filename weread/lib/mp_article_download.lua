-- MP jobs share the downloader's active slot, standby guard and worker gate.
local BookRecords = require("weread.lib.book_records")
local Content = require("weread.lib.content")
local Files = require("weread.lib.mp_article_files")
local WorkerSettings = require("weread.lib.worker_settings")
local PluginUtil = require("weread.lib.plugin_util")
local logger = require("weread.lib.logger")
local _ = PluginUtil.tr
local T = PluginUtil.T
local M = {}

local function account_id(settings)
    local account = settings:get("account", {})
    return type(account) == "table" and tostring(account.user_vid or "") or ""
end

local function persist(downloader, job, download)
    local settings = downloader.settings
    local book_id = job.book.book_id or job.book.bookId
    local previous = BookRecords.get(settings, book_id)
    if previous and previous.cache_dir == download.target_dir then return end
    local record = {}
    for key, value in pairs(previous or {}) do record[key] = value end
    record.book_id, record.cache_dir = book_id, download.target_dir
    local saved, err = pcall(function()
        BookRecords.put(settings, book_id, record)
        settings:flush()
    end)
    if not saved then
        local restored = pcall(function()
            if previous then BookRecords.put(settings, book_id, previous)
            else BookRecords.delete(settings, book_id) end
            settings:flush()
        end)
        download.keep_workspace = not restored
        error(err, 0)
    end
end

function M.start(downloader, job)
    local worker = downloader.background_worker
    local download, finished
    local original_account = job.account_id
    local function complete(result)
        if finished then return end
        finished = true
        job.worker_handle = nil
        local cancelled = job.cancelled or downloader._active_job ~= job
            or account_id(downloader.settings) ~= original_account
        local ok, path = pcall(function()
            if cancelled then return end
            if not result or not result.ok then
                local reason = result and result.error
                local messages = {
                    worker_unavailable = _("Background downloads are unavailable on this device."),
                    worker_busy = _("Another background task is running. Try again shortly."),
                    low_memory = _("Download stopped: not enough free memory.\n\nClose the open book or restart KOReader, then try again."),
                }
                error(messages[reason] or reason or "article worker failed", 0)
            end
            local value = result.value
            assert(value and value.path == download.stage_html, "article worker returned an invalid path")
            if value.auth then WorkerSettings.merge(downloader.settings, job.auth_fingerprint, value.auth) end
            local saved, err = Files.commit(download, function() persist(downloader, job, download) end)
            if not saved then error(err, 0) end
            job.book.cache_dir = download.target_dir
            return saved
        end)
        if download then
            local cleaned, value, clean_err = pcall(Files.cleanup, download)
            if not cleaned or not value then
                logger.warn("MP workspace cleanup failed:", PluginUtil.log_error(clean_err or value))
            end
        end
        if job.progress_dialog then
            local closed, close_err = pcall(job.progress_dialog.close, job.progress_dialog)
            job.progress_dialog = nil
            if not closed then logger.warn("MP dialog close failed:", PluginUtil.log_error(close_err)) end
        end
        local released, release_err = pcall(downloader._releaseStandby, downloader, job)
        if not released then logger.warn("MP standby release failed:", PluginUtil.log_error(release_err)) end
        downloader:_notifyCompletion(job, ok and path ~= nil, cancelled and "cancelled" or path)
        downloader:_finishJob(job)
        if cancelled then return end
        if not ok then
            logger.err("download MP article failed:", PluginUtil.log_error(path))
            downloader.show_info(T(_("Download failed:\n%1"), PluginUtil.display_error(path)))
        elseif path and job.open_on_complete then
            downloader.open_file(path)
        end
    end
    if account_id(downloader.settings) ~= original_account then complete(); return end
    local prepared, value = pcall(Files.prepare, downloader.settings, job.book, job.chapters[1])
    if not prepared then complete({ ok = false, error = value }); return end
    download = value
    if not worker or not worker:available() then
        complete({ ok = false, error = "worker_unavailable" })
        return
    end
    local called, started, handle = pcall(worker.start, worker, {
        kind = "mp_article",
        timeout = 180,
        task = function(context)
            local auth_result, restore_auth = WorkerSettings.capture(downloader.settings)
            local ok, result = xpcall(function()
                context.checkCancelled()
                local path = Content.fetch_mp_article_html(downloader.client, downloader.settings,
                    download.stage_book, job.chapters[1], {
                        asset_name = download.asset_name,
                        progress = function(current, total)
                            context.checkCancelled()
                            context.emit { current = current, total = total }
                        end,
                    })
                context.checkCancelled()
                return { path = path, auth = auth_result() }
            end, debug.traceback)
            if not ok then restore_auth(); error(result, 0) end
            return result
        end,
        on_launch = function()
            downloader:_beginStandby()
            job.standby_guard = true
        end,
        on_progress = function(state)
            if downloader._active_job ~= job or job.cancelled then return end
            local total = tonumber(state.total) or 1
            job.total = total
            if job.progress_dialog then job.progress_dialog.progress_max = total end
            downloader:_setStage(job, T(_("Downloading images: %1"), job.chapters[1].title or ""), state.current)
        end,
        on_done = complete,
    })
    if not finished then
        if called and started then job.worker_handle = handle
        else complete({ ok = false, error = called and handle or started }) end
    end
end

return M
