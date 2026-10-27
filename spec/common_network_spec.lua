-- Unit tests for shared network task behavior.

package.path = "./?.lua;" .. package.path

local checks = 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        error(string.format("%s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
local dns_lookups = 0
local link_up = false
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function()
            dns_lookups = dns_lookups + 1
            return false
        end,
        isConnected = function() return link_up end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        unpack_args = function(args) return unpack(args) end,
    }
end

local Common = require("weread.ui.common")
local offline_notices = 0
local host = setmetatable({
    showOffline = function()
        offline_notices = offline_notices + 1
    end,
}, { __index = Common })

eq(host:runOnlineTask("automatic", function() end, nil, {
    silent_offline = true,
}), false, "silent offline task does not start")
eq(offline_notices, 0, "silent offline task does not show a notice")

eq(host:runOnlineTask("manual", function() end), false,
    "regular offline task does not start")
eq(offline_notices, 1, "regular offline task still shows a notice")

dns_lookups = 0
local ran = false
link_up = true
eq(host:runOnlineTask("lifecycle", function() ran = true end, nil, {
    silent_offline = true, link_only = true,
}), true, "link-only task starts when the link is up")
eq(ran, true, "link-only task runs")
eq(dns_lookups, 0, "link-only task never resolves DNS")
link_up = false
eq(host:runOnlineTask("lifecycle", function() end, nil, {
    silent_offline = true, link_only = true,
}), false, "link-only task skips quietly when the link is down")
eq(dns_lookups, 0, "still no DNS lookup")

print(string.format("common_network_spec: %d checks", checks))
