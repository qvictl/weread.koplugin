-- @title In-app updater against the mocked GitHub release
-- @timeout 150
-- @fixture github_release
-- The real UpdaterUI + lib/updater, pointed at the mock's synthetic GitHub
-- API (v9999.9.1, built from the candidate). Manual check shows the release
-- dialog with notes; a corrupted checksum must abort with the translated
-- "SHA-256 verification failed" (the profile runs zh_CN; the English text
-- comes from the forked worker) and leave the plugin untouched; "Update now" then
-- installs in place (backup kept) and the restart prompt is declined.
return function(H)
    local UIManager = require("ui/uimanager")
    local lfs = require("libs/libkoreader-lfs")

    local VERSION = "9999.9.1"
    local NOTES = "合成更新，用于模拟器测试。"
    local plugin, ui, lib, plugin_dir, old_version, old_meta

    -- Exact-text tap ("稍后" is also a prefix of "稍后提醒").
    local function tap_exact(text, timeout)
        return H.tap_exact(text, timeout)
    end

    local function read_file(path)
        local file = io.open(path, "rb")
        if not file then return nil end
        local data = file:read("*a")
        file:close()
        return data
    end

    local function meta_version(dir)
        local meta = read_file(dir .. "/_meta.lua")
        return meta and meta:match('version%s*=%s*"([^"]+)"') or nil
    end

    local function is_dir(path)
        return lfs.attributes(path, "mode") == "directory"
    end

    local function wait_release_dialog()
        local viewer = H.wait_until("release dialog", function()
            local top = H.top_window()
            return top and H.has_text("v" .. VERSION, top) and H.has_text(NOTES, top) and top or nil
        end, 30)
        H.check(H.has_text("v" .. old_version, viewer), "dialog names the running version")
        return viewer
    end

    local function downloads(suffix)
        return #H.mock_requests(function(event)
            return event.path and event.path:find("^/github/download/v" .. VERSION .. "/")
                and event.path:sub(-#suffix) == suffix
        end)
    end

    H.step("point the updater at the mock", function()
        plugin = H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        ui = plugin.updater
        lib = ui.updater
        plugin_dir = lib.plugin_dir
        old_version = lib.current_version
        old_meta = read_file(plugin_dir .. "/_meta.lua")
        H.check(old_meta and meta_version(plugin_dir) == old_version, "installed meta matches the running version")
        H.check(not is_dir(plugin_dir .. ".backup"), "no backup before the test")
        H.call(function()
            -- Module fields: forked check/install workers inherit them.
            local Updater = require("weread.lib.updater")
            Updater.API_URL = H.env.mock .. "/github/api/releases/latest"
            Updater.RELEASE_PREFIX = H.env.mock .. "/github/download/"
            Updater.GITHUB_MIRRORS = {}
        end)
        H.metric("from_version", old_version)
    end)

    H.step("manual check finds v" .. VERSION, function()
        local t0 = H.now_ms()
        H.check(H.call(function() return ui:check(true) end), "check started")
        local viewer = wait_release_dialog()
        H.metric("check_ms", H.now_ms() - t0)
        H.equal(H.call(function() return lib:available_version() end), VERSION, "release cached")
        H.check(#H.mock_requests(function(e) return e.path == "/github/api/releases/latest" end) >= 1,
            "GitHub API served by the mock")
        H.shot("release_dialog")
        tap_exact(H.tr("Remind me later"))
        H.wait_until("release dialog closed", function() return not UIManager:isWidgetShown(viewer) end, 10)
        local state = H.call(function() return plugin.settings:get("update") end)
        H.equal(state.snoozed_version, VERSION, "Remind me later snoozes the version")
    end)

    H.step("corrupted checksum is rejected", function()
        local release = H.call(function() return lib:cached_release() end)
        H.check(release and release.version == VERSION, "cached release available")
        release.checksum_url = release.checksum_url .. ".corrupt"
        H.call(function() ui:install(release) end)
        local failed = H.tr("Update installation failed:\n%1"):match("^([^\n]+)")
        H.wait_text(failed, 60)
        local mismatch = H.tr("SHA-256 verification failed")
        H.equal(mismatch, "SHA-256 校验失败", "checksum failure has a Chinese translation")
        H.check(H.has_text(mismatch), "SHA-256 failure reported in Chinese", H.screen_text())
        H.check(not H.has_text("verification failed"), "no untranslated English failure text",
            H.screen_text())
        H.shot("checksum_rejected")
        H.equal(downloads(".sha256.corrupt"), 1, "corrupt checksum downloaded")
        H.equal(read_file(plugin_dir .. "/_meta.lua"), old_meta, "plugin _meta.lua untouched")
        H.check(not is_dir(plugin_dir .. ".backup"), "no backup created")
        local data_dir = plugin.settings.data_dir
        H.check(not is_dir(data_dir .. "/update-stage"), "staging directory removed")
        H.check(not H.file_exists(data_dir .. "/weread-update.zip"), "downloaded archive removed")
        H.check(H.call(function() return not lib:restart_pending() end), "no restart pending")
        H.close_dialogs()
    end)

    H.step("Update now installs v" .. VERSION, function()
        local t0 = H.now_ms()
        local zips_before = downloads(".zip")
        H.check(H.call(function() return ui:check(true) end), "second check started")
        wait_release_dialog()
        tap_exact(H.tr("Update now"))
        local installed = H.tr("WeRead Plugin v%1 was installed.\n\nRestart KOReader to apply the update?")
            :gsub("%%1", VERSION):match("^([^\n]+)")
        H.wait_text(installed, 90)
        H.metric("install_ms", H.now_ms() - t0)
        H.shot("installed_restart_prompt")
        H.equal(downloads(".zip") - zips_before, 1, "archive downloaded once")
        H.equal(downloads(".zip.sha256"), 1, "real checksum downloaded once")
        H.equal(meta_version(plugin_dir), VERSION, "installed _meta.lua version")
        H.check(H.file_exists(plugin_dir .. "/main.lua"), "installed main.lua present")
        H.check(is_dir(plugin_dir .. ".backup"), ".backup kept for rollback")
        H.equal(read_file(plugin_dir .. ".backup/_meta.lua"), old_meta, "backup holds the previous version")
        H.equal(H.call(function() return lib:installed_version() end), VERSION, "installed_version()")
        H.check(H.call(function() return lib:restart_pending() end), "restart pending")
        H.equal(H.call(function() return lib:available_version() end), nil, "available update cleared")
        tap_exact(H.tr("Later"))
        H.wait_until("restart prompt closed", function() return not H.has_text(installed) end, 10)
        H.check(H.call(function() return lib:cleanup_backup() end), "cleanup keeps backup while restart pending")
        H.check(is_dir(plugin_dir .. ".backup"), "backup still there after Later")
        H.equal(H.plugin(), plugin, "still running the old plugin instance (no restart)")
    end)
end
