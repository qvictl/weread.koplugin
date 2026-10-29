-- One live WeRead child at a time, including children cancelled by their UI.
-- Keep each child's handle after reaping: waitpid consumes the exit status,
-- and checking that numeric pid again could accidentally observe a reused pid.
local Budget = {}
local MemoryGate = require("weread.lib.memory_gate")
local active
local waiting = {}

function Budget.withdraw(request)
    for index, queued in ipairs(waiting) do
        if queued == request then table.remove(waiting, index); return end
    end
end

function Budget.wait(request)
    for _, queued in ipairs(waiting) do if queued == request then return end end
    waiting[#waiting + 1] = request
end

function Budget.is_done(child)
    if child.reaped then return true end
    if not child.pid then return false end
    if not child.runner.is_done(child.pid) then return false end
    child.reaped = true
    if active == child then active = nil end
    return true
end

function Budget.available(request)
    if active then
        local ok, done = pcall(Budget.is_done, active)
        if not ok or not done then return false end
    end
    -- A full-book continuation must not take every newly free slot before
    -- an interactive request already waiting on the UI loop gets a turn.
    return not waiting[1] or waiting[1] == request
end

-- runner.run must return synchronously after fork; task runs only in the child.
-- The optional third result owns the pid until its exact exit is collected.
function Budget.run(runner, task, request)
    if not Budget.available(request) then return nil, "worker_busy" end
    -- QR and cover runners also pass here. Reading the floor does not run
    -- another full GC after their caller already checked its own heap gate.
    local available = MemoryGate.parse_available_kb(MemoryGate.read_meminfo())
    if available and available < MemoryGate.DEFAULT_MIN_AVAILABLE_KB then
        return nil, "low_memory"
    end
    if request then Budget.withdraw(request) end
    local child = { runner = runner }
    active = child
    local ok, pid, read_fd = pcall(runner.run, task)
    if not ok or not pid then
        if active == child then active = nil end
        if not ok then error(pid, 0) end
        return pid, read_fd
    end
    child.pid = pid
    return pid, read_fd, child
end

function Budget.terminate(child)
    if child.reaped then return end
    -- Cancellation asks for termination; only waitpid releases the slot.
    child.runner.terminate(child.pid)
end

return Budget
