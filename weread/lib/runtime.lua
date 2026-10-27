-- Process-level services shared by every WeRead plugin instance.
--
-- KOReader creates one plugin instance per FileManager and one per ReaderUI,
-- i.e. a new instance on every book open/close. Settings, the HTTP client,
-- the background worker and the downloader must not be duplicated per
-- instance: separate Settings copies flush stale in-memory state over each
-- other (lost cookie rotations, lost book records), separate downloaders let
-- two full-book downloads run at once, and a per-instance recover() deletes
-- the workspace of a download that is still running in the same process.
--
-- The runtime owns those services for the life of the Lua process. Plugin
-- instances attach() in init and detach() in onCloseWidget. The downloader's
-- UI callbacks are forwarded to the most recently attached instance, so a
-- download started in the FileManager keeps reporting to the reader that
-- replaced it, and a closed instance never receives callbacks.
local logger = require("weread.lib.logger")

local Runtime = {}
Runtime.__index = Runtime

-- Modules that are otherwise required lazily, mostly inside forked workers.
-- Loading them up front keeps a running process on one code version after an
-- in-place plugin update (which only takes effect after a restart).
Runtime.PRELOAD_MODULES = {
    "weread.lib.chapter_prefetch_worker",
    "weread.lib.annotation_prefetch_worker",
    "weread.lib.annotation_store",
}

local current

-- Downloader callback field -> host method, plus the behaviour used while no
-- plugin instance is attached (between FileManager close and ReaderUI init).
local function show_message(text, timeout)
    logger.info("message without attached plugin UI:", tostring(text))
    pcall(function()
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
    end)
end

local DOWNLOADER_CALLBACKS = {
    show_info = {
        method = "showInfo",
        fallback = function(text) show_message(text) end,
    },
    show_transient = {
        method = "showTransientInfo",
        fallback = function(text, timeout) show_message(text, timeout or 2) end,
    },
    refresh_ui = {
        method = "refreshUI",
        fallback = function()
            pcall(function() require("ui/uimanager"):forceRePaint() end)
        end,
    },
    refresh_shelf = {
        method = "refreshShelfCacheIndicators",
        fallback = function() end,
    },
    open_file = {
        method = "openFile",
        fallback = function(path)
            logger.warn("open file skipped without attached plugin UI:", tostring(path))
        end,
    },
    safe_callback = {
        method = "safeCallback",
        fallback = function(label, fn)
            return function(...)
                local ok, err = xpcall(fn, debug.traceback, ...)
                if not ok then logger.err("action failed:", tostring(label), tostring(err)) end
            end
        end,
    },
    require_login = {
        method = "requireLogin",
        fallback = function() return false end,
    },
    run_online_task = {
        method = "runOnlineTask",
        fallback = function(label)
            logger.warn("online task skipped without attached plugin UI:", tostring(label))
            return false
        end,
    },
    is_connected = {
        method = "isNetworkConnected",
        fallback = function() return false end,
    },
}

function Runtime:_forward(field)
    local spec = DOWNLOADER_CALLBACKS[field]
    return function(...)
        local host = self.host
        if host and type(host[spec.method]) == "function" then
            return host[spec.method](host, ...)
        end
        return spec.fallback(...)
    end
end

-- options (all optional; tests inject fakes):
--   Settings, Client, BackgroundWorker, Downloader  -- service classes
--   preload_modules                                 -- defaults to PRELOAD_MODULES
function Runtime.new(options)
    options = options or {}
    local Settings = options.Settings or require("weread.lib.settings")
    local Client = options.Client or require("weread.lib.client")
    local BackgroundWorker = options.BackgroundWorker or require("weread.lib.background_worker")
    local Downloader = options.Downloader or require("weread.lib.downloader")

    local runtime = setmetatable({ hosts = {}, host = nil, _done = {} }, Runtime)
    runtime.settings = Settings:new()
    runtime.client = Client:new(runtime.settings)
    runtime.prefetch_worker = BackgroundWorker:new{
        temp_dir = runtime.settings.data_dir .. "/workers",
        -- A soft launch gate, not a reservation: fork uses copy-on-write and
        -- normally consumes far less than this on a 512 MB Kindle.
        min_available_kb = 64 * 1024,
    }
    local downloader_options = {
        client = runtime.client,
        settings = runtime.settings,
        background_worker = runtime.prefetch_worker,
    }
    for field in pairs(DOWNLOADER_CALLBACKS) do
        downloader_options[field] = runtime:_forward(field)
    end
    runtime.downloader = Downloader:new(downloader_options)

    for _i, name in ipairs(options.preload_modules or Runtime.PRELOAD_MODULES) do
        local ok, err = pcall(require, name)
        if not ok then logger.warn("runtime preload failed:", name, tostring(err)) end
    end
    return runtime
end

-- The process singleton; created on first use.
function Runtime.get(options)
    if not current then
        current = Runtime.new(options)
    end
    return current
end

-- Tests only: forget the singleton so the next get() builds a fresh one.
function Runtime._reset()
    current = nil
end

-- Runs fn once per process. A failure propagates and is retried on the next
-- call, matching the previous per-init behaviour.
function Runtime:once(name, fn)
    if self._done[name] then return false end
    fn()
    self._done[name] = true
    return true
end

-- Removes download artifacts left by a previous (killed) process. Only valid
-- once per process: later plugin instances share the live downloader, whose
-- workspaces must not be deleted under it.
function Runtime:recover()
    return self:once("recover", function()
        if self.downloader and self.downloader.recover then
            self.downloader:recover()
        end
    end)
end

function Runtime:attach(host)
    self:detach(host)
    table.insert(self.hosts, host)
    self.host = host
end

function Runtime:detach(host)
    local removed = false
    for i = #self.hosts, 1, -1 do
        if self.hosts[i] == host then
            table.remove(self.hosts, i)
            removed = true
        end
    end
    self.host = self.hosts[#self.hosts]
    return removed
end

-- Set when a plugin update was installed into the plugin directory by this
-- process. Code that would lazily load modules (downloads, prefetch) can
-- check it and ask for a restart instead of mixing old and new modules.
function Runtime:markRestartRequired(reason)
    if not self.restart_required then
        logger.info("plugin restart required:", tostring(reason or "update installed"))
    end
    self.restart_required = true
end

return Runtime
