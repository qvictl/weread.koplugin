package.path = "./?.lua;./?/init.lua;" .. package.path

-- Behavioural coverage of the QR login flow: protocol requests, the inline
-- and forked getLoginInfo poll, the login-info state machine, the OTP
-- dialog, completion/persistence and cancellation clean-up.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function contains(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

-- KOReader stubs ---------------------------------------------------------

local sleeps = {}
package.preload["socket"] = function()
    return { sleep = function(seconds) sleeps[#sleeps + 1] = seconds end }
end

package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end,
        getHeight = function() return 800 end } }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.logger"] = function()
    local function noop() end
    return { scoped = function()
        return { warn = noop, err = noop, dbg = noop, info = noop }
    end }
end
package.preload["ffi/util"] = function()
    -- No runInSubProcess: the default runner is unavailable (inline polling).
    return { template = function(text, ...)
        local args = { ... }
        return (text:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end }
end

local ui = { scheduled = {}, shown = {}, closed = {} }
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, fn)
            ui.scheduled[#ui.scheduled + 1] = { delay = delay, fn = fn }
        end,
        show = function(_self, widget) ui.shown[#ui.shown + 1] = widget end,
        close = function(_self, widget)
            ui.closed[#ui.closed + 1] = widget
            -- Worst case: closing the widget fires its dismiss callback.
            if widget.dismiss_callback then widget.dismiss_callback() end
        end,
    }
end
package.preload["ui/widget/qrmessage"] = function()
    return { new = function(_self, args) args.kind = "qr"; return args end }
end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_self, args)
        args.kind = "otp"
        args.getInputText = function(self) return self.typed end
        return args
    end }
end
package.preload["weread.lib.protocol"] = function()
    return { urlencode = function(value)
        return (tostring(value):gsub("[^%w%-_%.~]", function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    end }
end

local QRLogin = require("weread.lib.qr_login")

-- Helpers ----------------------------------------------------------------

local function reset_ui()
    ui.scheduled, ui.shown, ui.closed = {}, {}, {}
    sleeps = {}
end

-- Runs (and drains) scheduled UI callbacks, optionally only those with a
-- given delay. Returns the number run.
local function run_scheduled(delay)
    local ran = 0
    local pending = ui.scheduled
    ui.scheduled = {}
    for _i, item in ipairs(pending) do
        if delay == nil or item.delay == delay then
            ran = ran + 1
            item.fn()
        else
            ui.scheduled[#ui.scheduled + 1] = item
        end
    end
    return ran
end

local function make_host()
    local host = { infos = {}, transients = {}, busy = {}, closed_busy = 0,
        inputs = {}, refreshed = 0, account_changed = 0, tasks = {} }
    function host:showInfo(text) self.infos[#self.infos + 1] = text end
    function host:showTransientInfo(text) self.transients[#self.transients + 1] = text end
    function host:showBusy(text) self.busy[#self.busy + 1] = text end
    function host:closeBusy() self.closed_busy = self.closed_busy + 1 end
    function host:runOnlineTask(name, fn, delay, options)
        self.tasks[#self.tasks + 1] = name
        self.task_delay, self.task_options = delay, options
        fn()
    end
    function host:_runNetworkRequest(text, _label, task, success, failure)
        self:showBusy(text)
        local ok, value = pcall(task)
        self:closeBusy()
        if ok then success(value) else failure(value, false) end
    end
    function host:showInputDialog(dialog) self.inputs[#self.inputs + 1] = dialog end
    function host:refreshLoginMenu() self.refreshed = self.refreshed + 1 end
    function host:onWeReadAccountChanged() self.account_changed = self.account_changed + 1 end
    return host
end

local function make_settings()
    local settings = { saved = {} }
    function settings:get_device_fingerprint() return "fp123" end
    function settings:update_auth(credentials, options)
        self.saved[#self.saved + 1] = { credentials = credentials, options = options }
    end
    return settings
end

-- A scripted client: `routes` maps a URL substring to a list of responses
-- consumed in order (the last one repeats). A response is
-- { body, code, headers, status } or a function(opts) returning those, or
-- { raise = "message" } to make request() throw.
local function make_client(routes)
    local client = { requests = {} }
    local function respond(_self, opts)
        client.requests[#client.requests + 1] = opts
        for pattern, list in pairs(routes) do
            if opts.url:find(pattern, 1, true) then
                local response = list[1]
                if #list > 1 then table.remove(list, 1) end
                if type(response) == "function" then return response(opts) end
                if response.raise then error(response.raise, 0) end
                return response[1], response[2], response[3] or {}, response[4]
            end
        end
        error("unexpected request " .. opts.url)
    end
    client.request = respond
    client.request_follow = respond
    function client:decode_http_json(body) return body end
    return client
end

local function requests_to(client, pattern)
    local found = {}
    for _i, opts in ipairs(client.requests) do
        if opts.url:find(pattern, 1, true) then found[#found + 1] = opts end
    end
    return found
end

local function success_routes(overrides)
    local routes = {
        ["/r/weread-skills"] = { { "<html>", 200, { ["Set-Cookie"] = "wr_page=p1; Path=/" } } },
        ["getLoginUid"] = { { { uid = "U-1" }, 200 } },
        ["getLoginInfo"] = { { { succeed = true, webLoginVid = "vid9",
            accessToken = "skey-abcdef", refreshToken = "r/t+1" }, 200 } },
        ["/api/userInfo"] = { { { name = "Reader" }, 200, { ["set-cookie"] = "wr_ui=1" } } },
        ["apikeyGet"] = { { { apikey = "KEY-1" }, 200 } },
    }
    for key, value in pairs(overrides or {}) do routes[key] = value end
    return routes
end

local function new_login(routes, options)
    local host, settings = make_host(), make_settings()
    local client = make_client(routes or success_routes())
    return QRLogin:new(host, client, settings, options or { subprocess = false })
end

-- _request_json / _poll_protocol ---------------------------------------------

do
    reset_ui()
    local login = new_login({
        ["getLoginInfo"] = {
            { nil, nil, nil, "closed" },
            { { logicCode = "NEED_OTP" }, 200, { ["SET-COOKIE"] = "wr_poll=2; other=x" } },
            { "not json", 200 },
            { {}, 503 },
        },
    })
    local client = login.client
    login.login_cookies = { wr_page = "p1" }

    local pending = login:_poll_protocol("U 1")
    expect(pending.transport_pending == true,
        "a closed getLoginInfo connection must be reported as pending, not as an error")
    expect(login.login_cookies.wr_page == "p1" and login.login_cookies.wr_poll == nil,
        "a failed transport must not change the login cookie jar")
    local first = client.requests[1]
    expect(first.skip_cookie == true, "login requests must never use the stored account cookies")
    expect(first.headers.Cookie == "wr_page=p1", "login cookies must be sent with the poll")
    expect(first.timeout[1] == 5 and first.timeout[2] == 8, "background poll uses the long-poll timeout")
    expect(contains(first.url, "uid=U%201&otp="), "UID is URL-encoded")

    local data = login:_poll_protocol("U 1", "", { 1, 2 })
    expect(data.logicCode == "NEED_OTP", "server answer returned unchanged")
    expect(login.login_cookies.wr_poll == "2" and login.login_cookies.other == nil,
        "only WeRead cookies from a case-insensitive Set-Cookie header are merged")
    expect(client.requests[2].timeout[1] == 1, "explicit poll timeout is honoured")

    local ok, err = pcall(login._poll_protocol, login, "U 1")
    expect(not ok and contains(err, "invalid JSON"), "a non-object JSON body is rejected")
    ok, err = pcall(login._poll_protocol, login, "U 1")
    expect(not ok and contains(err, "getLoginInfo") and contains(err, "HTTP 503"),
        "an HTTP error names the stage and the status")

    for _i, bad_uid in ipairs({ "", 42 }) do
        local count = #client.requests
        ok, err = pcall(login._poll_protocol, login, bad_uid)
        expect(not ok and contains(err, "Missing QR login UID"), "a missing UID is rejected")
        expect(#client.requests == count, "no request is sent without a UID")
    end

    local fresh = new_login({ ["getLoginInfo"] = { { { logicCode = "X" }, 200 } } })
    fresh:_poll_protocol("U")
    expect(fresh.client.requests[1].headers.Cookie == nil,
        "no Cookie header is sent while the login jar is empty")
end

-- _begin_protocol ------------------------------------------------------------

do
    local login = new_login()
    local client = login.client
    expect(login:_begin_protocol() == "U-1", "UID returned from getLoginUid")
    expect(client.requests[1].maxredirects == 5, "login page request follows redirects")
    expect(client.requests[2].headers.Cookie == "wr_fp=fp123; wr_page=p1",
        "page cookies and the device fingerprint are sent to getLoginUid")
    expect(login.login_cookies.wr_page == "p1", "login cookie jar kept for the poll")

    local function begin_error(overrides)
        local failing = new_login(success_routes(overrides))
        local ok, err = pcall(failing._begin_protocol, failing)
        expect(not ok, "begin must fail")
        expect(failing.login_cookies == nil, "a failed begin must not leave a login cookie jar")
        return err, failing.client
    end
    local err, failing_client = begin_error({ ["/r/weread-skills"] = { { "", 503 } } })
    expect(contains(err, "Unable to open WeRead login page") and contains(err, "503"),
        "login page HTTP error reported")
    expect(#requests_to(failing_client, "getLoginUid") == 0, "no UID request after the page failed")
    expect(contains(begin_error({ ["/r/weread-skills"] = { { nil, nil, nil, "closed" } } }),
        "Unable to open WeRead login page"), "login page transport error reported")
    expect(contains(begin_error({ ["getLoginUid"] = { { { uid = "" }, 200 } } }), "valid login UID"),
        "empty UID rejected")
    expect(contains(begin_error({ ["getLoginUid"] = { { { uid = 42 }, 200 } } }), "valid login UID"),
        "non-string UID rejected")
    err = begin_error({ ["getLoginUid"] = { { {}, 500 } } })
    expect(contains(err, "getLoginUid") and contains(err, "HTTP 500"), "UID HTTP error reported")
end

-- _complete_protocol: credentials are persisted only on success -------------

do
    local login = new_login()
    local client, settings = login.client, login.settings
    login.login_cookies = { wr_page = "p1", wr_vid = "old-vid", wr_skey = "old-skey" }
    local jar_before = login.login_cookies
    local account = login:_complete_protocol({ succeed = true, webLoginVid = "vid9",
        accessToken = "skey-abcdef", refreshToken = "r/t+1" }, login.generation)
    expect(account.user_vid == "vid9" and account.name == "Reader" and account.login_method == "qr",
        "account built from the login result and userInfo")
    expect(#settings.saved == 1, "credentials persisted once")
    local saved = settings.saved[1]
    expect(saved.options.replace_cookies == true, "QR login replaces the cookie jar")
    local cookies = saved.credentials.cookies
    expect(cookies.wr_vid == "vid9" and cookies.wr_skey == "skey-abcdef" and cookies.wr_ql == "0",
        "new account credentials override the old ones")
    expect(cookies.wr_rt == "r%2Ft%2B1", "refresh token stored URL-encoded")
    expect(cookies.wr_page == "p1" and cookies.wr_ui == "1",
        "login-session and authenticated-request cookies are kept")
    expect(saved.credentials.api_key == "KEY-1" and saved.credentials.wr_ticket == ""
        and saved.credentials.wr_wrpa == "", "API key stored and legacy tokens cleared")
    expect(jar_before.wr_vid == "old-vid", "the login cookie jar is copied, not mutated")
    expect(login.login_cookies == nil, "login cookie jar dropped after success")
    expect(login.host.account_changed == 1, "host notified about the account switch")
    local user_request = requests_to(client, "/api/userInfo")[1]
    expect(contains(user_request.url, "userVid=vid9"), "userInfo requested for the new account")
    expect(user_request.headers["X-Vid"] == "vid9" and user_request.headers["X-Skey"] == "skey-abcdef",
        "authenticated requests carry the new credentials")
    expect(contains(requests_to(client, "apikeyGet")[1].headers.Cookie, "wr_ui=1"),
        "cookies from userInfo are forwarded to apikeyGet")

    -- No refresh token, no name, no host callback.
    local plain = new_login(success_routes({ ["/api/userInfo"] = { { { name = 7 }, 200 } } }))
    plain.host.onWeReadAccountChanged = nil
    local plain_account = plain:_complete_protocol({ succeed = true, webLoginVid = 5,
        accessToken = "tok-123456" }, plain.generation)
    expect(plain_account.name == "" and plain_account.user_vid == "5", "non-string name becomes empty")
    expect(plain.settings.saved[1].credentials.cookies.wr_rt == nil, "no refresh cookie without a token")

    local function complete_error(result, overrides, mutate)
        local failing = new_login(success_routes(overrides))
        if mutate then mutate(failing) end
        local ok, err = pcall(failing._complete_protocol, failing, result, failing.generation)
        expect(not ok, "completion must fail")
        expect(#failing.settings.saved == 0, "no credentials persisted on failure: " .. tostring(err))
        expect(failing.host.account_changed == 0, "host not notified on failure")
        return err, failing.client
    end
    local good = { succeed = true, webLoginVid = "vid9", accessToken = "skey-abcdef" }

    local err, failing_client = complete_error({ succeed = false, logicCode = "NEED_OTP" })
    expect(contains(err, "has not succeeded") and #failing_client.requests == 0,
        "an unsuccessful result is rejected without network")
    expect(contains(complete_error("garbage"), "has not succeeded"), "a malformed result is rejected")
    expect(contains(complete_error({ succeed = true, webLoginVid = "vid9" }), "missing account credentials"),
        "a missing access token is rejected")
    expect(contains(complete_error({ succeed = true, accessToken = "x" }), "missing account credentials"),
        "a missing vid is rejected")

    -- userInfo: 401 is retried, the third failure is final.
    reset_ui()
    err, failing_client = complete_error(good, { ["/api/userInfo"] = { { {}, 401 } } })
    expect(contains(err, "HTTP 401") and #requests_to(failing_client, "/api/userInfo") == 3,
        "userInfo 401 retried three times before giving up")
    expect(#sleeps == 2 and sleeps[1] == 0.5, "retries back off between attempts")
    -- Other HTTP errors are not retried.
    err, failing_client = complete_error(good, { ["/api/userInfo"] = { { {}, 500 } } })
    expect(contains(err, "HTTP 500") and #requests_to(failing_client, "/api/userInfo") == 1,
        "userInfo 500 fails without retry")

    -- apikeyGet: retried while empty, error when never returned.
    err, failing_client = complete_error(good, { ["apikeyGet"] = { { { apikey = "" }, 200 } } })
    expect(contains(err, "API key") and #requests_to(failing_client, "apikeyGet") == 3,
        "missing API key retried three times then reported")

    -- Cancelled while the network was in flight: nothing persisted.
    local racing
    err = complete_error(good, { ["apikeyGet"] = { function()
        racing:cancel()
        return { apikey = "KEY" }, 200, {}
    end } }, function(instance) racing = instance end)
    expect(contains(err, "cancelled"), "a cancelled session must not save credentials")

    -- Transient failures recover.
    local recovering = new_login(success_routes({
        ["/api/userInfo"] = { { {}, 401 }, { { name = "R" }, 200 } },
        ["apikeyGet"] = { { { apikey = "" }, 200 }, { { apikey = false }, 200 }, { { apikey = "K" }, 200 } },
    }))
    recovering:_complete_protocol(good, recovering.generation)
    expect(#requests_to(recovering.client, "/api/userInfo") == 2
        and #requests_to(recovering.client, "apikeyGet") == 3, "transient failures retried")
    expect(recovering.settings.saved[1].credentials.api_key == "K", "late API key persisted")
end

-- start(): begin + QR dialog -------------------------------------------------

do
    reset_ui()
    local failed = new_login(success_routes({ ["getLoginUid"] = { { {}, 500 } } }))
    failed:start()
    expect(failed.host.busy[1] and failed.host.closed_busy == 1, "busy indicator shown and closed")
    expect(contains(failed.host.infos[1], "QR login failed") and contains(failed.host.infos[1], "HTTP 500"),
        "begin failure reported")
    expect(failed.qr_dialog == nil and #ui.scheduled == 0, "no QR dialog after a failed begin")

    -- Cancelled while getting the UID: silent.
    reset_ui()
    local racing
    racing = new_login(success_routes({ ["getLoginUid"] = { function()
        racing:cancel()
        return { uid = "U" }, 200, {}
    end } }))
    racing:start()
    expect(#racing.host.infos == 0 and racing.qr_dialog == nil, "a cancelled begin shows nothing")

    -- Successful begin shows the QR dialog after a delay and starts polling.
    reset_ui()
    local login = new_login(success_routes({
        ["getLoginUid"] = { { { uid = "U/1" }, 200 } },
        ["getLoginInfo"] = { { nil, nil, nil, "closed" } },
    }))
    login:start()
    local dialog = login.qr_dialog
    expect(dialog and dialog.kind == "qr", "QR dialog created")
    expect(dialog.text == "https://weread.qq.com/web/confirm?uid=U%2F1", "QR encodes the confirm URL")
    expect(dialog.width == 432 and dialog.height == 432, "QR sized to 72% of the short screen edge")
    expect(#ui.shown == 0, "dialog is shown only after the UI settled")
    expect(run_scheduled(0.2) == 1 and ui.shown[1] == dialog, "dialog shown")
    expect(#requests_to(login.client, "getLoginInfo") == 0, "no poll before the delay")
    expect(run_scheduled(0.5) == 1, "poll started")
    local polls = requests_to(login.client, "getLoginInfo")
    expect(#polls == 1 and polls[1].timeout[1] == 2 and polls[1].timeout[2] == 3,
        "failed dedicated worker uses a short dismissable worker request")
    expect(ui.scheduled[1].delay == 1.5, "a pending inline poll is rescheduled")

    -- User dismisses the QR dialog: the session is cancelled.
    local generation = login.generation
    dialog.dismiss_callback()
    expect(login.generation == generation + 1 and login.qr_dialog == nil and login.started_at == nil,
        "dismissing the QR dialog cancels the session")
    expect(login.host.transients[1] == "QR login cancelled.", "cancellation acknowledged")
    expect(run_scheduled(1.5) == 1 and #requests_to(login.client, "getLoginInfo") == 1,
        "a cancelled session never polls again")

    -- Callbacks of a cancelled session neither show nor poll.
    reset_ui()
    local stale = new_login()
    stale:start()
    local stale_dialog = stale.qr_dialog
    stale:cancel()
    expect(#stale.host.transients == 0, "programmatic close is not reported as a user cancellation")
    expect(ui.closed[1] == stale_dialog, "cancel closes the QR dialog")
    run_scheduled()
    expect(#ui.shown == 0 and #requests_to(stale.client, "getLoginInfo") == 0,
        "callbacks of a cancelled session neither show nor poll")
end

-- Fallback poll: expiry, retries and errors -------------------------------------

do
    local function inline(routes)
        reset_ui()
        local login = new_login(routes)
        login.qr_dialog = { kind = "qr" }
        login.started_at = os.time()
        return login
    end

    local retrying = inline({ ["getLoginInfo"] = {
        { raise = "connection timeout" }, { raise = "wantread" }, { nil, nil, nil, "closed" },
        { { logicCode = "LOGIN_TIMEOUT" }, 200 },
    } })
    retrying:_poll("U", retrying.generation)
    for _i = 1, 3 do
        expect(#ui.scheduled == 1 and ui.scheduled[1].delay == 1.5, "transient poll failure retried")
        run_scheduled()
    end
    expect(#requests_to(retrying.client, "getLoginInfo") == 4, "poll retried until the server answered")
    expect(contains(retrying.host.infos[1], "expired") and retrying.qr_dialog == nil
        and retrying.started_at == nil, "LOGIN_TIMEOUT closes the session as expired")

    local hard = inline({ ["getLoginInfo"] = { { raise = "boom" } } })
    hard:_poll("U", hard.generation)
    expect(contains(hard.host.infos[1], "QR login failed") and contains(hard.host.infos[1], "boom"),
        "a non-timeout poll error fails the session")
    expect(#ui.scheduled == 0 and hard.qr_dialog == nil, "no retry after a hard failure")

    local http = inline({ ["getLoginInfo"] = { { {}, 500 } } })
    http:_poll("U", http.generation)
    expect(contains(http.host.infos[1], "HTTP 500") and #ui.scheduled == 0, "HTTP errors are not retried")

    local expired = inline({ ["getLoginInfo"] = { { { logicCode = "X" }, 200 } } })
    expired.started_at = os.time() - 301
    expired:_poll("U", expired.generation)
    expect(#expired.client.requests == 0, "an expired session does not poll")
    expect(contains(expired.host.infos[1], "expired") and expired.qr_dialog == nil
        and expired.started_at == nil, "an expired session is closed")

    -- Cancelled while the request was in flight: the result is dropped.
    local racing
    racing = inline({ ["getLoginInfo"] = { function()
        racing:cancel()
        return { succeed = true }, 200, {}
    end } })
    racing:_poll("U", racing.generation)
    expect(#racing.host.infos == 0 and #ui.scheduled == 0 and #racing.host.busy == 1,
        "a result for a cancelled session is ignored")

    -- The OTP is forwarded by the inline poll.
    local with_otp = inline({ ["getLoginInfo"] = { { { logicCode = "OTP_EXPIRED" }, 200 } } })
    with_otp:_poll("U", with_otp.generation, "4321")
    expect(contains(with_otp.client.requests[1].url, "otp=4321"), "OTP sent with the poll")
    expect(contains(with_otp.host.infos[1], "verification code has expired"), "expired OTP reported")
end

-- Login-info state machine ------------------------------------------------------

do
    local function handle(result)
        reset_ui()
        local login = new_login()
        login.qr_dialog = { kind = "qr" }
        login.started_at = os.time()
        login.generation_before = login.generation
        login:_handle_login_info("U", login.generation, result)
        return login
    end

    local confirmed = handle({ succeed = true, webLoginVid = "vid9", accessToken = "skey-abcdef" })
    expect(confirmed.qr_dialog == nil and #confirmed.settings.saved == 1,
        "confirmed login completes and persists")
    expect(confirmed.host.refreshed == 1 and contains(confirmed.host.infos[1], "login successful")
        and contains(confirmed.host.infos[1], "Account: Reader"), "success reported with the account name")
    expect(confirmed.generation == confirmed.generation_before, "a successful login is not cancelled")

    local scanned = handle({ logicCode = "NEED_OTP" })
    local otp = scanned.host.inputs[1]
    expect(otp and otp.kind == "otp" and scanned.qr_dialog == nil,
        "scanned with OTP: QR replaced by OTP prompt")
    expect(scanned.generation == scanned.generation_before and #scanned.settings.saved == 0,
        "session stays alive for the OTP")
    expect(not contains(otp.description, "Incorrect"), "first OTP prompt has no error")

    expect(contains(handle({ logicCode = "OTP_NOT_MATCH" }).host.inputs[1].description,
        "Incorrect verification code"), "wrong OTP re-prompted")

    local otp_expired = handle({ logicCode = "OTP_EXPIRED" })
    expect(contains(otp_expired.host.infos[1], "verification code has expired")
        and #otp_expired.host.inputs == 0, "expired OTP ends the session")

    local unknown = handle({ logicCode = "SOMETHING_NEW" })
    expect(unknown.host.infos[1] == "QR login failed:\nSOMETHING_NEW", "unknown logic code surfaced")
    expect(#unknown.settings.saved == 0 and unknown.started_at == nil, "unknown answer cancels without saving")

    expect(contains(handle({}).host.infos[1], "Unknown login response"), "empty answer reported")
end

-- OTP dialog --------------------------------------------------------------------

do
    local function otp_dialog(routes, error_message)
        reset_ui()
        local login = new_login(success_routes(routes))
        login.started_at = os.time()
        login:_show_otp("U", login.generation, error_message)
        login.dialog = login.host.inputs[1]
        login.cancel_button = login.dialog.buttons[1][1]
        login.verify_button = login.dialog.buttons[1][2]
        return login
    end

    local login = otp_dialog(nil, "Oops")
    local dialog, host = login.dialog, login.host
    expect(contains(dialog.description, "Oops\n\n"), "error shown above the instructions")
    expect(login.verify_button.is_enter_default == true and login.cancel_button.id == "close",
        "dialog buttons wired")

    for _i, typed in ipairs({ "12a4", "123", "12345", "" }) do
        dialog.typed = typed
        login.verify_button.callback()
    end
    dialog.typed = nil
    login.verify_button.callback()
    expect(#host.infos == 5 and contains(host.infos[1], "four digits"), "non four-digit codes rejected")
    expect(#login.client.requests == 0 and #ui.closed == 0, "invalid codes keep the dialog and send nothing")

    dialog.typed = " 1234\n"
    login.verify_button.callback()
    expect(ui.closed[1] == dialog, "verify closes the OTP dialog")
    expect(contains(requests_to(login.client, "getLoginInfo")[1].url, "otp=1234"), "trimmed OTP submitted")
    expect(#login.settings.saved == 1 and host.refreshed == 1, "correct OTP completes the login")

    local cancelled = otp_dialog()
    local generation = cancelled.generation
    cancelled.cancel_button.callback()
    expect(ui.closed[1] == cancelled.dialog and cancelled.generation == generation + 1
        and cancelled.started_at == nil, "cancel closes the dialog and the session")
    expect(#cancelled.client.requests == 0 and #cancelled.settings.saved == 0, "cancel sends nothing")

    local function verify_with(response)
        local l = otp_dialog({ ["getLoginInfo"] = { response } })
        l.dialog.typed = "0000"
        l.generation_before = l.generation
        l.verify_button.callback()
        return l
    end

    local l = verify_with({ { logicCode = "OTP_NOT_MATCH" }, 200 })
    expect(#l.host.inputs == 2 and contains(l.host.inputs[2].description, "Incorrect"), "wrong OTP re-prompted")
    expect(l.generation == l.generation_before and #l.settings.saved == 0,
        "wrong OTP keeps the session, saves nothing")
    l = verify_with({ { logicCode = "NEED_OTP" }, 200 })
    expect(contains(l.host.inputs[2].description, "Incorrect"), "NEED_OTP after a code is a wrong code")
    l = verify_with({ { logicCode = "OTP_EXPIRED" }, 200 })
    expect(contains(l.host.infos[1], "verification code has expired")
        and l.generation == l.generation_before + 1, "expired OTP cancels")
    l = verify_with({ { logicCode = "DENIED" }, 200 })
    expect(l.host.infos[1] == "QR login failed:\nDENIED" and l.generation == l.generation_before + 1,
        "unknown OTP answer cancels")
    l = verify_with({ {}, 200 })
    expect(contains(l.host.infos[1], "Unknown login response"), "empty OTP answer reported")
    l = verify_with({ nil, nil, nil, "closed" })
    expect(contains(l.host.inputs[2].description, "timed out"), "closed connection re-prompts")
    l = verify_with({ raise = "read timeout" })
    expect(contains(l.host.inputs[2].description, "timed out"), "timeout re-prompts")
    l = verify_with({ {}, 502 })
    expect(contains(l.host.infos[1], "HTTP 502") and l.generation == l.generation_before + 1
        and #l.host.inputs == 1, "HTTP error ends the OTP flow")
    expect(l.host.closed_busy == 1, "busy indicator closed after verification")

    local racing
    racing = otp_dialog({ ["getLoginInfo"] = { function()
        racing:cancel()
        return { succeed = true, webLoginVid = "v", accessToken = "a" }, 200, {}
    end } })
    racing.dialog.typed = "1111"
    racing.verify_button.callback()
    expect(#racing.host.infos == 0 and #racing.settings.saved == 0,
        "a verification answer for a cancelled session is ignored")
end

-- _complete: UI outcome -----------------------------------------------------------

do
    reset_ui()
    local login = new_login(success_routes({ ["apikeyGet"] = { { { apikey = "" }, 200 } } }))
    login.started_at = os.time()
    local generation = login.generation
    login:_complete({ succeed = true, webLoginVid = "v", accessToken = "a" }, generation)
    expect(contains(login.host.infos[1], "QR login failed") and contains(login.host.infos[1], "API key"),
        "completion failure reported")
    expect(login.generation == generation + 1 and #login.settings.saved == 0 and login.host.refreshed == 0,
        "failed completion cancels, saves nothing and keeps the menu")

    local nameless = new_login(success_routes({ ["/api/userInfo"] = { { {}, 200 } } }))
    nameless:_complete({ succeed = true, webLoginVid = "v", accessToken = "a" }, nameless.generation)
    expect(contains(nameless.host.infos[1], "Account: Unknown account"), "nameless account labelled")

    -- Cancelled while completing: no message, no menu refresh.
    local racing
    racing = new_login(success_routes({ ["/api/userInfo"] = { function()
        racing:cancel()
        return { name = "R" }, 200, {}
    end } }))
    racing:_complete({ succeed = true, webLoginVid = "v", accessToken = "a" }, racing.generation)
    expect(#racing.host.infos == 0 and racing.host.refreshed == 0 and racing.host.closed_busy == 1,
        "a completion for a cancelled session is silent")
    expect(#racing.settings.saved == 0, "a cancelled completion saves nothing")

    -- Long, multi-line server errors are flattened and truncated for the dialog.
    reset_ui()
    local noisy = new_login(success_routes({ ["getLoginInfo"] = { { raise = "bad\n" .. string.rep("x", 400) } } }))
    noisy.qr_dialog = { kind = "qr" }
    noisy.started_at = os.time()
    noisy:_poll("U", noisy.generation)
    local shown = noisy.host.infos[1]
    expect(not shown:find("bad\n", 1, true) and contains(shown, "bad x"), "control characters flattened")
    expect(shown:sub(-3) == "..." and #shown < 350, "long errors truncated")
end

-- Forked poll job -------------------------------------------------------------------

local function make_runner()
    local runner = { terminated = {}, reads = 0, is_done_calls = 0 }
    function runner.run(child)
        runner.child = child
        if runner.fail then error(runner.fail) end
        if runner.no_pid then return nil, "fork failed" end
        return 101, 9
    end
    function runner.write_all(_fd, data) runner.written = data end
    function runner.is_done()
        runner.is_done_calls = runner.is_done_calls + 1
        return runner.done == true
    end
    function runner.read_size() return runner.written and #runner.written or 0 end
    function runner.read_all()
        runner.reads = runner.reads + 1
        local data = runner.written
        runner.written = nil
        return data
    end
    function runner.terminate(pid) runner.terminated[#runner.terminated + 1] = pid end
    return runner
end

local function make_scheduler()
    local scheduler = { items = {}, unscheduled = {} }
    function scheduler:scheduleIn(delay, fn) self.items[#self.items + 1] = { delay = delay, fn = fn } end
    function scheduler:unschedule(fn)
        self.unscheduled[#self.unscheduled + 1] = fn
        for i = #self.items, 1, -1 do
            if self.items[i].fn == fn then table.remove(self.items, i) end
        end
    end
    function scheduler:run()
        local items = self.items
        self.items = {}
        for _i, item in ipairs(items) do item.fn() end
        return #items
    end
    return scheduler
end

local function job_login(routes, runner_options)
    reset_ui()
    local runner, scheduler = make_runner(), make_scheduler()
    for key, value in pairs(runner_options or {}) do runner[key] = value end
    local login = new_login(routes, { subprocess = runner, scheduler = scheduler })
    local stash = {}
    function login.client:json_encode(value)
        if runner.encode_fails then error("cannot encode") end
        stash[#stash + 1] = value
        return "#" .. #stash
    end
    function login.client:json_decode(text)
        if text == '{"error":"failed to serialize login result"}' then
            return { error = "failed to serialize login result" }
        end
        local value = stash[tonumber(text:sub(2)) or 0]
        if value == nil then error("bad json") end
        return value
    end
    login.qr_dialog = { kind = "qr" }
    login.started_at = os.time()
    return login, runner, scheduler
end

do
    -- Connection closed and timeouts are retried in the child until the
    -- server answers; the parent then drives the state machine.
    local login, runner, scheduler = job_login(success_routes({
        ["getLoginInfo"] = {
            { nil, nil, nil, "closed" }, { raise = "timeout" },
            { { succeed = true, webLoginVid = "vid9", accessToken = "skey-abcdef" }, 200,
              { ["set-cookie"] = "wr_child=c" } },
        },
    }))
    expect(login:_start_poll_job("U", login.generation), "poll job started")
    local job = login.poll_job
    expect(job and job.pid == 101 and scheduler.items[1].delay == 0.5, "parent checks the pipe periodically")
    runner.child(101, 9)
    expect(#requests_to(login.client, "getLoginInfo") == 3, "child retried closed/timeout polls")
    expect(#sleeps == 2 and sleeps[1] == 0.5, "child waits between polls")
    expect(runner.written ~= nil, "child wrote its result")
    expect(scheduler:run() == 1, "pipe checked")
    expect(login.poll_job == nil, "job consumed")
    expect(#login.settings.saved == 1 and login.settings.saved[1].credentials.cookies.wr_child == "c",
        "cookies collected by the child reach the persisted credentials")
    expect(contains(login.host.infos[1], "login successful") and runner.reads == 1, "login completed once")
end

do
    -- Not ready yet: the check reschedules itself without reading.
    local login, runner, scheduler = job_login(success_routes())
    login:_start_poll_job("U", login.generation)
    scheduler:run()
    expect(#scheduler.items == 1 and runner.reads == 0 and login.poll_job ~= nil,
        "an unfinished job is checked again later")
    -- Readable before the process exits: read, then reap in the background.
    runner.written = "#999"
    scheduler:run()
    expect(login.poll_job == nil and runner.reads == 1, "a readable pipe is consumed")
    expect(contains(login.host.infos[1], "no result"), "an undecodable payload fails the login")
    expect(#login.settings.saved == 0, "no credentials from a broken payload")
    expect(#scheduler.items == 1 and scheduler.items[1].delay == 2, "a live child is reaped later")
    runner.done = true
    scheduler:run()
    expect(#scheduler.items == 0, "reaping stops once the child exited")
end

do
    -- Session expiry inside the child.
    local login, runner, scheduler = job_login(success_routes())
    login.started_at = os.time() - 400
    login:_start_poll_job("U", login.generation)
    runner.child(101, 9)
    expect(#requests_to(login.client, "getLoginInfo") == 0, "an expired session does not poll in the child")
    runner.done = true
    scheduler:run()
    expect(contains(login.host.infos[1], "expired") and login.qr_dialog == nil and login.started_at == nil,
        "child expiry closes the session")
    expect(#login.settings.saved == 0, "expired QR saves nothing")
end

do
    -- Deadline defaults to options.now when the session has no start time.
    local login, runner = job_login(success_routes())
    login.started_at = nil
    login.now = function() return os.time() - 1000 end
    login:_start_poll_job("U", login.generation)
    runner.child(101, 9)
    expect(#requests_to(login.client, "getLoginInfo") == 0, "deadline computed from the injected clock")
end

do
    -- Hard errors in the child end the session.
    local login, runner, scheduler = job_login(success_routes({ ["getLoginInfo"] = { { {}, 500 } } }))
    login:_start_poll_job("U", login.generation)
    runner.child(101, 9)
    expect(#requests_to(login.client, "getLoginInfo") == 1, "HTTP errors are not retried in the child")
    runner.done = true
    scheduler:run()
    expect(contains(login.host.infos[1], "QR login failed") and contains(login.host.infos[1], "HTTP 500"),
        "child error reported")
end

do
    -- A result that cannot be serialized still reaches the parent as an error.
    local login, runner, scheduler = job_login(success_routes({
        ["getLoginInfo"] = { { { logicCode = "NEED_OTP" }, 200 } },
    }), { encode_fails = true })
    login:_start_poll_job("U", login.generation)
    runner.child(101, 9)
    runner.done = true
    scheduler:run()
    expect(contains(login.host.infos[1], "failed to serialize"), "serialization failure reported")
end

do
    -- A non-final answer from the child (OTP needed) is handed to the state machine.
    local login, runner, scheduler = job_login(success_routes({
        ["getLoginInfo"] = { { { logicCode = "NEED_OTP" }, 200 } },
    }))
    login:_start_poll_job("U", login.generation)
    runner.child(101, 9)
    runner.done = true
    scheduler:run()
    expect(#login.host.inputs == 1 and login.qr_dialog == nil, "child NEED_OTP opens the OTP prompt")
end

do
    -- A finished job for an old generation is dropped.
    local login, runner, scheduler = job_login(success_routes({
        ["getLoginInfo"] = { { { succeed = true, webLoginVid = "v", accessToken = "a" }, 200 } },
    }))
    login:_start_poll_job("U", login.generation)
    runner.child(101, 9)
    runner.done = true
    login.poll_job.generation = login.generation - 1
    scheduler:run()
    expect(#login.host.infos == 0 and #login.settings.saved == 0, "a stale job result is ignored")
end

do
    -- A check for a job that is no longer current does nothing.
    local login, runner = job_login(success_routes())
    login:_start_poll_job("U", login.generation)
    local old = login.poll_job
    login.poll_job = nil
    runner.done = true
    login:_check_poll_job(old)
    expect(runner.is_done_calls == 0 and #login.host.infos == 0, "an orphaned check is a no-op")
end

do
    -- Cancellation kills the child, unschedules the check and drains the pipe.
    local login, runner, scheduler = job_login(success_routes())
    login:_start_poll_job("U", login.generation)
    local job = login.poll_job
    runner.written = "#1"
    login:cancel()
    expect(runner.terminated[1] == 101, "child terminated on cancel")
    expect(scheduler.unscheduled[1] == job.check, "pending pipe check unscheduled")
    expect(runner.reads == 1 and job.read_fd == nil, "pipe drained on cancel")
    expect(login.poll_job == nil and login.qr_dialog == nil, "session state cleared")
    expect(#scheduler.items == 1 and scheduler.items[1].delay == 2, "terminated child reaped later")
    runner.done = true
    scheduler:run()
    job.check()
    expect(#login.host.infos == 0 and #scheduler.items == 0, "a check after cancel does nothing")
    login:cancel()
    expect(#runner.terminated == 1, "cancel is idempotent")
end

do
    -- Scheduler without unschedule still cleans up.
    local login, runner, scheduler = job_login(success_routes())
    scheduler.unschedule = nil
    login:_start_poll_job("U", login.generation)
    login:cancel()
    expect(runner.terminated[1] == 101 and login.poll_job == nil, "cleanup without unschedule")
end

do
    -- Fork failures fall back to the inline poll.
    for _i, options in ipairs({ { fail = "no fork" }, { no_pid = true } }) do
        local login, _, scheduler = job_login(success_routes({
            ["getLoginInfo"] = { { nil, nil, nil, "closed" } },
        }), options)
        expect(login:_start_poll_job("U", login.generation) == false, "fork failure reported")
        expect(login.poll_job == nil and #scheduler.items == 0, "no job tracked after a failed fork")
        login.qr_dialog = nil
        login:_show_qr("U", login.generation)
        run_scheduled()
        local polls = requests_to(login.client, "getLoginInfo")
        expect(#polls == 1 and polls[1].timeout[1] == 2, "QR flow falls back to a short dismissable worker request")
    end
end

-- A deferred delivery lets the UI cancel or switch accounts after the
-- worker returns, before its data is applied. Workers never persist auth.
do
    local good = { succeed = true, webLoginVid = "new", accessToken = "token" }
    local function deferred()
        reset_ui()
        local l = new_login()
        l.settings.account = { user_vid = "old" }
        function l.settings:get(key, default) return self[key] or default end
        function l.host:_runNetworkRequest(_text, _label, task, success, failure)
            self.worker_task, self.success, self.failure = task, success, failure
        end
        return l
    end
    local l = deferred()
    l:start()
    expect(#l.client.requests == 0, "start defers HTTP to the network worker")
    expect(l.host.task_delay == 0.1 and l.host.task_options.link_only == true,
        "QR worker startup checks link state without synchronous DNS")
    local result = l.host.worker_task()
    expect(l.login_cookies == nil, "worker begin cannot mutate parent cookies")
    l:cancel()
    l.host.success(result)
    expect(l.login_cookies == nil and not l.qr_dialog, "cancelled begin cannot revive QR state")
    l = deferred()
    l:_complete(good, l.generation)
    result = l.host.worker_task()
    expect(#l.settings.saved == 0 and l.host.account_changed == 0,
        "completion worker cannot save auth or notify account changes")
    l:cancel()
    l.host.success(result)
    expect(#l.settings.saved == 0 and #l.host.infos == 0, "late cancelled completion cannot log in")
    l = deferred()
    l:_complete(good, l.generation)
    result = l.host.worker_task()
    l.settings.account = { user_vid = "other" }
    l.host.success(result)
    expect(#l.settings.saved == 0 and l.host.refreshed == 0, "account switch rejects stale credentials")
    expect(l.generation == 1 and l.started_at == nil and l.login_cookies == nil and l.session_account == nil,
        "account mismatch cancels the generation and cleans up stale session state")
    l = deferred()
    l:_complete(good, l.generation)
    result = l.host.worker_task()
    l.settings.cookies = { wr_ticket = "rotated" }
    l.host.success(result)
    expect(#l.settings.saved == 1 and l.host.account_changed == 1,
        "same-account credential rotation permits QR completion")
    l = deferred()
    l:_show_otp("U", l.generation)
    local dialog = l.host.inputs[1]
    dialog.typed = "0000"
    dialog.buttons[1][2].callback()
    expect(#l.client.requests == 0, "OTP verification defers HTTP to the worker")
    l:cancel()
    l.host.success({ value = { logicCode = "OTP_NOT_MATCH" }, cookies = {} })
    expect(#l.host.inputs == 1, "late OTP result cannot reopen cancelled dialog")
    l = deferred()
    l:start()
    result = l.host.worker_task()
    l.host.success(result)
    l.settings.account = { user_vid = "changed-between-stages" }
    local previous = l.host.worker_task
    l:_complete(good, l.generation)
    expect(l.host.worker_task == previous and #l.settings.saved == 0,
        "account switch between QR stages invalidates the entire session")
    expect(l.started_at == nil and l.qr_dialog == nil and l.session_account == nil,
        "account switch between QR stages closes the abandoned QR dialog")

    l = deferred()
    l.started_at = os.time()
    l:_poll("U", l.generation)
    expect(#l.client.requests == 0 and type(l.host.worker_task) == "function",
        "fallback poll defers HTTP when the dedicated poll worker cannot start")

    l = deferred()
    l:start()
    local generation = l.generation
    l.host.failure(nil, true)
    expect(l.generation == generation + 1 and #l.host.infos == 0,
        "worker cancellation invalidates QR session silently")
end

do
    reset_ui()
    local l = new_login()
    function l.host:_runNetworkRequest(_text, _label, _task, _success, failure)
        failure("Skill is unavailable\nstack traceback:\n\tprivate/worker.lua:1", false)
    end
    l:_complete({ succeed = true, webLoginVid = "new", accessToken = "token" }, l.generation)
    expect(contains(l.host.infos[1], "Skill is unavailable"), "worker error keeps its useful message")
    expect(not contains(l.host.infos[1], "stack traceback") and not contains(l.host.infos[1], "private/worker"),
        "worker errors do not expose traceback implementation details in the UI")
end

do
    reset_ui()
    local l = new_login()
    l.started_at = os.time()
    l.login_cookies = { wr_fp = "synthetic" }
    l.qr_dialog = { kind = "qr" }
    function l.host:runOnlineTask() return false end
    l:_poll("U", l.generation)
    expect(l.generation == 1 and l.started_at == nil and l.qr_dialog == nil and l.login_cookies == nil,
        "offline worker startup ends the fallback session instead of leaving a dead QR dialog")
    expect(#l.client.requests == 0, "offline fallback sends no HTTP")
end

for _, failure_at in ipairs({ "flush", "account notification" }) do
    reset_ui()
    local l = new_login()
    l.settings.account = { user_vid = "old" }
    function l.settings:get(key, default) return self[key] or default end
    function l.settings:update_auth(credentials)
        self.account = credentials.account
        if failure_at == "flush" then error("storage flush failed") end
    end
    if failure_at == "account notification" then
        function l.host:onWeReadAccountChanged() error("account notification failed") end
    end
    -- Mirror the real common helper: errors from parent delivery return
    -- through on_failure after the settings account ID may have changed.
    function l.host:_runNetworkRequest(_text, _label, task, success, failure)
        local ok, value = pcall(task)
        if not ok then failure(value, false); return end
        local delivered, err = pcall(success, value)
        if not delivered then failure(err, false) end
    end
    l:_complete({ succeed = true, webLoginVid = "new", accessToken = "token" }, l.generation)
    expect(l.settings.account.user_vid == "new", failure_at .. " occurs after account mutation")
    expect(contains(l.host.infos[1], failure_at .. " failed"), failure_at .. " failure is never silently discarded")
    expect(l.host.refreshed == 0 and l.generation == 1, failure_at .. " failure ends the session without success UI")
end

-- Exercise the real common network boundary, with the production mock-endpoint
-- shortcut absent: link checks must never enter the synchronous DNS probe.
do
    for _, name in ipairs({ "ui/bidi", "ui/widget/confirmbox", "ui/widget/infomessage", "ui/widget/menu" }) do
        package.loaded[name] = {}
    end
    package.loaded["weread.lib.plugin_util"] = {
        tr = function(text) return text end, T = function(text) return text end,
        log_error = tostring, display_error = tostring, unpack_args = unpack,
    }
    local dns, links = 0, 0
    package.loaded["ui/network/manager"] = {
        isConnected = function() links = links + 1; return true end,
        isOnline = function() dns = dns + 1; error("UI DNS must not run") end,
    }
    local Common = require("weread.ui.common")
    for _, stage in ipairs({ "start", "otp", "complete", "poll" }) do
        reset_ui()
        local l = new_login()
        l.host.runOnlineTask = Common.runOnlineTask
        l.host.isNetworkOnline = Common.isNetworkOnline
        l.host.isNetworkConnected = Common.isNetworkConnected
        if stage == "start" then l:start()
        elseif stage == "complete" then
            l:_complete({ succeed = true, webLoginVid = "new", accessToken = "token" }, l.generation)
        elseif stage == "poll" then
            l.started_at = os.time()
            l:_poll("U", l.generation)
        else
            l:_show_otp("U", l.generation)
            local dialog = l.host.inputs[1]
            dialog.typed = "0000"
            dialog.buttons[1][2].callback()
        end
        expect(#l.client.requests == 0, stage .. " waits for scheduled worker startup")
        expect(run_scheduled(0.1) == 1, stage .. " starts after the UI paints")
        expect(dns == 0, stage .. " never invokes synchronous isOnline DNS")
    end
    expect(links >= 4, "all four QR request entries use the real link-state check")
end

print("qr_login_flow_spec: " .. checks .. " checks passed")
