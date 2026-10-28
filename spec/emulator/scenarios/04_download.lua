-- @title Chapter download and read, interrupted full-book download resumes
-- @timeout 240
-- Real UI paths: "download chapter and read" (confirm, worker fork, EPUB,
-- "Read now" opens the ReaderUI), then a full-book download of 900001 that
-- is cancelled through the progress dialog after >= 1 completed chapter and
-- started again. The restart must reuse the checkpointed chapters (the mock
-- request log shows no second fetch of them) and package all 6 chapters.
local BOOK_ID = "900001"

return function(H)
    local Content = require("weread.lib.content")
    local WeRead = require("weread.lib.protocol")
    local UIManager = require("ui/uimanager")

    local function downloader() return H.runtime().downloader end

    -- Taps the painted widget whose text is exactly needle (ConfirmBox
    -- messages often contain the button label as a substring).
    local function tap_exact(needle, timeout)
        return H.tap_exact(needle, timeout)
    end

    -- All requests the mock served so far (the evidence log is not capped).
    local function requests()
        local json = require("json")
        local out = {}
        local file = io.open(H.env.evidence .. "/requests.jsonl", "r")
        if not file then return out end
        for line in file:lines() do
            local ok, event = pcall(json.decode, line)
            if ok and type(event) == "table" then out[#out + 1] = event end
        end
        file:close()
        return out
    end

    -- e_0 fetches (one per chapter source attempt) by encoded chapter uid.
    local function chapter_fetches(from)
        local counts = {}
        local all = requests()
        for i = (from or 0) + 1, #all do
            local event = all[i]
            if event.path == "/web/book/chapter/e_0" and event.encoded_chapter then
                counts[event.encoded_chapter] = (counts[event.encoded_chapter] or 0) + 1
            end
        end
        return counts, #all
    end

    local function epub_entries(path)
        return H.call(function()
            local Archiver = require("ffi/archiver")
            local archive = Archiver.Reader:new()
            assert(archive:open(path), "cannot open EPUB " .. tostring(path))
            local names, data = {}, {}
            for entry in archive:iterate() do
                if entry.mode == "file" then names[#names + 1] = entry.path end
            end
            for _i, name in ipairs(names) do
                if name:match("%.xhtml$") or name:match("%.opf$") or name == "mimetype" then
                    data[name] = archive:extractToMemory(name)
                end
            end
            archive:close()
            return names, data
        end)
    end

    local function check_full_epub(path, chapters)
        local file = io.open(path, "rb")
        H.check(file, "full EPUB exists", path)
        local magic = file:read(4)
        file:close()
        H.equal(magic, "PK\3\4", "full EPUB is a ZIP")
        local names, data = epub_entries(path)
        H.equal(names[1], "mimetype", "mimetype is the first ZIP entry")
        H.equal(data.mimetype, "application/epub+zip", "EPUB mimetype")
        local texts = {}
        for _i, name in ipairs(names) do
            if name:match("^OEBPS/text/.+%.xhtml$") and not name:match("cover%.xhtml$") then
                texts[#texts + 1] = name
            end
        end
        H.equal(#texts, #chapters, "chapter documents in EPUB")
        local joined = {}
        for _i, name in ipairs(texts) do joined[#joined + 1] = data[name] or "" end
        joined = table.concat(joined, "\n")
        for _i, chapter in ipairs(chapters) do
            H.check(joined:find(chapter.title, 1, true), "chapter title in EPUB text", chapter.title)
        end
        return #names
    end

    -- The plugin's standby guard: reference counted in the downloader, and
    -- it pauses KOReader's AutoSuspend through PluginShare while held.
    -- (UIManager's own prevent counter also moves with AutoSuspend/Trapper,
    -- so it is logged, not asserted.)
    local function standby_state()
        return H.call(function()
            return downloader()._standby_ref or 0, require("pluginshare").pause_auto_suspend == true,
                UIManager._prevent_standby_count
        end)
    end
    local function standby_released()
        local ref, paused, count = standby_state()
        H.log("standby ref", ref, "auto-suspend paused", paused, "uimanager count", count)
        return ref == 0 and not paused
    end
    local function standby_held()
        local ref, paused = standby_state()
        return ref > 0 and paused
    end

    local book, chapters
    H.step("load catalog", function()
        H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        book, chapters = H.call(function()
            local client = H.runtime().client
            local info = client:get_book_info(BOOK_ID)
            Content.ensure_reader_state(client, info)
            return info, Content.fetch_catalog(client, info)
        end)
        H.equal(#chapters, 6, "catalog chapters")
        H.metric("chapters", #chapters)
    end)

    H.step("download chapter and read", function()
        local state = {}
        local t0 = H.now_ms()
        H.call(function()
            H.plugin():downloadChapterAndRead(book, chapters[1], function(path) state.path = path end)
        end)
        tap_exact(H.tr("Download"))
        H.wait_until("chapter EPUB downloaded", function() return state.path end, 60)
        H.metric("chapter_download_ms", H.now_ms() - t0)
        H.check(H.file_exists(state.path), "chapter EPUB on disk", state.path)
        local names = epub_entries(state.path)
        H.check(#names >= 5, "chapter EPUB has entries")
        H.wait_text(H.tr("Read now"))
        H.shot("chapter_downloaded")
        tap_exact(H.tr("Read now"))
        H.wait_until("ReaderUI opened the chapter", function()
            local reader = H.reader()
            return reader and reader.document and reader.document.file == state.path
        end, 30)
        local pages = H.call(function() return H.reader().document:getPageCount() end)
        H.check(pages >= 1, "chapter paginates", tostring(pages))
        H.metric("chapter_pages", pages)
        H.sleep(0.5)
        H.shot("chapter_reader")
        H.call(function() H.reader():onHome() end)
        H.wait_until("back in FileManager", function()
            return H.file_manager() and not H.reader() and H.plugin()
        end, 20)
        H.wait_until("downloader idle", function()
            local dl = downloader()
            return not dl._active_job and not dl._scheduled_start
        end, 20)
        H.close_dialogs()
    end)

    local first_dl, first_state, mark, fetched_before
    H.step("full download cancelled after a completed chapter", function()
        -- ~1.2 s per chapter (4 shards) leaves room to cancel mid-book.
        H.mock_control({ match = "/web/book/chapter/", delay = 0.3, times = 0 })
        -- The chapter download above already fetched chapter 1 once.
        local start_mark = select(2, chapter_fetches())
        first_state = {}
        H.call(function()
            H.plugin():confirmAndDownloadChapters(book, chapters, "full", {
                offer_read = false,
                silent_completion = true,
                on_complete = function(ok, value)
                    first_state.done, first_state.ok, first_state.value = true, ok, value
                end,
            })
        end)
        tap_exact(H.tr("Download"))
        first_dl = H.wait_until("full download job active", function()
            return downloader()._active_job
        end, 20)
        H.wait_until("one chapter checkpointed", function()
            return (first_dl.completed_count or 0) >= 1
        end, 60, 0.1)
        H.check(standby_held(), "standby guard held while downloading")
        H.shot("full_download_progress")
        tap_exact(H.tr("Cancel download"))
        H.wait_until("cancellation reported", function() return first_state.done end, 30)
        H.check(not first_state.ok, "cancelled download reports failure")
        H.equal(first_state.value, "cancelled", "completion reason")
        H.wait_text(H.tr("Download cancelled"), 5)
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.wait_until("downloader idle after cancel", function() return not downloader()._active_job end, 10)
        H.check(standby_released(), "standby guard released after cancel")
        local completed = first_dl.completed_count
        H.check(completed >= 1 and completed < #chapters, "partial checkpoint", tostring(completed))
        H.equal(#first_dl.failed, 0, "no chapter marked failed by the cancel")
        local on_disk = H.call(function()
            local map = Content.full_download_completed_chapters(first_dl.workspace, chapters)
            local n = 0
            for _k in pairs(map) do n = n + 1 end
            return n, map
        end)
        H.equal(on_disk, completed, "checkpoints on disk")
        H.check(H.call(function()
            return require("libs/libkoreader-lfs").attributes(first_dl.workspace.path, "mode") == "directory"
        end), "resume workspace kept", first_dl.workspace.path)
        H.metric("completed_before_cancel", completed)
        fetched_before, mark = chapter_fetches(start_mark)
        H.sleep(0.3)
        H.shot("cancelled")
        H.close_dialogs()
    end)

    H.step("restart resumes and completes", function()
        local state = {}
        local t0 = H.now_ms()
        H.call(function()
            H.plugin():confirmAndDownloadChapters(book, chapters, "full", {
                offer_read = false,
                silent_completion = true,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
        end)
        tap_exact(H.tr("Download"))
        H.wait_until("resumed download finished", function() return state.done end, 120)
        H.check(state.ok, "resumed download succeeded", tostring(state.value))
        H.metric("resume_download_ms", H.now_ms() - t0)
        local after = chapter_fetches(mark)
        local refetched, fetched_now = 0, 0
        for index, chapter in ipairs(chapters) do
            local encoded = WeRead.e(chapter.chapterUid)
            if first_dl.completed[index] then
                H.equal(after[encoded] or 0, 0, "completed chapter " .. index .. " fetched again")
                H.equal(fetched_before[encoded], 1, "completed chapter " .. index .. " fetched once before")
            else
                H.check((after[encoded] or 0) >= 1, "pending chapter fetched on resume", tostring(index))
                fetched_now = fetched_now + 1
            end
            refetched = refetched + (first_dl.completed[index] and (after[encoded] or 0) or 0)
        end
        H.metric("chapters_fetched_on_resume", fetched_now)
        H.metric("chapters_refetched", refetched)
        local entries = check_full_epub(state.value, chapters)
        H.metric("full_epub_entries", entries)
        H.check(H.call(function()
            return require("libs/libkoreader-lfs").attributes(first_dl.workspace.path, "mode") == nil
        end), "resume workspace removed after success")
        H.check(standby_released(), "standby guard released after completion")
        local record = H.call(function() return H.runtime().settings:get_book(BOOK_ID) end)
        H.equal(record and record.cached_full_book, state.value, "book record points at the full EPUB")
        H.sleep(0.3)
        H.shot("full_download_done")
    end)
end
