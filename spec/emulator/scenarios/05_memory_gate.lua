-- @title Memory gate: wait for free memory, then pause and resume
-- @timeout 240
-- The downloader checks MemAvailable before every worker fork. A fake
-- /proc/meminfo (the downloader's injectable read_meminfo) drives it:
-- (a) memory is low at the start and recovers while waiting: the progress
--     dialog shows the "Waiting for free memory" stage and the book completes;
-- (b) memory drops mid-book and never recovers (compressed wait schedule):
--     the resumable job pauses with the low-memory message, keeps its
--     checkpoint, fails no chapter and releases the standby guard; with
--     memory back, "download full book" again resumes to a complete EPUB.
local WAIT_BOOK_ID = "900001"
local PAUSE_BOOK_ID = "900002"
local PLENTY_KB = 4 * 1024 * 1024
local LOW_KB = 20 * 1024

return function(H)
    local Content = require("weread.lib.content")
    local Downloader = require("weread.lib.downloader")
    local WeRead = require("weread.lib.protocol")

    local function downloader() return H.runtime().downloader end

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

    -- e_0 fetches (one per chapter source attempt) by encoded chapter uid,
    -- counted after request number `from`; also returns the new mark.
    local function chapter_fetches(from)
        local counts, total = {}, 0
        local all = requests()
        for i = (from or 0) + 1, #all do
            local event = all[i]
            if event.path == "/web/book/chapter/e_0" and event.encoded_chapter then
                counts[event.encoded_chapter] = (counts[event.encoded_chapter] or 0) + 1
                total = total + 1
            end
        end
        return counts, #all, total
    end

    local function load_book(book_id)
        return H.call(function()
            local client = H.runtime().client
            local book = client:get_book_info(book_id)
            Content.ensure_reader_state(client, book)
            return book, Content.fetch_catalog(client, book)
        end)
    end

    local function start_full(book, chapters)
        local state = {}
        local started = H.call(function()
            return downloader():start(book, chapters, "full", {
                offer_read = false,
                silent_completion = true,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
        end)
        H.check(started, "download started")
        state.dl = H.wait_until("download job active", function()
            return downloader()._active_job or state.done
        end, 10)
        return state
    end

    local function check_epub(path, chapters)
        local names = H.call(function()
            local archive = require("ffi/archiver").Reader:new()
            assert(archive:open(path), "cannot open EPUB " .. tostring(path))
            local out = {}
            for entry in archive:iterate() do
                if entry.mode == "file" then out[#out + 1] = entry.path end
            end
            archive:close()
            return out
        end)
        H.equal(names[1], "mimetype", "EPUB starts with mimetype")
        local texts = 0
        for _i, name in ipairs(names) do
            if name:match("^OEBPS/text/.+%.xhtml$") and not name:match("cover%.xhtml$") then texts = texts + 1 end
        end
        H.equal(texts, #chapters, "chapter documents in EPUB")
    end

    local function standby_released()
        return H.call(function()
            return (downloader()._standby_ref or 0) == 0 and require("pluginshare").pause_auto_suspend ~= true
        end)
    end

    -- Fake /proc/meminfo; mem.kb is flipped by the scenario.
    local mem = { kb = PLENTY_KB, reads = 0 }
    H.step("inject fake meminfo", function()
        H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            downloader().read_meminfo = function()
                mem.reads = mem.reads + 1
                return string.format("MemTotal: %d kB\nMemFree: %d kB\nMemAvailable: %d kB\n",
                    PLENTY_KB, mem.kb, mem.kb)
            end
        end)
        local ok, available, required = H.call(function() return downloader().memory_gate() end)
        H.check(ok and available == PLENTY_KB, "gate passes with plenty of memory", tostring(available))
        H.metric("fork_required_kb", required)
        mem.kb = LOW_KB
        ok = H.call(function() return downloader().memory_gate() end)
        H.check(not ok, "gate refuses low memory")
        mem.kb = PLENTY_KB
    end)

    local waiting_prefix = H.tr("Waiting for free memory... %1 MB free, %2 MB needed"):match("^(.-)%%1")
    H.check(waiting_prefix and #waiting_prefix > 0, "waiting stage text")

    H.step("(a) wait for memory, then complete", function()
        H.patch_upvalue_table(Downloader._waitForMemory, "MEMORY_WAIT_SCHEDULE", { 1, 1, 1, 1, 1, 1, 1, 1 })
        local book, chapters = load_book(WAIT_BOOK_ID)
        mem.kb = LOW_KB
        local before_mark = select(2, chapter_fetches())
        local state = start_full(book, chapters)
        local waited_at = H.now_ms()
        H.wait_text(waiting_prefix, 15)
        local title = H.call(function() return state.dl.stage_title end)
        H.check(title:find(waiting_prefix, 1, true) and title:find("20", 1, true),
            "waiting stage names the free memory", title)
        H.sleep(1.5)
        H.check(not state.done, "download waits instead of failing")
        local forks = select(3, chapter_fetches(before_mark))
        H.equal(forks, 0, "no chapter fetched while memory is low")
        H.shot("a_waiting_for_memory")
        mem.kb = PLENTY_KB
        local recovered_at = H.now_ms()
        H.metric("a_low_memory_wait_ms", recovered_at - waited_at)
        H.wait_until("download completed after memory recovered", function() return state.done end, 60)
        H.check(state.ok, "download succeeded", tostring(state.value))
        H.metric("a_download_after_recovery_ms", H.now_ms() - recovered_at)
        H.equal(#state.dl.failed, 0, "no chapter failed")
        check_epub(state.value, chapters)
        H.check(standby_released(), "standby guard released")
    end)

    local pause_book, pause_chapters, paused_dl, pause_mark
    H.step("(b) memory never recovers: pause with checkpoint", function()
        H.patch_upvalue_table(Downloader._waitForMemory, "MEMORY_WAIT_SCHEDULE", { 0.3, 0.3 })
        pause_book, pause_chapters = load_book(PAUSE_BOOK_ID)
        mem.kb = PLENTY_KB
        -- ~1.2 s per chapter: room to drop the memory after two chapters.
        H.mock_control({ match = "/web/book/chapter/", delay = 0.3, times = 0 })
        local state = start_full(pause_book, pause_chapters)
        paused_dl = state.dl
        H.wait_until("two chapters checkpointed", function()
            return (paused_dl.completed_count or 0) >= 2
        end, 60, 0.1)
        local low_mark = select(2, chapter_fetches())
        mem.kb = LOW_KB
        local low_at = H.now_ms()
        H.wait_until("download paused for low memory", function() return state.done end, 30)
        H.metric("b_pause_after_ms", H.now_ms() - low_at)
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.check(not state.ok, "paused job reports no success")
        H.equal(state.value, "low_memory", "completion reason")
        local paused_line = H.tr("Download paused: not enough free memory.\n\nCompleted chapters were kept. Close the open book or restart KOReader, then choose Download full book again to continue."):match("^[^\n]+")
        H.wait_text(paused_line, 10)
        H.sleep(0.3)
        H.shot("b_paused_low_memory")
        local forks_after_low = select(3, chapter_fetches(low_mark))
        H.check(forks_after_low <= 1, "at most the in-flight chapter after memory dropped", tostring(forks_after_low))
        H.equal(#paused_dl.failed, 0, "no chapter marked failed")
        local completed = paused_dl.completed_count
        H.check(completed >= 2 and completed < #pause_chapters, "partial checkpoint", tostring(completed))
        H.metric("b_completed_before_pause", completed)
        local on_disk = H.call(function()
            local n = 0
            for _k in pairs(Content.full_download_completed_chapters(paused_dl.workspace, pause_chapters)) do n = n + 1 end
            return n
        end)
        H.equal(on_disk, completed, "checkpoints on disk")
        H.check(standby_released(), "standby guard released while paused")
        H.check(H.call(function() return downloader()._active_job == nil end), "no active job while paused")
        pause_mark = select(2, chapter_fetches())
        H.close_dialogs()
    end)

    H.step("(b) memory back: resume to completion", function()
        mem.kb = PLENTY_KB
        local state = start_full(pause_book, pause_chapters)
        H.wait_until("resumed download finished", function() return state.done end, 90)
        H.check(state.ok, "resumed download succeeded", tostring(state.value))
        local after = chapter_fetches(pause_mark)
        for index, chapter in ipairs(pause_chapters) do
            local encoded = WeRead.e(chapter.chapterUid)
            if paused_dl.completed[index] then
                H.equal(after[encoded] or 0, 0, "checkpointed chapter " .. index .. " fetched again")
            else
                H.check((after[encoded] or 0) >= 1, "pending chapter fetched on resume", tostring(index))
            end
        end
        H.equal(#state.dl.failed, 0, "no chapter failed after resume")
        check_epub(state.value, pause_chapters)
        H.check(standby_released(), "standby guard released after completion")
        H.metric("meminfo_reads", mem.reads)
        H.shot("b_resumed_done")
    end)
end
