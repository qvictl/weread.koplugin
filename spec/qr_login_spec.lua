package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end,
        getHeight = function() return 800 end } }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return { warn = function() end, err = function() end,
                dbg = function() end, info = function() end }
        end,
    }
end
package.preload["ui/widget/qrmessage"] = function() return {} end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end
package.preload["ui/uimanager"] = function()
    return { close = function() end, scheduleIn = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        urlencode = function(value)
            return tostring(value):gsub(" ", "%%20")
        end,
    }
end

local requests = {}
local client = {
    request = function(_self, options)
        requests[#requests + 1] = options
        return "{}", 200, {}
    end,
    decode_http_json = function()
        return { logicCode = "PENDING" }
    end,
}

local QRLogin = require("weread.lib.qr_login")
local login = QRLogin:new({}, client, {})

login:_poll_protocol("uid value", "")
expect(requests[1].url ==
    "https://weread.qq.com/api/auth/getLoginInfo?uid=uid%20value&otp=",
    "empty OTP was not serialized with an explicit value")

login:_poll_protocol("uid value", "1234")
expect(requests[2].url ==
    "https://weread.qq.com/api/auth/getLoginInfo?uid=uid%20value&otp=1234",
    "non-empty OTP was serialized incorrectly")

local function run_login(fingerprint)
    local protocol_requests, saved = {}, nil
    local responses = {
        { "html", { ["set-cookie"] = "wr_preflight=test-preflight; Path=/" } },
        { { uid = "test-uid" } },
        { { succeed = true, webLoginVid = "test-user", accessToken = "test-access", refreshToken = "test-refresh" } },
        { { name = "Test user" } },
        { { apikey = "test-api-key" } },
    }
    local protocol_client = {
        request = function(_self, opts)
            protocol_requests[#protocol_requests + 1] = opts
            local response = table.remove(responses, 1)
            return response[1], 200, response[2] or {}
        end,
        decode_http_json = function(_self, body) return body end,
    }
    protocol_client.request_follow = protocol_client.request
    local settings = {
        get_device_fingerprint = function() return fingerprint end,
        update_auth = function(_self, credentials, options)
            expect(options.replace_cookies, "login should replace account cookies")
            saved = credentials
        end,
    }
    local protocol_login = QRLogin:new({}, protocol_client, settings)
    local uid = protocol_login:_begin_protocol()
    local result = protocol_login:_poll_protocol(uid)
    protocol_login:_complete_protocol(result, protocol_login.generation)
    local expected_urls = {
        "https://weread.qq.com/r/weread-skills",
        "https://weread.qq.com/api/auth/getLoginUid",
        "https://weread.qq.com/api/auth/getLoginInfo?uid=test-uid&otp=",
        "https://weread.qq.com/api/userInfo?userVid=test-user",
        "https://weread.qq.com/api/skills/apikeyGet?only_show=1",
    }
    expect(#protocol_requests == #expected_urls, "fingerprint must not introduce a new login chain")
    for i, request in ipairs(protocol_requests) do
        expect(request.url == expected_urls[i], "classic login endpoint changed")
        expect(request.skip_cookie, "login must not inherit old account credentials")
        expect(request.headers.Cookie:find("wr_fp=" .. fingerprint, 1, true),
            "fingerprint missing from login request " .. i)
        expect(not request.headers.Cookie:find("wr_gid=", 1, true),
            "fingerprint-only experiment must not add a guest ID")
    end
    expect(protocol_requests[2].headers.Cookie:find("wr_preflight=test-preflight", 1, true),
        "fingerprint must not discard server cookies")
    expect(saved.cookies.wr_fp == fingerprint and saved.cookies.wr_skey == "test-access",
        "completed login must persist both the fingerprint and new credentials")
    expect(saved.api_key == "test-api-key" and protocol_login.login_cookies == nil,
        "login completion state changed")
    return protocol_requests[2].headers.Cookie
end

expect(run_login("1234567890") ~= run_login("2345678901"),
    "separate device fingerprints must reach the server independently")

-- F11: the long poll runs in a background process; the UI loop only
-- checks its pipe.
do
    local scheduled = {}
    local scheduler = {
        scheduleIn = function(_self, _delay, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function() end,
    }
    local runner = { forks = 0 }
    function runner.run(child) runner.forks = runner.forks + 1; runner.child = child; return 42, 7 end
    function runner.write_all(_fd, data) runner.written = data end
    function runner.is_done() return runner.done == true end
    function runner.read_size() return runner.written and #runner.written or 0 end
    function runner.read_all() local d = runner.written; runner.written = nil; return d end
    function runner.terminate() runner.terminated = true end

    local stash = {}
    local poll_count = 0
    local poll_client = {
        request = function(_self, opts)
            poll_count = poll_count + 1
            if poll_count < 3 then return nil, nil, nil, "timeout" end
            return "body", 200, { ["set-cookie"] = "wr_poll=1; Path=/" }
        end,
        decode_http_json = function() return { succeed = true, webLoginVid = "v" } end,
        json_encode = function(_self, value) stash[#stash + 1] = value; return "#" .. #stash end,
        json_decode = function(_self, text) return stash[tonumber(text:sub(2))] end,
    }
    local host_calls = {}
    local host = {
        showInfo = function(_self, text) host_calls[#host_calls + 1] = text end,
    }
    local login = QRLogin:new(host, poll_client, {}, {
        subprocess = runner, scheduler = scheduler,
    })
    local completed
    login._complete = function(_self, result) completed = result end
    login.qr_dialog = {}
    login.started_at = os.time()
    expect(login:_start_poll_job("uid", login.generation), "poll job starts")
    expect(poll_count == 0, "no request on the UI loop")
    runner.child(42, 7)
    expect(poll_count == 3, "child keeps polling through timeouts")
    runner.done = true
    for _i, fn in ipairs(scheduled) do fn() end
    expect(completed and completed.webLoginVid == "v", "parent completes the login")
    expect(login.login_cookies and login.login_cookies.wr_poll == "1",
        "cookies merged in the child reach the parent")

    -- Suspend ends a running session and kills its process.
    runner.terminated = false
    runner.done = false
    login.qr_dialog = nil
    login.started_at = os.time()
    expect(login:_start_poll_job("uid", login.generation), "second poll job starts")
    local generation = login.generation
    expect(login:on_suspend() == true, "suspend cancels an active session")
    expect(runner.terminated == true, "poll process killed")
    expect(login.generation ~= generation and login.poll_job == nil, "session invalidated")
    expect(login:on_suspend() == false, "nothing to cancel when idle")
end

-- A connection dropped while completing the login (userInfo/apikeyGet) is
-- retried like a transient 401 and never surfaces as a Lua runtime error.
do
    package.loaded["socket"] = { sleep = function() end }
    local saved
    local attempts = {}
    local responses = {
        userInfo = { false, { name = "Reader" } },
        apikeyGet = { false, { apikey = "flaky-key" } },
    }
    local function decode(_self, body) return body end
    local flaky_client = {
        request = function(_self, opts)
            local stage = opts.url:find("userInfo", 1, true) and "userInfo" or "apikeyGet"
            attempts[stage] = (attempts[stage] or 0) + 1
            local response = table.remove(responses[stage], 1)
            if response == false then return nil, nil, nil, "closed" end
            return response, 200, {}
        end,
        decode_http_json = decode,
    }
    local settings = { update_auth = function(_self, credentials) saved = credentials end }
    local login_result = { succeed = true, webLoginVid = "vid", accessToken = "token" }
    local flaky = QRLogin:new({}, flaky_client, settings)
    local ok, account = pcall(flaky._complete_protocol, flaky, login_result, flaky.generation)
    expect(ok and account.name == "Reader" and saved and saved.api_key == "flaky-key",
        "a dropped connection while completing the login must be retried: " .. tostring(account))
    expect(attempts.userInfo == 2 and attempts.apikeyGet == 2, "each dropped request retried once")

    saved = nil
    local dead_client = {
        request = function() return nil, nil, nil, "closed" end,
        decode_http_json = decode,
    }
    local dead = QRLogin:new({}, dead_client, settings)
    local dead_ok, err = pcall(dead._complete_protocol, dead, login_result, dead.generation)
    expect(not dead_ok and tostring(err):find("userInfo", 1, true)
        and tostring(err):find("closed", 1, true)
        and not tostring(err):find("attempt to index", 1, true),
        "a persistent transport failure must be reported as a network error: " .. tostring(err))
    expect(saved == nil, "no credentials saved after a transport failure")
end

print("qr_login_spec: " .. checks .. " checks passed")
