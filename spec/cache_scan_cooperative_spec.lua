-- Exercise actual Scan iteration with an elapsed clock and scheduled slices.
package.path = "./?.lua;" .. package.path
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local now, queue, account, writes, records = 0, {}, "one", {}, {}
local confirmation, notices = nil, 0
local flushes, db_failure = 0, false
local function empty() return {} end
for _, key in ipairs({"ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/pathchooser"}) do
    package.preload[key] = empty
end
package.preload["ui/widget/confirmbox"] = function() return { new = function(_, value) return value end } end
package.preload["weread.lib.content"] = empty
package.preload["weread.lib.logger"] = function() return { warn = function() end } end
package.preload["weread.lib.protocol"] = function() return { is_mp_book = function() return false end } end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s) return s end }
end
package.preload["ui/time"] = function() return { now = function() return now end, to_s = function(v) return v end } end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_, delay, fn) queue[#queue + 1] = { delay, fn } end,
        show = function(_, value) confirmation = value end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(path)
            local i, limit = 0, path == "/root" and 4 or 100
            return function()
                i = i + 1
                if i <= limit then return path == "/root" and tostring(i) or (i .. ".epub") end
            end
        end,
        attributes = function(path)
            now = now + 0.01
            return { mode = path:match("%.epub$") and "file" or "directory", size = tonumber(path:match("/(%d+)%.epub$")) }
        end,
    }
end
-- This test targets scheduling/persistence; BookStore release has disk tests.
local releases = 0
package.preload["weread.lib.book_store"] = function()
    return { cache_mark = function() return {} end,
        release_cache_since = function() releases = releases + 1 end }
end
local Cache = require("weread.ui.cache")
local allowed = {}
for i = 1, 4 do allowed[tostring(i)] = { book_id = tostring(i), title = "Book " .. i } end
local host = setmetatable({ settings = {
    get = function() return { user_vid = account } end,
    get_book = function(_, id) return records[id] end,
    put_book = function(_, id, value) writes[#writes + 1] = id; records[id] = value end,
    get_books = function() error("must not materialize whole library") end,
    flush = function() flushes = flushes + 1 end,
}, library_db = { putBook = function() if db_failure then return false end return true end },
    showInfo = function() notices = notices + 1 end,
    showBusy = function(self) self.busy = true end }, { __index = Cache })
local done, failure, cancelled
local function finish(added, updated) done = { added, updated }; host.busy = nil end
local function fail(err, cancel) failure, cancelled, host.busy = err, cancel, nil end
host:scanLocalCacheAsync("/root", allowed, false, finish, fail)
expect(not done and #queue == 1, "first elapsed slice must yield")
host:confirmScanLocalCache()
expect(notices == 1 and host.busy and #queue == 1, "concurrent command replaced busy state or hid rejection")
local slices = 0
while #queue > 0 do
    local task = table.remove(queue, 1)
    expect(task[1] >= 0.1, "continuation delay below scheduling floor")
    local started = now
    task[2]()
    expect(now - started <= 0.27, "slice exceeded budget plus one file stat")
    slices = slices + 1
end
expect(slices < 30, "per-file sleeps replaced elapsed batching")
expect(done and done[1] == 4 and done[2] == 0 and #writes == 4, "actual imports differ")
for id, record in pairs(records) do expect(record.cached_file == "/root/" .. id .. "/100.epub", "largest EPUB not persisted") end
expect(flushes == 1 and not host.busy and not host._cache_import and releases > 4, "completion cleanup failed")
queue, writes, records, done = {}, {}, {}, nil
host:scanLocalCacheAsync("/root", allowed, false, finish, fail)
account = "two"
table.remove(queue, 1)[2]()
expect(cancelled and not done and #writes == 0 and not host._cache_import, "old-account scan wrote after checkpoint")
account, cancelled, db_failure, queue = "one", nil, true, {}
host:scanLocalCacheAsync("/root", allowed, false, finish, fail)
while #queue > 0 do table.remove(queue, 1)[2]() end
expect(failure and tostring(failure):find("SQLite", 1, true) and not cancelled and #writes == 0,
    "local persistence error became network fallback or successful import")
-- The confirmation modal can outlive its shelf account as well.
local imports = 0
host.settings.is_api_configured = function() return true end
host.isNetworkConnected = function() return true end
host.runOnlineTask = function(_, _, fn) fn() end
host._runNetworkRequest = function(_, _, _, task, success) success(task()) end
host.fetchShelfAllowedMap = function() return allowed end
host.closeBusy = function() end
host.scanLocalCacheAsync = function(_, _, _, dry_run, callback)
    if dry_run then callback(1, 0) else imports = imports + 1 end
end
account = "one"
host:offerScanNewDir("/root", "base")
expect(confirmation and confirmation.ok_callback, "import confirmation not shown")
host._cache_import = {}
confirmation.ok_callback()
expect(imports == 0 and notices == 2, "concurrent confirmation import was silently discarded")
host._cache_import = nil
account = "two"
confirmation.ok_callback()
expect(imports == 0, "old shelf confirmation imported into new account")
account = "one"
confirmation.ok_callback()
expect(imports == 1, "same account confirmation was incorrectly discarded")
print(("cache_scan_cooperative_spec: %d checks"):format(checks))
