-- Emulator scenario harness. Loaded once per KOReader process by the
-- wereadtest.koplugin driver; runs WEREAD_TEST_SCENARIO as a coroutine on the
-- real UIManager loop of a real KOReader (reader.lua) with the candidate
-- weread.koplugin installed in an isolated KO_HOME.
--
-- Scenario files return function(H) ... end. Everything that touches the
-- plugin or widgets should go through H.call/H.tap* so it runs on the UI loop
-- exactly like a user event, never inside the scenario coroutine (plugin code
-- uses Trapper coroutines of its own).
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local H = {}

local env = {
    scenario = os.getenv("WEREAD_TEST_SCENARIO"),
    result = os.getenv("WEREAD_TEST_RESULT"),
    evidence = os.getenv("WEREAD_TEST_EVIDENCE"),
    mock = os.getenv("WEREAD_MOCK_URL"),
    timeout = tonumber(os.getenv("WEREAD_TEST_TIMEOUT")) or 240,
}
H.env = env

local started = false
local finished = false
local co
local result = {
    scenario = env.scenario and env.scenario:match("([^/]+)%.lua$") or "unknown",
    ok = false,
    steps = {},
    metrics = {},
    screenshots = {},
}
H.result = result
H.metrics = result.metrics
local clock0 = time.now()

local function now_ms()
    return time.to_ms(time.now() - clock0)
end
H.now_ms = now_ms

function H.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = "[SCENARIO " .. string.format("%7.2fs", now_ms() / 1000) .. "] " .. table.concat(parts, " ")
    io.stdout:write(line, "\n")
    io.stdout:flush()
end

-- ---------------------------------------------------------------- results

local function encode_json(value)
    local ok, json = pcall(require, "json")
    if ok and json and json.encode then
        local enc_ok, out = pcall(json.encode, value)
        if enc_ok then return out end
    end
    return '{"ok":false,"error":"result encoding failed"}'
end

local function write_result()
    if not env.result then return end
    result.duration_ms = now_ms()
    local file = io.open(env.result, "w")
    if file then
        file:write(encode_json(result))
        file:close()
    end
end

local function finish(ok, err)
    if finished then return end
    finished = true
    result.ok = ok
    if err then
        result.error = tostring(err)
        H.log("FAIL:", result.error)
        pcall(H.shot, "failure")
    else
        H.log("PASS")
    end
    write_result()
    -- Give pending repaints a moment, then leave with a meaningful status.
    UIManager:scheduleIn(0.3, function()
        UIManager:quit(ok and 0 or 1)
    end)
end

-- ------------------------------------------------------- coroutine control

local function resume(...)
    if finished or not co or coroutine.status(co) ~= "suspended" then return end
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        finish(false, debug.traceback(co, err))
    elseif coroutine.status(co) == "dead" then
        finish(true)
    end
end

local function in_scenario()
    return co ~= nil and coroutine.running() == co
end

--- Sleeps in the scenario while the real UI loop keeps running.
function H.sleep(seconds)
    assert(in_scenario(), "H.sleep must be called from the scenario")
    local token = {}
    local function wake() resume(token) end
    UIManager:scheduleIn(seconds, wake)
    while true do
        local got = coroutine.yield()
        if got == token then return end
    end
end

--- Runs fn on the UI loop (outside the scenario coroutine) and returns its
-- results. Errors are re-raised in the scenario with the UI-side traceback.
function H.call(fn, ...)
    assert(in_scenario(), "H.call must be called from the scenario")
    local args = { n = select("#", ...), ... }
    local token = {}
    local packed
    UIManager:scheduleIn(0, function()
        packed = { xpcall(function() return fn(unpack(args, 1, args.n)) end, debug.traceback) }
        resume(token)
    end)
    while true do
        local got = coroutine.yield()
        if got == token and packed then break end
    end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2, table.maxn(packed))
end

--- Polls pred (run on the UI loop) until it returns a truthy value.
function H.wait_until(description, pred, timeout, interval)
    timeout = timeout or 20
    interval = interval or 0.2
    local deadline = now_ms() + timeout * 1000
    while true do
        local value = H.call(pred)
        if value then return value end
        if now_ms() > deadline then
            error("timed out after " .. tostring(timeout) .. "s waiting for: " .. description, 0)
        end
        H.sleep(interval)
    end
end

function H.check(condition, message, ...)
    if not condition then
        local extra = select("#", ...) > 0 and (" " .. table.concat({ ... }, " ")) or ""
        error("check failed: " .. tostring(message) .. extra, 2)
    end
    return condition
end

function H.equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("check failed: %s (expected %s, got %s)",
            tostring(message), tostring(expected), tostring(actual)), 2)
    end
end

--- Named, timed step; failures name the step.
function H.step(name, fn)
    H.log("STEP", name)
    local entry = { name = name, started_ms = now_ms() }
    table.insert(result.steps, entry)
    local ok, err = pcall(fn)
    entry.ms = now_ms() - entry.started_ms
    entry.ok = ok
    if not ok then
        error("[" .. name .. "] " .. tostring(err), 0)
    end
    H.log("STEP", name, "ok", string.format("%.0fms", entry.ms))
end

function H.metric(name, value)
    result.metrics[name] = value
    H.log("METRIC", name, "=", tostring(value))
end

-- ------------------------------------------------------------ screen/UI

function H.screen()
    return require("device").screen
end

function H.shot(name)
    if not env.evidence then return end
    local path = env.evidence .. "/" .. name .. ".png"
    local ok = pcall(function()
        UIManager:forceRePaint()
        H.screen():shot(path)
    end)
    if ok then table.insert(result.screenshots, name .. ".png") end
    return ok and path or nil
end

function H.file_manager()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    return ok and FileManager.instance or nil
end

function H.reader()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance or nil
end

--- The weread plugin instance of the active UI (reader if open).
function H.plugin()
    local ui = H.reader() or H.file_manager()
    return ui and ui.weread or nil
end

function H.runtime()
    return require("weread.lib.runtime").get()
end

function H.tr(text)
    return require("weread.lib.i18n").tr(text)
end

function H.windows()
    local out = {}
    for i = #UIManager._window_stack, 1, -1 do
        out[#out + 1] = UIManager._window_stack[i].widget
    end
    return out
end

function H.top_window()
    local stack = UIManager._window_stack
    return stack[#stack] and stack[#stack].widget or nil
end

local function walk(widget, visit, seen, depth, chain)
    if type(widget) ~= "table" or seen[widget] or depth > 80 then return nil end
    seen[widget] = true
    chain[depth] = widget
    local found = visit(widget, chain, depth)
    if found then return found end
    for _i, child in ipairs(widget) do
        found = walk(child, visit, seen, depth + 1, chain)
        if found then return found end
    end
    return nil
end

--- Visits every widget reachable through container array slots of every
-- window, top-most first. visit(widget, ancestors, depth) returns a value
-- to stop.
function H.walk(visit, root)
    local roots = root and { root } or H.windows()
    for _i, window in ipairs(roots) do
        local found = walk(window, visit, {}, 1, {})
        if found then return found end
    end
    return nil
end

local function widget_text(widget)
    local text = rawget(widget, "text")
    if type(text) == "string" then return text end
    return nil
end

--- All visible texts (deduplicated, in traversal order) of a window.
function H.texts(root)
    local out, seen = {}, {}
    H.walk(function(widget)
        local text = widget_text(widget)
        if text and not seen[text] then
            seen[text] = true
            out[#out + 1] = text
        end
    end, root)
    return out
end

local function has_dimen(widget)
    local d = rawget(widget, "dimen")
    return type(d) == "table" and type(d.x) == "number" and type(d.w) == "number"
        and d.w > 0 and d.h > 0
end

--- Finds the first widget whose text contains needle (plain find). Returns
-- the widget and its nearest ancestor-or-self with a painted dimen.
function H.find_text(needle, root)
    local hit, target
    H.walk(function(widget, chain, depth)
        local text = widget_text(widget)
        if text and text:find(needle, 1, true) then
            hit = widget
            for i = depth, 1, -1 do
                if has_dimen(chain[i]) then
                    target = chain[i]
                    break
                end
            end
            return true
        end
    end, root)
    return hit, target
end

function H.has_text(needle, root)
    return H.find_text(needle, root) ~= nil
end

function H.screen_text()
    return table.concat(H.texts(), " | ")
end

--- Sends a real tap gesture through UIManager event dispatch.
function H.tap_at(x, y)
    return H.call(function()
        local ges = {
            ges = "tap",
            pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
            time = time.now(),
        }
        UIManager:sendEvent(Event:new("Gesture", ges))
        return true
    end)
end

local function center(dimen)
    return math.floor(dimen.x + dimen.w / 2), math.floor(dimen.y + dimen.h / 2)
end

--- Taps the painted element showing needle; waits for it first.
function H.tap_text(needle, timeout)
    local target = H.wait_until("text '" .. needle .. "' painted", function()
        local _hit, painted = H.find_text(needle)
        return painted
    end, timeout or 15)
    local x, y = center(target.dimen)
    H.log("tap", needle, "@", x, y)
    return H.tap_at(x, y)
end

--- Waits until the screen shows needle somewhere.
function H.wait_text(needle, timeout)
    return H.wait_until("text '" .. needle .. "'", function()
        return H.has_text(needle)
    end, timeout or 20)
end

--- Closes every window above the FileManager/ReaderUI (dialogs, menus).
function H.close_dialogs()
    return H.call(function()
        local base = H.reader() or H.file_manager()
        for _i = 1, 30 do
            local top = H.top_window()
            if not top or top == base then break end
            UIManager:close(top)
        end
        UIManager:forceRePaint()
        return true
    end)
end

function H.broadcast(name, ...)
    local args = { n = select("#", ...), ... }
    return H.call(function()
        UIManager:broadcastEvent(Event:new(name, unpack(args, 1, args.n)))
        return true
    end)
end

-- --------------------------------------------------------------- mock

local function http_request(method, path, body)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local chunks = {}
    local req = {
        url = env.mock .. path,
        method = method,
        sink = ltn12.sink.table(chunks),
        headers = { ["Content-Type"] = "application/json" },
    }
    if body then
        req.source = ltn12.source.string(body)
        req.headers["Content-Length"] = tostring(#body)
    end
    -- A direct connection to the local mock; never a global proxy.
    local old_proxy = http.PROXY
    http.PROXY = nil
    local _ok, code = http.request(req)
    http.PROXY = old_proxy
    local text = table.concat(chunks)
    local decoded
    pcall(function() decoded = require("json").decode(text) end)
    return code, decoded or text
end

function H.mock_control(values)
    local code = http_request("POST", "/__control", require("json").encode(values))
    H.check(code == 200, "mock control accepted", tostring(code))
end

function H.mock_post(path, values)
    return http_request("POST", path, require("json").encode(values or {}))
end

function H.mock_state()
    local code, state = http_request("GET", "/__state")
    H.check(code == 200 and type(state) == "table", "mock state readable")
    return state
end

function H.mock_requests(filter)
    local out = {}
    for _i, event in ipairs(H.mock_state().requests or {}) do
        if not filter or filter(event) then out[#out + 1] = event end
    end
    return out
end

-- ------------------------------------------------------------ process info

function H.rss_kb()
    local file = io.open("/proc/self/status", "r")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return tonumber(data:match("VmRSS:%s*(%d+)%s*kB"))
end

function H.lua_kb()
    return collectgarbage("count")
end

function H.file_exists(path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "mode") == "file"
end

function H.find_files(dir, pattern)
    local lfs = require("libs/libkoreader-lfs")
    local out = {}
    local function scan(path)
        if lfs.attributes(path, "mode") ~= "directory" then return end
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local full = path .. "/" .. name
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    scan(full)
                elseif mode == "file" and (not pattern or name:find(pattern)) then
                    out[#out + 1] = full
                end
            end
        end
    end
    scan(dir)
    table.sort(out)
    return out
end

--- Replaces a local upvalue table's contents (test-only time compression,
-- e.g. a retry schedule). Returns the previous contents.
function H.patch_upvalue_table(fn, name, values)
    for i = 1, 200 do
        local upname, value = debug.getupvalue(fn, i)
        if not upname then break end
        if upname == name and type(value) == "table" then
            local previous = {}
            for k, v in pairs(value) do previous[k] = v end
            for k in pairs(previous) do value[k] = nil end
            for k, v in pairs(values) do value[k] = v end
            return previous
        end
    end
    error("upvalue " .. tostring(name) .. " not found")
end

-- ------------------------------------------------------------- startup

local function start()
    if started then return end
    started = true
    H.log("scenario", tostring(env.scenario), "mock", tostring(env.mock))
    if not env.scenario then return end
    local chunk, load_err = loadfile(env.scenario)
    if not chunk then
        finish(false, "cannot load scenario: " .. tostring(load_err))
        return
    end
    local ok, scenario = pcall(chunk)
    if not ok or type(scenario) ~= "function" then
        finish(false, "scenario must return function(H): " .. tostring(scenario))
        return
    end
    UIManager:scheduleIn(env.timeout, function()
        finish(false, "scenario watchdog: exceeded " .. tostring(env.timeout) .. "s")
    end)
    co = coroutine.create(function()
        -- First-run KOReader notices (e.g. "book info cache updated") would
        -- swallow the scenario's first tap.
        H.close_dialogs()
        scenario(H)
    end)
    resume()
end

--- Called by every driver plugin instance (FileManager and ReaderUI).
function H.attach(ui)
    H.last_ui = ui
    if not started then
        -- Let the FileManager finish its first paint before acting.
        UIManager:scheduleIn(1, start)
    end
end

logger.dbg("weread emulator harness loaded")

return H
