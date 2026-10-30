local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("weread.lib.plugin_util").tr

local QRDialog = InputContainer:extend{
    modal = true,
    stop_events_propagation = true,
    text = "",
    dismiss_callback = nil,
}

function QRDialog:init()
    local viewport = Device.screen:getSize()
    local border = Size.border.window
    -- A QR symbol has at least 21 modules and needs four clear modules on
    -- each side. Reserve two extra pixels for the two ceil-rounded margins.
    local side = math.max(1, math.floor((math.min(viewport.w, viewport.h) - 2 * border - 2) * 21 / 29))
    local content, padding
    if #self.text <= (QRWidget.MAX_BYTES or 2953) then
        local qr = QRWidget:new{ text = self.text, width = side, height = side, scale_factor = 1 }
        self.qr = qr
        if qr.image then
            -- ImageWidget should paint its native image size, without another
            -- scaling or a larger placeholder area inside the quiet zone.
            qr.width, qr.height = nil, nil
            -- Bind the generated image to ImageWidget's disposal path even
            -- when login is cancelled before its delayed first paint.
            local size = qr:getSize()
            if size.w > 0 and size.h > 0 then
                padding = math.ceil(math.max(size.w, size.h) * 4 / 21)
                content = qr
            end
        end
    end
    if not content then
        padding = Size.padding.large
        content = TextWidget:new{
            text = _("Could not generate a QR code"),
            face = Font:getFace("infofont"), max_width = side,
        }
    end
    self[1] = CenterContainer:new{
        dimen = viewport,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE, bordersize = border,
            padding = padding, content,
        },
    }
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = Geom:new(viewport) },
        }
    end
    self:registerKeyEvents()
end

function QRDialog:registerKeyEvents()
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.FullRefresh = { { { "Press", "F5" } } }
    end
end
QRDialog.onPhysicalKeyboardConnected = QRDialog.registerKeyEvents

function QRDialog:onFullRefresh()
    UIManager:setDirty(self, "full")
    return true
end

function QRDialog:onTapClose()
    UIManager:close(self)
    return true
end
QRDialog.onClose = QRDialog.onTapClose

function QRDialog:onCloseWidget()
    if self._closed then return end
    self._closed = true
    UIManager:setDirty(nil, "ui")
    if self.qr then
        self.qr:free()
        self.qr = nil
    end
    local callback = self.dismiss_callback
    self.dismiss_callback = nil
    if callback then callback() end
end

return QRDialog
