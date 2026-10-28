-- @title Public-account article lists remain responsive and cancellable
-- @timeout 40
-- @no_coverage Timing measures the real event loop, without LuaCov overhead.
return function(H)
    local UIManager = require("ui/uimanager")
    local TrapWidget = require("ui/widget/trapwidget")
    local ffiutil = require("ffi/util")
    local plugin, max_gap
    local book = { book_id = "MP_WXS_900000", title = "合成公众号" }
    H.step("delayed article list", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        H.mock_control({ match = "/web/mp/articles", delay = 1.5, times = 0 })
        local running, last = true, H.now_ms()
        max_gap = 0
        local function beat()
            if not running then return end
            local now = H.now_ms()
            max_gap, last = math.max(max_gap, now - last), now
            UIManager:scheduleIn(0.05, beat)
        end
        H.call(function() beat(); plugin:fetchMPArticles(book) end)
        H.wait_until("article list shown", function() return H.has_text("合成公众号文章") end, 15)
        H.call(beat)
        running = false
        H.metric("mp_list_heartbeat_gap_ms", max_gap)
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.close_dialogs()
    end)
    H.step("UI budget", function()
        H.check(max_gap < 800, "article list request keeps the UI responsive", tostring(max_gap))
    end)
    H.step("cancel article list without changing its cache or reopening UI", function()
        local previous = H.input_window()
        local saved = H.call(function() return plugin.settings:get_book(book.book_id).mp_articles_time end)
        local prior = #H.mock_requests(function(event) return event.path == "/web/mp/articles" end)
        local started_prior = H.mock_state().started_counts["/web/mp/articles"] or 0
        H.mock_control({ match = "/web/mp/articles", delay = 1.5, times = 0 })
        local worker_pid
        local launch = ffiutil.runInSubProcess
        local launched, launch_err = xpcall(function()
            H.call(function()
                ffiutil.runInSubProcess = function(...)
                    local pid, fd = launch(...)
                    worker_pid = pid
                    return pid, fd
                end
                plugin:fetchMPArticles(book)
            end)
            H.wait_until("dismissable article request", function()
                return worker_pid and getmetatable(H.input_window()) == TrapWidget
                    and (H.mock_state().started_counts["/web/mp/articles"] or 0) > started_prior
            end, 5)
        end, debug.traceback)
        H.call(function() ffiutil.runInSubProcess = launch end)
        if not launched then error(launch_err, 0) end
        local started = H.now_ms()
        H.tap_at(580, 20)
        H.wait_until("article request dismissed", function() return H.input_window() == previous end, 5)
        local elapsed = H.now_ms() - started
        H.metric("mp_list_cancel_ms", elapsed)
        H.check(elapsed < 800, "cancel does not wait for HTTP", tostring(elapsed))
        H.equal(plugin.busy_message, nil, "cancel clears busy state")
        H.wait_until("delayed service finished the cancelled request", function()
            return #H.mock_requests(function(event) return event.path == "/web/mp/articles" end) > prior
        end, 5)
        H.wait_until("cancelled Trapper worker has actually exited", function()
            return ffiutil.isSubProcessDone(worker_pid)
        end, 5)
        H.equal(H.input_window(), previous, "completed cancellation does not reopen article list")
        local current = H.call(function() return plugin.settings:get_book(book.book_id).mp_articles_time end)
        H.equal(current, saved, "cancelled response does not update parent article cache")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)
end
