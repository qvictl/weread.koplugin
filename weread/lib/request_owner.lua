-- In-memory ownership for work that can outlive its accepting UI callback.
-- WeRead cookies and the gateway API key may authenticate different accounts.
-- Rotating a ticket/session key for the same user does not change ownership.
local M = {}
function M.capture(settings)
    local account = settings:get("account", {})
    local cookies = settings:get("cookies", {})
    return {
        user_vid = type(account) == "table" and tostring(account.user_vid or "") or "",
        cookie_vid = type(cookies) == "table" and tostring(cookies.wr_vid or "") or "",
        api_key = tostring(settings:get("api_key", "") or ""),
        api = type(settings.is_api_configured) == "function" and settings:is_api_configured() == true,
        cookie = type(settings.is_cookie_configured) == "function" and settings:is_cookie_configured() == true,
    }
end
function M.matches(settings, owner)
    if type(owner) ~= "table" then return false end
    local current = M.capture(settings)
    for _, key in ipairs({ "user_vid", "cookie_vid", "api_key", "api", "cookie" }) do
        if current[key] ~= owner[key] then return false end
    end
    return true
end
return M
