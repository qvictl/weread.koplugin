-- @title Network loss pauses a full-book download; restart resumes
-- @timeout 240
-- The network link disappears in the middle of a resumable full-book
-- download (NetworkMgr reports no connection, as on a Kindle whose Wi-Fi
-- dropped). The downloader must stop forking workers after a couple of
-- attempts, pause with the "network seems to be unavailable" message and
-- keep its checkpoint; starting again while offline is refused without any
-- request. With the link up but the server silent (requests time out), it
-- pauses the same way after two attempts. With the network back, the restart
-- reuses the completed chapters.
local BOOK_ID = "900001"

return function(H)
    local Content = require("weread.lib.content")
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

    -- e_0 fetches by encoded chapter uid after request number `from`;
    -- returns counts, the new mark and the number of e_0 fetches.
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

    local function start_full(book, chapters)
        local state = {}
        state.started = H.call(function()
            return downloader():start(book, chapters, "full", {
                offer_read = false,
                silent_completion = true,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
        end)
        return state
    end

    local function standby_released()
        return H.call(function()
            return (downloader()._standby_ref or 0) == 0 and require("pluginshare").pause_auto_suspend ~= true
        end)
    end

    -- NetworkMgr link state seen by the plugin; net.up is flipped by the
    -- scenario (the SDL emulator is always "connected").
    local net = { up = true, checks = 0 }
    local book, chapters
    H.step("setup", function()
        H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            local NetworkMgr = require("ui/network/manager")
            local is_connected, is_online = NetworkMgr.isConnected, NetworkMgr.isOnline
            NetworkMgr.isConnected = function(self, ...)
                net.checks = net.checks + 1
                if not net.up then return false end
                return is_connected(self, ...)
            end
            NetworkMgr.isOnline = function(self, ...)
                net.checks = net.checks + 1
                if not net.up then return false end
                return is_online(self, ...)
            end
        end)
        H.check(H.call(function() return H.plugin():isNetworkConnected() end), "plugin sees the link up")
        book, chapters = H.call(function()
            local client = H.runtime().client
            local info = client:get_book_info(BOOK_ID)
            Content.ensure_reader_state(client, info)
            return info, Content.fetch_catalog(client, info)
        end)
        H.equal(#chapters, 6, "catalog chapters")
    end)

    local first, offline_mark
    H.step("network drops mid-download: pause", function()
        -- ~1.2 s per chapter so the link can drop mid-book.
        H.mock_control({ match = "/web/book/chapter/", delay = 0.3, times = 0 })
        first = start_full(book, chapters)
        H.check(first.started, "download started")
        first.dl = H.wait_until("download job active", function() return downloader()._active_job end, 10)
        H.wait_until("two chapters checkpointed", function()
            return (first.dl.completed_count or 0) >= 2
        end, 60, 0.1)
        H.shot("downloading")
        local mark = select(2, chapter_fetches())
        net.up = false
        local checks_at_drop = net.checks
        local dropped_at = H.now_ms()
        H.check(not H.call(function() return H.plugin():isNetworkConnected() end), "plugin sees the link down")
        H.wait_until("download paused for the network", function() return first.done end, 30)
        H.metric("pause_after_ms", H.now_ms() - dropped_at)
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.check(not first.ok, "paused job reports no success")
        H.equal(first.value, "network_unavailable", "completion reason")
        local message = H.tr("Full-book download paused: the network seems to be unavailable.\n\nCompleted chapters were kept. Choose Download full book again to continue when the connection is back.\n\nLast error: %1")
        H.wait_text(message:match("^[^\n]+"), 10)
        H.check(H.has_text("network is not connected"), "last error names the missing link")
        H.sleep(0.3)
        H.shot("paused_network")
        local fetched = select(3, chapter_fetches(mark))
        H.check(fetched <= 1, "at most the in-flight chapter fetched after the drop", tostring(fetched))
        H.metric("link_checks_until_pause", net.checks - checks_at_drop)
        H.equal(#first.dl.failed, 0, "no chapter marked failed")
        local completed = first.dl.completed_count
        H.check(completed >= 2 and completed < #chapters, "partial checkpoint", tostring(completed))
        H.metric("completed_before_pause", completed)
        local on_disk = H.call(function()
            local n = 0
            for _k in pairs(Content.full_download_completed_chapters(first.dl.workspace, chapters)) do n = n + 1 end
            return n
        end)
        H.equal(on_disk, completed, "checkpoints on disk")
        H.check(standby_released(), "standby guard released while paused")
        offline_mark = select(2, chapter_fetches())
        H.close_dialogs()
    end)

    H.step("offline: no busy loop, restart refused", function()
        local before_requests = #requests()
        local before_checks = net.checks
        H.sleep(3)
        H.equal(#requests(), before_requests, "no request while paused offline")
        H.check(H.call(function() return downloader()._active_job == nil end), "no job running while offline")
        local idle_checks = net.checks - before_checks
        H.metric("idle_link_checks_3s", idle_checks)
        H.check(idle_checks <= 10, "no link-polling loop while paused", tostring(idle_checks))
        -- "Download full book" again while still offline.
        local retry = start_full(book, chapters)
        H.wait_until("offline restart reported", function() return retry.done end, 10)
        H.check(not retry.ok, "offline restart does not succeed")
        H.equal(retry.value, "offline", "offline restart reason")
        H.wait_text(H.tr("No network connection. Please connect Wi-Fi and try again."):match("^[^\n]+"), 10)
        H.shot("offline_restart_refused")
        H.equal(#requests(), before_requests, "offline restart sent no request")
        H.close_dialogs()
    end)

    H.step("link up, server silent: pause on transport timeouts", function()
        net.up = true
        -- Requests reach the mock but get no answer before the client's 15 s
        -- block timeout (a dead access point / captive network).
        H.mock_control({ match = "/web/book/chapter/", delay = 17, times = 0 })
        local mark = select(2, chapter_fetches())
        local started_at = H.now_ms()
        local state = start_full(book, chapters)
        H.check(state.started, "download restarted")
        state.dl = H.wait_until("download job active", function() return downloader()._active_job end, 10)
        H.wait_until("download paused after timeouts", function() return state.done end, 90, 0.5)
        H.metric("timeout_pause_after_ms", H.now_ms() - started_at)
        H.mock_control({ match = "", delay = 0, times = 0 })
        H.check(not state.ok, "paused job reports no success")
        H.equal(state.value, "network_unavailable", "timeouts count as a lost network")
        local message = H.tr("Full-book download paused: the network seems to be unavailable.\n\nCompleted chapters were kept. Choose Download full book again to continue when the connection is back.\n\nLast error: %1")
        H.wait_text(message:match("^[^\n]+"), 10)
        H.check(H.has_text("timeout"), "last error names the timeout")
        H.shot("paused_timeouts")
        -- The mock logs a request when it answers, i.e. after the delay.
        H.wait_until("both timed-out attempts logged", function()
            return select(3, chapter_fetches(mark)) >= 2
        end, 15, 0.5)
        H.sleep(1)
        local fetched = select(3, chapter_fetches(mark))
        H.equal(fetched, 2, "chapter attempts before pausing (TRANSPORT_FAILURES_BEFORE_PAUSE)")
        H.equal(#state.dl.failed, 0, "no chapter marked failed")
        H.check(standby_released(), "standby guard released while paused")
        offline_mark = select(2, chapter_fetches())
        H.close_dialogs()
    end)

    H.step("network back: resume to completion", function()
        net.up = true
        local state = start_full(book, chapters)
        H.check(state.started, "download restarted")
        H.wait_until("resumed download finished", function() return state.done end, 90)
        H.check(state.ok, "resumed download succeeded", tostring(state.value))
        local after = chapter_fetches(offline_mark)
        local fetched_now = 0
        for index, chapter in ipairs(chapters) do
            local encoded = WeRead.e(chapter.chapterUid)
            if first.dl.completed[index] then
                H.equal(after[encoded] or 0, 0, "checkpointed chapter " .. index .. " fetched again")
            else
                H.check((after[encoded] or 0) >= 1, "pending chapter fetched on resume", tostring(index))
                fetched_now = fetched_now + 1
            end
        end
        H.metric("chapters_fetched_on_resume", fetched_now)
        local names = H.call(function()
            local archive = require("ffi/archiver").Reader:new()
            assert(archive:open(state.value), "cannot open EPUB " .. tostring(state.value))
            local out = {}
            for entry in archive:iterate() do
                if entry.mode == "file" then out[#out + 1] = entry.path end
            end
            archive:close()
            return out
        end)
        local texts = 0
        for _i, name in ipairs(names) do
            if name:match("^OEBPS/text/.+%.xhtml$") and not name:match("cover%.xhtml$") then texts = texts + 1 end
        end
        H.equal(texts, #chapters, "chapter documents in EPUB")
        H.check(standby_released(), "standby guard released after completion")
        H.shot("resumed_done")
    end)
end
