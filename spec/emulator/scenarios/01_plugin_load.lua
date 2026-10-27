-- @title Plugin loads in the real KOReader app
-- @timeout 60
-- Real reader.lua start-up: PluginLoader discovers the candidate package in
-- KO_HOME/plugins, the FileManager instance gets a live plugin, the mock
-- environment is active and the WeRead entry is in the tools menu.
return function(H)
    H.step("plugin instance on FileManager", function()
        local plugin = H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        H.check(tostring(plugin.name):match("weread$"), "plugin instance name", tostring(plugin.name))
        H.check(type(plugin.version) == "string" and plugin.version:match("^%d+%.%d+%.%d+$"), "plugin version")
        H.metric("plugin_version", plugin.version)
    end)
    H.step("namespaced modules only", function()
        H.check(package.loaded["weread.lib.client"], "weread.lib.client loaded")
        H.check(package.loaded["weread.ui.menu"], "weread.ui.menu loaded")
        H.check(package.loaded["lib.client"] == nil and package.loaded["ui.menu"] == nil, "no legacy module keys")
    end)
    H.step("isolated mock environment", function()
        local settings = H.runtime().settings
        H.check(settings.mock_endpoint == H.env.mock, "mock endpoint active", tostring(settings.mock_endpoint))
        H.check(settings.data_dir:match("/weread%-mock$"), "isolated mock data dir", settings.data_dir)
    end)
    H.step("main menu entry", function()
        local plugin = H.plugin()
        local items = {}
        H.call(function() plugin:addToMainMenu(items) end)
        H.check(items.weread and items.weread.text, "tools menu entry registered")
        H.metric("menu_text", items.weread.text)
    end)
    H.shot("filemanager")
end
