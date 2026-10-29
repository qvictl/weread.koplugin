local PositionMapper = require("weread.lib.position_mapper")
local RequestOwner = require("weread.lib.request_owner")

local logger = require("weread.lib.logger").scoped("ProgressSync")

local ProgressSync = {}
ProgressSync.__index = ProgressSync

local OPEN_DELAY_SECONDS = 0.6
-- A cloud jump into another chapter file is persisted for the ReaderUI that
-- opens that file (a new plugin instance); it expires after this long, which
-- also covers downloading the chapter first.
local PENDING_JUMP_TTL_SECONDS = 10 * 60
local RESUME_RECHECK_SECONDS = 5 * 60
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local BUSY_RETRY_SECONDS = 2
-- Network work after resume or open (deferred uploads, the resume recheck)
-- waits for these delays in turn while the link is still down, then gives
-- up quietly until the next resume/open: the Amazon framework brings Wi-Fi
-- back a few seconds after resume.
local NETWORK_WORK_DELAYS = { 5, 10, 20 }
local BUSY_RETRY_LIMIT = 10
-- Background upload jobs are polled this often, up to this many times
-- (the job itself is killed after 45 s).
local UPLOAD_POLL_SECONDS = 1
local UPLOAD_POLL_LIMIT = 60
-- Automatic pulls resolve differences up to this (whole-book percent) by
-- direction, without a dialog. See ProgressSync:_resolve.
local SILENT_BAND_PERCENT = 2
-- Positions closer than this (whole-book percent) are the same spot.
local EXACT_THRESHOLD_PERCENT = 0.3
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

-- Per-book settings API (upstream #207) with a legacy "books" fallback.
local function stored_book(settings, book_id)
    if type(settings.get_book) == "function" then
        return settings:get_book(book_id)
    end
    local books = settings:get("books", {})
    return type(books) == "table" and (books[book_id] or books[tonumber(book_id)]) or nil
end

local function store_book(settings, book_id, book)
    if type(settings.put_book) == "function" then
        return settings:put_book(book_id, book)
    end
    local books = settings:get("books", {}) or {}
    books[book_id] = book
    settings:set("books", books)
end

local function all_books(settings)
    if type(settings.get_books) == "function" then
        return settings:get_books() or {}
    end
    return settings:get("books", {}) or {}
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.upload_position) == "function", "upload_position callback is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        session_owner = RequestOwner.capture(options.settings),
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        get_footer = options.get_footer,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        refresh_catalog = options.refresh_catalog,
        fetch_catalog = options.fetch_catalog,
        apply_catalog = options.apply_catalog,
        request = options.request,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        upload_position = options.upload_position,
        goto_fraction = options.goto_fraction,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        on_choice = options.on_choice or function(context)
            context.keep_local()
        end,
        notify = options.notify or function() end,
        now = options.now or os.time,
        state = "idle",
        generation = 0,
        pull_retry_token = 0,
        dirty = false,
        verified = false,
    }
    return setmetatable(object, self)
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

function ProgressSync:_persist(book_id, patch)
    if not RequestOwner.matches(self.settings, self.session_owner) then return false end
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end
    local book = stored_book(self.settings, book_id) or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    store_book(self.settings, book_id, book)
    self.settings:flush()
    return true
end

-- All timers go through here so teardown() can cancel them.
function ProgressSync:_schedule(delay, callback)
    self.timers = self.timers or {}
    local timer
    timer = function()
        self.timers[timer] = nil
        if self.torn_down then return end
        callback()
    end
    self.timers[timer] = true
    self.scheduler:scheduleIn(delay, timer)
    return timer
end

-- Cancels every timer, poll chain and open dialog of this object, for the
-- host's onCloseWidget. Unsent positions stay persisted in the book records
-- and are uploaded by the next instance.
function ProgressSync:teardown(reason)
    self:_cancel_pull()
    self:_close_choice(reason or "teardown")
    self:_persist_unsaved_uploads()
    self.torn_down = true
    self.generation = self.generation + 1
    self.pull_retry_token = self.pull_retry_token + 1
    self.upload_token = (self.upload_token or 0) + 1
    self.net_token = (self.net_token or 0) + 1
    self.uploading = nil
    if type(self.scheduler.unschedule) == "function" then
        for timer in pairs(self.timers or {}) do
            self.scheduler:unschedule(timer)
        end
    end
    self.timers = {}
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end

    local footer = self.get_footer and self.get_footer()
    local footer_value = footer and tonumber(footer.percent_finished)
    if footer_value then
        if footer_value > 1 then footer_value = footer_value / 100 end
        return math.max(0, math.min(1, footer_value))
    end

    local page
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page and type(document.getPageNumber) == "function" then
        local ok, value = pcall(document.getPageNumber, document)
        if ok then page = tonumber(value) end
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
    return nil
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    local path = document_path(document)
    if not document or not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            book = book,
            chapters = chapters,
            position_catalog = PositionMapper.catalog(chapters),
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            path = path,
        }
        cached = self.document_context
    end
    local fraction = self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local position, reason = PositionMapper.local_to_remote(
        chapters,
        fraction,
        {
            catalog = cached.position_catalog,
            is_full_book = is_full_book == true,
            current_chapter_uid = current_chapter
                and (current_chapter.chapterUid or current_chapter.chapterId),
            summary = book.summary or book.title or "",
        }
    )
    if not position then return nil, reason end
    position.book_id = book_id
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.remote_floor = nil
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters)
    local gateway
    local web
    local gateway_error
    local web_error
    if self.settings:is_api_configured() then
        local ok, result = pcall(self.client.get_progress, self.client, book_id)
        if ok then
            gateway, gateway_error = PositionMapper.normalize_remote(
                result, book_id, "gateway", chapters)
        else
            gateway_error = tostring(result)
        end
    end
    if self.settings:is_cookie_configured() then
        local ok, result = pcall(
            self.client.get_web_progress, self.client, book_id)
        if ok then
            web, web_error = PositionMapper.normalize_remote(
                result, book_id, "web", chapters)
        else
            web_error = tostring(result)
        end
    end
    local selected = PositionMapper.choose_remote(
        web,
        gateway,
        SOURCE_CONFLICT_THRESHOLD_PERCENT
    )
    if not selected then
        return nil, gateway_error or web_error or "remote_unavailable"
    end
    return selected
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end

    if target.requires_chapter_open then
        if options.no_chapter_open then
            return false, "requires_chapter_open"
        end
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            book_id = context.book_id,
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            remote = copy(remote),
            notify = options.manual == true,
            created_at = self.now(),
            owner_digest = RequestOwner.digest(self.session_owner),
        }
        -- Opening the chapter file replaces this ReaderUI and this plugin
        -- instance; the new one picks the jump up from the book record (F8).
        self:_persist(context.book_id, { pending_jump = self.pending_jump })
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self:_persist(context.book_id, { pending_jump = false })
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local ok, err, landed = self:_jump_to(target.fraction)
    if not ok then return false, err or "jump_failed" end
    self:_mark_verified(
        context.book_id,
        "remote_selected",
        landed or self.local_position,
        remote
    )
    if options.manual then
        self.notify("remote_applied", { position = remote })
    end
    return true
end

-- Moves the reader for a cloud position and records where it landed.
-- KOReader announces the move with PageUpdate (PosUpdate in scroll mode)
-- dispatched synchronously inside goto_fraction (ReaderRolling:_gotoPage),
-- and may announce the same page again later (a re-render repositions on
-- the saved xpointer). Those echoes are told apart from reading by
-- identity, never by time: events inside the call are the jump itself, and
-- the first later event at the landed position is its echo (one-shot, see
-- _is_jump_echo). Any other position is the reader's own move, however
-- soon it follows, and makes the session dirty.
function ProgressSync:_jump_to(fraction)
    self.jump_echo = nil
    self.jumping = true
    local called, ok, err = pcall(self.goto_fraction, fraction)
    self.jumping = false
    if not called then return false, tostring(ok) end
    if not ok then return false, err end
    local landed = self:capture_local()
    self.jump_echo = copy(landed)
    if landed then self.local_position = landed end
    self.dirty = false
    return true, nil, landed
end

-- True for the jump's own echo: a position event at the exact spot the
-- last cloud jump landed on. One-shot: the marker is consumed by the first
-- event after the jump, matching or not, so a later return to that spot by
-- the reader counts as reading again. Repeated echoes of the same spot are
-- no change either way (same position as local_position).
function ProgressSync:_is_jump_echo(position)
    local echo = self.jump_echo
    self.jump_echo = nil
    return echo ~= nil and PositionMapper.same_position(position, echo)
end

-- Uploads (F3, F10). A snapshot is queued per book, newest wins, so a
-- newer position captured while an older upload is in flight is never
-- dropped: it is sent after the current one finishes. Uploads run as
-- background jobs (ReadReport:upload_position is submit-or-poll), so this
-- never blocks the UI loop. Lifecycle handlers only queue (suspend) or
-- persist (close); the network happens after resume/open, once the link is
-- up. Automatic uploads carry guard data so the child never moves the
-- cloud back past newer reading done elsewhere (see ReadReport).
function ProgressSync:_enqueue_upload(position, reason, options)
    if not RequestOwner.matches(self.settings, self.session_owner) then return nil end
    options = options or {}
    if type(position) ~= "table" then return nil end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" then return nil end
    local entry = {
        book_id = book_id,
        position = copy(position),
        owner = RequestOwner.capture(self.settings),
        reason = reason or "unspecified",
        show_result = options.show_result == true,
        explicit = options.explicit == true,
        baselines = copy(options.baselines)
            or self:_known_cloud_positions(book_id),
    }
    entry.position.guard = nil
    self.upload_queue = self.upload_queue or {}
    self.upload_queue[book_id] = entry
    if options.persist ~= false then
        self:_persist_upload(entry)
    end
    return entry
end

function ProgressSync:_persist_upload(entry)
    if not RequestOwner.matches(self.settings, entry.owner) then return false end
    local persisted = self:_persist(entry.book_id, {
        pending_upload_position = entry.position,
        pending_upload_reason = entry.reason,
        pending_upload_baselines = entry.baselines or false,
        pending_upload_owner = RequestOwner.digest(entry.owner),
    })
    if persisted then entry.persisted = true end
    return persisted
end

-- Queued positions that so far only live in memory (suspend) must survive
-- this instance (document close, teardown).
function ProgressSync:_persist_unsaved_uploads()
    local entries = {}
    for _book_id, entry in pairs(self.upload_queue or {}) do
        entries[#entries + 1] = entry
    end
    if self.uploading then entries[#entries + 1] = self.uploading end
    for _i, entry in ipairs(entries) do
        if not entry.persisted then
            local ok, err = pcall(self._persist_upload, self, entry)
            if not ok then log("warn", "persist pending upload failed:", tostring(err)) end
        end
    end
end

-- Positions persisted by earlier instances (closed documents, failed
-- uploads). Without book_id: every book; with it: that book only.
function ProgressSync:_load_persisted_uploads(book_id)
    if not RequestOwner.matches(self.settings, self.session_owner) then return end
    if self:_config().upload_on_close ~= true then return end
    self.upload_queue = self.upload_queue or {}
    local books
    if book_id then
        books = { [book_id] = stored_book(self.settings, book_id) }
    else
        local ok, result = pcall(all_books, self.settings)
        if not ok then
            log("warn", "loading pending uploads failed:", tostring(result))
            return
        end
        books = result
    end
    local owner = RequestOwner.capture(self.settings)
    local digest = RequestOwner.digest(owner)
    for id, book in pairs(books) do
        id = tostring(id)
        -- Older unsigned positions stay on disk: the global book store
        -- cannot prove their account. Fresh local positions can replace them.
        if type(book) == "table" and type(book.pending_upload_position) == "table"
            and book.pending_upload_owner == digest
            and not self.upload_queue[id]
            and not (self.uploading and self.uploading.book_id == id) then
            local position = copy(book.pending_upload_position)
            position.book_id = position.book_id or id
            self.upload_queue[id] = {
                book_id = id,
                position = position,
                reason = book.pending_upload_reason or "deferred",
                owner = owner,
                baselines = type(book.pending_upload_baselines) == "table"
                    and copy(book.pending_upload_baselines) or {},
                persisted = true,
            }
        end
    end
end

-- Starts the next queued upload unless one is running, the device sleeps,
-- or the link is down (the queue then waits for the next resume/open).
function ProgressSync:_pump_uploads()
    if not RequestOwner.matches(self.settings, self.session_owner) then
        self:on_account_changed()
        return false
    end
    if self.uploading or self.suspended or self.torn_down then return false end
    local queue = self.upload_queue or {}
    local entry
    for book_id, candidate in pairs(queue) do
        -- The open book's pending position is decided by a running pull
        -- or an open choice dialog, not uploaded behind it.
        local held = book_id == self.current_book_id
            and (self.pulling or self.choice ~= nil)
        if not RequestOwner.matches(self.settings, candidate.owner) then
            queue[book_id] = nil
        elseif not held and (not entry or book_id == self.current_book_id) then
            entry = candidate
        end
    end
    if not entry then return false end
    if not self.is_online() then
        if entry.book_id == self.current_book_id then self.state = "offline" end
        if entry.show_result then
            entry.show_result = false
            self.notify("offline", {})
        end
        return false
    end
    queue[entry.book_id] = nil
    self:_start_upload(entry)
    return true
end

function ProgressSync:_start_upload(entry)
    if not RequestOwner.matches(self.settings, entry.owner) then return false end
    self.uploading = entry
    self.upload_token = (self.upload_token or 0) + 1
    local token = self.upload_token
    if entry.book_id == self.current_book_id then
        self.state = "uploading"
    end
    local payload = copy(entry.position)
    if not entry.explicit then
        payload.guard = { strict = true, baselines = copy(entry.baselines) }
    end
    -- Only the first attempt of an explicit choice goes unguarded.
    entry.explicit = false
    local attempts = 0
    local polls = 0
    local attempt
    attempt = function()
        if token ~= self.upload_token then return end
        if not RequestOwner.matches(self.settings, entry.owner) then
            if self.uploading == entry then self.uploading = nil end
            return
        end
        attempts = attempts + 1
        local ok, accepted, outcome = pcall(
            self.upload_position,
            entry.book_id,
            copy(payload),
            0
        )
        if token ~= self.upload_token then return end
        if not RequestOwner.matches(self.settings, entry.owner) then
            if self.uploading == entry then self.uploading = nil end
            return
        end
        -- The upload runs in a background job; poll for its result.
        if ok and not accepted and type(outcome) == "table"
            and outcome.error_kind == "pending"
            and polls < UPLOAD_POLL_LIMIT then
            polls = polls + 1
            attempts = attempts - 1
            self:_schedule(UPLOAD_POLL_SECONDS, attempt)
            return
        end
        if ok and not accepted and type(outcome) == "table"
            and outcome.error_kind == "busy"
            and attempts < BUSY_RETRY_LIMIT then
            self:_schedule(BUSY_RETRY_SECONDS, attempt)
            return
        end
        self.uploading = nil
        self:_finish_upload(entry, ok, accepted, outcome)
        self:_pump_uploads()
    end
    attempt()
end

function ProgressSync:_finish_upload(entry, ok, accepted, outcome)
    if not RequestOwner.matches(self.settings, entry.owner) then return false end
    local book_id = entry.book_id
    local position = entry.position
    local is_current = book_id == self.current_book_id
    local newer = self.upload_queue and self.upload_queue[book_id]
    local clear_pending = not newer and {
        pending_upload_position = false,
        pending_upload_reason = false,
        pending_upload_baselines = false,
        pending_upload_owner = false,
    } or {}
    if ok and accepted then
        self.last_uploaded_position = copy(position)
        if is_current then
            self.state = "verified"
            if not newer and (not self.local_position
                or PositionMapper.same_position(self.local_position, position)) then
                self.dirty = false
            end
        end
        clear_pending.last_uploaded_position = position
        clear_pending.last_upload_at = self.now()
        clear_pending.last_sync_error = false
        if is_current then clear_pending.last_local_position = position end
        self:_persist(book_id, clear_pending)
        log("info", "upload accepted:",
            "book=", book_id,
            "percent=", tostring(position.percent),
            "reason=", tostring(entry.reason))
        if entry.show_result then
            self.notify("upload_success", { position = position })
        end
        return
    end
    if ok and type(outcome) == "table" and outcome.error_kind == "remote_ahead" then
        -- Someone read further elsewhere: this older snapshot must not
        -- replace it. Drop it; the open book keeps the cloud as a floor.
        -- Not recorded as last_remote_position: that would make this
        -- foreign position count as one this device knew (a baseline).
        clear_pending.last_sync_error = false
        self:_persist(book_id, clear_pending)
        log("info", "upload skipped, cloud progress is ahead:",
            "book=", book_id,
            "percent=", tostring(position.percent),
            "reason=", tostring(entry.reason))
        if is_current and type(outcome.remote) == "table" then
            self.remote_floor = copy(outcome.remote)
            if self.verified and self:_config().pull_on_open == true then
                self:_clear_verified("cloud_moved")
                self:_pull({ manual = false })
            end
        end
        return
    end
    -- pcall puts a thrown error in the second value (`accepted`).
    local error_message
    if not ok then
        error_message = accepted
    elseif type(outcome) == "table" then
        error_message = outcome.error
    else
        error_message = outcome
    end
    if is_current then self.state = "error" end
    -- Keep it pending for the next resume/open.
    if not entry.persisted and not newer then
        self:_persist_upload(entry)
    end
    self:_persist(book_id, {
        last_sync_error = tostring(error_message or "upload_failed"),
    })
    log("warn", "upload failed:", tostring(error_message))
    if entry.show_result then
        self.notify("upload_failed", {
            error = tostring(error_message or "upload_failed"),
        })
    end
end

function ProgressSync:_upload_snapshot(position, reason, show_result, options)
    options = options or {}
    local entry = self:_enqueue_upload(position, reason, {
        show_result = show_result,
        explicit = options.explicit,
        baselines = options.baselines,
    })
    if not entry then return false end
    return self:_pump_uploads()
end

-- Network work after resume/open: wait for the link, then run `work`.
-- Skipped quietly when the link stays down (see NETWORK_WORK_DELAYS).
function ProgressSync:_schedule_network_work(reason, work)
    self.net_token = (self.net_token or 0) + 1
    local token = self.net_token
    local step = 1
    local try
    try = function()
        if token ~= self.net_token or self.suspended then return end
        if not self.is_online() then
            step = step + 1
            if not NETWORK_WORK_DELAYS[step] then
                log("info", "network still down, deferred sync skipped:",
                    "reason=", tostring(reason))
                return
            end
            self:_schedule(NETWORK_WORK_DELAYS[step], try)
            return
        end
        work()
    end
    self:_schedule(NETWORK_WORK_DELAYS[1], try)
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        -- An explicit choice is sent as is once; should it fail, the
        -- persisted retry is guarded by the cloud position the reader chose
        -- to replace.
        self:_upload_snapshot(local_position, options.reason, not options.silent, {
            explicit = options.reason == "explicit_local_choice",
            baselines = options.reason == "explicit_local_choice"
                and { copy(remote) } or nil,
        })
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

-- Progress policy (F6). Cloud progress is only ever moved backwards by an
-- explicit button press; everything automatic is monotonic:
--
-- 1. Within EXACT_THRESHOLD_PERCENT (or the same chapter/offset) the two
--    positions are the same spot: verified, nothing to do.
-- 2. Automatic pulls inside SILENT_BAND_PERCENT resolve by direction
--    without asking: a cloud position ahead is followed (it is newer reading
--    elsewhere, following it loses nothing); a local position ahead is kept
--    and reaches the cloud through later reports/uploads. The band used to
--    mean "same" in both directions, after which every report re-sent the
--    older local position and moved the cloud back by up to 2 %.
-- 3. A local position ahead beyond the band is still kept silently when the
--    cloud holds exactly what this device last saw or wrote there (nobody
--    read elsewhere since), so resuming after reading on the Kindle does not
--    prompt about the Kindle's own progress.
-- 4. Everything else asks (or follows ask_on_conflict = false as before).
--    A manual sync asks on any real difference so a reader can still pick
--    a nearby chapter back.
function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    -- A position queued for this book (suspend/close) is decided here: it is
    -- uploaded only on the "keep local" paths below.
    local queued = self.upload_queue and self.upload_queue[context.book_id]
    if queued and not RequestOwner.matches(self.settings, queued.owner) then
        self.upload_queue[context.book_id], queued = nil, nil
    end
    if queued then
        self.upload_queue[context.book_id] = nil
        options.upload_pending = true
        options.baselines = options.baselines or {}
        for _i, baseline in ipairs(queued.baselines or {}) do
            options.baselines[#options.baselines + 1] = baseline
        end
        if queued.persisted then
            self:_persist(context.book_id, {
                pending_upload_position = false,
                pending_upload_reason = false,
                pending_upload_baselines = false,
                pending_upload_owner = false,
            })
        end
    end
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.remote_floor = nil
    self.report_fallback = nil
    local comparison = PositionMapper.compare(
        local_position,
        remote,
        SILENT_BAND_PERCENT
    )
    local delta = PositionMapper.exact_percent(remote)
        - PositionMapper.exact_percent(local_position)
    local manual = options.manual == true
    local same = PositionMapper.same_position(local_position, remote)
        or math.abs(delta) <= EXACT_THRESHOLD_PERCENT

    if same and not remote.conflict then
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    if not manual and not remote.conflict then
        if comparison == "same" and delta > 0 then
            self:_follow_remote_silently(local_position, remote, context)
            return
        end
        if delta < 0 and (comparison == "same"
            or self:_cloud_unchanged(remote, options.baselines)) then
            self:_keep_local(local_position, remote, {
                reason = "local_ahead",
                upload_now = options.upload_pending == true
                    and self:_config().upload_on_close == true,
                silent = true,
            })
            return
        end
    end

    local ask = self:_config().ask_on_conflict ~= false
    if remote.conflict or ask or manual then
        self:_offer_choice(local_position, remote, context, options)
        return
    end

    if delta > 0 then
        local ok, reason = self:_apply_remote(
            remote, context, { manual = options.manual })
        if not ok then
            self.state = "error"
            self.notify("jump_failed", { error = reason })
        end
    else
        self:_keep_local(local_position, remote, {
            manual = options.manual,
            upload_now = options.manual == true,
            reason = "manual_sync",
        })
    end
end

-- Cloud ahead within the silent band: jump there. A per-chapter EPUB whose
-- cloud position lies in another chapter file is not switched behind the
-- reader's back; the session is verified with the cloud position as a floor
-- instead, so no report or upload sends anything behind it.
function ProgressSync:_follow_remote_silently(local_position, remote, context)
    local ok, reason = self:_apply_remote(remote, context, {
        no_chapter_open = true,
    })
    if ok then
        log("info", "followed nearby cloud progress:",
            "book=", context.book_id,
            "local=", tostring(PositionMapper.exact_percent(local_position)),
            "remote=", tostring(remote.percent))
        return
    end
    self.dirty = false
    self:_mark_verified(context.book_id, "remote_floor", local_position, remote)
    self.remote_floor = copy(remote)
    log("info", "kept local position below nearby cloud progress:",
        "book=", context.book_id, "reason=", tostring(reason))
end

-- Never upload a position below a cloud floor (see _follow_remote_silently).
function ProgressSync:_below_floor(position)
    return self.remote_floor ~= nil and PositionMapper.is_behind(
        position, self.remote_floor, EXACT_THRESHOLD_PERCENT)
end

-- True when the cloud position equals one this device last saw or wrote.
function ProgressSync:_cloud_unchanged(remote, baselines)
    for _i, baseline in ipairs(baselines or {}) do
        if PositionMapper.same_spot(remote, baseline) then
            return true
        end
    end
    return false
end

-- Cloud positions this device knows about for `book_id`: the last pulled
-- and uploaded positions and the last position the read report sent (its
-- context fields). Must be collected before a pull persists its result.
function ProgressSync:_known_cloud_positions(book_id, extra)
    local result = {}
    local function add(position)
        if type(position) == "table" and (position.chapter_uid ~= nil
            or position.percent ~= nil) then
            result[#result + 1] = position
        end
    end
    if self.current_book_id == book_id then
        add(self.remote_position)
    end
    add(self.last_uploaded_position)
    local ok, book = pcall(self.get_book, book_id)
    if ok and type(book) == "table" then
        add(book.last_remote_position)
        add(book.last_uploaded_position)
        -- The read report's last position counts only when it was this
        -- device's reading position, not a cloud position it re-asserted.
        if book.reported_local == true
            and book.chapter_uid ~= nil and book.chapter_offset ~= nil then
            add({
                chapter_uid = book.chapter_uid,
                chapter_offset = tonumber(book.chapter_offset),
                percent = tonumber(book.progress),
            })
        end
    end
    for _i, position in ipairs(extra or {}) do add(position) end
    return result
end

-- Closes a choice dialog that is still on screen without treating it as an
-- answer (document closed, device suspended). Returns true when one was open.
function ProgressSync:_close_choice(reason)
    local choice = self.choice
    if not choice then return false end
    self.choice = nil
    if type(choice.close) == "function" then
        local ok, err = pcall(choice.close)
        if not ok then log("warn", "closing progress choice failed:", tostring(err)) end
    end
    if self.state == "awaiting_choice" then
        self.state = "unverified"
    end
    if type(choice.remote_position) == "table" then
        self.report_fallback = copy(choice.remote_position)
        self.report_fallback.chapter_title = nil
    end
    log("info", "progress choice closed without an answer:",
        "book=", tostring(self.current_book_id),
        "reason=", tostring(reason))
    return true
end

function ProgressSync:_offer_choice(local_position, remote, context, options)
    -- One dialog at a time. A second conflict (resume recheck, manual sync)
    -- would otherwise stack another box whose callbacks are also "current".
    if self.choice then return end
    self.state = "awaiting_choice"
    local choice_generation = self.generation
    local choice_owner = RequestOwner.capture(self.settings)
    local choice_position = self:capture_local()
    local choice_path = document_path(self.get_document())
    local choice
    local function choice_is_current()
        if self.choice ~= choice or choice_generation ~= self.generation
            or tostring(self.detect_book() or "") ~= context.book_id then return false end
        local owner_valid = RequestOwner.matches(self.settings, choice_owner)
        local current_position = owner_valid and self:capture_local() or nil
        if not owner_valid or document_path(self.get_document()) ~= choice_path
            or not choice_position or not current_position
            or not PositionMapper.same_position(current_position, choice_position) then
            self:_close_choice("context_changed")
            self.verified, self.remote_floor, self.dirty = false, nil, true
            if not owner_valid then self.report_fallback = nil end
            return false
        end
        return true
    end
    local function chapter_title(position)
        local uid = position and position.chapter_uid
        if uid ~= nil and type(context.chapters) == "table" then
            for _, chapter in ipairs(context.chapters) do
                if tostring(chapter.chapterUid or chapter.chapterId) == tostring(uid) then
                    if chapter.title and chapter.title ~= "" then
                        return chapter.title
                    end
                end
            end
        end
        return position and position.summary or ""
    end
    local local_choice = copy(local_position)
    local remote_choice = copy(remote)
    local_choice.chapter_title = chapter_title(local_position)
    remote_choice.chapter_title = chapter_title(remote)
    choice = {
        book_title = context.book.title or context.book_id,
        local_position = local_choice,
        remote_position = remote_choice,
        source_conflict = remote.conflict == true,
        -- Keeping the local position would move cloud progress back:
        -- the dialog asks for a second confirmation first.
        local_behind_remote = PositionMapper.is_behind(
            local_position, remote, EXACT_THRESHOLD_PERCENT),
        use_remote = function()
            if not choice_is_current() then return end
            self.choice = nil
            local ok, reason = self:_apply_remote(
                remote, context, { manual = options.manual })
            if not ok then
                self.state = "error"
                self.notify("jump_failed", { error = reason })
            end
        end,
        keep_local = function()
            if not choice_is_current() then return end
            self.choice = nil
            self:_keep_local(local_position, remote, {
                manual = options.manual,
                upload_now = true,
                reason = "explicit_local_choice",
            })
        end,
        -- Tap outside / Back: no answer. Nothing is uploaded or moved;
        -- the session stays unverified and the choice is offered again
        -- on the next open, resume recheck or manual sync.
        dismiss = function()
            if not choice_is_current() then return end
            self.choice = nil
            self.state = "unverified"
            -- Reading time is still reported, carrying the cloud's own
            -- position, so neither side moves until the reader decides.
            self.report_fallback = copy(remote)
            log("info", "progress choice dismissed, nothing uploaded:",
                "book=", context.book_id)
        end,
    }
    self.choice = choice
    self.on_choice(choice)
end

function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local generation = self.generation
    self:_schedule(PULL_RETRY_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull({
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        })
    end)
    log("info", "pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_cancel_pull()
    local cancel = self.pull_cancel
    self.pull_cancel, self.pull_request, self.pulling = nil, nil, false
    if type(cancel) == "function" then
        local ok, err = pcall(cancel)
        if not ok then log("warn", "cancel progress pull failed:", tostring(err)) end
    end
end

function ProgressSync:_pull(options)
    options = options or {}
    if not RequestOwner.matches(self.settings, self.session_owner) then
        self:on_account_changed()
        if not options.manual then return false end
        self.session_owner = RequestOwner.capture(self.settings)
    end
    if self.pulling then return false end
    -- A choice dialog is still waiting for an answer: do not stack another.
    if self.choice then return false end
    -- A real sync compares positions afresh; an older jump has no echo left.
    self.jump_echo = nil
    local retry_token = options.retry_token
    if retry_token == nil then
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        if not (options.manual == true
            and reason == "catalog_unavailable"
            and (type(self.fetch_catalog) == "function" or type(self.refresh_catalog) == "function")) then
            if options.manual then
                self.notify("local_unavailable", { error = reason })
            end
            return false
        end
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local generation, request_token = self.generation, {}
    local book_id = tostring(self.detect_book() or "")
    local path = document_path(self.get_document())
    local owner = RequestOwner.capture(self.settings)
    self.session_owner = owner
    self.pull_request, self.pulling = request_token, true
    self.state = "pulling"
    local function release()
        if self.pull_request == request_token then
            self.pull_request, self.pull_cancel, self.pulling = nil, nil, false
            if self.state == "pulling" then self.state = "unverified" end
            if not RequestOwner.matches(self.settings, owner) then
                self.verified, self.remote_floor, self.report_fallback = false, nil, nil
            end
        end
    end
    local function current()
        return self.pull_request == request_token and generation == self.generation
            and not self.torn_down and not self.suspended and RequestOwner.matches(self.settings, owner)
            and tostring(self.detect_book() or "") == book_id
            and document_path(self.get_document()) == path
    end
    local function guarded(callback)
        return function(...)
            if not current() then release(); return end
            local args = { ... }
            local ok, err = xpcall(function() return callback(unpack(args)) end, debug.traceback)
            if not ok then
                release()
                self.state = "error"
                if options.manual then self.notify("pull_failed", { error = tostring(err) })
                else self:_schedule_pull_retry(options, retry_token) end
            end
        end
    end
    local function failed(err, cancelled)
        self.pulling = false
        if cancelled then
            self.state = self.verified and "synced" or "unverified"
            if not options.manual then self:_schedule_pull_retry(options, retry_token) end
        else
            self.state = "error"
            self:_persist(book_id, { last_pull_at = self.now(), last_sync_error = tostring(err) })
            if options.manual then self.notify("pull_failed", { error = tostring(err) })
            else self:_schedule_pull_retry(options, retry_token) end
        end
        release()
    end
    local function request(task, on_success, on_failure)
        if not current() then release(); return end
        self.pull_cancel = nil
        local success, failure = guarded(on_success), guarded(on_failure or failed)
        if self.request then
            local ok, cancel = pcall(self.request, task, success, failure, options)
            if not ok then failure(cancel, false)
            elseif self.pull_request == request_token and self.pulling and type(cancel) == "function" then
                self.pull_cancel = cancel
            end
        else
            -- Non-UI consumers may execute their supplied client directly.
            local ok, value = pcall(task)
            if ok then success(value) else failure(value, false) end
        end
    end
    local function fetched(result)
        self.pulling = false
        local remote, pull_error = result.remote, result.error
        if not remote then return failed(pull_error, false) end
        local_position, reason, context = self:capture_local()
        if not local_position then
            self.state = "error"
            self.notify("local_unavailable", { error = reason })
            release()
            return
        end
        -- Keep the positions known before this result replaces them.
        options.baselines = self:_known_cloud_positions(book_id)
        self:_persist(book_id, {
            last_remote_position = remote,
            last_local_position = local_position,
            last_pull_at = self.now(), last_sync_error = false,
        })
        self:_resolve(local_position, remote, context, options)
        self:_pump_uploads()
        release()
    end
    local function fetch_remote()
        request(function()
            local remote, err = self:_fetch_remote(context.book_id, context.chapters)
            return { remote = remote, error = err }
        end, fetched)
    end
    local function after_catalog(refreshed, refresh_error)
        self.document_context = nil
        local_position, reason, context = self:capture_local()
        if not local_position then
            self.pulling, self.state = false, "error"
            self.notify("local_unavailable", { error = refresh_error or reason })
            release()
            return
        end
        if type(refreshed) ~= "table" or #refreshed == 0 then
            log("warn", "catalog refresh returned no chapters for:", book_id)
        end
        fetch_remote()
    end
    local function start_request()
        if local_position then return fetch_remote() end
        if self.fetch_catalog then
            request(function() return self.fetch_catalog(book_id) end, function(chapters)
                local refreshed, err = chapters
                if self.apply_catalog then refreshed, err = self.apply_catalog(book_id, chapters) end
                after_catalog(refreshed, err)
            end, function(err, cancelled)
                if cancelled then return failed(err, true) end
                after_catalog(nil, err)
            end)
        else
            local ok, refreshed, err = pcall(self.refresh_catalog, book_id)
            if not ok then err, refreshed = refreshed, nil end
            after_catalog(refreshed, err)
        end
    end
    local started = self.run_online("progress_pull", guarded(start_request), {
        silent_offline = true, link_only = true,
    })
    if not started then
        release()
        self.state = "offline"
        if options.manual then self.notify("offline", {})
        else self:_schedule_pull_retry(options, retry_token) end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    if not pending then
        local ok, book = pcall(stored_book, self.settings, tostring(book_id))
        pending = ok and type(book) == "table" and type(book.pending_jump) == "table"
            and book.pending_jump or nil
    end
    if not pending or tostring(pending.book_id or book_id) ~= tostring(book_id) then
        return false
    end
    -- A chapter-open transaction may survive its plugin instance, but not
    -- a cookie/gateway owner change. Preserve unsigned legacy records.
    if pending.owner_digest ~= RequestOwner.digest(self.session_owner) then return false end
    if self.now() - (tonumber(pending.created_at) or 0) > PENDING_JUMP_TTL_SECONDS then
        self:_persist(book_id, { pending_jump = false })
        return false
    end
    pending.book_id = pending.book_id or book_id
    local local_position, _reason, context = self:capture_local()
    if not context or not context.current_chapter
        or tostring(context.current_chapter.chapterUid or context.current_chapter.chapterId)
            ~= tostring(pending.chapter_uid) then
        return false
    end
    self.pending_jump = nil
    self:_persist(book_id, { pending_jump = false })
    local ok, err, landed = self:_jump_to(pending.fraction)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        landed or local_position,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    local book_id = self.pending_jump.book_id
    self.pending_jump = nil
    if book_id then self:_persist(book_id, { pending_jump = false }) end
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

-- Account transitions invalidate in-memory work without touching the new
-- account's book records. Existing pending positions stay with their store.
function ProgressSync:on_account_changed()
    self.session_owner = nil
    self:_cancel_pull()
    self:_close_choice("account_changed")
    self.upload_token = (self.upload_token or 0) + 1
    self.net_token = (self.net_token or 0) + 1
    self.pull_retry_token = self.pull_retry_token + 1
    self.generation = self.generation + 1
    self.upload_queue, self.uploading = {}, nil
    self.current_book_id, self.pending_jump = nil, nil
    self.local_position, self.remote_position, self.remote_floor = nil, nil, nil
    self.report_fallback, self.document_context, self.jump_echo = nil, nil, nil
    self.verified, self.dirty, self.state = false, false, "unverified"
    if type(self.scheduler.unschedule) == "function" then
        for timer in pairs(self.timers or {}) do self.scheduler:unschedule(timer) end
    end
    self.timers = {}
end

function ProgressSync:on_reader_ready()
    self:_cancel_pull()
    self.session_owner = RequestOwner.capture(self.settings)
    self:_close_choice("document_changed")
    self.generation = self.generation + 1
    local generation = self.generation
    -- A request of the previous document may still be marked in flight.
    -- Its upload stays queued (and persisted) for the pump below.
    self.pulling = false
    if self.uploading then
        local entry = self.uploading
        self.uploading = nil
        self.upload_token = (self.upload_token or 0) + 1
        self.upload_queue = self.upload_queue or {}
        if not self.upload_queue[entry.book_id] then
            self.upload_queue[entry.book_id] = entry
        end
    end
    self.suspended = false
    self.current_book_id = nil
    self.local_position = nil
    self.remote_position = nil
    self.remote_floor = nil
    self.report_fallback = nil
    self.document_context = nil
    self.jump_echo = nil
    self.verified = false
    self.dirty = false
    self.state = "waiting"

    self:_schedule(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        local book_id = self.detect_book()
        if not book_id or is_mp_book(book_id) then
            self.state = "unsupported"
            return
        end
        book_id = tostring(book_id)
        self.current_book_id = book_id
        if self:_apply_pending_jump(book_id) then return end

        local local_position, reason = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            log("warn", "local position unavailable:", tostring(reason))
            return
        end
        self.local_position = local_position
        self:_persist(book_id, { last_local_position = local_position })
        -- This book's position left pending by an earlier session is decided
        -- by the pull below when there is one, uploaded (guarded) otherwise.
        -- Other books' pending positions are sent after the next resume.
        self:_load_persisted_uploads(book_id)
        if self:_config().pull_on_open == true then
            self:_pull({ manual = false })
        else
            self.state = "unverified"
            self:_pump_uploads()
        end
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    local position = self:capture_local()
    if not position then return end
    if self.jumping or self:_is_jump_echo(position) then
        self.local_position = position
        return
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

-- Must not touch the network (F3): the final position is persisted as a
-- pending upload and sent by a later instance after open/resume.
function ProgressSync:on_close_document()
    self:_cancel_pull()
    -- A choice left on screen would float over the next document.
    self:_close_choice("document_closed")
    -- Only a verified WeRead book can enqueue an upload; don't scan the
    -- library to detect a non-WeRead document.
    local position = self.current_book_id
        and (self:capture_local() or self.local_position) or nil
    if position and self.verified
        and self:_config().upload_on_close == true
        and not self:_below_floor(position) then
        if not self.local_position
            or not PositionMapper.same_position(position, self.local_position) then
            self.dirty = true
        end
        if self.dirty then
            self:_enqueue_upload(position, "document_close")
        end
    end
    self:_persist_unsaved_uploads()
    -- Results of an upload still in flight are ignored from here on; its
    -- position stays persisted until a later upload succeeds.
    self.upload_token = (self.upload_token or 0) + 1
    self.uploading = nil
    self.net_token = (self.net_token or 0) + 1
    self.generation = self.generation + 1
    self.current_book_id = nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.remote_floor = nil
    self.report_fallback = nil
    self.document_context = nil
    self.jump_echo = nil
end

-- O(1) and network-free (F3, F16): the device and its Wi-Fi are going to
-- sleep. Remember what to upload (in memory) and stop every chain.
function ProgressSync:on_suspend()
    self:_cancel_pull()
    self.suspended = true
    self.suspended_at = self.now()
    -- Positions in an unanswered dialog may be stale after sleeping; ask
    -- again with fresh data after resume instead.
    if self:_close_choice("suspend") then
        self.reask_after_resume = true
    end
    local position = self.current_book_id
        and (self:capture_local() or self.local_position) or nil
    if position and self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.upload_queue = self.upload_queue or {}
    -- The in-flight upload's job is killed with ReadReport's; queue it again
    -- unless a newer position replaces it below.
    if self.uploading then
        local entry = self.uploading
        self.uploading = nil
        if not self.upload_queue[entry.book_id] then
            self.upload_queue[entry.book_id] = entry
        end
    end
    if position and self.verified and self.dirty
        and self:_config().upload_on_close == true
        and not self:_below_floor(position) then
        self:_enqueue_upload(position, "suspend", { persist = false })
    end
    self.upload_token = (self.upload_token or 0) + 1
    self.net_token = (self.net_token or 0) + 1
    self.pull_retry_token = self.pull_retry_token + 1
end

-- Nothing network-bound runs here (F4): the recheck pull and queued
-- uploads wait a few seconds for Wi-Fi and are skipped quietly when it
-- stays down.
function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    self.suspended = false
    local reask = self.reask_after_resume == true
    self.reask_after_resume = nil
    local book_id = self.current_book_id
    local recheck = book_id ~= nil
        and self:_config().pull_on_open == true
        and (slept >= RESUME_RECHECK_SECONDS or reask
            or (not self.verified and not self.report_fallback
                and self.state ~= "switching_chapter"))
    local generation = self.generation
    self:_schedule_network_work("resume", function()
        if generation ~= self.generation then return end
        if recheck and not self.choice and not self.pulling then
            -- Someone may have read elsewhere while we slept. A position
            -- queued at suspend goes through this pull (see _resolve).
            self:_clear_verified("resume_recheck")
            self:_pull({ manual = false })
        end
        self:_load_persisted_uploads()
        self:_pump_uploads()
    end)
end

function ProgressSync:sync_now()
    return self:_pull({ manual = true })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if not self.verified then
        -- An unanswered (dismissed or suspended) choice: report time with
        -- the cloud's own position so neither side moves.
        if self.report_fallback and self.state ~= "awaiting_choice" then
            local fallback = copy(self.report_fallback)
            fallback.book_id = tostring(book_id)
            fallback.cloud = true
            return fallback, nil, true
        end
        -- Without automatic pulls nothing ever verifies the session, so
        -- gating would drop all reading time. Let the report fall back to
        -- its remote-derived context position instead, unless a manual sync
        -- is still waiting on a conflict choice.
        if self:_config().pull_on_open ~= true
            and self.state ~= "awaiting_choice" then
            return nil, nil, false
        end
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    -- The session was verified below a nearby cloud position (another
    -- chapter file): report the cloud's position until reading passes it.
    if self.remote_floor then
        if PositionMapper.is_behind(position, self.remote_floor,
            EXACT_THRESHOLD_PERCENT) then
            local floor = copy(self.remote_floor)
            floor.book_id = tostring(book_id)
            floor.cloud = true
            return floor, nil, true
        end
        self.remote_floor = nil
    end
    return position, nil, true
end

function ProgressSync:status()
    return {
        state = self.state,
        book_id = self.current_book_id,
        verified = self.verified,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading ~= nil and self.uploading ~= false,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
