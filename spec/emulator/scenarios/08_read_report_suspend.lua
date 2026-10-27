-- @title Read report: timer pauses on Suspend without network, resumes on Resume
-- @timeout 150
-- Reading-time report enabled in auto mode with the shortest interval. A
-- chapter of 900001 is downloaded through the plugin's chapter dialog and
-- opened via "Read now". After the report timer has opened the server
-- session and credited time, a real Suspend broadcast must stop the timer
-- with no network request during or after it (F3/F16); Resume re-arms the
-- timer and the next /web/book/read report arrives.
local BOOK_ID = "900001"
local INTERVAL = 10 -- ReadReport's minimum interval
local SUSPENDED_FOR = 2 * INTERVAL

return function(H)
    local tr = H.tr
    local UIManager = require("ui/uimanager")

    local function has_dimen(widget)
        local d = rawget(widget, "dimen")
        return type(d) == "table" and type(d.x) == "number" and type(d.w) == "number"
            and d.w > 0 and d.h > 0
    end

    local function find_exact(label)
        local found
        H.walk(function(widget, chain, depth)
            if rawget(widget, "text") == label then
                for i = depth, 1, -1 do
                    if has_dimen(chain[i]) then
                        found = chain[i]
                        return true
                    end
                end
            end
        end)
        return found
    end

    local function tap_exact(label, timeout)
        local target = H.wait_until("button '" .. label .. "' painted", function()
            return find_exact(label)
        end, timeout or 15)
        local x = math.floor(target.dimen.x + target.dimen.w / 2)
        local y = math.floor(target.dimen.y + target.dimen.h / 2)
        H.log("tap button", label, "@", x, y)
        return H.tap_at(x, y)
    end

    -- Requests that reached the synthetic WeRead service. Control/state
    -- calls of this scenario have a JSON null host, which decodes to a
    -- non-nil sentinel: require a string.
    local function service_requests()
        return H.mock_requests(function(event) return type(event.host) == "string" end)
    end

    local function read_posts()
        local count = 0
        for _i, event in ipairs(service_requests()) do
            if event.method == "POST" and event.path == "/web/book/read" then count = count + 1 end
        end
        return count
    end

    local function report()
        return H.plugin().read_report
    end

    local function task_scheduled(task)
        if not task then return false end
        for _i, item in ipairs(UIManager._task_queue or {}) do
            if item.action == task then return true end
        end
        return false
    end

    local function report_state()
        return H.call(function()
            local rr = report()
            return {
                task = rr.task,
                scheduled = task_scheduled(rr.task),
                state = rr.state,
                suspended = rr.suspended == true,
                job = rr.job ~= nil,
                count = rr.count or 0,
                failures = rr.failure_count or 0,
                last_error = rr.last_error,
                session = rr.server_session_ready == true,
            }
        end)
    end

    H.step("enable reading-time report (auto, shortest interval)", function()
        H.wait_until("weread plugin on FileManager", function() return H.plugin() end, 20)
        H.call(function()
            local settings = H.runtime().settings
            settings:set("read_report", {
                enabled = true,
                mode = "auto",
                book_id = "",
                book_title = "",
                interval_seconds = INTERVAL,
                report_on_open = true,
            })
            settings:flush()
            H.check(report():_interval() == INTERVAL, "report interval applied")
        end)
    end)

    H.step("download chapter 1 through the plugin and open it", function()
        local chapters
        H.call(function()
            local plugin = H.plugin()
            local book = plugin.client:get_book_info(BOOK_ID)
            plugin.settings:put_book(BOOK_ID, book)
            plugin.settings:flush()
            book = plugin.settings:get_book(BOOK_ID)
            plugin:loadChapters(book, function(list)
                chapters = list
                plugin:downloadChapterAndRead(book, list[1])
            end)
        end)
        H.wait_until("chapter catalog loaded", function() return chapters end, 20)
        H.equal(#chapters, 6, "catalog chapters")
        tap_exact(tr("Download"))
        tap_exact(tr("Read now"), 60)
        H.wait_until("ReaderUI ready", function()
            local reader = H.reader()
            return reader and reader.document and reader.postReaderReadyCallback == nil and reader.weread
        end, 30)
        H.shot("08-01-reader-open")
    end)

    local before_suspend
    H.step("report timer opens the session and credits time", function()
        local started = H.now_ms()
        H.wait_until("first accepted report (server session entered)", function()
            local rr = report()
            return (rr.count or 0) >= 1 and rr.server_session_ready
        end, 20)
        H.metric("first_report_ms", H.now_ms() - started)
        H.wait_until("second accepted report (reading time credited)", function()
            return (report().count or 0) >= 2
        end, 35)
        H.metric("second_report_ms", H.now_ms() - started)
        H.check(read_posts() >= 2, "reports reached /web/book/read", tostring(read_posts()))
        -- Suspend between ticks, not while a report job is in flight.
        H.wait_until("report job collected and next tick armed", function()
            local rr = report()
            return rr.job == nil and task_scheduled(rr.task)
        end, 10)
        before_suspend = report_state()
        H.equal(before_suspend.state, "active", "report state before suspend")
        H.equal(before_suspend.failures, 0, "report failures before suspend")
    end)

    local quiet_from
    H.step("Suspend stops the timer without any network request", function()
        local requests_before = #service_requests()
        local inline = H.call(function()
            local count_before = #service_requests()
            UIManager:broadcastEvent(require("ui/event"):new("Suspend"))
            -- The handlers ran synchronously: a blocking request in them would
            -- already be in the mock's log here.
            return #service_requests() - count_before
        end)
        H.equal(inline, 0, "requests made inside the Suspend handlers")
        quiet_from = #service_requests()
        local state = report_state()
        H.equal(state.task, nil, "report task cleared on suspend")
        H.equal(H.call(task_scheduled, before_suspend.task), false, "old report tick unscheduled")
        H.equal(state.state, "suspended", "report state")
        H.equal(state.suspended, true, "report suspended flag")
        H.equal(state.job, false, "no report job running")
        H.check(H.call(function() return H.plugin().progress_sync.suspended end), "progress sync suspended too")
        H.equal(quiet_from, requests_before, "requests at suspend")
        H.shot("08-02-suspended")
        -- Two whole intervals asleep: no tick, no job, no request.
        H.sleep(SUSPENDED_FOR)
        local after = service_requests()
        local extra = {}
        for index = quiet_from + 1, #after do
            extra[#extra + 1] = tostring(after[index].method) .. " " .. tostring(after[index].path)
        end
        H.check(#after == quiet_from, "no network request while suspended", table.concat(extra, ", "))
        state = report_state()
        H.equal(state.task, nil, "still no report task while suspended")
        H.equal(state.count, before_suspend.count, "no report while suspended")
        H.metric("suspended_s", SUSPENDED_FOR)
    end)

    H.step("Resume re-arms the timer and reporting continues", function()
        local posts_before = read_posts()
        H.broadcast("Resume")
        local state = report_state()
        H.check(state.task ~= nil, "report task re-armed on resume")
        H.equal(state.scheduled, true, "report tick scheduled on the UI loop")
        H.equal(state.suspended, false, "report no longer suspended")
        H.check(state.session, "server session kept across suspend")
        local started = H.now_ms()
        H.wait_until("next accepted report after resume", function()
            return (report().count or 0) > before_suspend.count
        end, 3 * INTERVAL)
        H.metric("report_after_resume_ms", H.now_ms() - started)
        H.check(read_posts() > posts_before, "a /web/book/read report arrived after resume")
        state = report_state()
        H.equal(state.failures, 0, "report failures")
        H.equal(state.state, "active", "report state after resume")
        H.shot("08-03-resumed")
    end)

    H.step("reader stays responsive", function()
        local page = H.call(function() return H.reader():getCurrentPage() end)
        H.call(function() H.reader().rolling:onGotoViewRel(1) end)
        H.wait_until("page turn after resume", function()
            return H.reader():getCurrentPage() > page
        end, 10)
    end)
end
