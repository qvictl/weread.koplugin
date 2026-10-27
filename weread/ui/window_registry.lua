-- Registry of the plugin's full-screen views and list menus.
--
-- Opening a document must not leave WeRead windows in UIManager's window
-- stack underneath the reader: they keep a stale plugin instance alive and
-- reappear when the reader closes. Views register themselves when shown;
-- closeAll() closes whichever of them are still open, newest first.
-- Keys are weak, so a view the user closed is simply collected.

local UIManager = require("ui/uimanager")

local Registry = {}

local windows = setmetatable({}, { __mode = "k" })
local sequence = 0

function Registry.track(widget)
    if widget then
        sequence = sequence + 1
        windows[widget] = sequence
    end
    return widget
end

function Registry.closeAll()
    local open = {}
    for widget, order in pairs(windows) do
        open[#open + 1] = { widget = widget, order = order }
    end
    table.sort(open, function(left, right) return left.order > right.order end)
    for _i, entry in ipairs(open) do
        windows[entry.widget] = nil
        if UIManager:isWidgetShown(entry.widget) then
            UIManager:close(entry.widget)
        end
    end
end

return Registry
