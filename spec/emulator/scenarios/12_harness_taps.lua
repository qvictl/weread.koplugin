-- @title Harness: taps wait for a dialog's painted position
-- @timeout 60
-- @no_coverage
-- Guards the harness itself, not the plugin. A dialog shown by a task that
-- runs in the same UI tick as a wait_until predicate is in the window stack
-- but not painted yet: its Buttons still carry the init-time dimen
-- Geom{w, h}, whose x/y are Geom's class defaults (0, 0). Tapping the centre
-- of that placeholder hits the screen's top-left corner, outside the dialog,
-- and a dismissable ConfirmBox just closes - the cause of the flaky
-- "timed out waiting for: ReaderUI ready" (09, "Read now" tapped @ 112 20)
-- and "resumed download finished" (04) failures. H.tap_exact paints pending
-- windows first and only trusts a dimen whose x/y paintTo stored.
return function(H)
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")

    local function button_dimen(label)
        return H.walk(function(widget, chain, depth)
            if rawget(widget, "text") ~= label then return nil end
            for i = depth, 1, -1 do
                local d = rawget(chain[i], "dimen")
                if type(d) == "table" then return d end
            end
        end, H.input_window())
    end

    H.step("an unpainted button only has a placeholder dimen", function()
        local probe = H.call(function()
            local box = ConfirmBox:new{ text = "probe", ok_text = "PROBE_OK" }
            UIManager:show(box)
            local before = button_dimen("PROBE_OK")
            local out = {
                found = before ~= nil,
                x = before and before.x, y = before and before.y,
                painted_before = H.painted_dimen({ dimen = before }) ~= nil,
            }
            UIManager:forceRePaint()
            local after = button_dimen("PROBE_OK")
            out.painted_after = H.painted_dimen({ dimen = after }) ~= nil
            out.after_y = after and after.y
            UIManager:close(box)
            return out
        end)
        H.check(probe.found, "button found before the first paint")
        -- The trap: a numeric x/y before anything was painted.
        H.equal(probe.x, 0, "placeholder x")
        H.equal(probe.y, 0, "placeholder y")
        H.check(not probe.painted_before, "placeholder is not treated as painted")
        H.check(probe.painted_after, "button painted after a repaint")
        H.check(probe.after_y > 0, "painted button is not at the top edge", tostring(probe.after_y))
        H.close_dialogs()
    end)

    H.step("tap a dialog shown in the predicate's own UI tick", function()
        for round = 1, 5 do
            local state = {}
            local label = "SAME_TICK_OK_" .. round
            H.call(function()
                -- Runs right before tap_exact's first predicate, in the same
                -- _checkTasks pass, so nothing repaints in between.
                UIManager:scheduleIn(0, function()
                    UIManager:show(ConfirmBox:new{
                        text = "same tick " .. round,
                        ok_text = label,
                        ok_callback = function() state.ok = true end,
                        cancel_callback = function() state.cancelled = true end,
                    })
                end)
            end)
            H.tap_exact(label, 5)
            H.wait_until("ok_callback of round " .. round, function()
                return state.ok or state.cancelled
            end, 5)
            H.check(state.ok and not state.cancelled, "tap reached the button, round " .. round)
            H.close_dialogs()
        end
    end)
end
