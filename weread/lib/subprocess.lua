-- Coroutine adapter for BackgroundWorker's parent-owned process lifetime.
-- Unlike a dismissed Trapper call, the worker keeps its process reservation
-- until waitpid has collected the child, even after this coroutine returns.
local Process = {}

function Process.run(task, trap, _simple_string, options)
    options = options or {}
    local co, is_main = coroutine.running()
    if not co or is_main then return false, nil, "start_failed" end
    local UIManager = require("ui/uimanager")
    local Worker = require("weread.lib.background_worker")
    local directory = options.settings and options.settings.data_dir
    if not directory then return false, nil, "start_failed" end
    local worker = Worker:new{
        temp_dir = directory .. "/workers",
        poll_interval = 0.125,
        cancel_grace = 0,
        -- The task retains its existing request timeouts. A generic worker
        -- timeout must not shorten image batches or an updater extraction.
        timeout = options.timeout or math.huge,
    }
    if not worker:available() then return false, nil, "start_failed" end

    local owned = type(trap) ~= "table"
    if owned then
        trap = require("ui/widget/trapwidget"):new{
            text = type(trap) == "string" and trap or nil,
            resend_event = trap ~= false,
        }
        UIManager:show(trap)
        if trap.text then UIManager:forceRePaint() end
    end
    local previous = trap.dismiss_callback
    local cancelled, result, request
    local function wake()
        if coroutine.status(co) == "suspended" then coroutine.resume(co) end
    end
    local dismiss = function()
        cancelled = true
        if request then
            worker:cancel(request, "cancelled")
            -- Ask for immediate termination, but leave polling and the
            -- budget reservation alive until the actual child is reaped.
            worker:_poll()
        end
        wake()
    end
    trap.dismiss_callback = dismiss
    local started, handle = worker:start{
        task = task,
        before_launch = options.before_launch,
        on_done = function(value) result = value; wake() end,
    }
    if started then request = handle end
    if not started and not result then result = { error = handle } end
    while not result and not cancelled do coroutine.yield() end
    if trap.dismiss_callback == dismiss then trap.dismiss_callback = previous end
    if owned then UIManager:close(trap) end
    if cancelled or (result and result.cancelled) then
        return false, nil, result and result.error
    end
    if not result or not result.ok then
        return false, result and result.error, "start_failed"
    end
    return true, result.value
end

return Process
