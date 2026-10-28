-- @title QR start, OTP and credential completion keep the UI responsive
-- @timeout 100
-- @no_coverage Real event-loop timing, without instrumentation overhead.
return function(H)
    local UIManager = require("ui/uimanager")
    local TrapWidget = require("ui/widget/trapwidget")
    local InputDialog = require("ui/widget/inputdialog")
    local plugin, otp_dialog, poll_runner
    local good = { succeed = true, webLoginVid = "900000",
        accessToken = "mock-access-token", refreshToken = "mock-refresh-token" }
    local function input_dialog()
        for _, widget in ipairs(H.windows()) do
            if getmetatable(widget) == InputDialog then return widget end
        end
    end
    local function account()
        return H.call(function() return plugin.settings:get("account", {}).user_vid end)
    end
    local function reset()
        H.call(function()
            plugin.qr_login:cancel()
            plugin.qr_login.subprocess = poll_runner
            plugin.settings:reset_account()
            plugin:onWeReadAccountChanged()
        end)
        H.close_dialogs()
    end
    local cases = {
        { name = "start", path = "/api/auth/getLoginUid",
            start = function() plugin.qr_login:start() end,
            done = function() return plugin.qr_login.qr_dialog end },
        { name = "otp", path = "/api/auth/getLoginInfo",
            start = function()
                plugin.qr_login:_show_otp("mock-login-uid", plugin.qr_login.generation)
            end,
            prepare = function()
                otp_dialog = H.wait_until("OTP painted", input_dialog, 5)
                H.call(function() otp_dialog:setInputText("0000") end)
            end,
            tap = function() H.tap_exact(H.tr("Verify"), 5, input_dialog) end,
            done = function()
                local d = input_dialog()
                return d and d ~= otp_dialog and H.has_text(H.tr("Incorrect verification code."), d)
            end },
        { name = "poll_fallback", path = "/api/auth/getLoginInfo",
            start = function()
                plugin.qr_login.subprocess = nil
                plugin.qr_login.started_at = os.time()
                plugin.qr_login:_show_qr("mock-login-uid", plugin.qr_login.generation)
            end,
            done = function() return input_dialog() end },
        { name = "complete", path = "/api/userInfo",
            start = function() plugin.qr_login:_complete(good, plugin.qr_login.generation) end,
            done = function() return plugin.settings:get("account", {}).user_vid == "900000" end },
    }
    H.step("setup", function()
        plugin = H.wait_until("plugin attached", H.plugin, 20)
        poll_runner = plugin.qr_login.subprocess
        reset()
    end)
    for _, case in ipairs(cases) do
        H.step(case.name .. " HTTP delay and cancel", function()
            for _, cancel in ipairs({ false, true }) do
                reset()
                H.mock_control({ qr_mode = "otp", qr_delay = 0, match = case.path,
                    delay = 1.5, times = 0 })
                local prior = H.mock_state().started_counts[case.path] or 0
                local function finished(event) return event.path == case.path end
                local finished_before = #H.mock_requests(finished)
                local running, last, gap = true, H.now_ms(), 0
                local function beat()
                    if not running then return end
                    local now = H.now_ms()
                    gap, last = math.max(gap, now - last), now
                    UIManager:scheduleIn(0.05, beat)
                end
                H.call(function() beat(); case.start() end)
                if case.prepare then case.prepare(); case.tap() end
                H.wait_until("worker reached " .. case.path, function()
                    return (H.mock_state().started_counts[case.path] or 0) > prior
                end, 5)
                if cancel then
                    H.wait_until("dismissable worker shown", function()
                        return getmetatable(H.input_window()) == TrapWidget
                    end, 5)
                    local t0 = H.now_ms()
                    H.tap_at(580, 20)
                    H.wait_until("worker dismissed", function()
                        return getmetatable(H.input_window()) ~= TrapWidget
                    end, 5)
                    local elapsed = H.now_ms() - t0
                    H.metric(case.name .. "_cancel_ms", elapsed)
                    H.check(elapsed < 800, case.name .. " cancellation stays responsive", tostring(elapsed))
                    H.wait_until(case.name .. " cancelled request completed at the mock", function()
                        return #H.mock_requests(finished) > finished_before
                    end, 10)
                    H.check(not case.done(), case.name .. " late cancelled response cannot restore UI/auth")
                    H.equal(account(), "", case.name .. " cancellation saves no account")
                else
                    H.wait_until(case.name .. " completed", case.done, 10)
                end
                H.sleep(0.1)
                running = false
                H.metric(case.name .. (cancel and "_cancel" or "") .. "_heartbeat_ms", gap)
                H.check(gap < 800, case.name .. " HTTP keeps UI heartbeat", tostring(gap))
                H.mock_control({ match = "", delay = 0, times = 0 })
            end
        end)
    end
    H.step("same-account generation invalidation rejects live completion", function()
        reset()
        H.mock_control({ match = "/api/userInfo", delay = 1.5, times = 0 })
        local prior = H.mock_state().started_counts["/api/userInfo"] or 0
        H.call(function() plugin.qr_login:_complete(good, plugin.qr_login.generation) end)
        H.wait_until("completion HTTP started", function()
            return (H.mock_state().started_counts["/api/userInfo"] or 0) > prior
        end, 5)
        -- Do not dismiss the worker: its response must reach the parent's
        -- generation check while the account ID remains unchanged.
        H.call(function() plugin.qr_login:cancel() end)
        H.wait_until("stale worker settled", function()
            return getmetatable(H.input_window()) ~= TrapWidget
        end, 10)
        H.equal(account(), "", "generation-invalid completion saves no account")
        H.equal(H.call(function() return plugin.settings:get("api_key", "") end), "",
            "generation-invalid completion saves no API key")
        H.check(not H.has_text("合成扫码用户"), "stale completion displays no success")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)
    H.step("account switch during QR scan invalidates the whole session", function()
        reset()
        H.mock_control({ qr_mode = "succeed", qr_delay = 0, match = "/api/auth/getLoginInfo",
            delay = 1.5, times = 0 })
        local prior = H.mock_state().started_counts["/api/auth/getLoginInfo"] or 0
        H.call(function() plugin.qr_login:start() end)
        H.wait_until("scan poll started", function()
            return (H.mock_state().started_counts["/api/auth/getLoginInfo"] or 0) > prior
        end, 5)
        H.call(function()
            plugin.settings:update_auth({ cookies = { wr_vid = "900002", wr_skey = "mock-other" },
                api_key = "mock-other-key", account = { user_vid = "900002", name = "mock-other" } },
                { replace_cookies = true })
        end)
        H.wait_until("old scan session discarded", function()
            return not plugin.qr_login.poll_job and not plugin.qr_login.qr_dialog
        end, 10)
        H.equal(account(), "900002", "account switch during scan rejects old QR credentials")
        H.check(not H.has_text("合成扫码用户"), "old scan cannot open successful completion")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)
    H.step("account switch rejects live completion, retry still succeeds", function()
        reset()
        H.mock_control({ match = "/api/userInfo", delay = 1.5, times = 0 })
        local prior = H.mock_state().started_counts["/api/userInfo"] or 0
        H.call(function() plugin.qr_login:_complete(good, plugin.qr_login.generation) end)
        H.wait_until("completion HTTP started", function()
            return (H.mock_state().started_counts["/api/userInfo"] or 0) > prior
        end, 5)
        H.call(function()
            plugin.settings:update_auth({ cookies = { wr_vid = "900002", wr_skey = "mock-other" },
                api_key = "mock-other-key", account = { user_vid = "900002", name = "mock-other" } },
                { replace_cookies = true })
        end)
        H.wait_until("old account worker settled", function()
            return getmetatable(H.input_window()) ~= TrapWidget
        end, 10)
        H.equal(account(), "900002", "account switch survives old response")
        H.check(plugin.qr_login.started_at == nil and plugin.qr_login.login_cookies == nil,
            "account mismatch clears the abandoned login session")
        H.equal(H.call(function() return plugin.settings:get("api_key", "") end), "mock-other-key",
            "old completion cannot overwrite the newer account key")
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.call(function() plugin.qr_login:_complete(good, plugin.qr_login.generation) end)
        H.wait_until("new QR completion succeeds", function()
            return plugin.settings:get("account", {}).user_vid == "900000"
        end, 10)
        H.equal(account(), "900000", "retry can switch accounts intentionally")
        H.close_dialogs()
    end)
end
