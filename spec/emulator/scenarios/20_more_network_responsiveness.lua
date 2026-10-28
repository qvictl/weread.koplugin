-- @title Reviews, catalogs, statistics and cache scans keep the UI responsive
-- @timeout 100
-- @no_coverage Timing measures the real event loop, without LuaCov overhead.
return function(H)
    local UIManager = require("ui/uimanager")
    local TrapWidget = require("ui/widget/trapwidget")
    local plugin, book, catalog_done
    H.step("setup", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        book = H.call(function() return H.runtime().client:get_book_info("900001") end)
    end)
    local cases = {
        { name = "reviews", api = "/review/list", start = function() plugin:showBookReviews(book) end },
        { name = "catalog", api = "/web/book/chapterInfos", start = function()
            catalog_done = false
            plugin:loadChapters(book, function() catalog_done = true end, true)
        end },
        { name = "statistics", api = "/readdata/detail", start = function() plugin:loadReadStats("monthly") end },
        { name = "scan", api = "/shelf/sync", start = function() plugin:confirmScanLocalCache() end },
        { name = "new_dir", api = "/shelf/sync", start = function()
            plugin:offerScanNewDir(H.env.evidence .. "/empty-cache", "Synthetic scan finished")
        end },
    }
    local gaps = {}
    for _, case in ipairs(cases) do
        H.step(case.name .. " network delay", function()
            H.mock_control({ match = case.api, delay = 1.5, times = 0 })
            local running, last, max_gap = true, H.now_ms(), 0
            local function beat()
                if not running then return end
                local now = H.now_ms()
                max_gap, last = math.max(max_gap, now - last), now
                UIManager:scheduleIn(0.05, beat)
            end
            local prior = #H.mock_requests(function(event) return event.api == case.api or event.path == case.api end)
            H.call(function() beat(); case.start() end)
            H.sleep(0.2)
            H.wait_until(case.name .. " completed", function()
                local count = #H.mock_requests(function(event) return event.api == case.api or event.path == case.api end)
                local top = H.input_window()
                return count > prior and not plugin.busy_message
                    and (not top or getmetatable(top) ~= TrapWidget)
            end, 20)
            if case.name == "catalog" then H.check(catalog_done, "catalog callback delivered in parent") end
            H.sleep(0.1)
            running = false
            gaps[case.name] = max_gap
            H.metric(case.name .. "_heartbeat_gap_ms", max_gap)
            H.mock_control({ match = "", delay = 0, times = 0 })
            H.call(function() plugin:closeWeReadUI() end)
            H.close_dialogs()
        end)
    end
    H.step("UI budget", function()
        for name, gap in pairs(gaps) do
            H.check(gap < 800, name .. " request keeps the event loop responsive", tostring(gap))
        end
    end)
    for _, case in ipairs(cases) do
        H.step(case.name .. " cancellation", function()
            local previous = H.input_window()
            local prior = #H.mock_requests(function(event) return event.api == case.api or event.path == case.api end)
            book.psvts = "parent-session"
            H.mock_control({ match = case.api, delay = 1.5, times = 0 })
            H.call(case.start)
            H.wait_until("dismissable request shown", function()
                return getmetatable(H.input_window()) == TrapWidget
            end, 5)
            H.sleep(0.2)
            local started = H.now_ms()
            H.tap_at(580, 20)
            H.wait_until("request dismissed", function() return H.input_window() == previous end, 5)
            local elapsed = H.now_ms() - started
            H.metric(case.name .. "_cancel_ms", elapsed)
            H.check(elapsed < 800, "tap cancels without waiting for HTTP", tostring(elapsed))
            H.equal(plugin.busy_message, nil, "busy state released on cancel")
            H.sleep(1.7)
            H.check(#H.mock_requests(function(event) return event.api == case.api or event.path == case.api end) > prior,
                "cancelled worker reached the delayed endpoint")
            H.equal(H.input_window(), previous, "cancelled response does not reopen UI")
            if case.name == "catalog" then
                H.check(not catalog_done, "cancelled catalog does not call its parent callback")
                H.equal(book.psvts, "parent-session", "cancelled reader state does not overwrite parent state")
            end
            H.mock_control({ match = "", delay = 0, times = 0 })
        end)
    end
end
