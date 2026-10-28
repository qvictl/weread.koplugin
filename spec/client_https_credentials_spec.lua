package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local timeout_calls = {}
local reset_count = 0
local requests = {}
local responses = {}
local logs = {}

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(value)
                return function() return value end
            end,
        },
    }
end
package.preload["logger"] = function()
    local function capture(level, ...)
        local parts = { level }
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        logs[#logs + 1] = table.concat(parts, " ")
    end
    return {
        info = function(...) capture("info", ...) end,
        err = function(...) capture("error", ...) end,
        warn = function(...) capture("warn", ...) end,
    }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_self, block, total)
            timeout_calls[#timeout_calls + 1] = { block, total }
        end,
        reset_timeout = function()
            reset_count = reset_count + 1
        end,
        table_sink = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(options)
            requests[#requests + 1] = options
            local response = table.remove(responses, 1)
            if response.raise then error(response.raise) end
            if response.fail then return nil, response.fail end
            if options.sink then
                for _i, chunk in ipairs(response.chunks or { response.body or "" }) do
                    if response.before_chunk then response.before_chunk() end
                    local accepted, sink_err = options.sink(chunk)
                    if not accepted then return nil, sink_err end
                end
            end
            return 1, response.code, response.headers or {}, response.status
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        USER_AGENT = "WeRead client spec",
        SKILL_VERSION = "test-skill",
        urlencode = function(value)
            return tostring(value):gsub("([^%w%-_%.~])", function(ch)
                return string.format("%%%02X", ch:byte())
            end)
        end,
    }
end

-- Credentials never travel in clear text: stored cookies are attached only to
-- https WeRead URLs, explicit credential headers are stripped from non-https
-- requests, Set-Cookie from a plain-http response is not stored, and an
-- https -> http redirect is refused instead of followed.
local Client = require("weread.lib.client")
local merged = {}
local settings = {
    get = function(_self, key, default)
        if key == "cookies" then return { wr_skey = "secret-skey", wr_vid = "42" } end
        return default
    end,
    merge_set_cookie = function(_self, value) merged[#merged + 1] = value end,
}
local client = Client:new(settings)

local function reset()
    requests, responses, logs, merged = {}, {}, {}, {}
end

-- https WeRead URL: the stored cookie is attached and Set-Cookie is stored.
reset()
responses[1] = { code = 200, body = "ok", headers = { ["set-cookie"] = "wr_skey=new; Path=/" } }
client:request({ url = "https://weread.qq.com/web/a" })
expect(requests[1].headers.Cookie == "wr_skey=secret-skey; wr_vid=42", "https WeRead request lost its cookie")
expect(#merged == 1, "https Set-Cookie was not stored")

-- Plain http WeRead URL (any case): no cookie, no stored Set-Cookie.
for _, url in ipairs({ "http://weread.qq.com/web/a", "HTTP://I.WEREAD.QQ.COM/api", "http://weread.qq.com:80/x" }) do
    reset()
    responses[1] = { code = 200, body = "ok", headers = { ["set-cookie"] = "wr_skey=stolen; Path=/" } }
    client:request({ url = url })
    expect(requests[1].headers.Cookie == nil, "cookie sent in clear text to " .. url)
    expect(#merged == 0, "Set-Cookie over http was stored for " .. url)
end

-- Explicit credential headers (QR login passes Cookie / X-Skey itself) are
-- dropped for non-https URLs and kept for https ones.
reset()
responses[1] = { code = 200, body = "ok" }
client:request({ url = "http://weread.qq.com/api/userInfo", headers = {
    Cookie = "wr_skey=explicit", ["X-Skey"] = "token", authorization = "Bearer x", Accept = "text/plain",
} })
local sent = requests[1].headers
expect(sent.Cookie == nil and sent["X-Skey"] == nil and sent.authorization == nil,
    "explicit credential headers were sent over http")
expect(sent.Accept == "text/plain", "non-credential headers were dropped too")
expect(table.concat(logs, "\n"):find("credentials dropped", 1, true), "dropping credentials was not logged")
reset()
responses[1] = { code = 200, body = "ok" }
client:request({ url = "https://weread.qq.com/api/userInfo", headers = { ["X-Skey"] = "token" } })
expect(requests[1].headers["X-Skey"] == "token", "https request lost its explicit credential header")

-- https -> http redirect: refused, the http URL is never requested.
for _, location in ipairs({ "http://weread.qq.com/plain", "http://evil.example/steal" }) do
    reset()
    responses[1] = { code = 302, body = "", headers = { location = location } }
    local ok, err = pcall(client.request_follow, client, { url = "https://weread.qq.com/web/a" })
    expect(not ok and tostring(err):find("Refusing redirect from https", 1, true),
        "downgrade redirect to " .. location .. " was not refused")
    expect(not tostring(err):find("client.lua", 1, true), "refusal message carries a source position")
    expect(#requests == 1, "downgrade redirect target was requested: " .. location)
end

-- https -> https redirects (same host and cross-origin) are still followed.
reset()
responses[1] = { code = 301, body = "", headers = { location = "https://i.weread.qq.com/next" } }
responses[2] = { code = 200, body = "done" }
local text, code, _, _, final_url = client:request_follow({ url = "https://weread.qq.com/web/a" })
expect(text == "done" and code == 200 and final_url == "https://i.weread.qq.com/next", "https redirect not followed")
expect(requests[2].headers.Cookie == "wr_skey=secret-skey; wr_vid=42", "cookie not rebuilt for the https WeRead hop")

-- http -> http (public, non-WeRead) is not a downgrade and still works.
reset()
responses[1] = { code = 302, body = "", headers = { location = "/img2.png" } }
responses[2] = { code = 200, body = "png" }
text = client:request_follow({ url = "http://img.example/img1.png" })
expect(text == "png" and requests[2].url == "http://img.example/img2.png", "plain-http public redirect broke")

-- download_to_file refuses the downgrade too and leaves no partial file.
reset()
local path = os.tmpname()
os.remove(path)
responses[1] = { code = 302, body = "", headers = { location = "http://weread.qq.com/file" } }
local ok = pcall(client.download_to_file, client, "https://weread.qq.com/file", path)
expect(not ok and #requests == 1, "download followed a downgrade redirect")
expect(io.open(path, "rb") == nil and io.open(path .. ".part", "rb") == nil, "downgraded download left a file")

print(string.format("client_https_credentials_spec: %d checks", checks))
