-- @title Download throughput, UI responsiveness and checkpoint resume benchmark
-- @timeout 1800
-- @no_coverage
-- Run through scripts/benchmark_downloader.py (synthetic 200/811 chapter book).
return function(H)
    local count = assert(tonumber(os.getenv("WEREAD_BENCH_CHAPTERS")))
    local UIManager = require("ui/uimanager")
    local Content = require("weread.lib.content")
    local time = require("ui/time")
    local d, book, chapters
    local heartbeat = { running = true, count = 0, max_gap = 0 }
    local input_polls, max_input_gap, last_input = 0, 0, nil
    local peak_rss, peak_lua, baseline_rss, baseline_lua
    local resume_started, resume_dispatch_ms
    local source_ms, source_count = 0, 0
    H.step("instrument real UI loop and load synthetic catalog", function()
        H.wait_until("plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            d = H.runtime().downloader
            local client = H.runtime().client
            book = client:get_book_info("900100")
            Content.ensure_reader_state(client, book)
            chapters = Content.fetch_catalog(client, book)
            H.equal(#chapters, count, "benchmark chapter count")
            collectgarbage("collect")
            baseline_rss, baseline_lua = H.rss_kb(), H.lua_kb()
            peak_rss, peak_lua = baseline_rss, baseline_lua
            local perf = d._perf
            d._perf = function(self, dl, stage, started, ...)
                if stage:match("^chapter_source") then
                    local ms = tonumber(time.now() - started) / 1000
                    source_ms, source_count = source_ms + ms, source_count + 1
                    if resume_started and not resume_dispatch_ms then
                        resume_dispatch_ms = H.now_ms() - resume_started - ms
                    end
                end
                return perf(self, dl, stage, started, ...)
            end
            local input = require("device").input
            local wait_event = input.waitEvent
            input.waitEvent = function(...)
                local now = H.now_ms()
                if last_input then max_input_gap = math.max(max_input_gap, now - last_input) end
                last_input, input_polls = now, input_polls + 1
                return wait_event(...)
            end
            local function tick()
                if not heartbeat.running then return end
                local now = H.now_ms()
                if heartbeat.last then heartbeat.max_gap = math.max(heartbeat.max_gap, now - heartbeat.last) end
                heartbeat.last, heartbeat.count = now, heartbeat.count + 1
                peak_rss = math.max(peak_rss, H.rss_kb())
                peak_lua = math.max(peak_lua, H.lua_kb())
                UIManager:scheduleIn(0.1, tick)
            end
            UIManager:scheduleIn(0.1, tick)
        end)
    end)

    local first, second = {}, {}
    local started, cancel_ms, first_dl, second_dl
    local function start(state)
        return H.call(function()
            return d:start(book, chapters, "full", {
                offer_read = false, silent_completion = true,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
        end)
    end
    H.step("download, cancel through the real dialog and preserve checkpoints", function()
        started = H.now_ms()
        H.check(start(first), "fresh download starts")
        first_dl = H.wait_until("download active", function() return d._active_job end, 10)
        H.wait_until("three quarters checkpointed", function()
            return (first_dl.completed_count or 0) >= math.floor(count * 0.75)
        end, 1400, 0.1)
        local cancel_started = H.now_ms()
        H.tap_exact(H.tr("Cancel download"))
        H.wait_until("cancellation completed", function() return first.done end, 10, 0.1)
        cancel_ms = H.now_ms() - cancel_started
        H.check(not first.ok and first.value == "cancelled", "real cancellation reports cancelled")
        H.wait_until("downloader idle", function() return not d._active_job end, 10)
        H.equal(#first_dl.failed, 0, "cancel does not mark a chapter failed")
        H.metric("checkpointed_before_cancel", first_dl.completed_count)
        H.close_dialogs()
    end)
    H.step("resume the checkpointed book and verify the complete EPUB", function()
        resume_started = H.now_ms()
        H.check(start(second), "resume starts")
        second_dl = H.wait_until("resumed download active", function() return d._active_job end, 10)
        H.wait_until("resumed download complete", function() return second.done end, 1400, 0.1)
        local total_ms = H.now_ms() - started
        local resume_ms = H.now_ms() - resume_started
        H.check(second.ok, "resumed download succeeds", tostring(second.value))
        H.equal(second_dl.completed_count, count, "every chapter checkpointed")
        H.equal(#second_dl.failed, 0, "no download failures")
        local archived = H.call(function()
            local archive = require("ffi/archiver").Reader:new()
            assert(archive:open(second.value))
            local n = 0
            for entry in archive:iterate() do
                if entry.path:match("^OEBPS/text/chapter%-%d+%.xhtml$") then n = n + 1 end
            end
            archive:close()
            return n
        end)
        H.equal(archived, count, "complete EPUB chapter count")
        heartbeat.running = false
        H.metric("chapters", count)
        H.metric("total_ms", total_ms)
        H.metric("resume_ms", resume_ms)
        H.metric("resume_chapter_dispatch_ms", math.floor(resume_dispatch_ms + 0.5))
        H.metric("cancel_ms", cancel_ms)
        H.metric("source_ms", math.floor(source_ms + 0.5))
        H.metric("source_attempts", source_count)
        H.metric("rss_baseline_kb", baseline_rss)
        H.metric("rss_peak_kb", peak_rss)
        H.metric("rss_growth_kb", peak_rss - baseline_rss)
        H.metric("lua_peak_kb", math.floor(peak_lua + 0.5))
        H.metric("lua_growth_kb", math.floor(peak_lua - baseline_lua + 0.5))
        H.metric("heartbeat_count", heartbeat.count)
        H.metric("heartbeat_max_gap_ms", heartbeat.max_gap)
        H.metric("input_polls", input_polls)
        H.metric("input_max_gap_ms", max_input_gap)
        H.check(cancel_ms < 1500, "cancellation stays responsive", tostring(cancel_ms))
        H.check(heartbeat.max_gap < 1500, "UI heartbeat stays responsive", tostring(heartbeat.max_gap))
        H.check(peak_rss - baseline_rss < 40 * 1024, "parent RSS growth stays bounded")
    end)
end
