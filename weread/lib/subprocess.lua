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
    local ok_codec, codec = pcall(require, "string.buffer")
    if not ok_codec then return false, nil, "start_failed" end
    local directory = options.settings and options.settings.data_dir
    if not directory then return false, nil, "start_failed" end
    local worker = Worker:new{
        temp_dir = directory .. "/workers",
        -- Chapter results contain raw images. Use the same binary codec as
        -- KOReader's Trapper rather than treating arbitrary bytes as JSON text.
        result_codec = codec,
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
            resend_event = type(trap) ~= "string" and trap ~= false,
        }
        UIManager:show(trap)
        if trap.text then UIManager:forceRePaint() end
    end
    local previous = trap.dismiss_callback
    local cancelled, finished, result, request
    local function wake()
        if coroutine.status(co) == "suspended" then
            local ok = coroutine.resume(co)
            if not ok then require("weread.lib.logger").warn("worker parent coroutine failed") end
        end
    end
    local dismiss = function()
        if finished then return end
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
        before_launch = function()
            if options.before_launch then
                local current, reason = options.before_launch()
                if not current then return false, reason end
            end
            if options.required_memory_kb then worker.min_available_kb = options.required_memory_kb() end
            return true
        end,
        on_done = function(value)
            if finished or cancelled then return end
            result = value; wake()
        end,
    }
    if started then request = handle end
    if not started and not result then result = { error = handle } end
    while not result and not cancelled do coroutine.yield() end
    finished = true
    if trap.dismiss_callback == dismiss then trap.dismiss_callback = previous end
    if owned then UIManager:close(trap) end
    if cancelled then return false end
    if result and result.cancelled then
        return false, nil, result and result.error
    end
    if not result or not result.ok then
        if result and result.error == "low_memory" then return false, nil, "low_memory" end
        return false, result and result.error, "start_failed"
    end
    return true, result.value
end

return Process
