-- Focused tests for optional SimpleUI/ZenUI launch integration.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

_G.__ZEN_UI_REGISTER_HOME_ITEM = nil
local ZenUI = require("integrations.zenui")
ZenUI.registered = false

local opened = 0
local plugin = {
    openBookshelf = function() opened = opened + 1 end,
}
expect(ZenUI:register(plugin) == false,
    "ZenUI integration should remain optional when ZenUI is absent")

local registered_id, registered_builder, registered_options
_G.__ZEN_UI_REGISTER_HOME_ITEM = function(id, builder, options)
    registered_id = id
    registered_builder = builder
    registered_options = options
    return true
end

expect(ZenUI:onZenUIReady(plugin) == true,
    "ZenUIReady did not register the WeRead Home widget")
expect(registered_id == "weread.bookshelf"
    and type(registered_builder) == "function",
    "ZenUI registration used the wrong item descriptor")
expect(registered_options.label == "WeRead",
    "ZenUI registration used the wrong label")
expect(ZenUI:_openBookshelf() == true and opened == 1,
    "ZenUI entry did not call the stable bookshelf method")

-- The Home widget ignores taps until it was painted at its real position,
-- and opens the bookshelf after the gesture handler returned, once.
do
    local ticks = {}
    package.preload["ui/uimanager"] = function()
        return { nextTick = function(_self, callback) ticks[#ticks + 1] = callback end }
    end
    package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0 } end
    package.preload["device"] = function()
        return { screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
        } }
    end
    package.preload["ui/font"] = function() return { getFace = function() return {} end } end
    package.preload["ui/geometry"] = function()
        return { new = function(_self, values)
            values.x, values.y = values.x or 0, values.y or 0
            function values:contains(pos)
                return pos.x >= self.x and pos.y >= self.y
                    and pos.x < self.x + self.w and pos.y < self.y + self.h
            end
            return values
        end }
    end
    package.preload["ui/gesturerange"] = function()
        return { new = function(_self, values) return values end }
    end
    local function simple_widget()
        return { new = function(_self, values)
            values = values or {}
            values.getSize = function() return { w = 50, h = 20 } end
            return values
        end }
    end
    for _i, name in ipairs({
        "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
        "ui/widget/iconwidget", "ui/widget/textwidget", "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
    }) do
        package.preload[name] = simple_widget
    end
    package.preload["ui/widget/container/inputcontainer"] = function()
        return { new = function(_self, values)
            function values:paintTo(_bb, x, y) self.dimen.x, self.dimen.y = x, y end
            return values
        end }
    end

    opened = 0
    local widget = ZenUI:_buildWidget({ width = 200, height = 100 })
    local corner_tap = { pos = { x = 10, y = 10 } }
    expect(widget:onTapWeRead(nil, corner_tap) == false and #ticks == 0,
        "unpainted Home widget caught a tap at its placeholder position")
    widget:paintTo(nil, 300, 500)
    expect(widget:onTapWeRead(nil, corner_tap) == false,
        "painted Home widget caught a tap outside its area")
    local inside = { pos = { x = 350, y = 550 } }
    expect(widget:onTapWeRead(nil, inside) == true and opened == 0 and #ticks == 1,
        "Home widget opened the bookshelf inside the gesture handler")
    widget:onTapWeRead(nil, inside)
    expect(#ticks == 1, "repeated taps scheduled the bookshelf twice")
    ticks[1]()
    expect(opened == 1, "deferred bookshelf did not open")
end

_G.__ZEN_UI_REGISTER_HOME_ITEM = nil
print(("ui_integrations_spec: %d checks"):format(checks))
