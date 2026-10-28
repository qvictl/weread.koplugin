-- Behavioural coverage for the reader open/close/suspend/resume hooks in
-- weread/lib/reader_lifecycle.lua: which work is scheduled or skipped per
-- event, I/O-free suspend, teardown on close, local-document binding,
-- chapter mapping and the end-of-book / prefetch decision paths.

package.path = "./?.lua;" .. package.path

local existing = {}
local warnings = {}
local infos = {}
local scheduled = {}
local memo_puts = {}
local memo_loaded
local saved_catalogs = {}
local save_result = { true }

package.preload["weread.lib.catalog_memo"] = function()
    return {
        put_chapters = function(_db, book_id, chapters)
            memo_puts[#memo_puts + 1] = { book_id = book_id, chapters = chapters }
            return true
        end,
        load = function() return memo_loaded end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function(_settings, book)
            return book.catalog_path
        end,
        save_catalog_cache = function(_client, _settings, book, chapters)
            saved_catalogs[#saved_catalogs + 1] = { book = book, chapters = chapters }
            return save_result[1], save_result[2]
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return {
                info = function(...) infos[#infos + 1] = table.concat({ ... }, " ") end,
                warn = function(...)
                    local parts = {}
                    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
                    warnings[#warnings + 1] = table.concat(parts, " ")
                end,
            }
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(book_id) return tostring(book_id):sub(1, 3) == "MP_" end }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, fn)
            scheduled[#scheduled + 1] = { delay = delay, fn = fn }
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        display_error = function(value) return "display:" .. tostring(value) end,
        log_error = function(value) return tostring(value) end,
        file_exists = function(path) return path ~= nil and existing[path] == true end,
        reader_open_perf = function(stage) return stage end,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")
local Book = require("spec.helpers.book_settings")

local checks = 0
local function expect(value, label)
    checks = checks + 1
    if not value then error("FAIL " .. label, 2) end
end

local function contains(list, needle)
    for _, value in ipairs(list) do
        if tostring(value):find(needle, 1, true) then return true end
    end
    return false
end

-- A table that records every field access; used to prove a handler never
-- reaches the network client, the downloader or the settings store.
local function tripwire(name, hits)
    return setmetatable({}, {
        __index = function(_t, key)
            hits[#hits + 1] = name .. "." .. tostring(key)
            return function() end
        end,
    })
end

local function run_scheduled()
    local pending = scheduled
    scheduled = {}
    for _, task in ipairs(pending) do task.fn() end
end

local function make_host(opts)
    opts = opts or {}
    local calls = {}
    local function record(name)
        return function(_self, ...)
            calls[#calls + 1] = name
            local hook = opts.hooks and opts.hooks[name]
            if hook then return hook(...) end
        end
    end
    local cache = opts.cache or { show_annotations = true }
    local read_report_cfg = opts.read_report or { enabled = false, mode = "auto" }
    local books = opts.books or {
        book = { cache_dir = "/lib/book", chapters = {} },
    }
    local settings = Book.install({
        cache_dir = "/lib",
        get = function(_self, key)
            if key == "cache" then return cache end
            if key == "read_report" then return read_report_cfg end
        end,
        flush = record("settings.flush"),
    }, books)
    local status = { onEndOfBook = function() calls[#calls + 1] = "native_end"; return "native" end }
    local host = {
        calls = calls,
        cache = cache,
        settings = settings,
        ui = {
            document = { file = opts.file or "/lib/book/ch1.epub" },
            status = status,
        },
        progress_sync = {
            on_reader_ready = record("progress.ready"),
            on_page_update = record("progress.page"),
            on_close_document = record("progress.close"),
            on_suspend = record("progress.suspend"),
            on_resume = record("progress.resume"),
            sync_now = record("progress.sync_now"),
        },
        read_report = {
            on_reader_ready = function()
                calls[#calls + 1] = "report.ready"
                return false, nil, opts.report_reason
            end,
            on_page_update = record("report.page"),
            on_close_document = record("report.close"),
            on_suspend = record("report.suspend"),
            on_resume = record("report.resume"),
            maybe_start = function(_self, source)
                calls[#calls + 1] = "report.start:" .. source
                return "started"
            end,
            stop = function(_self, reason) calls[#calls + 1] = "report.stop:" .. reason end,
        },
        downloader = {
            cancelPrefetch = function(_self, reason) calls[#calls + 1] = "cancel:" .. reason end,
            isPrefetching = function() return false end,
            isPromotedPrefetch = function() return false end,
            start = function() return true end,
        },
        _teardownThoughtInterception = record("thought.teardown"),
        _setupThoughtInterception = record("thought.setup"),
        _ensureThoughtDB = function(_self, book_id) calls[#calls + 1] = "thought.db:" .. book_id end,
        _setupXPointerOverlayPrototype = record("overlay.setup"),
        _teardownXPointerOverlayPrototype = record("overlay.teardown"),
        _cancelUnifiedAnnotationSync = record("annotations.cancel"),
        _refreshAnnotationOverlay = record("overlay.refresh"),
        showTransientInfo = function(_self, text, timeout)
            calls[#calls + 1] = "notice:" .. text .. "@" .. tostring(timeout)
        end,
        showInfo = function(_self, text) calls[#calls + 1] = "info:" .. text end,
        showAccountStatus = record("account"),
        requireLogin = function() return opts.logged_in ~= false end,
        showEndOfBookDialog = function(_self, book_id)
            calls[#calls + 1] = "dialog:" .. book_id
            return opts.dialog ~= false
        end,
        openChapter = function(_self, _book, chapter)
            calls[#calls + 1] = "open:" .. tostring(chapter.chapterUid)
        end,
        downloadChapterAndRead = function(_self, _book, chapter)
            calls[#calls + 1] = "download_read:" .. tostring(chapter.chapterUid)
        end,
        prefetchChapterAnnotations = function(_self, _book, chapter)
            calls[#calls + 1] = "annotations.prefetch:" .. tostring(chapter.chapterUid)
        end,
    }
    for key, value in pairs(Lifecycle) do host[key] = value end
    return host, calls
end

local function index_of(calls, name)
    for i, value in ipairs(calls) do
        if value == name then return i end
    end
    return nil
end

local function count(calls, prefix)
    local n = 0
    for _, value in ipairs(calls) do
        if value:sub(1, #prefix) == prefix then n = n + 1 end
    end
    return n
end

-- ReaderReady on a WeRead book: interception, deferred thought DB, end-of-book
-- hook, progress sync and a deferred next-chapter prefetch.
do
    scheduled = {}
    local host, calls = make_host()
    host.ui.highlight = { onTap = function() end, view = { highlight = {} } }
    local native_end = host.ui.status.onEndOfBook
    host:onReaderReady()
    expect(host._reader_session_gen == 1, "ReaderReady opens reader session 1")
    expect(host._current_weread_book_id == "book", "WeRead book id is cached for taps")
    expect(index_of(calls, "thought.teardown") < index_of(calls, "thought.setup"),
        "stale thought interception is torn down before a new one is installed")
    expect(host._reader_highlight_guard_target == host.ui.highlight,
        "ReaderHighlight tap guard is installed on open")
    host.ui.highlight:onTap(nil, { pos = {} })
    expect(type(host.ui.highlight.view.highlight.visible_boxes) == "table",
        "tap during the post-open window gets an initialised box cache")
    expect(index_of(calls, "progress.ready") and index_of(calls, "report.ready"),
        "progress sync and read report are notified of the open")
    expect(index_of(calls, "overlay.setup") ~= nil, "XPointer overlay prototype is set up")
    expect(index_of(calls, "thought.db:book") == nil,
        "thought DB is not opened synchronously on the UI thread")
    expect(#scheduled == 2 and scheduled[1].delay == 0.1 and scheduled[2].delay == 0.2,
        "thought DB (0.1 s) and prefetch (0.2 s) are deferred")
    expect(host.ui.status.onEndOfBook ~= native_end and host._orig_onEndOfBook == native_end,
        "end-of-book handler is intercepted for WeRead books")
    host.handleEndOfBook = function(_self, status_self) return "weread_end", status_self end
    local result, forwarded = host.ui.status.onEndOfBook(host.ui.status)
    expect(result == "weread_end" and forwarded == host.ui.status,
        "intercepted end-of-book routes to handleEndOfBook with the status module")
    host.handleEndOfBook = Lifecycle.handleEndOfBook

    run_scheduled()
    expect(index_of(calls, "thought.db:book") ~= nil, "deferred thought DB opens for the same session")
    expect(index_of(calls, "cancel:prefetch_not_applicable") ~= nil,
        "deferred prefetch runs and is declined when auto prefetch is off")

    -- A second ReaderReady for the same book must not wrap the hook twice.
    local wrapped = host.ui.status.onEndOfBook
    host:onReaderReady()
    expect(host._reader_session_gen == 2, "every ReaderReady opens a new session")
    expect(host.ui.status.onEndOfBook == wrapped and host._orig_onEndOfBook == native_end,
        "repeated ReaderReady keeps a single end-of-book wrapper")
    scheduled = {}
end

-- Deferred work queued for an earlier session is dropped after a document
-- switch or close.
do
    scheduled = {}
    local host, calls = make_host()
    host:onReaderReady()
    expect(#scheduled == 2, "open queued deferred work")
    host:onCloseDocument()
    run_scheduled()
    expect(index_of(calls, "thought.db:book") == nil,
        "thought DB queued before close is skipped")
    expect(index_of(calls, "cancel:prefetch_not_applicable") == nil,
        "prefetch queued before close is skipped")

    -- Same session but the cached book changed: the DB task is skipped.
    host:onReaderReady()
    host._current_weread_book_id = "other"
    run_scheduled()
    expect(index_of(calls, "thought.db:book") == nil,
        "thought DB is skipped when the open book changed under it")
end

-- Annotation visibility decides whether the thought DB is scheduled at all.
do
    scheduled = {}
    local host, calls = make_host({ cache = { show_annotations = false } })
    host:onReaderReady()
    expect(index_of(calls, "thought.setup") ~= nil,
        "tap interception is still installed when annotations are hidden")
    expect(#scheduled == 1 and scheduled[1].delay == 0.2,
        "hidden annotations schedule only the prefetch")

    scheduled = {}
    host, calls = make_host()
    host._usesUnifiedAnnotations = function() return true end
    host.onUnifiedAnnotationsReady = function() calls[#calls + 1] = "unified.ready" end
    host:onReaderReady()
    expect(#scheduled == 1, "unified annotations replace the legacy thought DB")
    expect(index_of(calls, "unified.ready") ~= nil, "unified annotations are notified on open")
    scheduled = {}
end

-- ReaderReady on a local document: no WeRead work, end-of-book restored and a
-- one-second notice when automatic read reports cannot run.
do
    scheduled = {}
    local host, calls = make_host({
        file = "/sdcard/books/local.epub",
        read_report = { enabled = true, mode = "auto" },
        report_reason = "document_not_weread",
    })
    local native_end = function() return "native" end
    host._orig_onEndOfBook = native_end
    host.ui.status.onEndOfBook = function() return "wrapped" end
    host:onReaderReady()
    expect(host._current_weread_book_id == nil, "local document is not bound to a WeRead book")
    expect(index_of(calls, "thought.setup") == nil, "no thought interception for local documents")
    expect(host.ui.status.onEndOfBook == native_end and host._orig_onEndOfBook == nil,
        "native end-of-book handler is restored for a local document")
    expect(#scheduled == 1, "only the (no-op) prefetch is scheduled for a local document")
    expect(contains(calls, "notice:Current book is not from WeRead, reading time not reported@1"),
        "auto read report explains why a local book is not reported")
    run_scheduled()
    expect(index_of(calls, "cancel:prefetch_not_applicable") ~= nil,
        "prefetch for a local document is cancelled as not applicable")

    scheduled = {}
    host, calls = make_host({
        file = "/sdcard/books/local.epub",
        read_report = { enabled = true, mode = "manual" },
        report_reason = "document_not_weread",
    })
    host:onReaderReady()
    expect(count(calls, "notice:") == 0, "manual read report mode stays silent")
    scheduled = {}
end

-- Close: everything is torn down, nothing touches the network and failures
-- in one service do not skip the others.
do
    scheduled = {}
    local hits = {}
    local host, calls = make_host({
        hooks = { ["progress.close"] = function() error("db locked") end },
    })
    host.client = tripwire("client", hits)
    host.ui.highlight = { onTap = function() return "native_tap" end, view = { highlight = {} } }
    local native_tap = host.ui.highlight.onTap
    local native_end = host.ui.status.onEndOfBook
    host:onReaderReady()
    host._annotation_pending_prefetch = { "x" }
    host._annotation_context = { "ctx" }
    scheduled = {}
    calls[#calls + 1] = "--close--"
    local mark = #calls
    host:onCloseDocument()
    expect(host._reader_session_gen == 2, "close invalidates the reader session")
    expect(contains(warnings, "progress sync close failed:") and contains(warnings, "db locked"),
        "progress sync close failure is logged")
    expect(index_of(calls, "report.close") ~= nil,
        "read report still closes after a progress sync failure")
    expect(index_of(calls, "cancel:document_closed") > mark,
        "an in-flight prefetch is cancelled on close")
    expect(index_of(calls, "annotations.cancel") > mark, "unified annotation sync is cancelled")
    expect(host._annotation_pending_prefetch == nil and host._annotation_context == nil
        and host._current_weread_book_id == nil, "per-document state is cleared")
    expect(index_of(calls, "overlay.teardown") ~= nil, "overlay prototype is torn down")
    expect(host.ui.highlight.onTap == native_tap and host._reader_highlight_guard_target == nil,
        "native ReaderHighlight tap handler is restored")
    expect(host.ui.status.onEndOfBook == native_end and host._orig_onEndOfBook == nil,
        "native end-of-book handler is restored on close")
    expect(#hits == 0, "close never touches the network client")
    expect(#scheduled == 0, "close schedules no further work")

    -- Second close (e.g. CloseDocument fired twice): still safe and idempotent.
    warnings = {}
    host.progress_sync.on_close_document = function() end
    host.read_report.on_close_document = function() error("report gone") end
    host:onCloseDocument()
    expect(host._reader_session_gen == 3, "repeated close bumps the session again")
    expect(host.ui.status.onEndOfBook == native_end, "repeated close keeps the native handler")
    expect(host.ui.highlight.onTap == native_tap, "repeated close keeps the native tap handler")
    expect(#warnings == 1 and warnings[1]:find("read report close failed:", 1, true)
        and warnings[1]:find("report gone", 1, true),
        "read report close failure is logged, not raised")
end

-- Suspend: O(1), network-free and disk-free; each service is isolated.
do
    scheduled = {}
    warnings = {}
    local hits = {}
    local host, calls = make_host({
        hooks = {
            ["progress.suspend"] = function() error("boom") end,
            ["report.suspend"] = function() error("bang") end,
        },
    })
    host.client = tripwire("client", hits)
    host.downloader = tripwire("downloader", hits)
    host.library_db = tripwire("library_db", hits)
    host.qr_login = { on_suspend = function() calls[#calls + 1] = "qr.suspend" end }
    host._annotation_pending_prefetch = { "pending" }
    host:onSuspend()
    expect(index_of(calls, "annotations.cancel") ~= nil, "suspend cancels annotation sync")
    expect(host._annotation_pending_prefetch == nil, "suspend drops queued annotation prefetch")
    expect(index_of(calls, "qr.suspend") ~= nil, "suspend stops QR login long-polling")
    expect(index_of(calls, "progress.suspend") and index_of(calls, "report.suspend"),
        "both progress sync and read report see the suspend")
    expect(#warnings == 2 and warnings[1]:find("boom", 1, true) and warnings[2]:find("bang", 1, true),
        "suspend failures are logged rather than raised")
    expect(#hits == 0, "suspend touches neither client, downloader nor library DB")
    expect(index_of(calls, "settings.flush") == nil, "suspend does not flush settings to disk")
    expect(#scheduled == 0, "suspend schedules no work")

    -- A suspend without QR login / unified annotations is still fine, and
    -- repeated suspend + resume pairs forward every event.
    host, calls = make_host()
    host._cancelUnifiedAnnotationSync = nil
    host.qr_login = {}
    host:onSuspend()
    host:onSuspend()
    host:onResume()
    host:onResume()
    expect(count(calls, "progress.suspend") == 2 and count(calls, "report.suspend") == 2,
        "repeated suspend is forwarded each time")
    expect(count(calls, "progress.resume") == 2 and count(calls, "report.resume") == 2,
        "repeated resume is forwarded each time")
    expect(index_of(calls, "progress.resume") < index_of(calls, "report.resume"),
        "progress sync resumes before read report")
    expect(#scheduled == 0, "resume schedules no work by itself")
end

-- Page / position updates and small menu entry points.
do
    local host, calls = make_host()
    host:onPageUpdate()
    expect(index_of(calls, "progress.page") and index_of(calls, "report.page")
        and index_of(calls, "overlay.refresh"), "page update fans out to all services")
    host.read_report = nil
    host._refreshAnnotationOverlay = nil
    host:onPageUpdate()
    expect(count(calls, "progress.page") == 2, "page update tolerates missing optional services")
    host:onPosUpdate()
    expect(count(calls, "progress.page") == 3 and count(calls, "overlay.refresh") == 1,
        "position updates reach progress sync without optional services")

    host, calls = make_host()
    host:onPosUpdate()
    expect(index_of(calls, "progress.page") and index_of(calls, "report.page")
        and index_of(calls, "overlay.refresh"), "position updates fan out to all reading services")
    host:onShowWeRead()
    expect(index_of(calls, "account") ~= nil, "ShowWeRead opens the account status")
    expect(host:maybeStartReadReport() == "started" and index_of(calls, "report.start:menu"),
        "menu read report start uses the menu source")
    host:stopReadReport()
    host:stopReadReport("user")
    expect(index_of(calls, "report.stop:explicit_stop") and index_of(calls, "report.stop:user"),
        "stopReadReport defaults its reason")
    host:onFlushSettings()
    expect(index_of(calls, "settings.flush") ~= nil, "FlushSettings flushes the settings store")
    host.settings = nil
    host:onFlushSettings()
    expect(count(calls, "settings.flush") == 1, "FlushSettings without settings is a no-op")
end

-- Manual sync gesture.
do
    local host, calls = make_host({ books = { MP_1 = { cache_dir = "/lib/MP_1" } },
        file = "/lib/MP_1/a.epub" })
    expect(host:onWeReadSyncProgress() == false, "official-account articles cannot sync progress")
    expect(index_of(calls, "progress.sync_now") == nil, "no sync for an MP article")

    host, calls = make_host({ logged_in = false })
    expect(host:onWeReadSyncProgress() == false, "sync gesture requires login")
    expect(index_of(calls, "progress.sync_now") == nil, "no sync while logged out")

    host, calls = make_host()
    expect(host:onWeReadSyncProgress() == true, "sync gesture succeeds for a WeRead book")
    expect(index_of(calls, "progress.sync_now") ~= nil, "sync gesture triggers sync_now")
end

-- detectWeReadBook: binding the open document to a WeRead book.
do
    local host = make_host({ books = {
        a = { cache_dir = "/lib/a//" },
        b = { cache_dir = "/lib/abc" },
    } })
    host.ui.document = nil
    expect(host:detectWeReadBook() == nil, "no document means no WeRead book")
    host.ui.document = {}
    expect(host:detectWeReadBook() == nil, "document without a file is not bound")
    host.ui.document.file = "/lib/a/ch.epub"
    expect(host:detectWeReadBook() == "a", "trailing slashes in a book dir are ignored")
    host.ui.document.file = "/lib/abc/ch.epub"
    expect(host:detectWeReadBook() == "b", "book dir prefix requires a path boundary")
    host.ui.document.file = "/lib/zzz/nested/ch.epub"
    expect(host:detectWeReadBook() == "zzz",
        "an unknown dir under the cache root binds by its directory name")
    host.settings.cache_dir = "/lib/"
    host.ui.document.file = "/libx/zzz/ch.epub"
    expect(host:detectWeReadBook() == nil, "cache root prefix requires a path boundary")
end

-- getChapterInfoFromFile / getFullBookCachePath.
do
    local host = make_host()
    local chapters = { { chapterUid = 10 }, { chapterUid = 20 }, { chapterUid = 30 } }
    local book = {
        chapters = chapters,
        cached_chapters = { ["10"] = "/c/10.epub", ["20"] = "/c/full.epub", ["30"] = "/c/full.epub" },
    }
    local idx, ch, full = host:getChapterInfoFromFile(nil, "/c/10.epub")
    expect(idx == nil and ch == nil and full == false, "missing book maps to nothing")
    local _
    idx, _, full = host:getChapterInfoFromFile({ cached_chapters = {} }, "/c/10.epub")
    expect(idx == nil and full == false, "book without catalog maps to nothing")
    idx, ch, full = host:getChapterInfoFromFile(book, "/c/10.epub")
    expect(idx == 1 and ch == chapters[1] and full == false, "single-chapter file maps to its chapter")
    idx, ch, full = host:getChapterInfoFromFile(book, "/c/full.epub")
    expect(idx == nil and ch == nil and full == true, "file shared by chapters is a full book")
    idx, _, full = host:getChapterInfoFromFile(book, "/c/unknown.epub")
    expect(idx == nil and full == false, "unmapped file is neither a chapter nor a full book")

    book.cached_chapters = { ["99"] = "/c/orphan.epub" }
    idx = host:getChapterInfoFromFile(book, "/c/orphan.epub")
    expect(idx == nil, "mapped uid missing from the catalog yields no index")

    existing["/c/book.epub"] = true
    book.cached_full_book = "/c/book.epub"
    idx, _, full = host:getChapterInfoFromFile(book, "/c/book.epub")
    expect(full == true and idx == nil, "explicit full-book cache is recognised")
    expect(host:getFullBookCachePath(book) == "/c/book.epub", "existing full-book path wins")
    existing["/c/book.epub"] = nil
    expect(host:getFullBookCachePath(book) == nil,
        "deleted full-book file falls back to (absent) legacy path")
    expect(host:getFullBookCachePath("bad") == nil, "non-table book has no full-book path")

    -- Legacy cached_file: a single-chapter path is not a full book, an
    -- unmapped (combined) one is.
    book.cached_full_book = nil
    book.cached_file = "/c/legacy.epub"
    book.cached_chapters = {}
    expect(host:getFullBookCachePath(book) == "/c/legacy.epub",
        "unmapped legacy cached_file is a full-book cache")
    idx, _, full = host:getChapterInfoFromFile(book, "/c/legacy.epub")
    expect(full == true and idx == nil, "legacy combined EPUB maps to the full book")
    book.cached_chapters = { ["10"] = "/c/legacy.epub" }
    expect(host:getFullBookCachePath(book) == nil,
        "legacy cached_file of exactly one chapter is not a full book")
    book.cached_file = ""
    expect(host:getFullBookCachePath(book) == nil, "empty legacy path is ignored")
end

-- End of book: WeRead navigation instead of the global action.
do
    _G.G_reader_settings = nil
    local chapters = { { chapterUid = 1 }, { chapterUid = 2 } }
    local books = { book = {
        cache_dir = "/lib/book",
        chapters = chapters,
        cached_chapters = { ["1"] = "/lib/book/1.epub", ["2"] = "/lib/book/2.epub" },
    } }

    local host = make_host({ file = "/elsewhere/x.epub" })
    host._orig_onEndOfBook = function() return "native" end
    host.settings.cache_dir = "/nowhere"
    expect(host:handleEndOfBook({}) == "native", "non-WeRead book uses the native handler")

    local calls
    host, calls = make_host({ books = books, file = "/lib/book/1.epub" })
    host.ensureChaptersLoaded = function(_self, book) return book.chapters end
    expect(host:handleEndOfBook({}) == true and index_of(calls, "dialog:book"),
        "default action shows the WeRead end-of-book dialog")

    host = make_host({ books = books, file = "/lib/book/1.epub", dialog = false })
    host.ensureChaptersLoaded = function(_self, book) return book.chapters end
    host._orig_onEndOfBook = function() return "native" end
    expect(host:handleEndOfBook({}) == "native",
        "native handler is used when the dialog cannot be built")

    _G.G_reader_settings = {
        readSetting = function(_self, key)
            if key == "end_document_action" then return "next_file" end
        end,
    }
    host, calls = make_host({ books = books, file = "/lib/book/1.epub" })
    host.ensureChaptersLoaded = function(_self, book) return book.chapters end
    expect(host:handleEndOfBook({}) == true and index_of(calls, "open:2"),
        "next_file opens the following WeRead chapter")
    host.ui.document.file = "/lib/book/2.epub"
    expect(host:handleEndOfBook({}) == true and index_of(calls, "info:You have reached the last chapter."),
        "next_file on the last chapter explains there is nothing next")
    expect(count(calls, "open:") == 1, "no chapter is opened past the end")
    _G.G_reader_settings = nil
end

-- ensureChaptersLoaded: the in-memory catalog backfills a missing catalog.json
-- once and logs (not raises) a failed write.
do
    memo_puts, saved_catalogs = {}, {}
    warnings = {}
    local host = make_host()
    host.library_db = {}
    local chapters = { { chapterUid = 1 } }
    local book = { book_id = "b1", chapters = chapters, catalog_path = "/c/catalog.json" }
    save_result = { false, "read-only fs" }
    expect(host:ensureChaptersLoaded(book) == chapters, "memory catalog is returned")
    expect(#memo_puts == 1 and memo_puts[1].book_id == "b1", "memory catalog is mirrored to SQLite")
    expect(#saved_catalogs == 1 and contains(warnings, "read-only fs"),
        "failed catalog.json backfill is logged")

    saved_catalogs = {}
    existing["/c/catalog.json"] = true
    host:ensureChaptersLoaded(book)
    expect(#saved_catalogs == 0, "an existing catalog.json is not rewritten")
    existing["/c/catalog.json"] = nil
    save_result = { true }
    expect(host:ensureChaptersLoaded(nil) == nil, "nil book has no chapters")

    memo_puts = {}
    memo_loaded = { { chapterUid = 7 } }
    host.library_db = nil
    expect(host:ensureChaptersLoaded({ bookId = "b2" }) == memo_loaded,
        "memoised catalog is used when the record has none")
    expect(#memo_puts == 0, "no SQLite write without a library DB")
    host.library_db = {}
    expect(host:ensureChaptersLoaded({ bookId = "b2" }) == memo_loaded
        and #memo_puts == 1 and memo_puts[1].book_id == "b2",
        "memoised catalog is mirrored to SQLite")
    memo_loaded = nil

    -- SQLite is the last resort: it backfills the record and catalog.json.
    saved_catalogs, warnings = {}, {}
    local db_chapters = { { chapterUid = 9 } }
    host.library_db = { getChapters = function(_self, id)
        return id == "b3" and db_chapters or {}
    end }
    local b3 = { book_id = "b3" }
    save_result = { false, "disk full" }
    expect(host:ensureChaptersLoaded(b3) == db_chapters and b3.chapters == db_chapters,
        "SQLite catalog fills the book record")
    expect(#saved_catalogs == 1 and contains(warnings, "disk full"),
        "SQLite catalog backfill failure is logged")
    save_result = { true }
    expect(host:ensureChaptersLoaded({ book_id = "empty" }) == nil,
        "empty SQLite catalog is a miss")
end

-- maybePrefetchNextChapter decision paths not covered by prefetch_lifecycle_spec.
do
    local chapters = { { chapterUid = 1, title = "One" }, { chapterUid = 2 } }
    local books = { book = {
        cache_dir = "/lib/book",
        chapters = chapters,
        cached_chapters = { ["1"] = "/lib/book/1.epub" },
    } }
    local starts = {}
    local host, calls = make_host({ books = books, file = "/lib/book/1.epub",
        cache = { auto_prefetch_next_chapter = true, show_prefetch_notifications = true } })
    host.ensureChaptersLoaded = function(_self, book) return book and book.chapters end
    host.downloader.start = function(_self, book, list, kind, options)
        starts[#starts + 1] = { book = book, list = list, kind = kind, options = options }
        return true
    end

    expect(host:maybePrefetchNextChapter(nil) == false, "no book id declines prefetch")
    expect(index_of(calls, "cancel:prefetch_not_applicable") ~= nil, "declined prefetch is cancelled")

    host.ui.document = nil
    expect(host:maybePrefetchNextChapter("book") == false
        and index_of(calls, "cancel:prefetch_context_missing"),
        "prefetch needs an open document")
    host.ui.document = { file = "/lib/book/9.epub" }
    expect(host:maybePrefetchNextChapter("book") == false
        and index_of(calls, "cancel:no_next_chapter"),
        "unmapped file has no next chapter")

    host.ui.document.file = "/lib/book/1.epub"
    host.downloader.isPrefetching = function() return true end
    expect(host:maybePrefetchNextChapter("book") == true and #starts == 0,
        "an already running prefetch for the next chapter is not restarted")

    -- Cached next chapter while its prefetch is still running: keep it.
    books.book.cached_chapters["2"] = "/lib/book/2.epub"
    existing["/lib/book/2.epub"] = true
    local cancels = count(calls, "cancel:")
    expect(host:maybePrefetchNextChapter("book") == true, "cached next chapter is satisfied")
    expect(count(calls, "cancel:") == cancels, "a running prefetch is not cancelled")
    expect(index_of(calls, "annotations.prefetch:2") ~= nil,
        "annotations are prefetched for a cached next chapter")
    books.book.cached_chapters["2"] = nil
    existing["/lib/book/2.epub"] = nil
    host.downloader.isPrefetching = function() return false end

    expect(host:maybePrefetchNextChapter("book") == true and #starts == 1,
        "next chapter prefetch starts")
    local options = starts[1].options
    options.on_start()
    expect(contains(calls, "notice:Prefetching next chapter: Chapter 2@0.5"),
        "untitled next chapter is announced by its uid for half a second")
    expect(options.prefetch and options.single_chapter and options.silent_completion
        and options.offer_read == false, "prefetch is silent, single-chapter, no read offer")

    -- Plain success prefetches the chapter's annotations; a promoted success
    -- opens the new file itself, so no annotation worker is forked.
    local before_success = count(calls, "annotations.prefetch:")
    options.on_complete(true, "/lib/book/2.epub")
    expect(count(calls, "annotations.prefetch:") == before_success + 1,
        "background prefetch success also prefetches annotations")
    host.downloader.isPromotedPrefetch = function() return true end
    local annotations = count(calls, "annotations.prefetch:")
    options.on_complete(true, "/lib/book/2.epub")
    expect(count(calls, "annotations.prefetch:") == annotations,
        "promoted prefetch does not fork an annotation worker")

    -- Benign endings are logged quietly with no notice.
    host.downloader.isPromotedPrefetch = function() return false end
    -- Includes the reasons maybePrefetchNextChapter passes to cancelPrefetch
    -- itself (last chapter, prefetch switched off, context gone).
    for _, reason in ipairs({ "cancelled", "document_closed", "replaced", "manual_download",
        "setting_disabled", "next_chapter_cached", "prefetch_not_applicable", "prefetch_context_missing",
        "no_next_chapter" }) do
        local notices = count(calls, "notice:")
        options.on_complete(false, reason)
        expect(count(calls, "notice:") == notices, "no failure notice for " .. reason)
    end
    expect(contains(infos, "ended without completion:"), "benign ending is logged at info")

    for reason, text in pairs({
        offline = "Network is not connected",
        low_memory = "Not enough free memory; prefetch skipped",
        worker_unavailable = "Background prefetch is unavailable",
        worker_timeout = "Background prefetch timed out",
        weird = "display:weird",
    }) do
        options.on_complete(false, reason)
        expect(contains(calls, "notice:Next chapter prefetch failed: " .. text),
            "failure notice for " .. reason)
    end

    -- A promoted (user is waiting) prefetch that fails retries a foreground
    -- download, but only while the same document is still open.
    scheduled = {}
    host.downloader.isPromotedPrefetch = function() return true end
    local offline_notices = count(calls, "notice:Next chapter prefetch failed: Network is not connected")
    options.on_complete(false, "offline")
    expect(#scheduled == 1 and scheduled[1].delay == 1.1, "failed promoted prefetch schedules a retry")
    expect(count(calls, "notice:Next chapter prefetch failed: Network is not connected") == offline_notices + 1,
        "failed promoted prefetch tells the reader the network is down")
    run_scheduled()
    expect(index_of(calls, "download_read:2") ~= nil, "retry downloads and opens the next chapter")

    host.cache.show_prefetch_notifications = false
    options.on_complete(false, "offline")
    expect(#scheduled == 1 and scheduled[1].delay == 0.1, "silent mode retries sooner")
    host.ui.document = { file = "/lib/book/other.epub" }
    run_scheduled()
    expect(count(calls, "download_read:") == 1, "retry is dropped after the document changed")
end

print(string.format("reader_lifecycle_events_spec: %d checks passed", checks))
