-- MP worker completion must release the shared job and keep account writes isolated.
package.path = "./?.lua;" .. package.path
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local committed, cleaned, prepared, restore_failure, fetch_failure = 0, 0, 0, false, false
package.preload["weread.lib.logger"] = function() return { warn = function() end, err = function() end } end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s) return s end, log_error = tostring, display_error = tostring }
end
package.preload["weread.lib.content"] = function()
    return { fetch_mp_article_html = function(_, settings, _, _, options)
        if fetch_failure then error("HTTP injected failure") end
        settings:update_auth({ wr_ticket = "worker-ticket" })
        options.progress(1, 2)
        return "/stage/article.html"
    end }
end
package.preload["weread.lib.mp_article_files"] = function()
    return {
        prepare = function()
            prepared = prepared + 1
            return { stage_html = "/stage/article.html", stage_book = {}, asset_name = "version",
                target_dir = "/book", target_html = "/book/article.html" }
        end,
        cleanup = function() cleaned = cleaned + 1; return true end,
        commit = function(download, persist)
            local ok, err = pcall(persist)
            if not ok then return nil, err end
            committed = committed + 1
            return download.target_html
        end,
    }
end
local WorkerSettings = require("weread.lib.worker_settings")
local Download = require("weread.lib.mp_article_download")
local function fixture()
    local values = { account = { user_vid = "one" }, wr_ticket = "parent-ticket" }
    local books, flushes, completions, released, finished, opened, messages = {}, 0, {}, 0, 0, 0, {}
    local settings = {
        get = function(_, key, default) return values[key] or default end,
        get_book = function(_, id) return books[id] end,
        put_book = function(_, id, value) if restore_failure then error("metadata write failure") end books[id] = value end,
        delete_book = function(_, id) books[id] = nil end,
        flush = function() flushes = flushes + 1 end,
        update_auth = function(_, auth) values.wr_ticket = auth.wr_ticket end,
    }
    local job = { account_id = "one", book = { book_id = "MP_WXS_1" }, chapters = {{ title = "Article" }},
        auth_fingerprint = WorkerSettings.fingerprint(settings), open_on_complete = true,
        progress_dialog = { close = function() end } }
    local worker = { available = function() return true end,
        start = function(self, options) self.options = options; options.on_launch(); return true, {} end }
    local dl = { _active_job = job, settings = settings, background_worker = worker,
        _beginStandby = function() end,
        _releaseStandby = function() released = released + 1 end,
        _notifyCompletion = function(_, _, ok, value) completions[#completions + 1] = { ok, value } end,
        _finishJob = function(self) self._active_job = nil; finished = finished + 1 end,
        _setStage = function() end,
        open_file = function() opened = opened + 1 end,
        show_info = function(message) messages[#messages + 1] = message end,
    }
    return dl, job, worker, values, books, function()
        return { released = released, finished = finished, opened = opened, completions = completions,
            messages = messages, flushes = flushes }
    end
end
local function result(worker)
    return worker.options.task({ checkCancelled = function() end, emit = function() end })
end
local dl, job, worker, values, books, state = fixture()
Download.start(dl, job)
local captured = result(worker)
expect(captured.path == "/stage/article.html" and captured.auth.wr_ticket == "worker-ticket", "worker returned bulk or missing data")
values.wr_ticket = "parent-ticket" -- emulate the fork leaving parent settings unchanged
worker.options.on_done({ ok = true, value = captured })
expect(committed == 1 and books.MP_WXS_1.cache_dir == "/book" and job.book.cache_dir == "/book", "publication did not persist parent book")
expect(values.wr_ticket == "worker-ticket" and state().opened == 1, "fresh worker credentials/open not applied")
expect(state().released == 1 and state().finished == 1 and state().completions[1][1], "success leaked active job")
worker.options.on_done({ ok = true, value = captured })
expect(state().finished == 1, "duplicate worker completion ran twice")

for _, change in ipairs({ "cancel", "account", "ticket" }) do
    dl, job, worker, values, books, state = fixture()
    Download.start(dl, job)
    captured = result(worker)
    values.wr_ticket = change == "ticket" and "new-parent-ticket" or "parent-ticket"
    if change == "cancel" then job.cancelled = true end
    if change == "account" then values.account = { user_vid = "two" } end
    local before = committed
    worker.options.on_done({ ok = true, value = captured })
    if change == "ticket" then
        expect(committed == before + 1 and books.MP_WXS_1 and state().opened == 1,
            "same-account credential rotation discarded article")
        expect(values.wr_ticket == "new-parent-ticket", "old worker credentials overwrote rotated ticket")
    else
        expect(committed == before and not books.MP_WXS_1 and job.book.cache_dir == nil and state().opened == 0,
            change .. " committed old worker output")
        expect(values.wr_ticket == "parent-ticket" and #state().messages == 0, "cancelled/account-discard result touched auth or UI")
    end
    expect(state().finished == 1 and state().released == 1, change .. " left downloader active")
end

dl, job, worker, values, books, state = fixture() -- luacheck: ignore 311
values.account = { user_vid = "two" }
local before = prepared
Download.start(dl, job)
expect(prepared == before and not worker.options and state().finished == 1,
    "account changed before deferred launch still prepared or downloaded article")

for _, failure in ipairs({ "start", "unavailable", "metadata", "close", "fetch" }) do
    dl, job, worker, values, books, state = fixture() -- luacheck: ignore 311
    if failure == "start" then worker.start = function() error("start threw") end end
    if failure == "unavailable" then worker.available = function() return false end end
    if failure == "close" then job.progress_dialog.close = function() error("close threw") end end
    Download.start(dl, job)
    if worker.options then
        fetch_failure = failure == "fetch"
        local ok, value = pcall(result, worker)
        fetch_failure = false
        values.wr_ticket = "parent-ticket"
        restore_failure = failure == "metadata"
        worker.options.on_done({ ok = ok, value = ok and value or nil, error = not ok and value or nil })
        restore_failure = false
    end
    expect(state().finished == 1 and state().released == 1 and dl._active_job == nil,
        failure .. " stranded active job")
    if failure ~= "close" then expect(not state().completions[1][1] and state().opened == 0,
        failure .. " reported success/opened article") end
end
expect(cleaned >= 9, "failure/cancellation paths skipped staging cleanup")
print(("mp_article_download_spec: %d checks"):format(checks))
