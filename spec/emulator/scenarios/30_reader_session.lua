-- @title Download jobs reuse accepted reader state and refresh after rejection or restart
-- @timeout 150
-- @no_coverage Real HTTP request counts, fork lifecycle and UI heartbeat.
-- Three synthetic chapters only; no real account or whole-book benchmark.
return function(H)
    local UIManager = require("ui/uimanager")
    local Content = require("weread.lib.content")
    local Protocol = require("weread.lib.protocol")
    local Budget = require("weread.lib.fork_budget")
    local plugin, book, chapters, phase
    local source, run, retry
    local running, last, gap = true, H.now_ms(), 0
    local function beat()
        local now = H.now_ms()
        gap, last = math.max(gap, now - last), now
        if running then UIManager:scheduleIn(0.05, beat) end
    end
    local function count(prefix)
        local total = 0
        for path, value in pairs(H.mock_state().started_counts) do
            if path:sub(1, #prefix) == prefix then total = total + value end
        end
        return total
    end
    local function chapter_counts()
        local counts, events = {}, H.mock_requests()
        H.check(#events < 500, "bounded scenario retains the entire mock request log")
        for _, event in ipairs(events) do
            if event.path == "/web/book/chapter/e_0" and event.encoded_chapter then
                counts[event.encoded_chapter] = (counts[event.encoded_chapter] or 0) + 1
            end
        end
        return counts
    end
    local function reset_fault()
        H.mock_control({ match = "", delay = 0, times = 0, drop = false, empty_chapter = false })
    end
    local function entries(path)
        return H.call(function()
            local archive = require("ffi/archiver").Reader:new()
            assert(archive:open(path))
            local names, values = {}, {}
            for entry in archive:iterate() do
                if entry.mode == "file" then names[#names + 1] = entry.path end
            end
            for _, name in ipairs(names) do
                local bytes = assert(archive:extractToMemory(name))
                if name == "OEBPS/content.opf" then
                    local replacements
                    bytes, replacements = bytes:gsub('(<meta property="dcterms:modified">)[^<]+(</meta>)',
                        "%1BUILD-TIME%2")
                    H.equal(replacements, 1, "only publication time is normalized")
                end
                values[name] = bytes
            end
            archive:close()
            return values
        end)
    end
    local function start(name, size, force_fresh, fault, suffix)
        phase = { name = name, sources = {}, retries = {}, force_fresh = force_fresh, fault = fault,
            readers_before = count("/web/reader/"), shards_before = count("/web/book/chapter/e_0"),
            started = H.now_ms() }
        H.call(function()
            local selected = {}
            for index = 1, size do selected[index] = chapters[index] end
            H.check(plugin.downloader:start(book, selected, suffix or "session-probe", {
                silent_completion = true, offer_read = false, include_annotations = false,
                on_complete = function(ok, value) phase.result = { ok = ok, value = value } end,
            }), "real Downloader accepts " .. name)
            phase.job = plugin.downloader._active_job
            H.equal(phase.job.reader_session_ready, nil, "new job begins without an accepted session")
            H.equal(book.reader_session_ready, nil, "session readiness is not a book property")
        end)
        return phase
    end
    local function wait_done(current)
        H.wait_until(current.name .. " completion", function() return current.result end, 45)
        H.wait_until("download child reaped", function()
            return not plugin.downloader._active_job and Budget.available()
        end, 10)
        current.readers = count("/web/reader/") - current.readers_before
        current.shards = count("/web/book/chapter/e_0") - current.shards_before
        H.metric(current.name .. "_reader_requests", current.readers)
        H.metric(current.name .. "_ms", H.now_ms() - current.started)
    end
    local function success(current)
        wait_done(current)
        H.check(current.result.ok, current.name .. " succeeds", tostring(current.result.value))
        H.equal(#current.job.failed, 0, "no failed chapter")
        local final = current.job.chapters[current.job.total]
        H.equal(current.job.book.chapter_uid, final.chapterUid, "parent accepted the final chapter UID")
        H.equal(current.job.book.chapter_idx, final.chapterIdx, "parent accepted the final chapter index")
    end
    local ok, err = xpcall(function()
        H.step("prepare bounded real HTTP jobs and observe accepted results", function()
            plugin = H.wait_until("plugin attached", H.plugin, 20)
            H.call(function()
                book = plugin.client:get_book_info("900001")
                Content.ensure_reader_state(plugin.client, book)
                chapters = Content.fetch_catalog(plugin.client, book)
                local cache = plugin.settings:get("cache", {})
                cache.download_book_images = false
                plugin.settings:set("cache", cache)
                source, run, retry = Content.fetch_single_chapter_source,
                    plugin.downloader._runInterruptible, plugin.downloader._retryChapterSource
                Content.fetch_single_chapter_source = function(client, settings, current_book, chapter, state, options)
                    if phase and phase.force_fresh then options = nil end
                    return source(client, settings, current_book, chapter, state, options)
                end
                plugin.downloader._runInterruptible = function(self, job, task)
                    local was_ready = job.reader_session_ready == true
                    if phase and job.index == 2 and was_ready and phase.fault and not phase.injected then
                        phase.injected = true
                        H.mock_control({ match = "/web/book/chapter/e_0", times = 1,
                            empty_chapter = phase.fault == "empty", drop = phase.fault == "transport" })
                    end
                    local value = run(self, job, task)
                    if phase and type(value) == "table" and type(value.xhtml) == "string" then
                        H.equal(value.book.reader_url,
                            Protocol.reader_url(book.book_id or book.bookId, job.chapters[job.index].chapterUid),
                            "reused reader URL follows the current chapter")
                        H.equal(value.book.chapter_uid, job.chapters[job.index].chapterUid,
                            "returned reader chapter UID follows its URL")
                        H.equal(value.book.chapter_idx, job.chapters[job.index].chapterIdx,
                            "returned reader chapter index follows its URL")
                        phase.sources[job.index] = { xhtml = value.xhtml, was_ready = was_ready }
                    end
                    return value
                end
                plugin.downloader._retryChapterSource = function(self, job, reason)
                    phase.retries[#phase.retries + 1] = {
                        readers = count("/web/reader/") - phase.readers_before,
                        shards = count("/web/book/chapter/e_0") - phase.shards_before,
                    }
                    local value = retry(self, job, reason)
                    H.equal(job.reader_session_ready, nil, "outer retry discards the accepted session")
                    return value
                end
                beat()
            end)
        end)
        local fresh, reused, expected
        H.step("three chapters save two reader requests with identical EPUB bytes", function()
            fresh = start("fresh", 3, true)
            success(fresh)
            H.equal(fresh.readers, 4, "control initializes once and refreshes every chapter")
            expected = entries(fresh.result.value)
            reused = start("reused", 3, false)
            success(reused)
            H.equal(reused.readers, 2, "initialization and first chapter are fresh; later chapters reuse")
            H.check(not reused.sources[1].was_ready, "first source is fresh despite the book's cached state")
            for index = 2, 3 do
                H.check(reused.sources[index].was_ready, "later source has an accepted job session")
            end
            local actual = entries(reused.result.value)
            for name, bytes in pairs(expected) do H.equal(actual[name], bytes, "same EPUB entry " .. name) end
            for name in pairs(actual) do H.check(expected[name] ~= nil, "no unexpected EPUB entry " .. name) end
            for index = 1, 3 do
                H.equal(reused.sources[index].xhtml, fresh.sources[index].xhtml, "identical decoded chapter")
            end
        end)
        H.step("explicit cached-context rejection refreshes internally once", function()
            local rejected = start("rejected", 2, false, "empty")
            success(rejected)
            H.equal(rejected.readers, 3, "initialization, first chapter and one rejection fallback refresh")
            H.equal(rejected.shards, 3, "rejected cached shard is fetched once again")
            H.equal(#rejected.retries, 0, "successful context fallback never invokes outer retries")
            H.equal(rejected.sources[2].xhtml, fresh.sources[2].xhtml, "fallback preserves decoded content")
            reset_fault()
        end)
        H.step("transport errors retain the existing outer retry policy", function()
            local transport = start("transport", 2, false, "transport")
            success(transport)
            H.equal(#transport.retries, 1, "transport failure reaches the original outer retry")
            H.equal(transport.retries[1].readers, 2, "transport failure adds no internal reader refresh")
            H.equal(transport.retries[1].shards, 2, "transport failure adds no internal shard retry")
            H.equal(transport.readers, 3, "outer retry uses a fresh reader session")
            H.equal(transport.shards, 3, "one original retry fetches the failed source")
            H.check(not transport.sources[2].was_ready, "retry cannot reuse the failed session")
            H.equal(transport.sources[2].xhtml, fresh.sources[2].xhtml, "retried content is identical")
            reset_fault()
        end)
        H.step("cancelled full jobs resume checkpoints with a fresh session", function()
            H.mock_control({ match = "/web/book/chapter/", delay = 0.25, times = 0 })
            local interrupted = start("interrupted", 3, false, nil, "full")
            H.wait_until("first chapter checkpoint", function()
                return interrupted.job.completed_count >= 1
            end, 20, 0.03)
            H.tap_exact(H.tr("Cancel download"), 5)
            wait_done(interrupted)
            H.check(not interrupted.result.ok, "cancelled full job reports failure")
            H.check(interrupted.job.completed_count >= 1 and interrupted.job.completed_count < 3,
                "a partial full-book checkpoint survives")
            H.check(H.call(function()
                return require("libs/libkoreader-lfs").attributes(interrupted.job.workspace.path, "mode") == "directory"
            end), "cancelled workspace remains resumable")
            reset_fault()
            H.close_dialogs()
            local before = chapter_counts()
            local resumed = start("resumed", 3, false, nil, "full")
            success(resumed)
            H.equal(resumed.readers, 2, "resumed job initializes and refreshes its first pending chapter")
            local after = chapter_counts()
            local first = true
            for index = 1, 3 do
                local uid = Protocol.e(chapters[index].chapterUid)
                if interrupted.job.completed[index] then
                    H.equal(after[uid], before[uid], "completed checkpoint is not downloaded again")
                else
                    H.check((after[uid] or 0) > (before[uid] or 0), "pending chapter is fetched on resume")
                    H.equal(resumed.sources[index].xhtml, fresh.sources[index].xhtml, "resumed decoded chapter")
                    if first then
                        H.check(not resumed.sources[index].was_ready, "first pending source refreshes after restart")
                        first = false
                    end
                end
            end
            H.check(H.call(function()
                return require("libs/libkoreader-lfs").attributes(interrupted.job.workspace.path) == nil
            end), "successful resume cleans the checkpoint workspace")
        end)
        H.metric("reader_session_heartbeat_gap_ms", gap)
        H.check(gap < 800, "job reuse, retries and cancellation keep the UI responsive", tostring(gap))
    end, debug.traceback)
    running = false
    reset_fault()
    H.call(function()
        UIManager:unschedule(beat)
        if source then Content.fetch_single_chapter_source = source end
        if run then plugin.downloader._runInterruptible = run end
        if retry then plugin.downloader._retryChapterSource = retry end
    end)
    if not ok then error(err, 0) end
end
