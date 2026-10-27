-- Process-wide memo for chapter catalogs (review F9).
--
-- Every read-report tick and every ProgressSync context miss used to decode
-- the whole catalog.json (811 chapters in the reported book) and rewrite the
-- SQLite catalog (DELETE plus one INSERT per chapter plus COMMIT), even when
-- nothing had changed. Plugin instances come and go with every ReaderUI, but
-- this module stays loaded, and forked report children inherit its tables,
-- so a catalog that is already in SQLite (or already decoded) is not written
-- (or decoded) again.

local Content = require("weread.lib.content")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = nil end

local CatalogMemo = {
    -- database path .. book_id -> signature of the catalog last written
    written = {},
    -- the most recently decoded catalog.json: { path, mtime, size, chapters }
    decoded = nil,
}

-- Cheap fingerprint of a catalog: count, ends and summed word counts.
function CatalogMemo.signature(chapters)
    if type(chapters) ~= "table" then return nil end
    local count = #chapters
    local words, indexes = 0, 0
    for _i, chapter in ipairs(chapters) do
        words = words + (tonumber(chapter.wordCount or chapter.word_count) or 0)
        indexes = indexes + (tonumber(chapter.chapterIdx) or 0)
    end
    local first, last = chapters[1] or {}, chapters[count] or {}
    return table.concat({
        count,
        tostring(first.chapterUid or first.chapterId),
        tostring(last.chapterUid or last.chapterId),
        tostring(last.title),
        words,
        indexes,
    }, "|")
end

-- library_db:putChapters, skipped when this exact catalog was written last.
function CatalogMemo.put_chapters(library_db, book_id, chapters)
    if not library_db or book_id == nil or type(chapters) ~= "table" then
        return false
    end
    -- Each account has its own database: key by database and book.
    local ok_path, db_path = pcall(function()
        return type(library_db.databasePath) == "function"
            and library_db:databasePath() or ""
    end)
    local key = tostring(ok_path and db_path or "") .. "\0" .. tostring(book_id)
    local signature = CatalogMemo.signature(chapters)
    if signature and CatalogMemo.written[key] == signature then
        return true
    end
    local ok = library_db:putChapters(book_id, chapters)
    if ok and signature then
        CatalogMemo.written[key] = signature
    end
    return ok
end

local function file_stamp(path)
    if not lfs or not path then return nil end
    local ok, attributes = pcall(lfs.attributes, path)
    if not ok or type(attributes) ~= "table" then return nil end
    return attributes.modification, attributes.size
end

-- Content.load_catalog_cache, reusing the last decoded catalog while the
-- file is unchanged (same path, mtime and size). Sets book.chapters.
function CatalogMemo.load(client, settings, book)
    local path = type(Content.catalog_cache_path) == "function"
        and Content.catalog_cache_path(settings, book) or nil
    local mtime, size = file_stamp(path)
    local memo = CatalogMemo.decoded
    if memo and path and mtime and memo.path == path
        and memo.mtime == mtime and memo.size == size then
        book.chapters = memo.chapters
        return memo.chapters
    end
    local chapters = Content.load_catalog_cache(client, settings, book)
    if type(chapters) == "table" and #chapters > 0 and path and mtime then
        CatalogMemo.decoded = {
            path = path, mtime = mtime, size = size, chapters = chapters,
        }
    end
    return chapters
end

return CatalogMemo
