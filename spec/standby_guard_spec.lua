package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local platform = "kindle"
local commands = {}
local share = {}
local standby = 0

package.preload["device"] = function()
    return {
        isKindle = function() return platform == "kindle" end,
        isCervantes = function() return false end,
        isKobo = function() return platform == "kobo" end,
    }
end
package.preload["pluginshare"] = function() return share end
package.preload["ui/uimanager"] = function()
    return {
        preventStandby = function() standby = standby + 1 end,
        allowStandby = function() standby = standby - 1 end,
    }
end
os.execute = function(command) -- luacheck: ignore 122
    commands[#commands + 1] = command
    return 0
end

local Guard = require("weread.lib.standby_guard")

-- Kindle: AutoSuspend must be paused, and its t1 resets disabled while the
-- powerd screensaver is prevented.
local first = Guard.acquire()
expect(share.pause_auto_suspend == true, "kindle pauses AutoSuspend")
expect(share.keepalive == true, "kindle marks keepalive for AutoSuspend")
expect(commands[#commands]:find("preventScreenSaver 1", 1, true), "kindle prevents powerd screensaver")
local second = Guard.acquire()
expect(#commands == 1, "nested acquire does not repeat platform calls")
Guard.release(first)
expect(share.pause_auto_suspend == true, "still paused while a job holds the guard")
Guard.release(second)
expect(share.pause_auto_suspend == false, "AutoSuspend resumes after the last release")
expect(share.keepalive == false, "keepalive cleared after the last release")
expect(commands[#commands]:find("preventScreenSaver 0", 1, true), "powerd screensaver allowed again")
expect(standby == 0, "UIManager standby counter is balanced")

-- A KeepAlive the user enabled must survive our release.
share.keepalive = true
share.pause_auto_suspend = false
local token = Guard.acquire()
Guard.release(token)
expect(share.keepalive == true, "user keepalive is preserved")
expect(share.pause_auto_suspend == false, "previous pause state is restored")

-- Other platforms still pause AutoSuspend, without touching powerd.
platform = "kobo"
share.keepalive = nil
commands = {}
token = Guard.acquire()
expect(share.pause_auto_suspend == true, "kobo pauses AutoSuspend")
expect(share.keepalive == nil, "keepalive is only used on kindle")
Guard.release(token)
expect(share.pause_auto_suspend == false, "kobo resumes AutoSuspend")
expect(#commands == 0, "no lipc calls off kindle")

print(string.format("standby_guard_spec: %d checks", checks))
