-- Entry-point smoke test. All KOReader services are replaced with deterministic
-- fakes, while main.lua and the composition helper remain real.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

local old_namespace_sentinel = {}
for _, module_name in ipairs({
    "lib.client",
    "lib.downloader",
    "lib.settings",
    "ui.common",
    "ui.menu",
}) do
    package.loaded[module_name] = old_namespace_sentinel
end
-- Keep the runtime from loading real worker modules in this fake environment.
require("weread.lib.runtime").PRELOAD_MODULES = {}

package.preload["ui/event"] = function()
    return { new = function(_self, name, value) return { name, value } end }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["ui/uimanager"] = function()
    return {}
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local base = {
        inherited_from_widget_container = function()
            return true
        end,
    }
    function base:extend(fields)
        fields.__index = fields
        return setmetatable(fields, { __index = self })
    end
    return base
end

local settings_values = {
    read_report = {
        enabled = false,
        mode = "manual",
        book_id = "",
        report_on_open = true,
    },
}
local fake_settings = {
    data_dir = "/tmp/weread-plugin-load",
    get = function(_self, key, default)
        local value = settings_values[key]
        if value == nil then return default end
        return value
    end,
}

local migrations_ran = false
local dispatcher_registered = false
local menu_registered = false
local bookshelf_opened = false
local backup_cleaned = false

package.preload["weread.lib.client"] = function()
    return { new = function(_self, settings) return { settings = settings } end }
end
package.preload["weread.lib.background_worker"] = function()
    return { new = function(_self, options) return { options = options } end }
end
local downloaders_created, recovers, settings_created = 0, 0, 0
package.preload["weread.lib.downloader"] = function()
    return {
        new = function(_self, options)
            downloaders_created = downloaders_created + 1
            options.recover = function() recovers = recovers + 1 end
            return options
        end,
    }
end
package.preload["weread.lib.settings"] = function()
    return {
        new = function()
            settings_created = settings_created + 1
            return fake_settings
        end,
    }
end
package.preload["weread.lib.updater"] = function()
    return {
        new = function(_self, options)
            options.cleanup_backup = function()
                backup_cleaned = true
                return true
            end
            return options
        end,
    }
end
package.preload["weread.ui.updater"] = function()
    return {
        new = function(_self, options)
            options.schedule_auto_check = function() end
            return options
        end,
    }
end
package.preload["weread.lib.migrations"] = function()
    return {
        run = function(settings, client)
            migrations_ran = settings == fake_settings
                and client.settings == fake_settings
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
    }
end
local qr_cancels = 0
package.preload["weread.lib.qr_login"] = function()
    return {
        new = function()
            return { kind = "qr_login", cancel = function() qr_cancels = qr_cancels + 1 end }
        end,
    }
end
package.preload["weread.lib.read_report"] = function()
    return {
        new = function(_self, options)
            options.maybe_start = function() end
            options.stop = function(self, reason) self.stopped = reason end
            return options
        end,
    }
end
package.preload["weread.lib.progress_sync"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["weread.ui.progress_sync_dialog"] = function()
    return {
        show_choice = function() end,
        notify = function() end,
    }
end
package.preload["weread.lib.reader_lifecycle"] = function()
    return {
        inherited_feature = function()
            return "reader_lifecycle"
        end,
    }
end

local infos = {}
package.preload["weread.ui.common"] = function()
    return {
        showInfo = function(self, text) infos[#infos + 1] = { self, text } end,
        showTransientInfo = function() end,
        refreshUI = function() end,
        refreshShelfCacheIndicators = function() end,
        openFile = function() end,
        safeCallback = function(_self, _label, fn) return fn end,
        requireLogin = function() return true end,
        runOnlineTask = function(_self, _label, fn) return fn() end,
        isNetworkConnected = function() return true end,
    }
end
package.preload["weread.ui.menu"] = function()
    return {
        onDispatcherRegisterActions = function()
            dispatcher_registered = true
        end,
    }
end
package.preload["weread.ui.cache"] = function()
    return {}
end
package.preload["weread.ui.read_report"] = function()
    return {}
end
package.preload["weread.ui.library"] = function()
    return {
        ensureChaptersLoaded = function() return {} end,
        showBookshelf = function()
            bookshelf_opened = true
            return true
        end,
    }
end
package.preload["weread.ui.annotations_controller"] = function()
    return {}
end
package.preload["weread.ui.reader_navigation"] = function()
    return {
        detectWeReadBook = function() return nil end,
        getChapterInfoFromFile = function() return nil end,
        openProgressTargetChapter = function() return false end,
    }
end

local Plugin = dofile("main.lua")
local function new_instance()
    return setmetatable({
        ui = {
            menu = {
                registerToMainMenu = function(_self, registered_plugin)
                    menu_registered = registered_plugin ~= nil
                end,
            },
        },
    }, { __index = Plugin })
end
local plugin = new_instance()
plugin:init()

expect(plugin.name == "weread", "plugin metadata was not loaded")
expect(plugin:inherited_from_widget_container(),
    "KOReader WidgetContainer inheritance was broken")
expect(plugin:inherited_feature() == "reader_lifecycle",
    "feature mixins were not composed")
expect(plugin.settings == fake_settings, "settings service was not initialized")
expect(plugin.client.settings == fake_settings, "client did not receive settings")
expect(plugin.downloader.settings == fake_settings,
    "downloader did not receive settings")
expect(plugin.qr_login.kind == "qr_login", "QR login service was not initialized")
expect(migrations_ran, "migrations did not run during initialization")
expect(dispatcher_registered, "dispatcher actions were not registered")
expect(menu_registered, "plugin was not registered in KOReader's main menu")
expect(backup_cleaned,
    "successful plugin initialization did not clean the update backup")
expect(plugin:launch() == true and bookshelf_opened,
    "standard third-party launcher entry did not open the bookshelf")
expect(type(plugin.openBookshelf) == "function",
    "stable bookshelf entry point was not exposed")
expect(package.loaded["weread.lib.client"] ~= nil,
    "namespaced client module was not loaded")
expect(package.loaded["weread.ui.menu"] ~= nil,
    "namespaced menu module was not loaded")

-- Progress transport adapters split HTTP from parent catalog/application.
do
    local Content = require("weread.lib.content")
    local Dialog, PluginUtil = require("weread.ui.progress_sync_dialog"), require("weread.lib.plugin_util")
    local originals = { ensure = Content.ensure_reader_state, fetch = Content.fetch_catalog,
        save = Content.save_catalog_cache, get_book = fake_settings.get_book, log_error = PluginUtil.log_error,
        request = Dialog.request, upload = plugin.read_report.upload_position,
        subprocess = plugin.read_report.subprocess, database = plugin.library_db }
    local function run_adapter_checks(inject_failure)
    local ok, error_message = xpcall(function()
    local book, chapters, child = { book_id = "book" }, { { chapterUid = 1 } }, true
    local saves, writes = 0, 0
    fake_settings.get_book = function() return book end
    Content.ensure_reader_state = function() expect(child, "reader HTTP escaped child task") end
    Content.fetch_catalog = function() expect(child, "catalog HTTP escaped child task"); return chapters end
    Content.save_catalog_cache = function()
        expect(not child, "catalog publication escaped parent")
        saves = saves + 1; return saves ~= 2, "synthetic catalog failure"
    end
    require("weread.lib.plugin_util").log_error = tostring
    plugin.library_db = { putChapters = function() expect(not child, "SQLite escaped parent"); writes = writes + 1 end }
    expect(plugin.progress_sync.fetch_catalog("book") == chapters and saves == 0 and writes == 0,
        "catalog task performed parent side effects")
    child = false
    expect(plugin.progress_sync.apply_catalog("book", chapters) == chapters and saves == 1 and writes == 1,
        "catalog result did not reach parent publication")
    expect(plugin.progress_sync.apply_catalog("book", chapters) == chapters and writes == 2,
        "catalog file failure lost SQLite fallback")
    plugin.library_db = nil
    expect(plugin.progress_sync.apply_catalog("book", chapters) == chapters, "catalog without SQLite failed")
    book = nil
    local value, err = plugin.progress_sync.apply_catalog("book", chapters)
    expect(value == nil and err == "book_not_found", "missing parent book accepted")
    child = true
    expect(not pcall(plugin.progress_sync.fetch_catalog, "book"), "missing source book accepted")
    book, chapters = { book_id = "book" }, {}
    expect(not pcall(plugin.progress_sync.fetch_catalog, "book"), "empty catalog accepted")
    local task, options, cancel = function() end, { manual = true }, function() end
    Dialog.request = function(host, fn, _, _, opts)
        expect(host == plugin and fn == task and opts == options, "progress request adapter lost context")
        return cancel
    end
    expect(plugin.progress_sync.request(task, function() end, function() end, options) == cancel,
        "progress request adapter lost cancellation")
    plugin.read_report.upload_position = function() error("synchronous upload must not run") end
    local accepted, outcome = plugin.progress_sync.upload_position("book", {}, 0)
    expect(not accepted and outcome.error_kind == "unsupported", "UI invoked no-worker raw upload")
    plugin.read_report.subprocess = {}
    plugin.read_report.upload_position = function() return true, { accepted = true } end
    expect(plugin.progress_sync.upload_position("book", {}, 0) == true, "worker upload adapter stopped forwarding")
    if inject_failure then error("synthetic adapter assertion failure") end
    end, debug.traceback)
    Content.ensure_reader_state, Content.fetch_catalog, Content.save_catalog_cache = originals.ensure, originals.fetch, originals.save
    fake_settings.get_book, PluginUtil.log_error, Dialog.request = originals.get_book, originals.log_error, originals.request
    plugin.read_report.upload_position, plugin.read_report.subprocess = originals.upload, originals.subprocess
    plugin.library_db = originals.database
    expect(fake_settings.get_book == originals.get_book and PluginUtil.log_error == originals.log_error
        and Dialog.request == originals.request, "module replacements were not restored")
    expect(plugin.read_report.upload_position == originals.upload
        and plugin.read_report.subprocess == originals.subprocess and plugin.library_db == originals.database,
        "plugin replacements were not restored")
    if inject_failure then
        expect(not ok and error_message:find("synthetic adapter assertion failure", 1, true),
            "fault did not reach cleanup")
    elseif not ok then error(error_message, 0) end
    end
    run_adapter_checks(false)
    run_adapter_checks(true)
end

-- KOReader re-instantiates the plugin for every FileManager/ReaderUI. The
-- second instance must share the services and must not re-run recovery.
plugin.downloader.show_info("from first")
expect(infos[1] and infos[1][1] == plugin, "downloader callbacks did not reach the instance")
plugin:onCloseWidget()
expect(plugin.read_report.stopped == "plugin_closed" and qr_cancels == 1,
    "closing an instance must stop its read-report timer and QR login")
local reader_instance = new_instance()
reader_instance:init()
expect(settings_created == 1 and downloaders_created == 1,
    "a second plugin instance must reuse the process services")
expect(reader_instance.settings == plugin.settings
    and reader_instance.downloader == plugin.downloader
    and reader_instance.client == plugin.client,
    "plugin instances do not share the runtime services")
expect(recovers == 1, "stale download recovery must run once per process")
plugin.downloader.show_info("from second")
expect(#infos == 2 and infos[2][1] == reader_instance,
    "callbacks must follow the current instance, not the closed one")

for _, module_name in ipairs({
    "lib.client",
    "lib.downloader",
    "lib.settings",
    "ui.common",
    "ui.menu",
}) do
    expect(package.loaded[module_name] == old_namespace_sentinel,
        "main.lua touched legacy module key " .. module_name)
end

print(("plugin_load_spec: %d checks"):format(checks))
