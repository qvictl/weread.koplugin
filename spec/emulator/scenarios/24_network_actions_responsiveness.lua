-- @title Cookie renewal, progress lookup and reader URL parsing stay responsive
-- @timeout 90
-- @no_coverage Timing measures the real event loop without LuaCov overhead.
return function(H)
    local UIManager = require("ui/uimanager")
    local TrapWidget = require("ui/widget/trapwidget")
    local ffiutil = require("ffi/util")
    local plugin, reader_url
    H.step("setup", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        reader_url = require("weread.lib.protocol").reader_url("900006")
    end)
    local cases = {
        { name = "renew", endpoint = "/web/login/renewal", start = function() plugin:renewCookieWithUI() end,
            done = function() return H.has_text(H.tr("WeRead cookie renewed.")) end },
        { name = "progress", endpoint = "/book/getprogress", start = function() plugin:pullProgressWithUI("900001") end,
            done = function() return H.has_text((H.tr("Remote progress: %1%"):gsub("%%1", "0"))) end },
        { name = "reader_url", endpoint = "/web/reader/", start = function() plugin:parseReaderURLWithUI(reader_url) end,
            done = function() return plugin.settings:get_book("900006") end },
    }
    local gaps = {}
    for _, case in ipairs(cases) do
        H.step(case.name .. " delayed successful response", function()
            H.mock_control({ match = case.endpoint, delay = 1.5, times = 0 })
            local running, last, gap = true, H.now_ms(), 0
            local function beat()
                if not running then return end
                local now = H.now_ms(); gap, last = math.max(gap, now - last), now
                UIManager:scheduleIn(0.05, beat)
            end
            H.call(function() beat(); case.start() end)
            H.wait_until(case.name .. " result applied", case.done, 15)
            H.call(beat); running = false
            gaps[case.name] = gap
            H.metric(case.name .. "_heartbeat_gap_ms", gap)
            if case.name == "renew" then
                H.equal(plugin.settings:get("wr_ticket"), "mock-renewed-ticket", "renewal ticket merged in parent")
                H.equal(plugin.settings:get("cookies").wr_skey, "XXX_RENEWED_KEY", "renewal cookies merged in parent")
            elseif case.name == "reader_url" then
                H.equal(plugin.settings:get_book("900006").reader_url, reader_url, "parsed reader persisted in parent")
            end
            H.mock_control({ match = "", delay = 0, times = 0 })
            H.close_dialogs()
        end)
    end
    H.step("UI budget", function()
        for name, gap in pairs(gaps) do H.check(gap < 800, name .. " keeps event loop responsive", tostring(gap)) end
    end)
    for _, case in ipairs(cases) do
        H.step(case.name .. " real cancellation", function()
            local previous = H.input_window()
            local before_arrival = 0
            for key, count in pairs(H.mock_state().started_counts) do
                if key:find(case.endpoint, 1, true) == 1 then before_arrival = before_arrival + count end
            end
            local before_done = #H.mock_requests(function(event)
                return event.api == case.endpoint or event.path:find(case.endpoint, 1, true) == 1
            end)
            H.call(function()
                plugin.settings:delete_book("900006")
                plugin.settings:update_auth({ wr_ticket = "parent-ticket-sentinel" })
            end)
            local saved_key = plugin.settings:get("cookies").wr_skey
            H.mock_control({ match = case.endpoint, delay = 1.5, times = 0 })
            local pid, launch = nil, ffiutil.runInSubProcess
            local ok, err = xpcall(function()
                H.call(function()
                    ffiutil.runInSubProcess = function(...)
                        local child, fd = launch(...); pid = child; return child, fd
                    end
                    case.start()
                end)
                H.wait_until("request reached synthetic service", function()
                    -- Reader URLs have the encrypted ID suffix in the key.
                    local arrived = 0
                    for key, count in pairs(H.mock_state().started_counts) do
                        if key:find(case.endpoint, 1, true) == 1 then arrived = arrived + count end
                    end
                    return pid and getmetatable(H.input_window()) == TrapWidget and arrived > before_arrival
                end, 5)
            end, debug.traceback)
            H.call(function() ffiutil.runInSubProcess = launch end)
            if not ok then error(err, 0) end
            local started = H.now_ms()
            H.tap_at(580, 20)
            H.wait_until("cancelled action dismissed", function() return H.input_window() == previous end, 5)
            local elapsed = H.now_ms() - started
            H.metric(case.name .. "_cancel_ms", elapsed)
            H.check(elapsed < 800, "cancel remains responsive", tostring(elapsed))
            H.wait_until("cancelled task exited and synthetic response finished", function()
                return ffiutil.isSubProcessDone(pid) and #H.mock_requests(function(event)
                    return event.api == case.endpoint or event.path:find(case.endpoint, 1, true) == 1
                end) > before_done
            end, 5)
            H.equal(plugin.settings:get("wr_ticket"), "parent-ticket-sentinel", "cancel does not overwrite parent ticket")
            H.equal(plugin.settings:get("cookies").wr_skey, saved_key, "cancel does not overwrite parent cookies")
            H.equal(plugin.settings:get_book("900006"), nil, "cancelled parser does not persist a book")
            H.equal(H.input_window(), previous, "late response does not reopen action result")
            H.mock_control({ match = "", delay = 0, times = 0 })
        end)
    end
end
