-- Finalize pipeline (footnote rescan + transform before the EPUB is built)
-- runs in time-budgeted batches instead of sleeping 0.1 s per chapter.
-- Regression: a 200-chapter book spent ~25 s of its ~26 s packaging time in
-- per-chapter UIManager:scheduleIn(0.1) waits (emulator scenario 11).
--
-- A fake UIManager records every scheduled step and its delay; an injected
-- clock advances by a fixed cost per scanned/transformed chapter, so batch
-- sizes are deterministic.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local queue = {}
package.preload["ui/uimanager"] = function()
    local UIManager = {}
    function UIManager:scheduleIn(delay, callback)
        queue[#queue + 1] = { delay = delay, fn = callback }
    end
    function UIManager:nextTick(callback) return self:scheduleIn(0, callback) end
    function UIManager:unschedule() end
    function UIManager:show() end
    function UIManager:preventStandby() end
    function UIManager:allowStandby() end
    return UIManager
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["logger"] = function()
    local noop = function() end
    return { info = noop, warn = noop, err = noop, dbg = noop }
end
-- ui/time stays frozen: batch budgets must use the injected clock.
package.preload["ui/time"] = function()
    return { now = function() return 0 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.protocol"] = function()
    return { normalize_cover_url = function(value) return value end }
end

-- Injected clock (ui/time units: microseconds) and per-chapter costs.
local now_us = 0
local cost = { load = 0, scan = 0, transform = 0 }
local function spend(ms) now_us = now_us + ms * 1000 end

local log = {} -- ordered events: "scan:<uid>", "transform:<uid>", "save:<uid>"
local load_error_uid
package.preload["weread.lib.content"] = function()
    return {
        reset_full_download_rendered_text = function() end,
        load_full_download_chapter = function(_workspace, chapter)
            spend(cost.load)
            local uid = tostring(chapter.chapterUid)
            if uid == load_error_uid then error("injected checkpoint read failure " .. uid, 0) end
            return "<p>" .. uid .. "</p>"
        end,
        save_full_download_rendered_chapter = function(_workspace, chapter, _index, body)
            log[#log + 1] = "save:" .. tostring(chapter.chapterUid) .. ":" .. body
        end,
        cleanup_download_workspace = function() end,
    }
end
package.preload["weread.lib.footnotes"] = function()
    return {
        FOOTNOTES_CSS = ".fn{}",
        scan_chapter = function(_body, chapter)
            spend(cost.scan)
            log[#log + 1] = "scan:" .. tostring(chapter.chapterUid)
            return { uid = chapter.chapterUid }
        end,
        build_book_index = function(scans, chapters)
            local n = 0
            for _k in pairs(scans) do n = n + 1 end
            return { scans = n, chapters = #chapters }
        end,
        transform_chapter = function(original, scan)
            spend(cost.transform)
            log[#log + 1] = "transform:" .. tostring(scan and scan.uid)
            return "T" .. tostring(original), { converted = 1 }
        end,
        validate = function() return true end,
        has_converted = function(stats) return (stats.converted or 0) > 0 end,
    }
end

local Downloader = require("weread.lib.downloader")
local BUDGET_MS = Downloader.FINALIZE_BATCH_BUDGET_MS
local YIELD_S = Downloader.FINALIZE_YIELD_S
expect(type(BUDGET_MS) == "number" and BUDGET_MS > 0 and BUDGET_MS <= 250,
    "finalize batch budget must be a small named constant")
expect(type(YIELD_S) == "number" and YIELD_S > 0 and YIELD_S < 0.1,
    "finalize yield must be a real but short delay")

local infos, transients = {}, {}
local downloader = Downloader:new{
    settings = { get = function() return {} end },
    clock = function() return now_us end,
    show_info = function(text) infos[#infos + 1] = text end,
    show_transient = function(text) transients[#transients + 1] = text end,
    refresh_ui = function() end,
}

local packaged
downloader._step = function(_self, dl)
    packaged = { dl = dl, log_size = #log }
end

local function reset(costs)
    queue, log, infos, transients, packaged, load_error_uid = {}, {}, {}, {}, nil, nil
    now_us = 0
    cost = { load = costs.load or 0, scan = costs.scan or 0, transform = costs.transform or 0 }
end

local function new_job(count, resumable)
    local chapters = {}
    for i = 1, count do chapters[i] = { chapterUid = 1000 + i, chapterIdx = i } end
    local titles, progress = {}, {}
    local dl = {
        book = {}, chapters = chapters, total = count, index = count + 1,
        selected = {}, bodies = {}, state = { css = "body{}" },
        resumable = resumable, workspace = resumable and { path = "/ws" } or nil,
        footnote_scans = {}, failed = {},
        progress_dialog = {
            setTitle = function(_self, title) titles[#titles + 1] = title end,
            reportProgress = function(_self, value) progress[#progress + 1] = value end,
            close = function() end,
        },
    }
    for i, chapter in ipairs(chapters) do
        dl.selected[i] = chapter
        if not resumable then
            local uid = tostring(chapter.chapterUid)
            dl.bodies[uid] = "<p>" .. uid .. "</p>"
            dl.footnote_scans[uid] = { uid = chapter.chapterUid }
        end
    end
    local completion = {}
    dl.on_complete = function(ok, value) completion.ok, completion.value = ok, value end
    downloader._active_job = dl
    return dl, completion, titles, progress
end

local function count_prefix(from, to, prefix)
    local n = 0
    for i = from + 1, to do
        if log[i]:sub(1, #prefix) == prefix then n = n + 1 end
    end
    return n
end

-- Runs scheduled steps like the UI loop would, one per "tick", recording
-- the injected-clock time and the chapters each step processed.
local function drive(max_steps, on_step)
    local batches = {}
    local steps = 0
    while #queue > 0 do
        steps = steps + 1
        expect(steps <= max_steps, "finalize did not finish within " .. max_steps .. " steps")
        local task = table.remove(queue, 1)
        expect(task.delay == YIELD_S, "finalize step scheduled with delay " .. tostring(task.delay))
        local before_log, before_us = #log, now_us
        task.fn()
        local batch = {
            ms = (now_us - before_us) / 1000,
            scans = count_prefix(before_log, #log, "scan:"),
            transforms = count_prefix(before_log, #log, "transform:"),
            pending = #queue,
        }
        batches[#batches + 1] = batch
        expect(#queue <= 1, "a finalize step scheduled more than one continuation")
        if on_step and on_step(steps, batch) then break end
    end
    return batches
end

-- 1. 200 chapters: budgeted batches, no per-chapter delay, order kept.
do
    reset{ scan = 3, transform = 7 }
    local dl, completion, titles, progress = new_job(200, true)
    downloader:_startFootnotes(dl)
    expect(#queue == 1 and #log == 0, "resumable finalize did not start in its own step")
    local batches = drive(60)
    -- 200 * (3 + 7) ms of work at 200 ms per batch: ~10 batches + the start
    -- and packaging hand-offs, instead of 50 scan + 200 transform steps.
    local yields = dl.finalize_yields
    expect(yields == #batches, "every finalize step must be counted as a UI yield")
    expect(yields >= 10 and yields <= 14,
        "finalize yields not bounded by the work/budget ratio: " .. tostring(yields))
    local idle_s = yields * YIELD_S
    expect(idle_s < 1.0, "finalize idles " .. idle_s .. " s (was 0.1 s per chapter)")
    for i, batch in ipairs(batches) do
        local items = batch.scans + batch.transforms
        if i > 1 and i < #batches then
            expect(items >= 1, "batch " .. i .. " made no progress")
            -- Never more than one chapter past the budget...
            expect(batch.ms < BUDGET_MS + 7, "batch " .. i .. " overran the budget: " .. batch.ms .. " ms")
            -- ...and never yields while budget is left (except at the end of
            -- a phase or of the whole pipeline).
            if batch.pending == 1 and i < #batches - 1 then
                expect(batch.ms >= BUDGET_MS, "batch " .. i .. " yielded early: " .. batch.ms .. " ms")
            end
        end
    end
    expect(batches[1].scans > 0 and batches[#batches].scans == 0 and batches[#batches].transforms == 0,
        "first step must scan; last step must only hand off to packaging")
    -- Ordering: all scans before transforms, chapters in book order.
    local scans, transforms, saves = {}, {}, {}
    for _i, entry in ipairs(log) do
        local kind, uid = entry:match("^(%a+):(%d+)")
        if kind == "scan" then scans[#scans + 1] = tonumber(uid)
        elseif kind == "transform" then
            expect(#scans == 200, "transform started before every chapter was scanned")
            transforms[#transforms + 1] = tonumber(uid)
        elseif kind == "save" then saves[#saves + 1] = tonumber(uid) end
    end
    expect(#scans == 200 and #transforms == 200 and #saves == 200, "every chapter scanned, transformed and saved once")
    for i = 1, 200 do
        expect(scans[i] == 1000 + i and transforms[i] == 1000 + i and saves[i] == 1000 + i,
            "chapter order changed at " .. i)
    end
    expect(log[#log]:find("^save:1200:T<p>1200</p>"), "rendered chapter body was not saved")
    expect(packaged and packaged.dl == dl and packaged.log_size == #log,
        "packaging did not run exactly after the last chapter")
    expect(dl.footnotes_done and not dl.footnote_job and not dl.footnote_scan_job, "finalize state not cleared")
    expect(dl.state.css == "body{}\n.fn{}", "footnote CSS not appended exactly once")
    expect(dl.footnote_stats.converted == 200 and dl.footnote_stats.fallback == 0, "footnote stats not aggregated")
    expect(completion.ok == nil, "finalize must not report completion before packaging")
    -- Progress: monotonically increasing chapter counts, ending at 200/200.
    local last_scan, last_transform = -1, -1
    for _i, title in ipairs(titles) do
        local done = tonumber(title:match("Scanning footnotes · chapter (%d+)/200"))
        if done then
            expect(done > last_scan and last_transform < 0, "scan progress out of order")
            last_scan = done
        end
        done = tonumber(title:match("Processing footnotes · chapter (%d+)/200"))
        if done then
            expect(done > last_transform, "transform progress out of order")
            last_transform = done
        end
    end
    expect(last_scan > 0 and last_scan < 200, "scan progress not reported between batches")
    expect(last_transform == 200, "final transform progress not reported")
    expect(#progress > 0 and progress[#progress] == 200, "progress bar not kept at the full chapter count")
end

-- 2. A chapter slower than the whole budget: one chapter per step, still
-- yielding between chapters.
do
    reset{ transform = BUDGET_MS * 3 }
    local dl = new_job(5, true)
    downloader:_startFootnotes(dl)
    local batches = drive(20)
    -- start, scan (+ first transform), 4 transforms, packaging hand-off
    expect(#batches == 6, "slow chapters were not processed one per step: " .. #batches)
    for i = 2, 5 do
        expect(batches[i].transforms == 1, "slow batch " .. i .. " processed more than one chapter")
    end
    expect(packaged and packaged.dl == dl, "slow finalize did not reach packaging")
end

-- 3. Cancel between batches (transform phase): stops before the next chapter,
-- keeps the resumable checkpoint, never packages.
do
    reset{ scan = 1, transform = 50 }
    local dl, completion = new_job(40, true)
    downloader:_startFootnotes(dl)
    local transformed_at_cancel
    drive(20, function(_steps, batch)
        if batch.transforms > 0 and not transformed_at_cancel then
            transformed_at_cancel = count_prefix(0, #log, "transform:")
            dl.cancelled, dl.cancel_reason = true, "cancelled"
        end
    end)
    expect(transformed_at_cancel and transformed_at_cancel < 40, "cancel test did not stop mid-transform")
    expect(count_prefix(0, #log, "transform:") == transformed_at_cancel, "a chapter was processed after cancel")
    expect(not packaged, "cancelled finalize still built the EPUB")
    expect(completion.ok == false and completion.value == "cancelled", "cancel not reported")
    expect(downloader._active_job == nil, "cancelled job still active")
    expect(dl.workspace, "resumable checkpoint workspace not kept on cancel")
    expect(transients[#transients] == "Download cancelled", "cancel not shown to the user")
end

-- 4. Cancel between scan batches.
do
    reset{ scan = 30 }
    local dl, completion = new_job(40, true)
    downloader:_startFootnotes(dl)
    drive(20, function(steps)
        if steps == 2 then dl.cancelled, dl.cancel_reason = true, "cancelled" end
    end)
    local scanned = count_prefix(0, #log, "scan:")
    expect(scanned > 0 and scanned < 40, "scan was not interrupted between batches: " .. scanned)
    expect(count_prefix(0, #log, "transform:") == 0 and not packaged, "work continued after cancel")
    expect(completion.ok == false and completion.value == "cancelled", "scan cancel not reported")
end

-- 5. An error inside a batch goes through the guarded step: the job stops,
-- keeps its checkpoint, reports the failure, and no later batch runs.
do
    reset{ load = 1, scan = 1, transform = 5 }
    local dl, completion = new_job(200, true)
    downloader:_startFootnotes(dl)
    load_error_uid = "1150"
    drive(60)
    expect(not packaged, "failed finalize still built the EPUB")
    expect(completion.ok == false and tostring(completion.value):find("injected checkpoint read failure 1150", 1, true),
        "finalize failure not reported")
    expect(downloader._active_job == nil, "failed job still active")
    expect(infos[#infos] and infos[#infos]:find("Download failed", 1, true), "failure not shown to the user")
    expect(count_prefix(0, #log, "transform:") < 200, "processing continued after the failure")
end

-- 6. Non-resumable jobs scanned while downloading: the scan phase only
-- collects (same step), transforms are batched the same way.
do
    reset{ transform = 30 }
    local dl = new_job(20, false)
    downloader:_startFootnotes(dl)
    expect(#queue == 1 and count_prefix(0, #log, "transform:") >= 1,
        "non-resumable finalize did not start transforming in the calling step")
    local first = count_prefix(0, #log, "transform:")
    expect(first == math.ceil(BUDGET_MS / 30), "first non-resumable batch ignored the budget: " .. first)
    drive(20)
    expect(count_prefix(0, #log, "transform:") == 20 and packaged and packaged.dl == dl,
        "non-resumable finalize incomplete")
    for i = 1, 20 do
        local uid = tostring(1000 + i)
        expect(dl.bodies[uid] == "T<p>" .. uid .. "</p>", "non-resumable body not transformed in place: " .. uid)
    end
end

-- 7. A scan phase that ends exactly on the budget yields before the
-- transform phase instead of overrunning; a missing transform job goes
-- straight to packaging (after a yield).
do
    reset{ scan = 1 }
    local dl = new_job(BUDGET_MS, true)
    downloader:_startFootnotes(dl)
    local batches = drive(10)
    expect(batches[1].scans == BUDGET_MS and batches[1].transforms == 0,
        "budget-exact scan batch did not yield before transforming")
    expect(batches[2].transforms == BUDGET_MS and packaged and packaged.dl == dl,
        "transform phase did not follow the budget-exact scan batch")

    reset{}
    local bare = new_job(1, true)
    downloader:_footnoteStep(bare)
    expect(bare.footnotes_done and #queue == 1 and not packaged, "missing footnote job did not yield")
    drive(1)
    expect(packaged and packaged.dl == bare, "missing footnote job did not continue to packaging")
end

-- 8. Without an injected clock the downloader falls back to ui/time.
do
    local plain = Downloader:new{ settings = { get = function() return {} end } }
    expect(plain:_now() == 0, "default finalize clock is not ui/time")
    expect(plain:_batchSpent(0) == false, "frozen ui/time must not spend the budget")
end

print(("downloader_finalize_batching_spec: %d checks"):format(checks))
