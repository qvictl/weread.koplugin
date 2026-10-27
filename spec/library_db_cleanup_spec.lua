-- LibraryDB must close statements and connections when SQLite raises while
-- stepping (busy or corrupt database); a leaked connection keeps a WAL read
-- lock and a file handle open for the rest of the session.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local opened, closed_dbs, closed_stmts = 0, 0, 0
local fail_on
local function new_stmt(sql)
    local stmt = {}
    function stmt:reset() return self end
    function stmt:bind() return self end
    function stmt:step()
        if fail_on and sql:find(fail_on, 1, true) then error("database is locked") end
        return nil
    end
    function stmt:close() closed_stmts = closed_stmts + 1 end
    return stmt
end
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function()
            opened = opened + 1
            return {
                exec = function() end,
                prepare = function(_self, sql) return new_stmt(sql) end,
                close = function() closed_dbs = closed_dbs + 1 end,
            }
        end,
    }
end

local LibraryDB = require("weread.lib.library_db")
local db = LibraryDB:new({
    data_dir = "/tmp/weread-library-cleanup",
    get = function(_self, key, default)
        if key == "account" then return { user_vid = "10001" } end
        return default
    end,
})

fail_on = "WHERE on_shelf=1"
local ok, shelf = pcall(db.getShelf, db)
expect(ok and shelf == nil, "getShelf must report failure instead of raising")
expect(closed_stmts == 1 and closed_dbs == opened,
    "getShelf leaked its statement or connection on a step error")

closed_stmts = 0
fail_on = "DELETE FROM chapters"
ok = db:putChapters("book", { { chapterUid = 1 } })
expect(ok == false, "putChapters must report the failed delete")
expect(closed_stmts == 1 and closed_dbs == opened,
    "putChapters leaked the delete statement or connection")

fail_on = nil
closed_stmts = 0
-- A successful read closes its statement. The connection may be kept open
-- for reuse, so allow at most one open connection, but never a leak.
expect(#db:getShelf() == 0 and closed_stmts == 1 and opened - closed_dbs <= 1,
    "a successful shelf read must close its statement and not leak connections")

print(("library_db_cleanup_spec: %d checks"):format(checks))
