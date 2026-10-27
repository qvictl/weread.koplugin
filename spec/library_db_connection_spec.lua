-- The library database keeps one connection per process: the schema runs
-- once, reads that fail mid-step do not leak handles, a failed operation
-- starts over with a fresh connection, and a forked child never touches the
-- parent's handle.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local opened, closed, execs, prepared = {}, {}, {}, {}
local rows_by_sql = {}
local step_error

local function fake_statement(db, sql)
    local stmt = { sql = sql, closed = false, index = 0 }
    prepared[#prepared + 1] = stmt
    function stmt:reset() self.index = 0 return self end
    function stmt:bind() return self end
    function stmt:step()
        assert(not db.closed, "statement stepped on a closed connection")
        if step_error and sql:find(step_error, 1, true) and self.index >= 1 then
            error("disk I/O error")
        end
        self.index = self.index + 1
        for pattern, rows in pairs(rows_by_sql) do
            if sql:find(pattern, 1, true) then return rows[self.index] end
        end
        return nil
    end
    function stmt:close() self.closed = true end
    return stmt
end

package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(path)
            local db = { path = path, closed = false }
            opened[#opened + 1] = db
            function db:exec(sql)
                assert(not self.closed, "exec on a closed connection")
                execs[#execs + 1] = sql
            end
            function db:prepare(sql)
                assert(not self.closed, "prepare on a closed connection")
                return fake_statement(self, sql)
            end
            function db:close()
                self.closed = true
                closed[#closed + 1] = self
            end
            return db
        end,
    }
end
-- Minimal JSON double: payloads in this spec are flat {"key":value} objects.
package.preload["json"] = function()
    return {
        encode = function() return "{}" end,
        decode = function(text)
            local result = {}
            for key, value in text:gmatch('"([^"]+)":"?([^",}]+)"?') do result[key] = value end
            return result
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end

local LibraryDB = require("weread.lib.library_db")
local pid = 100
LibraryDB._getpid = function() return pid end

local account = { user_vid = "1" }
local settings = {
    data_dir = "/tmp/weread-db-test",
    get = function(_self, key, default)
        if key == "account" then return account end
        return default
    end,
}

local function count(list, pattern)
    local n = 0
    for _i, value in ipairs(list) do
        if value:find(pattern, 1, true) then n = n + 1 end
    end
    return n
end

rows_by_sql["FROM chapters"] = { { '{"chapterUid":1}' }, { '{"chapterUid":2}' } }
rows_by_sql["FROM books WHERE book_id"] = {}

-- Repeated operations, across plugin instances, share one connection and
-- run the schema once.
local first = LibraryDB:new(settings)
local second = LibraryDB:new(settings)
expect(#(first:getChapters("b") or {}) == 2, "chapters were not read")
first:getChapters("b")
second:getBook("b")
second:putBook({ bookId = "b", title = "T" })
expect(#opened == 1, "operations opened " .. #opened .. " connections")
expect(#closed == 0, "a successful operation closed the shared connection")
expect(count(execs, "journal_mode") == 1 and count(execs, "CREATE TABLE IF NOT EXISTS books") == 1,
    "schema ran more than once")
for _i, stmt in ipairs(prepared) do
    expect(stmt.closed, "statement leaked: " .. stmt.sql)
end

-- A failing step inside a read loop is contained: no error escapes, the
-- statement is closed and the next call reopens a clean connection.
rows_by_sql["on_shelf=1"] = { { '{"bookId":"1"}' }, { '{"bookId":"2"}' } }
step_error = "on_shelf=1"
local ok, shelf = pcall(first.getShelf, first)
expect(ok and shelf == nil, "a stepping error escaped getShelf")
expect(prepared[#prepared].closed, "getShelf leaked its statement")
expect(#closed == 1 and closed[1] == opened[1], "failed read kept the broken connection")
step_error = nil
first:getChapters("b")
expect(#opened == 2 and not opened[2].closed, "next call did not reopen a fresh connection")
expect(count(execs, "journal_mode") == 2, "schema was not re-checked after a failure")

-- Switching accounts closes the old database and opens the new one.
account = { user_vid = "2" }
first:getChapters("b")
expect(#opened == 3 and opened[2].closed and opened[3].path ~= opened[2].path,
    "account switch reused the previous account database")

-- A forked child neither uses nor closes the parent's connection.
local parent_db = opened[3]
pid = 200
first:getChapters("b")
expect(#opened == 4 and opened[4] ~= parent_db, "child reused the parent's connection")
expect(not parent_db.closed, "child closed the parent's connection")

-- Explicit close only closes this process' connection.
first:close()
expect(opened[4].closed, "close did not close the current connection")

-- Without an identified account nothing is opened.
account = { user_vid = "" }
local before = #opened
expect(first:getChapters("b") == nil and #opened == before, "logged-out state opened a database")

print(("library_db_connection_spec: %d checks"):format(checks))
