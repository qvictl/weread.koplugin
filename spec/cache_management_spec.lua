-- The cache management page measures book directories in slices behind a
-- busy message instead of freezing the UI, and cleanups run after their
-- busy message painted.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        show = function() end,
        close = function() end,
        isWidgetShown = function() return true end,
    }
end
local function run_scheduled()
    local count = 0
    while #scheduled > 0 do
        local callback = table.remove(scheduled, 1)
        callback()
        count = count + 1
    end
    return count
end
-- No KOReader clock: slices fall back to a fixed number of books.
package.preload["ui/time"] = function() error("not available") end

-- Every book directory holds one 1 KB file.
local stat_calls = 0
package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(path)
            local entries = { ".", "..", "book.epub" }
            local index = 0
            return function()
                index = index + 1
                return entries[index]
            end
        end,
        attributes = function(path)
            stat_calls = stat_calls + 1
            if path:match("%.epub$") then return { mode = "file", size = 1024 } end
            return { mode = "directory" }
        end,
    }
end
for _i, name in ipairs({ "ui/widget/buttondialog", "ui/widget/pathchooser", "weread.lib.scan" }) do
    package.preload[name] = function() return {} end
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(id) return tostring(id):match("^MP_WXS_") ~= nil end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        book_resolved_dir = function(_settings, book_id) return "/cache/" .. tostring(book_id) end,
        book_dir_name = function(book_id) return tostring(book_id) end,
    }
end

local Cache = require("weread.ui.cache")

local books = {}
for index = 1, 30 do books["b" .. index] = { title = "Book " .. index } end
local busy, lists = {}, {}
local host = {
    settings = {
        get = function(_self, key, default)
            if key == "books" then return books end
            return default
        end,
    },
    showBusy = function(_self, text) busy[#busy + 1] = text end,
    closeBusy = function() busy[#busy + 1] = "closed" end,
    showTrackedList = function(_self, title, items) lists[#lists + 1] = { title = title, items = items } return {} end,
    showInfo = function() end,
    safeCallback = function(_self, _label, callback) return callback end,
}
for key, value in pairs(Cache) do host[key] = value end

host:showCacheManagement()
expect(stat_calls == 0 and busy[1] == "Calculating cache size...",
    "cache page measured directories before showing a busy message")
host:showCacheManagement()
expect(#scheduled == 1, "a second open started another measurement")
local slices = run_scheduled()
expect(slices == 4, "30 books were not measured in slices of 8: " .. slices)
expect(#lists == 1 and #lists[1].items == 32, "cache page did not list every book after measuring")
expect(busy[#busy] == "closed", "busy message stayed open")
expect(host._cache_scan == nil, "finished measurement stayed registered")

-- Clearing all cache paints a busy message first.
local cleared = false
host.clearAllCache = function() cleared = true return true end
host.refreshCacheManagement = function() end
local confirm
package.loaded["ui/uimanager"].show = function(_self, dialog) confirm = dialog end
lists[1].items[2].callback()
confirm.ok_callback()
expect(not cleared and busy[#busy] == "Clearing cache...", "cleanup ran before its busy message")
run_scheduled()
expect(cleared and busy[#busy] == "closed", "cleanup did not run or left the busy message")

print(("cache_management_spec: %d checks"):format(checks))
