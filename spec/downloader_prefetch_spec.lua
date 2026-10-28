-- Focused tests for the downloader's single-prefetch invariant and promotion.

package.path = "./?.lua;" .. package.path

local scheduled = {}
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
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
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
package.preload["weread.lib.content"] = function()
    return { ensure_reader_state = function() end }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            options.show = function() end
            options.reportProgress = function() end
            options.close = function() end
            return options
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end

local Downloader = require("weread.lib.downloader")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local completions = {}
local function fake_settings()
    local values = { cache = {}, books = {} }
    return {
        is_cookie_configured = function() return true end,
        get = function(_self, key, default)
            return values[key] == nil and default or values[key]
        end,
        set = function(_self, key, value) values[key] = value end,
        flush = function() end,
    }
end
local function fake_worker()
    local worker = { starts = {}, events = {} }
    worker.available = function() return true end
    worker.start = function(self, options)
        local handle = { options = options }
        self.starts[#self.starts + 1] = handle
        if options.on_launch then options.on_launch(100 + #self.starts, 96 * 1024) end
        return true, handle
    end
    worker.cancel = function(self, handle, reason)
        self.events[#self.events + 1] = function()
            handle.options.on_done { ok = false, cancelled = true, error = reason }
        end
        return true
    end
    return worker
end
local function run_scheduled()
    local callback = table.remove(scheduled, 1)
    if callback then callback() end
end
local function run_worker_event(worker)
    local callback = table.remove(worker.events, 1)
    if callback then callback() end
end

local worker = fake_worker()
local downloader = Downloader:new{
    client = {},
    settings = fake_settings(),
    background_worker = worker,
    is_connected = function() return true end,
    show_transient = function() end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
}

local book_a = { book_id = "a" }
local chapter_2 = { chapterUid = 2 }
local chapter_3 = { chapterUid = 3 }

expect(downloader:start(book_a, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
    on_complete = function(ok, reason)
        completions[#completions + 1] = { ok, reason }
    end,
}), "first prefetch starts")
expect(#scheduled == 1 and #worker.starts == 0,
    "first prefetch defers the worker launch so the UI can paint")
run_scheduled()
expect(#worker.starts == 1, "first prefetch starts one worker")
expect(worker.starts[1].options.kind == "chapter"
        and worker.starts[1].options.replace_active == true,
    "chapter prefetch did not identify its replaceable worker kind")
expect(downloader:isPrefetching(book_a, chapter_2), "first target is active")
expect(downloader:promotePrefetch(book_a, chapter_2), "matching prefetch promotes")
expect(downloader._active_job.open_on_complete == true,
    "promotion requests automatic open")
expect(downloader._active_job.progress_dialog ~= nil,
    "promotion exposes the background task progress")
expect(downloader:isPromotedPrefetch(book_a, chapter_2),
    "promoted target can be detected by navigation")
expect(not downloader:promotePrefetch(book_a, chapter_3),
    "different chapter cannot promote")

expect(downloader:start(book_a, { chapter_3 }, "chapter", {
    prefetch = true,
    single_chapter = true,
}), "replacement prefetch is queued")
expect(downloader._active_job.cancelled == true,
    "old prefetch is cancelled before replacement")
expect(downloader._pending_start.chapters[1] == chapter_3,
    "only replacement target is pending")

run_worker_event(worker)
expect(#scheduled == 1, "replacement schedules exactly one downloader start")
run_scheduled()
expect(#scheduled == 1, "replacement keeps the UI paint delay")
run_scheduled()
expect(#worker.starts == 2, "replacement creates one new worker")
expect(downloader:isPrefetching(book_a, chapter_3),
    "replacement becomes the sole active prefetch")
expect(#completions == 1 and completions[1][2] == "replaced",
    "cancelled prefetch reports replacement reason once")

downloader:cancelPrefetch("document_closed")
expect(downloader._active_job.cancelled == true,
    "document close cancels active prefetch")
run_worker_event(worker)
expect(downloader._active_job == nil,
    "cancelled worker completion clears the active prefetch")

scheduled = {}
local race_worker = fake_worker()
local race = Downloader:new{
    client = {},
    settings = fake_settings(),
    background_worker = race_worker,
    is_connected = function() return true end,
    show_transient = function() end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
}
race:start(book_a, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
})
race:start(book_a, { chapter_3 }, "chapter", {
    prefetch = true,
    single_chapter = true,
})
run_scheduled()
expect(#scheduled == 1 and race._scheduled_start ~= nil,
    "replacement waits in a cancellable scheduled slot")
race:cancelPrefetch("document_closed")
run_scheduled()
expect(#race_worker.starts == 0 and race._active_job == nil,
    "document close prevents the scheduled replacement from starting")

scheduled = {}
local starts_notified = 0
local deferred_worker = fake_worker()
local deferred = Downloader:new{
    client = {},
    settings = fake_settings(),
    background_worker = deferred_worker,
    is_connected = function() return true end,
    show_transient = function() end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
}
expect(deferred:start({ book_id = "b" }, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
    start_delay = 0.7,
    on_start = function() starts_notified = starts_notified + 1 end,
}), "deferred prefetch starts")
expect(starts_notified == 1 and #scheduled == 1,
    "start notice runs before initialization is scheduled")
expect(deferred._active_job.standby_guard == nil,
    "network initialization has not begun while notice is visible")
run_scheduled()
expect(deferred._active_job.standby_guard == true,
    "subprocess launch acquires standby after the notice grace period")
expect(#deferred_worker.starts == 1,
    "deferred prefetch performs work in the subprocess runner")

-- A manual download queued behind a stopping prefetch must not be replaced
-- by a later prefetch (e.g. the next page turn) before the worker stops.
scheduled = {}
local queue_worker = fake_worker()
local queued_transients = {}
local queued = Downloader:new{
    client = {},
    settings = fake_settings(),
    background_worker = queue_worker,
    is_connected = function() return true end,
    require_login = function() return true end,
    run_online_task = function() return true end,
    show_transient = function(text) queued_transients[#queued_transients + 1] = text end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
}
queued:start(book_a, { chapter_2 }, "chapter", { prefetch = true, single_chapter = true })
run_scheduled()
local manual_results = {}
expect(queued:start(book_a, { chapter_2, chapter_3 }, "full", {
    on_complete = function(ok, reason) manual_results[#manual_results + 1] = { ok, reason } end,
}), "manual download queues behind the prefetch")
expect(not queued:start(book_a, { chapter_3 }, "chapter", {
    prefetch = true, single_chapter = true,
}), "prefetch must not replace a queued manual download")
expect(#queued_transients == 0, "a refused prefetch stays silent")
expect(not queued:start(book_a, { chapter_3 }, "chapter", { single_chapter = true }),
    "a second manual download must not replace the queued one")
expect(queued_transients[#queued_transients] == "Another download is already in progress.",
    "the refused manual download tells the reader why")
expect(queued._pending_start and queued._pending_start.suffix == "full",
    "queued manual download survives a later prefetch")
run_worker_event(queue_worker)
run_scheduled()
expect(queued._active_job and not queued._active_job.prefetch
        and queued._active_job.suffix == "full",
    "queued manual download starts once the prefetch stops")

-- A worker can succeed while parent-side persistence or refresh fails.
-- Completion must still release the active slot and any queued manual job.
local downloaded_path = os.tmpname()
local downloaded = assert(io.open(downloaded_path, "wb"))
downloaded:write("synthetic EPUB")
downloaded:close()
for _, failure in ipairs({ "auth", "save", "refresh" }) do
    scheduled = {}
    local failed_settings = fake_settings()
    if failure == "auth" then
        failed_settings.update_auth = function() error("injected auth save failure") end
    elseif failure == "save" then
        failed_settings.flush = function() error("injected book save failure") end
    end
    local failure_worker = fake_worker()
    local result_count, result_ok, opened = 0, nil, false
    local failing = Downloader:new{
        client = {}, settings = failed_settings, background_worker = failure_worker,
        is_connected = function() return true end,
        refresh_ui = function() end,
        require_login = function() return true end,
        run_online_task = function() return true end,
        refresh_shelf = function()
            if failure == "refresh" then error("injected shelf refresh failure") end
        end,
        open_file = function() opened = true end,
    }
    failing:start(book_a, { chapter_2 }, "chapter", {
        prefetch = true, single_chapter = true,
        on_complete = function(ok)
            result_count, result_ok = result_count + 1, ok
        end,
    })
    run_scheduled()
    local job = failing._active_job
    job.open_on_complete = true
    failing._pending_start = {
        book = book_a, chapters = { chapter_3 }, suffix = "manual", options = {},
    }
    local callback_ok = pcall(failure_worker.starts[1].options.on_done, {
        ok = true, value = { path = downloaded_path, auth = {} },
    })
    expect(callback_ok, failure .. " failure escaped the worker callback")
    expect(failing._active_job == nil and job.standby_guard == nil,
        failure .. " failure kept the downloader active or standby inhibited")
    expect(result_count == 1 and result_ok == (failure == "refresh"),
        failure .. " failure reported an incorrect or duplicate completion")
    expect(opened == (failure == "refresh"),
        failure .. " failure opened a chapter whose parent state was not saved")
    expect(failing._scheduled_start and failing._scheduled_start.pending.suffix == "manual",
        failure .. " failure swallowed the queued manual download")
    local preserved = io.open(downloaded_path, "rb")
    expect(preserved ~= nil, failure .. " failure removed the successful worker's EPUB")
    if preserved then preserved:close() end
    run_scheduled()
    expect(failing._active_job and failing._active_job.suffix == "manual",
        failure .. " failure prevented the queued manual download from starting")
end
-- Stable identity protects deferred launch and parent delivery; rotating a
-- ticket for the same account still permits downloaded chapter metadata.
for _, change in ipairs({ "before_launch", "after_worker", "ticket" }) do
    scheduled = {}
    local settings = fake_settings()
    settings:set("account", { user_vid = "one" })
    settings:set("wr_ticket", "original-ticket")
    settings.update_auth = function(self, auth) self:set("wr_ticket", auth.wr_ticket) end
    local account_worker = fake_worker()
    local result_ok, result_reason, opened, refreshed
    local candidate = { book_id = "isolated", title = "Account fixture" }
    local account_downloader = Downloader:new{
        client = {}, settings = settings, background_worker = account_worker,
        require_login = function() return true end,
        refresh_ui = function() end,
        refresh_shelf = function() refreshed = true end,
        open_file = function() opened = true end,
    }
    account_downloader:start(candidate, { chapter_2 }, "chapter", {
        prefetch = true, single_chapter = true, open_on_complete = true,
        on_complete = function(ok, value) result_ok, result_reason = ok, value end,
    })
    if change == "before_launch" then settings:set("account", { user_vid = "two" }) end
    run_scheduled()
    if change == "before_launch" then
        expect(#account_worker.starts == 0, "old-account deferred prefetch started under new credentials")
    else
        if change == "after_worker" then settings:set("account", { user_vid = "two" })
        else settings:set("wr_ticket", "rotated-parent-ticket") end
        account_worker.starts[1].options.on_done({ ok = true,
            value = { path = downloaded_path, chapter_uid = "2", auth = { wr_ticket = "old-account_worker-ticket" } } })
    end
    if change == "ticket" then
        expect(result_ok and settings:get("books").isolated.cached_chapters["2"] == downloaded_path
            and opened and refreshed, "same-account ticket rotation discarded chapter result")
        expect(settings:get("wr_ticket") == "rotated-parent-ticket", "old account_worker auth replaced rotated ticket")
    else
        expect(result_ok == false and result_reason == "account_changed" and not settings:get("books").isolated
            and not candidate.cached_chapters and not opened and not refreshed,
            change .. " wrote old-account metadata or refreshed/opened UI")
    end
    expect(account_downloader._active_job == nil and (account_downloader._standby_ref or 0) == 0,
        change .. " stranded prefetch active slot/standby")
end
-- A task queued behind another worker rechecks identity in the child too.
scheduled = {}
local pending_settings = fake_settings()
pending_settings:set("account", { user_vid = "one" })
local pending_worker = fake_worker()
local pending_dl = Downloader:new{
    settings = pending_settings, client = {}, background_worker = pending_worker,
    require_login = function() return true end,
}
local ChapterWorker = require("weread.lib.chapter_prefetch_worker")
local original_run, child_requests = ChapterWorker.run, 0
ChapterWorker.run = function() child_requests = child_requests + 1; return {} end
pending_dl:start({ book_id = "queued" }, { chapter_2 }, "chapter", { prefetch = true, single_chapter = true })
run_scheduled()
pending_settings:set("account", { user_vid = "two" })
local task_ok, task_err = pcall(pending_worker.starts[1].options.task, {})
ChapterWorker.run = original_run
expect(not task_ok and tostring(task_err):find("account_changed", 1, true) and child_requests == 0,
    "queued old-account task issued requests with new credentials")
pending_worker.starts[1].options.on_done({ ok = false, error = task_err })
expect(pending_dl._active_job == nil and (pending_dl._standby_ref or 0) == 0,
    "queued account rejection stranded downloader/standby")

-- The downloader's replacement queue also retains identity across restart.
for _, change in ipairs({ "before_finish", "after_finish", "ticket", "mp_before_finish", "mp_after_finish" }) do
    scheduled = {}
    local queued_settings, queued_worker = fake_settings(), fake_worker()
    queued_settings:set("account", { user_vid = "one" })
    local replacement_dl = Downloader:new{
        settings = queued_settings, client = {}, background_worker = queued_worker,
        require_login = function() return true end,
        is_connected = function() return true end,
    }
    replacement_dl:start(book_a, { chapter_2 }, "chapter", { prefetch = true, single_chapter = true })
    run_scheduled()
    local queued_done, queued_ok, queued_reason = 0
    replacement_dl:start(book_a, { chapter_3 }, "chapter", {
        prefetch = not change:find("mp_", 1, true), mp_article = change:find("mp_", 1, true) ~= nil,
        single_chapter = true,
        on_complete = function(ok, reason)
            queued_done, queued_ok, queued_reason = queued_done + 1, ok, reason
        end,
    })
    expect(replacement_dl._pending_start ~= nil, change .. " replacement did not enter downloader queue")
    if change:find("before_finish", 1, true) then queued_settings:set("account", { user_vid = "two" }) end
    run_worker_event(queued_worker)
    if change:find("after_finish", 1, true) then queued_settings:set("account", { user_vid = "two" }) end
    if change == "ticket" then queued_settings:set("wr_ticket", "rotated") end
    run_scheduled()
    run_scheduled()
    if change == "ticket" then
        expect(#queued_worker.starts == 2, "same-account ticket rotation rejected replacement")
        queued_worker.starts[2].options.on_done({ ok = false, error = "fixture_done" })
    else
        expect(#queued_worker.starts == 1 and queued_done == 1 and queued_ok == false
            and queued_reason == "account_changed", change .. " restarted a stale replacement")
    end
    expect(replacement_dl._active_job == nil and replacement_dl._pending_start == nil and replacement_dl._scheduled_start == nil
        and (replacement_dl._standby_ref or 0) == 0, change .. " queue rejection stranded state")
end

os.remove(downloaded_path)

-- MP jobs use the same active slot and capture identity before deferred work.
scheduled = {}
local mp_launched, mp_snapshot = 0, nil
package.preload["weread.lib.mp_article_download"] = function()
    return { start = function(_owner, job)
        mp_launched, mp_snapshot = mp_launched + 1, job.account_id
    end }
end
local mp_settings = fake_settings()
mp_settings:set("account", { user_vid = "first" })
local mp_messages = {}
local mp = Downloader:new{
    settings = mp_settings, client = {}, background_worker = fake_worker(),
    require_login = function() return true end,
    is_connected = function() return true end,
    show_info = function(message) mp_messages[#mp_messages + 1] = message end,
    refresh_ui = function() end,
}
expect(mp:start(book_a, { chapter_2 }, "article", { mp_article = true, single_chapter = true }),
    "MP job was not accepted by shared downloader")
expect(mp._active_job and mp._active_job.progress_dialog and mp_launched == 0,
    "MP work ran before its cancellable dialog could paint")
mp_settings:set("account", { user_vid = "second" })
run_scheduled()
expect(mp_launched == 1 and mp_snapshot == "first", "MP deferred launch captured new account instead of job account")
mp:_finishJob(mp._active_job)
scheduled = {}
expect(mp:start(book_a, { chapter_3 }, "article", { mp_article = true, single_chapter = true }),
    "second MP job did not start")
mp._active_job.progress_dialog.buttons[1][1].callback()
run_scheduled()
expect(mp._active_job == nil and mp_launched == 1, "cancel-before-launch executed MP worker or kept active slot")
mp.is_connected = function() return false end
expect(not mp:start(book_a, { chapter_3 }, "article", { mp_article = true, single_chapter = true })
    and mp._active_job == nil and mp_messages[#mp_messages]:find("No network connection", 1, true),
    "offline MP job was silent or stranded the downloader")

print(string.format(
    "downloader_prefetch_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
