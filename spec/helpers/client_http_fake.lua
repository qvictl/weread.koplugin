-- Deterministic stand-ins for LuaSocket, socketutil, KOReader's logger and the
-- JSON module, shared by the weread.lib.client specs. install() must run before
-- the first require("weread.lib.client").
--
-- Scripted responses (state.responses, consumed in order):
--   { code = 200, body = "..." | chunks = { ... }, headers = { ... }, status = "..." }
--   { raise = "message" }   -- http.request throws (e.g. TLS/socket failure)
--   { fail = "timeout" }    -- http.request returns nil, "timeout"
-- Every request is recorded in state.requests with a snapshot of its headers,
-- the body produced by its ltn12 source and whether a socket timeout was active.
local M = {}

local function copy(value)
    local out = {}
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end

function M.install()
    local state = {
        requests = {},
        responses = {},
        timeouts = {},
        resets = 0,
        timeout_active = false,
        logs = {},
        sleeps = {},
        encoded = {},
        json_docs = {},
    }

    -- Registers a decoded value and returns the JSON-looking text the fake
    -- decoder maps back to it. Unregistered text fails to decode.
    function state.json(value)
        state.doc_count = (state.doc_count or 0) + 1
        local text = '{"doc":' .. state.doc_count .. "}"
        state.json_docs[text] = value
        return text
    end

    function state.log_text()
        return table.concat(state.logs, "\n")
    end

    function state.reset()
        state.requests, state.responses, state.logs, state.sleeps = {}, {}, {}, {}
        state.timeouts, state.resets, state.encoded = {}, 0, {}
    end

    package.preload["ltn12"] = function()
        return {
            source = {
                string = function(value)
                    local done = false
                    return function()
                        if done then return nil end
                        done = true
                        return value
                    end
                end,
            },
        }
    end
    package.preload["logger"] = function()
        local function capture(level, ...)
            local parts = { level }
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring(select(i, ...))
            end
            state.logs[#state.logs + 1] = table.concat(parts, " ")
        end
        return {
            dbg = function(...) capture("dbg", ...) end,
            info = function(...) capture("info", ...) end,
            warn = function(...) capture("warn", ...) end,
            err = function(...) capture("error", ...) end,
        }
    end
    package.preload["socketutil"] = function()
        return {
            set_timeout = function(_self, block, total)
                state.timeouts[#state.timeouts + 1] = { block, total }
                state.timeout_active = true
            end,
            reset_timeout = function()
                state.resets = state.resets + 1
                state.timeout_active = false
            end,
            table_sink = function(target)
                return function(chunk)
                    if chunk then target[#target + 1] = chunk end
                    return 1
                end
            end,
        }
    end
    package.preload["socket"] = function()
        return { sleep = function(seconds) state.sleeps[#state.sleeps + 1] = seconds end }
    end
    package.preload["socket.http"] = function()
        return {
            request = function(options)
                local record = {
                    method = options.method,
                    url = options.url,
                    headers = copy(options.headers),
                    redirect = options.redirect,
                    proxy = options.proxy,
                    body = options.source and options.source() or nil,
                    options = options,
                    timeout_active = state.timeout_active,
                    timeout = state.timeouts[#state.timeouts],
                }
                state.requests[#state.requests + 1] = record
                local response = table.remove(state.responses, 1)
                if not response then
                    error("unexpected HTTP request to " .. tostring(options.url), 0)
                end
                if response.raise then error(response.raise, 0) end
                if response.fail then return nil, response.fail end
                if options.sink then
                    for _, chunk in ipairs(response.chunks or { response.body or "" }) do
                        local accepted, sink_err = options.sink(chunk)
                        if not accepted then return nil, sink_err end
                    end
                    options.sink(nil)
                end
                return 1, response.code, response.headers or {}, response.status
            end,
        }
    end
    package.preload["json"] = function()
        return {
            encode = function(value)
                state.encoded[#state.encoded + 1] = value
                return "<encoded#" .. #state.encoded .. ">"
            end,
            decode = function(text)
                local value = state.json_docs[text]
                if value == nil then error("invalid JSON", 0) end
                return value
            end,
        }
    end
    -- weread.lib.mock_environment loads these at require time; only
    -- endpoint() is used by the client, which needs neither.
    package.preload["datastorage"] = package.preload["datastorage"] or function() return {} end
    package.preload["luasettings"] = package.preload["luasettings"] or function() return {} end

    return state
end

-- Minimal settings double: get() with defaults, plus the two credential
-- writers the client may call, both recorded.
function M.settings(values)
    local settings = { values = values or {}, merged = {}, auth_updates = {} }
    function settings:get(key, default)
        local value = self.values[key]
        if value == nil then return default end
        return value
    end
    function settings:merge_set_cookie(value)
        self.merged[#self.merged + 1] = value
    end
    function settings:update_auth(credentials, options)
        self.auth_updates[#self.auth_updates + 1] = { credentials = credentials, options = options }
    end
    return settings
end

-- Case-insensitive header lookup that also reports how many spellings exist.
function M.header(headers, name)
    local found, count = nil, 0
    for key, value in pairs(headers or {}) do
        if type(key) == "string" and key:lower() == name:lower() then
            found, count = value, count + 1
        end
    end
    return found, count
end

return M
