-- Minimal stand-in for KOReader's lua-ljsqlite3 on top of the system SQLite
-- library (CI installs libsqlite3-0). It mirrors the parts of the real binding
-- that the plugin uses, including its value mapping: Lua numbers bind as
-- doubles, strings as text, nil as NULL; INTEGER columns come back as int64
-- cdata, REAL as numbers, TEXT as strings and NULL as nil. Errors are raised.
-- Keep the system SQLite FFI bridge interpreted on macOS ARM.
require("jit").off()
local ffi = require("ffi")
ffi.cdef[[
typedef struct sqlite3 sqlite3; typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open(const char*, sqlite3**); int sqlite3_close(sqlite3*);
int sqlite3_exec(sqlite3*, const char*, void*, void*, char**);
const char *sqlite3_errmsg(sqlite3*);
int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void*);
int sqlite3_bind_double(sqlite3_stmt*, int, double);
int sqlite3_bind_int64(sqlite3_stmt*, int, int64_t);
int sqlite3_bind_null(sqlite3_stmt*, int);
int sqlite3_step(sqlite3_stmt*); int sqlite3_reset(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt*); int sqlite3_column_count(sqlite3_stmt*);
int sqlite3_column_type(sqlite3_stmt*, int);
int64_t sqlite3_column_int64(sqlite3_stmt*, int);
double sqlite3_column_double(sqlite3_stmt*, int);
int sqlite3_column_bytes(sqlite3_stmt*, int);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int);
]]
local loaded, sql = pcall(ffi.load, "sqlite3")
if not loaded then sql = ffi.load("libsqlite3.so.0") end

local SQLITE_ROW, SQLITE_DONE = 100, 101
local TRANSIENT = ffi.cast("void*", -1)
local int64_ct = ffi.typeof("int64_t")

local M = { opened = 0, closed = 0 }

function M.open(path)
    local handle = ffi.new("sqlite3 *[1]")
    local rc = sql.sqlite3_open(path, handle)
    if rc ~= 0 then
        local msg = handle[0] ~= nil and ffi.string(sql.sqlite3_errmsg(handle[0])) or tostring(rc)
        if handle[0] ~= nil then sql.sqlite3_close(handle[0]) end
        error("sqlite open failed: " .. msg)
    end
    M.opened = M.opened + 1
    local conn = { ptr = handle[0] }
    local function check(rc_value)
        if rc_value ~= 0 and rc_value ~= SQLITE_ROW and rc_value ~= SQLITE_DONE then
            error(ffi.string(sql.sqlite3_errmsg(conn.ptr)))
        end
        return rc_value
    end
    function conn:exec(query)
        assert(self.ptr, "connection closed")
        check(sql.sqlite3_exec(self.ptr, query, nil, nil, nil))
    end
    function conn:close()
        if self.ptr then
            check(sql.sqlite3_close(self.ptr))
            self.ptr = nil
            M.closed = M.closed + 1
        end
    end
    function conn.prepare(connection, query)
        assert(connection.ptr, "connection closed")
        local out = ffi.new("sqlite3_stmt *[1]")
        check(sql.sqlite3_prepare_v2(connection.ptr, query, -1, out, nil))
        local stmt = { ptr = out[0], done = false }
        function stmt:reset()
            sql.sqlite3_reset(self.ptr)
            self.done = false
            return self
        end
        function stmt:bind(...)
            for index = 1, select("#", ...) do
                local value = select(index, ...)
                local rc_value
                if ffi.istype(int64_ct, value) then
                    rc_value = sql.sqlite3_bind_int64(self.ptr, index, value)
                elseif type(value) == "number" then
                    rc_value = sql.sqlite3_bind_double(self.ptr, index, value)
                elseif type(value) == "string" then
                    rc_value = sql.sqlite3_bind_text(self.ptr, index, value, #value, TRANSIENT)
                elseif value == nil then
                    rc_value = sql.sqlite3_bind_null(self.ptr, index)
                else
                    error("unexpected Lua type")
                end
                check(rc_value)
            end
            return self
        end
        function stmt:step()
            if self.done then return nil end
            local rc_value = check(sql.sqlite3_step(self.ptr))
            if rc_value ~= SQLITE_ROW then
                self.done = true
                return nil
            end
            local row = {}
            for col = 0, sql.sqlite3_column_count(self.ptr) - 1 do
                local kind = sql.sqlite3_column_type(self.ptr, col)
                if kind == 1 then
                    row[col + 1] = sql.sqlite3_column_int64(self.ptr, col)
                elseif kind == 2 then
                    row[col + 1] = sql.sqlite3_column_double(self.ptr, col)
                elseif kind == 5 then
                    row[col + 1] = nil
                else
                    row[col + 1] = ffi.string(sql.sqlite3_column_text(self.ptr, col),
                        sql.sqlite3_column_bytes(self.ptr, col))
                end
            end
            return row
        end
        function stmt:close()
            if self.ptr then
                sql.sqlite3_finalize(self.ptr)
                self.ptr = nil
            end
        end
        return stmt
    end
    return conn
end

-- Run a query and return every row (convenience for assertions).
function M.rows(conn, query, ...)
    local stmt = conn:prepare(query)
    stmt:bind(...)
    local rows = {}
    local row = stmt:step()
    while row do
        rows[#rows + 1] = row
        row = stmt:step()
    end
    stmt:close()
    return rows
end

-- Make a fresh empty directory under the system temp location.
function M.tempdir()
    local path = os.tmpname()
    os.remove(path)
    assert(os.execute("mkdir -p '" .. path .. "'"))
    return path
end

function M.rmtree(path)
    if type(path) == "string" and path:match("^/tmp/") then
        os.execute("rm -rf '" .. path .. "'")
    end
end

function M.exists(path)
    local file = io.open(path, "rb")
    if file then file:close() return true end
    return false
end

-- KOReader lfs stub that creates real directories.
function M.lfs()
    return {
        mkdir = function(path)
            return os.execute("mkdir -p '" .. path .. "' 2>/dev/null")
        end,
    }
end

return M
