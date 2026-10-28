-- @title Credentials never go over plain http (redirect downgrade refused)
-- @timeout 60
-- The mock answers an https WeRead request with a 302 to the same URL over
-- plain http (as a captive portal or a hostile network could). The plugin
-- must refuse to follow it: no request reaches an http:// WeRead URL, so
-- no cookie or credential header can travel in clear text (unit specs cover
-- the header decisions themselves; the mock never receives credentials).
local BOOK_ID = "900001"

return function(H)
    local function client() return H.runtime().client end

    local function events_since(mark)
        local all = H.mock_requests()
        local out = {}
        for i = mark + 1, #all do out[#out + 1] = all[i] end
        return out, #all
    end

    H.step("plugin ready", function()
        H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        H.check(H.call(function() return H.plugin().settings:is_cookie_configured() end),
            "mock account has a login cookie")
    end)

    H.step("https -> http redirect is refused", function()
        local _, mark = events_since(0)
        H.mock_control({ downgrade_path = "/web/book/getProgress" })
        local ok, err = H.call(function()
            -- get_binary follows redirects (as asset and cover downloads do).
            return pcall(client().get_binary, client(),
                "https://weread.qq.com/web/book/getProgress?bookId=" .. BOOK_ID)
        end)
        H.mock_control({ downgrade_path = "" })
        H.check(not ok, "request failed instead of following the downgrade")
        H.check(tostring(err):find("Refusing redirect from https", 1, true), "refusal reason", tostring(err))
        local events = events_since(mark)
        local https_hits, http_hits = 0, 0
        for _i, event in ipairs(events) do
            if event.path == "/web/book/getProgress" then
                if event.scheme == "https" then https_hits = https_hits + 1 end
                if event.scheme == "http" then http_hits = http_hits + 1 end
            end
            H.check(event.cookie ~= true, "no Cookie header reached the service", event.path)
        end
        H.equal(https_hits, 1, "one https request answered with the redirect")
        H.equal(http_hits, 0, "no request over plain http")
    end)
end
