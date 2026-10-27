-- Taps queued in the input batch that opens a thought popup must never reach
-- the popup before its first paint (KOReader dispatches a whole input batch
-- before repainting; unpainted title-bar icons crash in widgetInvert).
-- Run from the repo root with:
--   luajit spec/thought_popup_first_paint_spec.lua

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed"), 2) end
end

-- Minimal KOReader widget class: new() runs init(), getSize/getHeight work.
local function class(fields)
    local proto = fields or {}
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
    proto.getSize = proto.getSize or function(self)
        return { w = self.width or 100, h = self.height_px or 40 }
    end
    proto.getHeight = proto.getHeight or function(self) return self:getSize().h end
    proto.free = proto.free or function() end
    return proto
end

local inner_events, inner_paints = {}, 0
local InputContainer = class{
    handleEvent = function(_self, event)
        inner_events[#inner_events + 1] = event.handler
        return true
    end,
    paintTo = function() inner_paints = inner_paints + 1 end,
    clear = function(self)
        for i = #self, 1, -1 do self[i] = nil end
    end,
}

local titlebars = {}
package.preload["ui/widget/titlebar"] = function()
    return class{
        init = function(self)
            titlebars[#titlebars + 1] = self
            -- Roughly one 30px line per 40 bytes when wrapping.
            local lines = self.title_multilines and math.ceil(#self.title / 40) or 1
            self.height_px = 30 * math.max(1, lines)
        end,
    }
end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/bidi"] = function()
    return {
        flipIfMirroredUILayout = function(value) return value end,
        flipDirectionIfMirroredUILayout = function(value) return value end,
    }
end
for _i, name in ipairs({ "ui/widget/buttondialog", "ui/widget/container/bottomcontainer",
    "ui/widget/linewidget", "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer", "ui/widget/verticalgroup",
    "ui/widget/verticalspan", "ui/gesturerange", "weread.ui.thought_popup.page_viewport",
    "weread.ui.thought_popup.scroll_container" }) do
    package.preload[name] = function() return class() end
end
package.preload["ui/widget/buttontable"] = function()
    return class{ getButtonById = function() return nil end }
end
package.preload["ui/geometry"] = function() return class() end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 255 } end
package.preload["device"] = function()
    return {
        input = { group = {} },
        screen = {
            scaleBySize = function(_, value) return value end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getSize = function() return { w = 600, h = 800 } end,
        },
        isTouchDevice = function() return false end,
        hasKeys = function() return false end,
    }
end
package.preload["ui/font"] = function()
    return { getFace = function(name, size) return { name = name, size = size } end }
end
local renderer = {
    content_h = 200, text_w = 400,
    ensureLayout = function() end,
    setContent = function() end,
    computePages = function() return { 0 } end,
}
package.preload["weread.ui.thought_popup.pages"] = function()
    return { new = function() return renderer end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end
package.preload["ui/size"] = function()
    return {
        padding = { large = 8, default = 4 },
        radius = { window = 6 },
        line = { thick = 2 },
    }
end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { free = function() end }
end

local CenterWidget = require("weread.ui.thought_popup.center_widget")
local BottomWidget = require("weread.ui.thought_popup.widget")
local gesture = { handler = "onGesture" }
local key = { handler = "onKeyPress" }

for _i, Widget in ipairs({ CenterWidget, BottomWidget }) do
    inner_events, inner_paints = {}, 0
    local popup = Widget:new{ items = { { abstract = "quote", content = "body" } } }
    expect(popup:handleEvent(gesture) == true and #inner_events == 0,
        "an unpainted popup let a queued tap reach its unpainted children")
    expect(popup:handleEvent(key) == true and inner_events[1] == "onKeyPress",
        "an unpainted popup dropped a key event (Back must still close it)")
    popup:paintTo({}, 0, 0)
    expect(inner_paints == 1, "first paint was not forwarded")
    popup:handleEvent(gesture)
    expect(inner_events[2] == "onGesture", "a painted popup ignored taps")
    -- Reopening rebuilds the title bar and buttons: they are unpainted again.
    popup:_reopen({ items = { { abstract = "other", content = "body" } } })
    inner_events = {}
    popup:handleEvent(gesture)
    expect(#inner_events == 0, "a reopened popup accepted taps before repainting")
end

-- A paragraph-long quote must not push the thought text out of the window.
local long_quote = string.rep("很长的划线原文", 300)
local tall = CenterWidget:new{ items = { { abstract = long_quote, content = "body" } } }
local title = tall._titlebar.title
expect(#title < 120 * 3 + 4 and title:sub(-3) == "…", "a long quote was not truncated")
expect(title:sub(1, 21) == long_quote:sub(1, 21), "truncation did not keep the start of the quote")
expect(tall._titlebar:getHeight() <= math.floor(800 * 0.7 * 0.3),
    "the title bar takes too much of the popup height")
local short = CenterWidget:new{ items = { { abstract = "short quote", content = "body" } } }
expect(short._titlebar.title_multilines == true and short._titlebar.title == "short quote",
    "a short quote lost its multi-line title")

-- The entry never stacks a visible pooled widget twice.
package.loaded["ui/uimanager"] = nil
local shown, closed, visible = {}, {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget; visible[widget] = true end,
        close = function(_self, widget) closed[#closed + 1] = widget; visible[widget] = nil end,
        isWidgetShown = function(_self, widget) return visible[widget] == true end,
    }
end
package.preload["weread.ui.thought_popup.face_factory"] = function()
    return { init = function() end }
end
local reopened = 0
package.loaded["weread.ui.thought_popup.center_widget"] = {
    new = function(_self, fields)
        fields._reopen = function(widget, opts)
            expect(not visible[widget], "a shown popup was rebuilt in place")
            widget.items = opts.items
            reopened = reopened + 1
        end
        fields.clear = function() end
        fields._freeContentCaches = function() end
        return fields
    end,
}
local Entry = require("weread.ui.thought_popup")
local first = Entry.show({ pages = { { content = "a" } } })
local second = Entry.show({ pages = { { content = "b" } } })
expect(first == second and reopened == 1, "the pooled widget was not reused")
expect(#closed == 1 and closed[1] == first and #shown == 2,
    "the visible pooled popup was not closed before reopening")
Entry.cleanup()

-- Overlay taps are deferred to the next tick and deduplicated per batch.
local ticks = {}
package.loaded["ui/uimanager"] = {
    nextTick = function(_self, callback) ticks[#ticks + 1] = callback end,
    setDirty = function() end,
}
local popup_shows = 0
package.loaded["weread.ui.thought_popup"] = {
    show = function(options)
        popup_shows = popup_shows + 1
        return { options = options }
    end,
    isShowing = function() return popup_shows > 0 end,
    closeVisible = function() end,
    cleanup = function() end,
}
package.preload["weread.ui.thought_popup.popup_config"] = function()
    return { build = function(_plugin, pages, extra)
        local options = { pages = pages }
        for name, value in pairs(extra or {}) do options[name] = value end
        return options
    end }
end
package.preload["weread.lib.annotations"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.thought_db"] = function() return {} end
package.preload["weread.lib.external_annotations"] = function() return {} end
package.preload["weread.ui.xpointer_overlay"] = function() return {} end
package.preload["ui/event"] = function() return { new = function() return {} end } end
package.preload["ui/time"] = function() return { now = function() return 0 end } end
package.preload["weread.lib.logger"] = function() return { warn = function() end } end
package.loaded["weread.lib.plugin_util"] = {
    tr = function(text) return text end,
    T = function(text) return text end,
    thought_perf = function() end,
}
package.loaded["device"].screen.getWidth = function() return 600 end
local host = {
    _reader_session_gen = 1,
    ui = { document = { highlightXPointer = function() end } },
    settings = { get = function(_self, name)
        if name == "cache" then return { ignore_edge_thought_taps = false } end
        return {}
    end },
    _xpointer_overlay = {
        enabled = true,
        hitTest = function() return { items = { { abstract = "q", content = "c" } } } end,
    },
}
for name, method in pairs(require("weread.ui.annotations_controller")) do host[name] = method end
for name, method in pairs(require("weread.ui.xpointer_overlay_controller")) do host[name] = method end
local tap = { pos = { x = 300, y = 300 } }
expect(host:_onXPointerOverlayTap(tap) == true, "the overlay tap was not consumed")
expect(popup_shows == 0 and #ticks == 1, "the popup opened inside the gesture handler")
expect(host:_onXPointerOverlayTap(tap) == true and #ticks == 1,
    "a second tap from the same input batch queued another popup")
table.remove(ticks, 1)()
expect(popup_shows == 1 and host._current_thought_popup, "the queued popup was not shown")
expect(host:_onXPointerOverlayTap(tap) == true and #ticks == 0,
    "a tap while the popup is visible queued another popup")
host._current_thought_popup.options.close_callback()
expect(not host._thought_popup_open, "closing the overlay popup did not reset the guard")

print(string.format("thought_popup_first_paint_spec: %d checks", checks))
