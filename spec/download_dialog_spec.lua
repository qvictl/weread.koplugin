-- The progress dialog is retitled on every sync step; it must not force a
-- repaint and an e-ink refresh for each one, but must still show the latest
-- title. Run from the repo root with:
--   luajit spec/download_dialog_spec.lua

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed"), 2) end
end

local function class()
    local proto = {}
    proto.__index = proto
    function proto:extend(child)
        child = child or {}
        child.__index = child
        return setmetatable(child, { __index = self })
    end
    function proto:new(o)
        o = setmetatable(o or {}, self)
        if o.init then o:init() end
        return o
    end
    function proto:getSize() return { w = 10, h = 10 } end
    function proto:setText(text) self.text = text end
    return proto
end
for _i, name in ipairs({ "ui/widget/buttontable", "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer", "ui/geometry", "ui/widget/progresswidget",
    "ui/widget/textwidget", "ui/widget/textboxwidget", "ui/widget/verticalgroup",
    "ui/widget/verticalspan" }) do
    package.preload[name] = function() return class() end
end
package.preload["ui/widget/container/inputcontainer"] = function() return class() end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0, COLOR_BLACK = 1 } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/size"] = function()
    return { padding = { small = 1, large = 2 }, margin = { tiny = 1 },
        radius = { window = 1 }, border = { window = 1 } }
end
package.preload["device"] = function()
    return { screen = {
        getSize = function() return { w = 600, h = 800 } end,
        getWidth = function() return 600 end,
        scaleBySize = function(_, value) return value end,
    } }
end
local now = 0
package.preload["ui/time"] = function()
    return {
        now = function() return now end,
        s = function(seconds) return seconds * 1000000 end,
        to_s = function(value) return value / 1000000 end,
    }
end
local dirty, repaints, scheduled = 0, 0, {}
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() dirty = dirty + 1 end,
        forceRePaint = function() repaints = repaints + 1 end,
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
        show = function() end, close = function() end,
    }
end

local DownloadDialog = require("weread.ui.download_dialog")
local dialog = DownloadDialog:new{ title = "start", progress_max = 10 }

dialog:setTitle("step 1")
expect(repaints == 1 and dirty == 1, "the first title change was not shown immediately")
for index = 2, 40 do
    now = now + 20000 -- 20 ms per step
    dialog:setTitle("step " .. index)
end
expect(repaints == 1 and dirty == 1, "every step forced a repaint")
expect(#scheduled == 1 and scheduled[1].delay > 0 and scheduled[1].delay <= 1,
    "the latest title was not scheduled for a trailing repaint")
expect(dialog.title_widget.text == "step 40", "the title text fell behind")
now = now + 1000000
scheduled[1].callback()
expect(dirty == 2 and repaints == 1, "the trailing repaint did not mark the dialog dirty")
dialog:setTitle("step 40")
expect(dirty == 2, "an unchanged title caused a repaint")
now = now + 1000000
dialog:setTitle("later")
expect(repaints == 2, "a title change after the interval was not shown at once")

-- A trailing repaint for a closed dialog is dropped.
now = now + 1000
dialog:setTitle("closing")
dialog:onCloseWidget()
local before = dirty
scheduled[#scheduled].callback()
expect(dirty == before, "a closed dialog was marked dirty")

print(("download_dialog_spec: %d checks"):format(checks))
