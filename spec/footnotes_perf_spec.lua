-- Performance regression guard for Footnotes.scan_chapter and
-- transform_chapter. Both run on KOReader's UI thread (once per downloaded
-- chapter and again for the whole book when footnotes are finalized), and a
-- Kindle's Cortex-A7 is roughly 10-20x slower than a desktop x86 core.
--
-- Before the rewrite a 2000-entry index chapter took ~50 s on x86 to scan
-- (quadratic: every id inside the wrapper block re-cleaned the whole block)
-- and logged one warning per id; a chapter of 2000 <aside> endnotes took
-- ~4 s to scan plus ~2 s to transform (every "<a"-prefixed opener after the
-- last </a> made the pattern engine search to the end of the chapter).
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local log = { warn = 0, info = {} }
package.preload["logger"] = function()
    local function noop() end
    return {
        dbg = noop,
        err = noop,
        warn = function() log.warn = log.warn + 1 end,
        info = function(...) log.info[#log.info + 1] = { ... } end,
    }
end

local Footnotes = require("weread.lib.footnotes")

local BUDGET_SECONDS = 1.0

local function index_chapter(entries)
    local parts = { '<html><body><div class="index">' }
    for i = 1, entries do
        parts[#parts + 1] = string.format(
            '<p id="ix%d" class="ix">term %d, <a href="#ch%d">%d</a> and some words here</p>',
            i, i, i, i * 3)
    end
    parts[#parts + 1] = "</div></body></html>"
    return table.concat(parts, "\n")
end

local function endnote_chapter(notes)
    local parts = { "<html><body>" }
    for i = 1, notes do
        parts[#parts + 1] = string.format(
            '<p>Body text %d<a epub:type="noteref" href="#n%d">%d</a> more body words.</p>',
            i, i, i)
    end
    for i = 1, notes do
        parts[#parts + 1] = string.format(
            '<aside epub:type="footnote" id="n%d"><p>Note %d explains something.</p></aside>',
            i, i)
    end
    parts[#parts + 1] = "</body></html>"
    return table.concat(parts, "\n")
end

-- Best of three CPU-time runs keeps the guard stable on a busy CI host.
local function timed(fn)
    local best, result_a, result_b = math.huge, nil, nil
    for _run = 1, 3 do
        collectgarbage("collect")
        local started = os.clock()
        result_a, result_b = fn()
        best = math.min(best, os.clock() - started)
    end
    return best, result_a, result_b
end

local chapter = { chapterUid = "index", chapterIdx = 1 }

-- 2000-entry index chapter.
local index_html = index_chapter(2000)
log.warn, log.info = 0, {}
local scan_seconds, scan = timed(function()
    return Footnotes.scan_chapter(index_html, chapter)
end)
local index = Footnotes.build_book_index({ index = scan }, { chapter })
local transform_seconds, body, stats = timed(function()
    return Footnotes.transform_chapter(index_html, scan, index)
end)
print(string.format(
    "footnotes_perf_spec: index chapter ids=2000 bytes=%d scan=%.3fs transform=%.3fs",
    #index_html, scan_seconds, transform_seconds))
expect(scan_seconds < BUDGET_SECONDS, string.format(
    "2000-id index chapter scan took %.3fs (budget %.1fs)", scan_seconds, BUDGET_SECONDS))
expect(transform_seconds < BUDGET_SECONDS, string.format(
    "2000-id index chapter transform took %.3fs", transform_seconds))
expect(scan.definitions["ix1"] and scan.definitions["ix2000"],
    "index entries must still be indexed individually")
expect(scan.definitions["ix1"].text == "term 1, 3 and some words here",
    "index entry text changed")
expect(stats.unresolved == 2000 and Footnotes.validate(body) == true,
    "index chapter transform result changed")

-- Oversized wrapper candidates are summarized, not warned one by one.
expect(log.warn == 0, "oversized candidates must not emit per-candidate warnings")
expect(#log.info == 3, "expected one oversized-drop summary line per scan, got "
    .. #log.info)
local summary = log.info[1]
local fields = {}
for i = 3, #summary - 1, 2 do fields[summary[i]] = summary[i + 1] end
expect(summary[2] == "dropped oversized note candidates:", "unexpected summary line")
expect(fields["chapter="] == "index" and fields["candidates="] == "2000"
    and fields["regions="] == "1" and fields["limit="] == "6000"
    and fields["first_anchor="] == "ix1",
    "oversized-drop summary lost its counts")

-- 2000 <aside> endnotes after the last </a>.
local endnote_html = endnote_chapter(2000)
local endnote_scan_seconds, endnote_scan = timed(function()
    return Footnotes.scan_chapter(endnote_html, chapter)
end)
local endnote_index = Footnotes.build_book_index({ index = endnote_scan }, { chapter })
local endnote_transform_seconds, endnote_body, endnote_stats = timed(function()
    return Footnotes.transform_chapter(endnote_html, endnote_scan, endnote_index)
end)
print(string.format(
    "footnotes_perf_spec: aside endnotes=2000 bytes=%d scan=%.3fs transform=%.3fs",
    #endnote_html, endnote_scan_seconds, endnote_transform_seconds))
expect(endnote_scan_seconds < BUDGET_SECONDS, string.format(
    "2000-aside endnote scan took %.3fs", endnote_scan_seconds))
expect(endnote_transform_seconds < BUDGET_SECONDS, string.format(
    "2000-aside endnote transform took %.3fs", endnote_transform_seconds))
expect(endnote_stats.converted == 2000 and Footnotes.validate(endnote_body) == true,
    "aside endnotes were not all converted")

-- Growth must stay near-linear: quadrupling the chapter may not cost more
-- than ~10x (a quadratic scan would cost 16x).
local small_seconds = timed(function()
    return Footnotes.scan_chapter(index_chapter(1000), chapter)
end)
local large_seconds = timed(function()
    return Footnotes.scan_chapter(index_chapter(4000), chapter)
end)
print(string.format("footnotes_perf_spec: index scan 1000 ids=%.3fs 4000 ids=%.3fs ratio=%.1f",
    small_seconds, large_seconds, large_seconds / math.max(small_seconds, 1e-3)))
expect(large_seconds < 10 * math.max(small_seconds, 0.005),
    "index chapter scan no longer scales linearly")

print(("footnotes_perf_spec: %d checks"):format(checks))
