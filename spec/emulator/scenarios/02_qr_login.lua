-- @title QR login: scan, OTP and expired code against the mock
-- @timeout 120
-- Starts logged out (account cleared through the plugin's own confirmation
-- dialog), then drives the real QRLogin flow: QRMessage on screen, the
-- forked getLoginInfo long poll, userInfo + apikeyGet, credentials saved.
-- Also covers the NEED_OTP path (wrong code first, then "1234") and an
-- expired QR session that must not save any credentials, and a userInfo
-- request whose connection drops after the scan (retried, login completes).
return function(H)
    local UIManager = require("ui/uimanager")
    local QRMessage = require("ui/widget/qrmessage")
    local InputDialog = require("ui/widget/inputdialog")

    local plugin

    local function is_a(widget, class)
        local mt = getmetatable(widget)
        for _i = 1, 20 do
            if not mt then return false end
            if mt == class then return true end
            mt = getmetatable(mt)
        end
        return false
    end

    local function window_of(class)
        for _i, widget in ipairs(H.windows()) do
            if is_a(widget, class) then return widget end
        end
        return nil
    end

    -- Taps the painted widget whose text is exactly `text` (H.tap_text does a
    -- substring match and "验证" is also part of the title "需要验证码").
    local function tap_exact(text, root_pred, timeout)
        local target = H.wait_until("exact text '" .. text .. "' painted", function()
            local found
            local roots
            if root_pred then
                local root = root_pred()
                if not root then return nil end
                roots = root
            end
            H.walk(function(widget, chain, depth)
                if rawget(widget, "text") == text then
                    for i = depth, 1, -1 do
                        local d = rawget(chain[i], "dimen")
                        if type(d) == "table" and type(d.x) == "number" and (d.w or 0) > 0 and (d.h or 0) > 0 then
                            found = d
                            return true
                        end
                    end
                end
            end, roots)
            return found
        end, timeout or 15)
        local x, y = math.floor(target.x + target.w / 2), math.floor(target.y + target.h / 2)
        H.log("tap exact", text, "@", x, y)
        H.tap_at(x, y)
    end

    local function auth()
        return H.call(function()
            local settings = plugin.settings
            local account = settings:get("account", {})
            return {
                api_key = settings:get("api_key", ""),
                name = account.name,
                method = account.login_method,
                cookie = settings:is_cookie_configured(),
            }
        end)
    end

    local function clear_account(via_dialog)
        if via_dialog then
            H.call(function() plugin:confirmClearAccount() end)
            H.wait_text(H.tr("Clear WeRead cookie and API key? Cached books will remain."))
            H.shot("clear_account_confirm")
            tap_exact(H.tr("Clear"))
            H.wait_text(H.tr("WeRead account data cleared."))
        else
            H.call(function()
                plugin.qr_login:cancel()
                plugin.settings:reset_account()
                if plugin.onWeReadAccountChanged then plugin:onWeReadAccountChanged() end
            end)
        end
        H.close_dialogs()
        local state = auth()
        H.equal(state.api_key, "", "api key cleared")
        H.check(not state.cookie, "login cookie cleared")
        H.check(state.name == "" or state.name == nil, "account name cleared", tostring(state.name))
    end

    local function wait_qr_shown()
        local dialog = H.wait_until("QRMessage shown", function()
            local qr = plugin.qr_login.qr_dialog
            return qr and UIManager:isWidgetShown(qr) and is_a(qr, QRMessage) and qr or nil
        end, 15)
        H.check(tostring(dialog.text):find("/web/confirm?uid=mock-login-uid", 1, true),
            "QR payload carries the login uid", tostring(dialog.text))
        return dialog
    end

    local function login_requests(path)
        return #H.mock_requests(function(event) return event.path == path end)
    end

    H.step("plugin ready", function()
        plugin = H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        local state = auth()
        H.equal(state.api_key, "mock-api-key", "mock environment starts with synthetic key")
    end)

    H.step("log out through the clear-account dialog", function()
        clear_account(true)
    end)

    H.step("QR login succeeds", function()
        H.mock_control({ qr_mode = "succeed", qr_delay = 2 })
        local t0 = H.now_ms()
        H.call(function() plugin.qr_login:start() end)
        wait_qr_shown()
        H.metric("qr_shown_ms", H.now_ms() - t0)
        H.shot("qr_dialog")
        -- The poll starts 0.5 s after the dialog; qr_delay keeps it pending.
        local job = H.wait_until("background poll job", function() return plugin.qr_login.poll_job end, 5)
        H.check(type(job.pid) == "number" and job.pid > 0, "getLoginInfo polled in a forked process")
        local success = H.tr("WeRead login successful.\n\nAccount: %1\nCookie: %2\nOfficial API key: %3")
            :match("^([^\n]+)")
        H.wait_text(success, 30)
        H.metric("qr_login_ms", H.now_ms() - t0)
        H.check(H.has_text("合成扫码用户"), "success info names the account", H.screen_text())
        H.shot("qr_success")
        H.check(not plugin.qr_login.qr_dialog, "QR dialog closed")
        local state = auth()
        H.equal(state.api_key, "mock-qr-api-key", "api key from apikeyGet")
        H.equal(state.name, "合成扫码用户", "account name from userInfo")
        H.equal(state.method, "qr", "login method")
        H.check(state.cookie, "login cookie stored")
        local cookies = H.call(function() return plugin.settings:get("cookies", {}) end)
        H.equal(cookies.wr_vid, "900000", "wr_vid from webLoginVid")
        H.equal(cookies.wr_skey, "mock-access-token", "wr_skey from accessToken")
        H.check(login_requests("/api/auth/getLoginInfo") >= 1, "getLoginInfo requested")
        H.check(login_requests("/api/userInfo") >= 1, "userInfo requested")
        H.check(login_requests("/api/skills/apikeyGet") >= 1, "apikeyGet requested")
        H.close_dialogs()
    end)

    H.step("OTP: wrong code, then 1234", function()
        clear_account(false)
        H.mock_control({ qr_mode = "otp", qr_delay = 1 })
        H.call(function() plugin.qr_login:start() end)
        wait_qr_shown()
        local title = H.tr("Verification code required")
        local dialog = H.wait_until("OTP input dialog", function()
            local d = window_of(InputDialog)
            return d and H.has_text(title, d) and d or nil
        end, 30)
        H.check(not plugin.qr_login.qr_dialog, "QR dialog replaced by the OTP dialog")
        H.shot("otp_dialog")
        H.call(function() dialog:setInputText("0000") end)
        tap_exact(H.tr("Verify"), function() return window_of(InputDialog) end)
        local wrong = H.tr("Incorrect verification code.")
        local retry = H.wait_until("OTP dialog again with the error", function()
            local d = window_of(InputDialog)
            return d and d ~= dialog and H.has_text(wrong, d) and d or nil
        end, 20)
        H.shot("otp_wrong_code")
        H.equal(auth().api_key, "", "no credentials after a wrong code")
        H.call(function() retry:setInputText("1234") end)
        tap_exact(H.tr("Verify"), function() return window_of(InputDialog) end)
        H.wait_text("合成扫码用户", 30)
        H.shot("otp_success")
        local state = auth()
        H.equal(state.api_key, "mock-qr-api-key", "api key after OTP")
        H.equal(state.name, "合成扫码用户", "account name after OTP")
        H.check(not window_of(InputDialog), "OTP dialog closed")
        local otp_polls = H.mock_requests(function(event) return event.path == "/api/auth/getLoginInfo" end)
        H.check(#otp_polls >= 3, "poll + wrong OTP + right OTP requests", tostring(#otp_polls))
        H.close_dialogs()
    end)

    H.step("expired QR code saves nothing", function()
        clear_account(false)
        H.mock_control({ qr_mode = "expire", qr_delay = 1 })
        H.call(function() plugin.qr_login:start() end)
        wait_qr_shown()
        H.wait_text(H.tr("The QR code has expired. Please try again."), 30)
        H.shot("qr_expired")
        H.check(not plugin.qr_login.qr_dialog and not plugin.qr_login.poll_job, "login session ended")
        local state = auth()
        H.equal(state.api_key, "", "no api key saved")
        H.check(not state.cookie, "no login cookie saved")
        H.check(state.name == "" or state.name == nil, "no account saved", tostring(state.name))
        H.close_dialogs()
        H.mock_control({ qr_mode = "succeed", qr_delay = 1 })
    end)

    H.step("dropped userInfo connection is retried", function()
        clear_account(false)
        local function user_info_statuses()
            local out = {}
            for _i, event in ipairs(H.mock_requests(function(e) return e.path == "/api/userInfo" end)) do
                out[#out + 1] = event.status
            end
            return out
        end
        local before = #user_info_statuses()
        -- The next userInfo request gets no HTTP response at all.
        H.mock_control({ qr_mode = "succeed", qr_delay = 1, match = "/api/userInfo", times = 1, drop = true })
        H.call(function() plugin.qr_login:start() end)
        wait_qr_shown()
        H.wait_text("合成扫码用户", 30)
        H.shot("qr_success_after_drop")
        local statuses = user_info_statuses()
        H.equal(statuses[before + 1], 0, "first userInfo connection dropped")
        H.equal(statuses[before + 2], 200, "userInfo retried")
        local state = auth()
        H.equal(state.api_key, "mock-qr-api-key", "api key saved after the retry")
        H.equal(state.name, "合成扫码用户", "account name after the retry")
        H.close_dialogs()
        H.mock_control({ match = "", times = 0, drop = false })
    end)
end
