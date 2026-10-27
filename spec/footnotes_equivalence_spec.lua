-- Differential check: the linear-time footnote scanner must produce exactly
-- what the previous implementation produced. spec/fixtures/footnotes_legacy.lua
-- is a verbatim copy of weread/lib/footnotes.lua before the rewrite (commit
-- ae3930f); both run on the same corpus and every observable output is
-- compared: scan tables, the book index, transformed chapters and their stats,
-- validation verdicts, and the number of oversized candidates dropped.
--
-- Set FOOTNOTES_CORPUS_DIR to a directory of extracted .xhtml/.html chapters
-- (for example an unzipped EPUB or a resumable download's text/ directory) to
-- compare a real book as well; each sub-directory is treated as one book.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

-- Record what each implementation logs about oversized candidates. The old
-- one warns once per candidate; the new one logs one summary line carrying
-- the same count.
local oversized_warnings, oversized_summary = 0, 0
package.preload["logger"] = function()
    local function noop() end
    return {
        dbg = noop,
        err = noop,
        warn = function(_prefix, message)
            if message == "dropping oversized note candidate:" then
                oversized_warnings = oversized_warnings + 1
            end
        end,
        info = function(_prefix, message, ...)
            if message ~= "dropped oversized note candidates:" then return end
            local fields = { ... }
            for i = 1, #fields - 1 do
                if fields[i] == "candidates=" then
                    oversized_summary = oversized_summary + tonumber(fields[i + 1])
                end
            end
        end,
    }
end

local Current = require("weread.lib.footnotes")
local Legacy = dofile("spec/fixtures/footnotes_legacy.lua")
expect(Current ~= Legacy, "legacy fixture must be a separate module instance")

-- Canonical, order-independent rendering of plain Lua data.
local function serialize(value, out)
    out = out or {}
    local kind = type(value)
    if kind == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then return type(a) < type(b) end
            return a < b
        end)
        out[#out + 1] = "{"
        for _i, key in ipairs(keys) do
            out[#out + 1] = string.format("[%q]=", key)
            serialize(value[key], out)
            out[#out + 1] = ","
        end
        out[#out + 1] = "}"
    elseif kind == "string" then
        out[#out + 1] = string.format("%q", value)
    else
        out[#out + 1] = tostring(value)
    end
    return out
end

local function canon(value)
    return table.concat(serialize(value))
end

local function first_difference(a, b)
    local limit = math.min(#a, #b)
    for i = 1, limit do
        if a:byte(i) ~= b:byte(i) then
            return i, a:sub(math.max(1, i - 60), i + 60), b:sub(math.max(1, i - 60), i + 60)
        end
    end
    return limit + 1, a:sub(limit - 60), b:sub(limit - 60)
end

local function expect_same(label, old, new)
    checks = checks + 1
    if old == new then return end
    local at, old_ctx, new_ctx = first_difference(old, new)
    error(string.format("%s differs at byte %d\n old: %s\n new: %s",
        label, at, old_ctx, new_ctx), 2)
end

local stats = { books = 0, chapters = 0, bytes = 0, definitions = 0,
    refs = 0, converted = 0, image_notes = 0, oversized = 0 }

-- chapters: array of { uid = ..., html = ..., chapter = ... }
local function compare_book(label, chapters)
    stats.books = stats.books + 1
    local catalog = {}
    for _i, entry in ipairs(chapters) do catalog[#catalog + 1] = entry.chapter end

    local old_scans, new_scans = {}, {}
    for _i, entry in ipairs(chapters) do
        local name = label .. "/" .. entry.uid
        oversized_warnings, oversized_summary = 0, 0
        local old_scan = Legacy.scan_chapter(entry.html, entry.chapter)
        local new_scan = Current.scan_chapter(entry.html, entry.chapter)
        expect_same(name .. " scan", canon(old_scan), canon(new_scan))
        expect(oversized_warnings == oversized_summary, string.format(
            "%s oversized drop count changed: legacy=%d current=%d",
            name, oversized_warnings, oversized_summary))
        old_scans[entry.uid], new_scans[entry.uid] = old_scan, new_scan
        stats.chapters = stats.chapters + 1
        stats.bytes = stats.bytes + #entry.html
        stats.refs = stats.refs + #new_scan.refs
        stats.oversized = stats.oversized + oversized_summary
        for _anchor in pairs(new_scan.definitions) do
            stats.definitions = stats.definitions + 1
        end
    end

    local old_index = Legacy.build_book_index(old_scans, catalog)
    local new_index = Current.build_book_index(new_scans, catalog)
    expect_same(label .. " book index", canon(old_index), canon(new_index))

    for _i, entry in ipairs(chapters) do
        local name = label .. "/" .. entry.uid
        local old_body, old_stats = Legacy.transform_chapter(
            entry.html, old_scans[entry.uid], old_index)
        local new_body, new_stats = Current.transform_chapter(
            entry.html, new_scans[entry.uid], new_index)
        expect_same(name .. " transformed body", old_body, new_body)
        expect_same(name .. " transform stats", canon(old_stats), canon(new_stats))
        local old_valid, old_reason = Legacy.validate(old_body)
        local new_valid, new_reason = Current.validate(new_body)
        expect(old_valid == new_valid and old_reason == new_reason,
            name .. " validation verdict changed")
        expect(Legacy.has_converted(old_stats) == Current.has_converted(new_stats),
            name .. " has_converted changed")
        stats.converted = stats.converted + (new_stats.converted or 0)
        stats.image_notes = stats.image_notes + (new_stats.image_notes or 0)

        -- A chapter transformed without a book index (single-chapter path).
        local old_alone = Legacy.transform_chapter(entry.html, old_scans[entry.uid])
        local new_alone = Current.transform_chapter(entry.html, new_scans[entry.uid])
        expect_same(name .. " standalone transform", old_alone, new_alone)
    end
end

local function chapter_entry(uid, idx, html)
    return {
        uid = tostring(uid),
        html = html,
        chapter = { chapterUid = tostring(uid), chapterIdx = idx,
            files = { string.format("Text/chapter%d.xhtml", idx) } },
    }
end

---------------------------------------------------------------------------
-- 1. Hand-written fixtures, including every HTML sample from the existing
--    footnote specs.
---------------------------------------------------------------------------
local padding = ("這是用來模擬整章長度的填充正文段落。"):rep(260)
local filler = "補充背景說明文字。"
local fixtures = {
    [[<p>正文<a epub:type="noteref" href="#note-1"><sup>[1]</sup></a></p>
<aside id="note-1"><p>[1] 同章脚注内容</p></aside>]],
    [[<html><body><p><a class="noteref" href="#multi-note">[1]</a></p>
<p id="multi-note">[1] 多文档脚注</p></body></html>
<html><body><h2 id="later-body">后续正文</h2></body></html>]],
    [[<p>正文<a href="../Text/chapter2.xhtml#target-x"><span>[2]</span></a></p>]],
    [[<section><p id="target-x">[2] 跨章尾注内容</p></section>]],
    [[<a id="adjacent-note"></a><p>[3] 空锚点后的脚注内容</p>]],
    [[<p>正文<img class="cover qqreader-footnote icon" alt="图片脚注说明" src="note.png"/></p>]],
    [[<p><a class="noteref" href="Text/missing.xhtml#fn404">[9]</a></p>]],
    [[<p><a class="wr-thought-link" href="#wrthought-book-chapter-1-2">*</a></p>]],
    [[<a href="../Text/chapter1.xhtml#w1">[1]</a><span id="w1"></span>]],
    [[<p><span id="source-1"><a href="#note-1">[1]</a></span></p>
<p class="note"><a id="note-1"></a>正文脚注<a href="#source-1">[1]</a></p>]],
    [[<p><a class="noteref" href="#shared">[1]</a></p>]],
    [[<p id="shared">[1] 第一处</p>]],
    [[<html><body><div id="root">
<h2 class="wr-traditional">第一章</h2><h2 class="wr-simplified">第一章</h2>
<p class="wr-traditional">這是正文內容。<a href="#fn_1">1</a></p>
<p class="wr-simplified">这是正文内容。</p>
<p class="wr-traditional">]] .. padding .. [[</p>
<a id="fn_1"></a><p>譯註：這是真正的注釋。</p>
</div></body></html>]],
    "<aside>" .. filler:rep(30) .. '<p id="short-note">真注釋</p>'
        .. filler:rep(30) .. "</aside>",
    '<p id="long-note">' .. ("這是一條很長但完全真實的注釋內容。"):rep(100) .. "</p>",
    [[<p>正文<a class="noteref" href="#fn_9"><sup>[9]</sup></a></p><li id="fn_9">這是完整的注釋正文內容。<a id="fn_9" href="#ref_9">↩</a></li>]],
    '<p id="kana-note">これは日本語の脚注です。</p><p id="hangul-note">한국어 각주입니다.</p>'
        .. '<p id="cyrillic-note">Это сноска на русском языке.</p>'
        .. '<p id="extb-note">𠀀𠀁 rare CJK extension footnote.</p>'
        .. '<p id="mixed-note">①これは注釈本体。</p>',
    '<p id="glyph-arrow">↩</p><p id="glyph-arrow-vs">↩️</p><p id="glyph-left">←</p>'
        .. '<p id="glyph-hook">⤴</p><p id="glyph-enclosed">①</p><p id="glyph-cjk-punct">。</p>'
        .. '<p id="glyph-latin1">«»</p><p id="glyph-dash">……</p>',
    [[<p><a class="noteref" href="../Text/chapter2.xhtml#target2">[2]</a></p>]],
    [[<p id="target2">[2] 下载器跨章脚注</p>]],
    [[<p><a class="noteref" href="#shared-note">[1]</a></p>
<p id="shared-note">[1] 可跨章节恢复的脚注</p>]],
    [[<p><a class="noteref" href="../Text/chapter1.xhtml#shared-note">[1]</a></p>]],
    -- Edge cases around the new fast paths and the last-closing-tag cut.
    "",
    "plain text without any markup",
    [[<p>trailing opener after the last closing tag</p><aside id="n1">text<abbr>x</abbr>]],
    [[<p><a href="#n1">[1]</a></p><a id="n1"></a>   <p>note without close]],
    [[<P ID="x">upper</P><P id="u1">大写段落脚注</P ><A HREF="#u1">[1]</A ><A class="noteref" href="#u1">[1]</a >]],
    [[<p id='sq'>single quoted &amp;lt;b&amp;gt; note</p><a class='noteref' href='#sq'>[2]</a>]],
    "<p id=\"ws\">  \t\n  </p><p id=\"zw\">\226\128\139\226\128\140</p>"
        .. "<p id=\"zw3\">a\226\128\140b\226\128\141c</p>"
        .. "<p id=\"zw2\">\226\128\226\128\139\139 kept</p><p id=\"nb\">&nbsp;&#160;&#xA0;x&#xa0;</p>",
    [[<p id="ents">&quot;q&#34; &apos;a&#39; &amp;amp; &#38;lt; &lt;i&gt;tag&lt;/i&gt;</p>]],
    [[<a href="#n2">[2]</a><pre>code <p>x</pre><param name="n2"/><p id="n2">pre note</p>]],
    [[<a href=" ../Text/./a/../chapter2.xhtml#%66n%2D1 ">[1]</a><p id="fn-1">percent anchor</p>]],
    [[<p><a href="#n">†</a><a href="#m">※</a><a href="#k">**</a></p><p id="n">† dagger note</p><p id="m">※ ref mark</p><p id="k">** star note</p>]],
}
local fixture_chapters = {}
for i, html in ipairs(fixtures) do
    fixture_chapters[#fixture_chapters + 1] = chapter_entry(100 + i, i, html)
end
compare_book("fixtures", fixture_chapters)
-- Each fixture also on its own, since the book index merges anchors.
for i, html in ipairs(fixtures) do
    compare_book("fixture-" .. i, { chapter_entry(1, 1, html) })
end

---------------------------------------------------------------------------
-- 2. Seeded random books built from footnote layouts seen in WeRead EPUBs.
---------------------------------------------------------------------------
local seed = 20261027
local function rand(n)
    -- 31-bit LCG; deterministic across LuaJIT builds, unlike math.random.
    seed = (seed * 1103515245 + 12345) % 2147483648
    return math.floor(seed / 65536) % n + 1
end
local function pick(list) return list[rand(#list)] end

local words = {
    "正文", "注释", "說明", "the", "note", "Go", "interface", "これは", "각주",
    "сноска", "&amp;", "&lt;b&gt;", "&nbsp;", "&#160;", "&quot;", "&#39;", "&apos;",
    "\226\128\139", "↩", "←", "①", "。", "«»", "†", "※", "*", "[3]", "(4)",
    "（5）", "12", "<br/>", "<br>", "<em>強調</em>", "<span class=\"x\">span</span>",
    "<b>bold</b>", "<sup>2</sup>", "  ", "\n", "\t", "𠀀",
}
local function text(n)
    local out = {}
    for i = 1, n do out[i] = pick(words) end
    return table.concat(out, rand(3) == 1 and "" or " ")
end

local anchor_styles = { "n%d", "fn_%d", "note-%d", "ref%d", "foot%d", "x%d", "ix%d" }
local function anchor_name(i) return string.format(pick(anchor_styles), i) end

local function ref_markup(anchor, chapter_count)
    local display = pick({ "[%d]", "%d", "(%d)", "（%d）", "*", "†", "<sup>%d</sup>", "word" })
    display = display:format(rand(99))
    local file = ""
    if rand(4) == 1 then
        file = pick({ "../Text/", "Text/", "", "./" })
            .. string.format("chapter%d.xhtml", rand(chapter_count))
    end
    local attrs = pick({
        'epub:type="noteref"', 'class="noteref"', 'class="footnote"', 'role="doc-noteref"',
        "", 'class="fn-ref"', 'class="backlink"', 'id="r' .. rand(40) .. '"',
    })
    if rand(10) == 1 then
        return string.format("<A %s HREF=\"%s#%s\">%s</A>", attrs, file, anchor, display)
    elseif rand(10) == 1 then
        return string.format("<a %s href='%s#%s'>%s</a >", attrs, file, anchor, display)
    end
    return string.format('<a %s href="%s#%s">%s</a>', attrs, file, anchor, display)
end

local function definition_markup(anchor)
    local body = text(rand(12))
    local layouts = {
        '<aside epub:type="footnote" id="%s"><p>%s</p></aside>',
        '<p class="note" id="%s">%s</p>',
        '<p class="fncontent"><a id="%s"></a>%s</p>',
        '<li id="%s"><p>%s <a href="#back" class="backlink">↩</a></p></li>',
        '<a id="%s"></a> <p>%s</p>',
        '<a name="%s"></a><p class="note">%s</p>',
        '<dd id="%s">%s</dd>',
        '<td id="%s">%s</td>',
        '<div id="%s"><div>%s</div></div>',
        '<section id="%s"><blockquote>%s</blockquote></section>',
        '<P ID="x" id="%s">%s</P>',
        '<blockquote><span id="%s">%s</span></blockquote>',
    }
    return string.format(pick(layouts), anchor, body)
end

local function image_markup()
    local class = pick({ "qqreader-footnote", "footnote-icon", "footnote-ref",
        "note-ref", "footnote", "cover", "FOOTNOTE" })
    local attr = pick({ "alt", "title", "data-content", "data-note" })
    return string.format('<img class="%s" %s="%s" src="i.png"/>', class, attr, text(rand(5)))
end

local function random_chapter(chapter_count)
    local parts = {}
    local ids = rand(25)
    for _i = 1, rand(30) + 5 do
        local roll = rand(10)
        if roll <= 3 then
            parts[#parts + 1] = "<p>" .. text(rand(10)) .. ref_markup(anchor_name(rand(ids)), chapter_count)
                .. text(rand(4)) .. "</p>"
        elseif roll <= 6 then
            parts[#parts + 1] = definition_markup(anchor_name(rand(ids)))
        elseif roll == 7 then
            parts[#parts + 1] = "<p>" .. text(rand(6)) .. image_markup() .. "</p>"
        elseif roll == 8 then
            parts[#parts + 1] = pick({
                "<abbr>abbr</abbr>", "<pre>code</pre>", '<link rel="x"/>',
                "<audio>a</audio>", "<p>unclosed", "<aside>", "<P>", "</p>",
                "<area>", "<h2 id=\"h" .. rand(9) .. "\">heading</h2>",
            })
        else
            parts[#parts + 1] = "<p>" .. text(rand(20)) .. "</p>"
        end
    end
    local body = table.concat(parts, rand(2) == 1 and "\n" or "")
    local wrap = rand(4)
    if wrap == 1 then
        body = '<div class="wrapper" id="w' .. rand(9) .. '">' .. body .. "</div>"
    elseif wrap == 2 then
        -- Oversized wrapper: thousands of bytes around its descendant ids.
        body = '<section id="big">' .. ("<p>" .. text(30) .. "</p>"):rep(rand(40) + 20)
            .. body .. "</section>"
    end
    if rand(3) == 1 then body = "<html><body>" .. body .. "</body></html>" end
    return body
end

for book = 1, 250 do
    local chapter_count = rand(4)
    local chapters = {}
    for idx = 1, chapter_count do
        chapters[idx] = chapter_entry(1000 * book + idx, idx, random_chapter(chapter_count))
    end
    compare_book("random-" .. book, chapters)
end

---------------------------------------------------------------------------
-- 3. The layouts that used to be super-linear, at sizes the legacy code can
--    still finish quickly: an index chapter (one wrapper, many ids, dropped
--    as oversized) and a chapter of <aside> endnotes after the last </a>.
---------------------------------------------------------------------------
local index_parts = { '<html><body><div class="index">' }
for i = 1, 250 do
    index_parts[#index_parts + 1] = string.format(
        '<p id="ix%d" class="ix">term %d &amp; more, <a href="#ch%d">%d</a> and words</p>',
        i, i, i, i * 3)
end
index_parts[#index_parts + 1] = "</div></body></html>"
local before = stats.oversized
compare_book("index", { chapter_entry(1, 1, table.concat(index_parts, "\n")) })
expect(stats.oversized > before, "index chapter should drop its oversized wrapper candidates")

local endnote_parts = { "<html><body>" }
for i = 1, 150 do
    endnote_parts[#endnote_parts + 1] = string.format(
        '<p>Body %d<a epub:type="noteref" href="#n%d">%d</a> text.</p>', i, i, i)
end
for i = 1, 150 do
    endnote_parts[#endnote_parts + 1] = string.format(
        '<aside epub:type="footnote" id="n%d"><p>Note %d &lt;explained&gt;.</p></aside>', i, i)
end
endnote_parts[#endnote_parts + 1] = "</body></html>"
compare_book("asides", { chapter_entry(1, 1, table.concat(endnote_parts, "\n")) })

---------------------------------------------------------------------------
-- 4. Optional real corpus.
---------------------------------------------------------------------------
local corpus_dir = os.getenv("FOOTNOTES_CORPUS_DIR")
if corpus_dir and corpus_dir ~= "" then
    local listing = io.popen(string.format(
        "find %q -type f \\( -name '*.xhtml' -o -name '*.html' -o -name '*.htm' \\) | sort",
        corpus_dir))
    local books, order = {}, {}
    for path in listing:lines() do
        local dir = path:match("^(.*)/[^/]+$") or "."
        if not books[dir] then books[dir] = {}; order[#order + 1] = dir end
        local file = assert(io.open(path, "rb"))
        local html = file:read("*a")
        file:close()
        local list = books[dir]
        local entry = chapter_entry(path, #list + 1, html)
        entry.chapter.files = { path:sub(#dir + 2) }
        list[#list + 1] = entry
    end
    listing:close()
    for _i, dir in ipairs(order) do compare_book(dir, books[dir]) end
end

print(string.format(
    "footnotes_equivalence_spec: %d checks; books=%d chapters=%d bytes=%d "
        .. "definitions=%d refs=%d converted=%d image_notes=%d oversized_dropped=%d",
    checks, stats.books, stats.chapters, stats.bytes, stats.definitions,
    stats.refs, stats.converted, stats.image_notes, stats.oversized))
