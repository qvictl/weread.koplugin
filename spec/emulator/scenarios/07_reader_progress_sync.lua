-- @title Reader progress sync: download, paginate, conflict dismissal, monotonic cloud
-- @timeout 150
-- Real user path: the full book 900001 is downloaded through the plugin's
-- "download all chapters" dialog, opened via "Read now" in the real
-- ReaderUI, paginated and paged with real taps. Progress rules checked
-- against the mock's progress_history:
--   (a) cloud AHEAD on open -> choice dialog; dismissing it (tap outside /
--       Back) never uploads the older local position (F1/F13);
--   (b) following the cloud, reading forward and closing persists the newer
--       position, which the next open uploads (F3: nothing at close);
--   (c) no automatic action ever moves the cloud backwards (F6), also when a
--       stale pending upload meets a cloud that moved further ahead.
-- A page turned on the very next UI tick after the cloud jump (far inside
-- the 150 ms window that used to be taken for the jump's own echo) is
-- reading: it is uploaded after Suspend/Resume.
local BOOK_ID = "900001"
local TOTAL_WORDS = 6 * 1800

return function(H)
    local tr = H.tr
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")

    -- Painted widget whose text is exactly label (buttons; avoids matching
    -- the same word inside a dialog's message).
    local function find_exact(label)
        return H.find_tappable(label)
    end

    local function tap_exact(label, timeout)
        return H.tap_exact(label, timeout)
    end

    local function wait_reader_ready(previous)
        return H.wait_until("ReaderUI ready with the weread plugin", function()
            local reader = H.reader()
            if reader and reader ~= previous and reader.document
                and reader.postReaderReadyCallback == nil and reader.weread then
                return reader
            end
        end, 30)
    end

    -- Progress-sync open delay (0.6 s) + pull: wait until it settled.
    local function wait_sync_settled(expect)
        return H.wait_until("progress sync state " .. expect, function()
            local plugin = H.plugin()
            local state = plugin and plugin.progress_sync and plugin.progress_sync.state
            return state == expect and state or nil
        end, 20)
    end

    local function history()
        return H.mock_state().progress_history or {}
    end

    local function uploads()
        local out = {}
        for _i, entry in ipairs(history()) do
            if entry.source == "upload" then out[#out + 1] = entry end
        end
        return out
    end

    local function read_posts()
        return #H.mock_requests(function(event)
            return event.method == "POST" and event.path == "/web/book/read"
        end)
    end

    local function cloud_percent(entry)
        local uid = tonumber(entry.chapterUid) or 1
        return ((uid - 1) * 1800 + (tonumber(entry.chapterOffset) or 0)) / TOTAL_WORDS * 100
    end

    local function describe(entry)
        return string.format("%s ch%s+%s (%.2f%%, pr=%s)", tostring(entry.source),
            tostring(entry.chapterUid), tostring(entry.chapterOffset), cloud_percent(entry),
            tostring(entry.progress))
    end

    local function set_cloud(chapter_uid, offset)
        local code = H.mock_post("/__progress", {
            bookId = BOOK_ID, chapterUid = chapter_uid, chapterIdx = chapter_uid,
            chapterOffset = offset,
            progress = math.floor(((chapter_uid - 1) * 1800 + offset) / TOTAL_WORDS * 100),
            updateTime = os.time(),
        })
        H.check(code == 200, "mock accepted /__progress", tostring(code))
    end

    local function current_page()
        return H.call(function() return H.reader():getCurrentPage() end)
    end

    local function turn_page_forward()
        local before = current_page()
        local screen = H.screen()
        -- Real tap in the right page-turn zone (outside the thought tap area).
        H.tap_at(math.floor(screen:getWidth() * 0.92), math.floor(screen:getHeight() * 0.5))
        H.wait_until("page turned forward from " .. before, function()
            return H.reader():getCurrentPage() > before
        end, 10)
        return current_page()
    end

    -- The reader's "go to file browser" action: closes the document (the
    -- plugin's onCloseDocument/onCloseWidget run) and shows the FileManager.
    local function close_to_file_manager()
        H.call(function() H.reader():onHome() end)
        H.wait_until("reader closed, FileManager plugin back", function()
            return H.reader() == nil and H.file_manager() and H.plugin()
        end, 10)
    end

    local function local_percent()
        return H.call(function()
            local position = H.plugin().progress_sync:capture_local()
            return position and position.fraction * 100 or nil
        end)
    end

    -- ConfirmBox titles are not rendered by every KOReader release; the
    -- message's last line is.
    local function dialog_shown()
        return H.has_text(tr("Choose which position to keep."))
    end

    local book_path
    local control_entries = 0

    H.step("configure progress sync", function()
        H.wait_until("weread plugin on FileManager", function() return H.plugin() end, 20)
        H.call(function()
            local settings = H.runtime().settings
            settings:set("sync", {
                pull_on_open = true,
                upload_on_close = true,
                ask_on_conflict = true,
                upload_interval_minutes = 0,
            })
            local report = settings:get("read_report")
            report.enabled = false
            settings:set("read_report", report)
            settings:flush()
        end)
    end)

    H.step("download full book through the plugin dialog", function()
        H.call(function()
            local plugin = H.plugin()
            local book = plugin.client:get_book_info(BOOK_ID)
            plugin.settings:put_book(BOOK_ID, book)
            plugin.settings:flush()
            plugin:confirmDownloadAllChapters(plugin.settings:get_book(BOOK_ID))
        end)
        tap_exact(tr("Download"))
        local started = H.now_ms()
        H.wait_until("download finished (Read now offered)", function()
            return find_exact(tr("Read now"))
        end, 60)
        H.metric("full_download_ms", H.now_ms() - started)
        book_path = H.call(function()
            return H.runtime().settings:get_book(BOOK_ID).cached_full_book
        end)
        H.check(type(book_path) == "string" and H.file_exists(book_path), "full EPUB on disk", tostring(book_path))
        H.shot("07-01-download-complete")
    end)

    H.step("(a) cloud ahead on open offers the choice dialog", function()
        set_cloud(4, 900) -- 58.3 % of the book
        control_entries = control_entries + 1
        tap_exact(tr("Read now"))
        wait_reader_ready()
        H.wait_until("progress choice dialog", dialog_shown, 20)
        local plugin = H.plugin()
        local state = H.call(function() return plugin.progress_sync:status() end)
        H.equal(state.state, "awaiting_choice", "sync state with dialog open")
        H.check(state.remote_position and state.remote_position.chapter_uid == 4,
            "dialog compares against the cloud chapter", tostring(state.remote_position and state.remote_position.chapter_uid))
        H.shot("07-02-conflict-dialog")
    end)

    H.step("(a) dismissing the dialog uploads nothing", function()
        local posts_before = read_posts()
        -- Tap outside the ConfirmBox: no answer.
        H.tap_at(8, 8)
        H.wait_until("dialog dismissed", function() return not dialog_shown() end, 10)
        local plugin = H.plugin()
        local state = H.call(function()
            return { state = plugin.progress_sync.state, verified = plugin.progress_sync.verified,
                choice = plugin.progress_sync.choice ~= nil }
        end)
        H.equal(state.state, "unverified", "state after dismissal")
        H.equal(state.verified, false, "dismissal does not verify")
        H.equal(state.choice, false, "no choice pending after dismissal")
        H.sleep(3)
        H.equal(#uploads(), 0, "uploads after dismissal")
        H.equal(read_posts(), posts_before, "/web/book/read requests after dismissal")
        H.shot("07-03-dismissed")
    end)

    H.step("paginates and turns pages with real taps", function()
        local count = H.call(function()
            local reader = H.reader()
            reader.rolling:onGotoPage(1)
            return reader.document:getPageCount()
        end)
        H.check(count > 5, "downloaded EPUB paginates", tostring(count))
        H.metric("page_count", count)
        H.wait_until("on page 1", function() return H.reader():getCurrentPage() == 1 end, 5)
        H.shot("07-04-page-1")
        local page = turn_page_forward()
        H.equal(page, 2, "page after one forward tap")
        H.shot("07-05-page-2")
        H.equal(#uploads(), 0, "page turns of an unverified session upload nothing")
    end)

    local followed_percent
    local turned_percent
    H.step("(b) manual sync follows the cloud, the page is turned right away", function()
        local plugin = H.plugin()
        -- Seam: the reader's page-forward handler runs on the UI tick right
        -- after the cloud jump returns, the earliest a tap can be handled.
        local jump = {}
        H.call(function()
            local sync = plugin.progress_sync
            local goto_fraction = sync.goto_fraction
            sync.goto_fraction = function(fraction)
                sync.goto_fraction = goto_fraction
                local ok, err = goto_fraction(fraction)
                jump.ms = H.now_ms()
                jump.page = H.reader():getCurrentPage()
                local landed = sync:capture_local()
                jump.percent = landed and landed.fraction * 100
                UIManager:nextTick(function()
                    jump.turn_ms = H.now_ms()
                    -- What the tap_forward zone runs (a real tap would only
                    -- dismiss the "Jumped to WeRead progress" notice).
                    H.reader().rolling:onGotoViewRel(1)
                    jump.turned_page = H.reader():getCurrentPage()
                end)
                return ok, err
            end
        end)
        H.call(function() plugin:onWeReadSyncProgress() end)
        H.wait_until("manual sync dialog", dialog_shown, 20)
        tap_exact(tr("Use WeRead progress"))
        H.wait_until("page turned right after the cloud jump", function()
            return jump.turned_page ~= nil
        end, 10)
        local gap = jump.turn_ms - jump.ms
        H.metric("turn_after_jump_ms", gap)
        H.check(gap < 150, "page turned inside the old 150 ms echo window", tostring(gap))
        H.check(jump.turned_page > jump.page, "page turn moved forward",
            tostring(jump.page), "->", tostring(jump.turned_page))
        followed_percent = jump.percent
        H.check(followed_percent and math.abs(followed_percent - 58.3) < 3,
            "reader jumped near the cloud's 58.3 %", tostring(followed_percent))
        H.metric("followed_percent", string.format("%.2f", followed_percent))
        -- Well past the old window: the turn must still count as reading.
        H.sleep(0.5)
        H.close_dialogs() -- "Jumped to WeRead progress" notice
        local state = H.call(function() return plugin.progress_sync:status() end)
        H.equal(state.verified, true, "verified at the cloud position")
        H.equal(state.dirty, true, "the immediate page turn is unsynced reading")
        turned_percent = local_percent()
        H.check(turned_percent > followed_percent + 0.05, "local position follows the turned page",
            string.format("jump=%.2f turned=%.2f", followed_percent, turned_percent))
        H.equal(#uploads(), 0, "following the cloud uploads nothing")
        H.shot("07-06-followed-cloud-turned")
    end)

    H.step("(b) the page turned right after the jump is uploaded", function()
        H.broadcast("Suspend")
        H.broadcast("Resume")
        -- Resume waits a few seconds for Wi-Fi before network work.
        local entry = H.wait_until("upload of the turned page", function()
            local list = uploads()
            return list[#list]
        end, 30)
        H.log("uploaded:", describe(entry))
        H.check(math.abs(cloud_percent(entry) - turned_percent) < 0.5,
            "uploaded the page turned right after the jump", describe(entry),
            string.format("local=%.2f", turned_percent))
        H.check(cloud_percent(entry) > followed_percent + 0.05,
            "upload is past the jump target", describe(entry))
        H.wait_until("turned page accepted", function()
            local sync = H.plugin().progress_sync
            return not sync.dirty and sync.uploading == nil
        end, 15)
    end)

    local read_to
    H.step("(b) read forward, close: persisted, not sent at close", function()
        -- One page was already turned right after the jump.
        for _i = 1, 2 do turn_page_forward() end
        H.sleep(0.3)
        read_to = local_percent()
        H.check(read_to > 58.4, "read past the cloud position", tostring(read_to))
        H.metric("read_to_percent", string.format("%.2f", read_to))
        local posts_before = read_posts()
        close_to_file_manager()
        local pending = H.call(function()
            return H.runtime().settings:get_book(BOOK_ID).pending_upload_position
        end)
        H.check(type(pending) == "table", "close persisted the newer position as pending upload")
        H.sleep(1)
        H.equal(read_posts(), posts_before, "no network request at document close (F3)")
    end)

    H.step("(b) reopen uploads the newer position", function()
        local uploads_before = #uploads()
        H.call(function() H.plugin():openFile(book_path) end)
        wait_reader_ready()
        local entry = H.wait_until("upload of the newer position", function()
            local list = uploads()
            return #list > uploads_before and list[#list]
        end, 30)
        H.log("uploaded:", describe(entry))
        H.check(cloud_percent(entry) > 58.4, "uploaded position is ahead of the old cloud", describe(entry))
        H.check(math.abs(cloud_percent(entry) - read_to) < 2.5, "uploaded the position read locally", describe(entry),
            string.format("local=%.2f", read_to))
        H.check(not dialog_shown(), "no dialog when only this device moved")
        -- The parent collects the background job's result by polling.
        H.wait_until("pending upload cleared after acceptance", function()
            local book = H.runtime().settings:get_book(BOOK_ID)
            return book.pending_upload_position == nil and book.last_uploaded_position ~= nil
        end, 15)
        H.shot("07-07-reopened-uploaded")
    end)

    H.step("scroll mode marks the new position dirty and uploads it", function()
        local mapper = require("weread.lib.position_mapper")
        H.call(function() H.reader().view:onSetViewMode("scroll") end)
        local scrolled_percent = H.call(function()
            local sync = H.plugin().progress_sync
            local before = sync:capture_local()
            H.reader().rolling:onGotoViewRel(1)
            local after = sync:capture_local()
            H.check(not mapper.same_position(before, after), "scroll moves the reading position")
            H.check(mapper.same_position(sync.local_position, after), "PosUpdate captures the scroll position")
            H.equal(sync.dirty, true, "scrolling is unsynced reading")
            return after.fraction * 100
        end)
        local uploads_before = #uploads()
        H.broadcast("Suspend")
        H.broadcast("Resume")
        local entry = H.wait_until("upload of the scroll position", function()
            local list = uploads()
            return #list > uploads_before and list[#list]
        end, 30)
        H.check(math.abs(cloud_percent(entry) - scrolled_percent) < 0.5,
            "uploaded the scroll position", describe(entry))
        H.wait_until("scroll position accepted", function()
            local sync = H.plugin().progress_sync
            return not sync.dirty and sync.uploading == nil
        end, 15)
        H.call(function() H.reader().view:onSetViewMode("page") end)
        H.close_dialogs()
    end)

    H.step("(c) cloud moved ahead elsewhere: stale pending position is never sent", function()
        local uploads_before = #uploads()
        turn_page_forward()
        local expected_local = H.call(function() return H.plugin().progress_sync:capture_local() end)
        H.check(expected_local.fraction * 100 < 91.7, "local reading remains behind the new cloud position")
        set_cloud(6, 900) -- 91.7 %: someone read further on another device
        control_entries = control_entries + 1
        close_to_file_manager()
        local stale = H.call(function()
            return H.runtime().settings:get_book(BOOK_ID).pending_upload_position
        end)
        H.check(type(stale) == "table" and stale.chapter_uid == expected_local.chapter_uid
                and stale.chapter_offset == expected_local.chapter_offset,
            "close queued the (now stale) local position", tostring(stale and stale.chapter_uid))
        H.call(function() H.plugin():openFile(book_path) end)
        wait_reader_ready()
        H.wait_until("conflict dialog for the newer cloud", dialog_shown, 20)
        H.shot("07-08-cloud-ahead-again")
        -- Back key: no answer.
        H.call(function()
            UIManager:sendEvent(Event:new("Close"))
        end)
        H.wait_until("dialog dismissed by Back", function() return not dialog_shown() end, 10)
        wait_sync_settled("unverified")
        H.sleep(3)
        H.equal(#uploads(), uploads_before, "uploads after Back-dismissal with a stale pending position")
        close_to_file_manager()
        H.sleep(1)
        H.equal(#uploads(), uploads_before, "uploads after closing the unverified session")
    end)

    H.step("(c) cloud never moved backwards automatically", function()
        local list = history()
        local previous
        local controls = 0
        local uploaded = {}
        for index, entry in ipairs(list) do
            H.log("history", index, describe(entry))
            if entry.source == "control" then
                controls = controls + 1
            else
                uploaded[tostring(entry.chapterUid) .. "+" .. tostring(entry.chapterOffset)] = true
            end
            if previous and entry.source == "upload" then
                H.check(cloud_percent(entry) + 0.05 >= cloud_percent(previous),
                    "automatic upload moved the cloud backwards", describe(previous), "->", describe(entry))
            end
            previous = entry
        end
        H.equal(controls, control_entries, "control entries in history")
        -- A progress upload opening a new server session posts enter + read
        -- to /web/book/read with the same position: count positions.
        local distinct = 0
        for _key in pairs(uploaded) do distinct = distinct + 1 end
        -- The immediate page turn, the later reading position, then scrolling.
        H.equal(distinct, 3, "distinct positions uploaded in the whole scenario")
        H.metric("history_entries", #list)
        local final = H.mock_state().progress[BOOK_ID]
        H.equal(tonumber(final.chapterUid), 6, "cloud keeps the newest (other-device) chapter")
    end)
end
