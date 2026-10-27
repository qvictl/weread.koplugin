-- WorkerSettings.capture must only suppress flushes while a task runs: when
-- Trapper falls back to an in-process run, the parent's settings object has
-- to flush normally again once the result has been collected.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local WorkerSettings = require("weread.lib.worker_settings")

local Store = {}
Store.__index = Store
function Store:get(key, default)
    local value = self.values[key]
    if value == nil then return default end
    return value
end
function Store:set(key, value) self.values[key] = value end
function Store:flush() self.flushes = self.flushes + 1 end
function Store:update_auth(credentials, options)
    for key, value in pairs(credentials) do self:set(key, value) end
    if not options or options.flush ~= false then self:flush() end
    return true
end

local settings = setmetatable({ values = { wr_ticket = "old" }, flushes = 0 }, Store)
local caller_options = { replace_cookies = true }

local collect = WorkerSettings.capture(settings)
settings:update_auth({ wr_ticket = "renewed" }, caller_options)
settings:flush()
expect(settings.flushes == 0, "flushes must be suppressed while captured")
expect(caller_options.flush == nil, "caller options must not be mutated")
local auth = collect()
expect(auth and auth.wr_ticket == "renewed", "renewed credentials were not collected")
expect(rawget(settings, "flush") == nil and rawget(settings, "update_auth") == nil,
    "capture left instance overrides behind")
settings:flush()
settings:update_auth({ wr_ticket = "later" })
expect(settings.flushes == 2, "settings did not flush normally after collection")

-- Unchanged tasks collect nothing; restore-only also undoes the overrides.
local collect_unchanged, restore = WorkerSettings.capture(settings)
restore()
expect(rawget(settings, "flush") == nil, "restore did not remove the flush override")
expect(collect_unchanged() == nil, "an unchanged task must not return credentials")

-- Instance-level methods present before capture are put back as they were.
local own_flush = function() end
local plain = { flush = own_flush, get = function() return nil end }
local collect_plain = WorkerSettings.capture(plain)
expect(plain.flush ~= own_flush, "flush was not overridden")
collect_plain()
expect(plain.flush == own_flush and plain.update_auth == nil,
    "pre-existing instance fields were not restored")

print(("worker_settings_spec: %d checks"):format(checks))
