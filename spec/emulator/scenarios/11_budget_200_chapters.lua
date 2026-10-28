-- @title Budget: 200-chapter full-book download (memory and time)
-- @timeout 600
-- @no_coverage
-- Downloads the hidden 200-chapter mock book 900100 as one resumable full
-- EPUB through the real Downloader (one worker fork per chapter) and records
-- RSS / Lua heap (baseline, sampled peak, after), total time and per-chapter
-- time. Budgets catch leaks that grow with the chapter count and per-chapter
-- slowdowns (e.g. O(n^2) checkpoint scans) long before a Kindle runs out of
-- memory on a long novel. Budgets keep roughly 2x headroom over local runs.
local BOOK_ID = "900100"
local CHAPTERS = 200
local WINDOW = 20
-- Budgets. Local reference run (x86-64, SDL dummy, official v2026.07.1):
-- total 114 s (~0.45 s per chapter fork), packaging 0.89 s (footnote
-- rescan + transform in one 160 ms finalize batch, EPUB save 0.49 s; it was
-- 26.4 s with a fixed 0.1 s wait per chapter), parent RSS peak +12 MB, Lua
-- heap after +0.9 MB, last/first 20 chapters 1.0x.
local MAX_RSS_GROWTH_KB = 40 * 1024 -- parent RSS, sampled peak over baseline
local MAX_LUA_GROWTH_KB = 8 * 1024 -- Lua heap after the job (collected) over baseline
local MAX_LATE_TO_EARLY_RATIO = 3.0 -- last 20 vs first 20 chapters
local MAX_PACKAGING_S = 2 -- last chapter checkpointed -> EPUB saved
local MAX_TOTAL_S = 360
-- One finalize UI step (budget 200 ms, Downloader.FINALIZE_BATCH_BUDGET_MS)
-- plus one chapter and CI noise.
local MAX_FINALIZE_BATCH_MS = 1000

return function(H)
    local Content = require("weread.lib.content")
    local time = require("ui/time")

    local function downloader() return H.runtime().downloader end

    local function avg(list, first, last)
        local sum, n = 0, 0
        for i = first, last do
            if list[i] then sum, n = sum + list[i], n + 1 end
        end
        return n > 0 and sum / n or nil
    end

    local function round(value) return math.floor(value + 0.5) end

    local book, chapters
    H.step("load 200-chapter catalog", function()
        H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        book, chapters = H.call(function()
            local client = H.runtime().client
            local info = client:get_book_info(BOOK_ID)
            Content.ensure_reader_state(client, info)
            return info, Content.fetch_catalog(client, info)
        end)
        H.equal(#chapters, CHAPTERS, "catalog chapters")
    end)

    -- Per-chapter source time from the downloader's own download_perf
    -- measurement (worker fork + requests), keyed by chapter index.
    local chapter_ms, stage_ms = {}, {}
    H.step("instrument download_perf", function()
        H.call(function()
            local d = downloader()
            local perf = d._perf
            d._perf = function(self, dl, stage, started, ...)
                local ms = tonumber(time.now() - started) / 1000
                if stage:match("^chapter_source") then
                    chapter_ms[dl.index] = ms
                else
                    stage_ms[stage] = (stage_ms[stage] or 0) + ms
                end
                return perf(self, dl, stage, started, ...)
            end
        end)
    end)

    local baseline_rss, baseline_lua
    -- Finalize pipeline (footnote rescan/transform before packaging) runs in
    -- time-budgeted batches. Every continuation must come after the UI loop
    -- polled input (so Cancel gets through between batches): count real
    -- Input:waitEvent calls and check one happened before each continuation.
    local input_polls = 0
    local finalize = { yields = 0, polled = 0, step_ms = {} }
    H.step("instrument finalize batches", function()
        H.call(function()
            local Input = require("device").input
            local wait_event = Input.waitEvent
            Input.waitEvent = function(...)
                input_polls = input_polls + 1
                return wait_event(...)
            end
            local d = downloader()
            local yield = d._yieldFinalize
            d._yieldFinalize = function(self, dl, step_fn)
                local polls_at_yield = input_polls
                return yield(self, dl, function()
                    finalize.yields = finalize.yields + 1
                    if input_polls > polls_at_yield then finalize.polled = finalize.polled + 1 end
                    local started = time.now()
                    step_fn()
                    finalize.step_ms[#finalize.step_ms + 1] = tonumber(time.now() - started) / 1000
                end)
            end
        end)
    end)

    H.step("baseline", function()
        H.call(function()
            collectgarbage("collect")
            collectgarbage("collect")
        end)
        H.sleep(0.5)
        baseline_rss, baseline_lua = H.rss_kb(), H.lua_kb()
        H.check(baseline_rss, "VmRSS readable")
        H.metric("rss_baseline_kb", baseline_rss)
        H.metric("lua_baseline_kb", round(baseline_lua))
    end)

    local state = {}
    local reached = {} -- completed chapter count -> scenario time (ms)
    local peak_rss, peak_lua = baseline_rss, baseline_lua
    local t0
    H.step("download 200 chapters", function()
        t0 = H.now_ms()
        local started = H.call(function()
            return downloader():start(book, chapters, "full", {
                offer_read = false,
                silent_completion = true,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
        end)
        H.check(started, "download started")
        local dl = H.wait_until("download job active", function() return downloader()._active_job end, 15)
        reached[0] = t0
        local shot_mid = false
        while not state.done do
            local rss, lua = H.rss_kb(), H.lua_kb()
            if rss and rss > peak_rss then peak_rss = rss end
            if lua > peak_lua then peak_lua = lua end
            local count = dl.completed_count or 0
            for n = 1, count do
                if not reached[n] then reached[n] = H.now_ms() end
            end
            if not shot_mid and count >= CHAPTERS / 2 then
                shot_mid = true
                H.shot("halfway")
            end
            H.check(H.now_ms() - t0 < MAX_TOTAL_S * 1000, "download within the total time budget",
                tostring(count) .. "/" .. CHAPTERS .. " chapters done")
            H.sleep(0.25)
        end
        H.check(state.ok, "download succeeded", tostring(state.value))
        H.equal(#dl.failed, 0, "no chapter failed")
        H.equal(dl.completed_count, CHAPTERS, "all chapters checkpointed")
    end)

    H.step("budgets", function()
        local total_ms = H.now_ms() - t0
        H.call(function()
            collectgarbage("collect")
            collectgarbage("collect")
        end)
        H.sleep(0.5)
        local after_rss, after_lua = H.rss_kb(), H.lua_kb()
        H.metric("total_ms", total_ms)
        H.metric("rss_peak_kb", peak_rss)
        H.metric("rss_after_kb", after_rss)
        H.metric("rss_peak_growth_kb", peak_rss - baseline_rss)
        H.metric("rss_after_growth_kb", after_rss - baseline_rss)
        H.metric("lua_peak_kb", round(peak_lua))
        H.metric("lua_after_kb", round(after_lua))
        H.metric("lua_after_growth_kb", round(after_lua - baseline_lua))
        for stage, ms in pairs(stage_ms) do H.metric("stage_" .. stage .. "_ms", round(ms)) end

        local measured = 0
        for i = 1, CHAPTERS do if chapter_ms[i] then measured = measured + 1 end end
        H.equal(measured, CHAPTERS, "download_perf chapter timings")
        local first_ms = avg(chapter_ms, 1, WINDOW)
        local last_ms = avg(chapter_ms, CHAPTERS - WINDOW + 1, CHAPTERS)
        H.metric("chapter_ms_first20", round(first_ms))
        H.metric("chapter_ms_last20", round(last_ms))
        H.metric("chapter_ms_all", round(avg(chapter_ms, 1, CHAPTERS)))
        -- Wall clock per chapter as seen by the user (includes the UI-side
        -- checkpoint write and step scheduling between forks).
        H.check(reached[WINDOW] and reached[CHAPTERS - WINDOW] and reached[CHAPTERS], "progress sampled")
        local wall_first = (reached[WINDOW] - reached[0]) / WINDOW
        local wall_last = (reached[CHAPTERS] - reached[CHAPTERS - WINDOW]) / WINDOW
        H.metric("wall_ms_per_chapter_first20", round(wall_first))
        H.metric("wall_ms_per_chapter_last20", round(wall_last))
        local packaging_ms = total_ms - (reached[CHAPTERS] - t0)
        H.metric("packaging_ms", packaging_ms)

        H.check(peak_rss - baseline_rss < MAX_RSS_GROWTH_KB, "peak RSS growth within budget",
            tostring(peak_rss - baseline_rss) .. " kB")
        H.check(after_lua - baseline_lua < MAX_LUA_GROWTH_KB, "Lua heap growth within budget",
            tostring(round(after_lua - baseline_lua)) .. " kB")
        H.check(last_ms <= first_ms * MAX_LATE_TO_EARLY_RATIO, "late chapters not slower than 3x early ones",
            string.format("%.0f ms vs %.0f ms", last_ms, first_ms))
        H.check(wall_last <= wall_first * MAX_LATE_TO_EARLY_RATIO, "late wall time per chapter within 3x",
            string.format("%.0f ms vs %.0f ms", wall_last, wall_first))
        H.check(packaging_ms < MAX_PACKAGING_S * 1000, "packaging time within budget", tostring(packaging_ms) .. " ms")
        -- The last continuation is the EPUB build (one step, may wait for the
        -- cover worker); the batches before it are budgeted.
        local max_batch_ms = 0
        for i = 1, #finalize.step_ms - 1 do max_batch_ms = math.max(max_batch_ms, finalize.step_ms[i]) end
        H.metric("finalize_ui_yields", finalize.yields)
        H.metric("finalize_input_polled", finalize.polled)
        H.metric("finalize_max_batch_ms", round(max_batch_ms))
        H.check(finalize.yields >= 2, "finalize yielded to the UI loop", tostring(finalize.yields))
        H.equal(finalize.polled, finalize.yields, "input polled before every finalize continuation")
        H.check(max_batch_ms < MAX_FINALIZE_BATCH_MS, "finalize batch within its time budget",
            string.format("%.0f ms", max_batch_ms))
        H.check(total_ms < MAX_TOTAL_S * 1000, "total time within budget", tostring(total_ms) .. " ms")
    end)

    H.step("200-chapter EPUB", function()
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
        H.equal(names[1], "mimetype", "EPUB starts with mimetype")
        local texts = 0
        for _i, name in ipairs(names) do
            if name:match("^OEBPS/text/.+%.xhtml$") and not name:match("cover%.xhtml$") then texts = texts + 1 end
        end
        H.equal(texts, CHAPTERS, "chapter documents in EPUB")
        local size = H.call(function() return require("libs/libkoreader-lfs").attributes(state.value, "size") end)
        H.metric("epub_kb", round(size / 1024))
        H.close_dialogs()
        H.shot("done")
    end)
end
