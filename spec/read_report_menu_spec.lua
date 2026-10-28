-- Reading-report menu (weread/ui/read_report.lua): enable/trigger toggles,
-- menu texts and check marks, the status text shown by the status gesture
-- in automatic mode, login gating of the book picker, and the reading
-- statistics page (load, error, tab switch and period navigation).
-- Run from the repo root with:
--   luajit spec/read_report_menu_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local closed_views = {}
package.preload["ui/uimanager"] = function()
    return { close = function(_self, view) closed_views[#closed_views + 1] = view end }
end
local logged_errors = {}
package.preload["weread.lib.logger"] = function()
    return { err = function(...) logged_errors[#logged_errors + 1] = table.concat({ ... }, " ") end }
end

-- Reading statistics: fetch results are scripted per call.
local fetches = {}
local fetch_results = {}
package.preload["weread.lib.read_stats"] = function()
    return {
        fetch = function(client, mode, base_time)
            fetches[#fetches + 1] = { client = client, mode = mode, base_time = base_time }
            local result = table.remove(fetch_results, 1)
            if type(result) == "string" then error(result, 0) end
            return result
        end,
    }
end
local shown = {}
package.preload["weread.ui.read_stats_view"] = function()
    return {
        show = function(data, callbacks)
            local view = { data = data, callbacks = callbacks }
            shown[#shown + 1] = view
            return view
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(args[tonumber(index)])
            end))
        end,
        log_error = function(err) return "log:" .. tostring(err) end,
        display_error = function(err) return "shown:" .. tostring(err):match("^[^\r\n]+") end,
    }
end

package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
local ReadReportUI = require("weread.ui.read_report")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function make_host(config)
    local host = {
        config = config,
        events = {},
        flushes = 0,
        logged_in = true,
        client = { name = "client" },
    }
    local function event(name, value)
        host.events[#host.events + 1] = value ~= nil and (name .. ":" .. tostring(value)) or name
    end
    host.settings = {
        get = function(_self, key) if key == "read_report" then return host.config end end,
        set = function(_self, key, value) if key == "read_report" then host.config = value end end,
        flush = function() host.flushes = host.flushes + 1 end,
    }
    host.safeCallback = function(_self, _label, callback) return callback end
    host.maybeStartReadReport = function() event("start") end
    host.stopReadReport = function(_self, reason) event("stop", reason) end
    host.showTransientInfo = function(_self, text) event("notice", text) end
    host.showReadReportBookPicker = function() event("picker") end
    host.showInfo = function(_self, text) host.info = text end
    host.showBusy = function(_self, text) event("busy", text) end
    host.closeBusy = function() event("close_busy") end
    host._runNetworkRequest = require("weread.ui.common")._runNetworkRequest
    host.runOnlineTask = function(_self, label, task)
        event("online", label)
        task()
    end
    host.requireLogin = function(_self, ...)
        host.login_args = { ... }
        return host.logged_in
    end
    host.refreshBookshelf = function() event("shelf") end
    return setmetatable(host, { __index = ReadReportUI })
end

local function events(host)
    local text = table.concat(host.events, ",")
    host.events = {}
    return text
end

-- ------------------------------------------------------------------
-- Enable / trigger toggles
-- ------------------------------------------------------------------

do
    local host = make_host({ enabled = false, mode = "auto", book_id = "", book_title = "" })
    local items = host:getReadReportMenuItems()
    local enable = items[1]
    expect(enable.checked_func() == false, "disabled is unchecked")

    enable.callback()
    expect(host.config.enabled == true and enable.checked_func() == true, "enabled and checked")
    expect(host.flushes == 1, "setting flushed")
    expect(events(host) == "start", "auto mode starts reporting right away")

    enable.callback()
    expect(host.config.enabled == false, "disabled again")
    expect(events(host) == "stop", "disabling stops reporting")

    -- Manual mode without a target book asks for one first.
    host.config.mode = "manual"
    enable.callback()
    expect(events(host) == "notice:Please select a target book,picker",
        "manual mode without a book opens the picker")

    host.config.enabled = false
    host.config.book_id = "b1"
    enable.callback()
    expect(events(host) == "start", "manual mode with a book starts reporting")
end

do
    local host = make_host({ enabled = true, mode = "auto" })
    local trigger = host:getReadReportMenuItems()[2]
    expect(trigger.checked_func() == true, "reporting only while reading is the default")
    trigger.callback()
    expect(host.config.report_on_open == false and trigger.checked_func() == false,
        "background reporting enabled")
    expect(events(host) == "stop:trigger_mode_changed,start", "restarted with the new trigger")
    trigger.callback()
    expect(host.config.report_on_open == true, "back to reading-only")
    events(host)
    host.config.enabled = false
    trigger.callback()
    expect(events(host) == "stop:trigger_mode_changed", "a disabled report is not started")
end

-- ------------------------------------------------------------------
-- Menu texts and sub menus
-- ------------------------------------------------------------------

do
    local host = make_host({ enabled = true, mode = "auto", book_id = "", book_title = "" })
    local items = host:getReadReportMenuItems()
    expect(items[3].text_func() == "Report interval: 30 s", "default interval shown")
    host.config.interval_seconds = "60"
    expect(items[3].text_func() == "Report interval: 60 s", "stored interval shown")
    local intervals = items[3].sub_item_table_func()
    expect(#intervals == 2 and intervals[2].checked_func() == true, "interval presets")

    expect(items[4].post_text == "Auto-associate", "auto mode label")
    expect(items[4].text_func() == "Select target book", "no book in auto mode")
    host.config.mode = "manual"
    expect(items[4].text_func() == "Select target book", "manual mode without a title")
    host.config.book_title = "Pinned"
    expect(items[4].text_func() == "Select target book · Pinned", "manual target shown")

    local targets = items[4].sub_item_table_func()
    expect(targets[1].checked_func() == false and targets[2].checked_func() == true,
        "manual target checked")
    expect(targets[2].post_text == "Pinned", "manual target title as post text")

    local manual_items = host:getReadReportMenuItems()
    expect(manual_items[4].post_text == nil, "no auto label in manual mode")

    targets[1].callback()
    expect(host.config.mode == "auto" and host.config.book_id == "" and host.config.book_title == "",
        "auto mode clears the pinned book")
    expect(targets[1].checked_func() == true and targets[2].checked_func() == false, "auto checked")
    expect(events(host) == "stop:target_changed,start", "restarted for the open book")

    host.config.enabled = false
    targets[1].callback()
    expect(events(host) == "stop:target_changed", "disabled report stays stopped")
end

-- ------------------------------------------------------------------
-- Status text (status gesture)
-- ------------------------------------------------------------------

do
    local host = make_host({ mode = "auto", book_title = "" })
    local status = { running = false, count = 0 }
    host.read_report = { status = function() return status end }
    host:onShowWeReadReportStatus()
    expect(host.info == "Report book: Auto-associate\nStatus: Stopped\nReported: 0 times, last: --",
        "auto mode before any target")

    status = { running = false, count = 2, target_book_title = "Last Book" }
    host:onShowWeReadReportStatus()
    expect(host.info:find("Report book: Auto: Last Book\nStatus: Stopped", 1, true),
        "stopped auto session still names its last target")

    host.config = { mode = "manual", book_title = "" }
    status = { running = true, count = 1, target_book_title = "" }
    host:onShowWeReadReportStatus()
    expect(host.info:find("Report book: Not configured\nStatus: Running", 1, true),
        "manual mode without a book")
    expect(not host.info:find("Last error", 1, true), "no error line without an error")
end

-- ------------------------------------------------------------------
-- Book picker login gate
-- ------------------------------------------------------------------

do
    local host = make_host({ mode = "auto" })
    host.showReadReportBookPicker = nil
    host.logged_in = false
    host:showReadReportBookPicker()
    expect(events(host) == "", "not logged in: no bookshelf")
    expect(host.login_args[1] == true and host.login_args[2] == true, "login prompt requested")
end

-- ------------------------------------------------------------------
-- Reading statistics
-- ------------------------------------------------------------------

do
    local host = make_host({ mode = "auto" })
    host.logged_in = false
    host:showReadStats()
    expect(#fetches == 0 and events(host) == "", "statistics need a login")
    expect(host.login_args[1] == false and host.login_args[2] == true, "login check arguments")

    host.logged_in = true
    fetch_results = { { prev_base_time = 100, next_base_time = 300, label = "May" } }
    host:showReadStats()
    expect(#fetches == 1 and fetches[1].mode == "monthly" and fetches[1].base_time == nil,
        "opens on the monthly tab")
    expect(fetches[1].client == host.client, "fetched with the plugin client")
    expect(events(host) == "busy:Loading reading statistics...,online:Reading statistics,close_busy",
        "busy indicator around an online task")
    local first = shown[1]
    expect(first and first.data.label == "May", "statistics shown")
    expect(#closed_views == 0, "nothing to close on first open")

    fetch_results = { { prev_base_time = 50, next_base_time = 200, label = "April" } }
    first.callbacks.on_prev()
    expect(fetches[2].mode == "monthly" and fetches[2].base_time == 100, "previous period")
    expect(closed_views[1] == first and shown[2].data.label == "April", "old page replaced")

    fetch_results = { { label = "June" } }
    shown[2].callbacks.on_next()
    expect(fetches[3].base_time == 200, "next period")
    expect(closed_views[2] == shown[2], "previous page closed")

    fetch_results = { { label = "Week" } }
    shown[3].callbacks.on_switch("weekly")
    expect(fetches[4].mode == "weekly" and fetches[4].base_time == nil, "tab switch resets period")
    expect(closed_views[3] == shown[3] and shown[4].data.label == "Week", "switched")

    -- A failed fetch keeps the current page and shows the error.
    events(host)
    fetch_results = { "HTTP 500" }
    shown[4].callbacks.on_prev()
    expect(#shown == 4 and #closed_views == 3, "current page kept on failure")
    expect(events(host):find("close_busy", 1, true), "busy indicator closed on failure")
    expect(host.info == "Reading statistics failed:\nshown:HTTP 500", "error shown")
    expect(logged_errors[1] and logged_errors[1]:find("log:HTTP 500", 1, true), "error logged")
end

print(("read_report_menu_spec: %d checks"):format(checks))
