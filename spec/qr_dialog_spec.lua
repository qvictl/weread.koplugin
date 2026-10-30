package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(ok, message)
    checks = checks + 1
    if not ok then error(message) end
end

local width, height, modules = 600, 800, 29
local touch, keys, encode_failure = true, true, false
local requests, freed, dirty, closed = 0, 0, 0, 0
local dirty_widget, dirty_mode
local function widget(_self, options) return options end
local Input = {}
function Input:extend(options)
    self.__index = self
    return setmetatable(options, self)
end
function Input:new(options)
    options = self:extend(options)
    options.ges_events, options.key_events = {}, {}
    options:init()
    return options
end
package.preload["ui/widget/container/inputcontainer"] = function() return Input end
package.preload["device"] = function()
    return {
        screen = { getSize = function() return { w = width, h = height } end },
        isTouchDevice = function() return touch end, hasKeys = function() return keys end,
        input = { group = { Back = "Back" } },
    }
end
for _, name in ipairs({ "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
    "ui/geometry", "ui/gesturerange", "ui/widget/textwidget" }) do
    package.preload[name] = function() return { new = widget } end
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white" } end
package.preload["ui/font"] = function() return { getFace = function() return "font" end } end
package.preload["ui/size"] = function()
    return { border = { window = 2 }, padding = { large = 10 } }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_self, target, mode)
            dirty = dirty + 1; dirty_widget, dirty_mode = target, mode
        end,
        close = function(_self, dialog) closed = closed + 1; dialog:onCloseWidget() end,
    }
end
package.preload["ui/widget/qrwidget"] = function()
    return { MAX_BYTES = 2953, new = function(_self, options)
        requests = requests + 1
        expect(options.scale_factor == 1, "QR grid must not be resampled")
        local pixels = math.floor(math.min(options.width, options.height) / modules) * modules
        options.image = not encode_failure and pixels > 0 and {
            getWidth = function() return pixels end, getHeight = function() return pixels end,
        } or nil
        options.free = function() freed = freed + 1 end
        return options
    end }
end

local QRDialog = require("weread.ui.qr_dialog")
for _, viewport in ipairs({ { 600, 800 }, { 800, 600 }, { 320, 240 }, { 240, 320 } }) do
    width, height = viewport[1], viewport[2]
    for _, count in ipairs({ 21, 29, 177 }) do
        modules = count
        local dialog = QRDialog:new{ text = "synthetic login payload" }
        local frame = dialog[1][1]
        expect(frame.background == "white", "QR margin must have an opaque white background")
        if dialog.qr.image then
            local pixels = dialog.qr.image:getWidth()
            local module_pixels = pixels / modules
            expect(frame.padding >= 4 * module_pixels, "each quiet margin needs at least four modules")
            expect(pixels + 2 * frame.padding + 2 * frame.bordersize <= math.min(width, height),
                "QR and its ceil-rounded quiet zone must fit the shorter viewport side")
            expect(dialog.qr.width == nil and dialog.qr.height == nil,
                "paint area follows the native QR bitmap")
        else
            expect(frame[1].text == "Could not generate a QR code", "unrenderable dense code has a fallback")
        end
        expect(dialog.ges_events.TapClose[1].range.w == width, "tap dismissal covers the viewport")
        expect(dialog.key_events.Close[1][1] == "Back", "Back key dismisses the dialog")
        expect(dialog.key_events.FullRefresh[1][1][2] == "F5", "F5 refreshes the QR surface")
        dialog:onCloseWidget()
    end
end

width, height, modules = 600, 800, 29
local callbacks = 0
local dialog
dialog = QRDialog:new{ text = "payload", dismiss_callback = function()
    callbacks = callbacks + 1
    expect(dialog.qr == nil, "native QR image is released before the dismiss callback")
end }
local before_freed, before_dirty, before_closed = freed, dirty, closed
expect(dialog:onTapClose() == true, "tap dismissal consumes the event")
dialog:onCloseWidget()
expect(freed == before_freed + 1 and dirty == before_dirty + 1 and callbacks == 1,
    "repeated close notification frees and calls back exactly once")
expect(closed == before_closed + 1, "tap closes through UIManager")

touch, keys, encode_failure = false, false, true
local failed = QRDialog:new{ text = "payload" }
expect(not next(failed.ges_events) and not next(failed.key_events), "unsupported input is not registered")
expect(failed[1][1][1].text == "Could not generate a QR code", "encoder failure has a readable fallback")
expect(failed:onClose() == true, "programmatic close remains available")
local keyboard = QRDialog:new{ text = "payload" }
expect(not keyboard.key_events.Close, "initially disconnected keyboard has no bindings")
keys = true
keyboard:onPhysicalKeyboardConnected()
expect(keyboard.key_events.Close and keyboard.key_events.FullRefresh,
    "connecting a keyboard registers Back and F5")
expect(keyboard:onFullRefresh() == true and dirty_widget == keyboard and dirty_mode == "full",
    "F5 requests a full refresh of the dialog")
keyboard:onCloseWidget()
local before_requests = requests
local overlong = QRDialog:new{ text = string.rep("x", 2954) }
expect(requests == before_requests and overlong.qr == nil, "oversized payload is not silently truncated")
expect(overlong[1][1][1].text == "Could not generate a QR code", "oversized payload shows the error")
overlong:onCloseWidget()

print("qr_dialog_spec: " .. checks .. " checks passed")
