-- Lifecycle of the background reading-time report (weread/lib/read_report.lua):
-- start/skip decisions, timer arming and cancelling on suspend/resume/close,
-- tick gating, the forked report job (spawn, poll back-off, timeout, reaping)
-- and how a job outcome updates status, the persisted server session, auth
-- and the stored reader context.
-- Run from the repo root with:
--   luajit spec/read_report_lifecycle_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local H = require("spec.helpers.read_report_harness")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function test(name, fn)
    H.clear_logs()
    H.reset_content()
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
end

local function contains(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

-- ------------------------------------------------------------------
-- Start / skip decisions
-- ------------------------------------------------------------------

test("disabled reporting never arms a timer and logs the skip once", function()
    local report, env = H.new_report{ config = { enabled = false, mode = "auto" } }
    local started, title, reason = report:maybe_start("reader_ready")
    expect(started == false and title == nil and reason == "disabled", "disabled result")
    report:maybe_start("resume")
    expect(#env.scheduler.queue == 0, "no timer armed")
    expect(report.task == nil and report:status().running == false, "not running")
    expect(H.count_logs("info", "read report skipped: disabled") == 1, "skip logged once")
end)

test("no open document or a non-WeRead document stops reporting", function()
    local report, env = H.new_report{ no_document = true }
    local started, _, reason = report:maybe_start("reader_ready")
    expect(started == false and reason == "no_document", "no document")
    expect(report:status().state == "stopped", "stopped state")
    expect(report:status().stop_reason == "no_document", "stop reason")

    env.document = { file = "/local.epub" }
    env.book_id = nil
    started, _, reason = report:maybe_start("reader_ready")
    expect(started == false and reason == "document_not_weread", "foreign document")
    expect(#env.scheduler.queue == 0, "no timer")
end)

test("a pinned manual book reports without an open book only when allowed", function()
    local config = { enabled = true, mode = "manual", book_id = 123, book_title = "Pinned" }
    local report, env = H.new_report{ no_document = true, config = config }
    local id, _, source = report:resolve_target()
    expect(id == nil and source == "no_document", "reading-only mode needs an open book")

    -- Any open (even non-WeRead) document allows the pinned target.
    env.document = { file = "/local.pdf" }
    env.book_id = nil
    local title
    id, title, source = report:resolve_target()
    expect(id == "123" and title == "Pinned" and source == "manual", "pinned while reading")

    env.document = nil
    config.report_on_open = false
    config.book_title = ""
    local started
    started, title, source = report:maybe_start("background")
    expect(started == true and title == "123" and source == "manual",
        "background target, title falls back to the id")
    expect(report:status().target_book_id == "123", "status shows the target")
    expect(env.scheduler:delays() == "1", "first tick armed")
end)

test("the open book's title comes from its stored record", function()
    local settings = H.settings{ books = { book = { title = "Stored Title" } } }
    local report = H.new_report{ settings = settings }
    local _, title = report:maybe_start("reader_ready")
    expect(title == "Stored Title", "title from the record")
    settings.books.book.title = "Renamed"
    expect(report:_target_title("book") == "Stored Title", "cached while the target is unchanged")

    local untitled = H.new_report{ book_id = "untitled" }
    _, title = untitled:maybe_start("reader_ready")
    expect(title == "untitled", "unknown record falls back to the id")

    -- Legacy whole-table settings holding a corrupt books value.
    local legacy = H.settings{ legacy = true }
    legacy.books = false
    local old = H.new_report{ settings = legacy }
    _, title = old:maybe_start("reader_ready")
    expect(title == "book", "corrupt legacy books table is ignored")
end)

test("start arms the first tick after 1 s and is idempotent", function()
    local report, env = H.new_report()
    local started, _, source = report:maybe_start("reader_ready")
    expect(started == true and source == "current_document", "started")
    expect(env.scheduler:delays() == "1", "session opens after 1 s")
    expect(report:status().state == "waiting" and report:status().running, "waiting state")

    expect(report:maybe_start("again") == true, "running session reported as started")
    expect(report:start("again") == true, "start is idempotent")
    expect(#env.scheduler.queue == 1, "still one timer")
    expect(H.count_logs("info", "reading time report started:") == 1, "one start log")
end)

test("a restored server session waits a full interval before the first tick", function()
    local report, env = H.new_report{ config = {
        enabled = true, mode = "auto", interval_seconds = 60,
        session_book_id = "book", session_started_at = 940, last_credit_at = 980,
    } }
    expect(report:maybe_start("reader_ready") == true, "started")
    expect(env.scheduler:delays() == "60", "no new enter right away")
    expect(report.server_session_ready == true, "session restored")
end)

test("start refuses when disabled, suspended or without a target", function()
    local report, env = H.new_report()
    env.settings.config.enabled = false
    expect(report:start("x") == false, "disabled")
    env.settings.config.enabled = true
    report.suspended = true
    expect(report:start("x") == false, "suspended")
    report.suspended = false
    env.book_id = nil
    expect(report:start("x") == false, "no target")
    expect(#env.scheduler.queue == 0, "nothing armed")
end)

test("a cloud floor of another book is dropped when a session starts", function()
    local report = H.new_report()
    report.report_floor = { book_id = "other", position = { percent = 50 } }
    report:maybe_start("reader_ready")
    expect(report.report_floor == nil, "foreign floor dropped")

    local same = H.new_report()
    local floor = { book_id = "book", position = { percent = 50 } }
    same.report_floor = floor
    same:maybe_start("reader_ready")
    expect(same.report_floor == floor, "floor of the same book kept")
    expect(same.needs_cloud_check == true, "cloud is checked after a (re)start")
end)

-- ------------------------------------------------------------------
-- Suspend / resume / close
-- ------------------------------------------------------------------

test("suspend cancels the timer and resume re-arms it without any request", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    report:on_suspend()
    expect(#env.scheduler.queue == 0, "timer cancelled")
    expect(report.task == nil, "task dropped")
    local status = report:status()
    expect(status.state == "suspended" and status.stop_reason == "suspend", "suspended status")

    local started, _, reason = report:maybe_start("page")
    expect(started == false and reason == "suspended", "no start while suspended")

    expect(report:on_resume() == true, "resume restarts")
    expect(env.scheduler:delays() == "1", "re-armed")
    expect(report:status().state == "waiting", "waiting again")
    expect(runner.forks == 0 and #env.client.sent == 0, "no network on suspend/resume")
end)

test("suspend while a report job runs kills and reaps the child", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    expect(runner.forks == 1 and report.job ~= nil, "job running")
    local pid = report.job.pid

    report:on_suspend()
    expect(report.job == nil, "job dropped")
    expect(runner.terminated[1] == pid, "child terminated")
    expect(env.scheduler:delays() == "2", "only the reaper is scheduled")

    -- Child still exiting and blocked on a full pipe: the reaper drains it.
    runner.written = "partial"
    env.scheduler:run_next()
    expect(runner.reads == 1 and runner.written == nil, "pipe drained")
    expect(env.scheduler:delays() == "2", "reaper keeps polling")
    runner.done = true
    env.scheduler:run_next()
    expect(#env.scheduler.queue == 0, "reaper stops once the child is collected")
    expect(report:status().count == 0 and report:status().failure_count == 0,
        "an abandoned job is neither a success nor a failure")
end)

test("reader ready clears a stale suspend flag", function()
    local report, env = H.new_report()
    report.suspended = true
    expect(report:on_reader_ready() == true, "started")
    expect(report.suspended == false and #env.scheduler.queue == 1, "armed")
end)

test("closing the book keeps a pinned background target reporting", function()
    local config = {
        enabled = true, mode = "manual", book_id = "pinned",
        book_title = "Pinned", report_on_open = false,
    }
    local report, env = H.new_report{ config = config }
    report:maybe_start("reader_ready")
    expect(report.current_book_id == "book", "open book wins while reading")
    env.document = nil
    report:on_close_document()
    expect(report.task ~= nil, "still running")
    expect(report.current_book_id == "pinned" and report.current_book_source == "manual",
        "falls back to the pinned book")
    expect(report.credit_paused_at == nil, "credit clock not paused")
end)

-- ------------------------------------------------------------------
-- Tick gating
-- ------------------------------------------------------------------

test("a tick without a cookie records an authentication error and retries", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    env.settings.cookie_ok = false
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    local status = report:status()
    expect(status.state == "error" and status.last_error_kind == "authentication", "auth error")
    expect(contains(status.last_error, "cookie"), "error text")
    expect(status.failure_count == 1 and status.consecutive_failures == 1, "counted")
    expect(env.scheduler:delays() == "30", "retried next interval")
    env.scheduler:run_next()
    expect(report:status().failure_count == 2 and report:status().consecutive_failures == 2,
        "streak grows")
    expect(H.count_logs("warn", "cookie not configured") == 1, "same error logged once")
    expect(runner.forks == 0, "no job without a cookie")
end)

test("offline ticks skip quietly and retry next interval", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    env.online = false
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    expect(report:status().state == "offline", "offline state")
    expect(report:status().failure_count == 0, "not a failure")
    expect(env.scheduler:delays() == "30", "next interval")
    expect(runner.forks == 0, "no job")
end)

test("unverified progress is rechecked within 5 s", function()
    local runner = H.runner()
    local verified = false
    local report, env = H.new_report{
        subprocess = runner,
        config = { enabled = true, mode = "auto", interval_seconds = 60 },
        position_provider = function()
            if verified then return { chapter_uid = 5, percent = 10 }, nil, true end
            return nil, nil, true
        end,
    }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    expect(report:status().state == "waiting_for_progress", "waiting for progress")
    expect(env.scheduler:delays() == "5", "short retry instead of 60 s")
    expect(H.count_logs("info", "progress_unverified") == 1, "default skip reason")
    verified = true
    env.scheduler:run_next()
    expect(runner.forks == 1, "verified position is reported")
end)

test("a position provider that does not apply lets time be reported", function()
    local runner = H.runner()
    local report, env = H.new_report{
        subprocess = runner,
        position_provider = function() return nil, "not_weread_view", false end,
    }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    expect(runner.forks == 1, "job started without a position")
end)

test("a tick stops the session when reporting was disabled or suspended meanwhile", function()
    local report, env = H.new_report()
    report:maybe_start("reader_ready")
    env.settings.config.enabled = false
    env.scheduler:run_next()
    expect(report.task == nil and report:status().stop_reason == "disabled", "stopped")
    expect(#env.scheduler.queue == 0, "no further tick")

    local sleepy, sleepy_env = H.new_report()
    sleepy:maybe_start("reader_ready")
    sleepy.suspended = true
    sleepy_env.scheduler:run_next()
    expect(sleepy:status().state == "suspended" and sleepy.task == nil, "suspended")
    expect(#sleepy_env.scheduler.queue == 0, "no further tick")

    local closed, closed_env = H.new_report()
    closed:maybe_start("reader_ready")
    closed_env.document = nil
    closed_env.scheduler:run_next()
    expect(closed:status().stop_reason == "no_document", "document gone")
    expect(#closed_env.scheduler.queue == 0, "no further tick")
end)

test("switching books restarts the session for the new book", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    local old_task = report.task
    env.book_id = "other"
    env.scheduler:run_next()
    expect(report.task ~= nil and report.task ~= old_task, "new session task")
    expect(report.current_book_id == "other", "new target")
    expect(env.scheduler:delays() == "1", "new session opens promptly")
    expect(runner.forks == 0, "nothing reported for the old book")

    -- A stale callback of the old session is a no-op.
    old_task()
    expect(#env.scheduler.queue == 1 and runner.forks == 0, "stale task ignored")
end)

test("a tick while a job is still in flight only keeps the cadence", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    expect(runner.forks == 1, "first job")
    report:_tick(report.generation, report.task)
    expect(runner.forks == 1, "no second job")
    expect(env.scheduler:find(report.task).delay == 30, "next tick at the interval")
end)

test("a freshly opened session waits for real reading time before reporting", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    report.server_session_ready = true
    report.server_session_book_id = "book"
    report.server_session_ready_at = 990
    report.last_credit_at = 996
    env.scheduler:run_next()
    expect(runner.forks == 0, "no report for 4 s of reading")
    expect(env.scheduler:delays() == "11", "wakes when 15 s have accrued")
    report.last_credit_at = 988
    env.scheduler:run_next()
    expect(env.scheduler:delays() == "5", "at least 5 s between checks")
end)

test("an exception inside a tick is recorded and the timer keeps running", function()
    local report, env = H.new_report{
        position_provider = function() error("provider boom") end,
    }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    local status = report:status()
    expect(status.state == "error" and status.last_error_kind == "task", "task error")
    expect(contains(status.last_error, "provider boom"), "error text kept")
    expect(env.scheduler:delays() == "30", "still scheduled")
end)

test("a page turn after a long pause triggers a prompt report", function()
    local report, env = H.new_report()
    report:on_page_update()
    expect(#env.scheduler.queue == 0, "not running: nothing to do")

    report:maybe_start("reader_ready")
    report.server_session_ready = true
    report.server_session_book_id = "book"
    report.server_session_ready_at = 900
    report.last_credit_at = 990
    report:on_page_update()
    expect(env.scheduler:delays() == "1", "10 s of reading does not reschedule")

    report.last_credit_at = 955
    report:on_page_update()
    expect(env.scheduler:delays() == "0.2", "45 s of reading reports right away")

    report.suspended = true
    report:on_page_update()
    expect(env.scheduler:delays() == "0.2", "ignored while suspended")
end)

-- ------------------------------------------------------------------
-- Report jobs
-- ------------------------------------------------------------------

local function session_book(report)
    return H.ready_book(report, { read_session_id = "older", read_session_entered_at = nil })
end

test("a forked report job is polled with back-off and its outcome applied", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    local stored = session_book(report)
    env.settings.books.book = stored
    report.ensure_context = function() return H.copy(env.settings.books.book) end
    env.client.web_progress = { bookId = "book", progress = 12, chapterUid = 6,
        chapterIdx = 2, chapterOffset = 40, summary = "cloud" }

    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    expect(runner.forks == 1 and #env.client.sent == 0, "nothing sent on the UI loop")
    for _i, want in ipairs({ "0.25", "0.5", "1", "2", "2" }) do
        expect(env.scheduler:delays() == want, "poll back-off " .. want)
        env.scheduler:run_next()
    end

    runner.finish()
    expect(#env.client.sent == 1 and env.client.sent[1].kind == "enter", "child opened the session")
    expect(env.client.sent[1].progress == 12, "time-only report re-asserts the cloud position")
    expect(env.client.sent[1].url == "https://reader/book", "reader url")
    runner.done = true
    env.scheduler:run_next()

    local status = report:status()
    expect(status.count == 1 and status.state == "active", "success recorded")
    expect(status.last_time == 1000, "last report time")
    expect(report.needs_cloud_check == false, "cloud checked")
    expect(env.settings.config.session_book_id == "book", "server session persisted")
    expect(env.settings.config.session_started_at == 1000, "session start persisted")
    expect(env.settings.books.book.read_session_id == report.session_id, "context written back")
    expect(env.settings.books.book.reported_local == false, "cloud position is not ours")
    expect(env.scheduler:delays() == "30", "next tick armed")

    -- Next tick credits the 30 s read since the session opened.
    env.clock.t = 1030
    report.ensure_context = function() return H.copy(env.settings.books.book) end
    env.scheduler:run_next()
    runner.finish()
    expect(env.client.sent[2].kind == "report", "duration report")
    expect(env.client.sent[2].elapsed_seconds == 30, "30 s credited")
    env.scheduler:run_next()
    expect(report:status().count == 2, "second success")
    expect(env.settings.config.last_credit_at == 1030, "credit clock persisted")
end)

test("a report job that never finishes is killed after 180 s", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    env.clock.t = 1182
    env.scheduler:run_next()
    expect(#runner.terminated == 1, "child killed")
    expect(report.job == nil, "job dropped")
    local status = report:status()
    expect(status.last_error_kind == "transport" and contains(status.last_error, "timed out"),
        "timeout recorded")
    expect(H.count_logs("warn", "read report job timed out, terminating:") == 1, "logged")
    local task_entry = env.scheduler:find(report.task)
    expect(task_entry and task_entry.delay == 30, "next tick still armed")
    expect(env.scheduler:delays() == "2,30", "reaper polls before the next tick")
    runner.done = true
    env.scheduler:run_next()
    expect(env.scheduler:delays() == "30", "reaper finished; only the tick remains")
end)

test("a poll of an abandoned job does nothing", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    local poll = report.job.poll
    report:stop("user")
    runner.done = true
    local before = #env.scheduler.queue
    poll()
    expect(runner.reads == 0, "the stale poll did not read the pipe")
    expect(#env.scheduler.queue == before, "nothing scheduled")
    expect(report:status().count == 0, "no outcome applied")
end)

test("output read before the child exits is applied and the child reaped later", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report.ensure_context = function() return H.ready_book(report) end
    report:maybe_start("reader_ready")
    report.needs_cloud_check = false
    env.scheduler:run_next()
    runner.finish()
    env.scheduler:run_next()
    expect(report:status().count == 1, "outcome applied")
    expect(env.scheduler:delays() == "1,30", "a reaper after 1 s plus the next tick")
    env.scheduler:run_next()
    expect(env.scheduler:delays() == "30,2", "reaper retries every 2 s")
    runner.done = true
    local reaper = table.remove(env.scheduler.queue, 2)
    reaper.fn()
    expect(env.scheduler:delays() == "30", "reaper stops once collected")
end)

test("a job that exits without a usable result counts as a failure", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    runner.done = true
    env.scheduler:run_next()
    local status = report:status()
    expect(status.last_error_kind == "job" and contains(status.last_error, "no result"), "empty")
    expect(status.failure_count == 1, "counted")

    env.scheduler:run_next()  -- next tick
    runner.written = "<garbage>"
    env.scheduler:run_next()
    expect(report:status().failure_count == 2, "undecodable output is a failure too")
end)

test("a child that cannot serialize its outcome reports a job error", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report.ensure_context = function() return H.ready_book(report) end
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    local encode = env.client.json_encode
    env.client.json_encode = function() error("cyclic table") end
    runner.finish()
    env.client.json_encode = encode
    expect(contains(runner.written, '"error_kind":"job"'), "fallback outcome written")
    runner.done = true
    env.scheduler:run_next()
    local status = report:status()
    expect(status.last_error_kind == "job", "job error")
    expect(contains(status.last_error, "serialize"), "error text")
end)

test("the subprocess runner wraps KOReader's ffi/util", function()
    local fake = H.runner()
    H.ffi = fake
    local report, env = H.new_report()
    report.ensure_context = function() return H.ready_book(report) end
    expect(report.subprocess ~= nil and report.subprocess ~= fake, "adapter built")
    report:maybe_start("reader_ready")
    env.scheduler:run_next()
    expect(fake.forks == 1 and fake.with_pipe == true, "runInSubProcess with a pipe")
    fake.finish()
    expect(fake.write_close == true, "writeToFD closes the pipe")
    fake.done = true
    env.scheduler:run_next()
    expect(fake.reads == 1, "readAllFromFD")
    expect(report:status().count == 1, "outcome applied through the adapter")
    env.scheduler:run_next()
    fake.done = false
    report:stop("user")
    expect(#fake.terminated == 1, "terminateSubProcess")
    H.ffi = {}
end)

-- ------------------------------------------------------------------
-- Outcome bookkeeping and write-back
-- ------------------------------------------------------------------

test("failures accumulate and a success resets the streak", function()
    local report, env = H.new_report()
    local rejected = { accepted = false, error = "HTTP 500", error_kind = "server",
        error_prefix = "read report server rejected:" }
    expect(report:_apply_outcome(rejected, "book") == false, "rejected")
    report:_apply_outcome(rejected, "book")
    local status = report:status()
    expect(status.failure_count == 2 and status.consecutive_failures == 2, "two failures")
    expect(status.last_error == "HTTP 500" and status.last_error_kind == "server", "last error")
    expect(H.count_logs("warn", "read report server rejected: HTTP 500") == 1, "logged once")

    report:_apply_outcome({ accepted = false }, "book")
    expect(report:status().last_error == "unknown report failure", "default error text")
    expect(report:status().last_error_kind == "error", "default kind")

    expect(report:_apply_outcome({ accepted = true, has_synckey = true }, "book") == true, "ok")
    status = report:status()
    expect(status.count == 1 and status.consecutive_failures == 0, "streak reset")
    expect(status.failure_count == 3 and status.last_error == nil, "history kept, error cleared")
    expect(status.state == "active", "active")
    expect(H.count_logs("info", "read report success:") == 1, "recovery logged")

    for _i = 2, 19 do report:_apply_outcome({ accepted = true }, "book") end
    expect(H.count_logs("info", "read report success:") == 1, "quiet while healthy")
    report:_apply_outcome({ accepted = true }, "book")
    expect(H.count_logs("info", "read report success:") == 2, "every 20th success logged")

    expect(report:_apply_outcome(nil, "book") == false, "missing outcome")
    expect(env.settings.config.session_book_id == nil, "no session without entered")
end)

test("a renewal attempt starts a 10 minute cooldown", function()
    local report, env = H.new_report()
    expect(report:_renewal_allowed() == true, "allowed initially")
    report:_apply_outcome({ accepted = false, renew_attempted = true, error = "x" }, "book")
    expect(report.last_renew_attempt == 1000, "attempt time")
    env.clock.t = 1599
    expect(report:_renewal_allowed() == false, "cooldown")
    env.clock.t = 1600
    expect(report:_renewal_allowed() == true, "cooldown over")
end)

test("an accepted enter opens the server session; later credits move the clock", function()
    local report, env = H.new_report()
    report:_apply_outcome({ accepted = true, entered = true }, "book")
    expect(report.server_session_ready and report.server_session_book_id == "book", "open")
    expect(env.settings.config.last_credit_at == 1000, "persisted")
    local flushes = env.settings.flushes
    env.clock.t = 1050
    report:_apply_outcome({ accepted = true, elapsed_seconds = 0 }, "book")
    expect(report.last_credit_at == 1000 and env.settings.flushes == flushes,
        "a zero credit does not move the clock")
    report:_apply_outcome({ accepted = true, elapsed_seconds = 50 }, "book")
    expect(report.last_credit_at == 1050 and env.settings.config.last_credit_at == 1050, "moved")
    report:_apply_outcome({ accepted = true, elapsed_seconds = 50 }, "other")
    expect(report.last_credit_at == 1050, "another book does not touch this session")
end)

test("a cloud floor is reported until reading passes it", function()
    local report = H.new_report()
    expect(report:_apply_report_floor("book", { percent = 5 }).percent == 5, "no floor")
    report.report_floor = { book_id = "book", position = { chapter_uid = 3, percent = 40 } }
    local sent = report:_apply_report_floor("book", { chapter_uid = 2, percent = 30 })
    expect(sent.percent == 40 and sent.chapter_uid == 3 and sent.cloud == true, "floor sent")
    expect(report:_apply_report_floor("other", { percent = 1 }).percent == 1, "other book")
    expect(report:_apply_report_floor("book", nil) == nil, "time-only report")
    expect(report.report_floor ~= nil, "floor kept")
    local ahead = { chapter_uid = 4, percent = 45 }
    expect(report:_apply_report_floor("book", ahead) == ahead, "reading passed the floor")
    expect(report.report_floor == nil, "floor cleared")

    report.needs_cloud_check = true
    report:_note_cloud_check("book", { accepted = true })
    expect(report.needs_cloud_check == true, "no cloud data: still to check")
    report:_note_cloud_check("book", { remote = { percent = 1 } })
    expect(report.needs_cloud_check == false and report.report_floor == nil, "checked, no floor")
    report:_note_cloud_check(7, { remote = { percent = 9 }, floor = { percent = 9 } })
    expect(report.report_floor.book_id == "7" and report.report_floor.position.percent == 9,
        "floor stored")
end)

local function job_for(report, book_id)
    return {
        book_id = book_id or "book",
        owner = require("weread.lib.request_owner").capture(report.settings),
        auth_fingerprint = report:_auth_fingerprint(),
        context_fingerprint = report:_context_fingerprint(book_id or "book"),
    }
end

test("renewed auth from a job is persisted unless the parent changed it meanwhile", function()
    local report, env = H.new_report()
    local auth = { cookies = { wr_skey = "renewed" }, wr_ticket = "t2", wr_wrpa = "w2" }
    report:_write_back(job_for(report), { auth = auth })
    local update = env.settings.auth_updates[1]
    expect(update and update.credentials.cookies.wr_skey == "renewed", "cookies persisted")
    expect(update.credentials.wr_ticket == "t2" and update.credentials.wr_wrpa == "w2", "tickets")
    expect(update.options.replace_cookies == true, "replaces the cookie jar")

    local job = job_for(report)
    env.settings.store.cookies = { wr_skey = "user-login" }
    report:_write_back(job, { auth = { cookies = { wr_skey = "stale" } } })
    expect(#env.settings.auth_updates == 1, "newer parent auth wins")
    expect(env.settings.store.cookies.wr_skey == "user-login", "not overwritten")
    expect(H.count_logs("info", "skip renewed auth write-back") == 1, "logged")

    env.settings.update_auth = function() error("disk full") end
    report:_write_back(job_for(report), { auth = auth })
    expect(H.count_logs("warn", "persist renewed auth failed:") == 1, "failure logged, not raised")
    report:_write_back(job_for(report), "not a table")
end)

test("a job's reader context replaces the stored one unless it changed meanwhile", function()
    local stored = { book_id = "book", title = "T", psvts = "old", pclts = "p1",
        chapter_uid = 1, cache_dir = "/books/book" }
    local report, env = H.new_report{ books = { book = stored } }
    local flushes = env.settings.flushes
    local snapshot = { title = "T", psvts = "new", chapter_uid = 2, progress = 40,
        reported_local = true }
    report:_write_back(job_for(report), { book = snapshot })
    local record = env.settings.books.book
    expect(record.psvts == "new" and record.chapter_uid == 2 and record.progress == 40, "replaced")
    expect(record.pclts == nil, "a field missing from the snapshot is cleared")
    expect(record.cache_dir == "/books/book", "non-context fields kept")
    expect(env.settings.flushes == flushes + 1, "flushed once")

    report:_write_back(job_for(report), { book = snapshot })
    expect(env.settings.flushes == flushes + 1, "unchanged context is not rewritten")

    local job = job_for(report)
    record.progress = 55
    report:_write_back(job, { book = { title = "T", progress = 41 } })
    expect(env.settings.books.book.progress == 55, "newer parent record wins")
    expect(H.count_logs("info", "skip report context write-back") == 1, "logged")

    env.settings.put_book = function() error("read-only fs") end
    report:_write_back(job_for(report), { book = { title = "X" } })
    expect(H.count_logs("warn", "persist report context failed:") == 1, "failure logged")
end)

test("context write-back creates missing records with legacy whole-table settings", function()
    local settings = H.settings{ legacy = true }
    local report = H.new_report{ settings = settings }
    report:_persist_context("b2", { title = "New", psvts = "p" })
    local record = settings.books.b2
    expect(record and record.book_id == "b2" and record.psvts == "p", "record created")
    expect(settings.get_book == nil and settings.flushes == 1, "legacy books table flushed")
end)

-- ------------------------------------------------------------------
-- Progress uploads in a job
-- ------------------------------------------------------------------

test("an upload job that times out or returns nothing fails for the caller", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    local position = { chapter_uid = 6, chapter_offset = 10, percent = 4 }
    local accepted, outcome = report:upload_position("book", position, 0)
    expect(accepted == false and outcome.error_kind == "pending", "pending")
    env.clock.t = 1046
    env.scheduler:run_next()
    expect(#runner.terminated == 1, "upload child killed after 45 s")
    accepted, outcome = report:upload_position("book", position, 0)
    expect(accepted == false and outcome.error_kind == "transport", "timeout result")
    expect(contains(outcome.error, "timed out"), "timeout text")

    env.scheduler.queue = {}
    runner.done = false
    report:upload_position("book", position, 0)
    runner.done = true
    env.scheduler:run_next()
    accepted, outcome = report:upload_position("book", position, 0)
    expect(accepted == false and outcome.error_kind == "job", "no result")
    expect(contains(outcome.error, "no result"), "empty result text")
end)

test("an upload result older than two minutes is not handed out", function()
    local runner = H.runner()
    local report, env = H.new_report{ subprocess = runner }
    report.ensure_context = function() return H.ready_book(report) end
    local position = { chapter_uid = 6, chapter_offset = 10, percent = 4 }
    report:upload_position("book", position, 0)
    runner.finish()
    runner.done = true
    env.scheduler:run_next()
    expect(report.upload_result and report.upload_result.accepted == true, "result stored")
    env.clock.t = 1121
    local accepted, outcome = report:upload_position("book", position, 0)
    expect(accepted == false and outcome.error_kind == "pending", "stale result: upload again")
    expect(runner.forks == 2, "second job")
end)

test("an inline upload records renewal and survives a failed context write", function()
    local report, env = H.new_report{ inline = true }
    report._run_pipeline = function(_self, _book_id, opts)
        expect(opts.progress_only == true, "upload pipeline is progress-only")
        return { accepted = true, renew_attempted = true, book = { title = "T" } }
    end
    report._persist_context = function() error("read-only fs") end
    local accepted = report:upload_position("book", { chapter_uid = 6, percent = 4 }, 0)
    expect(accepted == true, "upload accepted")
    expect(report.last_renew_attempt == 1000, "renewal cooldown started")
    expect(H.count_logs("warn", "persist progress upload context failed:") == 1, "logged")
    expect(env.settings.flushes == 0, "no session to persist")
end)

-- A completed job/cache belongs to its accepting cookie/gateway identity.
for _, stage in ipairs({ "active", "cached" }) do
    for _, change in ipairs({ "uid", "api_key", "ticket" }) do
        test(stage .. " upload owner " .. change, function()
            local settings, runner = H.settings(), H.runner()
            settings.store.account, settings.store.api_key = { user_vid = "42" }, "synthetic-api-one"
            local report, env = H.new_report{ settings = settings, subprocess = runner }
            report.ensure_context = function() return H.ready_book(report) end
            local position = { chapter_uid = 6, chapter_offset = 10, percent = 4 }
            report:upload_position("book", position, 0)
            runner.finish(); runner.done = true
            if stage == "cached" then env.scheduler:run_next() end
            if change == "uid" then settings.store.account.user_vid = "other"
            elseif change == "api_key" then settings.store.api_key = "synthetic-api-two"
            else settings.store.wr_ticket = "rotated" end
            local flushes = settings.flushes
            if stage == "active" then env.scheduler:run_next() end
            if change == "ticket" then
                local accepted = report:upload_position("book", position, 0)
                expect(accepted == true and runner.forks == 1, "same-account ticket rotation discarded result")
            else
                expect(report.upload_result == nil or report.upload_result.owner ~= nil, "cache lost owner metadata")
                local accepted, outcome = report:upload_position("book", position, 0)
                expect(not accepted and outcome.error_kind == "pending", "old accepted result crossed owner")
                expect(settings.flushes == flushes, "old result persisted into another owner")
                expect(runner.forks == 2, "fresh owner did not get its own job")
            end
        end)
    end
end

test("account invalidation cancels jobs and caches without writing new settings", function()
    local settings, runner = H.settings(), H.runner()
    local report = H.new_report{ settings = settings, subprocess = runner }
    report.ensure_context = function() return H.ready_book(report) end
    report:upload_position("book", { percent = 4 }, 0)
    report.upload_result = { accepted = true }
    report.server_session_ready, report.server_session_book_id = true, "book"
    local flushes = settings.flushes
    report:on_account_changed()
    expect(report.job == nil and report.upload_result == nil and #runner.terminated == 1,
        "account change kept old job/cache")
    expect(not report.server_session_ready and report.owner_changed, "old session credit retained")
    expect(settings.flushes == flushes, "account invalidation wrote new-owner settings")
end)

test("account change rebuilds the same book context and enters a new server session", function()
    local settings = H.settings()
    settings.store.account = { user_vid = "first" }
    local report, env = H.new_report{ inline = true, settings = settings }
    local book = H.ready_book(report, { read_context_updated_at = env.clock.t,
        chapters = { { chapterUid = 5, chapterIdx = 1, wordCount = 100 } } })
    settings:put_book("book", book)
    local old_session = report.session_id
    settings.store.account.user_vid = "second"
    report:on_account_changed()
    local accepted = report:upload_position("book", { chapter_uid = 5, percent = 4 }, 0)
    expect(accepted and env.client.sent[1].kind == "enter", "new owner skipped enter for the old book session")
    expect(report.session_id ~= old_session and H.content.reader_states == 1,
        "old owner context was reused before its TTL expired")
    expect(settings:get_book("book").read_session_id == report.session_id,
        "new session context did not reach parent persistence")
end)

test("old owner cannot write context or renewed auth", function()
    local report, env = H.new_report()
    local job = job_for(report)
    env.settings.store.api_key = "synthetic-new-api"
    local flushes, updates = env.settings.flushes, #env.settings.auth_updates
    expect(report:_write_back(job, { auth = { cookies = {} }, book = { progress = 50 } }) == false,
        "old job write-back accepted")
    expect(env.settings.flushes == flushes and #env.settings.auth_updates == updates,
        "old job touched new owner")
end)

print(("read_report_lifecycle_spec: %d checks"):format(checks))
