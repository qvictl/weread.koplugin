-- Report pipeline of weread/lib/read_report.lua: how server replies are
-- classified, the refresh/renewal retry ladder and its error reporting, the
-- monotonic cloud guard's fallbacks, reader-context (re)building and
-- persistence, payload building and the forked child's settings isolation.
-- Run from the repo root with:
--   luajit spec/read_report_pipeline_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local H = require("spec.helpers.read_report_harness")
local CatalogMemo = require("weread.lib.catalog_memo")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function test(name, fn)
    H.clear_logs()
    H.reset_content()
    CatalogMemo.written = {}
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
end

local function contains(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

-- A report whose ensure_context is scripted: `contexts(report)` returns a
-- list whose entries are a book table or an error message, consumed one per
-- call (the last entry repeats). Returns report, env, calls (`force` flags).
local function scripted(make_contexts, opts)
    local report, env = H.new_report(opts)
    local contexts = make_contexts(report)
    local calls = {}
    report.ensure_context = function(_self, _book_id, force)
        calls[#calls + 1] = force == true
        local entry = contexts[math.min(#calls, #contexts)]
        if type(entry) == "string" then error(entry) end
        return entry
    end
    return report, env, calls
end

-- `position = false` drops the default live position (pairs() skips nil, so
-- `position = nil` would keep it): a time-only report.
local function run(report, opts)
    local options = { allow_renewal = false, elapsed_seconds = 30, session_open = true,
        position = { chapter_uid = 5, chapter_offset = 10, percent = 3 } }
    for key, value in pairs(opts or {}) do options[key] = value end
    if options.position == false then options.position = nil end
    return report:_run_pipeline("book", options)
end

-- ------------------------------------------------------------------
-- Server replies
-- ------------------------------------------------------------------

test("wrapped success replies and synckey-only replies are accepted", function()
    local report, env = H.new_report()
    local book = H.ready_book(report)
    report.ensure_context = function() return book end
    local cases = {
        { reply = { data = { succ = 1 } }, synckey = false },
        { reply = { result = { succ = 1 } }, synckey = false },
        { reply = { synckey = 7 }, synckey = true },
        { reply = { data = { synckey = 8 } }, synckey = true },
    }
    for index, case in ipairs(cases) do
        env.client.responses = { { case.reply, 200 } }
        local outcome = run(report)
        expect(outcome.accepted == true, "case " .. index .. " accepted")
        expect(outcome.has_synckey == case.synckey, "case " .. index .. " synckey")
        expect(outcome.elapsed_seconds == 30, "case " .. index .. " credited time")
    end
    expect(#env.client.sent == #cases, "one request per report")
    expect(env.client.sent[1].elapsed_seconds == 30 and env.client.sent[1].chapter_offset == 10,
        "live position and time sent")
end)

test("an error code is a rejection that is retried once with a fresh context", function()
    local report, env, calls = scripted(function(r) return { H.ready_book(r) } end)
    local reject = { { errCode = -2012, errMsg = "login\ntimeout" }, 401 }
    env.client.responses = { reject, reject }
    local outcome = run(report)
    expect(outcome.accepted == false and outcome.error_kind == "server", "server rejection")
    expect(outcome.error_prefix == "read report server rejected:", "prefix")
    expect(#env.client.sent == 2, "retried once")
    expect(calls[1] == false and calls[2] == true, "retry forces a fresh context")
    expect(contains(outcome.error, "initial=http=401"), "initial status")
    expect(contains(outcome.error, "; refreshed="), "retry status")
    expect(contains(outcome.error, "error_code=-2012"), "error code")
    expect(contains(outcome.error, "error_message=login timeout"), "control chars flattened")
    expect(contains(outcome.error, 'response_body={"errCode":-2012'), "decoded body logged")
    expect(outcome.renew_attempted == false, "renewal not allowed")
    expect(outcome.book and outcome.book.psvts == "ps", "context snapshot returned")
end)

test("unknown bodies and non-JSON replies are rejections", function()
    local report, env = H.new_report()
    local book = H.ready_book(report)
    report.ensure_context = function() return book end
    env.client.responses = { { { foo = 1 }, 200 }, { "<html>busy</html>", 502 } }
    local outcome = run(report)
    expect(outcome.accepted == false, "rejected")
    expect(contains(outcome.error, "body_keys=foo"), "body keys described")
    expect(contains(outcome.error, "succ=nil"), "missing succ described")
    expect(contains(outcome.error, "non_table_response, http=502"), "non-table reply")
    expect(contains(outcome.error, "response_body=<html>busy</html>"), "raw body kept")
end)

test("the failure summary survives an encoder error", function()
    local report, env = H.new_report()
    local book = H.ready_book(report)
    report.ensure_context = function() return book end
    env.client.json_encode = function() error("cannot encode") end
    env.client.responses = { { { code = 5, message = "busy" }, 200 }, { { succ = 0 }, 200 } }
    local outcome = run(report)
    expect(contains(outcome.error, "error_code=5"), "generic code field")
    expect(contains(outcome.error, "error_message=busy"), "generic message field")
    expect(contains(outcome.error, "response_body=table:"), "falls back to tostring")
end)

test("a transport error is reported without retrying", function()
    local report, env, calls = scripted(function(r) return { H.ready_book(r) } end)
    env.client.responses = { function() error("socket timeout") end }
    local outcome = run(report, { allow_renewal = true })
    expect(outcome.accepted == false and outcome.error_kind == "transport", "transport")
    expect(contains(outcome.error, "socket timeout"), "message kept")
    expect(outcome.error_prefix == "read report request failed:", "prefix")
    expect(#calls == 1 and #env.client.sent == 1, "no retry, no refresh")
    expect(outcome.renew_attempted == false, "no renewal")
end)

test("a context failure stops before any request", function()
    local report, env = scripted(function() return { "reader page HTTP 500" } end)
    local outcome = run(report)
    expect(outcome.error_kind == "context", "context error")
    expect(contains(outcome.error, "HTTP 500"), "message kept")
    expect(#env.client.sent == 0, "nothing sent")
end)

test("a rejected report succeeds with the refreshed context", function()
    local report, env = scripted(function(r)
        return { H.ready_book(r, { psvts = "stale" }), H.ready_book(r, { psvts = "fresh" }) }
    end)
    env.client.responses = { { { succ = 0 }, 200 }, { { succ = 1, synckey = 3 }, 200 } }
    local outcome = run(report)
    expect(outcome.accepted == true and outcome.has_synckey == true, "accepted on retry")
    expect(env.client.sent[2].psvts == "fresh", "retry used the refreshed context")
    expect(outcome.book.psvts == "fresh", "refreshed context returned for persisting")
end)

test("a failing context refresh is part of the rejection", function()
    local report, env = scripted(function(r) return { H.ready_book(r), "reader page gone" } end)
    env.client.responses = { { { succ = 0 }, 200 } }
    local outcome = run(report)
    expect(outcome.error_kind == "server", "still a server rejection")
    expect(contains(outcome.error, "context_refresh=") and contains(outcome.error, "reader page gone"),
        "refresh failure described")
    expect(#env.client.sent == 1, "no retry without a context")
end)

-- ------------------------------------------------------------------
-- Cookie renewal
-- ------------------------------------------------------------------

local function renewal_case(renew, final_context_error, responses)
    local report, env, calls = scripted(function(r)
        local book = H.ready_book(r)
        return { book, book, final_context_error or book }
    end)
    env.client.renew = renew
    env.client.responses = responses or { { { succ = 0 }, 401 }, { { succ = 0 }, 401 } }
    return run(report, { allow_renewal = true }), env, calls
end

test("renewal failure is an authentication error", function()
    local outcome, env = renewal_case(function() error("renew endpoint down") end)
    expect(outcome.renew_attempted == true, "renewal attempted")
    expect(outcome.error_kind == "authentication", "auth error")
    expect(outcome.error_prefix == "read report cookie renewal failed:", "prefix")
    expect(contains(outcome.error, "renewal=") and contains(outcome.error, "renew endpoint down"),
        "renewal error kept")
    expect(#env.client.sent == 2, "no final retry")

    outcome = renewal_case({ succ = 0, errmsg = "session expired" })
    expect(outcome.error_kind == "authentication", "rejected renewal")
    expect(contains(outcome.error, "error_message=session expired"), "renewal reply described")
end)

test("a renewed cookie gets one final attempt", function()
    local outcome, env, calls = renewal_case({ succ = 1 }, nil,
        { { { succ = 0 }, 401 }, { { succ = 0 }, 401 }, { { synckey = 9 }, 200 } })
    expect(outcome.accepted == true and outcome.has_synckey == true, "accepted after renewal")
    expect(outcome.renew_attempted == true, "renewal recorded")
    expect(#env.client.sent == 3, "initial, refreshed and final attempts")
    expect(#calls == 3 and calls[3] == true, "final context is forced")

    local report = H.new_report()
    report:_apply_outcome(outcome, "book")
    expect(report:_renewal_allowed() == false, "renewal cooldown starts")
end)

test("a failed final context or attempt after renewal is reported", function()
    local outcome = renewal_case({ succ = 1 }, "final context boom")
    expect(outcome.error_kind == "context", "final context error")
    expect(contains(outcome.error, "final_context=") and contains(outcome.error, "boom"), "text")

    outcome = renewal_case({ succ = 1 }, nil,
        { { { succ = 0 }, 401 }, { { succ = 0 }, 401 }, { { errcode = -1 }, 403 } })
    expect(outcome.error_kind == "server", "final rejection")
    expect(outcome.error_prefix == "read report final retry failed:", "prefix")
    expect(contains(outcome.error, "; final=http=403"), "final reply described")

    outcome = renewal_case({ succ = 1 }, nil,
        { { { succ = 0 }, 401 }, { { succ = 0 }, 401 }, function() error("EOF") end })
    expect(outcome.error_kind == "transport", "final transport error")
    expect(contains(outcome.error, "EOF"), "transport text")
end)

-- ------------------------------------------------------------------
-- Session opening and _send
-- ------------------------------------------------------------------

test("a retry after opening the session claims no extra reading time", function()
    local report, env = scripted(function(r)
        return { H.ready_book(r, { read_session_id = "previous", read_session_entered_at = 500 }) }
    end)
    env.client.responses = { { { succ = 1 }, 200 }, { { succ = 0 }, 200 }, { { succ = 1 }, 200 } }
    local outcome = run(report, {
        session_open = false, elapsed_seconds = 120, progress_only = true,
    })
    expect(outcome.accepted == true and outcome.entered == true, "entered and accepted")
    expect(env.client.sent[1].kind == "enter", "a new reader session enters first")
    expect(env.client.sent[2].kind == "report" and env.client.sent[2].elapsed_seconds == 0,
        "the enter's own report claims nothing")
    expect(env.client.sent[3].elapsed_seconds == 0, "the retry claims nothing either")
    expect(outcome.elapsed_seconds == 0, "no credit used")
end)

test("a rejected enter is returned as the report result", function()
    local report, env = scripted(function(r)
        local book = H.ready_book(r)
        book.read_session_entered_at = nil
        return { book }
    end)
    env.client.responses = { { { succ = 0 }, 403 }, { { succ = 0 }, 403 } }
    local outcome = run(report, { session_open = false })
    expect(outcome.accepted == false and outcome.entered == nil, "not entered")
    expect(env.client.sent[1].kind == "enter" and env.client.sent[2].kind == "enter",
        "the retry enters again instead of reporting")
end)

test("a time report with nothing to credit sends no request", function()
    local report, env = H.new_report()
    local book = H.ready_book(report)
    local result, code, entered, elapsed = report:_send("book", book, nil, 0,
        { session_open = true, time_report = true })
    expect(type(result) == "table" and result.succ == 1 and code == 200, "local success")
    expect(entered == false and elapsed == 0, "nothing entered or credited")
    expect(#env.client.sent == 0, "no heartbeat posted")
end)

test("_send defaults the credit to the interval and mints a missing pclts", function()
    local report, env = H.new_report{ config = { enabled = true, mode = "auto", interval_seconds = 60 } }
    local book = H.ready_book(report, { pclts = "" })
    local _, _, entered, elapsed = report:_send("book", book, nil, nil, {})
    expect(entered == false and elapsed == 60, "interval used")
    local payload = env.client.sent[1]
    expect(payload.elapsed_seconds == 60 and payload.pclts == "e:1000", "payload")
    expect(payload.psvts == "ps" and payload.token == "tk" and payload.app_id == "app", "session fields")
end)

test("a payload re-asserting the cloud is not marked as our own position", function()
    local report = H.new_report()
    local context = H.ready_book(report, { app_id = nil, summary = nil })
    report.ensure_context = function() return context end
    local payload = report:build_payload("book", 30, nil, {
        chapter_uid = 9, chapter_idx = 4, chapter_offset = 12, progress = 66, cloud = true,
    })
    expect(payload.chapter_uid == 9 and payload.chapter_idx == 4 and payload.chapter_offset == 12,
        "position applied")
    expect(payload.progress == 66 and payload.summary == "" and payload.app_id == "app", "defaults")
    expect(context.reported_local == false, "cloud position flagged")
    report:build_payload("book", 30, context, { chapter_uid = 9, percent = 70 })
    expect(context.reported_local == true and context.progress == 70, "own position flagged")
end)

-- ------------------------------------------------------------------
-- Cloud guard fallbacks
-- ------------------------------------------------------------------

test("an unreachable cloud does not block a regular report", function()
    local report, env = H.new_report()
    local book = H.ready_book(report)
    report.ensure_context = function() return book end
    local outcome = run(report, { guard = {} })
    expect(outcome.accepted == true, "reported")
    expect(contains(outcome.remote_check_error, "Network is unreachable"), "check error kept")
    expect(outcome.remote == nil, "no cloud data")
    expect(env.client.sent[1].chapter_offset == 10, "local position sent")
end)

test("the gateway progress API is the fallback for the web progress", function()
    local report, env = H.new_report()
    -- The stored context differs from the default live position (chapter 5),
    -- so the assertions tell a time-only report from a position report.
    local book = H.ready_book(report, { chapter_uid = 8 })
    report.ensure_context = function() return book end
    env.client.web_progress = { unrelated = true }
    env.client.progress = { bookId = "book", progress = 50, chapterUid = 7,
        chapterIdx = 3, chapterOffset = 3, summary = "Chapter 7" }

    local outcome = run(report, { guard = {}, position = false })
    expect(outcome.remote_check_error and contains(outcome.remote_check_error, "progress_not_found"),
        "without the API key the gateway is not asked")
    expect(env.client.sent[1].chapter_uid == 8, "stored context sent")

    env.settings.is_api_configured = function() return true end
    outcome = run(report, { guard = {}, position = false })
    expect(outcome.remote and outcome.remote.chapter_uid == 7 and outcome.remote.percent == 50,
        "gateway position used")
    expect(outcome.floor == nil, "time-only report is not a guarded position report")
    local payload = env.client.sent[2]
    expect(payload.chapter_uid == 7 and payload.progress == 50 and payload.summary == "Chapter 7",
        "time-only report re-asserts the gateway position")
    expect(outcome.book.reported_local == false, "not our own position")

    outcome = run(report, { guard = {} })
    expect(outcome.accepted == true, "guarded position report accepted")
    expect(outcome.floor and outcome.floor.chapter_uid == 7
            and outcome.floor.chapter_idx == 3 and outcome.floor.chapter_offset == 3
            and outcome.floor.percent == 50,
        "the gateway position becomes the floor for a lagging local position")
    payload = env.client.sent[3]
    expect(payload.chapter_uid == 7 and payload.chapter_idx == 3
            and payload.chapter_offset == 3 and payload.progress == 50
            and payload.summary == "Chapter 7",
        "guarded report re-asserts the gateway position instead of the older local position")
    expect(outcome.book.reported_local == false, "guarded cloud position is not our own position")
end)

-- ------------------------------------------------------------------
-- report_once (inline)
-- ------------------------------------------------------------------

test("report_once applies prechecks and the outcome inline", function()
    local report, env = H.new_report()
    env.settings.cookie_ok = false
    expect(report:report_once() == false, "precheck blocks")
    expect(#env.client.sent == 0, "nothing sent")

    env.settings.cookie_ok = true
    local book = H.ready_book(report)
    report.ensure_context = function() return book end
    report.server_session_ready = true
    report.server_session_book_id = "book"
    report.server_session_ready_at = 900
    report.last_credit_at = 960
    expect(report:report_once() == true, "reported")
    expect(env.client.sent[1].elapsed_seconds == 40, "credit since the last report")
    expect(report:status().count == 1, "success counted")
    expect(report.last_credit_at == 1000, "credit clock moved")
end)

-- ------------------------------------------------------------------
-- Reader context
-- ------------------------------------------------------------------

local CATALOG = {
    { chapterUid = 10, chapterIdx = 1, wordCount = 0, title = "Cover" },
    { chapterUid = 11, chapterIdx = 2, wordCount = 100 },
    { chapterUid = 12, chapterIdx = 3, wordCount = 200 },
}

local function library_db(chapters)
    local db = { puts = {} }
    function db:getChapters() return chapters end
    function db:putChapters(book_id, list)
        self.puts[#self.puts + 1] = { book_id = book_id, chapters = list }
        return true
    end
    return db
end

test("a stale context is rebuilt from the reader page, catalog and cloud progress", function()
    local db = library_db(nil)
    local report, env = H.new_report{ library_db = db, books = { book = { title = "T" } } }
    H.content.catalog = CATALOG
    env.client.progress = { book = { progress = 35, chapterUid = 12, chapterIdx = 3,
        chapterOffset = 77, summary = "s" } }

    local book = report:ensure_context("book")
    expect(book.psvts == "ps-fresh" and book.token == "token-fresh", "reader state")
    expect(book.pclts == "e:1000", "missing pclts minted")
    expect(book.read_session_id == report.session_id and book.read_session_entered_at == nil,
        "a new reader session must enter again")
    expect(book.chapter_uid == 12 and book.chapter_idx == 3, "cloud chapter selected")
    expect(book.chapter_offset == 77 and book.progress == 35 and book.summary == "s", "cloud position")
    expect(book.reported_local == false, "cloud position is not ours")
    expect(book.app_id == "app" and book.read_context_updated_at == 1000, "app id and age")
    expect(book.reader_url == "https://reader/book", "reader url")
    expect(env.settings.books.book == book and env.settings.flushes == 1, "persisted")
    expect(H.content.saved[1] == CATALOG, "catalog.json written")
    expect(db.puts[1] and db.puts[1].chapters == CATALOG, "SQLite catalog written")

    -- Fresh enough: reused without any network.
    env.clock.t = 1899
    report:ensure_context("book")
    expect(H.content.reader_states == 1 and H.content.fetches == 1, "reused within the TTL")

    -- Past the TTL: the reader page is reloaded, the catalog kept.
    env.clock.t = 1901
    report:ensure_context("book")
    expect(H.content.reader_states == 2 and H.content.fetches == 1, "refreshed after the TTL")

    report:ensure_context("book", true)
    expect(H.content.reader_states == 3 and H.content.fetches == 2, "forced refresh refetches")
end)

test("an open server session reuses the context without minting a new pclts", function()
    local report = H.new_report()
    local stored = H.ready_book(report, { read_session_id = "other", pclts = "keep",
        read_context_updated_at = 0 })
    stored.chapters = nil
    report.settings.books.book = stored
    H.content.cached = CATALOG
    local book = report:ensure_context("book", false, { session_open = true })
    expect(book.pclts == "keep", "pclts kept")
    expect(H.content.reader_states == 0, "no reader page fetch")
    expect(book.chapters == CATALOG, "catalog restored from catalog.json")
end)

test("context building falls back and fails clearly", function()
    local report, env = H.new_report()
    H.content.catalog = CATALOG
    env.client.progress = { progress = 20, chapterUid = 99, chapterOffset = 5 }
    local book = report:ensure_context("book")
    expect(book.chapter_uid == 11 and book.chapter_idx == 2, "unknown chapter: first readable")

    H.content.pclts = "0"
    book = report:ensure_context("book", true)
    expect(book.pclts == "e:1000", "zero pclts replaced")

    env.client.progress = nil
    book.chapter_uid = 12
    book = report:ensure_context("book", true)
    expect(book.chapter_uid == 12 and book.progress == 20, "failed progress fetch keeps the position")
    env.client.progress = "not a table"
    book = report:ensure_context("book", true)
    expect(book.chapter_uid == 12, "unusable progress reply ignored")

    H.content.catalog = { { chapterUid = 10, wordCount = 0 } }
    local ok, err = pcall(report.ensure_context, report, "book", true)
    expect(not ok and contains(tostring(err), "no readable chapter"), "no readable chapter")

    H.content.catalog = CATALOG
    H.content.psvts = ""
    ok, err = pcall(report.ensure_context, report, "book", true)
    expect(not ok and contains(tostring(err), "incomplete"), "incomplete reader state")

    ok, err = pcall(report.ensure_context, report, "")
    expect(not ok and contains(tostring(err), "missing book id"), "missing id")
    env.settings.cookie_ok = false
    ok, err = pcall(report.ensure_context, report, "book")
    expect(not ok and contains(tostring(err), "cookie not configured"), "no cookie")
end)

test("a catalog cache write failure is logged, not fatal", function()
    local report = H.new_report{ library_db = library_db(CATALOG) }
    H.content.save_error = "disk full"
    -- Restored from SQLite and backfilled to catalog.json ...
    local book = report:ensure_context("book")
    expect(book.chapters == CATALOG, "SQLite catalog restored")
    expect(H.count_logs("warn", "save chapter catalog cache failed: disk full") == 1, "logged")
    -- ... and written again after a forced catalog fetch.
    H.content.catalog = CATALOG
    report:ensure_context("book", true)
    expect(H.count_logs("warn", "save chapter catalog cache failed: disk full") == 2, "logged")
end)

test("a forked child builds the context without persisting it", function()
    local report, env = H.new_report{ book_id = "newbook" }
    H.content.catalog = CATALOG
    report.current_book_title = "Current"
    report._no_persist = true
    local book = report:ensure_context("newbook")
    expect(book.title == "Current" and book.book_id == "newbook", "new record defaults")
    expect(env.settings.books.newbook == nil and env.settings.flushes == 0, "nothing persisted")
end)

test("legacy whole-table settings persist the context into the books table", function()
    local settings = H.settings{ legacy = true }
    local report = H.new_report{ settings = settings }
    H.content.catalog = CATALOG
    report:ensure_context("book")
    expect(settings.books.book and settings.books.book.psvts == "ps-fresh", "stored")
    expect(settings.flushes == 1, "flushed")
end)

-- ------------------------------------------------------------------
-- Child isolation
-- ------------------------------------------------------------------

test("the child captures renewed auth without flushing settings", function()
    local report, env = H.new_report()
    local settings = env.settings
    local flush = rawget(settings, "flush")
    local update_auth = rawget(settings, "update_auth")
    report._run_pipeline = function(self_, _book_id, opts)
        expect(opts.progress_only == true and opts.guard and opts.guard.strict, "upload options")
        expect(opts.elapsed_seconds == 12 and opts.session_open == true, "credit forwarded")
        self_.settings:update_auth({ cookies = { wr_skey = "renewed" }, wr_ticket = "t2" },
            { replace_cookies = true })
        self_.settings:flush()
        expect(self_._no_persist == true, "context persistence disabled")
        return { accepted = true }
    end
    local outcome = report:_child_report("book", true, nil,
        { elapsed_seconds = 12, session_open = true }, { kind = "upload", guard = { strict = true } })
    expect(outcome.accepted == true, "outcome kept")
    expect(outcome.auth and outcome.auth.cookies.wr_skey == "renewed", "renewed cookies returned")
    expect(outcome.auth.wr_ticket == "t2" and outcome.auth.wr_wrpa == "wrpa", "tickets returned")
    expect(settings.auth_updates[1].options.flush == false, "auth update did not flush")
    expect(settings.flushes == 0, "nothing flushed in the child")
    expect(rawget(settings, "flush") == flush and rawget(settings, "update_auth") == update_auth,
        "settings methods restored")
    expect(report._no_persist == nil, "persistence restored")
end)

test("a crashing child pipeline becomes a task failure", function()
    local report = H.new_report()
    report._run_pipeline = function() error("pipeline boom") end
    local outcome = report:_child_report("book", false, nil, nil, nil)
    expect(outcome.accepted == false and outcome.error_kind == "task", "task failure")
    expect(contains(outcome.error, "pipeline boom"), "error kept")
    expect(outcome.auth == nil, "no auth change")
end)

print(("read_report_pipeline_spec: %d checks"):format(checks))
