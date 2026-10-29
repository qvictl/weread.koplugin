package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local prevented = 0
local allowed = 0
local scheduled = {}
local dialog
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
        preventStandby = function() prevented = prevented + 1 end,
        allowStandby = function() allowed = allowed + 1 end,
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        show = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
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
    return {
        ensure_reader_state = function() end,
        fetch_single_chapter_source = function()
            error("injected transient timeout")
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            dialog = {
                options = options,
                title = options.title,
                show = function(self) self.visible = true end,
                close = function(self) self.visible = false end,
                setTitle = function(self, title) self.title = title end,
                reportProgress = function() end,
            }
            return dialog
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
    }
end

local Downloader = require("weread.lib.downloader")

local completions = {}
local messages = {}
local downloader = Downloader:new{
    client = {},
    settings = {},
    require_login = function() return false end,
    run_online_task = function() error("must not run while logged out") end,
    show_info = function(text) messages[#messages + 1] = text end,
    show_transient = function(text) messages[#messages + 1] = text end,
    refresh_ui = function() end,
}
local started = downloader:start({}, {}, "book", {
    on_complete = function(ok, value)
        completions[#completions + 1] = { ok, value }
    end,
})
expect(started == false, "logged-out download should not start")
expect(#completions == 1 and completions[1][1] == false
    and completions[1][2] == "authentication_required",
    "logged-out completion result was wrong")

downloader.require_login = function() return true end
downloader.run_online_task = function() return false end
started = downloader:start({}, {}, "book", {
    on_complete = function(ok, value)
        completions[#completions + 1] = { ok, value }
    end,
})
expect(started == false, "offline download should not start")
expect(#completions == 2 and completions[2][2] == "offline",
    "offline completion result was wrong")

local cancellation_count = 0
local cancelled = {
    cancelled = true,
    standby_guard = true,
    on_complete = function(ok, value)
        cancellation_count = cancellation_count + 1
        expect(ok == false and value == "cancelled",
            "cancel completion result was wrong")
    end,
}
downloader:_beginStandby()
downloader:_step(cancelled)
downloader:_step(cancelled)
expect(cancellation_count == 1, "cancel completion callback was not idempotent")
expect(downloader._standby_ref == 0 and allowed == 1,
    "cancel did not release standby exactly once")

local guarded_completion_count = 0
local closed = 0
local guarded = {
    standby_guard = true,
    progress_dialog = { close = function() closed = closed + 1 end },
    on_complete = function(ok, value)
        guarded_completion_count = guarded_completion_count + 1
        expect(ok == false and tostring(value):find("guarded boom", 1, true),
            "guarded error completion result was wrong")
    end,
}
downloader:_beginStandby()
downloader:_scheduleGuarded(guarded, function()
    error("guarded boom")
end, 0)
expect(#scheduled == 1, "guarded step was not scheduled")
scheduled[1]()
expect(guarded_completion_count == 1 and closed == 1,
    "guarded failure did not close and notify exactly once")
expect(downloader._standby_ref == 0 and allowed == 2,
    "guarded failure leaked the standby guard")
expect(#messages >= 2, "lifecycle failures were not surfaced to the user")
expect(prevented == 2, "standby guard was not acquired exactly once per job")

local retry_download = {
    book = { book_id = "book" },
    chapters = { { chapterUid = 30, title = "Chapter 30" } },
    index = 1,
    total = 1,
    failed = {},
}
local scheduled_before_retry = #scheduled
downloader:_step(retry_download)
expect(retry_download.index == 1 and #retry_download.failed == 0,
    "first transient chapter failure was not retained for retry")
expect(#scheduled == scheduled_before_retry + 1,
    "first chapter retry was not scheduled")
scheduled[#scheduled]()
expect(retry_download.index == 1 and #retry_download.failed == 0,
    "second transient chapter failure was not retained for retry")
scheduled[#scheduled]()
expect(retry_download.index == 2 and retry_download.failed[1] == "30",
    "chapter was not skipped after exhausting two retries")

-- Preparation must already be painted while DNS/session/cache work blocks.
local Content = require("weread.lib.content")
local pending_init, painted, reader_calls = nil, false, 0
downloader.refresh_ui = function()
    expect(dialog.visible, "preparation dialog was not shown before repaint")
    painted = true
end
downloader.run_online_task = function(_label, callback)
    expect(painted and dialog.visible and dialog.title == "Checking network...",
        "network check ran before the preparation dialog was painted")
    pending_init = callback
    return true
end
Content.ensure_reader_state = function()
    reader_calls = reader_calls + 1
    expect(dialog.visible and dialog.title == "Connecting to WeRead...",
        "reader session request ran without a visible stage")
end
Content.create_download_workspace = function()
    expect(dialog.visible and dialog.title == "Preparing download...",
        "workspace preparation ran without a visible stage")
    return {}
end
Content.cleanup_download_workspace = function() end
downloader.settings.get = function(_self, key, default)
    if key == "cache" then return { download_book_images = true } end
    return default
end
local chapters = { { chapterUid = 1 }, { chapterUid = 2 } }
local function start_selected()
    painted = false
    return downloader:start({ title = "Book" }, chapters, "chapters", {
        separate_chapters = true,
    })
end
expect(start_selected(), "selected chapter download did not start")
local preparing_dialog = dialog
expect(not start_selected(), "duplicate preparation was accepted")
pending_init()
expect(reader_calls == 1 and dialog == preparing_dialog and dialog.visible,
    "initialization replaced or closed the preparation dialog")
expect(downloader._active_job.standby_guard, "download did not acquire standby guard")
dialog.options.buttons[1][1].callback()
downloader:_step(downloader._active_job)
expect(not dialog.visible and downloader._active_job == nil,
    "cancelled download left the preparation dialog or job active")

expect(start_selected(), "cancel preparation setup failed")
dialog.options.buttons[1][1].callback()
pending_init()
expect(reader_calls == 1 and not dialog.visible and downloader._active_job == nil,
    "cancel before initialization still fetched or reopened the dialog")

Content.ensure_reader_state = function() error("injected reader failure") end
expect(start_selected(), "reader failure setup failed")
pending_init()
expect(not dialog.visible and downloader._active_job == nil,
    "failed initialization left the preparation dialog or job active")
expect(downloader._standby_ref == 0, "preparation failure leaked standby guard")

downloader.run_online_task = function()
    expect(painted and dialog.visible, "offline check ran before repaint")
    return false
end
expect(not start_selected() and not dialog.visible and downloader._active_job == nil,
    "offline start left the preparation dialog or job active")

-- Model Trapper yielding to the UI while a child is blocked on network I/O.
local child_pending, resumed, killed = nil, nil, 0
local trapper = {
    wrap = function(_self, callback)
        local co = coroutine.create(callback)
        local ok, err = coroutine.resume(co)
        assert(ok, err)
    end,
    dismissableRunInSubprocess = function(_self, task, widget)
        local co = coroutine.running()
        child_pending = task
        widget.dismiss_callback = function()
            killed = killed + 1
            child_pending = nil
            local ok, err = coroutine.resume(co, false)
            assert(ok, err)
        end
        resumed = function(value)
            child_pending = nil
            local ok, err = coroutine.resume(co, true, { ok = true, value = value })
            assert(ok, err)
        end
        return coroutine.yield()
    end,
}
local TaskStub = require("spec.helpers.subprocess_stub")
local restore_process = TaskStub.install(function(task, widget)
    return trapper:dismissableRunInSubprocess(task, widget)
end)
require("ffi/util").runInSubProcess = function() end
package.preload["ui/trapper"] = function() return trapper end
downloader.run_online_task = function(_label, callback) callback(); return true end
local cleanup_calls, completion_calls = 0, 0
Content.cleanup_download_workspace = function() cleanup_calls = cleanup_calls + 1 end
local function cancel_job(dl, expected_cleanup)
    local before_killed = killed
    expect(child_pending and dialog.visible, "network request did not yield to the UI")
    dialog.options.buttons[1][1].callback()
    expect(killed == before_killed + 1 and child_pending == nil,
        "cancel did not interrupt the in-flight child")
    expect(dl.cancelled and dl.completion_notified and downloader._active_job == nil,
        "cancel did not finish the job exactly once")
    expect(not dialog.visible and downloader._standby_ref == 0,
        "cancel left a dialog or standby guard active")
    expect(cleanup_calls == expected_cleanup, "cancel removed the wrong workspace")
end

expect(start_selected(), "interruptible preparation did not start")
cancel_job(downloader._active_job, 0)

for _, stage in ipairs({ "source", "images", "cover" }) do
    local dl = {
        book = { title = "Book", cover = "https://example.com/cover.jpg" },
        chapters = chapters, total = 2, index = stage == "cover" and 3 or 1,
        selected = {}, bodies = {}, state = {}, assets = {}, failed = {},
        standby_guard = true, trapper = trapper, workspace = {},
        resumable = true, completed = {}, completed_count = 0,
        workspace_verified = true, footnotes_done = true,
        on_complete = function(ok, reason)
            expect(not ok and reason == "cancelled", "cancel was reported as a failure")
            completion_calls = completion_calls + 1
        end,
    }
    if stage == "images" then dl.current = { chapter = chapters[1], xhtml = "body" } end
    if stage == "cover" then dl.selected = chapters end
    downloader._active_job = dl
    downloader:_beginStandby()
    downloader:_ensureProgressDialog(dl)
    expect(dialog.options.description and dialog.options.description:find("resume", 1, true),
        "full-book progress did not explain cancellation and resume")
    trapper:wrap(function()
        if stage == "images" then downloader:_finishChapter(dl) else downloader:_step(dl) end
    end)
    cancel_job(dl, 0)
end
expect(completion_calls == 3, "network-stage cancellation duplicated completion")

local transferred = {
    book = { book_id = "book", token = "stale" }, chapters = chapters, total = 2, index = 1,
    selected = {}, bodies = {}, state = {}, assets = {}, failed = {},
    standby_guard = true, trapper = trapper,
}
downloader._active_job = transferred
downloader:_beginStandby()
downloader:_ensureProgressDialog(transferred)
trapper:wrap(function() downloader:_step(transferred) end)
-- With images enabled one worker fetches the text and the images.
resumed({ xhtml = "<p>final</p>", assets = {}, state_delta = { css = { value = "body{}" } },
    book = { book_id = "book", psvts = "fresh" }, finalized = true })
expect(transferred.state.css == "body{}"
    and transferred.book.psvts == "fresh" and transferred.book.token == nil,
    "source result lost CSS/session changes or retained stale credentials")
expect(child_pending ~= nil and dialog.title:find("Downloading chapter 2/2:", 1, true)
    and transferred.current == nil,
    "the next worker must fetch chapter 2, not re-fetch chapter 1 images")
expect(transferred.bodies["1"] == "<p>final</p>" and transferred.index == 2
    and #transferred.selected == 1, "finalized child result was not saved in the parent")
dialog.options.buttons[1][1].callback()
downloader:_step(transferred)

-- A successful child must clear its dismiss callback before local work begins.
local dl = { book = {}, total = 1, trapper = trapper }
downloader:_ensureProgressDialog(dl)
local child_value
trapper:wrap(function()
    child_value = downloader:_runInterruptible(dl, function() return "unused" end)
end)
resumed("result")
expect(child_value == "result" and dialog.dismiss_callback == nil,
    "finished child left a stale coroutine cancellation callback")

dl.trapper = { dismissableRunInSubprocess = function() return false end }
local restore_failure = TaskStub.install(function() return false end)
local worker_ok, worker_err = pcall(downloader._runInterruptible, downloader, dl, function() end)
expect(not worker_ok and tostring(worker_err):find("could not start download worker", 1, true)
    and not dl.cancelled, "worker launch failure was mistaken for user cancellation")
restore_failure()

-- Low memory: wait (yielding to the UI) before forking, then fork once it frees up.
do
    local gate_calls = 0
    downloader.memory_gate = function()
        gate_calls = gate_calls + 1
        return gate_calls >= 3, gate_calls >= 3 and 200000 or 10000
    end
    local waiting = { book = {}, total = 1, trapper = trapper }
    downloader:_ensureProgressDialog(waiting)
    local value
    local before = #scheduled
    trapper:wrap(function()
        value = downloader:_runInterruptible(waiting, function() return "unused" end)
    end)
    expect(child_pending == nil and #scheduled == before + 1, "fork happened under memory pressure")
    table.remove(scheduled)()
    expect(child_pending == nil and #scheduled == before + 1, "second low-memory check did not wait")
    table.remove(scheduled)()
    expect(child_pending ~= nil, "fork did not resume once memory freed up")
    resumed("after-wait")
    expect(value == "after-wait", "result lost after waiting for memory")
end

-- Memory never frees up: the job stops instead of skipping the chapter.
do
    local gate_calls = 0
    downloader.memory_gate = function()
        gate_calls = gate_calls + 1
        return false, 50 * 1024, 96 * 1024
    end
    local starved = { book = {}, total = 1, trapper = trapper }
    downloader:_ensureProgressDialog(starved)
    local ok, err
    trapper:wrap(function()
        ok, err = pcall(downloader._runInterruptible, downloader, starved, function() end)
    end)
    expect(dialog.title:find("Waiting for free memory", 1, true)
        and dialog.title:find("50 MB free, 96 MB needed", 1, true),
        "low-memory wait did not show a stage: " .. tostring(dialog.title))
    local waits = 0
    while ok == nil and #scheduled > 0 do
        table.remove(scheduled)()
        waits = waits + 1
    end
    expect(waits == 6 and gate_calls == 7, "low-memory wait did not back off 6 times")
    expect(child_pending == nil, "forked although memory never recovered")
    expect(ok == false and tostring(err):find("weread_low_memory", 1, true),
        "starved download did not stop with a low-memory error")

    -- Resumable job: pause with the checkpoint kept, never count a failure.
    local infos_before = #messages
    local resumable = {
        book = {}, chapters = { { chapterUid = 9 } }, total = 1, index = 1,
        failed = {}, resumable = true, workspace = {}, standby_guard = true,
        completed_count = 0,
    }
    local reason
    resumable.on_complete = function(_ok, value) reason = value end
    downloader._active_job = resumable
    downloader:_beginStandby()
    expect(downloader:_retryChapterSource(resumable, err) == false,
        "low memory was retried as a chapter failure")
    expect(#resumable.failed == 0 and resumable.index == 1,
        "low memory skipped the chapter")
    expect(reason == "low_memory" and downloader._active_job == nil
        and downloader._standby_ref == 0, "low memory did not pause the resumable job")
    expect(#messages == infos_before + 1
        and messages[#messages]:find("Completed chapters were kept", 1, true)
        and messages[#messages]:find("restart KOReader", 1, true),
        "low-memory pause did not explain how to continue")

    -- Non-resumable job: stop cleanly.
    local plain = {
        book = {}, chapters = { { chapterUid = 9 } }, total = 1, index = 1,
        failed = {}, standby_guard = true,
    }
    plain.on_complete = function(_ok, value) reason = value end
    downloader._active_job = plain
    downloader:_beginStandby()
    downloader:_failChapter(plain, err)
    expect(#plain.failed == 0 and reason == "low_memory"
        and downloader._active_job == nil and downloader._standby_ref == 0,
        "low memory did not stop the non-resumable job cleanly")
    expect(messages[#messages]:find("Download stopped: not enough free memory", 1, true),
        "low-memory stop was not reported")
    downloader.memory_gate = function() return true end
end

-- Cancelling while waiting for memory wakes the job at once and never forks.
do
    downloader.memory_gate = function() return false, 1000, 98304 end
    local waiting = { book = {}, total = 1, trapper = trapper }
    downloader:_ensureProgressDialog(waiting)
    local returned, value = false, "unset"
    trapper:wrap(function()
        value = downloader:_runInterruptible(waiting, function() return "unused" end)
        returned = true
    end)
    expect(not returned and dialog.dismiss_callback ~= nil,
        "memory wait is not cancellable from the dialog")
    local pending_timer = table.remove(scheduled)
    dialog.options.buttons[1][1].callback()
    expect(returned and value == nil and waiting.cancelled and child_pending == nil,
        "cancel during the memory wait did not stop the job")
    pending_timer() -- the late timer must not resume the finished coroutine
    expect(child_pending == nil, "late memory-wait timer resumed the job")
    downloader.memory_gate = function() return true end
end

-- The default gate collects garbage and honours max(96 MB, heap + 48 MB).
do
    local MemoryGate = require("weread.lib.memory_gate")
    expect(MemoryGate.fork_requirement_kb(10 * 1024) == 96 * 1024,
        "small heaps must still keep the 96 MB floor")
    expect(MemoryGate.fork_requirement_kb(64 * 1024) == 112 * 1024,
        "large heaps must add 48 MB of headroom")
    local ok, available, required = MemoryGate.check_fork(function()
        return "MemTotal: 480000 kB\nMemAvailable: 90000 kB\n"
    end)
    expect(ok == false and available == 90000 and required >= 96 * 1024,
        "90 MB available must not pass the fork gate")
    ok = MemoryGate.check_fork(function() return "MemAvailable: 400000 kB\n" end)
    expect(ok == true, "plenty of memory must pass the fork gate")
    expect(MemoryGate.check_fork(function() return nil end) == true,
        "unknown memory must not block downloads")
    expect(MemoryGate.parse_rss_kb("Name:\treader\nVmRSS:\t  99196 kB\n") == 99196,
        "VmRSS was not parsed")
    local snapshot_downloader = Downloader:new{
        read_meminfo = function() return "MemAvailable: 123 kB\n" end,
        read_self_status = function() return "VmRSS: 456 kB\n" end,
    }
    local avail, rss = snapshot_downloader:_memorySnapshot()
    expect(avail == 123 and rss == 456, "memory snapshot did not use injected readers")
end

-- The worker child reseeds its PRNG and postpones its first GC cycle before
-- running the task (F1 copy-on-write, F12 identical random parameters).
do
    local order = {}
    local inline_trapper = {
        dismissableRunInSubprocess = function(_self, task) return true, task() end,
    }
    local restore_inline = TaskStub.install(function(task, widget)
        return inline_trapper:dismissableRunInSubprocess(task, widget)
    end)
    local child_dl = { book = {}, total = 1, trapper = inline_trapper }
    downloader.prepare_worker_child = function() order[#order + 1] = "prepare" end
    local value = downloader:_runInterruptible(child_dl, function()
        order[#order + 1] = "task"
        return "value"
    end)
    expect(value == "value" and order[1] == "prepare" and order[2] == "task",
        "child preparation did not run before the task")
    downloader.prepare_worker_child = nil

    math.randomseed(42)
    local parent_draw = math.random(0, 1000000)
    math.randomseed(42)
    local child_draw = downloader:_runInterruptible(child_dl, function()
        return math.random(0, 1000000)
    end)
    expect(child_draw ~= parent_draw, "worker child inherited the parent PRNG sequence")
    local child_pause = collectgarbage("setpause", 200)
    collectgarbage("restart")
    expect(child_pause >= 200 and child_pause <= 1000 and child_pause ~= 200,
        "worker child did not postpone its first GC cycle: " .. tostring(child_pause))
    restore_inline()
end

-- One fork per chapter: the worker runs source + images, the parent never
-- forks again; without images only the source runs in the worker.
do
    local forks, calls = 0, {}
    local inline_trapper = {
        wrap = function(_self, callback) callback() end,
        dismissableRunInSubprocess = function(_self, task)
            forks = forks + 1
            return true, task()
        end,
    }
    local restore_inline = TaskStub.install(function(task, widget)
        return inline_trapper:dismissableRunInSubprocess(task, widget)
    end)
    Content.fetch_single_chapter_source = function(_client, _settings, _book, chapter)
        calls[#calls + 1] = "source"
        return "<p>source " .. tostring(chapter.chapterUid) .. "</p>"
    end
    Content.finalize_single_chapter_content = function(_c, _s, _b, _chapter, xhtml)
        calls[#calls + 1] = "finalize"
        return xhtml:gsub("source", "final"), { { href = "images/a.png" } }
    end
    local images_enabled = true
    downloader.settings.get = function(_self, key, default)
        if key == "cache" then return { download_book_images = images_enabled } end
        return default
    end
    local function one_chapter_job()
        return {
            book = { book_id = "book" }, chapters = { { chapterUid = 7 } },
            total = 1, index = 1, selected = {}, bodies = {}, state = {},
            assets = {}, failed = {}, trapper = inline_trapper,
        }
    end
    local job = one_chapter_job()
    downloader:_step(job)
    expect(forks == 1 and calls[1] == "source" and calls[2] == "finalize",
        "source and images did not run in a single worker")
    expect(job.bodies["7"] == "<p>final 7</p>" and #job.assets == 1 and job.index == 2,
        "single-worker chapter result was not staged")

    images_enabled = false
    forks, calls = 0, {}
    job = one_chapter_job()
    downloader:_step(job)
    expect(forks == 1 and #calls == 2 and calls[1] == "source" and calls[2] == "finalize",
        "text-only chapter did not finalize in the parent after one worker")
    expect(job.bodies["7"] == "<p>final 7</p>", "text-only chapter was not staged")
    restore_inline()
end

-- Ordinary workers also retain the accepting account across every yield.
do
    local values = { account = { user_vid = "one" } }
    local d = Downloader:new{
        settings = { get = function(_, key, default) return values[key] or default end },
        client = {}, memory_gate = function() return true end,
        show_transient = function() end,
    }
    local forks = 0
    local queued_task
    local restore_worker = TaskStub.install(function()
        forks = forks + 1
        if queued_task then queued_task() end
        return true, { ok = true, value = "child-result" }
    end)
    local function job(task)
        queued_task = task
        return { account_id = "one", trapper = {} }
    end
    local pending = job()
    values.account.user_vid = "two"
    expect(d:_runInterruptible(pending, function() end) == nil and forks == 0
        and pending.cancel_reason == "account_changed", "changed account launched a manual worker")
    values.account.user_vid = "one"
    pending = job(function() values.account.user_vid = "two" end)
    expect(d:_runInterruptible(pending, function() end) == nil and pending.cancelled
        and pending.cancel_reason == "account_changed", "old-account manual result was delivered")
    values.account.user_vid = "one"
    pending = job(function() values.wr_ticket = "new-ticket" end)
    expect(d:_runInterruptible(pending, function() end) == "child-result" and not pending.cancelled,
        "same-account ticket rotation discarded a manual result")
    values.account.user_vid = "one"
    pending = { account_id = "one" }
    expect(d:_runInterruptible(pending, function() values.account.user_vid = "two"; return "old" end) == nil
        and pending.cancelled, "synchronous fallback delivered a changed-account result")

    values.account.user_vid = "one"
    pending = job()
    local previous_forks = forks
    d.memory_gate = function() return false, 1000, 96000 end
    d._sleepInJob = function() values.account.user_vid = "two"; return true end
    expect(d:_runInterruptible(pending, function() end) == nil and forks == previous_forks
        and pending.cancel_reason == "account_changed", "memory wait forked after account change")

    values.account.user_vid = "two"
    local direct_reason
    local direct = { account_id = "one", on_complete = function(_, reason) direct_reason = reason end }
    d._active_job = direct
    d:_step(direct)
    expect(direct_reason == "account_changed" and d._active_job == nil,
        "direct continuation after a coroutine yield entered finalization")
    restore_worker()

    -- Local finalize slices must stop too, even when no network task follows.
    for _, resumable in ipairs({ false, true }) do
        scheduled, values.account = {}, { user_vid = "one" }
        local completion, side_effect
        local waiting = { account_id = "one", resumable = resumable, workspace = {}, total = 1,
            standby_guard = true, on_complete = function(ok, reason) completion = { ok, reason } end }
        d._active_job = waiting
        d:_beginStandby()
        d:_scheduleGuarded(waiting, function() side_effect = true end)
        values.account.user_vid = "two"
        table.remove(scheduled, 1)()
        expect(not side_effect and completion and completion[1] == false and completion[2] == "account_changed"
            and d._active_job == nil and (d._standby_ref or 0) == 0,
            "changed account entered a local finalize slice or stranded state")
        expect((waiting.workspace ~= nil) == resumable,
            "account rejection changed checkpoint preservation semantics")
    end
end

-- The default memory gate performs a full collection. It must never run
-- while a child from another producer still shares the parent's COW pages.
do
    local Budget = require("weread.lib.fork_budget")
    local exited, gate_calls = false, 0
    local runner = { run = function() return 989898 end,
        is_done = function(pid) assert(pid == 989898); return exited end }
    assert(Budget.run(runner, function() end))
    local d = Downloader:new{ memory_gate = function()
        gate_calls = gate_calls + 1
        expect(Budget.available(), "memory gate collected the heap while another child was alive")
        return true
    end }
    d._sleepInJob = function() coroutine.yield(); return true end
    local co = coroutine.create(function() d:_waitForMemory({}) end)
    assert(coroutine.resume(co))
    expect(coroutine.status(co) == "suspended" and gate_calls == 0,
        "waiting for the fork slot collected or blocked the UI")
    exited = true
    assert(coroutine.resume(co))
    expect(coroutine.status(co) == "dead" and gate_calls == 1,
        "memory was not checked after the slot became available")

    exited, gate_calls = false, 0
    assert(Budget.run(runner, function() end))
    local waiting = {}
    d._sleepInJob = function() waiting.cancelled = true; return true end
    d:_waitForMemory(waiting)
    expect(gate_calls == 0 and waiting.cancelled, "cancellation during slot waiting collected the heap")
    exited = true
    expect(Budget.available(), "cancelled wait interfered with the other producer's reaping")
end

print(("downloader_lifecycle_spec: %d checks"):format(checks))

restore_process()
