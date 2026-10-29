-- Shared UI helpers in weread/ui/common.lua: error-trapping callbacks, busy
-- messages, network checks and online tasks, lists, login gating and the
-- account status/clear dialogs.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local shown, closed, scheduled = {}, {}, {}
local repaints, repaint_error = 0, nil
local UIManager = {
    show = function(_self, widget) shown[#shown + 1] = widget end,
    close = function(_self, widget) closed[#closed + 1] = widget end,
    scheduleIn = function(_self, delay, callback) scheduled[#scheduled + 1] = { delay = delay, callback = callback } end,
    forceRePaint = function()
        repaints = repaints + 1
        if repaint_error then error(repaint_error) end
    end,
}
package.preload["ui/uimanager"] = function() return UIManager end
local function run_scheduled()
    while #scheduled > 0 do table.remove(scheduled, 1).callback() end
end
package.preload["ui/bidi"] = function()
    return { dirpath = function(path) return "<" .. tostring(path) .. ">" end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_self, options) options.kind = "info" return options end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) options.kind = "confirm" return options end }
end
local menus = {}
package.preload["ui/widget/menu"] = function()
    return { new = function(_self, options)
        options.kind = "menu"
        options.onGotoPage = function(self, page) self.went_to = page end
        menus[#menus + 1] = options
        return options
    end }
end
local logged = { warn = {}, err = {} }
package.preload["weread.lib.logger"] = function()
    local function sink(level)
        return function(...)
            local parts = {}
            for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
            logged[level][#logged[level] + 1] = table.concat(parts, " ")
        end
    end
    return { info = function() end, warn = sink("warn"), err = sink("err") }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d)", function(index) return tostring(values[tonumber(index)]) end))
        end,
        log_error = tostring,
        display_error = tostring,
        unpack_args = unpack,
    }
end

-- KOReader's NetworkMgr, replaceable per scenario.
local function set_network(manager)
    package.loaded["ui/network/manager"] = nil
    package.preload["ui/network/manager"] = function()
        if manager == nil then error("module not available") end
        return manager
    end
end

local Common = require("weread.ui.common")

local function new_host(fields)
    local host = fields or {}
    host._runNetworkRequest = host._runNetworkRequest or require("spec.helpers.immediate_network_request")
    for key, value in pairs(Common) do
        if host[key] == nil then host[key] = value end
    end
    return host
end
local function last_shown() return shown[#shown] end

-- 1. Info messages.
local host = new_host()
host:showInfo("hello")
expect(last_shown().kind == "info" and last_shown().text == "hello" and last_shown().timeout == nil,
    "info message wrong")
host:showTransientInfo("brief")
expect(last_shown().timeout == 2, "transient info has no default timeout")
host:showTransientInfo("briefer", 1)
expect(last_shown().timeout == 1, "transient timeout ignored")

-- 2. Busy message: one at a time, never dismissable, repainted at once.
host:showBusy("Working...")
local first_busy = host.busy_message
expect(first_busy.text == "Working..." and first_busy.dismissable == false and last_shown() == first_busy,
    "busy message not shown")
expect(repaints == 1, "busy message was not painted at once")
host:showBusy("Still working...")
expect(closed[#closed] == first_busy and host.busy_message ~= first_busy and #closed == 1,
    "previous busy message was not replaced")
host:closeBusy()
expect(host.busy_message == nil and #closed == 2, "busy message not closed")
host:closeBusy()
expect(#closed == 2, "closing without a busy message closed something")
-- Repaint failures are logged, never raised; a UIManager without
-- forceRePaint is fine too.
repaint_error = "screen gone"
host:refreshUI()
expect(logged.warn[#logged.warn]:find("screen gone", 1, true), "repaint failure not logged")
repaint_error = nil
local force = UIManager.forceRePaint
UIManager.forceRePaint = nil
local repaints_before = repaints
host:refreshUI()
expect(repaints == repaints_before, "missing forceRePaint was called")
UIManager.forceRePaint = force

-- 3. safeCallback forwards arguments and turns errors into a message.
local got
local wrapped = host:safeCallback("Open book", function(a, b, c) got = { a, b, c } return "ignored" end)
expect(wrapped(1, "two", true) == nil and got[1] == 1 and got[2] == "two" and got[3] == true,
    "callback arguments not forwarded")
host:showBusy("Loading...")
local busy = host.busy_message
host:safeCallback("Open book", function() error("disk unplugged") end)()
expect(host.busy_message == nil and closed[#closed] == busy, "failed action left the busy message")
expect(last_shown().text:find("Open book failed:\n", 1, true) == 1
        and last_shown().text:find("disk unplugged", 1, true),
    "failed action not reported: " .. tostring(last_shown().text))
expect(logged.err[#logged.err]:find("action failed: Open book", 1, true)
        and logged.err[#logged.err]:find("stack traceback", 1, true),
    "failed action not logged with a traceback")

-- 4. Keyboard for input dialogs.
local keyboard = 0
local dialog = { onShowKeyboard = function() keyboard = keyboard + 1 end }
host:showInputDialog(dialog)
expect(last_shown() == dialog and keyboard == 1, "input dialog keyboard not shown")
host:showInputDialog({ onShowKeyboard = function() error("no keyboard") end })
expect(logged.warn[#logged.warn]:find("no keyboard", 1, true), "keyboard failure not logged")
local plain = {}
host:showInputDialog(plain)
expect(last_shown() == plain, "dialog without keyboard not shown")

-- 5. Network checks fall back to "online" when KOReader cannot tell.
set_network(nil)
expect(host:isNetworkOnline() == true, "missing NetworkMgr reported offline")
expect(host:isNetworkConnected() == true, "missing NetworkMgr link reported down")
set_network({ isOnline = function() error("dns broke") end })
expect(host:isNetworkOnline() == true and logged.warn[#logged.warn]:find("dns broke", 1, true),
    "failing online check not tolerated")
set_network({ isOnline = function() return "yes" end })
expect(host:isNetworkOnline() == false, "non-boolean online status counted as online")
-- Without isConnected the task checks reachability; the UI never probes DNS.
expect(host:isNetworkConnected() == true, "missing link API must defer reachability to the task")
set_network({ isConnected = function() error("ioctl failed") end })
expect(host:isNetworkConnected() == true and logged.warn[#logged.warn]:find("ioctl failed", 1, true),
    "failing link check not tolerated")
set_network({ isConnected = function() return 1 end })
expect(host:isNetworkConnected() == false, "non-boolean link status counted as up")
-- A mock (LAN) endpoint only needs the link, never DNS.
local dns = 0
set_network({ isOnline = function() dns = dns + 1 return false end, isConnected = function() return true end })
local mock_host = new_host({ settings = { mock_endpoint = "http://192.168.1.2" } })
expect(mock_host:isNetworkOnline() == true and dns == 0, "mock endpoint required Internet access")
set_network({ isOnline = function() dns = dns + 1 return false end })
expect(mock_host:isNetworkConnected() == true and dns == 0, "mock endpoint without link API was offline")

-- 6. Online tasks.
set_network({ isOnline = function() return true end, isConnected = function() return true end })
local ran = 0
expect(host:runOnlineTask("Sync", function() ran = ran + 1 end) == true and ran == 0,
    "online task ran synchronously")
expect(scheduled[1].delay == 0.1, "default delay not used")
run_scheduled()
expect(ran == 1, "online task did not run")
host:runOnlineTask("Sync", function() end, 2)
expect(scheduled[1].delay == 2, "explicit delay ignored")
run_scheduled()
host:showBusy("Syncing...")
host:runOnlineTask("Sync", function() error("HTTP 500") end)
run_scheduled()
expect(host.busy_message == nil and last_shown().text:find("Sync failed:\n", 1, true) == 1
        and last_shown().text:find("HTTP 500", 1, true),
    "failed online task not reported")
expect(logged.err[#logged.err]:find("network task failed: Sync", 1, true), "failed online task not logged")
-- Offline: the busy message is closed and the user told to connect.
set_network({ isConnected = function() return false end })
host:showBusy("Syncing...")
expect(host:runOnlineTask("Sync", function() ran = ran + 1 end) == false and #scheduled == 0,
    "offline task was scheduled")
expect(host.busy_message == nil and last_shown().text:find("No network connection", 1, true),
    "offline notice missing")
expect(logged.warn[#logged.warn]:find("network unavailable: Sync", 1, true), "offline not logged")
-- link_only checks the link and never the (possibly blocking) online probe.
local probes = { online = 0, link = 0 }
local link_up = true
set_network({
    isOnline = function() probes.online = probes.online + 1 return false end,
    isConnected = function() probes.link = probes.link + 1 return link_up end,
})
ran = 0
expect(host:runOnlineTask("Sync", function() ran = ran + 1 end, nil, { link_only = true }) == true
        and #scheduled == 1 and probes.online == 0 and probes.link == 1,
    "link-only task used the online check or was not scheduled")
run_scheduled()
expect(ran == 1, "link-only task did not run")
-- A link-only task without a link is reported offline; silent_offline
-- skips the notice.
link_up = false
local offline_shown_before = #shown
expect(host:runOnlineTask("Sync", function() ran = ran + 1 end, nil, { link_only = true }) == false
        and #scheduled == 0 and probes.online == 0 and #shown == offline_shown_before + 1
        and last_shown().text:find("No network connection", 1, true),
    "link-only task without a link was scheduled or not reported")
local shown_before = #shown
expect(host:runOnlineTask("Sync", function() ran = ran + 1 end, nil, { link_only = true, silent_offline = true })
        == false and #scheduled == 0 and #shown == shown_before and ran == 1,
    "silent offline task was scheduled or showed a notice")

-- 7. Network actions report their result or error without UI DNS checks.
set_network({ isConnected = function() return true end, isOnline = function() error("UI DNS used") end })
host:runNetworkAction("Refresh", function() return "Refreshed 3 books." end)
run_scheduled()
expect(last_shown().text == "Refreshed 3 books.", "action result not shown")
host:runNetworkAction("Refresh", function() end)
run_scheduled()
expect(last_shown().text == "Refresh", "action without result did not show its label")
host:runNetworkAction("Refresh", function() error("timeout") end)
run_scheduled()
expect(last_shown().text:find("Refresh failed:\n", 1, true) == 1 and last_shown().text:find("timeout", 1, true),
    "failed action not shown")
expect(logged.err[#logged.err]:find("network action failed: Refresh", 1, true), "failed action not logged")

local parent_value
host:runNetworkAction("Apply", function() return { count = 3 } end, function(result)
    parent_value = result.count
    return "Parent saved 3"
end)
run_scheduled()
expect(parent_value == 3 and last_shown().text == "Parent saved 3", "parent result application did not produce notice")
host:runNetworkAction("Saved", function() return { count = 4 } end, function(result)
    parent_value = result.count
end)
run_scheduled()
expect(parent_value == 4 and last_shown().text == "Saved", "parent-only result leaked a data table into the notice")
local before_cancel = #shown
local cancelled_task_ran = false
host.cancel_network_request = true
host:runNetworkAction("Cancel", function() cancelled_task_ran = true end)
run_scheduled()
host.cancel_network_request = nil
expect(not cancelled_task_ran and #shown == before_cancel, "cancelled action ran or reopened UI")

-- 8. Lists.
expect(host:showList("Books", {}) == nil and last_shown().text == "No items.", "empty list not explained")
expect(host:showList("Books", nil, "Nothing cached") == nil and last_shown().text == "Nothing cached",
    "custom empty text ignored")
local items = { { text = "a" }, { text = "b" } }
local menu = host:showList("Books", items, nil, { items_per_page = 7, subtitle = "sub", initial_page = 3 })
expect(menu == last_shown() and menu.title == "Books" and menu.item_table == items and menu.items_per_page == 7
        and menu.subtitle == "sub" and menu.is_borderless,
    "list menu options wrong")
expect(#scheduled == 1 and menu.went_to == nil, "initial page jumped before the menu painted")
run_scheduled()
expect(menu.went_to == 3, "initial page not opened")
menu = host:showList("Books", items, nil, { initial_page = 1 })
expect(menu.kind == "menu" and #scheduled == 0, "first page scheduled a jump")
menu = host:showList("Books", items)
expect(menu.kind == "menu" and #scheduled == 0, "list without options failed")

-- 9. Login gating.
local configured = { cookie = true, api = true }
local qr_starts, qr_cancels = 0, 0
local reports_stopped, account_resets, account_changes = {}, 0, 0
local account = {}
local settings = {
    cache_dir = "/mnt/us/weread",
    is_cookie_configured = function() return configured.cookie end,
    is_api_configured = function() return configured.api end,
    get = function(_self, key, default)
        if key == "account" then return account end
        return default
    end,
    reset_account = function()
        account_resets = account_resets + 1
        configured.cookie, configured.api = false, false
    end,
}
local renewals, renew_error = 0, nil
local login_menu_updates = 0
local app = new_host({
    settings = settings,
    qr_login = {
        start = function() qr_starts = qr_starts + 1 end,
        cancel = function() qr_cancels = qr_cancels + 1 end,
    },
    read_report = { stop = function(_self, reason) reports_stopped[#reports_stopped + 1] = reason end },
    client = { renew_cookie = function()
        renewals = renewals + 1
        if renew_error then error(renew_error) end
    end },
    onWeReadAccountChanged = function() account_changes = account_changes + 1 end,
    _login_menu_instance = { updateItems = function() login_menu_updates = login_menu_updates + 1 end },
})
expect(app:requireLogin(true, true) == true and #scheduled == 0, "configured account was asked to log in")
configured.cookie = false
expect(app:requireLogin(false, true) == true, "cookie demanded when only the API key is needed")
expect(app:requireLogin(true, false) == false, "missing cookie was accepted")
expect(last_shown().text:find("scan the QR code", 1, true) and last_shown().timeout == 2, "login prompt missing")
expect(qr_starts == 0, "QR login started before the prompt painted")
run_scheduled()
expect(qr_starts == 1, "QR login was not started")
configured.cookie, configured.api = true, false
expect(app:requireLogin(false, true) == false, "missing API key was accepted")
run_scheduled()

-- 10. Renewing the cookie.
configured.cookie = false
app:renewCookieWithUI()
run_scheduled()
expect(renewals == 0, "cookie renewal ran without a login")
configured.cookie = true
app:renewCookieWithUI()
run_scheduled()
expect(renewals == 1 and last_shown().text == "WeRead cookie renewed.", "cookie renewal not reported")
renew_error = "HTTP 401"
app:renewCookieWithUI()
run_scheduled()
expect(last_shown().text:find("Renew cookie failed:\n", 1, true) == 1 and last_shown().text:find("HTTP 401", 1, true),
    "failed cookie renewal not reported")

-- 11. Account status.
account = { name = "Reader", login_method = "qr" }
configured.cookie, configured.api = true, false
app:showAccountStatus()
expect(last_shown().text == "Account: Reader\nLogin method: QR login\nCookie: configured\n"
        .. "Official API key: missing\nCache directory:\n</mnt/us/weread>",
    "account status wrong: " .. last_shown().text)
account = { name = 42 }
app:showAccountStatus()
expect(last_shown().text:find("Account: Unknown account\nLogin method: Unknown", 1, true),
    "logged-in account without a name not reported as unknown")
configured.cookie, configured.api = false, true
app:showAccountStatus()
expect(last_shown().text:find("Account: Unknown account", 1, true)
        and last_shown().text:find("Cookie: missing\nOfficial API key: configured", 1, true),
    "API-key-only account status wrong")
configured.api = false
app:showAccountStatus()
expect(last_shown().text:find("Account: Not logged in", 1, true), "logged-out account not reported")

-- 12. Login menu refresh tolerates a broken menu.
app:refreshLoginMenu()
expect(login_menu_updates == 1, "login menu not refreshed")
app._login_menu_instance = { updateItems = function() error("menu closed") end }
app:refreshLoginMenu()
expect(logged.warn[#logged.warn]:find("menu closed", 1, true), "login menu failure not logged")
app._login_menu_instance = nil
repaints_before = repaints
app:refreshLoginMenu()
expect(repaints == repaints_before + 1, "screen not refreshed without a login menu")

-- 13. Clearing the account asks first; confirming stops login and
-- reporting, resets the account and tells the rest of the plugin.
app._login_menu_instance = { updateItems = function() login_menu_updates = login_menu_updates + 1 end }
configured.cookie, configured.api = true, true
app:confirmClearAccount()
local confirm = last_shown()
expect(confirm.kind == "confirm" and confirm.text:find("Cached books will remain", 1, true) and confirm.ok_text == "Clear",
    "clear-account confirm missing")
expect(account_resets == 0 and qr_cancels == 0 and #reports_stopped == 0, "account cleared before confirmation")
confirm.ok_callback()
expect(qr_cancels == 1 and reports_stopped[1] == "account_cleared" and account_resets == 1 and account_changes == 1,
    "account clearing skipped a step")
expect(login_menu_updates == 2 and last_shown().text == "WeRead account data cleared.", "account clearing not reported")
expect(not configured.cookie and not configured.api, "credentials were kept")
-- Without an account-change hook it still completes; a failing reset is
-- reported instead of raised.
app.onWeReadAccountChanged = nil
settings.reset_account = function() error("settings read-only") end
app:confirmClearAccount()
last_shown().ok_callback()
expect(last_shown().text:find("Clear failed:\n", 1, true) == 1 and last_shown().text:find("settings read-only", 1, true),
    "failed account clearing not reported")

print(("common_ui_helpers_spec: %d checks"):format(checks))
