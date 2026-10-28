-- Thought databases must create missing parent directories and stop before
-- SQLite is opened when directory creation fails.
-- Run from the repository root: luajit spec/thought_db_open_spec.lua
local old_path = package.path
package.path = "./?.lua;./?/init.lua;" .. package.path

local modules = { "weread.lib.thought_db", "weread.lib.logger", "util", "lua-ljsqlite3/init" }
local saved = {}
for _, name in ipairs(modules) do
    saved[name] = { loaded = package.loaded[name], preload = package.preload[name] }
    package.loaded[name] = nil
end

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    assert(condition, message)
end

local ok, err = xpcall(function()
    local warnings, directories, opened = {}, {}, {}
    local mkdir_ok, mkdir_error = true, nil
    local database = { exec = function() end }
    package.preload["weread.lib.logger"] = function()
        return {
            info = function() end,
            warn = function(...) warnings[#warnings + 1] = { ... } end,
        }
    end
    package.preload["util"] = function()
        return { makePath = function(path)
            directories[#directories + 1] = path
            return mkdir_ok, mkdir_error
        end }
    end
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function(path)
            opened[#opened + 1] = path
            return database
        end }
    end
    local ThoughtDB = require("weread.lib.thought_db")
    for _, value in ipairs({ false, 42, {}, "" }) do
        expect(ThoughtDB.open(value) == nil, "invalid directory must be rejected")
    end
    expect(ThoughtDB.open(nil) == nil, "missing directory must be rejected")
    expect(#directories == 0 and #opened == 0, "invalid input must not touch storage")

    local nested = "/cache/new-parent/new-book"
    expect(ThoughtDB.open(nested) == database, "missing parents must use recursive directory creation")
    expect(directories[1] == nested and opened[1] == nested .. "/thoughts.db",
        "database must be opened in the requested directory")
    expect(ThoughtDB.open(nested) == database, "an existing book directory must still open")

    for _, failure in ipairs({ { nil, "Permission denied" }, { false, "Not a directory" } }) do
        mkdir_ok, mkdir_error = failure[1], failure[2]
        local open_count, warning_count = #opened, #warnings
        expect(ThoughtDB.open(nested) == nil, "directory failure must return nil")
        expect(#opened == open_count, "directory failure must not attempt to open SQLite")
        local warning = warnings[#warnings]
        expect(#warnings == warning_count + 1 and warning[1] == "thought_db directory creation failed:"
                and warning[2] == nested and warning[3] == mkdir_error,
            "directory failure must log its path and cause")
    end
end, debug.traceback)

for _, name in ipairs(modules) do
    package.loaded[name] = saved[name].loaded
    package.preload[name] = saved[name].preload
end
package.path = old_path
if not ok then error(err, 0) end
print("thought_db_open_spec: " .. checks .. " checks")
