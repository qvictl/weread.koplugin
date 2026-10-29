-- Temporarily remove the mock shortcut while exercising a real UI entry.
-- Restore both instance and inherited methods even if the entry throws.
return function(H, action)
    return H.call(function()
        local plugin = H.plugin()
        local settings = plugin.settings
        local NetworkMgr = require("ui/network/manager")
        local old_endpoint = rawget(settings, "mock_endpoint")
        local old_connected, old_online = rawget(NetworkMgr, "isConnected"), rawget(NetworkMgr, "isOnline")
        local probes = 0
        settings.mock_endpoint = false
        NetworkMgr.isConnected = function() return true end
        NetworkMgr.isOnline = function()
            probes = probes + 1
            error("synchronous UI DNS is forbidden in this scenario")
        end
        local ok, value = xpcall(function() return action(plugin) end, debug.traceback)
        settings.mock_endpoint = old_endpoint
        NetworkMgr.isConnected, NetworkMgr.isOnline = old_connected, old_online
        if not ok then error(value, 0) end
        H.equal(probes, 0, "UI gate must not resolve DNS before scheduling network work")
        return value
    end)
end
