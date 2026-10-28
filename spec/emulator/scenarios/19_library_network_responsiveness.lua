-- @title Bookshelf, book details and search keep the UI responsive during network waits
-- @timeout 90
-- @no_coverage Timing measures the real event loop, without LuaCov overhead.
return function(H)
    local UIManager = require("ui/uimanager")
    local TrapWidget = require("ui/widget/trapwidget")
    local plugin, book
    H.step("setup", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        book = H.call(function() return H.runtime().client:get_book_info("900001") end)
    end)

    local cases = {
        { name = "shelf", api = "/shelf/sync",
            start = function() plugin:refreshBookshelf() end,
            done = function() return plugin.shelf_view and not plugin.shelf_refreshing end },
        { name = "details", api = "/book/info",
            start = function() plugin:refreshBookRecord(book) end,
            done = function() return book.detail_updated_at end },
        { name = "search", api = "/store/search",
            start = function() plugin:searchWithUI("山谷") end,
            done = function() return H.has_text((H.tr("Search: %1"):gsub("%%1", "山谷"))) end },
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
            H.call(function() beat(); case.start() end)
            H.wait_until(case.name .. " rendered", case.done, 20)
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
            book.detail_updated_at = nil
            local prior = #H.mock_requests(function(event) return event.api == case.api end)
            H.mock_control({ match = case.api, delay = 1.5, times = 0 })
            H.call(case.start)
            H.wait_until("dismissable request shown", function()
                local top = H.input_window()
                return top and getmetatable(top) == TrapWidget
            end, 5)
            H.sleep(0.2)
            local started = H.now_ms()
            H.tap_at(580, 20)
            H.wait_until("request dismissed", function()
                local top = H.input_window()
                return not top or getmetatable(top) ~= TrapWidget
            end, 5)
            local elapsed = H.now_ms() - started
            H.metric(case.name .. "_cancel_ms", elapsed)
            H.check(elapsed < 800, "tap cancels without waiting for HTTP", tostring(elapsed))
            H.equal(plugin.busy_message, nil, "busy message released on cancel")
            H.equal(plugin.shelf_refreshing, nil, "shelf refresh lock released on cancel")
            H.sleep(1.7)
            H.check(#H.mock_requests(function(event) return event.api == case.api end) > prior,
                "cancelled worker reached the delayed mock endpoint")
            H.check(not case.done(), "cancelled response does not update or reopen UI")
            H.mock_control({ match = "", delay = 0, times = 0 })
        end)
    end
    H.step("automatic detail cancellation keeps the local book accessible", function()
        H.mock_control({ match = "/book/info", delay = 1.5, times = 0 })
        H.call(function() plugin:refreshBookRecord(book, nil, { automatic = true }) end)
        H.wait_until("automatic detail request shown", function()
            return getmetatable(H.input_window()) == TrapWidget
        end, 5)
        H.tap_at(580, 20)
        local view = H.wait_until("local book menu shown", function()
            local current = plugin._book_detail_view
            return current and UIManager:isWidgetShown(current) and current
        end, 5)
        H.equal(plugin.busy_message, nil, "automatic cancel clears busy state")
        H.sleep(1.7)
        H.equal(plugin._book_detail_view, view, "late response does not replace the local menu")
        H.equal(book.detail_updated_at, nil, "cancelled automatic request does not apply remote details")
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.call(function() plugin:closeWeReadUI() end)
    end)
    H.step("queued QR completion cannot write an old shelf into the new account", function()
        H.mock_control({ match = "/shelf/sync", delay = 1.5, times = 0 })
        H.call(function()
            -- The mock QR protocol signs in as 900000. Empty that account's
            -- shelf first, then start the delayed request as another account.
            plugin.library_db:cacheShelf({}, {})
            plugin.settings:set("account", { user_vid = "900099" })
            plugin:refreshBookshelf()
            UIManager:scheduleIn(0.35, function()
                plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                    accessToken = "mock-access-token", refreshToken = "mock-refresh-token" },
                    plugin.qr_login.generation)
            end)
        end)
        H.wait_until("real mock QR completion and old request finish", function()
            return plugin.settings:get("account", {}).user_vid == "900000"
                and not plugin.shelf_refreshing
        end, 10)
        local shelf = H.call(function() return plugin.library_db:getShelf() end)
        H.equal(#shelf, 0, "old request must not populate the new account's shelf")
        H.equal(plugin.shelf_view, nil, "old request must not reopen a shelf after account switch")
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.close_dialogs()
    end)
end
