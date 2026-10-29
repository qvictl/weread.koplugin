-- Real UI gates, including callers that do not explicitly request link_only.
package.path = "./?.lua;" .. package.path
local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local scheduled, shown, connected, dns, links = {}, {}, true, 0, 0
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, callback)
            expect(delay >= 0.1, "network task lost the UI paint delay")
            scheduled[#scheduled + 1] = callback
        end,
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function() end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        isConnected = function() links = links + 1; return connected end,
        isOnline = function() dns = dns + 1; error("forbidden synchronous UI DNS") end,
    }
end
package.preload["ui/bidi"] = function() return {} end
for _, name in ipairs({ "confirmbox", "infomessage", "menu", "inputdialog" }) do
    package.preload["ui/widget/" .. name] = function()
        return { new = function(_, options)
            options.getInputText = function() return "synthetic title" end
            return options
        end }
    end
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(value) return value end, T = function(value) return value end,
        log_error = tostring, display_error = tostring, unpack_args = unpack }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.external_annotations"] = function()
    return { normalize_search = function() return {} end }
end
package.preload["weread.ui.xpointer_overlay"] = function() return {} end
package.preload["weread.ui.thought_popup.popup_config"] = function() return {} end
local pickers = 0
package.preload["weread.ui.annotation_chapter_picker"] = function()
    return { show = function() pickers = pickers + 1 end }
end
local Common = require("weread.ui.common")
local Annotations = require("weread.ui.annotation_sync_controller")
local Overlay = require("weread.ui.xpointer_overlay_controller")
local jobs, contexts, requests, searches, default_tasks, manual_tasks, downloads = 0, 0, 0, 0, 0, 0, 0
local host = {}
for _, methods in ipairs({ Common, Annotations, Overlay }) do
    for key, value in pairs(methods) do host[key] = value end
end
host.ui = { document = { file = "/synthetic/book.epub" } }
host.settings = { data_dir = "/synthetic", get = function() return {} end, set = function() end, flush = function() end }
host.requireLogin = function() return true end
host._annotationBinding = function() return { book_id = "1" } end
host._xpointerOverlayPrototypeAvailable = function() return true end
host._prepareAnnotationContext = function() return nil end
host._annotationSelectionModel = function() return {} end
host._withAnnotationContext = function(_, _, _, _, callback)
    contexts = contexts + 1
    return callback({ book_id = "1", binding = { title = "Synthetic" }, document_key = "local",
        chapters = { { chapterUid = 1 } }, catalog = { { chapterUid = 1 } },
        store = { put = function() end } })
end
host._runAnnotationJob = function() jobs = jobs + 1 end
host._runAnnotationRequest = function(_, _, _, task, apply)
    requests = requests + 1
    return apply(task())
end
host.client = { gateway = function(_, path)
    expect(path == "/store/search", "binding search reached the wrong worker task")
    return {}
end }
host.showList = function() searches = searches + 1 end
local Runtime = require("weread.lib.runtime")
local runtime = Runtime.new{
    Settings = { new = function() return host.settings end },
    Client = { new = function() return host.client end },
    BackgroundWorker = { new = function() return {} end },
    Downloader = { new = function(_, options) return options end }, preload_modules = {},
}
runtime:attach(host)
local cases = {
    { name = "default", run = function()
        host:runOnlineTask("Default", function() default_tasks = default_tasks + 1 end)
    end, completed = function() return default_tasks end },
    { name = "manual false option", run = function()
        host:runOnlineTask("Manual", function() manual_tasks = manual_tasks + 1 end, nil, { link_only = false })
    end, completed = function() return manual_tasks end },
    { name = "unified sync", run = function() host:startUnifiedAnnotationSync() end,
        completed = function() return jobs end },
    { name = "uncached chapter picker", run = function() host:chooseAnnotationChapters() end,
        completed = function() return pickers end },
    { name = "binding search", run = function()
        host:bindExternalAnnotationsBook()
        shown[#shown].buttons[1][2].callback()
    end, completed = function() return searches end },
    { name = "downloader runtime adapter", run = function()
        runtime.downloader.run_online_task("Download", function() downloads = downloads + 1 end)
    end, completed = function() return downloads end },
}
for _, case in ipairs(cases) do
    scheduled, dns, links, connected = {}, 0, 0, true
    local before = case.completed()
    case.run()
    expect(dns == 0 and links == 1, case.name .. " performed a blocking online probe")
    expect(#scheduled == 1 and case.completed() == before, case.name .. " did not defer work")
    while #scheduled > 0 do table.remove(scheduled, 1)() end
    expect(case.completed() == before + 1, case.name .. " did not reach its worker/presentation boundary")
    scheduled, dns, links, connected = {}, 0, 0, false
    before = case.completed()
    case.run()
    expect(dns == 0 and links == 1 and #scheduled == 0 and case.completed() == before,
        case.name .. " did not preserve offline rejection")
    scheduled = {}
end
expect(contexts == 2 and requests == 1, "annotation context/search boundaries were bypassed")
-- Older runtimes without a link API leave reachability to the worker.
package.loaded["ui/network/manager"].isConnected = nil
dns = 0
expect(host:runOnlineTask("Legacy", function() default_tasks = default_tasks + 1 end) == true
    and #scheduled == 1 and dns == 0, "legacy runtime fell back to UI DNS")
-- The real-scenario probe must restore inherited methods and endpoints
-- even when the exercised UI action fails.
local probe = dofile("spec/emulator/no_ui_dns.lua")
local manager = package.loaded["ui/network/manager"]
local inherited = { isConnected = function() return false end, isOnline = function() return false end }
local probe_manager = setmetatable({}, { __index = inherited })
local probe_settings = setmetatable({}, { __index = { mock_endpoint = "synthetic-endpoint" } })
package.loaded["ui/network/manager"] = probe_manager
local harness = {
    call = function(callback) return callback() end,
    plugin = function() return { settings = probe_settings } end,
    equal = function(got, want, label) expect(got == want, label) end,
}
for _, fail in ipairs({ false, true }) do
    local ok, value = pcall(probe, harness, function()
        expect(probe_settings.mock_endpoint == false and probe_manager:isConnected(), "DNS probe not installed")
        if fail then error("synthetic UI action failure") end
        return "done"
    end)
    expect(ok == not fail and (fail or value == "done"), "DNS probe swallowed an action result/failure")
    expect(rawget(probe_manager, "isConnected") == nil and rawget(probe_manager, "isOnline") == nil
        and probe_manager.isConnected == inherited.isConnected, "DNS probe retained a method override")
    expect(rawget(probe_settings, "mock_endpoint") == nil and probe_settings.mock_endpoint == "synthetic-endpoint",
        "DNS probe retained a mock shortcut override")
end
package.loaded["ui/network/manager"] = manager
print(("ui_network_gates_spec: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
