-- EPUB packaging in weread.lib.content: archive layout (mimetype first and
-- stored), OPF/nav/NCX documents, chapter nesting, cover and asset entries,
-- and the atomic .part -> final commit including its failure paths.
-- KOReader's ffi/archiver is replaced by a writer that serializes the entries
-- it receives into the .part file, so the committed file can be read back.
-- Run with: luajit spec/content_epub_packaging_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local function quoted(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end
local function write_raw(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end
local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() return true end
    return false
end
local function mkdir(path)
    assert(os.execute("mkdir -p " .. quoted(path)))
end
local function list_dir(path)
    local names = {}
    local listing = io.popen("ls -A " .. quoted(path) .. " 2>/dev/null")
    for name in listing:lines() do names[#names + 1] = name end
    listing:close()
    return names
end

-- Fake archive writer ---------------------------------------------------------
local archiver = { fail_open = false, fail_memory = nil, fail_path = nil, add_path_calls = {} }
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({ entries = {} }, { __index = Writer }) end
    function Writer:open(path, format)
        if archiver.fail_open then
            self.err = "injected open failure"
            return false
        end
        self.path, self.format = path, format
        write_raw(path, "") -- libarchive creates the file on open
        return true
    end
    function Writer:setZipCompression(method)
        self.compression = method
        return true
    end
    function Writer:addFileFromMemory(name, data, mtime)
        if archiver.fail_memory == name then
            self.err = "injected memory failure"
            return false
        end
        self.entries[#self.entries + 1] = {
            name = name, data = data, compression = self.compression, mtime = mtime,
        }
        return true
    end
    function Writer:addPath(name, path, recursive, mtime)
        archiver.add_path_calls[#archiver.add_path_calls + 1] = {
            name = name, path = path, recursive = recursive,
        }
        if archiver.fail_path then
            self.err = archiver.fail_path
            return false
        end
        local names = list_dir(path)
        table.sort(names)
        for _, child in ipairs(names) do
            self.entries[#self.entries + 1] = {
                name = name .. "/" .. child, data = read_file(path .. "/" .. child),
                compression = self.compression, mtime = mtime,
            }
        end
        return false -- KOReader's addPath reports a clean walk as EOF/false
    end
    function Writer:close()
        if not self.path then return end
        local file = assert(io.open(self.path, "wb"))
        for _, entry in ipairs(self.entries) do
            file:write(("%s\t%s\t%d\n"):format(entry.name, entry.compression, #entry.data))
            file:write(entry.data)
        end
        file:close()
    end
    return { Writer = Writer }
end

-- Read back what the fake writer committed.
local function read_epub(path)
    local data = assert(read_file(path), "EPUB was not written: " .. path)
    local entries, by_name, offset = {}, {}, 1
    while offset <= #data do
        local line_end = data:find("\n", offset, true)
        local name, compression, size = data:sub(offset, line_end - 1):match("^(.-)\t(.-)\t(%d+)$")
        size = tonumber(size)
        local entry = { name = name, compression = compression,
            data = data:sub(line_end + 1, line_end + size) }
        entries[#entries + 1] = entry
        by_name[name] = entry
        offset = line_end + size + 1
    end
    return entries, by_name
end

local Content = require("weread.lib.content")

local root = os.tmpname()
os.remove(root)
mkdir(root)
local settings = { cache_dir = root .. "/cache" }

local function no_leftovers(dir)
    for _, name in ipairs(list_dir(dir)) do
        if name:match("%.part$") or name:match("%.weread%-backup$") then return false end
    end
    return true
end

-- Single-chapter EPUB -----------------------------------------------------------
local image_dir = root .. "/staged/images"
mkdir(image_dir)
write_raw(image_dir .. "/disk-1.jpg", "\255\216\255disk-one")
write_raw(image_dir .. "/disk-2.png", "\137PNG\r\n\026\ndisk-two")
local chapter_book = { bookId = "single", title = "Tom & Jerry <1>" }
local chapter = { chapterUid = 7, title = "Part?1: \"Start\"" }
local chapter_path = Content.save_chapter_epub(settings, chapter_book, chapter,
    "<html><body>shell</body></html><html><body class=\"x\"><p>real text</p></body></html>",
    {
        { href = "images/inline.gif", media_type = "image/gif", data = "GIF89a-inline" },
        { href = "images/disk-1.jpg", media_type = "image/jpeg", path = image_dir .. "/disk-1.jpg" },
        { href = "images/disk-2.png", media_type = "image/png", path = image_dir .. "/disk-2.png" },
    })
local book_dir = root .. "/cache/single"
expect(chapter_path == book_dir .. "/Tom & Jerry _1_ - Part_1_ _Start_.epub",
    "single-chapter EPUB name was not made filesystem safe: " .. tostring(chapter_path))
expect(chapter_book.cache_dir == book_dir, "saving the EPUB did not pin the book directory")
expect(no_leftovers(book_dir), "single-chapter EPUB left a .part or backup file")
local entries, by_name = read_epub(chapter_path)
expect(entries[1].name == "mimetype" and entries[1].data == "application/epub+zip"
    and entries[1].compression == "store", "mimetype is not the first, stored entry")
for index = 2, #entries do
    expect(entries[index].compression == "deflate",
        "entry after mimetype was not deflated: " .. entries[index].name)
end
expect(by_name["META-INF/container.xml"].data:find('full-path="OEBPS/content.opf"', 1, true),
    "container.xml does not point at the OPF")
local opf = by_name["OEBPS/content.opf"].data
expect(opf:find("<dc:identifier id=\"bookid\">weread-single-7</dc:identifier>", 1, true)
    and opf:find("<dc:title>Tom &amp; Jerry &lt;1&gt;</dc:title>", 1, true)
    and opf:find("<dc:creator>WeRead</dc:creator>", 1, true)
    and opf:find("<dc:source>https://weread.qq.com/web/reader/", 1, true),
    "single-chapter OPF metadata is wrong")
expect(opf:find('<item id="asset_1" href="images/inline.gif" media-type="image/gif"/>', 1, true)
    and opf:find('<item id="asset_3" href="images/disk-2.png" media-type="image/png"/>', 1, true)
    and opf:find('<itemref idref="chapter"/>', 1, true),
    "single-chapter OPF manifest/spine is wrong")
expect(by_name["OEBPS/nav.xhtml"].data:find(
    '<a href="text/chapter.xhtml">Part?1: &quot;Start&quot;</a>', 1, true),
    "nav does not link the chapter with its escaped title")
expect(by_name["OEBPS/style.css"].data:find("line-height: 1.7", 1, true),
    "default stylesheet was not packaged")
local text = by_name["OEBPS/text/chapter.xhtml"].data
expect(text:find("shell\n<p>real text</p>", 1, true) and not text:find("class=\"x\"", 1, true)
    and text:find('href="../style.css"', 1, true),
    "chapter XHTML did not join the document bodies")
expect(by_name["OEBPS/images/inline.gif"].data == "GIF89a-inline",
    "in-memory asset was not packaged")
expect(by_name["OEBPS/images/disk-1.jpg"].data == "\255\216\255disk-one"
    and by_name["OEBPS/images/disk-2.png"] ~= nil,
    "disk-backed assets were not packaged")
local last_call = archiver.add_path_calls[#archiver.add_path_calls]
expect(#archiver.add_path_calls == 1 and last_call.name == "OEBPS/images"
    and last_call.path == image_dir and last_call.recursive == true,
    "disk-backed assets were not streamed as one directory")
local registered = chapter_book.annotation_documents[chapter_path]
expect(registered and registered.clean == true and registered.chapters[1].chapterUid == 7,
    "single-chapter EPUB was not registered as a clean annotation document")

-- Fallback names and a caller-provided stylesheet.
local untitled_path = Content.save_chapter_epub(settings, { book_id = "single" },
    { chapterUid = 8 }, "<p>plain fragment</p>", nil, "p{}")
local _, untitled = read_epub(untitled_path)
expect(untitled_path == book_dir .. "/WeRead - 8.epub", "untitled chapter name: " .. untitled_path)
expect(untitled["OEBPS/style.css"].data == "p{}"
    and untitled["OEBPS/text/chapter.xhtml"].data:find("<title>WeRead</title>\n", 1, true)
    and untitled["OEBPS/text/chapter.xhtml"].data:find("<p>plain fragment</p>", 1, true),
    "untitled chapter did not fall back to the book title or keep the custom CSS")

-- Invalid file-backed assets are rejected before anything is written.
local ok, err = pcall(Content.save_chapter_epub, settings, { book_id = "bad-assets" },
    { chapterUid = 1, title = "x" }, "", { { href = "images/a.jpg", path = "a.jpg" } })
expect(not ok and tostring(err):find("invalid file-backed asset path", 1, true),
    "asset path without a directory was accepted")
mkdir(root .. "/other")
ok, err = pcall(Content.save_chapter_epub, settings, { book_id = "bad-assets" },
    { chapterUid = 1, title = "x" }, "", {
        { href = "images/a.jpg", path = image_dir .. "/disk-1.jpg" },
        { href = "images/b.jpg", path = root .. "/other/b.jpg" },
    })
expect(not ok and tostring(err):find("share one directory", 1, true),
    "file-backed assets from two directories were accepted")
expect(#list_dir(root .. "/cache/bad-assets") == 0,
    "rejected asset list still produced an EPUB or partial file")

-- Full-book EPUB ----------------------------------------------------------------
local chapters = {
    { chapterUid = 1, title = "Part 1", level = 1 },
    { chapterUid = 2, title = "Ch 1.1", level = 2 },
    { chapterUid = 3, title = "Sec 1.1.1", level = 3 },
    { chapterUid = 4, title = "Ch 1.2", level = 2 },
    { chapterUid = 5, title = "Part 2", level = 1 },
    { chapterUid = 6, title = "Too deep", level = 9 },
    { chapterUid = "7.5", level = 0 },
}
local bodies = {
    ["1"] = "<p>one</p>", ["2"] = "<p>two</p>", ["3"] = "<p>three</p>", ["4"] = "<p>four</p>",
    ["5"] = "<p>five</p>", ["6"] = "<p>six</p>",
}
local full_book = { book_id = "full", title = "Full Book", author = "Ann & Bob",
    intro = "Line <1>\1\nLine 2" }
local cover_png = "\137PNG\r\n\026\ncover-bytes"
local full_path = Content.save_book_epub(settings, full_book, chapters, bodies, nil,
    { { href = "images/pic.jpg", media_type = "image/jpeg", data = "\255\216\255pic" } },
    "body{}", cover_png)
expect(full_path == root .. "/cache/full/Full Book - book.epub",
    "full-book EPUB name did not default its suffix: " .. full_path)
expect(no_leftovers(root .. "/cache/full"), "full-book EPUB left a .part file")
entries, by_name = read_epub(full_path)
local order = {}
for index, entry in ipairs(entries) do order[index] = entry.name end
expect(table.concat(order, ",") == table.concat({
    "mimetype", "META-INF/container.xml", "OEBPS/images/cover.png", "OEBPS/text/cover.xhtml",
    "OEBPS/images/pic.jpg",
    "OEBPS/text/chapter-001.xhtml", "OEBPS/text/chapter-002.xhtml", "OEBPS/text/chapter-003.xhtml",
    "OEBPS/text/chapter-004.xhtml", "OEBPS/text/chapter-005.xhtml", "OEBPS/text/chapter-006.xhtml",
    "OEBPS/text/chapter-007.xhtml",
    "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/style.css",
}, ","), "unexpected full-book entry order: " .. table.concat(order, ","))
expect(entries[1].compression == "store" and entries[2].compression == "deflate",
    "full-book mimetype was not stored uncompressed")
expect(by_name["OEBPS/images/cover.png"].data == cover_png
    and by_name["OEBPS/text/cover.xhtml"].data:find('src="../images/cover.png"', 1, true),
    "cover image or cover page was not packaged")
expect(by_name["OEBPS/text/chapter-003.xhtml"].data:find("<p>three</p>", 1, true)
    and by_name["OEBPS/text/chapter-007.xhtml"].data:find("<title>Chapter 7.5</title>", 1, true)
    and by_name["OEBPS/text/chapter-007.xhtml"].data:find("<body>\n</body>", 1, true),
    "chapter bodies or the missing-body fallback are wrong")

opf = by_name["OEBPS/content.opf"].data
expect(opf:find("<dc:identifier id=\"bookid\">weread-full-book</dc:identifier>", 1, true)
    and opf:find("<dc:creator>Ann &amp; Bob</dc:creator>", 1, true)
    and opf:find("<dc:description>Line &lt;1&gt;\nLine 2</dc:description>", 1, true)
    and opf:find('<meta name="cover" content="cover-image"/>', 1, true)
    and opf:find("<meta property=\"dcterms:modified\">%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ</meta>"),
    "full-book OPF metadata is wrong")
expect(opf:find('<item id="cover-image" href="images/cover.png" media-type="image/png" properties="cover-image"/>', 1, true)
    and opf:find('<item id="asset_1" href="images/pic.jpg" media-type="image/jpeg"/>', 1, true)
    and opf:find('<item id="chapter_7_5" href="text/chapter-007.xhtml" media-type="application/xhtml+xml"/>', 1, true),
    "full-book manifest is wrong")
local spine = opf:match("<spine toc=\"toc\">(.-)</spine>")
local spine_ids = {}
for idref in spine:gmatch('idref="([^"]+)"') do spine_ids[#spine_ids + 1] = idref end
expect(table.concat(spine_ids, ",")
    == "cover,chapter_1,chapter_2,chapter_3,chapter_4,chapter_5,chapter_6,chapter_7_5",
    "spine order is wrong: " .. table.concat(spine_ids, ","))

-- Depth of each TOC entry, from the open/close tags that precede it.
local function toc_depths(doc, open_tag, close_tag, label_pattern)
    local events = {}
    for pos in doc:gmatch("()" .. open_tag) do events[#events + 1] = { pos, 1 } end
    for pos in doc:gmatch("()" .. close_tag) do events[#events + 1] = { pos, -1 } end
    for pos, label in doc:gmatch("()" .. label_pattern) do events[#events + 1] = { pos, 0, label } end
    table.sort(events, function(a, b) return a[1] < b[1] end)
    local depth, out = 0, {}
    for _, event in ipairs(events) do
        if event[3] then out[#out + 1] = event[3] .. "@" .. depth end
        depth = depth + event[2]
    end
    return table.concat(out, ","), depth
end
local nav = by_name["OEBPS/nav.xhtml"].data
local nav_tree, nav_balance = toc_depths(nav, "<ol>", "</ol>", '<a href="[^"]+">([^<]+)</a>')
expect(nav_tree == "Part 1@1,Ch 1.1@2,Sec 1.1.1@3,Ch 1.2@2,Part 2@1,Too deep@2,Chapter 7.5@1"
    and nav_balance == 0, "nav nesting does not follow chapter levels: " .. nav_tree)
expect(nav:find('<a href="text/chapter-004.xhtml">Ch 1.2</a>', 1, true),
    "nav entry does not link its chapter file")
local ncx = by_name["OEBPS/toc.ncx"].data
local ncx_tree, ncx_balance = toc_depths(ncx, "<navPoint ", "</navPoint>",
    "<text>([^<]+)</text></navLabel>")
expect(ncx_tree == "Part 1@1,Ch 1.1@2,Sec 1.1.1@3,Ch 1.2@2,Part 2@1,Too deep@2,Chapter 7.5@1"
    and ncx_balance == 0, "NCX nesting does not follow chapter levels: " .. ncx_tree)
local orders = {}
for play_order in ncx:gmatch('playOrder="(%d+)"') do orders[#orders + 1] = play_order end
expect(table.concat(orders, ",") == "1,2,3,4,5,6,7", "NCX play order is not sequential")
expect(ncx:find('<navPoint id="navPoint-3" playOrder="3">\n<navLabel><text>Sec 1.1.1</text></navLabel>\n<content src="text/chapter-003.xhtml"/>', 1, true)
    and ncx:find('<meta name="dtb:uid" content="weread-full-book"/>', 1, true)
    and ncx:find("<docTitle><text>Full Book</text></docTitle>", 1, true),
    "NCX nav points or head metadata are wrong")
local full_registered = full_book.annotation_documents[full_path]
expect(full_registered and #full_registered.chapters == 7
    and full_registered.chapters[7].chapterUid == "7.5",
    "full-book EPUB was not registered with all chapters")

-- Cover media types are sniffed from the bytes; an empty cover is skipped.
for _, case in ipairs({
    { data = "\255\216\255\224jpeg", href = "images/cover.jpg", mime = "image/jpeg" },
    { data = "GIF87a....", href = "images/cover.gif", mime = "image/gif" },
    { data = "RIFF\0\0\0\0WEBPVP8 ", href = "images/cover.webp", mime = "image/webp" },
    { data = "unknown-bytes", href = "images/cover.bin", mime = "application/octet-stream" },
}) do
    local cover_path = Content.save_book_epub(settings, { book_id = "covers" },
        { { chapterUid = 1, title = "Only" } }, { ["1"] = "x" }, "c", nil, nil, case.data)
    local _, cover_entries = read_epub(cover_path)
    expect(cover_entries["OEBPS/" .. case.href].data == case.data
        and cover_entries["OEBPS/content.opf"].data:find('href="' .. case.href
            .. '" media-type="' .. case.mime .. '"', 1, true),
        "cover media type was not detected: " .. case.mime)
end
local plain_path = Content.save_book_epub(settings, { book_id = "covers" },
    { { chapterUid = 1, title = "Only" } }, { ["1"] = "x" }, "c", nil, nil, "")
local plain_entries, plain = read_epub(plain_path)
expect(plain["OEBPS/text/cover.xhtml"] == nil
    and not plain["OEBPS/content.opf"].data:find("cover-image", 1, true)
    and not plain["OEBPS/content.opf"].data:find('name="cover"', 1, true)
    and not plain["OEBPS/content.opf"].data:find("dc:description", 1, true)
    and plain["OEBPS/content.opf"].data:find("<dc:title>WeRead</dc:title>", 1, true)
    and #plain_entries == 7, "empty cover or missing intro still produced metadata")

-- Resumable full-book jobs stream checkpointed chapters from the workspace.
local ws_text = root .. "/ws/text"
local ws_images = root .. "/ws/images"
mkdir(ws_text)
mkdir(ws_images)
write_raw(ws_text .. "/chapter-001.xhtml", "<html>checkpoint one</html>")
write_raw(ws_text .. "/chapter-002.xhtml", "<html>checkpoint two</html>")
write_raw(ws_images .. "/img.jpg", "\255\216\255img")
archiver.add_path_calls = {}
local ws_path = Content.save_book_epub(settings, { book_id = "ws", title = "WS" },
    { { chapterUid = 1, title = "A" }, { chapterUid = 2, title = "B", level = 2 } },
    { __workspace_text_dir = ws_text }, "full",
    { { href = "images/img.jpg", media_type = "image/jpeg", path = ws_images .. "/img.jpg" } })
local ws_entries, ws = read_epub(ws_path)
expect(ws["OEBPS/text/chapter-001.xhtml"].data == "<html>checkpoint one</html>"
    and ws["OEBPS/text/chapter-002.xhtml"].data == "<html>checkpoint two</html>"
    and ws["OEBPS/images/img.jpg"].data == "\255\216\255img",
    "workspace chapters or images were not streamed from disk")
expect(#archiver.add_path_calls == 2 and archiver.add_path_calls[1].name == "OEBPS/images"
    and archiver.add_path_calls[2].name == "OEBPS/text"
    and archiver.add_path_calls[2].path == ws_text,
    "workspace packaging did not use one directory walk each for images and text")
expect(ws_entries[#ws_entries].name == "OEBPS/text/chapter-002.xhtml"
    and ws["OEBPS/content.opf"].data:find('href="text/chapter-002.xhtml"', 1, true),
    "streamed chapters are not listed in the manifest")

-- Atomic commit -----------------------------------------------------------------
local commit_dir = root .. "/cache/commit"
local function build(tag)
    return Content.save_book_epub(settings, { book_id = "commit", title = "Commit" },
        { { chapterUid = 1, title = tag } }, { ["1"] = "<p>" .. tag .. "</p>" }, "v")
end
local function packaged_tag(path)
    local _, files = read_epub(path)
    return files["OEBPS/text/chapter-001.xhtml"].data:match("<p>(.-)</p>")
end
local commit_path = build("first")
expect(packaged_tag(build("second")) == "second", "rebuilding did not replace the EPUB")

archiver.fail_open = true
ok, err = pcall(build, "never")
archiver.fail_open = false
expect(not ok and tostring(err):find("failed to open archive", 1, true)
    and tostring(err):find("injected open failure", 1, true),
    "archive open failure was not reported")
expect(packaged_tag(commit_path) == "second" and no_leftovers(commit_dir),
    "open failure damaged the previous EPUB")

archiver.fail_memory = "OEBPS/toc.ncx"
ok, err = pcall(build, "never")
archiver.fail_memory = nil
expect(not ok and tostring(err):find("injected memory failure", 1, true),
    "failed entry write was not reported")
expect(packaged_tag(commit_path) == "second" and no_leftovers(commit_dir),
    "failed entry write left a partial EPUB or replaced the old one")

archiver.fail_path = "injected walk failure"
ok, err = pcall(Content.save_book_epub, settings, { book_id = "commit", title = "Commit" },
    { { chapterUid = 1, title = "x" } }, { __workspace_text_dir = ws_text }, "v")
archiver.fail_path = nil
expect(not ok and tostring(err):find("injected walk failure", 1, true)
    and packaged_tag(commit_path) == "second" and no_leftovers(commit_dir),
    "directory walk failure did not abort the commit")

-- Storage where rename() does not replace an existing file: the old EPUB is
-- moved aside, the new one committed, and the backup dropped.
local original_rename = os.rename
local rename_mode
local function fake_rename(from, to)
    local is_part = from:sub(-5) == ".part"
    if rename_mode == "no_replace" or rename_mode == "part_fails" or rename_mode == "all_fail" then
        if is_part and (exists(to) or rename_mode ~= "no_replace") then
            return nil, "rename refused: " .. to
        end
        if rename_mode == "all_fail" then return nil, "rename refused: " .. to end
    end
    return original_rename(from, to)
end
-- luacheck: push ignore 122
os.rename = fake_rename
rename_mode = "no_replace"
local replaced = build("third")
rename_mode = "part_fails"
local fail_ok, fail_err = pcall(build, "fourth")
rename_mode = "all_fail"
local backup_ok, backup_err = pcall(build, "fifth")
rename_mode = "part_fails"
local fresh_ok, fresh_err = pcall(Content.save_book_epub, settings,
    { book_id = "fresh", title = "Fresh" }, { { chapterUid = 1, title = "x" } }, {}, "v")
os.rename = original_rename
-- luacheck: pop
expect(replaced == commit_path and packaged_tag(commit_path) == "third",
    "EPUB was not replaced via a backup when rename cannot overwrite")
expect(not fail_ok and tostring(fail_err):find("rename refused", 1, true)
    and packaged_tag(commit_path) == "third",
    "failed commit did not restore the previous EPUB")
expect(not backup_ok and tostring(backup_err):find("rename refused", 1, true)
    and packaged_tag(commit_path) == "third",
    "failed backup rename did not keep the previous EPUB")
expect(no_leftovers(commit_dir), "failed commits left .part or backup files")
expect(not fresh_ok and tostring(fresh_err):find("rename refused", 1, true)
    and #list_dir(root .. "/cache/fresh") == 0,
    "a first-time commit failure left a partial file")

-- Image source rewriting --------------------------------------------------------
local xhtml = [[<img src="https://cdn/x/a.jpg?w=1&amp;h=2"/><img src='b.png#frag'/><img src="c.gif"/>]]
expect(Content.rewrite_image_sources(xhtml, nil) == xhtml
    and Content.rewrite_image_sources(xhtml, {}) == xhtml,
    "an empty source map changed the chapter")
expect(Content.rewrite_image_sources(xhtml, { ["a.jpg"] = "../images/a.jpg",
    ["b.png"] = "../images/b-2.png" })
    == [[<img src="../images/a.jpg"/><img src='../images/b-2.png'/><img src="c.gif"/>]],
    "image sources were not rewritten by basename")

-- All output formats must preserve a user-selected literal directory.
local literal_settings = { cache_dir = root .. "/reader's $WEREAD_LITERAL_DIRECTORY with spaces" }
local literal_chapter = { chapterUid = 1, title = "One" }
local literal_single = Content.save_chapter_epub(literal_settings,
    { book_id = "literal-single", title = "Literal" }, literal_chapter, "<p>one</p>")
local literal_full_book = { book_id = "literal-full", title = "Literal" }
local literal_full = Content.save_book_epub(literal_settings, literal_full_book,
    { literal_chapter }, { ["1"] = "<p>one</p>" }, "full")
local literal_article = Content.save_mp_article_html(literal_settings,
    { book_id = "literal-article" }, { title = "Article" }, "<p>article</p>")
for _, path in ipairs({ literal_single, literal_full, literal_article }) do
    expect(path:sub(1, #literal_settings.cache_dir + 1) == literal_settings.cache_dir .. "/" and exists(path),
        "an output format did not preserve the literal directory: " .. path)
end
local literal_full_data = read_file(literal_full)
archiver.fail_memory = "OEBPS/toc.ncx"
local literal_ok = pcall(Content.save_book_epub, literal_settings, literal_full_book,
    { literal_chapter }, { ["1"] = "<p>replacement</p>" }, "full")
archiver.fail_memory = nil
expect(not literal_ok and read_file(literal_full) == literal_full_data
        and no_leftovers(literal_full_book.cache_dir),
    "failed literal-directory EPUB save damaged the old book or left temporary files")

assert(os.execute("rm -rf " .. quoted(root)))
print(("content_epub_packaging_spec: %d checks"):format(checks))
