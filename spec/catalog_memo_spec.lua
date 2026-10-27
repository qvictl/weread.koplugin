-- Catalog memo: no SQLite rewrite or JSON re-decode for an unchanged catalog.
package.path = "./?.lua;" .. package.path

local decodes = 0
local stamp = { modification = 100, size = 10 }
package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function(_settings, book)
            return "/cache/" .. tostring(book.book_id) .. "/catalog.json"
        end,
        load_catalog_cache = function(_client, _settings, book)
            decodes = decodes + 1
            book.chapters = { { chapterUid = 1, wordCount = 10 }, { chapterUid = 2, wordCount = 20 } }
            return book.chapters
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return stamp end }
end

local CatalogMemo = require("weread.lib.catalog_memo")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message) end
end

local writes = 0
local db_path = "/data/library-a.db"
local db = {
    putChapters = function() writes = writes + 1 return true end,
    databasePath = function() return db_path end,
}
local chapters = { { chapterUid = 1, wordCount = 10 }, { chapterUid = 2, wordCount = 20 } }
expect(CatalogMemo.put_chapters(db, "book", chapters), "first write")
expect(CatalogMemo.put_chapters(db, "book", chapters), "repeat write reports success")
expect(writes == 1, "unchanged catalog is written once")
chapters[3] = { chapterUid = 3, wordCount = 5 }
CatalogMemo.put_chapters(db, "book", chapters)
expect(writes == 2, "a changed catalog is written")
db_path = "/data/library-b.db"
CatalogMemo.put_chapters(db, "book", chapters)
expect(writes == 3, "another account's database is written")

local book = { book_id = "book" }
CatalogMemo.load({}, {}, book)
local other = { book_id = "book" }
local loaded = CatalogMemo.load({}, {}, other)
expect(decodes == 1, "unchanged catalog.json is decoded once")
expect(other.chapters == loaded and #loaded == 2, "memo sets book.chapters")
stamp = { modification = 101, size = 10 }
CatalogMemo.load({}, {}, { book_id = "book" })
expect(decodes == 2, "a rewritten catalog.json is decoded again")

print("catalog_memo_spec: " .. checks .. " checks passed")
