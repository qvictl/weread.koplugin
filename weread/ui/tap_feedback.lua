-- Tap highlight shared by the plugin's custom tappable rows.

local UIManager = require("ui/uimanager")

local TapFeedback = {}

-- Flash `frame`, then run `callback`.
--
-- A row whose frame has never been painted has no dimen yet, and its
-- gesture range is still the (0, 0) placeholder from init: the tap can
-- reach it when it is queued in the same input batch that showed the
-- view. It was not aimed at the row, so return false to let it propagate
-- instead of crashing on the missing dimen.
function TapFeedback.run(frame, callback)
    local dimen = frame.dimen
    if not dimen then return false end
    frame.invert = true
    UIManager:widgetRepaint(frame, dimen.x, dimen.y)
    UIManager:forceRePaint()
    frame.invert = false
    UIManager:widgetRepaint(frame, dimen.x, dimen.y)
    UIManager:setDirty(nil, "fast", dimen)
    callback()
    return true
end

return TapFeedback
