-- Decision-logic coverage for weread/lib/progress_sync.lua: upload vs
-- follow-cloud vs ask, the cloud never moving backwards automatically,
-- upload outcomes (accepted / remote_ahead / failed / busy / pending),
-- offline and error paths, stale results, and local position capture.
-- The cross-chapter "jump window" (pending_jump) is deliberately not pinned.

package.path = "./?.lua;" .. package.path
local ProgressSync = require("weread.lib.progress_sync")
local Book = require("spec.helpers.book_settings")

local checks = 0
local current_test
local function expect(value, label)
    checks = checks + 1
    if not value then
        error(string.format("FAIL [%s] %s", tostring(current_test), label), 2)
    end
end
local function eq(got, want, label)
    expect(got == want, string.format("%s: got %s, want %s",
        label, tostring(got), tostring(want)))
end
local function test(name, fn)
    current_test = name
    fn()
end

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100, title = "One" },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300, title = "Two" },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600, title = "" },
}

-- Cloud progress payload at `percent` of the 1000-word fixture book.
local function cloud(percent)
    local words = percent * 10
    local uid, idx, offset
    if words < 100 then
        uid, idx, offset = 11, 1, words
    elseif words < 400 then
        uid, idx, offset = 22, 2, words - 100
    else
        uid, idx, offset = 33, 3, words - 400
    end
    return {
        bookId = "book", progress = percent, chapterUid = uid,
        chapterIdx = idx, chapterOffset = offset, updateTime = 10,
        summary = "Cloud excerpt",
    }
end

local function fixture(remote, options)
    options = options or {}
    local document = {
        file = "/cache/book/full.epub",
        page = 25,
        getCurrentPage = function(self) return self.page end,
        getPageCount = function() return 100 end,
    }
    local book = { book_id = "book", title = "Book", summary = "Book summary" }
    local values = {
        sync = { pull_on_open = true, upload_on_close = true, ask_on_conflict = true },
        books = { book = book },
    }
    local settings = {
        get = function(_self, key, default) return values[key] or default end,
        set = function(_self, key, value) values[key] = value end,
        flush = function() end,
        is_api_configured = function() return options.api ~= false end,
        is_cookie_configured = function() return options.cookie ~= false end,
    }
    if not options.legacy_settings then Book.install(settings, values.books) end
    local queue = {}
    local f
    local client_calls = 0
    local client = {
        get_progress = function()
            client_calls = client_calls + 1
            if f.on_fetch then f.on_fetch() end
            return { book = f.remote }
        end,
        get_web_progress = function()
            client_calls = client_calls + 1
            return f.remote
        end,
    }
    local online = true
    f = {
        remote = remote,
        document = document,
        values = values,
        book = book,
        queue = queue,
        choices = {},
        uploads = {},
        jumps = {},
        notifications = {},
        client_calls = function() return client_calls end,
        set_online = function(value) online = value end,
    }
    f.upload_result = function() return true, { accepted = true } end
    f.goto_result = function() return true end
    f.sync = ProgressSync:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function(_self, delay, callback)
                queue[#queue + 1] = { delay = delay, callback = callback }
            end,
        },
        get_document = function() return f.document end,
        get_footer = options.get_footer,
        detect_book = function() return f.book_id == nil and "book" or f.book_id end,
        get_book = function(id) return values.books[tostring(id)] end,
        get_chapters = options.get_chapters or function() return chapters end,
        refresh_catalog = options.refresh_catalog,
        get_file_context = function() return nil, nil, true end,
        run_online = options.run_online or function(_kind, callback)
            callback()
            return true
        end,
        upload_position = function(_book_id, position)
            f.uploads[#f.uploads + 1] = position
            return f.upload_result(position)
        end,
        goto_fraction = function(fraction)
            f.jumps[#f.jumps + 1] = fraction
            local ok, err = f.goto_result(fraction)
            if ok then document.page = math.floor(fraction * 100 + 0.5) end
            return ok, err
        end,
        open_chapter = function() return true end,
        on_choice = (not options.default_choice) and function(context)
            f.choices[#f.choices + 1] = context
        end or nil,
        notify = function(code, data)
            f.notifications[#f.notifications + 1] = { code = code, data = data }
        end,
        is_online = function() return online end,
        now = function() return 1000 end,
    }
    function f.drain(limit)
        local count = 0
        while #queue > 0 do
            count = count + 1
            assert(count < (limit or 40), "scheduler did not quiesce")
            table.remove(queue, 1).callback()
        end
        return count
    end
    function f.codes()
        local codes = {}
        for i, item in ipairs(f.notifications) do codes[i] = item.code end
        return table.concat(codes, ",")
    end
    function f.open()
        f.sync:on_reader_ready()
        f.drain()
    end
    return f
end

-- Cloud ahead / local ahead with automatic prompts disabled ---------------

test("prompts off: cloud far ahead is followed without a dialog or upload", function()
    local f = fixture(cloud(50))
    f.values.sync.ask_on_conflict = false
    f.open()
    eq(#f.choices, 0, "no dialog")
    eq(f.jumps[1], 0.5, "jumped to the cloud position")
    eq(#f.uploads, 0, "following the cloud uploads nothing")
    eq(f.sync:status().verified, true, "session verified on the cloud position")
    eq(f.codes(), "", "automatic follow is silent")
end)

test("prompts off: failed jump to the cloud is an error, not a verification", function()
    local f = fixture(cloud(50))
    f.values.sync.ask_on_conflict = false
    f.goto_result = function() return false, "no reader" end
    f.open()
    eq(f.sync:status().state, "error", "state is error")
    eq(f.sync:status().verified, false, "session stays unverified")
    eq(f.codes(), "jump_failed", "jump failure is reported")
    eq(f.notifications[1].data.error, "no reader", "jump error is passed through")
    eq(#f.uploads, 0, "nothing uploaded after a failed jump")
end)

test("prompts off: local far ahead of a foreign cloud is kept, uploaded on close", function()
    local f = fixture(cloud(25))
    f.values.sync.ask_on_conflict = false
    f.document.page = 60
    f.open()
    eq(#f.choices, 0, "no dialog")
    eq(#f.jumps, 0, "no jump backwards")
    eq(#f.uploads, 0, "automatic keep does not upload immediately")
    local status = f.sync:status()
    eq(status.verified and status.dirty, true, "verified and dirty")
    eq(f.sync:position_for_report("book").percent, 60, "reports carry local progress")
    f.sync:on_close_document()
    eq(f.book.pending_upload_position.percent, 60, "close persists the newer local position")
end)

-- Choice dialog contents and answers --------------------------------------

test("choice shows chapter titles and flags keeping an older local position", function()
    local f = fixture(cloud(50))
    f.open()
    local choice = f.choices[1]
    eq(choice.local_position.chapter_title, "Two", "local chapter title from catalog")
    eq(choice.remote_position.chapter_title, "Cloud excerpt",
        "untitled chapter falls back to the position summary")
    eq(choice.book_title, "Book", "book title")
    eq(choice.local_behind_remote, true, "keeping local would move the cloud back")
    eq(choice.source_conflict, false, "sources agree")
    local position, reason = f.sync:position_for_report("book")
    eq(position, nil, "no report while awaiting an answer")
    eq(reason, "progress_unverified", "report is gated")
end)

test("manual cloud choice jumps and confirms; failed jump reports an error", function()
    local f = fixture(cloud(25))
    f.open()
    f.remote = cloud(50)
    f.sync:sync_now()
    f.choices[1].use_remote()
    eq(f.jumps[1], 0.5, "manual cloud choice jumps")
    eq(f.codes(), "remote_applied", "manual cloud choice is confirmed")
    eq(#f.uploads, 0, "choosing the cloud uploads nothing")

    f = fixture(cloud(50))
    f.goto_result = function() return false, "render busy" end
    f.open()
    f.choices[1].use_remote()
    eq(f.sync:status().state, "error", "failed cloud choice is an error")
    eq(f.codes(), "jump_failed", "failed cloud choice is reported")
    eq(f.sync:status().verified, false, "failed cloud choice does not verify")
end)

test("stale choice callbacks do nothing after the book changed", function()
    local f = fixture(cloud(50))
    f.open()
    local choice = f.choices[1]
    f.book_id = "other"
    choice.keep_local()
    choice.use_remote()
    choice.dismiss()
    eq(#f.uploads + #f.jumps, 0, "no upload or jump for another book")
    eq(f.sync.choice, choice, "dialog stays registered")
end)

test("without a choice handler a conflict keeps local and uploads it unguarded", function()
    local f = fixture(cloud(50), { default_choice = true })
    f.open()
    eq(#f.uploads, 1, "explicit local choice is uploaded")
    eq(f.uploads[1].percent, 25, "local position uploaded")
    eq(f.uploads[1].guard, nil, "an explicit choice is sent without a guard")
    eq(f.codes(), "upload_success", "upload result is shown")
end)

test("a cloud position the read report re-asserted is not this device's own", function()
    local f = fixture(cloud(25))
    f.book.reported_local = true
    f.book.reported_local_owner = require("weread.lib.request_owner").digest(f.sync.session_owner)
    f.book.chapter_uid, f.book.chapter_offset, f.book.progress = 22, 150, 25
    f.document.page = 60
    f.open()
    eq(#f.choices, 0, "own reported position: local ahead is kept quietly")
    eq(f.sync:status().verified, true, "verified")

    f = fixture(cloud(25))
    f.book.reported_local = false
    f.book.chapter_uid, f.book.chapter_offset, f.book.progress = 22, 150, 25
    f.document.page = 60
    f.open()
    eq(#f.choices, 1, "re-asserted cloud position does not count as a baseline")
end)

-- Upload outcomes ----------------------------------------------------------

local function verified_and_moved(f, page)
    f.open()
    expect(f.sync:status().verified, "fixture session verified")
    f.document.page = page
    f.sync:on_page_update()
end

test("remote_ahead: older snapshot dropped, cloud kept as a floor", function()
    local f = fixture(cloud(25))
    f.values.sync.pull_on_open = false
    f.sync:sync_now()
    expect(f.sync:status().verified, "manual sync verifies")
    f.document.page = 50
    f.sync:on_page_update()
    local ahead = { chapter_uid = 33, chapter_offset = 300, percent = 70 }
    f.upload_result = function()
        return false, { error_kind = "remote_ahead", remote = ahead }
    end
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "one guarded attempt")
    expect(type(f.uploads[1].guard) == "table" and f.uploads[1].guard.strict,
        "automatic upload carries a strict guard")
    eq(f.book.pending_upload_position, nil, "rejected snapshot is not retried")
    eq(f.book.last_sync_error, nil, "remote_ahead is not an error")
    eq(f.book.last_remote_position.percent, 25,
        "foreign cloud position is not recorded as a baseline")
    expect(f.sync:status().state ~= "error", "remote_ahead is not an error state")

    local report = f.sync:position_for_report("book")
    eq(report.percent, 70, "reports carry the cloud floor while behind it")
    eq(report.cloud, true, "floor report is marked as cloud position")

    -- Suspending below the floor queues nothing: cloud never moves back.
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "no upload below the cloud floor")

    f.document.page = 80
    report = f.sync:position_for_report("book")
    eq(report.percent, 80, "reading past the floor reports local again")
    eq(report.cloud, nil, "local report is not marked cloud")
    eq(f.sync.remote_floor, nil, "passed floor is cleared")
end)

test("remote_ahead with pulls on open re-checks and asks", function()
    local f = fixture(cloud(25))
    verified_and_moved(f, 50)
    f.remote = cloud(70)
    f.upload_result = function()
        return false, { error_kind = "remote_ahead",
            remote = { chapter_uid = 33, chapter_offset = 300, percent = 70 } }
    end
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "only the rejected attempt")
    eq(#f.choices, 1, "cloud moved: the reader is asked")
    eq(f.choices[1].local_behind_remote, true, "keeping local needs confirmation")
    eq(f.sync:status().verified, false, "session no longer verified")
end)

test("failed upload stays pending with the error recorded", function()
    local f = fixture(cloud(25))
    verified_and_moved(f, 50)
    f.upload_result = function() return false, { error = "HTTP 500 from gateway" } end
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "one attempt")
    eq(f.sync:status().state, "error", "state is error")
    eq(f.book.pending_upload_position.percent, 50, "position stays pending for later")
    expect(tostring(f.book.last_sync_error):find("HTTP 500", 1, true),
        "error text is recorded")
    eq(f.codes(), "", "automatic failure is silent")

    -- The next resume retries the persisted position and clears it on success.
    f.upload_result = function() return true, { accepted = true } end
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 2, "retried after the next resume")
    eq(f.uploads[2].percent, 50, "same position retried")
    eq(f.book.pending_upload_position, nil, "success clears the pending position")
    eq(f.book.last_uploaded_position.percent, 50, "accepted position recorded")
    eq(f.sync:status().dirty, false, "uploaded position is no longer dirty")
end)

test("a throwing upload is kept pending", function()
    local f = fixture(cloud(25))
    verified_and_moved(f, 50)
    f.upload_result = function() error("worker crashed") end
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(f.sync:status().state, "error", "state is error")
    eq(f.book.pending_upload_position.percent, 50, "position kept for later")
    expect(f.book.last_sync_error ~= nil, "failure is recorded")
end)

test("explicit local choice: failure is shown and the retry is guarded", function()
    local f = fixture(cloud(50))
    f.open()
    f.upload_result = function() return false, { error = "HTTP 502" } end
    f.choices[1].keep_local()
    eq(#f.uploads, 1, "one attempt")
    eq(f.uploads[1].guard, nil, "first explicit attempt is unguarded")
    eq(f.codes(), "upload_failed", "failure is shown to the reader")
    expect(f.notifications[1].data.error:find("HTTP 502", 1, true), "error text shown")
    eq(f.book.pending_upload_reason, "explicit_local_choice", "pending reason")
    eq(f.book.pending_upload_baselines[1].percent, 50,
        "retry is guarded by the cloud position the reader replaced")
end)

test("manual retries survive disabled automatic uploads, reopen and repeated busy", function()
    local f = fixture(cloud(50))
    f.values.sync.upload_on_close = false
    f.open()
    f.upload_result = function() return false, { error_kind = "busy" } end
    f.choices[1].keep_local()
    f.drain()
    eq(#f.uploads, 10, "the busy retry chain is bounded")
    eq(f.book.pending_upload_reason, "explicit_local_choice", "manual intent stays durable")
    f.document.page = 60
    f.sync:on_page_update()
    f.sync:on_close_document()
    f.open()
    eq(#f.uploads, 20, "automatic pull retries the old choice despite the close switch")
    eq(f.uploads[11].percent, 25, "new reading does not replace the requested snapshot")
    eq(f.uploads[11].guard.strict, true, "restored choice is guarded")
    eq(f.uploads[11].guard.baselines[1].percent, 50, "original cloud baseline survives pull")
    eq(f.book.pending_upload_reason, "explicit_local_choice", "second busy failure preserves reason")
    f.upload_result = function() return true, { accepted = true } end
    f.sync:on_suspend()
    f.sync.suspended_at = 600 -- force the natural five-minute resume recheck.
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 21, "resume recovers after the slot becomes free")
    eq(f.uploads[21].percent, 25, "resume also preserves the original choice")
    eq(f.book.pending_upload_position, nil, "accepted retry clears the durable request")
    eq(f.sync:status().dirty, true, "newer local reading is still dirty")
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    f.sync:on_close_document()
    eq(#f.uploads, 21, "disabled close and suspend do not upload the newer reading")
    eq(f.book.pending_upload_position, nil, "disabled automatic uploads stay disabled")
end)

test("manual pending is owner-bound and never requires a whole-library scan", function()
    local f = fixture(cloud(50))
    f.values.sync.upload_on_close = false
    f.open()
    f.upload_result = function() return false, { error_kind = "busy" } end
    f.choices[1].keep_local()
    f.drain()
    f.sync.settings.get_books = function() error("manual recovery must not scan every book") end
    f.values.account = { user_vid = "another-reader" }
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 10, "account change never dispatches the old choice")
    eq(f.book.pending_upload_position.percent, 25, "old owner's disk request is not cleared")
    f.sync:on_close_document()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 10, "resume without an open book does not scan or send")
end)

test("explicit local choice while offline waits and reports offline once", function()
    local f = fixture(cloud(50))
    f.open()
    f.set_online(false)
    f.choices[1].keep_local()
    eq(#f.uploads, 0, "nothing sent offline")
    eq(f.sync:status().state, "offline", "state is offline")
    eq(f.codes(), "offline", "reader is told once")
    eq(f.book.pending_upload_position.percent, 25, "choice is persisted")
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(f.codes(), "offline", "no second offline notice")
    f.set_online(true)
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "sent once the link is back")
    eq(f.uploads[1].percent, 25, "the chosen position is sent")
end)

test("busy uploads give up after the retry limit", function()
    local f = fixture(cloud(25))
    verified_and_moved(f, 50)
    f.upload_result = function() return false, { error = "busy", error_kind = "busy" } end
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 10, "busy retried up to the limit")
    eq(f.sync:status().state, "error", "then reported as an error")
    eq(f.book.pending_upload_position.percent, 50, "position kept for later")
end)

test("a background job that never finishes stops being polled", function()
    local f = fixture(cloud(25))
    verified_and_moved(f, 50)
    f.upload_result = function() return false, { error = "pending", error_kind = "pending" } end
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain(100)
    eq(#f.uploads, 61, "first submit plus the poll limit")
    eq(f.sync:status().state, "error", "unfinished job is a failure")
    eq(f.sync:status().uploading, false, "upload slot released")
end)

test("an upload in flight survives a document switch", function()
    local f = fixture(cloud(25))
    verified_and_moved(f, 50)
    f.sync:on_close_document()
    f.values.sync.pull_on_open = false
    f.upload_result = function() return false, { error_kind = "pending" } end
    f.sync:on_reader_ready()
    -- Run only the open timer: the upload starts and stays in flight.
    table.remove(f.queue, 1).callback()
    eq(#f.uploads, 1, "pending position submitted after open")
    eq(f.sync:status().uploading, true, "upload in flight")
    f.upload_result = function() return true, { accepted = true } end
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.uploads, 2, "requeued upload is sent again, old poll ignored")
    eq(f.uploads[2].percent, 50, "same position")
    eq(f.book.pending_upload_position, nil, "pending cleared after success")
end)

-- Pull error and offline paths --------------------------------------------

test("manual sync explains why it cannot run", function()
    local f = fixture(cloud(25), { api = false, cookie = false })
    f.open()
    eq(f.sync:sync_now(), false, "not logged in")
    eq(f.codes(), "authentication_required", "login required")

    f = fixture(cloud(25))
    f.document = nil
    eq(f.sync:sync_now(), false, "no document")
    eq(f.codes(), "local_unavailable", "local position unavailable")
    eq(f.notifications[1].data.error, "document_unavailable", "reason passed on")

    f = fixture(cloud(25), { run_online = function() return false end })
    eq(f.sync:sync_now(), false, "online task refused")
    eq(f.codes(), "offline", "manual refusal is reported as offline")
    eq(#f.queue, 0, "manual refusal schedules no retry")
    eq(f.client_calls(), 0, "no request sent")
end)

test("a pull deferred past suspend or teardown never touches the network", function()
    local deferred = {}
    local f = fixture(cloud(25), { run_online = function(_kind, callback)
        deferred[#deferred + 1] = callback
        return true
    end })
    f.open()
    eq(#deferred, 1, "automatic pull handed to run_online")
    f.sync:on_suspend()
    deferred[1]()
    eq(f.client_calls(), 0, "no request while suspended")
    eq(f.sync:status().pulling, false, "pull no longer marked in flight")
    f.sync:on_resume()
    eq(f.sync:sync_now(), true, "a later pull can start")
    f.sync:teardown("closed")
    deferred[#deferred]()
    eq(f.client_calls(), 0, "no request after teardown")
end)

test("a pull result for a book that is no longer open is ignored", function()
    local f = fixture(cloud(50))
    f.on_fetch = function() f.book_id = "other" end
    f.open()
    eq(#f.choices, 0, "no dialog for a closed book")
    eq(f.book.last_remote_position, nil, "stale result not persisted")
    eq(f.sync:status().pulling, false, "pull finished")
end)

test("a superseded retry token cannot start a pull", function()
    local f = fixture(cloud(25))
    f.sync.pull_retry_token = 5
    eq(f.sync:_pull({ manual = false, retry_token = 4 }), false, "stale retry refused")
    eq(f.client_calls(), 0, "no request")
end)

test("manual catalog refresh: failure and empty results", function()
    local catalog = {}
    local f = fixture(cloud(25), {
        get_chapters = function() return catalog end,
        refresh_catalog = function() error("catalog HTTP 503") end,
    })
    eq(f.sync:sync_now(), true, "manual sync starts despite missing catalog")
    eq(f.sync:status().state, "error", "refresh failure is an error")
    eq(f.codes(), "local_unavailable", "reader is told")
    expect(tostring(f.notifications[1].data.error):find("catalog HTTP 503", 1, true),
        "refresh error is passed on")
    eq(f.sync:status().pulling, false, "pull not left in flight")

    -- The refresh returns nothing but the catalog appeared meanwhile.
    f.notifications = {}
    f.sync.refresh_catalog = function()
        catalog = chapters
        return {}
    end
    eq(f.sync:sync_now(), true, "manual sync starts")
    eq(f.sync:status().verified, true, "catalog found after refresh: verified")
    eq(f.codes(), "already_synced", "positions match")
end)

-- Open, report and local capture ------------------------------------------

test("open skips unsupported documents", function()
    local f = fixture(cloud(25))
    f.book_id = false
    f.open()
    eq(f.sync:status().state, "unsupported", "no WeRead book")
    f.book_id = "MP_WXS_123"
    f.open()
    eq(f.sync:status().state, "unsupported", "official-account article")
    eq(f.client_calls(), 0, "no pull for unsupported documents")
    f.sync:on_page_update()
    eq(f.sync:status().local_position, nil, "page updates ignored without a book")
end)

test("position_for_report gates by book and capture", function()
    local f = fixture(cloud(25))
    f.open()
    local position, reason, applies = f.sync:position_for_report("other")
    expect(position == nil and reason == nil and applies == false, "other book does not apply")
    f.book_id = "MP_WXS_1"
    position, reason, applies = f.sync:position_for_report("MP_WXS_1")
    expect(position == nil and reason == nil and applies == false, "MP article does not apply")
    f.book_id = nil
    f.document.page = 40
    position = f.sync:position_for_report("book")
    eq(position.percent, 40, "live position reported")
    eq(f.sync:status().dirty, true, "moved position marks dirty")
    f.document = {}
    position, reason, applies = f.sync:position_for_report("book")
    expect(position == nil and reason == "document_unavailable" and applies,
        "capture failure is a gate reason")
end)

test("local capture falls back across document APIs", function()
    local footer = {}
    local f = fixture(cloud(25), { get_footer = function() return footer end })
    footer.percent_finished = 60
    eq(f.sync:capture_local().percent, 60, "footer percent (0-100)")
    footer.percent_finished = 0.3
    eq(f.sync:capture_local().percent, 30, "footer fraction (0-1)")
    footer.percent_finished = 250
    eq(f.sync:capture_local().percent, 100, "footer clamped")
    footer.percent_finished = nil

    f.document = {
        getFilePath = function() return "/cache/book/full.epub" end,
        getCurrentPage = function() error("no page") end,
        getPageNumber = function() return 45 end,
        getPageCount = function() return 100 end,
    }
    eq(f.sync:capture_local().percent, 45, "page number fallback via getFilePath")

    f.document = { file = "/cache/book/full.epub", current_pos = 300, info = { doc_height = 1000 } }
    eq(f.sync:capture_local().percent, 30, "scroll position fallback")
    f.document = { file = "/cache/book/full.epub", current_pos = 2000, doc_height = 1000 }
    eq(f.sync:capture_local().percent, 100, "scroll position clamped")
    f.document = { file = "/cache/book/full.epub" }
    local position, reason = f.sync:capture_local()
    expect(position == nil and reason == "position_unavailable", "no position API")

    f.book_id = "MP_WXS_9"
    position, reason = f.sync:capture_local()
    expect(position == nil and reason == "document_not_weread", "MP article")
    f.book_id = "missing"
    f.document = { file = "/x.epub" }
    position, reason = f.sync:capture_local()
    expect(position == nil and reason == "book_not_found", "unknown book")
end)

-- Legacy settings without the per-book API ---------------------------------

test("legacy settings store pending uploads in the books table", function()
    local f = fixture(cloud(25), { legacy_settings = true })
    verified_and_moved(f, 50)
    f.sync:on_close_document()
    eq(f.values.books.book.pending_upload_position.percent, 50,
        "pending upload persisted through settings:set")
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "persisted position found through settings:get")
    eq(f.values.books.book.pending_upload_position, nil, "cleared after upload")
end)

test("the per-book store returns a pending upload on resume (control)", function()
    local f = fixture(cloud(25))
    f.open()
    f.book.pending_upload_position = { percent = 40 }
    f.book.pending_upload_owner = require("weread.lib.request_owner").digest(
        require("weread.lib.request_owner").capture(f.sync.settings))
    f.sync:on_close_document()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "pending position from the per-book store uploaded once")
end)

test("a broken book store does not break resume", function()
    local f = fixture(cloud(25))
    f.open()
    f.book.pending_upload_position = { percent = 40 }
    f.book.pending_upload_owner = require("weread.lib.request_owner").digest(
        require("weread.lib.request_owner").capture(f.sync.settings))
    f.sync.settings.get_books = function() error("db locked") end
    f.sync:on_close_document()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 0, "nothing uploaded when the store cannot be listed")
end)

-- The OS runner and JSON codec are fixtures; ProgressSync, ReadReport,
-- ForkBudget, Settings' per-book API and BookStore's disk writes are actual.
test("shared-slot manual retry reloads from Settings and BookStore before a fresh pull", function()
    local modules = {}
    for _, name in ipairs({ "json", "datastorage", "luasettings", "libs/libkoreader-lfs",
        "weread.lib.book_store", "weread.lib.settings" }) do
        modules[name] = { preload = package.preload[name], loaded = package.loaded[name] }
        package.loaded[name] = nil
    end
    local case_ok, case_err = xpcall(function()
        local H = require("spec.helpers.read_report_harness")
        local Budget = require("weread.lib.fork_budget")
        local encoded = {}
        local function clone(value)
            if type(value) ~= "table" then return value end
            local out = {}
            for key, item in pairs(value) do out[key] = clone(item) end
            return out
        end
        package.preload["json"] = function()
            return {
                encode = function(value)
                    encoded[#encoded + 1] = clone(value)
                    return tostring(#encoded)
                end,
                decode = function(value) return clone(assert(encoded[tonumber(value)])) end,
            }
        end
        require("weread.lib.book_store")
        package.preload["datastorage"] = function() return {} end
        package.preload["luasettings"] = function() return {} end
        package.preload["libs/libkoreader-lfs"] = function() return {} end
        local Settings = require("weread.lib.settings")
        local root = os.tmpname()
        os.remove(root)
        root = root .. "-manual-retry"
        local f = fixture(cloud(50))
        f.values.books = {}
        f.values.api_key = "test-key"
        f.values.account = { user_vid = "42" }
        f.values.cookies = { wr_vid = "42", wr_skey = "key" }
        f.values.sync.upload_on_close = false
        local store = {
            readSetting = function(_, key, default) return f.values[key] or default end,
            saveSetting = function(_, key, value) f.values[key] = value end,
            flush = function() end,
        }
        local function settings_instance()
            return setmetatable({ store = store, cache_dir = root }, Settings)
        end
        local settings = settings_instance()
        settings:put_book("book", f.book)
        f.sync.settings = settings
        f.sync.get_book = function(id) return f.sync.settings:get_book(id) end
        local holder_done, reaped = false, 0
        local holder = {
            run = function() return 9001 end,
            is_done = function()
                if holder_done then reaped = reaped + 1 end
                return holder_done
            end,
        }
        local runner = H.runner()
        local report, env = H.new_report{ settings = settings, subprocess = runner }
        report.ensure_context = function()
            return H.ready_book(report, { chapter_uid = 22, chapter_idx = 2,
                chapter_offset = 150, progress = 25, chapters = chapters })
        end
        report.client.web_progress = cloud(50)
        report.client.progress = { book = cloud(50) }
        local seen = {}
        f.upload_result = function(position)
            seen[#seen + 1] = clone(position)
            local accepted, outcome = report:upload_position("book", position, 0)
            if outcome and outcome.error_kind == "pending" and runner.child then
                runner.finish()
                runner.done = true
                env.scheduler:run_next()
            end
            return accepted, outcome
        end
        local memory_ok, memory_err = H.with_memory(function()
            expect(Budget.run(holder, function() end) == 9001, "unrelated worker owns the slot")
            f.open()
            f.choices[1].keep_local()
            f.drain()
            eq(#seen, 10, "actual ReadReport reports busy for the bounded retry chain")
            eq(runner.forks, 0, "busy path never starts an upload child")
            local pending = settings:get_book("book")
            eq(pending.pending_upload_reason, "explicit_local_choice", "reason survived real book reload")
            eq(pending.pending_upload_position.percent, 25, "original choice survived real book reload")
            local path = root .. "/book/reading_state.json"
            local file = assert(io.open(path, "rb"))
            local reading = require("json").decode(file:read("*a")); file:close()
            expect(reading.pending_upload_owner ~= nil and reading.pending_upload_baselines ~= nil
                and reading.pending_upload_reason == "explicit_local_choice",
                "position, owner, baselines and intent share the atomic reading-state file")
            f.sync:on_close_document()
            -- A fresh Settings instance has no BookStore cache. Reopening runs
            -- the actual automatic pull before the strict guarded upload.
            f.sync.settings = settings_instance()
            f.document.page = 60
            holder_done = true
            f.open()
            eq(runner.forks, 1, "manual request starts after the shared slot is free")
            eq(reaped, 1, "the prior worker was exactly reaped before admission")
            eq(seen[11].percent, 25, "restored upload keeps the requested snapshot")
            eq(seen[11].guard.strict, true, "restored upload has the real strict guard")
            eq(seen[11].guard.baselines[1].percent, 50, "original baseline reaches ReadReport")
            eq(#report.client.sent, 1, "actual child pipeline reported in the existing session")
            eq(report.client.sent[1].chapter_offset, 150, "actual POST uses the original manual chapter offset")
            eq(f.sync.settings:get_book("book").pending_upload_position, nil,
                "successful parent apply clears the durable request")
        end)
        holder_done = true
        H.finish_runners()
        Budget.available()
        for _, name in ipairs({ "metadata", "reading_state", "articles" }) do
            os.remove(root .. "/book/" .. name .. ".json")
        end
        os.execute("rmdir '" .. root .. "/book' '" .. root .. "' 2>/dev/null")
        expect(memory_ok, tostring(memory_err))
    end, debug.traceback)
    for name, original in pairs(modules) do
        package.preload[name], package.loaded[name] = original.preload, original.loaded
    end
    expect(case_ok, tostring(case_err))
end)

print(string.format("progress_sync_decisions_spec: %d checks passed", checks))
