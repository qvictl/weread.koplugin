local M = {}

local function auth_fingerprint(settings)
    if not settings or type(settings.get) ~= "function" then return "" end
    local cookies = settings:get("cookies", {}) or {}
    local keys = {}
    for key in pairs(cookies) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(cookies[key])
    end
    parts[#parts + 1] = "ticket=" .. tostring(settings:get("wr_ticket", ""))
    parts[#parts + 1] = "wrpa=" .. tostring(settings:get("wr_wrpa", ""))
    return table.concat(parts, ";")
end

-- Suppresses flushes and records credential changes while a worker task runs.
--
-- Client and Content hold a reference to the settings object itself, so a
-- separate proxy would not see their calls; the overrides are therefore
-- installed on the object, but only for the duration of the task. The
-- returned collector removes them again. That matters when Trapper cannot
-- fork and runs the task in-process ("falling back to blocking in-process
-- run"): without the restore the parent's settings would never flush again.
-- The second return value restores without collecting (for error paths).
function M.capture(settings)
    local changed = false
    local saved = {}
    for _, key in ipairs({ "flush", "update_auth" }) do
        saved[key] = { present = rawget(settings, key) ~= nil, value = rawget(settings, key) }
    end
    local function no_flush() end
    settings.flush = no_flush
    local update_auth = settings.update_auth
    local wrapped_update_auth
    if type(update_auth) == "function" then
        wrapped_update_auth = function(object, credentials, options)
            changed = true
            local copy = {}
            for key, value in pairs(options or {}) do copy[key] = value end
            copy.flush = false
            return update_auth(object, credentials, copy)
        end
        settings.update_auth = wrapped_update_auth
    end
    local restored = false
    local function restore()
        if restored then return end
        restored = true
        -- Only undo our own overrides; leave anything installed later alone.
        if rawget(settings, "flush") == no_flush then
            rawset(settings, "flush", saved.flush.present and saved.flush.value or nil)
        end
        if wrapped_update_auth and rawget(settings, "update_auth") == wrapped_update_auth then
            rawset(settings, "update_auth",
                saved.update_auth.present and saved.update_auth.value or nil)
        end
    end
    return function()
        restore()
        if not changed or type(settings.get) ~= "function" then return nil end
        return {
            cookies = settings:get("cookies", {}),
            wr_ticket = settings:get("wr_ticket", ""),
            wr_wrpa = settings:get("wr_wrpa", ""),
        }
    end, restore
end

function M.fingerprint(settings)
    return auth_fingerprint(settings)
end

function M.merge(settings, expected_fingerprint, auth)
    if type(auth) ~= "table" then return false end
    if not settings or type(settings.update_auth) ~= "function" then return false end
    if auth_fingerprint(settings) ~= expected_fingerprint then return false end
    settings:update_auth(auth, { replace_cookies = true })
    return true
end

return M
