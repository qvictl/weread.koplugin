package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
local shown_widget
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown_widget = widget end,
        close = function(_self, widget)
            if shown_widget == widget then shown_widget = nil end
        end,
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
        unschedule = function() end,
    }
end
local dialogs = {}
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_, value)
            value.show = function(self) self.shown = true end
            value.close = function(self) self.closed = true end
            value.setTitle = function(self, title) self.title = title end
            value.reportProgress = function(self, percent) self.percent = percent end
            dialogs[#dialogs + 1] = value
            return value
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { warn = function() end, err = function() end }
end
-- Real dictionary: the language follows saved_language (English when unset,
-- as no gettext is loaded in standalone LuaJIT).
local saved_language
G_reader_settings = {
    readSetting = function(_self, key)
        assert(key == "language")
        return saved_language
    end,
}
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(value) return require("weread.lib.i18n").tr(value) end,
        T = function(template, ...)
            local values = { ... }
            return (template:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end

local UpdaterUI = require("weread.ui.updater")
local state = { available_version = "0.7.0" }
local settings = {
    data_dir = "/tmp",
    get = function() return state end,
    set = function(_, _, value) state = value end,
    flush = function() end,
}
local core = require("weread.lib.updater"):new{
    settings = settings, current_version = "0.6.0", plugin_dir = "/tmp/weread.koplugin",
}
local ui = UpdaterUI:new{
    updater = core,
    settings = settings,
}

expect(ui:has_update(), "UI did not delegate update state")
expect(ui:available_version() == "0.7.0",
    "UI did not delegate available version")

local download_title = ui:_progress_title{
    stage = "downloading",
    current = 512 * 1024,
    total = 1024 * 1024,
}
expect(download_title:find("50%%") ~= nil,
    "download title did not show the real percentage")
expect(download_title:find("512 KB", 1, true) ~= nil
    and download_title:find("1.0 MB", 1, true) ~= nil,
    "download title did not show transferred bytes")
expect(ui:_progress_title{ stage = "verifying" }
    == "Verifying update package…", "verification stage title was wrong")
expect(ui:_progress_title{ stage = "extracting" }
    == "Extracting update package…", "extraction stage title was wrong")
expect(ui:_progress_title{ stage = "installing" }
    == "Installing update…", "installation stage title was wrong")

ui:_show_release{
    version = "0.7.0",
    notes = "First change\nSecond change",
}
expect(shown_widget.title == "New version available\nWeRead v0.6.0 → v0.7.0",
    "release notes viewer title was wrong")
expect(shown_widget.text == "First change\nSecond change"
    and shown_widget.buttons_table[1][2].text == "Skip this version"
    and shown_widget.buttons_table[2][1].text == "Update now",
    "release notes viewer did not expose notes and install action")
expect(shown_widget.add_default_buttons == false and shown_widget.show_menu == false,
    "release viewer must not add navigation buttons")
shown_widget.buttons_table[1][1].callback()
expect(shown_widget == nil and not core:should_notify("0.7.0"), "later button did not snooze")

local fetched = { version = "0.7.0", notes = "Release notes" }
core.fetch_release = function() return fetched end
ui._run_subprocess = function(_self, message, task, callback)
    callback(task())
end
ui:check(false)
expect(shown_widget == nil, "snoozed automatic check displayed a dialog")
state.snooze_until = 0
ui:check(false)
expect(shown_widget and shown_widget.text == fetched.notes, "new release did not auto-notify")
local automatic_viewer = shown_widget
local another_ui = UpdaterUI:new{ updater = core, settings = settings }
expect(another_ui:_show_release(fetched) == nil and shown_widget == automatic_viewer,
    "two plugin instances displayed duplicate update dialogs")
automatic_viewer.buttons_table[1][2].callback()
expect(shown_widget == nil and state.skipped_version == "0.7.0", "skip button did not save the version")
ui:check(false)
expect(shown_widget == nil, "skipped automatic check displayed a dialog")
ui:show_cached_update()
expect(shown_widget ~= nil, "manual cached update must ignore suppression")
shown_widget.close_callback()
shown_widget = nil
fetched = { version = "0.8.0", notes = "Newer notes" }
ui:check(false)
expect(shown_widget and shown_widget.text == "Newer notes", "newer version should notify again")
shown_widget.close_callback()
shown_widget = nil
expect(state.snoozed_version == "0.8.0", "back/close must behave like remind later")
ui:check(true)
expect(shown_widget ~= nil, "manual check must ignore snoozing")
shown_widget.close_callback()
shown_widget = nil
fetched = { version = "0.6.0" }
ui:check(false)
expect(shown_widget == nil, "current version should remain silent automatically")
fetched = nil
ui:check(false)
expect(shown_widget == nil, "automatic failure should remain silent")
ui:check(true)
expect(shown_widget and shown_widget.text:find("Update check failed", 1, true),
    "manual failure should still be reported")
shown_widget = nil

local now = 100000
local original_env = getfenv(UpdaterUI.schedule_auto_check)
setfenv(UpdaterUI.schedule_auto_check, setmetatable({
    os = { time = function() return now end },
}, { __index = original_env }))
state = { auto_check = true, last_check = now - 3599 }
local automatic_checks = 0
ui.check = function(_self, manual)
    expect(manual == false, "automatic update checks must use the automatic policy")
    automatic_checks = automatic_checks + 1
end
ui:schedule_auto_check()
expect(#scheduled == 0, "automatic check repeated before one hour elapsed")
state.last_check = now - 3600
ui:schedule_auto_check()
expect(#scheduled == 1 and scheduled[1].delay == 5,
    "automatic check must become due after one hour and preserve startup delay")
scheduled[1].callback()
expect(automatic_checks == 1, "due automatic check did not run")
ui.is_connected = function() return false end
scheduled[1].callback()
expect(automatic_checks == 1, "automatic check must not connect while offline")
scheduled = {}
state.auto_check = false
ui:schedule_auto_check()
expect(#scheduled == 0, "disabled automatic checks must remain disabled")
setfenv(UpdaterUI.schedule_auto_check, original_env)

local installed
ui.install = function(_self, value) installed = value end
local install_release = { version = "0.9.0", notes = "Install now" }
ui:_show_release(install_release)
local install_button = shown_widget.buttons_table[2][1]
install_button.callback()
expect(shown_widget == nil, "install button must close the release viewer")
expect(another_ui:_show_release(install_release) == nil, "install must suppress concurrent dialogs")
scheduled[#scheduled].callback()
expect(installed == install_release, "install button did not use the displayed release")
local scheduled_count = #scheduled
install_button.callback()
expect(#scheduled == scheduled_count, "double activation scheduled two installs")

-- Regression: updater failures (e.g. a checksum mismatch) were shown in
-- English in the Chinese UI. lib/updater returns English text from the forked
-- worker; UpdaterUI translates it when the dialog is displayed.
local function failed_install(err)
    core.install_release = function(_self, _release, on_progress)
        on_progress{ stage = "verifying", percent = 82 }
        return nil, err
    end
    shown_widget = nil
    UpdaterUI.install(ui, { version = "0.9.0" })
    expect(dialogs[#dialogs].closed, "progress dialog must close after a failure")
    return shown_widget and shown_widget.text
end

saved_language = "zh_CN.UTF-8"
expect(failed_install("SHA-256 verification failed") == "安装更新失败：\nSHA-256 校验失败",
    "checksum mismatch must be shown in Chinese")
expect(failed_install("HTTP 404") == "安装更新失败：\n服务器返回 HTTP 404",
    "HTTP status must be shown in Chinese")
expect(failed_install("HTTP timeout") == "安装更新失败：\n网络错误：timeout",
    "transport errors must keep the raw detail inside a Chinese message")
expect(failed_install("cannot create staging directory: No space left on device")
    == "安装更新失败：\n无法创建更新暂存目录：No space left on device",
    "staging failure must keep the OS detail inside a Chinese message")
expect(failed_install(nil) == "安装更新失败：\n未知错误", "missing error must be translated")
expect(failed_install("/x: Permission denied") == "安装更新失败：\n/x: Permission denied",
    "unknown OS errors must be shown unchanged")
ui.check = UpdaterUI.check
ui.is_connected = function() return true end
core.fetch_release = function() return nil, "invalid GitHub response" end
shown_widget = nil
ui:check(true)
expect(shown_widget and shown_widget.text == "检查更新失败：\nGitHub 返回的数据无效",
    "manual check failure must be shown in Chinese")

-- Every fixed failure message lib/updater can return must be translated.
-- Prefixes with a variable part ("HTTP ", "...: ") are matched by pattern;
-- the helpers listed here never reach the UI.
local internal = {
    [""] = true, error = true, ["could not rewind file"] = true,
    ["invalid directory"] = true, ["directory cleanup unavailable"] = true,
}
local literals = 0
for line in io.lines("weread/lib/updater.lua") do
    if line:find("nil,", 1, true) or line:find('limit_error = "', 1, true) then
        for literal in line:gmatch('"([^"]*)"') do
            if not internal[literal] and not literal:match("[ :]$") then
                literals = literals + 1
                local display = UpdaterUI.display_error(literal)
                expect(display ~= literal and not display:find("%a%a%a%a%a %a%a%a"),
                    "untranslated updater error: " .. literal)
            end
        end
    end
end
expect(literals >= 20, "updater error scan found too few messages")

saved_language = nil
expect(failed_install("SHA-256 verification failed")
    == "Update installation failed:\nSHA-256 verification failed",
    "English UI must keep the original message")
expect(UpdaterUI.display_error("HTTP 503") == "Server returned HTTP 503"
    and UpdaterUI.display_error("") == "Unknown error",
    "English fallback for variable messages")

print(("updater_ui_spec: %d checks"):format(checks))
