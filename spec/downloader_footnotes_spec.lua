package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = {}
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
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, callback)
            -- A zero-delay chain keeps UIManager's task loop busy and never
            -- polls input (see FINALIZE_YIELD_S in the downloader).
            expect(delay > 0, "footnote processing used a zero-delay step that starves input")
            scheduled[#scheduled + 1] = callback
        end,
        preventStandby = function() end,
        allowStandby = function() end,
        show = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
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
local resumable_raw = {}
local resumable_rendered = {}
local rendered_resets = 0
package.preload["weread.lib.content"] = function()
    return {
        reset_full_download_rendered_text = function()
            rendered_resets = rendered_resets + 1
            resumable_rendered = {}
        end,
        load_full_download_chapter = function(_workspace, chapter)
            return resumable_raw[tostring(chapter.chapterUid)]
        end,
        save_full_download_rendered_chapter = function(_workspace, chapter, _index, body)
            resumable_rendered[tostring(chapter.chapterUid)] = body
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.protocol"] = function()
    return { normalize_cover_url = function(value) return value end }
end

local Footnotes = require("weread.lib.footnotes")
local Downloader = require("weread.lib.downloader")

local source_chapter = {
    chapterUid = 1, chapterIdx = 1, files = { "Text/chapter1.xhtml" },
}
local note_chapter = {
    chapterUid = 2, chapterIdx = 2, files = { "Text/chapter2.xhtml" },
}
local source = [[<p><a class="noteref" href="../Text/chapter2.xhtml#target2">[2]</a></p>]]
local note = [[<p id="target2">[2] 下载器跨章脚注</p>]]

local network_accesses = 0
local client = setmetatable({}, {
    __index = function()
        network_accesses = network_accesses + 1
        error("footnote finalization must not access the network client")
    end,
})
local downloader = Downloader:new{
    client = client,
    settings = {
        get = function()
            return { book_footnotes_in_popup = true }
        end,
    },
    show_transient = function() end,
}
local dl = {
    client = client,
    cancelled = false,
    selected = { source_chapter, note_chapter },
    bodies = { ["1"] = source, ["2"] = note },
    footnote_scans = {
        ["1"] = Footnotes.scan_chapter(source, source_chapter),
        ["2"] = Footnotes.scan_chapter(note, note_chapter),
    },
    footnote_stats = {
        candidates = 0, converted = 0, image_notes = 0,
        backlinks = 0, removed_note_blocks = 0,
        unresolved = 0, fallback = 0,
    },
    state = { css = "body{}" },
    index = 3,
    total = 2,
    progress_dialog = {
        setTitle = function() end,
        reportProgress = function() end,
    },
}

-- Both chapters fit in one finalize batch (the clock does not move), so the
-- phase finishes in this step and yields once before packaging.
downloader:_startFootnotes(dl)
expect(#scheduled == 1, "footnote phase did not yield exactly once before packaging")

expect(dl.footnotes_done == true, "footnote phase did not complete")
expect(network_accesses == 0, "full-book footnote processing accessed the network")
expect(dl.footnote_stats.converted == 1 and dl.footnote_stats.unresolved == 0,
    "downloader did not aggregate footnote conversion statistics")
expect(dl.bodies["1"]:find("下载器跨章脚注", 1, true),
    "downloader did not embed a cross-chapter note")
local _, css_count = dl.state.css:gsub("%.wr%-fn%-ref%{", "")
expect(css_count == 1, "footnote CSS was not merged exactly once")
expect(dl.state.css == "body{}\n" .. Footnotes.FOOTNOTES_CSS,
    "legacy popup preference must not override standard footnote CSS")

local resumed_source_chapter = {
    chapterUid = 11, chapterIdx = 1, files = { "Text/chapter1.xhtml" },
}
local resumed_reference_chapter = {
    chapterUid = 22, chapterIdx = 2, files = { "Text/chapter2.xhtml" },
}
resumable_raw = {
    ["11"] = [[<p><a class="noteref" href="#shared-note">[1]</a></p>
<p id="shared-note">[1] 可跨章节恢复的脚注</p>]],
    ["22"] = [[<p><a class="noteref" href="../Text/chapter1.xhtml#shared-note">[1]</a></p>]],
}

local function new_resumable_footnote_job()
    return {
        cancelled = false,
        resumable = true,
        workspace = { rendered_text_dir = "/cache/rendered-text" },
        chapters = { resumed_source_chapter, resumed_reference_chapter },
        selected = { resumed_source_chapter, resumed_reference_chapter },
        bodies = {},
        footnote_scans = {},
        footnote_stats = {
            candidates = 0, converted = 0, image_notes = 0,
            backlinks = 0, removed_note_blocks = 0,
            unresolved = 0, fallback = 0,
        },
        state = { css = "body{}" },
        index = 3,
        total = 2,
        progress_dialog = {
            setTitle = function() end,
            reportProgress = function() end,
        },
    }
end

local function run_resumable_footnotes(resumable_dl)
    local before = #scheduled
    downloader:_startFootnotes(resumable_dl)
    expect(#scheduled == before + 1 and resumable_dl.footnote_scan_job,
        "resumable footnote scan did not start as a scheduled step")
    local steps = 0
    while not resumable_dl.footnotes_done do
        steps = steps + 1
        expect(steps < 100 and scheduled[before + steps], "footnote phase stalled")
        scheduled[before + steps]()
    end
    -- one budgeted batch scans and transforms both chapters
    expect(steps == 1, "small resumable footnote phase took more than one batch")
    return steps
end

local first_run = new_resumable_footnote_job()
run_resumable_footnotes(first_run)
expect(resumable_raw["11"]:find('id="shared-note"', 1, true),
    "first footnote conversion mutated the raw resumable checkpoint")

local restarted_run = new_resumable_footnote_job()
run_resumable_footnotes(restarted_run)
expect(rendered_resets == 2,
    "resumed footnote pass did not discard stale rendered chapters")
expect(restarted_run.footnote_stats.unresolved == 0,
    "cross-chapter footnote was unresolved after rebuilding from checkpoints")
expect(resumable_rendered["22"]:find("可跨章节恢复的脚注", 1, true),
    "restarted footnote pass did not embed the cross-chapter definition")
expect(restarted_run.state.css:find("%.wr%-fn%-ref%{", 1) ~= nil,
    "restarted footnote pass did not rebuild its stylesheet")

local original_transform = Footnotes.transform_chapter
Footnotes.transform_chapter = function()
    error("injected footnote transformation failure")
end
local transform_fallback_run = new_resumable_footnote_job()
run_resumable_footnotes(transform_fallback_run)
Footnotes.transform_chapter = original_transform
expect(transform_fallback_run.footnote_stats.fallback == 2,
    "footnote transformation failures did not use original chapter fallbacks")
expect(resumable_rendered["11"] == resumable_raw["11"]
    and resumable_rendered["22"] == resumable_raw["22"],
    "footnote transformation fallback did not stage original chapters for packaging")

local original_validate = Footnotes.validate
Footnotes.validate = function() return false, "injected validation failure" end
local validation_fallback_run = new_resumable_footnote_job()
run_resumable_footnotes(validation_fallback_run)
Footnotes.validate = original_validate
expect(validation_fallback_run.footnote_stats.fallback == 2,
    "footnote validation failures did not use original chapter fallbacks")
expect(resumable_rendered["11"] == resumable_raw["11"]
    and resumable_rendered["22"] == resumable_raw["22"],
    "footnote validation fallback did not stage original chapters for packaging")

-- Resumable rescans are split into time-budgeted scheduled steps (F2/F4): a
-- large book must not be scanned in one synchronous UI step. Detailed batch
-- budget, cancellation and ordering checks: downloader_finalize_batching_spec.
do
    local many = {}
    resumable_raw = {}
    for chapter_index = 1, 10 do
        many[chapter_index] = { chapterUid = 100 + chapter_index, chapterIdx = chapter_index }
        resumable_raw[tostring(100 + chapter_index)] = "<p>chapter " .. chapter_index .. "</p>"
    end
    -- Each scan costs 70 ms on the injected clock: the 200 ms budget is
    -- spent after the third chapter of a batch.
    local now_us = 0
    downloader.clock = function() return now_us end
    local original_scan = Footnotes.scan_chapter
    local scans_per_step, current_step_scans = {}, 0
    Footnotes.scan_chapter = function(...)
        current_step_scans = current_step_scans + 1
        now_us = now_us + 70 * 1000
        return original_scan(...)
    end
    local job = new_resumable_footnote_job()
    job.chapters, job.selected, job.total, job.index = many, many, 10, 11
    local before = #scheduled
    downloader:_startFootnotes(job)
    expect(current_step_scans == 0, "resumable footnote scan ran inside the start step")
    local steps = 0
    while job.footnote_scan_job do
        steps = steps + 1
        current_step_scans = 0
        scheduled[before + steps]()
        scans_per_step[#scans_per_step + 1] = current_step_scans
    end
    Footnotes.scan_chapter = original_scan
    downloader.clock = nil
    expect(#scans_per_step == 4 and scans_per_step[1] == 3 and scans_per_step[2] == 3
        and scans_per_step[3] == 3 and scans_per_step[4] == 1,
        "footnote rescans were not batched by the 200 ms budget")
    -- The last scan batch had budget left, so the transform phase ran in it.
    local rendered = 0
    for chapter_index = 1, 10 do
        if resumable_rendered[tostring(100 + chapter_index)] then rendered = rendered + 1 end
    end
    expect(job.footnotes_done and rendered == 10,
        "batched scan did not hand all chapters to the transform phase")
end

-- The resumable download loop does not scan on the UI loop; the checkpoint
-- rescan in _startFootnotes is the only scan.
do
    local scan_calls = 0
    local original_scan = Footnotes.scan_chapter
    Footnotes.scan_chapter = function() scan_calls = scan_calls + 1; return {} end
    local Content = require("weread.lib.content")
    Content.fetch_single_chapter_source = function() return "<p>text</p>" end
    Content.finalize_single_chapter_content = function(_c, _s, _b, _ch, xhtml) return xhtml, {} end
    Content.save_full_download_css = function() end
    Content.save_full_download_chapter = function() end
    local function job(resumable)
        return {
            book = {}, chapters = { { chapterUid = 5 } }, total = 1, index = 1,
            selected = {}, bodies = {}, state = {}, assets = {}, failed = {},
            resumable = resumable, workspace = resumable and {} or nil,
            completed = {}, completed_count = 0, footnote_scans = {},
        }
    end
    downloader:_step(job(true))
    expect(scan_calls == 0, "resumable download scanned footnotes on the UI loop")
    downloader:_step(job(false))
    expect(scan_calls == 1, "non-resumable download stopped scanning footnotes")
    Footnotes.scan_chapter = original_scan
end
print(("downloader_footnotes_spec: %d checks"):format(checks))
