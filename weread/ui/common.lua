-- Shared dialog, network-task, and account UI helpers.
local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("weread.lib.logger")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local unpack_args = PluginUtil.unpack_args

local M = {}

function M:safeCallback(label, callback)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err("action failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

function M:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function M:showTransientInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

function M:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        text = text,
        dismissable = false,
    }
    UIManager:show(self.busy_message)
    self:refreshUI()
end

function M:closeBusy()
    if self.busy_message then
        UIManager:close(self.busy_message)
        self.busy_message = nil
        self:refreshUI()
    end
end

function M:refreshUI()
    if UIManager.forceRePaint then
        local ok, err = pcall(function()
            UIManager:forceRePaint()
        end)
        if not ok then
            logger.warn("forceRePaint failed:", log_error(err))
        end
    end
end

function M:showInputDialog(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        local ok, err = pcall(function()
            dialog:onShowKeyboard()
        end)
        if not ok then
            logger.warn("failed to show keyboard:", log_error(err))
        end
    end
end

function M:isNetworkOnline()
    -- The LAN server may be reachable without Internet/DNS connectivity.
    if self.settings and self.settings.mock_endpoint then return self:isNetworkConnected() end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isOnline then
        return true
    end
    local ok_online, online = pcall(function()
        return NetworkMgr:isOnline()
    end)
    if not ok_online then
        logger.warn("network status check failed:", log_error(online))
        return true
    end
    return online == true
end

-- Non-blocking connectivity check (interface link state only). Unlike
-- isNetworkOnline() it never resolves DNS, so it is safe on the UI loop.
function M:isNetworkConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isConnected then
        return self.settings and self.settings.mock_endpoint and true or self:isNetworkOnline()
    end
    local ok_connected, connected = pcall(function()
        return NetworkMgr:isConnected()
    end)
    if not ok_connected then
        logger.warn("network link check failed:", log_error(connected))
        return true
    end
    return connected == true
end

function M:showOffline(label)
    self:closeBusy()
    logger.warn("network unavailable:", label)
    self:showInfo(T(_("%1 failed:\n%2"), label, _("No network connection. Please connect Wi-Fi and try again.")))
end

-- options.silent_offline: no offline notice (background work).
-- options.link_only: check the interface link only, never a blocking DNS
-- lookup; for lifecycle-triggered work, where the request itself fails fast.
function M:runOnlineTask(label, callback, delay, options)
    local online
    if options and options.link_only then
        online = self:isNetworkConnected()
    else
        online = self:isNetworkOnline()
    end
    if not online then
        if not (options and options.silent_offline) then
            self:showOffline(label)
        end
        return false
    end
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err("network task failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end)
    return true
end

-- Short user-triggered requests (book search, chapter catalog) run in a
-- dismissable subprocess, like chapter downloads: blocking HTTP on the UI
-- thread freezes taps and repaints for the whole request. on_success runs in
-- the parent with the task's result; failures are reported with error_label.
-- Refuse to run network tasks when the runtime cannot provide a worker.
function M:_runNetworkRequest(busy_text, error_label, task, on_success, on_failure)
    local function report(err)
        if on_failure then return on_failure(err, false) end
        logger.warn("annotation request failed:", tostring(error_label), tostring(err))
        self:showInfo(T(_("%1 failed:\n%2"), error_label, display_error(err)))
    end
    local function deliver(value)
        local ok, err = xpcall(on_success, debug.traceback, value)
        if not ok then report(err) end
    end
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    if not (ok_ffi and type(ffiutil) == "table" and type(ffiutil.runInSubProcess) == "function"
        and ok_trapper and type(Trapper) == "table" and type(Trapper.wrap) == "function"
        and type(Trapper.dismissableRunInSubprocess) == "function") then
        return report(_("Network subprocess is unavailable."))
    end
    local ok_json, Json = pcall(require, "json")
    if not ok_json then Json = require("rapidjson") end
    local WorkerSettings = require("weread.lib.worker_settings")
    Trapper:wrap(function()
        local fingerprint = WorkerSettings.fingerprint(self.settings)
        local completed, encoded = Trapper:dismissableRunInSubprocess(function()
            local auth_result = WorkerSettings.capture(self.settings)
            local ok, value = xpcall(task, debug.traceback)
            return Json.encode({ ok = ok, value = value, auth = auth_result() })
        end, busy_text, true)
        if not completed then
            -- Dismissed by the user (the child was killed), or fork failed.
            if encoded ~= nil then report(encoded)
            elseif on_failure then on_failure(nil, true) end
            return
        end
        local decoded, result = pcall(Json.decode, encoded or "")
        if not decoded or type(result) ~= "table" then
            return report("no result from the request subprocess")
        end
        if result.auth then
            local merged, merge_err = pcall(WorkerSettings.merge, self.settings, fingerprint, result.auth)
            if not merged then return report(merge_err) end
        end
        if not result.ok then return report(result.value) end
        deliver(result.value)
    end)
end

function M:runNetworkAction(label, action)
    self:runOnlineTask(label, function()
        local ok, result = pcall(action)
        if ok then
            self:showInfo(result or label)
        else
            logger.err("network action failed:", label, log_error(result))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(result)))
        end
    end)
end

function M:showList(title, items, empty_text, options)
    if not items or #items == 0 then
        self:showInfo(empty_text or _("No items."))
        return
    end
    options = options or {}
    local menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
        items_per_page = options.items_per_page,
        subtitle = options.subtitle,
    }
    UIManager:show(menu)
    if options.initial_page and options.initial_page > 1
        and type(menu.onGotoPage) == "function" then
        UIManager:scheduleIn(0.1, function()
            if menu and type(menu.onGotoPage) == "function" then
                menu:onGotoPage(options.initial_page)
            end
        end)
    end
    return menu
end

function M:requireLogin(require_cookie, require_api_key)
    local missing_cookie = require_cookie and not self.settings:is_cookie_configured()
    local missing_api_key = require_api_key and not self.settings:is_api_configured()
    if not missing_cookie and not missing_api_key then
        return true
    end
    self:showTransientInfo(_("Please scan the QR code to log in first."), 2)
    UIManager:scheduleIn(0.2, function()
        self.qr_login:start()
    end)
    return false
end

function M:refreshLoginMenu()
    local menu = self._login_menu_instance
    if menu and type(menu.updateItems) == "function" then
        local ok, err = pcall(function()
            menu:updateItems()
        end)
        if not ok then
            logger.warn("refresh login menu failed:", log_error(err))
        end
    end
    self:refreshUI()
end

function M:renewCookieWithUI()
    if not self:requireLogin(true, false) then
        return
    end
    self:runNetworkAction(_("Renew cookie"), function()
        self.client:renew_cookie()
        logger.info("cookie renewed")
        return _("WeRead cookie renewed.")
    end)
end

function M:showAccountStatus()
    local account = self.settings:get("account", {})
    local account_name = type(account.name) == "string" and account.name or ""
    if account_name == "" then
        account_name = (self.settings:is_cookie_configured() or self.settings:is_api_configured())
            and _("Unknown account") or _("Not logged in")
    end
    local login_method = account.login_method == "qr" and _("QR login") or _("Unknown")
    local cookie_status = self.settings:is_cookie_configured() and _("configured") or _("missing")
    local api_status = self.settings:is_api_configured() and _("configured") or _("missing")
    self:showInfo(T(
        _("Account: %1\nLogin method: %2\nCookie: %3\nOfficial API key: %4\nCache directory:\n%5"),
        account_name,
        login_method,
        cookie_status,
        api_status,
        BD.dirpath(self.settings.cache_dir)
    ))
end

function M:confirmClearAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Clear WeRead cookie and API key? Cached books will remain."),
        ok_text = _("Clear"),
        ok_callback = self:safeCallback(_("Clear"), function()
            self.qr_login:cancel()
            self.read_report:stop("account_cleared")
            self.settings:reset_account()
            if self.onWeReadAccountChanged then
                self:onWeReadAccountChanged()
            end
            self:refreshLoginMenu()
            self:showInfo(_("WeRead account data cleared."))
        end),
    })
end

return M
