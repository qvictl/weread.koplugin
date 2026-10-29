-- Shared stubs and fixtures for the ReadReport specs (weread/lib/read_report.lua).
-- Installs package.preload stubs for KOReader's logger and ffi/util and for
-- WeRead's content/protocol modules, then loads ReadReport. Require it
-- before anything else loads weread.lib.read_report.
local BookSettings = require("spec.helpers.book_settings")

local H = { logs = {} }

local function copy(value)
    local out = {}
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end
H.copy = copy

-- KOReader logger: every line is recorded so specs can assert on logging.
package.preload["logger"] = function()
    local function record(level)
        return function(...)
            local parts = {}
            for index = 1, select("#", ...) do
                parts[#parts + 1] = tostring((select(index, ...)))
            end
            H.logs[#H.logs + 1] = { level = level, text = table.concat(parts, " ") }
        end
    end
    return {
        dbg = record("dbg"), info = record("info"),
        warn = record("warn"), err = record("err"),
    }
end

-- Admission is exercised with fake OS children, so host memory must not
-- decide whether they launch. Each case restores even after an assertion.
function H.with_memory(fn)
    local memory = require("weread.lib.memory_gate")
    local read_memory = memory.read_meminfo
    memory.read_meminfo = function() return "MemAvailable: 1048576 kB\n" end
    local ok, err = pcall(fn)
    memory.read_meminfo = read_memory
    return ok, err
end

function H.clear_logs()
    H.logs = {}
end

function H.count_logs(level, needle)
    local count = 0
    for _i, entry in ipairs(H.logs) do
        if entry.level == level and entry.text:find(needle, 1, true) then
            count = count + 1
        end
    end
    return count
end

-- KOReader ffi/util: delegates to whatever fake runner H.ffi holds.
H.ffi = {}
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function(fn, with_pipe) return H.ffi.run(fn, with_pipe) end,
        writeToFD = function(fd, data, close) return H.ffi.write_all(fd, data, close) end,
        isSubProcessDone = function(pid) return H.ffi.is_done(pid) end,
        terminateSubProcess = function(pid) return H.ffi.terminate(pid) end,
        getNonBlockingReadSize = function(fd) return H.ffi.read_size(fd) end,
        readAllFromFD = function(fd) return H.ffi.read_all(fd) end,
    }
end

-- Content: reader page, catalog and catalog cache, all in memory.
H.content = {}
function H.reset_content()
    H.content = {
        cached = nil,          -- catalog.json contents (nil = no cache file)
        saved = {},            -- catalogs written to catalog.json
        save_error = nil,      -- make save_catalog_cache fail
        catalog = nil,         -- what fetch_catalog returns
        fetches = 0,
        reader_states = 0,
        psvts = "ps-fresh",
        pclts = nil,
    }
end
H.reset_content()

package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function() return nil end,
        load_catalog_cache = function(_client, _settings, book)
            local cached = H.content.cached
            if cached then book.chapters = cached end
            return cached
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            H.content.saved[#H.content.saved + 1] = chapters
            if H.content.save_error then return false, H.content.save_error end
            return true
        end,
        ensure_reader_state = function(_client, book)
            H.content.reader_states = H.content.reader_states + 1
            book.psvts = H.content.psvts
            book.pclts = H.content.pclts
            book.token = "token-fresh"
        end,
        fetch_catalog = function(_client, book)
            H.content.fetches = H.content.fetches + 1
            book.chapters = H.content.catalog
            return H.content.catalog
        end,
        first_readable_chapter = function(chapters)
            for _i, chapter in ipairs(chapters or {}) do
                if (tonumber(chapter.wordCount) or 0) > 0 then return chapter end
            end
        end,
    }
end

-- Protocol: payload builders return a copy of their options, tagged.
package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
        make_enter_read_payload = function(options)
            local payload = copy(options)
            payload.kind = "enter"
            return payload
        end,
        make_read_payload = function(options)
            local payload = copy(options)
            payload.kind = "report"
            return payload
        end,
        is_success_response = function(value, field)
            if type(value) ~= "table" then return false end
            local flag = value[field or "succ"]
            return flag == true or tonumber(flag) == 1
        end,
    }
end

H.ReadReport = require("weread.lib.read_report")

-- Minimal JSON for flat/nested tables with sorted keys; decode understands
-- what encode produced plus flat objects of strings and booleans (the
-- child's hand-written fallback outcome).
local function encode(value)
    local kind = type(value)
    if kind == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        local parts = {}
        for _i, key in ipairs(keys) do
            local item = value[key]
            if item == nil then item = value[tonumber(key)] end
            parts[#parts + 1] = string.format("%q", key) .. ":" .. encode(item)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif kind == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

function H.json(client)
    local decoded = {}
    client.json_encode = function(_self, value)
        local text = encode(value)
        decoded[text] = value
        return text
    end
    client.json_decode = function(_self, text)
        if decoded[text] then return decoded[text] end
        if text:sub(1, 1) ~= "{" then error("invalid json") end
        local out = {}
        for key, raw in text:gmatch('"([%w_]+)":([^,}]+)') do
            if raw == "true" or raw == "false" then
                out[key] = raw == "true"
            else
                out[key] = raw:match('^"(.*)"$') or raw
            end
        end
        return out
    end
    return client
end

function H.client()
    local client = {
        sent = {},
        responses = {},     -- queue: { result, code } or function(payload)
        web_progress = nil, -- nil: get_web_progress raises
        progress = nil,     -- nil: get_progress raises
    }
    function client:report_read(payload, url)
        payload.url = url
        self.sent[#self.sent + 1] = payload
        local response = table.remove(self.responses, 1)
        if type(response) == "function" then return response(payload) end
        if response then return response[1], response[2] end
        return { succ = 1 }, 200
    end
    function client:get_web_progress(_book_id)
        if self.web_progress == nil then error("Network is unreachable") end
        return self.web_progress
    end
    function client:get_progress(_book_id)
        if self.progress == nil then error("gateway unavailable") end
        return self.progress
    end
    function client:renew_cookie()
        if type(self.renew) == "function" then return self.renew() end
        return self.renew
    end
    return H.json(client)
end

function H.settings(opts)
    opts = opts or {}
    local settings = {
        config = opts.config or { enabled = true, mode = "auto", interval_seconds = 30 },
        store = {
            cookies = { wr_skey = "skey", wr_vid = "42" },
            wr_ticket = "ticket",
            wr_wrpa = "wrpa",
        },
        books = opts.books or {},
        flushes = 0,
        auth_updates = {},
        cookie_ok = true,
    }
    function settings:get(key, default)
        if key == "read_report" then return self.config end
        if key == "books" then return self.books end
        local value = self.store[key]
        if value == nil then return default end
        return value
    end
    function settings:set(key, value)
        if key == "read_report" then
            self.config = value
        elseif key == "books" then
            self.books = value
        else
            self.store[key] = value
        end
    end
    function settings:flush()
        self.flushes = self.flushes + 1
    end
    function settings:is_cookie_configured()
        return self.cookie_ok
    end
    function settings:update_auth(credentials, options)
        options = options or {}
        self.auth_updates[#self.auth_updates + 1] = { credentials = credentials, options = options }
        if credentials.cookies then self.store.cookies = credentials.cookies end
        if credentials.wr_ticket then self.store.wr_ticket = credentials.wr_ticket end
        if credentials.wr_wrpa then self.store.wr_wrpa = credentials.wr_wrpa end
        if options.flush ~= false then self:flush() end
    end
    if not opts.legacy then
        BookSettings.install(settings, settings.books)
    end
    return settings
end

-- Scheduler that only records; specs run due callbacks explicitly.
function H.scheduler()
    local scheduler = { queue = {}, unscheduled = 0 }
    function scheduler:scheduleIn(delay, fn)
        self.queue[#self.queue + 1] = { delay = delay, fn = fn }
    end
    function scheduler:unschedule(fn)
        self.unscheduled = self.unscheduled + 1
        for index = #self.queue, 1, -1 do
            if self.queue[index].fn == fn then table.remove(self.queue, index) end
        end
    end
    function scheduler:find(fn)
        for _i, entry in ipairs(self.queue) do
            if entry.fn == fn then return entry end
        end
    end
    -- Runs and removes the oldest entry; returns it.
    function scheduler:run_next()
        local entry = table.remove(self.queue, 1)
        if entry then entry.fn() end
        return entry
    end
    function scheduler:delays()
        local out = {}
        for _i, entry in ipairs(self.queue) do out[#out + 1] = entry.delay end
        return table.concat(out, ",")
    end
    return scheduler
end

-- In-process stand-in for a forked child: `finish()` runs the child body,
-- which writes its encoded outcome to the "pipe".
local runners = {}
function H.runner()
    local runner = { forks = 0, done = false, terminated = {}, reads = 0, pid = 100 }
    runners[#runners + 1] = runner
    function runner.run(child, with_pipe)
        runner.forks = runner.forks + 1
        runner.child = child
        runner.with_pipe = with_pipe
        if runner.fail then return false, runner.fail end
        runner.pid = runner.pid + 1
        return runner.pid, 7
    end
    function runner.write_all(_fd, data, close)
        runner.written = data
        runner.write_close = close
        return true
    end
    function runner.is_done(_pid) return runner.done end
    function runner.read_size(_fd) return runner.written and #runner.written or 0 end
    function runner.read_all(_fd)
        runner.reads = runner.reads + 1
        local data = runner.written
        runner.written = nil
        return data
    end
    function runner.terminate(pid) runner.terminated[#runner.terminated + 1] = pid end
    function runner.finish() runner.child(runner.pid, 7) end
    return runner
end

-- Independent cases finish their simulated OS sessions. Dropping a Lua job
-- alone does not mean that a process has exited or been reaped.
function H.finish_runners()
    for _, runner in ipairs(runners) do runner.done = true end
    require("weread.lib.fork_budget").available()
    runners = {}
end

-- Builds a ReadReport with a controllable clock, document, network state
-- and scheduler. Returns report, env.
function H.new_report(opts)
    opts = opts or {}
    local env = {
        clock = { t = opts.now or 1000 },
        book_id = opts.book_id == nil and "book" or opts.book_id,
        online = true,
        scheduler = H.scheduler(),
        settings = opts.settings or H.settings(opts),
        client = opts.client or H.client(),
    }
    if not opts.no_document then env.document = { file = "/book.epub" } end
    local report = H.ReadReport:new{
        settings = env.settings,
        client = env.client,
        scheduler = env.scheduler,
        library_db = opts.library_db,
        get_document = function() return env.document end,
        detect_book = function() return env.book_id end,
        position_provider = opts.position_provider,
        is_online = function() return env.online end,
        now = function() return env.clock.t end,
        subprocess = opts.subprocess,
        memory_gate = opts.memory_gate or function() return true, 500000 end,
    }
    if opts.inline then report.subprocess = nil end
    return report, env
end

-- A fully built reader context for `book_id` with an open reader session.
function H.ready_book(report, overrides)
    local book = {
        book_id = "book", title = "Book", chapter_uid = 5, chapter_idx = 1,
        chapter_offset = 0, progress = 1, summary = "", psvts = "ps", pclts = "pc",
        token = "tk", read_session_id = report.session_id, read_session_entered_at = 900,
    }
    for key, value in pairs(overrides or {}) do book[key] = value end
    return book
end

return H
