package.path = "./?.lua;./?/init.lua;" .. package.path
local Budget = require("weread.lib.fork_budget")
local Memory = require("weread.lib.memory_gate")
local read_memory = Memory.read_meminfo
Memory.read_meminfo = function() return "MemAvailable: 1048576 kB\n" end
local checks, next_pid, exits, signals = 0, 100, {}, {}
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local runner = {
    run = function() next_pid = next_pid + 1; return next_pid, 7 end,
    is_done = function(pid)
        local done = exits[pid]
        if done then exits[pid] = nil end -- waitpid consumes the exit status.
        return done == true
    end,
    terminate = function(pid) signals[#signals + 1] = pid end,
}
local succeeded, failure_message = xpcall(function()
local pid, fd, first = Budget.run(runner, function() end)
expect(pid == 101 and fd == 7 and not Budget.available(), "live child owns the budget")
local second, reason = Budget.run(runner, function() end)
expect(second == nil and reason == "worker_busy" and next_pid == 101, "second task forked")
Budget.terminate(first)
expect(signals[1] == 101 and not Budget.available(), "cancellation released a live child")
expect(not Budget.available(), "terminate-no-op stopped reserving the child")
exits[101] = true
expect(Budget.available() and Budget.is_done(first), "exact reaping did not release the slot")
local _, _, current = Budget.run(runner, function() end)
expect(current.pid == 102 and not Budget.available(), "next task did not acquire")
expect(Budget.is_done(first) and not Budget.available(), "old handle released the newer child")
Budget.terminate(first)
expect(#signals == 1, "reaped pid was signalled again")
exits[102] = true
expect(Budget.is_done(current) and Budget.available(), "current child not collected")
local failed = { run = function() return nil, "fork failed" end }
local no_pid, failure = Budget.run(failed, function() end)
expect(no_pid == nil and failure == "fork failed" and Budget.available(), "fork failure leaked slot")
local throwing = { run = function() error("fork exception") end }
local ok, err = pcall(Budget.run, throwing, function() end)
expect(not ok and tostring(err):find("fork exception", 1, true) and Budget.available(), "spawn exception leaked slot")
local _, _, holding = Budget.run(runner, function() end)
local older, newer = {}, {}
Budget.wait(older); Budget.wait(newer); Budget.wait(older)
exits[holding.pid] = true
local jumped, busy = Budget.run(runner, function() end)
expect(not jumped and busy == "worker_busy", "new continuation bypassed a queued request")
expect(not Budget.available(newer) and Budget.available(older), "waiting order was not FIFO")
local _, _, admitted = Budget.run(runner, function() end, older)
expect(admitted and not Budget.available(newer), "second queued task overlapped the admitted one")
Budget.withdraw(newer)
exits[admitted.pid] = true
expect(Budget.available(), "cancelled waiter blocked all later work")
Memory.read_meminfo = function() return "MemAvailable: 64000 kB\n" end
local before = next_pid
local denied, memory_reason = Budget.run(runner, function() end)
expect(not denied and memory_reason == "low_memory" and next_pid == before and Budget.available(),
    "a raw runner bypassed the shared memory floor")
Memory.read_meminfo = function() return nil end
local _, _, unknown = Budget.run(runner, function() end)
expect(unknown ~= nil, "unknown memory permanently blocked the budget")
exits[unknown.pid] = true
expect(Budget.available(), "unknown-memory task did not release its slot")
end, debug.traceback)
Memory.read_meminfo = read_memory
if not succeeded then error(failure_message, 0) end
print("fork_budget_spec: " .. checks .. " checks")
