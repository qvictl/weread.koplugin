-- In-memory ownership for work that can outlive its accepting UI callback.
-- WeRead cookies and the gateway API key may authenticate different accounts.
-- Rotating a ticket/session key for the same user does not change ownership.
local M = {}
local function scalar(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    return ""
end
function M.capture(settings)
    settings = settings or {}
    local function get(key, default)
        if type(settings.get) == "function" then return settings:get(key, default) end
        return default
    end
    local account = get("account", {})
    local cookies = get("cookies", {})
    return {
        user_vid = type(account) == "table" and scalar(account.user_vid) or "",
        cookie_vid = type(cookies) == "table" and scalar(cookies.wr_vid) or "",
        api_key = scalar(get("api_key", "")),
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
-- Only this non-reversible, deterministic digest may accompany persisted
-- pending positions; raw credential fields stay in memory.
function M.digest(owner)
    if type(owner) ~= "table" then return nil end
    local parts = {}
    for _, key in ipairs({ "user_vid", "cookie_vid", "api_key", "api", "cookie" }) do
        local value = tostring(owner[key])
        parts[#parts + 1] = tostring(#value) .. ":" .. value
    end
    return require("weread.lib.crypto").sha256_hex(table.concat(parts))
end
return M
