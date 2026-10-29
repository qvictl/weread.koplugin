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
local Memory = require("weread.lib.memory_gate")
Memory.read_meminfo = function() return nil end -- unknown memory still permits work.
local Process = require("weread.lib.subprocess")
local Budget = require("weread.lib.fork_budget")
local H = require("spec.helpers.read_report_harness")
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
    end)
    expect(coroutine.resume(co), "coroutine failed")
    return co, function() return outcome end
end
local ok, err = xpcall(function()
    local first, second = {}, {}
    local co_a, result_a = start(first)
    local old_dismiss = first.dismiss_callback
    local co_b, result_b = start(second)
    expect(launched == 1 and coroutine.status(co_b) == "suspended", "second coroutine forked concurrently")
    local runner = H.runner()
    local report = H.new_report{ subprocess = runner }
    local accepted, reason = report:_spawn_job({ book_id = "book" }, function() end)
    expect(not accepted and reason == "worker_busy" and runner.forks == 0,
        "reading report bypassed the shared process budget")
    pump(3)
    expect(launched == 1, "waiting coroutine spawned while first child was alive")
    first.dismiss_callback()
    expect(coroutine.status(co_a) == "dead" and result_a()[1] == false,
        "cancel did not return control to the parent")
    expect(signalled[1] == 1 and not Budget.available(), "cancel released an unreaped process")
    pump(3)
    expect(launched == 1, "terminate-no-op admitted another child")
    children[1].done = true
    pump(8)
    expect(launched == 2 and children[1].reaped, "waiting task did not start after exact reaping")
    old_dismiss()
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
    children[4].task(); children[4].done = true
    pump(5)
    expect(coroutine.status(co_string) == "dead" and string_result()[1] and next(shown) == nil,
        "owned trap was not closed after success")
    local did_run = false
    expect(not Process.run(function() did_run = true end, {}, false, { settings = {data_dir="/data"} }),
        "unwrapped task fell back to inline work")
    expect(not did_run, "network ran on the UI loop")
end, debug.traceback)
rawset(io, "open", real_open)
rawset(os, "remove", real_remove)
rawset(os, "rename", real_rename)
if not ok then error(err, 0) end
print("subprocess_budget_spec: " .. checks .. " checks")
