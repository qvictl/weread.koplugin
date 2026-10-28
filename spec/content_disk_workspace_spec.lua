-- Disk-side behaviour of weread.lib.content: book directory resolution, the
-- catalog cache, full-book resume checkpoints, download workspaces and
-- startup recovery. Everything runs against a real temporary directory.
-- Run with: luajit spec/content_disk_workspace_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local warnings = {}
package.preload["logger"] = function()
    return {
        dbg = function() end,
        info = function() end,
        err = function() end,
        warn = function(...)
            warnings[#warnings + 1] = table.concat({ ... }, " ", 2)
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end
local store_puts, store_fails = {}, false
package.preload["weread.lib.annotation_source"] = function()
    return {
        plain = function(text) return "plain:" .. text end,
        index = function(html) return "index:" .. html end,
    }
end
package.preload["weread.lib.annotation_store"] = function()
    return {
        new = function(_self, store_settings)
            return {
                put = function(_store, book_id, kind, key, value, uid)
                    if store_fails then error("database is locked") end
                    store_puts[#store_puts + 1] = { settings = store_settings, book_id = book_id,
                        kind = kind, key = key, value = value, uid = uid }
                end,
            }
        end,
    }
end

-- KOReader's util.makePath; nil makes content.lua fall back to `mkdir -p`.
local util_stub = {}
package.preload["util"] = function() return util_stub end

local ffi_util_stub = {}
local function purge_dir(path)
    return os.execute("rm -rf " .. string.format("%q", path))
end
ffi_util_stub.purgeDir = purge_dir
package.preload["ffi/util"] = function() return ffi_util_stub end

local function quoted(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
local lfs_reports_times = true
local function lfs_stub()
    return {
        attributes = function(path, attribute)
            if attribute == "modification" then
                if not lfs_reports_times then return nil end
                local probe = io.popen("stat -c %Y " .. quoted(path) .. " 2>/dev/null")
                local value = tonumber(probe:read("*l") or "")
                probe:close()
                return value
            end
            local probe = io.popen("test -d " .. quoted(path)
                .. " && echo directory || (test -f " .. quoted(path) .. " && echo file)")
            local mode = probe:read("*l")
            probe:close()
            if attribute == "mode" then return mode end
            return mode and { mode = mode } or nil
        end,
        dir = function(path)
            local listing = io.popen("ls -a " .. quoted(path))
            return function()
                local name = listing:read("*l")
                if not name then listing:close() end
                return name
            end
        end,
    }
end
package.preload["lfs"] = lfs_stub

local Content = require("weread.lib.content")

-- Minimal JSON-like codec for the fake client: a Lua table literal that
-- decodes in an empty environment and raises on malformed input.
local function serialize(value)
    local kind = type(value)
    if kind == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = "[" .. serialize(key) .. "]=" .. serialize(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif kind == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end
local client = {
    encoded = 0,
    json_encode = function(self, data)
        self.encoded = self.encoded + 1
        if self.fail_encode then error("cannot encode catalog") end
        return serialize(data)
    end,
    json_decode = function(_self, text)
        local chunk = assert(loadstring("return " .. text))
        setfenv(chunk, {})
        return chunk()
    end,
}

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
local function is_dir(path)
    return os.execute("test -d " .. quoted(path)) == 0
        or os.execute("test -d " .. quoted(path)) == true
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
local function has_part_file(path)
    for _, name in ipairs(list_dir(path)) do
        if name:match("%.part$") then return true end
    end
    return false
end

local root = os.tmpname()
os.remove(root)
mkdir(root)
local settings = { cache_dir = root .. "/cache" }

-- Book directory resolution ---------------------------------------------------
expect(Content.book_dir_name("CB_1/../x y") == "CB_1_.._x_y",
    "book dir name kept path separators or spaces")
expect(Content.book_dir_name(nil) == "weread" and Content.book_dir_name("") == "weread",
    "empty book id did not fall back to a stable directory name")
expect(Content.book_cache_dir(settings, "b:1") == root .. "/cache/b_1",
    "book cache dir was not built under settings.cache_dir")
expect(Content.book_resolved_dir(settings, "b1", { cache_dir = "/media/old/b1" })
    == "/media/old/b1", "explicit book.cache_dir did not win")
expect(Content.book_resolved_dir(settings, "b1", {
    cache_dir = "", cached_full_book = "/old/full/b1/Book - full.epub",
    cached_file = "/old/single/b1/Book - one.epub",
}) == "/old/full/b1", "full-book path was not preferred over the single chapter file")
expect(Content.book_resolved_dir(settings, "b1", { cached_file = "/old/b1/one.epub" })
    == "/old/b1", "cached_file directory was not used")
expect(Content.book_resolved_dir(settings, "b1",
    { cached_chapters = { [3] = "/moved/b1/three.epub" } }) == "/moved/b1",
    "cached chapter path directory was not used")
expect(Content.book_resolved_dir(settings, "b1",
    { cached_chapters = { [3] = "relative.epub" } }) == root .. "/cache/b1",
    "a path without a directory did not fall back to the current cache root")
expect(Content.book_resolved_dir(settings, "b1", nil) == root .. "/cache/b1",
    "a missing book record did not fall back to the current cache root")

-- Catalog cache ---------------------------------------------------------------
expect(Content.catalog_cache_path(settings, {}) == nil
    and Content.catalog_cache_path(settings, nil) == nil,
    "catalog cache path invented a location for a book without an id")
expect(Content.catalog_cache_path(settings, { bookId = "camel" })
    == root .. "/cache/camel/catalog.json", "bookId records did not get a catalog path")

local ok, err = Content.save_catalog_cache(client, settings, { book_id = "c1" }, "nope")
expect(ok == false and err:find("not a table", 1, true), "non-table catalog was accepted")
ok, err = Content.save_catalog_cache(client, settings, { title = "no id" }, {})
expect(ok == false and err:find("missing book id", 1, true), "catalog saved without a book id")

local catalog = {
    { chapterUid = 1, title = "封面", wordCount = 0 },
    { chapterUid = 2, title = "One & <Two>", wordCount = 1200, level = 1 },
}
local cat_book = { book_id = "cat-book" }
local saved, saved_path = Content.save_catalog_cache(client, settings, cat_book, catalog)
expect(saved == true and saved_path == root .. "/cache/cat-book/catalog.json",
    "catalog cache was not saved to the book directory")
expect(cat_book.cache_dir == root .. "/cache/cat-book",
    "saving the catalog did not pin the real book directory")
expect(not exists(saved_path .. ".tmp"), "catalog save left its temporary file")
local reload_book = { book_id = "cat-book" }
local loaded = Content.load_catalog_cache(client, settings, reload_book)
expect(type(loaded) == "table" and #loaded == 2 and loaded[2].title == "One & <Two>"
    and loaded[2].wordCount == 1200, "catalog cache did not round-trip")
expect(reload_book.chapters == loaded, "loaded catalog was not attached to the book")

-- A catalog saved after the cache root moved still loads via book.cache_dir.
local moved_settings = { cache_dir = root .. "/elsewhere" }
expect(Content.load_catalog_cache(client, moved_settings,
    { book_id = "cat-book", cache_dir = cat_book.cache_dir })[2].chapterUid == 2,
    "catalog cache was not found after the cache root changed")
expect(Content.load_catalog_cache(client, moved_settings, { book_id = "cat-book" }) == nil,
    "catalog cache appeared under a root it was never written to")
expect(Content.load_catalog_cache(client, settings, { title = "no id" }) == nil,
    "catalog loaded for a book without an id")

write_raw(saved_path, "{{{ not a catalog")
warnings = {}
local corrupt_book = { book_id = "cat-book" }
expect(Content.load_catalog_cache(client, settings, corrupt_book) == nil
    and corrupt_book.chapters == nil, "corrupt catalog cache was returned")
expect(warnings[1] and warnings[1]:find("invalid catalog cache", 1, true),
    "corrupt catalog cache was not logged")
write_raw(saved_path, "42")
expect(Content.load_catalog_cache(client, settings, { book_id = "cat-book" }) == nil,
    "non-table catalog cache was returned")
write_raw(saved_path, "{version=1}")
expect(Content.load_catalog_cache(client, settings, { book_id = "cat-book" }) == nil,
    "catalog cache without chapters was returned")

client.fail_encode = true
ok, err = Content.save_catalog_cache(client, settings, { book_id = "enc" }, {})
client.fail_encode = false
expect(ok == false and tostring(err):find("cannot encode catalog", 1, true),
    "encoder failure was not reported")

-- The temporary file cannot be created: nothing is written, error returned.
mkdir(root .. "/cache/tmp-blocked/catalog.json.tmp")
local blocked_book = { book_id = "tmp-blocked" }
ok, err = Content.save_catalog_cache(client, settings, blocked_book, catalog)
expect(ok == false and err ~= nil and blocked_book.cache_dir == nil,
    "catalog save succeeded although its temporary file could not be opened")

-- The rename onto the final name fails: the temporary file is removed.
mkdir(root .. "/cache/rename-blocked/catalog.json")
write_raw(root .. "/cache/rename-blocked/catalog.json/keep", "x")
local rename_book = { book_id = "rename-blocked" }
ok, err = Content.save_catalog_cache(client, settings, rename_book, catalog)
expect(ok == false and err ~= nil and rename_book.cache_dir == nil,
    "catalog save reported success although the commit rename failed")
expect(not exists(root .. "/cache/rename-blocked/catalog.json.tmp"),
    "failed catalog commit left its temporary file")

-- A short write (disk full) is reported and the temporary file removed.
local original_open = io.open
-- luacheck: push ignore 122
io.open = function(path, mode) -- luacheck: ignore 122
    local file, open_err = original_open(path, mode)
    if not file or path:sub(-4) ~= ".tmp" then return file, open_err end
    return {
        write = function() return nil, "No space left on device" end,
        close = function() return file:close() end,
    }
end
ok, err = Content.save_catalog_cache(client, settings, { book_id = "full-disk" }, catalog)
io.open = original_open
-- luacheck: pop
expect(ok == false and err == "No space left on device",
    "short catalog write was not reported")
expect(not exists(root .. "/cache/full-disk/catalog.json.tmp")
    and not exists(root .. "/cache/full-disk/catalog.json"),
    "short catalog write left a temporary or final file")

-- Legal user directory names must be passed literally to the filesystem.
local literal_settings = { cache_dir = root .. "/reader's $WEREAD_LITERAL_DIRECTORY with spaces" }
local literal_book = { book_id = "literal-catalog" }
ok, err = Content.save_catalog_cache(client, literal_settings, literal_book, catalog)
expect(ok, "catalog save did not preserve the literal directory: " .. tostring(err))
local literal_catalog = literal_settings.cache_dir .. "/literal-catalog/catalog.json"
local literal_saved = read_file(literal_catalog)
expect(literal_saved and literal_book.cache_dir == literal_settings.cache_dir .. "/literal-catalog",
    "catalog was saved outside the requested literal directory")
client.fail_encode = true
local literal_ok = Content.save_catalog_cache(client, literal_settings, literal_book, catalog)
client.fail_encode = false
expect(not literal_ok and read_file(literal_catalog) == literal_saved
        and not exists(literal_catalog .. ".tmp"),
    "failed catalog save damaged the literal directory or left a temporary file")

-- Catalog helpers -------------------------------------------------------------
local updated = { { chapterUid = 9 } }
expect(Content.normalize_chapters({ data = { { bookId = "x", updated = {} },
    { bookId = 42, updated = updated } } }, "42") == updated,
    "catalog records were not matched by book id across types")
local infos = { { chapterUid = 1 } }
expect(Content.normalize_chapters({ bookId = "solo", chapterInfos = infos }, "solo") == infos,
    "single catalog record was not unwrapped")
expect(#Content.normalize_chapters({ data = { { bookId = "other", chapters = infos } } }, "x") == 0,
    "catalog of another book was returned")
expect(#Content.normalize_chapters("broken", "x") == 0
    and #Content.normalize_chapters({ data = "broken" }, "x") == 0,
    "malformed catalog payload was not treated as empty")
expect(#Content.normalize_chapters({ { bookId = "x" } }, "x") == 0,
    "record without chapter fields did not yield an empty catalog")
local readable = Content.readable_chapters(catalog)
expect(#readable == 1 and readable[1].chapterUid == 2,
    "cover or empty chapters were treated as readable")
expect(#Content.readable_chapters(nil) == 0, "nil catalog was not empty")
expect(Content.first_readable_chapter(catalog).chapterUid == 2,
    "first readable chapter skipped past the first real chapter")
expect(Content.first_readable_chapter({ { title = "封面", wordCount = 9 } }) == nil
    and Content.first_readable_chapter(nil) == nil,
    "a cover-only catalog produced a readable chapter")

-- Full-book workspace and checkpoints -------------------------------------------
local made = {}
util_stub.makePath = function(path)
    made[#made + 1] = path
    -- LuaJIT returns 0 or true (Lua 5.2 compatible builds) on success.
    local status = os.execute("mkdir -p " .. quoted(path))
    return (status == 0 or status == true) or nil
end
local book = { book_id = "full-book" }
local workspace = Content.open_full_download_workspace(settings, book)
util_stub.makePath = nil
local base = root .. "/cache/full-book/.weread-download-resume-full"
expect(workspace.path == base and workspace.resumable == true,
    "full-book workspace was not the stable resumable directory")
expect(book.cache_dir == root .. "/cache/full-book", "workspace did not pin the book dir")
for _, key in ipairs({ "incoming_dir", "asset_dir", "text_dir", "checkpoint_dir",
        "rendered_text_dir" }) do
    expect(is_dir(workspace[key]), "workspace directory was not created: " .. key)
end
expect(#made == 6 and made[1] == book.cache_dir,
    "workspace directories were not created through util.makePath")
local reopened = Content.open_full_download_workspace(settings, { book_id = "full-book" })
expect(reopened.text_dir == workspace.text_dir, "reopening the workspace moved it")
local literal_workspace = Content.open_full_download_workspace(literal_settings, { book_id = "literal-workspace" })
expect(literal_workspace.path:sub(1, #literal_settings.cache_dir + 1) == literal_settings.cache_dir .. "/"
        and is_dir(literal_workspace.incoming_dir) and is_dir(literal_workspace.rendered_text_dir),
    "fallback workspace creation did not preserve the literal directory")

util_stub.makePath = function() return nil, "read-only file system" end
ok, err = pcall(Content.open_full_download_workspace, settings, { book_id = "ro" })
expect(not ok and tostring(err):find("read-only file system", 1, true),
    "util.makePath failure was not raised")
util_stub.makePath = function() return false end
ok, err = pcall(Content.open_full_download_workspace, settings, { book_id = "ro" })
util_stub.makePath = nil
expect(not ok and tostring(err):find("could not create directory", 1, true),
    "util.makePath failure without a message was not raised")

expect(Content.full_download_chapter_path(nil, {}, 1) == nil
    and Content.full_download_checkpoint_path({}, {}, 1) == nil
    and Content.full_download_rendered_chapter_path({ text_dir = "x" }, {}, 1) == nil,
    "chapter paths were invented for an incomplete workspace")
expect(Content.full_download_chapter_path(workspace, {}, 7) == workspace.text_dir
    .. "/chapter-007.xhtml", "chapter checkpoint name is not zero-padded by index")
expect(Content.full_download_checkpoint_path(workspace, {}, "x") == workspace.checkpoint_dir
    .. "/chapter-000.xhtml.meta", "non-numeric chapter index was not normalized")

local chapters = {
    { chapterUid = 101, title = "First & <Best>" },
    { chapterUid = "uid/2" },
    { chapterUid = 103, title = "Third" },
}
local first_path = Content.save_full_download_chapter(workspace, chapters[1], 1,
    "<html><body>shell</body></html><html><body><p>first body</p></body></html>")
expect(first_path == workspace.text_dir .. "/chapter-001.xhtml",
    "checkpoint was saved somewhere else")
local first_xhtml = read_file(first_path)
expect(first_xhtml:find("<!-- weread-chapter-uid: 101 -->", 1, true)
    and first_xhtml:find("<title>First &amp; &lt;Best&gt;</title>", 1, true)
    and first_xhtml:find("shell\n<p>first body</p>", 1, true)
    and first_xhtml:sub(-7) == "</html>",
    "checkpoint XHTML lacks its marker, escaped title, joined bodies or closing tag")
local meta = read_file(Content.full_download_checkpoint_path(workspace, chapters[1], 1))
expect(meta == "uid=101\nlength=" .. #first_xhtml .. "\nsha256="
    .. require("weread.lib.crypto").sha256_hex(first_xhtml) .. "\n",
    "checkpoint metadata did not record uid, length and digest")
expect(read_file(workspace.checkpoint_dir .. "/last-written") == "index=1\n",
    "the chapter being written was not recorded first")
Content.save_full_download_chapter(workspace, chapters[2], 2, "<p>second</p>")
Content.save_full_download_chapter(workspace, chapters[3], 3, "<p>third</p>")
expect(read_file(workspace.text_dir .. "/chapter-002.xhtml"):find("<title>Chapter uid/2</title>", 1, true)
    and read_file(Content.full_download_checkpoint_path(workspace, chapters[2], 2)):find("^uid=uid_2\n"),
    "untitled chapter did not get a fallback title and a sanitized uid")
expect(not has_part_file(workspace.text_dir) and not has_part_file(workspace.checkpoint_dir),
    "atomic checkpoint writes left .part files behind")
for index = 1, 3 do
    expect(Content.full_download_chapter_exists(workspace, chapters[index], index)
        and Content.full_download_chapter_exists(workspace, chapters[index], index, true),
        "fresh checkpoint was not accepted: " .. index)
end
expect(not Content.full_download_chapter_exists(workspace, { chapterUid = 999 }, 1, true),
    "checkpoint of another chapter at the same index was accepted")
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 9),
    "missing checkpoint was accepted")
expect(Content.load_full_download_chapter(workspace, chapters[1], 1) == first_xhtml,
    "checkpoint did not load back unchanged")
local missing, missing_err = Content.load_full_download_chapter(nil, chapters[1], 1)
expect(missing == nil and missing_err:find("missing", 1, true),
    "loading without a workspace did not fail")
missing, missing_err = Content.load_full_download_chapter(workspace, chapters[1], 8)
expect(missing == nil and missing_err ~= nil, "loading an absent checkpoint did not fail")

-- Same-length corruption passes the cheap probe but not the digest check.
local corrupted = first_xhtml:gsub("first body", "FIRST BODY")
write_raw(first_path, corrupted)
expect(Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "cheap probe should only check size, marker and closing tag")
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1, true),
    "digest verification accepted a corrupted checkpoint")
-- Truncation is caught by the cheap probe too.
write_raw(first_path, first_xhtml:sub(1, -8))
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "truncated checkpoint passed the cheap probe")
-- Metadata without a digest line is not a checkpoint.
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first body</p>")
local meta_path = Content.full_download_checkpoint_path(workspace, chapters[1], 1)
write_raw(meta_path, read_file(meta_path):gsub("sha256=[^\n]*\n", ""))
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "checkpoint metadata without a digest was accepted")
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first body</p>")
os.remove(first_path)
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1, true),
    "metadata without its chapter file was accepted")
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first body</p>")

-- Only recently written checkpoints are hashed on resume.
local function age(index, seconds)
    assert(os.execute(("touch -d @%d %q"):format(os.time() - seconds,
        Content.full_download_checkpoint_path(workspace, chapters[index], index))))
end
local function corrupt_same_length(index)
    local path = Content.full_download_chapter_path(workspace, chapters[index], index)
    local data = read_file(path)
    local swapped = data:gsub("<body>\n", "<body> ", 1)
    assert(#swapped == #data and swapped ~= data)
    write_raw(path, swapped)
end
age(1, 7200)
age(2, 7200)
write_raw(workspace.checkpoint_dir .. "/last-written", "index=3\n")
corrupt_same_length(1)
corrupt_same_length(3)
local completed = Content.full_download_completed_chapters(workspace, chapters)
expect(completed[1] and completed[2] and not completed[3],
    "resume did not digest-check exactly the recently written chapter")
-- The chapter recorded as last written is hashed even when its file is old.
write_raw(workspace.checkpoint_dir .. "/last-written", "index=1\n")
age(3, 7200)
completed = Content.full_download_completed_chapters(workspace, chapters)
expect(not completed[1] and completed[2], "last-written chapter was not digest-checked")
-- Without file times or a last-written record every chapter is hashed.
os.remove(workspace.checkpoint_dir .. "/last-written")
lfs_reports_times = false
Content.save_full_download_chapter(workspace, chapters[3], 3, "<p>third</p>")
os.remove(workspace.checkpoint_dir .. "/last-written")
completed = Content.full_download_completed_chapters(workspace, chapters)
lfs_reports_times = true
expect(not completed[1] and completed[2] and completed[3],
    "unknown write order did not fall back to verifying every digest")
expect(next(Content.full_download_completed_chapters(workspace, nil)) == nil,
    "a nil catalog produced completed chapters")

-- A failed commit rename leaves no .part file and raises.
local blocked = Content.full_download_chapter_path(workspace, {}, 5)
mkdir(blocked)
write_raw(blocked .. "/occupied", "x")
ok, err = pcall(Content.save_full_download_chapter, workspace, { chapterUid = 5 }, 5, "<p>x</p>")
expect(not ok and err ~= nil, "checkpoint commit onto a directory did not fail")
expect(not has_part_file(workspace.text_dir), "failed checkpoint commit left a .part file")
expect(not exists(Content.full_download_checkpoint_path(workspace, {}, 5)),
    "metadata was written for a chapter whose text failed to commit")
local no_path, no_path_err = Content.save_full_download_chapter(nil, chapters[1], 1, "x")
expect(no_path == nil and no_path_err:find("missing", 1, true),
    "saving without a workspace did not report the missing workspace")

-- Stylesheet checkpoint.
expect(Content.save_full_download_css(nil, "x") == nil
    and Content.load_full_download_css(nil) == nil,
    "stylesheet checkpoint used a missing workspace")
expect(Content.save_full_download_css(workspace, nil) == true
    and Content.load_full_download_css(workspace) == "",
    "nil stylesheet was not checkpointed as empty")
Content.save_full_download_css(workspace, "p{margin:0}")
expect(Content.load_full_download_css(workspace) == "p{margin:0}"
    and not exists(workspace.path .. "/style.css.part"),
    "stylesheet checkpoint did not round-trip atomically")
expect(Content.load_full_download_css({ path = root .. "/no-such" }) == nil,
    "missing stylesheet checkpoint was not nil")

-- Rendered (footnote-processed) chapters.
expect(not Content.full_download_rendered_chapter_exists(workspace, chapters[1], 1),
    "rendered chapter reported before it was written")
local rendered_path = Content.save_full_download_rendered_chapter(workspace, chapters[1], 1,
    "<p>rendered</p>")
expect(rendered_path == workspace.rendered_text_dir .. "/chapter-001.xhtml"
    and Content.full_download_rendered_chapter_exists(workspace, chapters[1], 1),
    "rendered chapter was not saved")
expect(not Content.full_download_rendered_chapter_exists(workspace, chapters[2], 1),
    "rendered chapter accepted for a different chapter uid")
ok, err = pcall(Content.save_full_download_rendered_chapter, {}, chapters[1], 1, "x")
expect(not ok and tostring(err):find("rendered workspace", 1, true),
    "rendered chapter saved without a workspace")
ok, err = pcall(Content.reset_full_download_rendered_text, {})
expect(not ok and tostring(err):find("rendered workspace", 1, true),
    "reset accepted a workspace without a rendered dir")
ffi_util_stub.purgeDir = nil
ok, err = pcall(Content.reset_full_download_rendered_text, workspace)
ffi_util_stub.purgeDir = purge_dir
expect(not ok and tostring(err):find("cleanup unavailable", 1, true)
    and exists(rendered_path), "reset without purgeDir did not fail safely")
ok, err = pcall(Content.reset_full_download_rendered_text,
    { rendered_text_dir = root .. "/cache/full-book/rendered-text" })
expect(not ok and tostring(err):find("refusing", 1, true),
    "reset removed a directory outside the resume workspace")
expect(Content.reset_full_download_rendered_text(workspace) == true
    and is_dir(workspace.rendered_text_dir) and #list_dir(workspace.rendered_text_dir) == 0,
    "rendered workspace was not emptied and recreated")
expect(Content.full_download_chapter_exists(workspace, chapters[2], 2, true),
    "resetting rendered text touched the pristine checkpoints")

-- Workspace images ------------------------------------------------------------
write_raw(workspace.asset_dir .. "/b.png", "\137PNG\r\n\026\n0000")
write_raw(workspace.asset_dir .. "/a.jpg", "\255\216\255\224jpeg")
write_raw(workspace.asset_dir .. "/C.GIF", "GIF89a....")
write_raw(workspace.asset_dir .. "/d.webp", "RIFF\0\0\0\0WEBPVP8 ")
write_raw(workspace.asset_dir .. "/old.gif", "GIF87a")
write_raw(workspace.asset_dir .. "/notes.txt", "plain text")
write_raw(workspace.asset_dir .. "/empty.png", "")
mkdir(workspace.asset_dir .. "/nested.png")
local assets = Content.full_download_workspace_assets(workspace)
local hrefs, types = {}, {}
for index, asset in ipairs(assets) do
    hrefs[index] = asset.href
    types[asset.href] = asset.media_type
    expect(asset.path == workspace.asset_dir .. "/" .. asset.href:sub(8),
        "workspace asset path does not point at its file")
end
expect(table.concat(hrefs, ",") == "images/C.GIF,images/a.jpg,images/b.png,images/d.webp,images/old.gif",
    "workspace assets were not the sorted image files: " .. table.concat(hrefs, ","))
expect(types["images/a.jpg"] == "image/jpeg" and types["images/b.png"] == "image/png"
    and types["images/C.GIF"] == "image/gif" and types["images/d.webp"] == "image/webp"
    and types["images/old.gif"] == "image/gif",
    "workspace asset media types were not sniffed from content")
local used = Content.full_download_workspace_used_asset_names(workspace)
expect(used["c.gif"] and used["a.jpg"] and not used["C.GIF"] and not used["notes.txt"],
    "used asset names were not the lowercased image names")
expect(Content._unique_asset_name({}, "  ", ".jpg") == "weread.jpg",
    "a blank asset name did not get a usable fallback")
expect(Content._unique_asset_name(used, "c", ".gif") == "c-2.gif",
    "a resumed download could reuse an image name already on disk")
expect(#Content.full_download_workspace_assets(nil) == 0
    and #Content.full_download_workspace_assets({ asset_dir = root .. "/absent" }) == 0,
    "assets were listed for a missing image directory")

-- Per-job download workspaces -------------------------------------------------
local job_book = { bookId = "job-book" }
local job = Content.create_download_workspace(settings, job_book)
expect(job.path:match("^" .. (root .. "/cache/job-book"):gsub("%p", "%%%0")
    .. "/%.weread%-download%-%d+%-%d+$"), "job workspace name is not timestamped: " .. job.path)
expect(is_dir(job.incoming_dir) and is_dir(job.asset_dir)
    and job_book.cache_dir == root .. "/cache/job-book",
    "job workspace directories were not created")
-- `mkdir -p` prints "Not a directory" to stderr here; that is expected.
local file_blocker = root .. "/blocker"
write_raw(file_blocker, "file")
ok, err = pcall(Content.create_download_workspace, { cache_dir = file_blocker }, { book_id = "x" })
expect(not ok and tostring(err):find("could not create directory", 1, true),
    "workspace creation under a regular file did not fail")

-- A preparation failure after the first subdirectory exists must not leave
-- untracked staging behind for a book that has never been persisted.
local failed_workspace
util_stub.makePath = function(path)
    if path:match("/images$") then return nil, "injected image directory failure" end
    mkdir(path)
    failed_workspace = path:match("^(.*)/incoming$") or failed_workspace
    return true
end
ok, err = pcall(Content.create_download_workspace, settings, { book_id = "failed-stage" })
util_stub.makePath = nil
expect(not ok and tostring(err):find("injected image directory failure", 1, true)
    and failed_workspace and not exists(failed_workspace), "partial workspace preparation was not cleaned")

expect(Content.cleanup_download_workspace(nil) == true,
    "cleaning up no workspace was not a no-op")
local outside = root .. "/precious"
mkdir(outside)
warnings = {}
local cleaned, clean_err = Content.cleanup_download_workspace(outside)
expect(cleaned == nil and clean_err:find("refusing", 1, true) and is_dir(outside),
    "cleanup removed a directory that is not a download workspace")
expect(warnings[1] and warnings[1]:find("cleanup failed", 1, true),
    "refused cleanup was not logged")
ffi_util_stub.purgeDir = function() error("purge crashed") end
cleaned, clean_err = Content.cleanup_download_workspace(job)
expect(cleaned == nil and tostring(clean_err):find("purge crashed", 1, true),
    "a throwing purgeDir was not reported")
ffi_util_stub.purgeDir = function() return false, "device busy" end
cleaned, clean_err = Content.cleanup_download_workspace(job.path)
expect(cleaned == nil and clean_err == "device busy" and is_dir(job.path),
    "purgeDir failure was not reported")
ffi_util_stub.purgeDir = purge_dir
expect(Content.cleanup_download_workspace(job) == true and not is_dir(job.path),
    "job workspace was not removed")

-- Worker catalog publication preserves the old destination until commit.
local catalog_book = { book_id = "staged-catalog" }
local catalog_client = { json_encode = function() return "new catalog bytes" end }
local catalog_workspace = Content.create_download_workspace(settings, catalog_book)
local destination = Content.catalog_cache_path(settings, catalog_book)
write_raw(destination, "old catalog bytes")
local staged = { book_id = catalog_book.book_id, cache_dir = catalog_workspace.path }
expect(Content.save_catalog_cache(catalog_client, settings, staged, {}) == true,
    "worker could not stage catalog")
local staged_path = Content.catalog_cache_path(settings, staged)
expect(read_file(destination) == "old catalog bytes", "staging overwrote published catalog")
local rename = os.rename
os.rename = function() return nil, "injected rename failure" end -- luacheck: ignore 122
local committed, commit_err = Content.commit_catalog_cache(settings, catalog_book, staged_path)
os.rename = rename -- luacheck: ignore 122
expect(not committed and commit_err == "injected rename failure"
    and read_file(destination) == "old catalog bytes", "failed commit lost published catalog")
expect(Content.commit_catalog_cache(settings, catalog_book, staged_path) == true
    and read_file(destination) == "new catalog bytes" and not exists(staged_path),
    "successful commit did not publish staged bytes")
expect(Content.commit_catalog_cache(settings, {}, staged_path) == false, "missing book id was accepted")
local open = io.open
io.open = function(path, mode) -- luacheck: ignore 122
    if path == destination .. ".tmp" and mode == "wb" then
        return { write = function() return true end, close = function() return nil, "close failure" end }
    end
    return open(path, mode)
end
local close_ok, close_err = Content.save_catalog_cache(catalog_client, settings, catalog_book, {})
io.open = open -- luacheck: ignore 122
expect(not close_ok and close_err == "close failure" and read_file(destination) == "new catalog bytes"
    and not exists(destination .. ".tmp"), "close failure published or left temporary catalog")
expect(Content.cleanup_download_workspace(catalog_workspace) == true, "catalog stage cleanup failed")

-- Startup recovery ------------------------------------------------------------
local dir_a = root .. "/recover-a"
local dir_b = root .. "/recover-b"
mkdir(dir_a .. "/.weread-download-1700000000-123456/images")
mkdir(dir_a .. "/.weread-download-resume-full/text")
mkdir(dir_b .. "/.weread-download-1700000001-654321")
mkdir(dir_b .. "/.weread-download-notanumber-1")
write_raw(dir_a .. "/Book - full.epub.part", "partial")
write_raw(dir_a .. "/Kept.epub", "new")
write_raw(dir_a .. "/Kept.epub.weread-backup", "old")
write_raw(dir_a .. "/Restored.epub.weread-backup", "only copy")
write_raw(dir_a .. "/Book - one.epub", "final")
write_raw(dir_b .. "/catalog.json", "{}")
local removed = Content.cleanup_stale_downloads({
    get_book_dirs = function()
        return { a = dir_a, a_again = dir_a, b = dir_b, gone = root .. "/does-not-exist" }
    end,
})
expect(removed == 5, "unexpected stale download recovery count: " .. tostring(removed))
expect(not is_dir(dir_a .. "/.weread-download-1700000000-123456")
    and not is_dir(dir_b .. "/.weread-download-1700000001-654321"),
    "interrupted job workspaces were not removed")
expect(is_dir(dir_a .. "/.weread-download-resume-full/text")
    and is_dir(dir_b .. "/.weread-download-notanumber-1"),
    "recovery removed the resumable workspace or an unrelated directory")
expect(not exists(dir_a .. "/Book - full.epub.part"), "partial EPUB was not removed")
expect(read_file(dir_a .. "/Kept.epub") == "new" and not exists(dir_a .. "/Kept.epub.weread-backup"),
    "backup of a committed EPUB was not discarded")
expect(read_file(dir_a .. "/Restored.epub") == "only copy"
    and not exists(dir_a .. "/Restored.epub.weread-backup"),
    "orphaned backup was not restored as the EPUB")
expect(read_file(dir_a .. "/Book - one.epub") == "final" and exists(dir_b .. "/catalog.json"),
    "recovery touched finished files")
expect(Content.cleanup_stale_downloads({ get_book_dirs = function() return {} end }) == 0,
    "recovery without book dirs removed something")

package.loaded["lfs"] = nil
package.preload["lfs"] = function() error("lfs unavailable") end
expect(Content.cleanup_stale_downloads({ get_book_dirs = function() error("unused") end }) == 0,
    "recovery without lfs did not degrade to a no-op")
expect(#Content.full_download_workspace_assets(workspace) == 0,
    "asset listing without lfs did not degrade to empty")
package.preload["lfs"] = lfs_stub
package.loaded["lfs"] = nil

-- Annotation source cache -----------------------------------------------------
Content.cache_annotation_source(settings, { book_id = "ann" }, { chapterUid = 4 }, "<p>x</p>")
Content.cache_annotation_source(settings, { bookId = "ann", _content_format = "txt" },
    { chapterId = 5 }, "<p>y</p>", "raw y")
Content.cache_annotation_source(settings, { book_id = "ann", _content_format = "txt" },
    { chapterUid = 6 }, "<p>no raw text</p>")
expect(#store_puts == 2 and store_puts[1].settings == settings
    and store_puts[1].book_id == "ann" and store_puts[1].kind == "original"
    and store_puts[1].key == "4" and store_puts[1].uid == "4"
    and store_puts[1].value == "index:<p>x</p>",
    "EPUB chapter source was not indexed into the annotation store")
expect(store_puts[2].key == "5" and store_puts[2].value == "plain:<p>y</p>",
    "TXT chapter source was not stored as plain text")
store_fails = true
warnings = {}
ok = pcall(Content.cache_annotation_source, settings, { book_id = "ann" }, { chapterUid = 7 }, "z")
store_fails = false
expect(ok and warnings[1] and warnings[1]:find("database is locked", 1, true),
    "annotation cache failure escaped or was not logged")

assert(os.execute("rm -rf " .. quoted(root)))
print(("content_disk_workspace_spec: %d checks"):format(checks))
