-- Unit tests for weread/lib/progress_sync.lua.
-- Run from the repo root with:
--   lua spec/progress_sync_spec.lua

package.path = "./?.lua;" .. package.path
local ProgressSync = require("weread.lib.progress_sync")

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

-- Mirrors PULL_RETRY_DELAY_SECONDS in weread/lib/progress_sync.lua.
local PULL_RETRY_DELAY_SECONDS = 15

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600 },
}

local function fixture(remote, options)
    options = options or {}
    local document = {
        file = "/cache/book/full.epub",
        page = 25,
        getCurrentPage = function(self) return self.page end,
        getPageCount = function() return 100 end,
    }
    local book = {
        book_id = "book",
        title = "Book",
        summary = "Book",
        cached_file = document.file,
        cached_chapters = {
            ["11"] = document.file,
            ["22"] = document.file,
            ["33"] = document.file,
        },
    }
    local values = {
        sync = {
            pull_on_open = true,
            upload_on_close = true,
            ask_on_conflict = true,
        },
        books = { book = book },
    }
    local settings = require("spec.helpers.book_settings").install({
        get = function(_self, key, default)
            return values[key] or default
        end,
        set = function(_self, key, value)
            values[key] = value
        end,
        flush = function() end,
        is_api_configured = function() return true end,
        is_cookie_configured = function() return true end,
    }, values.books)
    local queue = {}
    local scheduler = {
        scheduleIn = function(_self, delay, callback)
            queue[#queue + 1] = { delay = delay, callback = callback }
        end,
    }
    local choices = {}
    local uploads = {}
    local jumps = {}
    local notifications = {}
    local client = {
        get_progress = function()
            return { book = remote }
        end,
        get_web_progress = function()
            return remote
        end,
    }
    local sync = ProgressSync:new{
        settings = settings,
        client = client,
        scheduler = scheduler,
        get_document = function() return document end,
        detect_book = function() return "book" end,
        get_book = function() return book end,
        get_chapters = options.get_chapters or function() return chapters end,
        refresh_catalog = options.refresh_catalog,
        fetch_catalog = options.fetch_catalog,
        apply_catalog = options.apply_catalog,
        request = options.request,
        get_file_context = function()
            return nil, nil, true
        end,
        run_online = options.run_online or function(_kind, callback)
            callback()
            return true
        end,
        upload_position = function(_book_id, position, elapsed)
            uploads[#uploads + 1] = position
            eq(elapsed, 0, "progress upload has zero reading time")
            return true, { accepted = true }
        end,
        goto_fraction = function(fraction)
            jumps[#jumps + 1] = fraction
            document.page = math.floor(fraction * 100 + 0.5)
            return true
        end,
        open_chapter = function() return true end,
        on_choice = function(context)
            choices[#choices + 1] = context
        end,
        notify = function(code, data)
            notifications[#notifications + 1] = { code = code, data = data }
        end,
        is_online = options.is_online,
        now = options.now,
    }
    local function step()
        local entry = table.remove(queue, 1)
        if not entry then return false end
        entry.callback()
        return true
    end
    local function drain()
        local count = 0
        while #queue > 0 do
            count = count + 1
            assert(count < 20, "scheduler did not quiesce")
            step()
        end
    end
    return {
        sync = sync,
        document = document,
        values = values,
        choices = choices,
        uploads = uploads,
        jumps = jumps,
        notifications = notifications,
        queue = queue,
        step = step,
        drain = drain,
    }
end

local Mapper = require("weread.lib.position_mapper")
local actual = require("spec.helpers.yan_word_counts")
local function position(uid, fraction)
    return assert(Mapper.local_to_remote(actual, fraction, {current_chapter_uid=uid}))
end
local function remote(uid, offset)
    return assert(Mapper.normalize_remote({progress=0, chapterUid=uid, chapterOffset=offset}, "book", "web", actual))
end
test("saved next chapter opening tolerates the previous chapter boundary", function()
    eq(Mapper.compare(position(6, 1/60), remote(5, 3555), 2), "same",
        "actual saved opening does not prompt")
end)

test("compare uses unrounded local progress at the two percent boundary", function()
    local local_position = position(6, 1/60)
    local remote_position = remote(6, 14515)
    local exact_gap = remote_position.percent - local_position.fraction*100
    eq(exact_gap < 2, true, "actual difference is within policy")
    eq(Mapper.compare(local_position, remote_position, 2), "same", "no false conflict caused by flooring")
end)

test("a different nearby chapter remains available to manual sync", function()
    local f = fixture(nil)
    f.sync.get_chapters = function() return actual end
    local a=position(3,1); a.book_id="book"
    local b=remote(5,3555)
    f.sync:_resolve(a,b,{book_id="book",book=f.values.books.book,chapters=actual},{manual=true})
    eq(#f.choices, 1, "manual sync can choose a genuinely different chapter")
    local opened
    f.sync.open_chapter = function(_book, chapter)
        opened = chapter.chapterUid
        return true
    end
    f.choices[1].use_remote()
    eq(opened, 5, "cloud choice opens the correct chapter")
    eq(f.sync.pending_jump.fraction, 1, "cloud choice preserves chapter end")
end)

test("manual sync offers a choice even when automatic conflict prompts are disabled", function()
    local f = fixture(nil)
    f.values.sync.ask_on_conflict = false
    local a = position(3, 1)
    a.book_id = "book"
    f.sync:_resolve(a, remote(5, 3555), {
        book_id = "book", book = f.values.books.book, chapters = actual,
    }, { manual = true })
    eq(#f.choices, 1, "manual action still offers position recovery")
end)

test("exact matching manual progress needs no choice despite integer percent", function()
    local f = fixture(nil)
    local a = position(6, 1/60)
    a.book_id = "book"
    f.sync:_resolve(a, remote(6, a.chapter_offset), {
        book_id = "book", book = f.values.books.book, chapters = actual,
    }, { manual = true })
    eq(#f.choices, 0, "exact position does not prompt")
    eq(f.notifications[1].code, "already_synced", "exact match is acknowledged")
end)

test("page turns reuse word counts and document changes rebuild them", function()
    local word_reads = 0
    local function chapter(uid, words)
        return setmetatable({ chapterUid = uid }, { __index = function(_, key)
            if key == "wordCount" then
                word_reads = word_reads + 1
                return words
            end
        end })
    end
    local catalog = {}
    for index = 1, 5000 do catalog[index] = chapter(index, 10) end
    local f = fixture(nil, { get_chapters = function() return catalog end })
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready()
    f.drain()
    eq(word_reads, 5000, "opening builds one word-count catalog")
    for page = 26, 80 do
        f.document.page = page
        f.sync:on_page_update()
    end
    eq(word_reads, 5000, "page turns do not reread chapter word counts")
    eq(f.sync.local_position.chapter_uid, 4001, "page turn chapter")
    eq(f.sync.local_position.chapter_offset, 0, "page turn offset")

    catalog = { chapter(44, 200), chapter(55, 800) }
    f.document.page = 50
    f.sync.detect_book = function() return "other" end
    local position = assert(f.sync:capture_local())
    eq(word_reads, 5002, "changed book rebuilds catalog even at the same path")
    eq(position.book_id, "other", "fresh book detection is preserved")
    eq(position.chapter_uid, 55, "new book chapter")
    eq(position.chapter_offset, 300, "new book offset")

    f.document.file = "/cache/other/chapter.epub"
    f.sync.get_file_context = function() return 1, catalog[1], false end
    position = assert(f.sync:capture_local())
    eq(word_reads, 5004, "changed file rebuilds catalog")
    eq(position.chapter_uid, 44, "single chapter file")
    eq(position.chapter_offset, 100, "single chapter offset")
    eq(position.percent, 10, "single chapter overall progress")
    f.sync:on_close_document()
    eq(f.sync.document_context, nil, "close releases the document catalog")
    f.sync:on_reader_ready()
    f.drain()
    eq(word_reads, 5006, "reopen rebuilds catalog")
end)

test("matching open progress verifies the reporting gate", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "session verified")
    eq(#f.choices, 0, "no conflict dialog")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(applies, true, "provider applies")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
    eq(position.chapter_offset, 150, "live offset")
end)

test("nearby progress within two percent is treated as aligned", function()
    local f = fixture({
        bookId = "book",
        progress = 26.9,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 169,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "nearby position verifies")
    eq(#f.choices, 0, "nearby position does not prompt")
    eq(#f.jumps, 1, "nearby cloud progress ahead is followed")
    eq(f.jumps[1], 0.269, "jump to the cloud position")
    local position = f.sync:position_for_report("book")
    eq(position.percent >= 26, true, "reports never send the older local position")
end)

test("nearby local progress ahead is kept without asking", function()
    local f = fixture({
        bookId = "book",
        progress = 23.1,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 131,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "local ahead verifies")
    eq(#f.choices, 0, "no prompt")
    eq(#f.jumps, 0, "no jump backwards")
    eq(f.sync:position_for_report("book").percent, 25, "reports carry local progress")
end)

test("nearby cloud progress in another chapter file becomes a report floor", function()
    local f = fixture({
        bookId = "book",
        progress = 41,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 10,
        updateTime = 10,
    })
    local opened = 0
    f.sync.get_file_context = function() return 2, chapters[2], false end
    f.sync.open_chapter = function() opened = opened + 1 return true end
    f.document.page = 99
    f.sync:on_reader_ready()
    f.drain()
    eq(opened, 0, "no chapter file is opened behind the reader's back")
    eq(#f.choices, 0, "no prompt")
    eq(f.sync:status().verified, true, "session verified")
    local position = f.sync:position_for_report("book")
    eq(position.chapter_uid, 33, "report carries the cloud chapter")
    eq(position.chapter_offset, 10, "report carries the cloud offset")
    f.sync:on_close_document()
    eq(#f.uploads, 0, "close never uploads below the floor")
end)

test("cloud unchanged since this device wrote it: local far ahead wins quietly", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.values.books.book.last_uploaded_position = {
        chapter_uid = 22, chapter_offset = 150, percent = 25,
    }
    f.document.page = 60
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 0, "own progress does not prompt")
    eq(f.sync:status().verified, true, "local kept and verified")
    eq(f.sync:position_for_report("book").percent, 60, "local progress is reported")
end)

test("cloud moved elsewhere: local far ahead still asks", function()
    local f = fixture({
        bookId = "book",
        progress = 30,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 200,
        updateTime = 10,
    })
    f.values.books.book.last_uploaded_position = {
        chapter_uid = 22, chapter_offset = 150, percent = 25,
    }
    f.document.page = 60
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "foreign cloud change asks")
    eq(f.choices[1].local_behind_remote, false, "keeping local moves forward")
end)

test("a dismissed choice reports time with the cloud position", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].dismiss()
    local position, reason, applies = f.sync:position_for_report("book")
    eq(applies, true, "provider applies")
    eq(reason, nil, "reporting continues")
    eq(position.chapter_uid, 33, "cloud chapter is re-sent")
    eq(position.chapter_offset, 100, "cloud offset is re-sent")
end)

test("unresolved conflict blocks reports and local choice uploads", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "conflict dialog requested")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position, nil, "position withheld")
    eq(reason, "progress_unverified", "gate reason")
    eq(applies, true, "provider applies")
    f.choices[1].keep_local()
    eq(f.sync:status().verified, true, "local choice verifies")
    eq(#f.uploads, 1, "local choice uploads immediately")
    eq(f.uploads[1].chapter_offset, 150, "uploaded immutable position")
end)

test("page change uploads once on close", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 50
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "page change marks dirty")
    f.sync:on_close_document()
    eq(#f.uploads, 0, "close never touches the network")
    eq(#f.queue, 0, "close schedules nothing")
    local pending = f.values.books.book.pending_upload_position
    eq(pending and pending.percent, 50, "close persists the current percent")
    eq(pending and pending.chapter_uid, 33, "close persists the current chapter")

    -- The next open sends it: the cloud still holds what this device saw,
    -- so the newer local position is kept and uploaded without a prompt.
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 0, "own progress does not prompt")
    eq(#f.uploads, 1, "uploaded once after reopening")
    eq(f.uploads[1].percent, 50, "uploads the closed position")
    eq(f.uploads[1].chapter_uid, 33, "uploads the closed chapter")
    eq(f.values.books.book.pending_upload_position, nil,
        "successful upload clears pending snapshot")
end)

test("remote choice jumps and verifies before reporting", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    f.drain()
    eq(#f.jumps, 1, "one jump")
    eq(f.jumps[1], 0.5, "jump fraction")
    eq(f.sync:status().verified, true, "remote choice verifies")
    local position = f.sync:position_for_report("book")
    eq(position.percent, 50, "report sees jumped position")
end)

-- Cloud jumps vs. the reader's own page turns. KOReader announces a
-- GotoPercent with a PageUpdate dispatched synchronously inside the call
-- (ReaderRolling:_gotoPage) and may repeat it for the same page later (a
-- re-render repositions on the saved xpointer). Only those echoes of the
-- jump are "already synced"; a page turn is reading however soon it comes.
local function jumped_to_cloud(options)
    options = options or {}
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    if options.sync_echo ~= false then
        local goto_fraction = f.sync.goto_fraction
        f.sync.goto_fraction = function(fraction)
            local ok, err = goto_fraction(fraction)
            f.sync:on_page_update() -- the jump's own PageUpdate
            return ok, err
        end
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    eq(f.document.page, 50, "jumped to the cloud page")
    eq(f.sync:status().verified, true, "cloud jump verifies")
    eq(f.sync:status().dirty, false, "the jump itself is not a change")
    return f
end

local function closed_upload(f)
    f.sync:on_close_document()
    return f.values.books.book.pending_upload_position
end

test("the cloud jump's own echo is not uploaded", function()
    local f = jumped_to_cloud()
    f.drain()
    f.sync:on_page_update() -- the echo after the call (re-render)
    eq(f.sync:status().dirty, false, "echo of the landed page is not a change")
    eq(f.sync:status().local_position.percent, 50, "local position is the landed page")
    eq(f.values.books.book.last_local_position.percent, 50,
        "landed position persisted without a timer")
    eq(closed_upload(f), nil, "nothing queued for upload at close")
end)

test("the landed position is recorded even when no echo reaches the plugin", function()
    local f = jumped_to_cloud({ sync_echo = false })
    eq(f.sync:status().local_position.percent, 50, "landed position captured after the call")
    f.sync:on_page_update()
    eq(f.sync:status().dirty, false, "a late echo is still recognised")
    eq(closed_upload(f), nil, "nothing queued for upload at close")
end)

test("a page turn 10 ms after the cloud jump is uploaded", function()
    local f = jumped_to_cloud()
    -- Before any timer can fire: the reader turns the page right away.
    f.document.page = 51
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "an immediate page turn is a change")
    f.drain() -- whatever the jump scheduled must not swallow it
    eq(f.sync:status().dirty, true, "the page turn stays unsynced")
    eq(f.sync:status().local_position.percent, 51, "local position follows the reader")
    local pending = closed_upload(f)
    eq(pending and pending.percent, 51, "close queues the turned page for upload")
end)

test("a page turn after the echo is uploaded", function()
    local f = jumped_to_cloud()
    f.sync:on_page_update() -- echo
    f.drain()
    f.document.page = 52
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "page turn after the echo is a change")
    local pending = closed_upload(f)
    eq(pending and pending.percent, 52, "close queues the turned page for upload")
end)

test("duplicate echoes of the jump target do not cause an upload", function()
    local f = jumped_to_cloud()
    for _i = 1, 3 do
        f.sync:on_page_update()
        f.drain()
    end
    eq(f.sync:status().dirty, false, "repeated echoes are no change")
    eq(f.sync.jump_echo, nil, "echo marker consumed")
    eq(closed_upload(f), nil, "nothing queued for upload at close")
end)

test("echo suppression does not leak to the reader returning to the jump target", function()
    local f = jumped_to_cloud()
    f.document.page = 51
    f.sync:on_page_update()
    eq(f.sync.jump_echo, nil, "a different position clears the echo marker")
    -- That page is uploaded and accepted: the session is clean again.
    f.sync:_upload_snapshot(f.sync:status().local_position, "test")
    f.drain()
    eq(#f.uploads, 1, "page 51 uploaded")
    eq(f.sync:status().dirty, false, "accepted upload clears dirty")
    -- The reader pages back to exactly where the cloud jump landed.
    f.document.page = 50
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "returning to the jump target is reading")
    local pending = closed_upload(f)
    eq(pending and pending.percent, 50, "close queues the returned-to page")
end)

test("a real sync clears an unconsumed echo marker", function()
    local f = jumped_to_cloud({ sync_echo = false })
    eq(f.sync.jump_echo ~= nil, true, "marker set by the jump")
    f.sync:sync_now()
    f.drain()
    eq(f.sync.jump_echo, nil, "marker cleared by the next pull")
end)

test("a cloud jump that throws reports the error and keeps tracking pages", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync.goto_fraction = function() error("reader gone") end
    f.sync:on_reader_ready()
    f.drain()
    local ok, err = f.sync:_jump_to(0.5)
    eq(ok, false, "throwing jump fails")
    eq(tostring(err):find("reader gone", 1, true) ~= nil, true, "error carried")
    eq(f.sync.jumping, false, "jump bracket closed")
    f.sync.local_position = f.sync:capture_local()
    f.document.page = 60
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "page updates still count after the failure")
end)

test("busy read report is retried with the immutable snapshot", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    local attempts = 0
    local uploaded
    f.sync.upload_position = function(_book_id, position)
        attempts = attempts + 1
        if attempts == 1 then
            return false, { error = "busy", error_kind = "busy" }
        end
        uploaded = position
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].keep_local()
    -- Mutating the live page must not change the already captured retry.
    f.document.page = 75
    f.drain()
    eq(attempts, 2, "busy upload retried")
    eq(uploaded.percent, 25, "retry uses immutable position")
    eq(f.values.books.book.pending_upload_position, nil,
        "retry success clears pending snapshot")
end)

test("suspend captures movement even without a page event", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    eq(#f.uploads, 0, "suspend itself does no network I/O")
    eq(f.values.books.book.pending_upload_position, nil, "suspend itself does not write")
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "captured movement is uploaded after resume")
    eq(f.uploads[1].percent, 40, "suspend uses current page")
end)

test("suspend upload waits for the link after resume", function()
    local online = true
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, { is_online = function() return online end })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    online = false
    f.sync:on_resume()
    f.step()
    f.step()
    eq(#f.uploads, 0, "no upload while offline")
    online = true
    f.drain()
    eq(#f.uploads, 1, "upload once the link is back")
end)

test("long sleep keeps local progress when the cloud did not move", function()
    local now = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, { now = function() return now end })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    now = 60 * 60
    f.sync:on_resume()
    f.drain()
    eq(#f.choices, 0, "no conflict dialog for our own unsent progress")
    eq(#f.uploads, 1, "pending progress uploaded after the recheck")
    eq(f.uploads[1].percent, 40, "local position wins")
    eq(f.sync:status().verified, true, "session verified again")
end)

test("long sleep asks when the cloud moved meanwhile", function()
    local now = 0
    local remote = {
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }
    local f = fixture(remote, { now = function() return now end })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    -- Read on another device while this one slept.
    remote.progress = 90
    remote.chapterUid = 33
    remote.chapterIdx = 3
    remote.chapterOffset = 500
    remote.updateTime = 20
    now = 60 * 60
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 0, "nothing uploaded over newer cloud progress")
    eq(#f.choices, 1, "user is asked")
end)

test("single chapter cloud choice waits for target chapter then jumps", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    local current_chapter = chapters[1]
    local requested_chapter
    f.sync.get_file_context = function()
        return 1, current_chapter, false
    end
    f.sync.open_chapter = function(_book, chapter)
        requested_chapter = chapter
        return true
    end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "chapter conflict requested")
    f.choices[1].use_remote()
    eq(requested_chapter.chapterUid, 22, "target chapter requested")
    eq(f.sync:status().verified, false, "reporting remains gated")
    eq(f.sync:status().state, "switching_chapter", "waiting for open")

    -- Simulate the downloader opening the requested single-chapter EPUB.
    current_chapter = chapters[2]
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "target chapter verifies")
    eq(f.jumps[#f.jumps], 0.5, "target chapter offset applied")
end)

test("cancelling target chapter download clears the pending jump", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync.get_file_context = function()
        return 1, chapters[1], false
    end
    f.sync.open_chapter = function() return true end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    eq(f.sync:cancel_pending_jump("cancelled"), true, "pending cancelled")
    eq(f.sync:status().state, "unverified", "returns to safe state")
    eq(f.sync:status().verified, false, "reporting stays gated")
end)

test("automatic hooks stay disabled when flags are absent", function()
    local f = fixture({
        bookId = "book",
        progress = 75,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 300,
        updateTime = 10,
    })
    f.values.sync = {}
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().state, "unverified", "open does not pull by default")
    eq(#f.choices, 0, "open does not prompt by default")

    f.sync.verified = true
    f.sync.dirty = true
    f.sync:on_close_document()
    eq(#f.uploads, 0, "close does not upload by default")
end)

test("manual sync refreshes a missing catalog inside the online task", function()
    local available_chapters
    local refresh_count = 0
    local online_count = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        get_chapters = function() return available_chapters end,
        refresh_catalog = function(book_id)
            eq(book_id, "book", "refresh receives current book")
            refresh_count = refresh_count + 1
            available_chapters = chapters
            return chapters
        end,
        run_online = function(_kind, callback)
            online_count = online_count + 1
            callback()
            return true
        end,
    })
    eq(f.sync:sync_now(), true, "manual sync starts")
    eq(refresh_count, 1, "catalog refreshed once")
    eq(online_count, 1, "catalog and progress share one online task")
    eq(f.sync:status().verified, true, "refreshed catalog completes sync")
    eq(#f.notifications, 1, "aligned manual sync notifies once")
    eq(f.notifications[1].code, "already_synced", "sync result notified")
end)

test("automatic open never refreshes a missing catalog", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(refresh_count, 0, "automatic path stays offline")
    eq(f.sync:status().state, "unsafe", "missing catalog degrades safely")
end)

test("offline manual catalog refresh reports offline instead of raw reason", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline sync does not start")
    eq(refresh_count, 0, "offline path does not refresh")
    eq(#f.notifications, 1, "offline failure notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("offline automatic pull schedules a delayed retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    -- Wi-Fi is usually still settling when the open delay expires.
    f.step()
    eq(f.sync:status().state, "offline", "automatic pull records offline")
    eq(#f.queue, 1, "offline automatic pull queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry waits for the link")
    eq(#f.notifications, 0, "automatic retry stays silent")
end)

test("automatic pull retries stop at the attempt limit", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "first retry queued")
    f.step()
    eq(#f.queue, 1, "second retry queued")
    f.step()
    eq(#f.queue, 1, "third retry queued")
    f.step()
    eq(#f.queue, 0, "retries stop at the limit")
    eq(f.sync:status().verified, false, "exhausted retries stay gated")
end)

test("offline manual sync never schedules a retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline manual sync does not start")
    eq(#f.queue, 0, "manual path leaves the queue empty")
    eq(#f.notifications, 1, "manual offline notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("retries queued for a closed book never pull again", function()
    local online_checks = 0
    local f = fixture({}, {
        is_online = function()
            online_checks = online_checks + 1
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "retry queued for the open book")
    f.sync:on_close_document()
    f.step()
    eq(online_checks, 1, "stale retry never reaches the offline check")
    eq(#f.queue, 0, "stale retry does not queue another attempt")
end)

test("a queued retry verifies once the link comes back", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().verified, false, "offline open leaves the gate closed")
    online = true
    f.drain()
    eq(f.sync:status().verified, true, "retry verifies the reporting gate")
    eq(#f.choices, 0, "no conflict dialog")
    eq(#f.notifications, 0, "automatic retry stays silent")
    local position, reason = f.sync:position_for_report("book")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
end)

test("automatic pull retries when the online task cannot start", function()
    local run_options
    local f = fixture({}, {
        is_online = function() return true end,
        run_online = function(_kind, _callback, options)
            run_options = options
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().state, "offline", "failed online task records offline")
    eq(#f.queue, 1, "failed automatic online task queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry remains delayed")
    eq(run_options.silent_offline, true, "automatic preflight stays silent")
    eq(#f.notifications, 0, "automatic start failure does not notify")
end)

test("queued automatic retry does not duplicate a manual conflict", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 80,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 500,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    online = true
    f.sync:sync_now()
    eq(#f.choices, 1, "manual sync opens one conflict")
    f.step()
    eq(#f.choices, 1, "stale automatic retry does not reopen conflict")
    eq(#f.queue, 0, "stale retry chain ends")
end)

test("a fresh automatic pull replaces an older retry chain", function()
    local now = 0
    local f = fixture({}, {
        is_online = function() return false end,
        now = function() return now end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "open queues the first retry chain")
    f.sync:on_suspend()
    now = 5 * 60
    f.sync:on_resume()
    eq(#f.queue, 2, "resume queues its replacement chain")
    f.step()
    eq(#f.queue, 1, "stale chain does not schedule another retry")
    f.step()
    eq(#f.queue, 1, "replacement chain remains active")
end)

test("reports fall back to context progress when open pulls are disabled", function()
    local f = fixture({
        bookId = "book",
        progress = 75,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 300,
        updateTime = 10,
    })
    f.values.sync = {}
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, false, "session stays unverified")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position, nil, "local position withheld")
    eq(reason, nil, "no gate reason")
    eq(applies, false, "provider does not block the report")
end)

test("manual conflict still blocks reports when open pulls are disabled", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready()
    f.drain()
    f.sync:sync_now()
    f.drain()
    eq(#f.choices, 1, "conflict dialog requested")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position, nil, "position withheld")
    eq(reason, "progress_unverified", "gate reason")
    eq(applies, true, "provider applies")
end)

test("failed automatic pull schedules a retry that verifies", function()
    local remote = {
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }
    local f = fixture(remote)
    local reachable = false
    f.sync.client = {
        get_progress = function()
            if not reachable then error("Network is unreachable") end
            return { book = remote }
        end,
        get_web_progress = function()
            if not reachable then error("Network is unreachable") end
            return remote
        end,
    }
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().verified, false, "failed pull leaves the gate closed")
    eq(#f.queue, 1, "failed pull queues a retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry delay")
    eq(#f.notifications, 0, "automatic failure stays silent")
    reachable = true
    f.drain()
    eq(f.sync:status().verified, true, "retry verifies the reporting gate")
    local position, reason = f.sync:position_for_report("book")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
end)

test("failed manual pull notifies without scheduling a retry", function()
    local f = fixture({})
    f.sync.client = {
        get_progress = function() error("Network is unreachable") end,
        get_web_progress = function() error("Network is unreachable") end,
    }
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready()
    f.drain()
    f.sync:sync_now()
    eq(#f.queue, 0, "manual failure does not retry")
    eq(f.notifications[#f.notifications].code, "pull_failed", "manual failure is reported")
end)

test("a pull that throws does not block later pulls", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        -- Like runOnlineTask: the task runs under xpcall.
        run_online = function(_kind, callback)
            pcall(callback)
            return true
        end,
    })
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready()
    f.drain()
    local real_fetch = f.sync._fetch_remote
    f.sync._fetch_remote = function() error("boom") end
    f.sync:sync_now()
    eq(f.sync:status().state, "error", "failed pull reports an error state")
    f.sync._fetch_remote = real_fetch
    eq(f.sync:sync_now(), true, "next manual pull starts")
    eq(f.sync:status().verified, true, "next manual pull verifies")
end)

test("dismissing the conflict dialog uploads nothing and asks again later", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "conflict dialog requested")
    eq(f.choices[1].local_behind_remote, true, "dialog knows keep-local moves cloud back")
    f.choices[1].dismiss()
    eq(#f.uploads, 0, "dismissal uploads nothing")
    eq(f.sync:status().verified, false, "dismissal does not verify")
    eq(f.sync:status().state, "unverified", "dismissal leaves the session unverified")
    f.choices[1].keep_local()
    eq(#f.uploads, 0, "a dismissed dialog cannot upload afterwards")
    f.sync:sync_now()
    eq(#f.choices, 2, "the choice is offered again")
end)

test("a second conflict while a dialog is open does not stack", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:sync_now(), false, "pull skipped while a choice is open")
    eq(#f.choices, 1, "one dialog only")
end)

test("closing the document closes an unanswered choice", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    local closed = 0
    f.choices[1].close = function() closed = closed + 1 end
    f.sync:on_close_document()
    eq(closed, 1, "dialog closed with the document")
    f.choices[1].keep_local()
    f.choices[1].use_remote()
    eq(#f.uploads, 0, "stale dialog cannot upload")
    eq(#f.jumps, 0, "stale dialog cannot jump")
end)

test("suspend closes an unanswered choice and resume asks again", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    local closed = 0
    f.choices[1].close = function() closed = closed + 1 end
    f.sync:on_suspend()
    eq(closed, 1, "dialog closed on suspend")
    eq(#f.uploads, 0, "nothing uploaded on suspend")
    f.sync:on_resume()
    f.drain()
    eq(#f.choices, 2, "fresh choice after resume")
end)

test("a background upload is polled until it finishes", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    local calls = 0
    f.sync.upload_position = function()
        calls = calls + 1
        if calls < 3 then
            return false, { error = "upload_pending", error_kind = "pending" }
        end
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].keep_local()
    f.drain()
    eq(calls, 3, "polled until the job finished")
    eq(f.sync:status().uploading, false, "upload finished")
    eq(f.notifications[#f.notifications].code, "upload_success", "result reported")
end)

test("a newer position is uploaded after the one in flight (F10)", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    local finish_first = false
    local sent = {}
    f.sync.upload_position = function(_book_id, position)
        if #sent == 0 and not finish_first then
            return false, { error_kind = "pending" }
        end
        sent[#sent + 1] = position
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].keep_local()
    eq(f.sync:status().uploading, true, "first upload in flight")
    f.document.page = 30
    f.sync:_upload_snapshot(assert(f.sync:capture_local()), "newer", false)
    eq(f.values.books.book.pending_upload_position.percent, 30,
        "newer position persisted at once")
    finish_first = true
    f.drain()
    eq(#sent, 2, "both positions sent, in order")
    eq(sent[1].percent, 25, "older one first")
    eq(sent[2].percent, 30, "newer one after it")
    eq(f.values.books.book.pending_upload_position, nil,
        "pending cleared only after the newest succeeded")
end)

test("suspend stops an upload in flight and resume sends it again", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    local polls = 0
    local done = false
    f.sync.upload_position = function(_book_id, position)
        polls = polls + 1
        if not done then return false, { error_kind = "pending" } end
        f.uploads[#f.uploads + 1] = position
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    f.sync:on_resume()
    f.step()  -- network work after resume starts the upload
    eq(f.sync:status().uploading, true, "upload started after resume")
    f.sync:on_suspend()
    local before = polls
    f.drain()
    eq(polls, before, "no polling while suspended")
    eq(f.sync:status().uploading, false, "chain stopped")
    done = true
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "sent once after the second resume")
    eq(f.uploads[1].percent, 40, "the suspended position")
end)

test("resume network work waits for Wi-Fi and gives up quietly (F4)", function()
    local online = false
    local checks = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        is_online = function()
            checks = checks + 1
            return online
        end,
    })
    online = true
    f.sync:on_reader_ready()
    f.drain()
    online = false
    f.document.page = 40
    f.sync:on_suspend()
    checks = 0
    f.sync:on_resume()
    eq(checks, 0, "resume handler itself checks nothing")
    local delays = {}
    while #f.queue > 0 do
        delays[#delays + 1] = f.queue[1].delay
        f.step()
    end
    eq(table.concat(delays, ","), "5,10,20", "bounded back-off")
    eq(#f.uploads, 0, "nothing sent while offline")
    eq(#f.notifications, 0, "silent")
    online = true
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(#f.uploads, 1, "sent after the next resume")
end)

test("automatic and manual pulls never do a UI DNS check", function()
    local seen = {}
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        run_online = function(_kind, callback, options)
            seen[#seen + 1] = options
            callback()
            return true
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(seen[1].link_only, true, "automatic pull checks the link only")
    f.sync:sync_now()
    eq(seen[2].link_only, true, "manual pull also checks the link only")
end)

test("resume sends positions other books left pending", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.values.books.other = {
        book_id = "other",
        pending_upload_position = { book_id = "other", chapter_uid = 7, percent = 12 },
        pending_upload_owner = require("weread.lib.request_owner").digest(
            require("weread.lib.request_owner").capture(f.sync.settings)),
        pending_upload_baselines = { { chapter_uid = 7, chapter_offset = 1 } },
    }
    local ids = {}
    f.sync.upload_position = function(book_id, position)
        ids[#ids + 1] = book_id
        f.uploads[#f.uploads + 1] = position
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.uploads, 0, "opening another book does not scan every book")
    f.sync:on_suspend()
    f.sync:on_resume()
    f.drain()
    eq(ids[1], "other", "pending position of a closed book sent")
    eq(f.uploads[1].guard.baselines[1].chapter_uid, 7, "with its guard baselines")
    eq(f.values.books.other.pending_upload_position, nil, "cleared after success")
end)

test("teardown cancels timers and keeps unsent positions", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    local unscheduled = 0
    f.sync.scheduler.unschedule = function() unscheduled = unscheduled + 1 end
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    f.sync:on_resume()
    eq(#f.queue, 1, "network work scheduled")
    f.sync:teardown("close_widget")
    eq(unscheduled, 1, "pending timer unscheduled")
    eq(f.values.books.book.pending_upload_position.percent, 40,
        "in-memory position persisted for the next instance")
    f.drain()
    eq(#f.uploads, 0, "nothing runs after teardown")
end)

test("a chapter jump survives the plugin instance that requested it (F8)", function()
    local now = 1000
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, { now = function() return now end })
    local current_chapter = chapters[1]
    f.sync.get_file_context = function() return 1, current_chapter, false end
    f.sync.open_chapter = function() return true end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    eq(f.values.books.book.pending_jump.chapter_uid, 22, "jump persisted")
    -- The chapter file opens in a new ReaderUI with a new plugin instance.
    f.sync.pending_jump = nil
    current_chapter = chapters[2]
    now = now + 30
    f.sync:on_reader_ready()
    f.drain()
    eq(f.jumps[#f.jumps], 0.5, "new instance applies the cloud offset")
    eq(f.sync:status().verified, true, "and verifies")
    eq(#f.choices, 1, "no second conflict dialog")
    eq(f.values.books.book.pending_jump, nil, "persisted jump consumed")
end)

test("a stale persisted chapter jump is ignored", function()
    local now = 1000
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, { now = function() return now end })
    f.sync.get_file_context = function() return 2, chapters[2], false end
    f.values.books.book.pending_jump = {
        book_id = "book", chapter_uid = 22, fraction = 0.5, created_at = 0,
        owner_digest = require("weread.lib.request_owner").digest(f.sync.session_owner),
    }
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.jumps, 0, "expired jump not applied")
    eq(f.values.books.book.pending_jump, nil, "expired jump removed")
end)

test("a failed upload records the real error text", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.sync.upload_position = function() error("worker crashed", 0) end
    f.choices[1].keep_local()
    local shown = f.notifications[#f.notifications]
    eq(shown and shown.code, "upload_failed", "thrown upload failure is shown")
    eq(shown and shown.data.error, "worker crashed", "thrown error text is shown")
    eq(f.values.books.book.last_sync_error, "worker crashed",
        "thrown error text is recorded")

    -- A rejection without an error text must not record a table address.
    f.sync.upload_position = function() return false, { accepted = false } end
    f.sync:sync_now()
    f.choices[#f.choices].keep_local()
    eq(f.values.books.book.last_sync_error, "upload_failed",
        "missing error text falls back to upload_failed")

    -- A scalar outcome (no table) is the error text itself.
    f.sync.upload_position = function() return false, "gateway said no" end
    f.sync:sync_now()
    f.choices[#f.choices].keep_local()
    eq(f.values.books.book.last_sync_error, "gateway said no", "scalar outcome is recorded as the error")
    shown = f.notifications[#f.notifications]
    eq(shown and shown.data.error, "gateway said no", "scalar outcome is shown")
end)

local function async_fixture(options)
    options = options or {}
    local pending, cancellations = {}, 0
    options.request = options.request or function(task, success, failure)
        pending[#pending + 1] = { task = task, success = success, failure = failure }
        return function() cancellations = cancellations + 1; failure(nil, true) end
    end
    local f = fixture({ bookId = "book", progress = 25, chapterUid = 22,
        chapterIdx = 2, chapterOffset = 150, updateTime = 10 }, options)
    f.values.account, f.values.api_key = { user_vid = "one" }, "synthetic-api-one"
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready(); f.drain()
    return f, pending, function() return cancellations end
end
local function complete(request) request.success(request.task()) end

test("async pull keeps HTTP in the task and persistence in the parent", function()
    local f, pending = async_fixture()
    local child, calls = false, 0
    for _, method in ipairs({ "get_progress", "get_web_progress" }) do
        local original = f.sync.client[method]
        f.sync.client[method] = function(...)
            eq(child, true, method .. " executes in child task")
            calls = calls + 1; return original(...)
        end
    end
    local flush = f.sync.settings.flush
    f.sync.settings.flush = function(...)
        eq(child, false, "progress persistence stays in parent"); return flush(...)
    end
    f.sync:sync_now(); eq(calls, 0, "acceptance performs no HTTP")
    child = true; local value = pending[1].task(); child = false
    pending[1].success(value)
    eq(calls, 2, "both sources fetched")
    eq(f.sync.verified, true, "parent verifies result")
    eq(f.sync.pulling, false, "success releases lock")
end)

test("deferred pull binds owner and document before starting HTTP", function()
    for _, change in ipairs({ "uid", "api_key", "source", "path", "close", "suspend", "ticket" }) do
        local callback
        local f, pending = async_fixture({ run_online = function(_, action) callback = action; return true end })
        f.sync:sync_now()
        if change == "uid" then f.values.account.user_vid = "two"
        elseif change == "api_key" then f.values.api_key = "synthetic-api-two"
        elseif change == "source" then f.sync.settings.is_cookie_configured = function() return false end
        elseif change == "path" then f.document.file = "/other/book.epub"
        elseif change == "close" then f.sync:on_close_document()
        elseif change == "suspend" then f.sync:on_suspend()
        else f.values.wr_ticket = "rotated" end
        callback()
        eq(#pending, change == "ticket" and 1 or 0, change .. " request-start guard")
        if change == "ticket" then complete(pending[1]); eq(f.sync.verified, true, "ticket accepted") end
        eq(f.sync.pulling, false, change .. " releases lock")
        if change ~= "ticket" then eq(f.values.books.book.last_remote_position, nil, change .. " no old write") end
    end
end)

test("lifecycle cancels pull without letting stale callbacks clear new work", function()
    for _, action in ipairs({ "on_reader_ready", "on_close_document", "on_suspend", "teardown", "on_account_changed" }) do
        local f, pending, cancelled = async_fixture()
        f.sync:sync_now(); local old = pending[1]
        f.sync[action](f.sync)
        eq(cancelled(), 1, action .. " cancels child")
        old.success(old.task())
        eq(f.sync.pulling, false, action .. " clears lock")
        eq(f.values.books.book.last_remote_position, nil, action .. " drops late position")
    end
    local f, pending = async_fixture()
    f.sync:sync_now(); local old = pending[1]
    f.sync:on_reader_ready(); f.drain(); f.sync:sync_now()
    old.success(old.task()); eq(f.sync.pulling, true, "old callback cannot clear new operation")
    complete(pending[2]); eq(f.sync.verified, true, "new request completes")
end)

test("late owner change and user cancellation do not deliver old results", function()
    for _, mode in ipairs({ "uid", "api_key", "cancel" }) do
        local f, pending = async_fixture(); f.sync:sync_now()
        local value, notices = pending[1].task(), #f.notifications
        if mode == "cancel" then pending[1].failure(nil, true)
        else
            if mode == "uid" then f.values.account.user_vid = "two" else f.values.api_key = "synthetic-api-two" end
            pending[1].success(value)
        end
        eq(f.sync.pulling, false, mode .. " clears lock")
        eq(f.values.books.book.last_remote_position, nil, mode .. " no persistence")
        eq(#f.notifications, notices, mode .. " no old result notice")
        eq(#f.uploads, 0, mode .. " no old upload")
    end
end)

test("catalog HTTP precedes parent application and progress HTTP", function()
    local available, applied, child = nil, 0, false
    local f, pending = async_fixture({
        get_chapters = function() return available end,
        fetch_catalog = function() eq(child, true, "catalog HTTP is child-only"); return chapters end,
        apply_catalog = function(_, value)
            eq(child, false, "catalog application is parent-only")
            available, applied = value, applied + 1; return value
        end,
    })
    f.sync:sync_now()
    child = true; local value = pending[1].task(); child = false
    pending[1].success(value)
    eq(applied, 1, "catalog applied")
    eq(#pending, 2, "progress follows catalog")
    complete(pending[2]); eq(f.sync.verified, true, "refreshed catalog verifies")
end)

test("transport and parent exceptions release state and permit retry", function()
    local f, pending = async_fixture(); f.sync:sync_now()
    local flush = f.sync.settings.flush
    f.sync.settings.flush = function() error("parent disk failure") end
    complete(pending[1])
    eq(f.sync.pulling, false, "parent exception releases lock")
    eq(f.sync.state, "error", "parent exception records error")
    eq(f.notifications[#f.notifications].code, "pull_failed", "parent error visible")
    f.sync.settings.flush = flush; f.sync:sync_now(); complete(pending[2])
    eq(f.sync.verified, true, "retry succeeds")
    f = async_fixture({ request = function() error("transport unavailable") end })
    f.sync:sync_now()
    eq(f.sync.pulling, false, "transport exception releases lock")
    eq(f.notifications[#f.notifications].code, "pull_failed", "transport error visible")
end)

test("queued and accepted uploads cannot cross owners but permit ticket renewal", function()
    for _, mode in ipairs({ "queued_uid", "queued_api", "pending_uid", "accepted_api", "ticket" }) do
        local f = fixture({ bookId = "book", progress = 25, chapterUid = 22,
            chapterIdx = 2, chapterOffset = 150, updateTime = 10 })
        f.values.account, f.values.api_key = { user_vid = "one" }, "synthetic-api-one"
        f.sync:on_reader_ready(); f.drain()
        local calls = 0
        f.sync.upload_position = function()
            calls = calls + 1
            if mode == "accepted_api" then f.values.api_key = "synthetic-api-two"; return true, { accepted = true } end
            if calls == 1 and (mode == "pending_uid" or mode == "ticket") then
                return false, { error_kind = "pending" }
            end
            return true, { accepted = true }
        end
        f.sync:_enqueue_upload({ book_id = "book", fraction = 0.4, percent = 40 }, "probe")
        if mode == "queued_uid" then f.values.account.user_vid = "two"
        elseif mode == "queued_api" then f.values.api_key = "synthetic-api-two" end
        f.sync:_pump_uploads()
        if mode == "pending_uid" then f.values.account.user_vid = "two"
        elseif mode == "ticket" then f.values.wr_ticket = "rotated" end
        f.drain()
        eq(calls, mode == "ticket" and 2 or (mode:find("queued", 1, true) and 0 or 1), mode .. " calls")
        eq(f.values.books.book.last_uploaded_position ~= nil, mode == "ticket", mode .. " result ownership")
        eq(f.values.books.book.pending_upload_position ~= nil, mode ~= "ticket", mode .. " pending kept")
    end
end)

test("a page turned during HTTP or while a prompt is open is never overwritten", function()
    local f, pending = async_fixture(); f.sync:sync_now()
    f.document.page = 50
    complete(pending[1])
    eq(f.values.books.book.last_local_position.percent, 50, "HTTP completion captures current page")
    eq(#f.choices, 1, "fresh conflict uses the new page")
    f.document.page = 60
    f.choices[1].use_remote()
    eq(#f.jumps, 0, "stale prompt never jumps")
    eq(#f.uploads, 0, "stale prompt never uploads")
    eq(f.sync.choice, nil, "stale prompt releases state")
end)

test("pending owner digest restores only a proven account across instances", function()
    local Owner = require("weread.lib.request_owner")
    local f = fixture({ bookId = "book", progress = 25, chapterUid = 22,
        chapterIdx = 2, chapterOffset = 150, updateTime = 10 })
    f.values.api_key = "synthetic-api-one"
    f.sync:on_reader_ready(); f.drain()
    f.sync:_enqueue_upload({ book_id = "book", percent = 40, fraction = 0.4 }, "persist")
    local digest = f.values.books.book.pending_upload_owner
    eq(#digest, 64, "only a digest is persisted")
    eq(digest:find("synthetic", 1, true), nil, "no raw API key in pending owner")
    f.sync.upload_queue = {}; f.sync:_load_persisted_uploads("book")
    eq(f.sync.upload_queue.book ~= nil, true, "same owner restores pending position")
    f.values.api_key = "synthetic-api-two"
    f.sync:on_account_changed(); f.sync:on_reader_ready()
    f.sync.upload_queue = {}; f.sync:_load_persisted_uploads("book")
    eq(f.sync.upload_queue.book, nil, "different gateway does not restore pending position")
    eq(f.values.books.book.pending_upload_owner, digest, "mismatched position remains on disk")
    f.values.books.book.pending_upload_owner = nil
    f.sync:_load_persisted_uploads("book")
    eq(f.sync.upload_queue.book, nil, "unsigned legacy position is not silently accepted")
    eq(f.values.books.book.pending_upload_position.percent, 40, "legacy position is preserved")
    f.sync:_enqueue_upload({ book_id = "book", percent = 50, fraction = 0.5 }, "fresh")
    eq(f.values.books.book.pending_upload_position.percent, 50, "fresh local position replaces legacy")
    eq(f.values.books.book.pending_upload_owner, Owner.digest(Owner.capture(f.sync.settings)),
        "fresh pending position is owned by current account")
end)

for _, change in ipairs({ "unsigned", "uid", "api_key", "ticket" }) do
    test("persisted chapter jump owner " .. change, function()
        local Owner = require("weread.lib.request_owner")
        local f = fixture({})
        f.values.account, f.values.api_key = { user_vid = "42" }, "synthetic-api-one"
        f.sync.session_owner = Owner.capture(f.sync.settings)
        f.sync.get_file_context = function() return 2, chapters[2], false end
        local pending = {
            book_id = "book", chapter_uid = 22, fraction = 0.5, created_at = f.sync.now(),
            owner_digest = Owner.digest(f.sync.session_owner),
        }
        f.values.books.book.pending_jump = pending
        if change == "unsigned" then pending.owner_digest = nil
        elseif change == "uid" then f.values.account.user_vid = "other"
        elseif change == "api_key" then f.values.api_key = "synthetic-api-two"
        else f.values.wr_ticket = "rotated" end
        f.sync.session_owner = Owner.capture(f.sync.settings)
        local applied = f.sync:_apply_pending_jump("book")
        eq(applied, change == "ticket", "only same-owner chapter transaction resumes")
        eq(#f.jumps, change == "ticket" and 1 or 0, "foreign transaction cannot move reader")
        if change ~= "ticket" then
            eq(f.values.books.book.pending_jump, pending, "unproven transaction remains on disk")
        end
    end)
end

print(string.format(
    "progress_sync_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
