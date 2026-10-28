-- Re-tapping the active shelf filter clears it (only within its dimension);
-- tapping another option of the same dimension replaces it.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local shown, ticks = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function() end,
        nextTick = function(_self, callback) ticks[#ticks + 1] = callback end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_self, options) return options end }
end
for _i, name in ipairs({ "ui/widget/confirmbox", "ui/widget/pathchooser", "weread.lib.scan" }) do
    package.preload[name] = function() return {} end
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end, T = function(text) return text end }
end

local Cache = require("weread.ui.cache")

local store = { shelf = {} }
local host = {
    settings = {
        get = function(_self, key) return store[key] end,
        set = function(_self, key, value) store[key] = value end,
        flush = function() end,
    },
    shelf_filters = {},
}
for key, value in pairs(Cache) do host[key] = value end

local changes = 0
host:showShelfFilterOptions(function() changes = changes + 1 end)
local dialog = shown[1]
local function tap(index)
    dialog.buttons[index][1].callback()
    while #ticks > 0 do table.remove(ticks, 1)() end
end
local filters = host.shelf_filters

tap(2) -- "Only show finished books"
tap(4) -- "Only show downloaded books"
expect(filters.reading == "finished" and filters.download == "downloaded", "filters were not selected")
tap(2)
expect(filters.reading == nil, "re-tapping the active filter did not clear it")
expect(store.shelf.filter_reading == nil, "cleared filter was still saved")
expect(filters.download == "downloaded", "clearing one dimension touched the other")
expect(dialog.buttons[1][1].checked_func() == false, "All checked while a filter is active")
tap(4)
expect(filters.download == nil and dialog.buttons[1][1].checked_func(), "All not checked after clearing every filter")
tap(3)
tap(2)
expect(filters.reading == "finished", "another option of the dimension did not replace the filter")
expect(changes == 6, "a filter tap did not refresh the shelf")

print(("shelf_filter_toggle_spec: %d checks"):format(checks))
