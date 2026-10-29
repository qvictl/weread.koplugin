-- Actual coroutine adapter + BackgroundWorker + report admission. Only the
-- operating-system runner and its IPC files are replaced with deterministic fakes.
package.path = "./?.lua;./?/init.lua;" .. package.path
local checks, queue, files, children, shown = 0, {}, {}, {}, {}
local launched, signalled = 0, {}
local function expect(value, text) checks = checks + 1; assert(value, text) end
local UI = {
    scheduleIn = function(_, _, fn) queue[#queue + 1] = fn end,
    show = function(_, widget) shown[widget] = true end,
    close = function(_, widget) shown[widget] = nil end,
    forceRePaint = function() end,
}
package.preload["ui/uimanager"] = function() return UI end
package.preload["ui/widget/trapwidget"] = function() return { new = function(_, value) return value end } end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path) return path == "/data/workers" and "directory" or files[path] end }
end
local ffi = {
    isAndroid = function() return false end,
    runInSubProcess = function(task)
        launched = launched + 1
        children[launched] = { task = task }
        return launched
    end,
    isSubProcessDone = function(pid)
        expect(not children[pid].reaped, "waitpid was repeated after reaping")
        if children[pid].done then children[pid].reaped = true; return true end
        return false
    end,
    terminateSubProcess = function(pid) signalled[#signalled + 1] = pid end,
}
package.preload["ffi/util"] = function() return ffi end
require("ffi/util")
local json_values = {}
package.preload["json"] = function()
    return {
        encode = function(value) json_values[#json_values + 1] = value; return tostring(#json_values) end,
        decode = function(value) return assert(json_values[tonumber(value)]) end,
    }
end
-- The codec's actual arbitrary-byte round trip is covered in emulator28.
-- This spec replaces OS execution and IPC encoding with in-memory tokens.
package.preload["string.buffer"] = function() return require("json") end
local Memory = require("weread.lib.memory_gate")
Memory.read_meminfo = function() return nil end -- unknown memory still permits work.
local Process = require("weread.lib.subprocess")
local Budget = require("weread.lib.fork_budget")
local H = require("spec.helpers.read_report_harness")
local replaced_modules = {}
local function replace_module(name, value)
    replaced_modules[#replaced_modules + 1] = { name = name, value = package.loaded[name] }
    package.loaded[name] = value
end
local real_open, real_remove, real_rename = io.open, os.remove, os.rename
rawset(io, "open", function(path, mode)
    if mode == "rb" then
        if files[path] == nil then return nil end
        return { read = function() return files[path] end, close = function() end }
    end
    files[path] = ""
    return { write = function(_, value) files[path] = value; return true end, close = function() end }
end)
rawset(os, "remove", function(path) files[path] = nil; return true end)
rawset(os, "rename", function(from, to) files[to], files[from] = files[from], nil; return true end)
local function pump(count)
    for _ = 1, count do local fn = table.remove(queue, 1); if fn then fn() end end
end
local function start(trap, options)
    local outcome
    local co = coroutine.create(function()
        outcome = { Process.run(function() return "from child" end, trap, false,
            options or { settings = { data_dir = "/data" } }) }
        if type(trap) == "table" and trap.keep_waiting then
            coroutine.yield()
            trap.resumed = true
        end
    end)
    expect(coroutine.resume(co), "coroutine failed")
    return co, function() return outcome end
end
local ok, err = xpcall(function()
    local first, second = { keep_waiting = true }, {}
    local co_a, result_a = start(first)
    local old_dismiss = first.dismiss_callback
    local co_b, result_b = start(second)
    expect(launched == 1 and coroutine.status(co_b) == "suspended", "second coroutine forked concurrently")
    local runner = H.runner()
    local report = H.new_report{ subprocess = runner,
        memory_gate = function() error("busy report must not collect the shared parent heap") end }
    local accepted, reason = report:_spawn_job({ book_id = "book" }, function() end)
    expect(not accepted and reason == "worker_busy" and runner.forks == 0,
        "reading report bypassed the shared process budget")
    pump(3)
    expect(launched == 1, "waiting coroutine spawned while first child was alive")
    first.dismiss_callback()
    expect(coroutine.status(co_a) == "suspended" and result_a()[1] == false,
        "cancel did not return control to the parent")
    expect(signalled[1] == 1 and not Budget.available(), "cancel released an unreaped process")
    pump(3)
    expect(launched == 1, "terminate-no-op admitted another child")
    children[1].done = true
    pump(8)
    expect(not first.resumed, "late cancelled worker resumed its parent during another wait")
    expect(launched == 2 and children[1].reaped, "waiting task did not start after exact reaping")
    old_dismiss()
    expect(not first.resumed, "stale dismissal resumed its parent during another wait")
    expect(coroutine.resume(co_a) and first.resumed, "parent could not finish its independent wait")
    expect(#signalled == 1 and not Budget.available(), "stale cancellation signalled the new child")
    children[2].task()
    children[2].done = true
    pump(8)
    expect(coroutine.status(co_b) == "dead" and result_b()[1] and result_b()[2] == "from child",
        "worker result was not delivered in the parent")
    expect(Budget.available(), "successful task leaked its reservation")

    local owner_current = true
    local holding = {}
    local _, holding_result = start(holding)
    local co_stale, stale_result = start({}, { settings = { data_dir = "/data" },
        before_launch = function() return owner_current, "account_changed" end })
    owner_current = false
    children[3].task(); children[3].done = true
    pump(10)
    expect(holding_result()[1] and coroutine.status(co_stale) == "dead", "pending owner check did not finish")
    expect(launched == 3 and not stale_result()[1] and stale_result()[3] == "account_changed",
        "stale queued task performed a fork")
    local co_string, string_result = start("Loading")
    expect(next(shown) ~= nil, "visible task did not show its cancellable trap")
    expect(next(shown).resend_event == false, "cancelling a visible request would replay its tap on the underlying UI")
    children[4].task(); children[4].done = true
    pump(5)
    expect(coroutine.status(co_string) == "dead" and string_result()[1] and next(shown) == nil,
        "owned trap was not closed after success")
    local required = 96 * 1024
    start({})
    local co_memory, memory_result = start({}, { settings = { data_dir = "/data" },
        required_memory_kb = function() return required end })
    required = 160 * 1024 -- the parent grew while this task waited for admission.
    files["/proc/meminfo"] = "MemAvailable: 131072 kB\n"
    children[5].task(); children[5].done = true
    pump(10)
    expect(launched == 5 and coroutine.status(co_memory) == "dead"
        and not memory_result()[1] and memory_result()[3] == "low_memory",
        "queued download used the stale or generic 64 MiB memory requirement")
    expect(Budget.available(), "late memory refusal blocked later tasks")
    files["/proc/meminfo"] = nil
    local co_failed, failed_result = start({}, { settings = { data_dir = "/data" },
        before_launch = function() error("lifetime check failed") end })
    expect(coroutine.status(co_failed) == "dead" and not failed_result()[1]
        and failed_result()[2]:find("lifetime check failed", 1, true) and Budget.available(),
        "a failing admission callback leaked the budget or coroutine")
    start({})
    local pending_trap = {}
    local co_pending, pending_result = start(pending_trap)
    pending_trap.dismiss_callback()
    expect(coroutine.status(co_pending) == "dead" and not pending_result()[1] and launched == 6,
        "cancelling a queued task forked or failed to return")
    expect(pending_result()[2] == nil and pending_result()[3] == nil
        and result_a()[2] == nil and result_a()[3] == nil,
        "queued and running user cancellation returned different failure protocols")
    children[6].task(); children[6].done = true
    pump(10)
    expect(Budget.available() and launched == 6, "cancelled waiter stayed ahead of new work")
    local did_run = false
    expect(not Process.run(function() did_run = true end, {}, false, { settings = {data_dir="/data"} }),
        "unwrapped task fell back to inline work")
    expect(not did_run, "network ran on the UI loop")

    -- Actual annotation producer + actual shared worker: admission ownership
    -- must survive both queues while an unrelated live worker holds the slot.
    replace_module("weread.lib.plugin_util", { tr = function(x) return x end, T = function(x) return x end })
    replace_module("weread.lib.annotation_chapters", {})
    replace_module("weread.lib.standby_guard", { acquire = function() return {} end, release = function() end })
    local observed
    replace_module("weread.lib.annotation_prefetch_worker", { run = function(settings, _, context)
        observed = { uid = settings:get("account").user_vid, book = context.book_id }
        return {}
    end })
    replace_module("weread.ui.annotation_sync_controller", nil)
    local Controller = require("weread.ui.annotation_sync_controller")
    local Worker = require("weread.lib.background_worker")
    local Owner = require("weread.lib.request_owner")
    for _, change in ipairs({ "uid", "api_key", "ticket" }) do
        observed = nil
        local held_pid = launched + 1
        start({})
        local values = { account = { user_vid = "A" }, cookies = { wr_vid = "A" }, api_key = "gateway-A",
            cache = { auto_prefetch_next_chapter = true, prefetch_annotations = true } }
        local settings = { data_dir = "/data", get = function(_, key, fallback) return values[key] or fallback end }
        local request = { owner = Owner.capture(settings) }
        local plugin = setmetatable({ settings = settings, client = {}, _external_annotation_sync = request,
            isNetworkConnected = function() return true end,
            prefetch_worker = Worker:new{ temp_dir = "/data/workers" } }, { __index = Controller })
        expect(plugin:_runAnnotationPrefetchWorker(request, { book_id = "A-book", chapters = {} }, {}),
            "annotation prefetch was not accepted")
        expect(plugin.prefetch_worker.pending and launched == held_pid, "annotation did not queue behind the blocker")
        plugin:_runAnnotationJob({ book_id = "A-next", owner = request.owner }, { background = true, prefetch = true })
        expect(plugin._annotation_pending_prefetch.owner == request.owner, "second queue lost its owner")
        if change == "uid" then values.account = { user_vid = "B" }; values.cookies = { wr_vid = "B" }
        elseif change == "api_key" then values.api_key = "gateway-B"
        else values.wr_ticket = "rotated-ticket" end
        children[held_pid].task(); children[held_pid].done = true
        pump(12)
        if change ~= "ticket" then
            expect(launched == held_pid and not observed and not plugin._external_annotation_sync
                and not plugin._annotation_pending_prefetch, "queued annotation adopted another account or gateway")
        else
            plugin._annotation_pending_prefetch = nil
            expect(launched == held_pid + 1, "same-account ticket rotation was rejected")
            children[launched].task(); children[launched].done = true
            pump(10)
            expect(observed and observed.uid == "A" and observed.book == "A-book",
                "same-account annotation did not retain its original context")
        end
    end
    local subsequent_wait = { keep_waiting = true }
    local co_waiting, waiting_result = start(subsequent_wait)
    local completed_dismiss = subsequent_wait.dismiss_callback
    children[launched].task(); children[launched].done = true
    pump(10)
    expect(waiting_result()[1] and coroutine.status(co_waiting) == "suspended",
        "successful operation did not enter its next independent wait")
    completed_dismiss()
    expect(not subsequent_wait.resumed, "completed trap resumed a later parent wait")
    expect(coroutine.resume(co_waiting) and subsequent_wait.resumed, "later parent wait was stranded")
    local failed_parent = coroutine.create(function()
        Process.run(function() return true end, {}, false, { settings = { data_dir = "/data" } })
        error("synthetic-private-auth")
    end)
    expect(coroutine.resume(failed_parent), "failure probe did not start")
    children[launched].task(); children[launched].done = true
    pump(10)
    expect(H.count_logs("warn", "worker parent coroutine failed") == 1, "resume failure was silently dropped")
    for _, log in ipairs(H.logs) do
        expect(not log.text:find("synthetic-private-auth", 1, true), "resume failure leaked its error contents")
    end
end, debug.traceback)
rawset(io, "open", real_open)
rawset(os, "remove", real_remove)
rawset(os, "rename", real_rename)
for index = #replaced_modules, 1, -1 do
    local entry = replaced_modules[index]
    package.loaded[entry.name] = entry.value
end
if not ok then error(err, 0) end
print("subprocess_budget_spec: " .. checks .. " checks")
