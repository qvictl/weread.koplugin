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

-- Unsupported runtimes fail through cleanup without executing the task.
local ran_without_worker, unavailable_failures = false, 0
host:_runNetworkRequest("Loading", "Load", function() ran_without_worker = true end,
    function() error("unsupported worker delivered a result") end,
    function(err, cancelled)
        unavailable_failures = unavailable_failures + 1
        eq(cancelled, false, "unavailable worker is a failure, not a dismissal")
        eq(err, "Network subprocess is unavailable.", "unavailable worker explained")
    end)
eq(ran_without_worker, false, "unavailable worker never executes network on UI")
eq(unavailable_failures, 1, "unavailable worker cleans up exactly once")

-- Shared short requests execute only the task in the worker and deliver UI
-- results/credential updates in the parent, including cancellation cleanup.
local in_child, encoded, mode, merged = false, nil, "success", 0
local account = { user_vid = "original" }
host.settings = { get = function(_self, key) if key == "account" then return account end end }
package.loaded["ffi/util"] = { runInSubProcess = function() end }
package.loaded["json"] = {
    encode = function(value) encoded = value return "reply" end,
    decode = function(value)
        if value ~= "reply" then error("invalid JSON") end
        return encoded
    end,
}
package.loaded["weread.lib.worker_settings"] = {
    fingerprint = function() return "original-auth" end,
    capture = function()
        eq(in_child, true, "auth captured in worker")
        return function() return { cookies = "renewed" } end
    end,
    merge = function(_settings, fingerprint, auth)
        eq(in_child, false, "auth merged in parent")
        eq(fingerprint, "original-auth", "auth fingerprint preserved")
        eq(auth.cookies, "renewed", "worker auth returned")
        if mode == "auth_error" then error("auth save failed") end
        if mode == "ticket_rotated" then return false end
        merged = merged + 1
    end,
}
package.loaded["ui/trapper"] = {
    wrap = function(_self, task) task() end,
    dismissableRunInSubprocess = function(_self, task)
        if mode == "cancel" then return false end
        if mode == "fork_error" then return false, "fork failed" end
        if mode == "invalid" then return true, "garbage" end
        in_child = true
        local value = task()
        in_child = false
        if mode == "account_changed" then account.user_vid = "replacement" end
        return true, value
    end,
}
for _, current in ipairs({ "success", "task_error", "cancel", "fork_error", "invalid", "auth_error", "ui_error",
    "ticket_rotated", "account_changed" }) do
    mode, account.user_vid = current, "original"
    local results, failures, cancelled, reason = 0, 0, false, nil
    host:_runNetworkRequest("Loading", "Load", function()
        eq(in_child, true, "network task runs in worker")
        if mode == "task_error" then error("HTTP 503") end
        return { books = 3 }
    end, function(result)
        eq(in_child, false, "UI callback runs in parent")
        eq(result.books, 3, "task result delivered")
        if mode == "ui_error" then error("UI update failed") end
        results = results + 1
    end, function(_err, was_cancelled, why)
        eq(in_child, false, "failure cleanup runs in parent")
        failures, cancelled, reason = failures + 1, was_cancelled, why
    end)
    local succeeds = current == "success" or current == "ticket_rotated"
    eq(results, succeeds and 1 or 0, current .. " success delivery")
    eq(failures, succeeds and 0 or 1, current .. " failure cleanup exactly once")
    eq(cancelled, current == "cancel" or current == "account_changed", current .. " cancellation distinguished")
    eq(reason, current == "account_changed" and "account_changed" or nil, current .. " discard reason")
end
eq(merged, 3, "successful worker credentials merged before task/UI error delivery")

print(string.format("common_network_spec: %d checks", checks))
