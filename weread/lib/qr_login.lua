local Cookie = require("weread.lib.cookie")
local Device = require("device")
local I18n = require("weread.lib.i18n")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("weread.lib.logger").scoped("QRLogin")
local QRMessage = require("ui/widget/qrmessage")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")

local function _(text)
    return I18n.tr(text)
end

local BASE_URL = "https://weread.qq.com"
local SKILLS_PAGE_URL = BASE_URL .. "/r/weread-skills"
local LOGIN_UID_URL = BASE_URL .. "/api/auth/getLoginUid"
local LOGIN_INFO_URL = BASE_URL .. "/api/auth/getLoginInfo"
local USER_INFO_URL = BASE_URL .. "/api/userInfo"
local API_KEY_URL = BASE_URL .. "/api/skills/apikeyGet?only_show=1"
local LOGIN_SESSION_TIMEOUT_SECONDS = 300
local POLL_BLOCK_TIMEOUT_SECONDS = 5
local POLL_TOTAL_TIMEOUT_SECONDS = 8
-- getLoginInfo is a long poll. It runs in a background process; the UI
-- loop only checks that process this often (F11).
local POLL_JOB_CHECK_SECONDS = 0.5
local POLL_JOB_INTERVAL_SECONDS = 0.5
-- A failed dedicated poll worker retries through the dismissable worker
-- helper. Keep each fallback request short before scheduling another poll.
local INLINE_POLL_TIMEOUT = { 2, 3 }
local INLINE_POLL_INTERVAL_SECONDS = 1.5

local QRLogin = {}
QRLogin.__index = QRLogin

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then
            return value
        end
    end
    return nil
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepcopy(item)
    end
    return copy
end

local function merge_response_cookies(cookies, headers)
    local set_cookie = header_value(headers, "set-cookie")
    if set_cookie then
        return Cookie.merge_set_cookie(cookies or {}, set_cookie)
    end
    return cookies or {}
end

local function error_text(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function is_timeout_error(err)
    local text = tostring(err or ""):lower()
    return text:find("timeout", 1, true) ~= nil
        or text:find("wantread", 1, true) ~= nil
end

-- Fork helpers (ffi/util), or nil where the platform cannot fork.
local function make_subprocess_runner()
    if type(FFIUtil.runInSubProcess) ~= "function"
        or type(FFIUtil.isSubProcessDone) ~= "function"
        or type(FFIUtil.readAllFromFD) ~= "function" then
        return nil
    end
    return {
        run = function(child) return FFIUtil.runInSubProcess(child, true) end,
        write_all = function(fd, data) return FFIUtil.writeToFD(fd, data, true) end,
        is_done = function(pid) return FFIUtil.isSubProcessDone(pid) end,
        read_size = function(fd) return FFIUtil.getNonBlockingReadSize(fd) end,
        read_all = function(fd) return FFIUtil.readAllFromFD(fd) end,
        terminate = function(pid) FFIUtil.terminateSubProcess(pid) end,
    }
end

local function sleep_seconds(seconds)
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket.sleep then
        socket.sleep(seconds)
    end
end

function QRLogin:new(host, client, settings, options)
    options = options or {}
    local subprocess = options.subprocess
    if subprocess == nil then subprocess = make_subprocess_runner() end
    return setmetatable({
        host = host,
        client = client,
        settings = settings,
        generation = 0,
        login_cookies = nil,
        qr_dialog = nil,
        programmatic_close = false,
        started_at = nil,
        subprocess = subprocess or nil,
        scheduler = options.scheduler or UIManager,
        now = options.now or os.time,
    }, self)
end

function QRLogin:_request_json(url, opts, stage)
    opts = opts or {}
    stage = stage or "request"
    opts.url = url
    opts.skip_cookie = true
    local text, code, headers, status = self.client:request(opts)
    if not code then
        return nil, headers, status or "request failed"
    end
    if code < 200 or code >= 300 then
        local request_headers = opts.headers or {}
        local cookie_header = header_value(request_headers, "cookie")
        local vid_header = header_value(request_headers, "x-vid")
        local skey_header = header_value(request_headers, "x-skey")
        logger.warn(
            stage, "rejected:", "HTTP", tostring(code),
            "cookie_bytes=", tostring(#tostring(cookie_header or "")),
            "x_vid_bytes=", tostring(#tostring(vid_header or "")),
            "x_skey_bytes=", tostring(#tostring(skey_header or ""))
        )
        error(stage .. " failed: HTTP " .. tostring(code))
    end
    local data = self.client:decode_http_json(text, {
        method = opts.method or "GET",
        url = url,
        code = code,
        headers = headers,
    })
    if type(data) ~= "table" then
        error("WeRead returned an invalid JSON response")
    end
    return data, headers
end

function QRLogin:_begin_protocol()
    local login_cookies = { wr_fp = self.settings:get_device_fingerprint() }
    local _, page_code, page_headers = self.client:request_follow({
        url = SKILLS_PAGE_URL,
        method = "GET",
        skip_cookie = true,
        maxredirects = 5,
        timeout = { 10, 20 },
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = BASE_URL .. "/",
            ["Cookie"] = Cookie.to_header(login_cookies),
        },
    })
    login_cookies = merge_response_cookies(login_cookies, page_headers)
    if not page_code or page_code < 200 or page_code >= 300 then
        error("Unable to open WeRead login page (HTTP " .. tostring(page_code) .. ")")
    end

    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(login_cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end

    local data, response_headers = self:_request_json(LOGIN_UID_URL, {
        method = "GET",
        timeout = { 10, 20 },
        headers = headers,
    }, "getLoginUid")
    login_cookies = merge_response_cookies(login_cookies, response_headers)
    if type(data.uid) ~= "string" or data.uid == "" then
        error("WeRead did not return a valid login UID")
    end

    self.login_cookies = login_cookies
    return data.uid
end

function QRLogin:_poll_protocol(uid, otp, timeout)
    if type(uid) ~= "string" or uid == "" then
        error("Missing QR login UID")
    end

    local url = LOGIN_INFO_URL .. "?uid=" .. WeRead.urlencode(uid) .. "&otp="
    if type(otp) == "string" and otp ~= "" then
        url = url .. WeRead.urlencode(otp)
    end

    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(self.login_cookies or {})
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end

    local data, response_headers, request_error = self:_request_json(url, {
        method = "GET",
        timeout = timeout or { POLL_BLOCK_TIMEOUT_SECONDS, POLL_TOTAL_TIMEOUT_SECONDS },
        headers = headers,
    }, "getLoginInfo")
    if not data then
        -- No HTTP status means the socket failed. Keep polling until the QR session expires.
        logger.dbg("getLoginInfo transport pending:", tostring(request_error))
        return { transport_pending = true }
    end
    self.login_cookies = merge_response_cookies(self.login_cookies, response_headers)
    return data
end

function QRLogin:_authenticated_get(url, cookies, web_login_vid, access_token, stage)
    for attempt = 1, 3 do
        local transport_failed = false
        local ok, data, response_headers = pcall(function()
            local result, headers, request_error = self:_request_json(url, {
                method = "GET",
                timeout = { 10, 20 },
                headers = {
                    ["Accept"] = "application/json, text/plain, */*",
                    ["Referer"] = SKILLS_PAGE_URL,
                    ["Cookie"] = Cookie.to_header(cookies),
                    ["X-Vid"] = web_login_vid,
                    ["X-Skey"] = access_token,
                },
            }, stage)
            if result == nil then
                -- No HTTP status: the connection failed (e.g. closed).
                transport_failed = true
                error(stage .. " failed: " .. tostring(request_error or "request failed"), 0)
            end
            return result, headers
        end)
        if ok then
            return data, merge_response_cookies(cookies, response_headers)
        end
        local retryable = transport_failed or tostring(data):find("HTTP 401", 1, true) ~= nil
        if not retryable or attempt == 3 then
            error(data)
        end
        logger.warn(stage, "request failed temporarily; retrying:", tostring(attempt))
        sleep_seconds(0.5)
    end
end

function QRLogin:_fetch_credentials(login_result)
    if type(login_result) ~= "table" or login_result.succeed ~= true then
        error("QR login has not succeeded")
    end

    local web_login_vid = tostring(login_result.webLoginVid or "")
    local access_token = tostring(login_result.accessToken or "")
    local refresh_token = tostring(login_result.refreshToken or "")
    if web_login_vid == "" or access_token == "" then
        error("QR login response is missing account credentials")
    end

    -- A QR login represents a complete account switch. Build a fresh jar from
    -- this login session so credentials from a previously signed-in account
    -- cannot leak into the new session.
    local cookies = deepcopy(self.login_cookies or {})
    cookies.wr_vid = web_login_vid
    cookies.wr_skey = access_token
    cookies.wr_ql = "0"
    if refresh_token ~= "" then
        cookies.wr_rt = WeRead.urlencode(refresh_token)
    end

    local user_url = USER_INFO_URL .. "?userVid=" .. WeRead.urlencode(web_login_vid)
    local user_info
    user_info, cookies = self:_authenticated_get(
        user_url,
        cookies,
        web_login_vid,
        access_token,
        "userInfo"
    )

    local api_result
    local api_key = ""
    for attempt = 1, 3 do
        api_result, cookies = self:_authenticated_get(
            API_KEY_URL,
            cookies,
            web_login_vid,
            access_token,
            "apikeyGet"
        )
        api_key = type(api_result.apikey) == "string" and api_result.apikey or ""
        if api_key ~= "" then
            break
        end
        if attempt < 3 then
            sleep_seconds(0.5)
        end
    end
    if api_key == "" then
        error(_("No official API key was returned. This account has not enabled WeRead Skill.\n\nOpen WeRead app → Me → Settings → WeRead Skill → Get API Key, then scan again."))
    end
    return {
        cookies = cookies,
        api_key = api_key,
        wr_ticket = "",
        wr_wrpa = "",
        account = {
            name = type(user_info.name) == "string" and user_info.name or "",
            user_vid = web_login_vid,
            login_method = "qr",
            login_time = os.time(),
        },
    }
end

function QRLogin:_apply_credentials(credentials, generation)
    if generation ~= self.generation then
        error("QR login was cancelled")
    end
    self.settings:update_auth(credentials, { replace_cookies = true })
    if self.host.onWeReadAccountChanged then
        self.host:onWeReadAccountChanged()
    end
    self.login_cookies = nil
    self.session_account = nil
    self.started_at = nil
    return credentials.account
end

function QRLogin:_complete_protocol(login_result, generation)
    return self:_apply_credentials(self:_fetch_credentials(login_result), generation)
end

-- Only protocol requests and parsing run in the worker. Session cookies and
-- account credentials are returned as data and applied after both parent-side
-- lifetime checks, before any account notification or UI update.
function QRLogin:_account_id()
    local account = self.settings.get and self.settings:get("account", {}) or {}
    return tostring(account.user_vid or "")
end

function QRLogin:_run_protocol_request(busy_text, generation, task, on_success, on_failure)
    local original_account = self:_account_id()
    local function valid()
        local current = self:_account_id()
        return generation == self.generation and current == original_account
            and (self.session_account == nil or self.session_account == current)
    end
    self.host:runOnlineTask(_("QR login"), function()
        if not valid() then return end
        local worker = setmetatable({
            client = self.client,
            login_cookies = deepcopy(self.login_cookies),
        }, QRLogin)
        self.host:_runNetworkRequest(busy_text, _("QR login"), function()
            local value = task(worker)
            return { value = value, cookies = worker.login_cookies }
        end, function(result)
            if not valid() then return end
            self.login_cookies = result.cookies
            on_success(result.value)
        end, function(err, cancelled)
            if not valid() then return end
            if cancelled then self:cancel(); return end
            on_failure(err)
        end)
    end)
end

function QRLogin:_close_qr_dialog(programmatic)
    local dialog = self.qr_dialog
    if not dialog then
        return
    end
    self.qr_dialog = nil
    self.programmatic_close = programmatic == true
    UIManager:close(dialog)
    self.programmatic_close = false
end

function QRLogin:cancel()
    self.session_account = nil
    self.generation = self.generation + 1
    self.login_cookies = nil
    self.started_at = nil
    self:_stop_poll_job()
    self:_close_qr_dialog(true)
end

-- The device is going to sleep and Wi-Fi with it: end the session instead
-- of polling into the screensaver (F11, F16).
function QRLogin:on_suspend()
    if not self.started_at and not self.qr_dialog and not self.poll_job then
        return false
    end
    logger.info("QR login cancelled by suspend")
    self:cancel()
    return true
end

function QRLogin:start()
    -- runOnlineTask checks the network (and reports offline) itself; a
    -- second check here only doubled the blocking DNS lookup.
    self:cancel()
    local generation = self.generation
    self.session_account = self:_account_id()
    self.started_at = os.time()
    -- Initialize a missing fingerprint in the parent before forking.
    local fingerprint = self.settings:get_device_fingerprint()
    self:_run_protocol_request(_("Getting login QR code..."), generation, function(worker)
        worker.settings = { get_device_fingerprint = function() return fingerprint end }
        return worker:_begin_protocol()
    end, function(uid)
        self:_show_qr(uid, generation)
    end, function(err)
        logger.err("get login UID failed:", error_text(err))
        self:cancel()
        self.host:showInfo(T(_("QR login failed:\n%1"), error_text(err)))
    end)
end

function QRLogin:_show_qr(uid, generation)
    local screen_width = Device.screen:getWidth()
    local screen_height = Device.screen:getHeight()
    local qr_size = math.floor(math.min(screen_width, screen_height) * 0.72)
    local dialog
    dialog = QRMessage:new{
        text = BASE_URL .. "/web/confirm?uid=" .. WeRead.urlencode(uid),
        -- QRMessage centers its framed content on the screen. Keeping the frame
        -- smaller than the viewport makes it a dismissible popup instead of a
        -- full-screen QR surface; tapping the modal surface (or pressing a key)
        -- cancels the login flow through dismiss_callback.
        width = qr_size,
        height = qr_size,
        dismiss_callback = function()
            if self.qr_dialog == dialog then
                self.qr_dialog = nil
            end
            if not self.programmatic_close and generation == self.generation then
                self:cancel()
                self.host:showTransientInfo(_("QR login cancelled."), 2)
            end
        end,
        scale_factor = 0.9,
    }
    self.qr_dialog = dialog
    -- Show the QR dialog after the surrounding UI has finished updating.
    -- Showing it immediately can leave part of the QR code obscured on Kindle.
    UIManager:scheduleIn(0.2, function()
        if generation == self.generation and self.qr_dialog == dialog then
            UIManager:show(dialog)
        end
    end)

    UIManager:scheduleIn(0.5, function()
        if generation == self.generation and self.qr_dialog == dialog then
            if not self:_start_poll_job(uid, generation) then
                self:_poll(uid, generation)
            end
        end
    end)
end

-- Runs the whole getLoginInfo long-poll loop in a forked process until the
-- server gives a final answer or the QR session expires. The UI loop only
-- checks the pipe every POLL_JOB_CHECK_SECONDS. Returns false when the
-- platform cannot fork (or the fork fails); the caller then uses the
-- dismissable worker helper.
function QRLogin:_start_poll_job(uid, generation)
    local runner = self.subprocess
    if not runner then return false end
    local deadline = (self.started_at or self.now()) + LOGIN_SESSION_TIMEOUT_SECONDS
    local ok_run, pid, read_fd = pcall(runner.run, function(_pid, write_fd)
        local result
        while os.time() < deadline do
            local ok, data = pcall(self._poll_protocol, self, uid, "")
            if not ok then
                if not is_timeout_error(data) then
                    result = { error = error_text(data) }
                    break
                end
            elseif not data.transport_pending then
                result = { data = data, cookies = self.login_cookies }
                break
            end
            sleep_seconds(POLL_JOB_INTERVAL_SECONDS)
        end
        result = result or { expired = true }
        local ok_encode, encoded = pcall(self.client.json_encode, self.client, result)
        if not ok_encode or type(encoded) ~= "string" then
            encoded = '{"error":"failed to serialize login result"}'
        end
        runner.write_all(write_fd, encoded)
    end)
    if not ok_run or not pid then
        logger.warn("QR login poll process unavailable, trying request worker:",
            tostring(ok_run and read_fd or pid))
        return false
    end
    local job = { pid = pid, read_fd = read_fd, uid = uid, generation = generation }
    job.check = function() self:_check_poll_job(job) end
    self.poll_job = job
    self.scheduler:scheduleIn(POLL_JOB_CHECK_SECONDS, job.check)
    return true
end

function QRLogin:_check_poll_job(job)
    if self.poll_job ~= job then return end
    local runner = self.subprocess
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd)
    if not done and not (readable and readable > 0) then
        self.scheduler:scheduleIn(POLL_JOB_CHECK_SECONDS, job.check)
        return
    end
    local payload = job.read_fd and runner.read_all(job.read_fd)
    job.read_fd = nil
    self.poll_job = nil
    if not done then self:_reap(job.pid) end
    if job.generation ~= self.generation then return end
    if self.session_account ~= nil and self.session_account ~= self:_account_id() then
        self:cancel()
        return
    end
    local ok, result = pcall(self.client.json_decode, self.client, payload or "")
    if not ok or type(result) ~= "table" then
        result = { error = "login poll returned no result" }
    end
    self:_handle_poll_result(job.uid, job.generation, result)
end

-- Kills a running poll process and reaps it in the background.
function QRLogin:_stop_poll_job()
    local job = self.poll_job
    if not job then return end
    self.poll_job = nil
    local runner = self.subprocess
    if self.scheduler.unschedule then self.scheduler:unschedule(job.check) end
    pcall(runner.terminate, job.pid)
    if job.read_fd then
        pcall(runner.read_all, job.read_fd)
        job.read_fd = nil
    end
    self:_reap(job.pid)
end

function QRLogin:_reap(pid)
    local runner = self.subprocess
    local reap
    reap = function()
        local ok, done = pcall(runner.is_done, pid)
        if ok and not done then
            self.scheduler:scheduleIn(2, reap)
        end
    end
    reap()
end

function QRLogin:_handle_poll_result(uid, generation, result)
    if result.expired then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The QR code has expired. Please try again."))
        return
    end
    if result.error then
        self:_close_qr_dialog(true)
        self:cancel()
        logger.err("login polling failed:", error_text(result.error))
        self.host:showInfo(T(_("QR login failed:\n%1"), error_text(result.error)))
        return
    end
    if type(result.cookies) == "table" then
        self.login_cookies = result.cookies
    end
    self:_handle_login_info(uid, generation, result.data or {})
end

function QRLogin:_schedule_poll(uid, generation)
    UIManager:scheduleIn(INLINE_POLL_INTERVAL_SECONDS, function()
        if generation == self.generation and self.qr_dialog then
            self:_poll(uid, generation)
        end
    end)
end

function QRLogin:_poll(uid, generation, otp)
    if os.time() - (self.started_at or os.time()) > LOGIN_SESSION_TIMEOUT_SECONDS then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The QR code has expired. Please try again."))
        return
    end

    self:_run_protocol_request(_("QR login"), generation, function(worker)
        return worker:_poll_protocol(uid, otp or "", INLINE_POLL_TIMEOUT)
    end, function(result)
        if result.transport_pending then
            self:_schedule_poll(uid, generation)
            return
        end
        self:_handle_login_info(uid, generation, result)
    end, function(err)
        if is_timeout_error(err) then
            self:_schedule_poll(uid, generation)
            return
        end
        self:_close_qr_dialog(true)
        self:cancel()
        logger.err("login polling failed:", error_text(err))
        self.host:showInfo(T(_("QR login failed:\n%1"), error_text(err)))
    end)
end

function QRLogin:_handle_login_info(uid, generation, result)
    if result.succeed == true then
        self:_close_qr_dialog(true)
        self:_complete(result, generation)
        return
    end

    local logic_code = tostring(result.logicCode or "")
    if logic_code == "NEED_OTP" then
        self:_close_qr_dialog(true)
        self:_show_otp(uid, generation)
    elseif logic_code == "LOGIN_TIMEOUT" then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The QR code has expired. Please try again."))
    elseif logic_code == "OTP_EXPIRED" then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The verification code has expired. Please try again."))
    elseif logic_code == "OTP_NOT_MATCH" then
        self:_close_qr_dialog(true)
        self:_show_otp(uid, generation, _("Incorrect verification code."))
    else
        self:_close_qr_dialog(true)
        self:cancel()
        local message = logic_code ~= "" and logic_code or _("Unknown login response")
        self.host:showInfo(T(_("QR login failed:\n%1"), message))
    end
end

function QRLogin:_show_otp(uid, generation, error_message)
    local description = _("Enter the four-digit verification code shown on your phone.")
    if error_message and error_message ~= "" then
        description = error_message .. "\n\n" .. description
    end

    local dialog
    dialog = InputDialog:new{
        title = _("Verification code required"),
        input = "",
        input_type = "text",
        description = description,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        self:cancel()
                    end,
                },
                {
                    text = _("Verify"),
                    is_enter_default = true,
                    callback = function()
                        local otp = tostring(dialog:getInputText() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        if not otp:match("^%d%d%d%d$") then
                            self.host:showInfo(_("The verification code must contain four digits."))
                            return
                        end
                        UIManager:close(dialog)
                        local function delivered(ok, result)
                            if not ok then
                                if is_timeout_error(result) then
                                    self:_show_otp(uid, generation, _("Verification timed out. Please try again."))
                                else
                                    logger.err("OTP verification failed:", error_text(result))
                                    self:cancel()
                                    self.host:showInfo(T(_("QR login failed:\n%1"), error_text(result)))
                                end
                            elseif result.transport_pending then
                                self:_show_otp(uid, generation, _("Verification timed out. Please try again."))
                            elseif result.succeed == true then
                                self:_complete(result, generation)
                            else
                                local code = tostring(result.logicCode or "")
                                if code == "OTP_NOT_MATCH" or code == "NEED_OTP" then
                                    self:_show_otp(uid, generation, _("Incorrect verification code."))
                                elseif code == "OTP_EXPIRED" then
                                    self:cancel()
                                    self.host:showInfo(_("The verification code has expired. Please try again."))
                                else
                                    self:cancel()
                                    local message = code ~= "" and code or _("Unknown login response")
                                    self.host:showInfo(T(_("QR login failed:\n%1"), message))
                                end
                            end
                        end
                        self:_run_protocol_request(_("Verifying login..."), generation, function(worker)
                            return worker:_poll_protocol(uid, otp)
                        end, function(result) delivered(true, result) end,
                            function(err) delivered(false, err) end)
                    end,
                },
            },
        },
    }
    self.host:showInputDialog(dialog)
end

function QRLogin:_complete(login_result, generation)
    self:_run_protocol_request(_("Completing WeRead login..."), generation, function(worker)
        return worker:_fetch_credentials(login_result)
    end, function(credentials)
        local account = self:_apply_credentials(credentials, generation)

        local account_name = account.name
        if type(account_name) ~= "string" or account_name == "" then
            account_name = _("Unknown account")
        end
        logger.info("login completed")
        self.host:refreshLoginMenu()
        self.host:showInfo(T(
            _("WeRead login successful.\n\nAccount: %1\nCookie: %2\nOfficial API key: %3"),
            account_name,
            _("configured"),
            _("configured")
        ))
    end, function(err)
        logger.err("complete login failed:", error_text(err))
        self:cancel()
        self.host:showInfo(T(_("QR login failed:\n%1"), error_text(err)))
    end)
end

return QRLogin
