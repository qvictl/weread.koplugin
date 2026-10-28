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
    f.sync:on_close_document()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "pending position from the per-book store uploaded once")
end)

test("a broken book store does not break resume", function()
    local f = fixture(cloud(25))
    f.open()
    f.book.pending_upload_position = { percent = 40 }
    f.sync.settings.get_books = function() error("db locked") end
    f.sync:on_close_document()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 0, "nothing uploaded when the store cannot be listed")
end)

print(string.format("progress_sync_decisions_spec: %d checks passed", checks))
