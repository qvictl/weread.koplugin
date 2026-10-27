-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        make_enter_read_payload = function(options)
            return {
                kind = "enter",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
            }
        end,
        make_read_payload = function(options)
            return {
                kind = "report",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
                elapsed_seconds = options.elapsed_seconds,
            }
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local function fixture(provider, overrides)
    overrides = overrides or {}
    local records = {}
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "auto",
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        set = function() end,
        flush = function() end,
        is_cookie_configured = function() return true end,
    }
    local client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function() end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = function() return true end,
        subprocess = overrides.subprocess or false,
        memory_gate = overrides.memory_gate,
        now = function() return 100 end,
    }
    return report, records
end

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 3, "enter plus two reports")
    eq(records[1].kind, "enter", "first request enters")
    eq(records[2].kind, "report", "second request reports")
    eq(records[2].chapter_uid, 22, "live chapter used")
    eq(records[2].chapter_offset, 150, "live offset used")
    eq(records[2].elapsed_seconds, 0, "progress-only report has zero time")
    eq(records[3].elapsed_seconds, 30, "time report keeps interval")
end)

test("open WeRead book wins over a pinned manual target", function()
    local report = fixture()
    report.settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "manual",
                    book_id = "pinned",
                    book_title = "Pinned",
                    report_on_open = false,
                    interval_seconds = 120,
                }
            end
            if key == "books" then
                return { openbook = { title = "Open" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
    }
    report.detect_book = function() return "openbook" end
    local id, _title, source = report:resolve_target()
    eq(id, "openbook", "open book is the report target")
    eq(source, "current_document", "source follows the open book")
end)

test("time report enter does not send an rt=0 heartbeat", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    report:_send("book", book, {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }, 120, { time_report = true })
    eq(#records, 1, "enter is the only request")
    eq(records[1].kind, "enter", "session opens without rt")
end)

test("restored session credits wall time without entering again", function()
    local stored = {
        enabled = true,
        mode = "auto",
        interval_seconds = 120,
        session_book_id = "book",
        session_started_at = 1000,
        last_credit_at = 1000,
    }
    local records = {}
    local report = fixture()
    report.now = function() return 1180 end
    report.settings = {
        get = function() return stored end,
        set = function(_self, _key, value) stored = value end,
        flush = function() end,
        is_cookie_configured = function() return true end,
    }
    report.client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local elapsed, session_open = report:_reading_credit("book")
    eq(session_open, true, "session restored inside the ttl")
    eq(elapsed, 180, "credit is capped at max(interval, 180)")
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    report:_send("book", book, {
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 400,
        percent = 1,
    }, elapsed, { session_open = true, time_report = true })
    eq(#records, 1, "no second enter")
    eq(records[1].kind, "report", "duration report")
    eq(records[1].elapsed_seconds, 180, "capped elapsed is sent")
    eq(records[1].chapter_offset, 400, "live offset is sent")
end)

test("progress upload sends a request in an already entered session", function()
    local report, records = fixture()
    local book = { book_id="book", chapter_uid=5, chapter_idx=5,
        chapter_offset=3555, progress=1, psvts="ps", pclts="pc", token="token",
        read_session_id=report.session_id, read_session_entered_at=100 }
    report.ensure_context = function() return book end
    report._persist_context = function() end
    local accepted = report:upload_position("book", {
        chapter_uid=6, chapter_idx=6, chapter_offset=25880, percent=4 }, 0)
    eq(accepted, true, "call claims success")
    eq(#records, 1, "a real POST must send the new position")
    if records[1] then eq(records[1].chapter_offset, 25880, "new position sent") end
end)

test("failed enter must not turn its retry into synthetic success", function()
    local report, records = fixture()
    local book = {book_id="book", chapter_uid=5, psvts="ps", pclts="pc", token="token"}
    report.ensure_context = function() return book end
    report.client.report_read = function(_, payload)
        records[#records+1]=payload
        return {succ=0, errCode=-1}, 403
    end
    local outcome=report:_run_pipeline("book", {elapsed_seconds=0, allow_renewal=false})
    eq(outcome.accepted, false, "rejected enter remains rejected")
    eq(#records >= 2, true, "retry must make a real request")
end)

test("progress heartbeat resets credit only after server acceptance", function()
    local report, records = fixture()
    local book = { book_id = "book", chapter_uid = 5, psvts = "ps", pclts = "pc",
        read_session_id = report.session_id, read_session_entered_at = 80 }
    report.ensure_context = function() return book end
    report._persist_context = function() end
    report.server_session_ready = true
    report.server_session_book_id = "book"
    report.server_session_ready_at = 80
    report.last_credit_at = 80
    local accepted = report:upload_position("book", { chapter_uid = 6, percent = 4 }, 0)
    eq(accepted, true, "heartbeat accepted")
    eq(#records, 1, "restored session sends one progress request")
    eq(report.last_credit_at, 100, "credit starts after accepted heartbeat")
    report.now = function() return 110 end
    report.client.report_read = function() return { succ = 0, errCode = -1 }, 403 end
    accepted = report:upload_position("book", { chapter_uid = 6, percent = 4 }, 0)
    eq(accepted, false, "rejected progress remains rejected")
    eq(report.last_credit_at, 100, "rejection does not reset credit")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

test("low memory skips the tick instead of forking or reporting inline", function()
    local forks = 0
    local runner = {
        run = function() forks = forks + 1; return 42, 7 end,
    }
    local report, records = fixture(function()
        return { chapter_uid = 22, chapter_offset = 150, percent = 25 }, nil, true
    end, {
        subprocess = runner,
        memory_gate = function() return false, 20000 end,
    })
    local inline = 0
    report._run_pipeline = function() inline = inline + 1 end
    report.task = function() end
    report:_tick(report.generation, report.task)
    eq(forks, 0, "no fork under memory pressure")
    eq(inline, 0, "no inline network pipeline on the UI loop")
    eq(#records, 0, "nothing reported")
    eq(report:status().state, "waiting_for_memory", "state shows the wait")
end)

test("failed fork does not fall back to an inline report", function()
    local report = fixture(function()
        return { chapter_uid = 22, chapter_offset = 150, percent = 25 }, nil, true
    end, {
        subprocess = { run = function() return false, "fork failed: Cannot allocate memory" end },
        memory_gate = function() return true, 200000 end,
    })
    local inline = 0
    report._run_pipeline = function() inline = inline + 1 end
    report.task = function() end
    report:_tick(report.generation, report.task)
    eq(inline, 0, "no inline network pipeline on the UI loop")
end)

test("suspend pauses the credit clock without reporting inline", function()
    local report, records = fixture()
    local now = 1000
    report.now = function() return now end
    report.server_session_ready = true
    report.server_session_book_id = "book"
    report.server_session_ready_at = 900
    report.last_credit_at = 980
    report.task = function() end
    report:on_suspend()
    eq(#records, 0, "suspend sends nothing")
    now = 1600
    report:on_resume()
    local elapsed = report:_reading_credit("book")
    eq(elapsed, 20, "credit keeps the 20 s read before sleeping, not the sleep")
end)

test("close pauses the credit clock for the next reader instance", function()
    local stored = {
        enabled = true, mode = "auto", interval_seconds = 30,
    }
    local report, records = fixture()
    local now = 1000
    report.now = function() return now end
    report.settings = {
        get = function() return stored end,
        set = function(_self, _key, value) stored = value end,
        flush = function() end,
        is_cookie_configured = function() return true end,
    }
    report.server_session_ready = true
    report.server_session_book_id = "book"
    report.server_session_ready_at = 900
    report.last_credit_at = 975
    report:on_close_document()
    eq(#records, 0, "close sends nothing")
    eq(stored.credit_paused_at, 1000, "pause persisted for the next reader")

    local next_report = fixture()
    next_report.settings = report.settings
    next_report.now = function() return 1300 end
    local elapsed, session_open = next_report:_reading_credit("book")
    eq(session_open, true, "session restored")
    eq(elapsed, 25, "the closed gap is not credited")
end)

local function fake_runner()
    local runner = { forks = 0, done = false }
    function runner.run(child)
        runner.forks = runner.forks + 1
        runner.child = child
        return 42, 7
    end
    function runner.write_all(_fd, data) runner.written = data end
    function runner.is_done() return runner.done end
    function runner.read_size() return runner.written and #runner.written or 0 end
    function runner.read_all()
        local data = runner.written
        runner.written = nil
        return data
    end
    function runner.terminate() runner.terminated = true end
    return runner
end

local function json_stub(client)
    local stash = {}
    client.json_encode = function(_self, value)
        stash[#stash + 1] = value
        return "#" .. #stash
    end
    client.json_decode = function(_self, text)
        return stash[tonumber(text:sub(2))]
    end
end

test("progress upload runs in a background job and is polled", function()
    local runner = fake_runner()
    local report, records = fixture(nil, {
        subprocess = runner,
        memory_gate = function() return true, 200000 end,
    })
    json_stub(report.client)
    local scheduled = {}
    report.scheduler = {
        scheduleIn = function(_self, _delay, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function() end,
    }
    local book = { book_id = "book", chapter_uid = 5, psvts = "ps", pclts = "pc",
        read_session_id = report.session_id, read_session_entered_at = 80 }
    report.ensure_context = function() return book end
    report._persist_context = function() end
    local original_flush = report.settings.flush
    local position = { chapter_uid = 6, chapter_idx = 6, chapter_offset = 25880, percent = 4 }

    local accepted, outcome = report:upload_position("book", position, 0)
    eq(accepted, false, "upload not finished yet")
    eq(outcome.error_kind, "pending", "upload is pending")
    eq(runner.forks, 1, "one background job")
    eq(#records, 0, "nothing sent on the UI loop")
    accepted, outcome = report:upload_position("book", position, 0)
    eq(outcome.error_kind, "pending", "same snapshot polls the running job")
    eq(runner.forks, 1, "polling does not fork again")
    local _a, other = report:upload_position("book", { chapter_uid = 7, percent = 5 }, 0)
    eq(other.error_kind, "busy", "a different snapshot waits")

    runner.child(42, 7)
    eq(#records, 1, "the child sent the position")
    eq(records[1].chapter_offset, 25880, "uploaded offset")
    eq(rawget(report.settings, "flush"), original_flush, "child restores settings.flush")
    runner.done = true
    for _i, fn in ipairs(scheduled) do fn() end
    accepted = report:upload_position("book", position, 0)
    eq(accepted, true, "final result is returned once")
    _a, outcome = report:upload_position("book", position, 0)
    eq(outcome.error_kind, "pending", "a new call starts a new upload")
end)

test("progress upload never runs inline when the fork is refused", function()
    local report, records = fixture(nil, {
        subprocess = { run = function() return false, "fork failed" end },
        memory_gate = function() return true, 200000 end,
    })
    local inline = 0
    report._run_pipeline = function() inline = inline + 1 end
    local accepted, outcome = report:upload_position("book", { chapter_uid = 6, percent = 4 }, 0)
    eq(accepted, false, "not accepted")
    eq(outcome.error_kind, "busy", "caller retries later")
    eq(inline, 0, "no inline pipeline")
    eq(#records, 0, "nothing sent")
end)

test("teardown cancels the tick and kills a running job", function()
    local runner = fake_runner()
    local report = fixture(nil, {
        subprocess = runner,
        memory_gate = function() return true, 200000 end,
    })
    json_stub(report.client)
    local unscheduled = 0
    report.scheduler = {
        scheduleIn = function() end,
        unschedule = function() unscheduled = unscheduled + 1 end,
    }
    report:upload_position("book", { chapter_uid = 6, percent = 4 }, 0)
    report.task = function() end
    report:teardown("close_widget")
    eq(report.task, nil, "tick cancelled")
    eq(report.job, nil, "job dropped")
    eq(runner.terminated, true, "child killed")
end)

local function guard_fixture(position, remote, stored)
    local report, records = fixture(function()
        return position, nil, true
    end)
    local book = {
        book_id = "book", psvts = "ps", pclts = "pc", token = "token",
        read_session_id = report.session_id, read_session_entered_at = 80,
    }
    for key, value in pairs(stored or {}) do book[key] = value end
    local get = report.settings.get
    report.settings.get = function(self_, key, default)
        if key == "books" then return { book = book } end
        return get(self_, key, default)
    end
    report.ensure_context = function() return book end
    report._persist_context = function() end
    report.client.get_web_progress = function()
        if not remote then error("Network is unreachable") end
        return remote
    end
    report.needs_cloud_check = true
    report.task = function() end
    -- An open server session with 40 s of reading to credit.
    report.server_session_ready = true
    report.server_session_book_id = "book"
    report.server_session_ready_at = 50
    report.last_credit_at = 60
    return report, records, book
end

test("first report after a gap never sends a position behind newer cloud progress", function()
    local report, records = guard_fixture(
        { chapter_uid = 22, chapter_idx = 2, chapter_offset = 200, percent = 30 },
        { bookId = "book", progress = 40, chapterUid = 33, chapterIdx = 3, chapterOffset = 10 },
        { chapter_uid = 22, chapter_offset = 150, progress = 25 })
    report:_tick(report.generation, report.task)
    eq(#records, 1, "time is still reported")
    eq(records[1].chapter_uid, 33, "cloud chapter re-sent")
    eq(records[1].progress, 40, "cloud progress re-sent")
    eq(report.needs_cloud_check, false, "check done for this session")
    eq(report.report_floor.position.chapter_uid, 33, "cloud position kept as floor")
    report.last_credit_at = 60
    report:_tick(report.generation, report.task)
    eq(#records, 2, "second report sent")
    eq(records[#records].chapter_uid, 33, "later reports keep the floor")
end)

test("a cloud position this device sent itself does not block moving back", function()
    local report, records = guard_fixture(
        { chapter_uid = 22, chapter_idx = 2, chapter_offset = 200, percent = 30 },
        { bookId = "book", progress = 40, chapterUid = 33, chapterIdx = 3, chapterOffset = 10 },
        { chapter_uid = 33, chapter_offset = 10, progress = 40 })
    report:_tick(report.generation, report.task)
    eq(records[1].chapter_uid, 22, "local position sent")
    eq(records[1].chapter_offset, 200, "local offset sent")
    eq(report.report_floor, nil, "no floor")
end)

test("a time-only report re-asserts the fresh cloud position", function()
    local report, records = guard_fixture(nil,
        { bookId = "book", progress = 40, chapterUid = 33, chapterIdx = 3, chapterOffset = 10 },
        { chapter_uid = 22, chapter_offset = 150, progress = 25 })
    report.position_provider = function() return nil, nil, false end
    report:_tick(report.generation, report.task)
    eq(records[1].chapter_uid, 33, "fresh cloud chapter, not the stale context")
    eq(records[1].progress, 40, "fresh cloud progress")
end)

test("a deferred upload is skipped when the cloud moved ahead elsewhere", function()
    local report, records = guard_fixture(nil,
        { bookId = "book", progress = 40, chapterUid = 33, chapterIdx = 3, chapterOffset = 10 },
        { chapter_uid = 22, chapter_offset = 150, progress = 25 })
    local accepted, outcome = report:upload_position("book", {
        chapter_uid = 22, chapter_idx = 2, chapter_offset = 200, percent = 30,
        guard = { strict = true, baselines = { { chapter_uid = 22, chapter_offset = 150 } } },
    }, 0)
    eq(accepted, false, "not uploaded")
    eq(outcome.error_kind, "remote_ahead", "reason")
    eq(outcome.remote.chapter_uid, 33, "cloud position returned")
    eq(#records, 0, "no request sent")
end)

test("a strict upload guard without cloud data does not upload", function()
    local report, records = guard_fixture(nil, nil,
        { chapter_uid = 22, chapter_offset = 150, progress = 25 })
    local accepted, outcome = report:upload_position("book", {
        chapter_uid = 22, chapter_offset = 200, percent = 30,
        guard = { strict = true },
    }, 0)
    eq(accepted, false, "not uploaded")
    eq(outcome.error_kind, "transport", "kept for a retry")
    eq(#records, 0, "no request sent")
end)

test("an explicit upload is never guarded", function()
    local report, records = guard_fixture(nil,
        { bookId = "book", progress = 40, chapterUid = 33, chapterIdx = 3, chapterOffset = 10 },
        { chapter_uid = 22, chapter_offset = 150, progress = 25 })
    local accepted = report:upload_position("book", {
        chapter_uid = 22, chapter_idx = 2, chapter_offset = 100, percent = 20,
    }, 0)
    eq(accepted, true, "explicit choice uploads")
    eq(records[1].chapter_offset, 100, "older position sent on request")
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
