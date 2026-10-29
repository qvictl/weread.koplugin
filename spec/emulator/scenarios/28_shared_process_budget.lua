-- @title A cancelled HTTP worker keeps the shared process slot until exact reaping
-- @timeout 60
-- @no_coverage Real process lifetime and UI heartbeat without instrumentation.
return function(H)
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local Budget = require("weread.lib.fork_budget")
    local plugin, spawn, done, terminate
    local live, launched, maximum, signals = {}, 0, 0, 0
    local handles, results = {}, {}
    local running, last, gap = true, H.now_ms(), 0
    local function beat()
        local now = H.now_ms(); gap = math.max(gap, now - last); last = now
        if running then UIManager:scheduleIn(0.05, beat) end
    end
    local function start(index)
        local trap = {}
        handles[index] = trap
        plugin:_runNetworkRequest(trap, "Budget probe", function()
            return plugin.client:get_book_info("900001")
        end, function(value) results[index] = { value = value } end,
        function(err, cancelled) results[index] = { error = err, cancelled = cancelled } end)
    end
    local ok, err = xpcall(function()
        H.step("hold real HTTP and queue another user request", function()
            plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
            H.mock_control({ match = "/book/info", hold_response = true, times = 0 })
            H.call(function()
                spawn, done, terminate = ffiutil.runInSubProcess, ffiutil.isSubProcessDone, ffiutil.terminateSubProcess
                ffiutil.runInSubProcess = function(...)
                    local pid, fd = spawn(...)
                    if pid then
                        live[pid] = true; launched = launched + 1
                        local count = 0; for _ in pairs(live) do count = count + 1 end
                        maximum = math.max(maximum, count)
                    end
                    return pid, fd
                end
                ffiutil.isSubProcessDone = function(pid, ...)
                    local exited = done(pid, ...)
                    if exited then live[pid] = nil end
                    return exited
                end
                -- A cancellation request must not count as process exit.
                ffiutil.terminateSubProcess = function() signals = signals + 1 end
                beat(); start(1)
            end)
            H.wait_until("first real request reaches service", function()
                return (H.mock_state().started_counts["/book/info"] or 0) >= 1
            end, 5)
            H.call(function()
                start(2)
                local accepted, reason = plugin.read_report:_spawn_job({ book_id = "900001" }, function() end)
                H.check(not accepted and reason == "worker_busy", "read report shares the foreground budget")
                H.check(not plugin.qr_login:_start_poll_job("synthetic-budget", plugin.qr_login.generation),
                    "QR poll cannot bypass the held process")
            end)
            H.sleep(0.35)
            H.equal(launched, 1, "queued requests do not fork while another worker is alive")
            H.check(not results[1] and not results[2], "both operations still await the held response")
        end)
        H.step("cancel returns immediately but a live child still owns the slot", function()
            local started = H.now_ms()
            H.call(function() handles[1].dismiss_callback() end)
            H.wait_until("active request cancellation callback", function() return results[1] end, 2)
            H.metric("budget_cancel_ms", H.now_ms() - started)
            H.check(results[1].cancelled, "cancelled request reports cancellation")
            H.check(signals >= 1 and not Budget.available(), "termination request does not release a live pid")
            H.sleep(0.35)
            H.equal(launched, 1, "terminate-no-op does not admit the queued worker")
            H.check(not results[2], "queued result is not fabricated")
        end)
        H.step("actual reaping admits the queued request without late publication", function()
            H.mock_control({ hold_response = false })
            H.wait_until("second request completes after first child exits", function() return results[2] end, 10)
            H.check(results[2].value and not results[2].error, "queued real HTTP delivers its result")
            H.equal(launched, 2, "only the two user requests forked")
            H.equal(maximum, 1, "at most one WeRead worker was alive")
            H.check(results[1].cancelled and not results[1].value, "cancelled response never publishes later")
            H.call(function() H.check(Budget.available(), "final child is reaped") end)
            H.equal(next(live), nil, "all tracked children have exited")
            H.metric("budget_max_live_workers", maximum)
            H.metric("budget_heartbeat_gap_ms", gap)
            H.check(gap < 800, "waiting and cancellation preserve the UI heartbeat", tostring(gap))
        end)
        H.step("the worker boundary preserves arbitrary image and cover bytes", function()
            local result
            local bytes = string.char(0, 255, 128, 13, 10, 34, 92)
            H.call(function()
                require("ui/trapper"):wrap(function()
                    local completed, value = require("weread.lib.subprocess").run(function()
                        return { cover_data = bytes, assets = { { data = bytes } } }
                    end, {}, false, { settings = plugin.settings })
                    result = { completed = completed, value = value }
                end)
            end)
            H.wait_until("binary result delivered to parent", function() return result end, 5)
            H.check(result.completed, "binary worker completed")
            H.equal(result.value.cover_data, bytes, "cover bytes round-trip unchanged")
            H.equal(result.value.assets[1].data, bytes, "image bytes round-trip unchanged")
            H.check(Budget.available(), "binary result child was reaped")
        end)
    end, debug.traceback)
    running = false
    H.mock_control({ hold_response = false, match = "", delay = 0, times = 0 })
    H.call(function()
        if spawn then ffiutil.runInSubProcess = spawn end
        if done then ffiutil.isSubProcessDone = done end
        if terminate then ffiutil.terminateSubProcess = terminate end
    end)
    if not ok then error(err, 0) end
end
