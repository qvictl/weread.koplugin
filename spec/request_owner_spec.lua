package.path = "./?.lua;" .. package.path
local Owner = require("weread.lib.request_owner")
local values = { account = { user_vid = "one" }, cookies = { wr_vid = "one", wr_skey = "old" },
    api_key = "synthetic-gateway-one", wr_ticket = "old-ticket" }
local api, cookie = true, true
local settings = {
    get = function(_, key, default) return values[key] or default end,
    is_api_configured = function() return api end,
    is_cookie_configured = function() return cookie end,
}
local checks = 0
local function expect(value)
    checks = checks + 1; assert(value, "request owner check " .. checks)
end
local owner = Owner.capture(settings)
expect(Owner.matches(settings, owner))
values.cookies.wr_skey, values.wr_ticket = "renewed", "rotated"
expect(Owner.matches(settings, owner))
for _, change in ipairs({ "uid", "cookie", "api_key", "api_source", "cookie_source" }) do
    if change == "uid" then values.account.user_vid = "two"
    elseif change == "cookie" then values.cookies.wr_vid = "two"
    elseif change == "api_key" then values.api_key = "synthetic-gateway-two"
    elseif change == "api_source" then api = false
    else cookie = false end
    expect(not Owner.matches(settings, owner))
    values.account.user_vid, values.cookies.wr_vid = "one", "one"
    values.api_key, api, cookie = "synthetic-gateway-one", true, true
end
values.account, cookie = {}, false
owner = Owner.capture(settings)
values.api_key = "synthetic-gateway-two"
expect(not Owner.matches(settings, owner))
expect(not Owner.matches(settings, nil))
print(("request_owner_spec: %d checks"):format(checks))
