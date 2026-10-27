package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local repaints = 0
package.preload["ui/uimanager"] = function()
    return {
        widgetRepaint = function(_self, _widget, x, y)
            assert(x and y, "repaint needs a position")
            repaints = repaints + 1
        end,
        forceRePaint = function() end,
        setDirty = function() end,
    }
end

local TapFeedback = require("weread.ui.tap_feedback")

local called = 0
local function callback() called = called + 1 end

local unpainted = {}
expect(TapFeedback.run(unpainted, callback) == false, "unpainted row lets the tap propagate")
expect(called == 0, "unpainted row does not run its callback")
expect(repaints == 0, "unpainted row is not repainted")

local painted = { dimen = { x = 10, y = 20, w = 100, h = 30 } }
expect(TapFeedback.run(painted, callback) == true, "painted row consumes the tap")
expect(called == 1, "painted row runs its callback")
expect(repaints == 2, "painted row flashes")
expect(painted.invert == false, "highlight is undone")

print(string.format("tap_feedback_spec: %d checks", checks))
