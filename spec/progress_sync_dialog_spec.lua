-- Verify precise progress text and usable choice callbacks without a renderer.
package.path = "./?.lua;" .. package.path
local shown
for _, module in ipairs({ "ui/widget/confirmbox", "ui/widget/infomessage" }) do
    package.preload[module] = function()
        return { new = function(_self, options) return options end }
    end
end
local closed = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown = widget end,
        close = function(_self, widget) closed[#closed + 1] = widget end,
    }
end
package.preload["ffi/util"] = function()
    return { template = function(text, ...)
        local args = { ... }
        return (text:gsub("%%(%d+)", function(index) return tostring(args[tonumber(index)]) end))
    end }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
local Dialog = require("weread.ui.progress_sync_dialog")
local selected = false
Dialog.show_choice{
    book_title = "Book",
    local_position = { percent = 1, fraction = 0.01675761, chapter_title = "Chapter six" },
    remote_position = { percent = 3.401893, chapter_title = "Chapter six" },
    use_remote = function() selected = true end,
}
assert(shown.text:find("1.7%", 1, true), "local progress lost its fractional precision")
assert(shown.text:find("3.4%", 1, true), "remote precision is displayed")
assert(shown.text:find("Chapter six", 1, true), "chapter title is displayed")
assert(not shown.text:find("%1", 1, true), "unexpanded placeholder")
shown.ok_callback()
assert(selected, "cloud choice callback is preserved")
Dialog.notify("upload_success", { position = { percent = 1, fraction = 0.01675761 } })
assert(shown.text == "Progress uploaded to WeRead: 1.7%", "uploaded percent formatting")
Dialog.notify("remote_applied", { position = { percent = 3.401893 } })
assert(shown.text == "Jumped to WeRead progress: 3.4%", "jumped percent formatting")

-- F1: tapping outside the box or pressing Back is not a choice.
local calls = {}
local function choice_context(behind)
    calls = {}
    local context = {
        book_title = "Book",
        local_position = { percent = 5, fraction = 0.05 },
        remote_position = { percent = 6.4655 },
        local_behind_remote = behind,
        use_remote = function() calls[#calls + 1] = "remote" end,
        keep_local = function() calls[#calls + 1] = "local" end,
        dismiss = function() calls[#calls + 1] = "dismiss" end,
    }
    Dialog.show_choice(context)
    return context
end
choice_context(true)
assert(shown.flush_events_on_show == true, "queued page-turn taps are discarded")
local first = shown
first:onClose()
assert(#calls == 1 and calls[1] == "dismiss", "dismissal only dismisses")
assert(closed[#closed] == first, "dismissal closes the box")

-- Keeping a position behind the cloud needs a second confirmation.
choice_context(true)
first = shown
first.cancel_callback()
assert(#calls == 0, "first press on keep-local does not upload yet")
local confirm = shown
assert(confirm ~= first and confirm.text:find("6.5%", 1, true)
    and confirm.text:find("5.0%", 1, true), "confirmation shows both positions")
confirm.cancel_callback()
assert(#calls == 0 and shown ~= confirm and shown.ok_text == "Use WeRead progress",
    "Back returns to the original choice")
shown.cancel_callback()
shown.ok_callback()
assert(#calls == 1 and calls[1] == "local", "confirmed keep-local runs once")

choice_context(true)
shown.cancel_callback()
shown:onClose()
assert(#calls == 1 and calls[1] == "dismiss", "dismissing the confirmation is no choice")

-- Local ahead: keep-local is a single press.
choice_context(false)
shown.cancel_callback()
assert(#calls == 1 and calls[1] == "local", "no confirmation when not moving back")

-- The state machine can close a stale dialog without answering it.
local context = choice_context(false)
first = shown
context.close()
assert(closed[#closed] == first and #calls == 0, "close() is not a choice")

print("progress_sync_dialog_spec: 18 checks passed")
