-- Process runtime: one Settings/Client/worker/downloader per process, one
-- recover() per process, and downloader UI callbacks routed to whichever
-- plugin instance is currently attached.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local shown = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget.text end,
        forceRePaint = function() end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_self, options) return options end }
end

local counts = { settings = 0, client = 0, worker = 0, downloader = 0, recover = 0 }
local fakes = {
    Settings = { new = function()
        counts.settings = counts.settings + 1
        return { data_dir = "/data/weread" }
    end },
    Client = { new = function(_self, settings)
        counts.client = counts.client + 1
        return { settings = settings }
    end },
    BackgroundWorker = { new = function(_self, options)
        counts.worker = counts.worker + 1
        return { options = options }
    end },
    Downloader = { new = function(_self, options)
        counts.downloader = counts.downloader + 1
        options.recover = function() counts.recover = counts.recover + 1 end
        return options
    end },
    preload_modules = { "weread.lib.runtime_spec_preload" },
}
local preloaded = 0
package.preload["weread.lib.runtime_spec_preload"] = function()
    preloaded = preloaded + 1
    return {}
end

local Runtime = require("weread.lib.runtime")
local first = Runtime.get(fakes)
local second = Runtime.get(fakes)
expect(first == second, "Runtime.get must return the process singleton")
expect(counts.settings == 1 and counts.client == 1 and counts.worker == 1
    and counts.downloader == 1, "services must be created once per process")
expect(first.client.settings == first.settings
    and first.downloader.settings == first.settings
    and first.downloader.client == first.client
    and first.downloader.background_worker == first.prefetch_worker,
    "services must share the one settings object")
expect(first.prefetch_worker.options.temp_dir == "/data/weread/workers",
    "background worker temp dir moved")
expect(preloaded == 1, "lazily required worker modules were not preloaded")

expect(first:recover() == true and first:recover() == false and counts.recover == 1,
    "recover must run once per process")
local once_runs = 0
first:once("migrations", function() once_runs = once_runs + 1 end)
first:once("migrations", function() once_runs = once_runs + 1 end)
expect(once_runs == 1, "once() ran twice")
local failing = 0
pcall(first.once, first, "flaky", function() failing = failing + 1; error("boom") end)
first:once("flaky", function() failing = failing + 1 end)
expect(failing == 2, "a failed once() must be retried")

-- Callback routing.
local function host(name)
    local calls = {}
    return {
        calls = calls,
        showInfo = function(_self, text) calls[#calls + 1] = name .. ":info:" .. text end,
        showTransientInfo = function(_self, text) calls[#calls + 1] = name .. ":transient:" .. text end,
        refreshUI = function() calls[#calls + 1] = name .. ":refresh_ui" end,
        refreshShelfCacheIndicators = function() calls[#calls + 1] = name .. ":refresh_shelf" end,
        openFile = function(_self, path) calls[#calls + 1] = name .. ":open:" .. path end,
        safeCallback = function(_self, _label, fn) return fn end,
        requireLogin = function() return name == "reader" end,
        runOnlineTask = function(_self, _label, fn) fn(); return true end,
        isNetworkConnected = function() return true end,
    }
end
local downloader = first.downloader
local filemanager = host("filemanager")
first:attach(filemanager)
downloader.show_info("started")
expect(filemanager.calls[1] == "filemanager:info:started", "attached host did not get callback")

-- FileManager closes when a book opens; the reader instance takes over.
expect(first:detach(filemanager) == true, "detach did not find the host")
downloader.show_transient("between instances")
expect(#filemanager.calls == 1, "a detached instance received a callback")
expect(shown[#shown] == "between instances", "fallback did not show the message")
expect(downloader.require_login(true, false) == false
    and downloader.run_online_task("x", function() error("must not run") end) == false
    and downloader.is_connected() == false,
    "fallbacks must refuse work that needs an attached UI")
local wrapped = downloader.safe_callback("label", function() error("swallowed") end)
wrapped()

local reader = host("reader")
first:attach(reader)
downloader.refresh_shelf()
downloader.open_file("/books/a.epub")
expect(reader.calls[1] == "reader:refresh_shelf" and reader.calls[2] == "reader:open:/books/a.epub",
    "callbacks did not follow the newly attached instance")
expect(downloader.require_login(true, false) == true, "return values must be forwarded")
expect(#filemanager.calls == 1, "closed FileManager instance kept receiving callbacks")

-- Stacked instances: closing the newest falls back to the previous one.
local other = host("other")
first:attach(other)
first:attach(other)
expect(#first.hosts == 2, "attaching twice must not duplicate the host")
first:detach(other)
downloader.refresh_ui()
expect(reader.calls[3] == "reader:refresh_ui", "detach did not restore the previous host")
first:detach(reader)
expect(first.host == nil, "host remained after all instances closed")

first:markRestartRequired("test")
expect(first.restart_required == true, "restart flag was not set")

Runtime._reset()
expect(Runtime.get(fakes) ~= first and counts.settings == 2, "_reset did not drop the singleton")

print(("runtime_spec: %d checks"):format(checks))
