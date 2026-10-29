local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local I18n = require("weread.lib.i18n")

local ProgressSyncDialog = {}

local function _(text)
    return I18n.tr(text)
end

local function percent(position)
    local fraction = tonumber(position and position.fraction)
    return string.format("%.1f%%", fraction and fraction * 100
        or tonumber(position and position.percent) or 0)
end

-- One decimal, with the percent sign added here. Putting "%" immediately
-- after %1 in a KOReader template is parsed as part of the placeholder, so
-- the dialog shows the raw "%1" and "%2".
local function place(position)
    local value = percent(position)
    local chapter = position and position.chapter_title or ""
    if chapter ~= "" then
        return value .. "\n" .. chapter
    end
    return value
end

function ProgressSyncDialog.show_choice(context)
    local title = tostring(context.book_title or "")
    local message
    if context.source_conflict then
        message = T(_("WeRead's two progress sources disagree for \"%1\"."), title)
            .. "\n\n" .. "KOReader\n" .. place(context.local_position)
            .. "\n\n" .. _("Selected cloud position") .. "\n" .. place(context.remote_position)
    else
        message = T(_("Reading progress differs for \"%1\"."), title)
            .. "\n\n" .. "KOReader\n" .. place(context.local_position)
            .. "\n\n" .. _("WeRead") .. "\n" .. place(context.remote_position)
    end
    message = message .. "\n\n" .. _("Choose which position to keep.")

    -- Only an explicit button press may change anything. Tapping outside the
    -- box or pressing Back used to run cancel_callback, i.e. "Keep KOReader
    -- progress", which uploaded an older local position over newer cloud
    -- progress. Dismissal now calls context.dismiss: nothing is uploaded and
    -- the choice is offered again later.
    local current
    local function show(widget)
        current = widget
        UIManager:show(widget)
    end
    local function dismissible(widget)
        widget.onClose = function(self_)
            if current == self_ then current = nil end
            UIManager:close(self_)
            if context.dismiss then context.dismiss() end
            return true
        end
        return widget
    end
    -- Lets the sync state machine close a stale dialog (document closed,
    -- device suspended) without treating it as a choice.
    context.close = function()
        local widget = current
        current = nil
        if widget then UIManager:close(widget) end
    end

    local show_choice_box
    local function confirm_move_back()
        show(dismissible(ConfirmBox:new{
            title = _("Move WeRead progress back?"),
            text = T(_("WeRead is further ahead than KOReader.\n\nWeRead: %1\nKOReader: %2\n\nKeeping the KOReader position moves your WeRead progress back."),
                percent(context.remote_position), percent(context.local_position)),
            ok_text = _("Move back"),
            cancel_text = _("Back"),
            flush_events_on_show = true,
            ok_callback = function()
                current = nil
                context.keep_local()
            end,
            cancel_callback = function()
                current = nil
                show_choice_box()
            end,
        }))
    end
    show_choice_box = function()
        show(dismissible(ConfirmBox:new{
            title = _("Reading progress sync"),
            text = message,
            ok_text = _("Use WeRead progress"),
            cancel_text = _("Keep KOReader progress"),
            -- The dialog appears shortly after a book opens, while the reader
            -- may already be tapping to turn pages: drop queued taps.
            flush_events_on_show = true,
            ok_callback = function()
                current = nil
                context.use_remote()
            end,
            cancel_callback = function()
                current = nil
                if context.local_behind_remote then
                    confirm_move_back()
                else
                    context.keep_local()
                end
            end,
        }))
    end
    show_choice_box()
end

function ProgressSyncDialog.notify(code, data)
    data = data or {}
    local text
    if code == "upload_success" then
        text = T(_("Progress uploaded to WeRead: %1"),
            percent(data.position))
    elseif code == "upload_failed" then
        text = T(_("Progress upload failed:\n%1"), tostring(data.error or ""))
    elseif code == "already_synced" then
        text = _("KOReader and WeRead are already at the same position.")
    elseif code == "remote_applied" then
        text = T(_("Jumped to WeRead progress: %1"),
            percent(data.position))
    elseif code == "local_kept" then
        text = _("Kept the current KOReader position.")
    elseif code == "pull_failed" then
        text = T(_("Could not fetch WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "jump_failed" then
        text = T(_("Could not jump to WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "local_unavailable" then
        text = T(_("Could not determine the current reading position:\n%1"),
            tostring(data.error or ""))
    elseif code == "authentication_required" then
        text = _("Please scan the QR code to log in first.")
    elseif code == "offline" then
        text = _("No network connection. Please connect Wi-Fi and try again.")
    else
        return
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- Own the trap so document/suspend lifecycle can cancel the pure HTTP task.
-- Automatic pulls use a non-UI cancellation token and never intercept reading.
function ProgressSyncDialog.request(host, task, on_success, on_failure, options)
    local manual = options and options.manual == true
    local widget = {}
    if manual then widget = require("ui/widget/trapwidget"):new{ text = _("Sync progress") } end
    local closed = false
    local function close()
        if closed then return end
        closed = true
        if manual then
            local ok, err = pcall(UIManager.close, UIManager, widget)
            if not ok then require("weread.lib.logger").warn("close progress request failed:", tostring(err)) end
        end
    end
    if manual then UIManager:show(widget) end
    local ok, err = pcall(host._runNetworkRequest, host, widget, _("Sync progress"), task,
        function(value) close(); on_success(value) end,
        function(...) close(); on_failure(...) end)
    if not ok then close(); on_failure(err, false) end
    return function()
        if closed then return end
        if type(widget.dismiss_callback) == "function" then widget.dismiss_callback() end
        close()
    end
end

return ProgressSyncDialog
