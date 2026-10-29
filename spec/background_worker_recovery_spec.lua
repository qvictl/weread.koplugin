-- Startup removes owned IPC artifacts containing old results/authentication,
-- while active jobs and unrelated files remain intact.
package.path = "./?.lua;./?/init.lua;" .. package.path
local checks, nodes, removed = 0, {}, {}
local root = "/data/workers"
local function expect(value, text) checks = checks + 1; assert(value, text) end
local directory_exists = true
package.preload["ffi/util"] = function() return {} end
package.preload["ui/uimanager"] = function() return {} end
package.preload["json"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            if path == root then return directory_exists and "directory" or nil end
            return nodes[path]
        end,
        dir = function()
            local names = {}; for path in pairs(nodes) do names[#names + 1] = path:match("([^/]+)$") end
            table.sort(names)
            local index = 0
            return function() index = index + 1; return names[index] end
        end,
    }
end
local Worker = require("weread.lib.background_worker")
local worker = Worker:new{ temp_dir = root, runner = {} }
local prefix = root .. "/prefetch-" .. worker:_token()
for _, suffix in ipairs({ ".result.json", ".result.bin", ".result.bin.tmp", ".progress.json.tmp", ".cancel" }) do
    nodes[prefix .. suffix] = "file"
end
nodes[root .. "/notes.txt"] = "file"
nodes[root .. "/prefetch-unrelated.result.json"] = "file"
nodes[prefix .. ".result.json.tmp"] = "directory"
local real_remove = os.remove
rawset(os, "remove", function(path) removed[#removed + 1] = path; nodes[path] = nil; return true end)
local ok, err = xpcall(function()
    worker.pending = {}
    local count, reason = worker:recover()
    expect(count == nil and reason == "worker_busy" and #removed == 0, "recovery deleted active worker state")
    worker.pending = nil
    expect(worker:recover() == 5 and #removed == 5, "interrupted credential/result files were not removed")
    expect(nodes[root .. "/notes.txt"] and nodes[root .. "/prefetch-unrelated.result.json"], "unrelated files were removed")
    expect(nodes[prefix .. ".result.json.tmp"] == "directory", "recovery traversed an unrelated directory")
    expect(worker:recover() == 0, "cleanup is not idempotent")
    nodes[prefix .. ".cancel"] = "file"
    rawset(os, "remove", function() return nil, "read-only filesystem" end)
    count, reason = worker:recover()
    expect(count == nil and reason == "read-only filesystem", "cleanup failure was hidden")
    directory_exists = false
    expect(worker:recover() == 0, "missing worker directory was treated as a cleanup failure")
end, debug.traceback)
rawset(os, "remove", real_remove)
if not ok then error(err, 0) end
print("background_worker_recovery_spec: " .. checks .. " checks")
