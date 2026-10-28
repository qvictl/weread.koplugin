package.path = "./?.lua;./?/init.lua;" .. package.path

-- LibraryDB against a real SQLite file: binding/open/schema failures, legacy
-- schema migration, catalog (chapters) replace semantics, book detail upserts,
-- rollback on encode failures, account isolation and reopen durability.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local helper = require("spec.helpers.annotation_test_store")

-- Count real connections so leaked handles are visible.
local opened, closed = 0, 0
local function counted_connect(path)
    local db = helper.connect(path)
    opened = opened + 1
    local raw_close = db.close
    function db.close(conn)
        closed = closed + 1
        return raw_close(conn)
    end
    return db
end

local binding_available = false
local open_hook
package.preload["lua-ljsqlite3/init"] = function()
    if not binding_available then error("module 'lua-ljsqlite3/init' not found") end
    return {
        open = function(path)
            if open_hook then return open_hook(path) end
            return counted_connect(path)
        end,
    }
end

-- Real JSON encoders reject functions; make the deterministic codec do the same.
local json = require("json")
local base_encode = json.encode
local function has_function(value)
    if type(value) == "function" then return true end
    if type(value) == "table" then
        for _, item in pairs(value) do
            if has_function(item) then return true end
        end
    end
    return false
end
json.encode = function(value)
    if has_function(value) then error("cannot encode function") end
    return base_encode(value)
end

local LibraryDB = require("weread.lib.library_db")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p '" .. root .. "'"))
local account = { user_vid = "reader-1" }
local settings = { data_dir = root, get = function() return account end }
local db = LibraryDB:new(settings)
local path = db:databasePath()
local paths = { [path] = true }

local function raw_rows(query, ...)
    local conn = helper.connect(path)
    local stmt = conn:prepare(query)
    stmt:bind(...)
    local rows, row = {}, stmt:step()
    while row do
        rows[#rows + 1] = row
        row = stmt:step()
    end
    stmt:close()
    conn:close()
    return rows
end
local function uids(chapters)
    local out = {}
    for index, chapter in ipairs(chapters or {}) do out[index] = tostring(chapter.chapterUid) end
    return table.concat(out, ",")
end

-- ── binding unavailable: every API degrades without throwing ───────────────
expect(db:open() == nil, "open must return nil without lua-ljsqlite3")
expect(db:cacheShelf({ { bookId = "1" } }) == false, "cacheShelf without binding")
expect(db:getShelf() == nil and db:getShelfArchives() == nil, "shelf reads without binding")
expect(db:putBook({ bookId = "1" }) == false and db:getBook("1") == nil, "book API without binding")
expect(db:putChapters("1", {}) == false, "putChapters without binding")
expect(db:getChapters("1") == nil and db:countChapters("1") == nil, "catalog reads without binding")
local probe = io.open(path, "rb")
expect(probe == nil, "a database file was created without the binding")
binding_available = true
-- A failed require leaves a sentinel in package.loaded; clear it like a fresh process.
package.loaded["lua-ljsqlite3/init"] = nil

-- ── open failures ───────────────────────────────────────────────────────────
open_hook = function() error("unable to open database file") end
expect(db:open() == nil, "open error must return nil")
open_hook = function() return nil end
expect(db:open() == nil and db:getShelf() == nil, "nil connection must return nil")
open_hook = nil

-- Corrupt file at the account path: schema init fails and the handle is closed.
local file = assert(io.open(path, "wb"))
file:write(string.rep("definitely not sqlite\n", 200))
file:close()
local opened_before, closed_before = opened, closed
expect(db:open() == nil, "corrupt database must not open")
expect(opened == opened_before + 1 and closed == closed_before + 1,
    "corrupt database handle leaked")
expect(db:putChapters("b", { { chapterUid = 1 } }) == false, "write to a corrupt database")
os.remove(path)

-- ── legacy schema migration ─────────────────────────────────────────────────
-- An early development build created books without detail_payload.
local legacy = helper.connect(path)
legacy:exec([[CREATE TABLE books (
    book_id TEXT PRIMARY KEY, kind TEXT NOT NULL DEFAULT 'book', payload TEXT NOT NULL,
    on_shelf INTEGER NOT NULL DEFAULT 0, shelf_position INTEGER,
    shelf_updated_at INTEGER, detail_updated_at INTEGER) WITHOUT ROWID]])
legacy:exec([[INSERT INTO books (book_id, payload, on_shelf, shelf_position)
    VALUES ('old', '{["bookId"]="old",["title"]="Legacy"}', 1, 1)]])
legacy:close()

local shelf = db:getShelf()
expect(shelf and #shelf == 1 and shelf[1].title == "Legacy", "legacy shelf row not readable")
expect(db:getBook("old").title == "Legacy", "getBook must fall back to the shelf payload")
expect(db:putBook({ bookId = "old", title = "Legacy", intro = "detail" }),
    "putBook failed on a migrated database")
expect(db:getBook("old").intro == "detail", "detail payload not stored after migration")
-- putBook must not change shelf membership.
expect(#db:getShelf() == 1 and db:getShelf()[1].intro == nil,
    "putBook changed the shelf snapshot")
-- A second open of the migrated database keeps working (duplicate column ignored).
db:close()
expect(LibraryDB:new(settings):getBook("old").intro == "detail", "migrated detail lost on reopen")

-- ── shelf snapshot details ──────────────────────────────────────────────────
expect(db:cacheShelf("not a table") == false, "non-table shelf accepted")
expect(db:cacheShelf({
    { bookId = "b2", title = "Two" },
    { bookId = "MP_WXS_1", title = "Feed" },
    { bookId = "b1", title = "One" },
}), "shelf write failed")
shelf = db:getShelf()
expect(#shelf == 3 and shelf[1].bookId == "b2" and shelf[2].bookId == "MP_WXS_1"
    and shelf[3].bookId == "b1", "shelf not returned in snapshot order")
local kinds = {}
for _, row in ipairs(raw_rows("SELECT book_id, kind, on_shelf FROM books")) do
    kinds[row[1]] = row[2] .. ":" .. row[3]
end
expect(kinds.MP_WXS_1 == "mp:1" and kinds.b1 == "book:1", "kind/on_shelf columns")
expect(kinds.old == "book:0", "books missing from the new snapshot must leave the shelf")
expect(db:getBook("old").intro == "detail", "leaving the shelf dropped the cached detail")

-- Encode failure: rollback keeps the previous snapshot and archives.
expect(db:cacheShelf(db:getShelf(), { { archiveId = 1, name = "G", bookIds = { "b1" } } }),
    "archive write failed")
local opened_mark = opened
expect(db:cacheShelf({ { bookId = "x", bad = function() end } }) == false,
    "unencodable book accepted")
expect(#db:getShelf() == 3 and db:getShelfArchives()[1].archiveId == 1,
    "failed shelf write was not rolled back")
expect(opened == opened_mark + 1, "failed write did not reset the shared connection")
expect(db:cacheShelf({ { bookId = "y" } }, { bad = function() end }) == false,
    "unencodable archives accepted")
expect(#db:getShelf() == 3 and db:getShelf()[1].bookId == "b2",
    "failed archive write was not rolled back")

-- ── catalog: putChapters / getChapters / countChapters ─────────────────────
expect(db:putChapters(nil, {}) == false and db:putChapters("b1", "x") == false,
    "invalid catalog arguments accepted")
expect(db:getChapters(nil) == nil and db:countChapters(nil) == nil, "nil book id")
expect(db:getChapters("b1") == nil and db:countChapters("b1") == 0, "empty catalog")

expect(db:putChapters("b1", {
    { chapterUid = 30, title = "C" },
    { chapterUid = 10, title = "A" },
    { chapterId = "id-x", title = "by id" },   -- uid falls back to chapterId
    { title = "by position" },                 -- uid falls back to position
}), "catalog write failed")
local chapters = db:getChapters("b1")
expect(#chapters == 4 and chapters[1].title == "C" and chapters[2].title == "A"
    and chapters[3].title == "by id" and chapters[4].title == "by position",
    "catalog not returned in insertion (position) order")
expect(db:countChapters("b1") == 4, "chapter count")
local stored_uids = {}
for _, row in ipairs(raw_rows("SELECT chapter_uid FROM chapters WHERE book_id='b1' ORDER BY position")) do
    stored_uids[#stored_uids + 1] = row[1]
end
expect(table.concat(stored_uids, ",") == "30,10,id-x,4", "chapter uid fallbacks")

-- Duplicate uids in one catalog violate the primary key: whole write rolls back.
expect(db:putChapters("b1", { { chapterUid = 1 }, { chapterUid = 1 } }) == false,
    "duplicate chapter uid accepted")
expect(uids(db:getChapters("b1")) == "30,10,nil,nil", "failed catalog write was not rolled back")

-- Replace semantics, per-book isolation and clearing.
expect(db:putChapters("b2", { { chapterUid = 7 } }), "second book catalog")
expect(db:putChapters("b1", { { chapterUid = 2 }, { chapterUid = 1 } }), "catalog rewrite")
expect(uids(db:getChapters("b1")) == "2,1", "rewrite did not replace the catalog")
expect(uids(db:getChapters("b2")) == "7", "rewrite touched another book")
expect(db:putChapters("b2", {}), "clearing a catalog failed")
expect(db:getChapters("b2") == nil and db:countChapters("b2") == 0, "catalog not cleared")

-- Encode failure mid-catalog: rollback and recover with a fresh connection.
opened_mark = opened
expect(db:putChapters("b1", { { chapterUid = 9 }, { chapterUid = 8, cb = function() end } }) == false,
    "unencodable chapter accepted")
expect(uids(db:getChapters("b1")) == "2,1", "failed chapter write leaked rows")
expect(opened == opened_mark + 1, "failed catalog write did not reset the connection")

-- Corrupt payload rows are skipped, not fatal.
local raw = helper.connect(path)
raw:exec("INSERT INTO chapters VALUES ('b1', 'junk', 99, 'not a lua table ((', 0)")
raw:exec([[INSERT INTO books (book_id, kind, payload, on_shelf, shelf_position)
    VALUES ('junk', 'book', 'garbage ((', 1, 99)]])
raw:close()
expect(uids(db:getChapters("b1")) == "2,1", "corrupt chapter payload not skipped")
expect(db:countChapters("b1") == 3, "count must include every stored row")
expect(#db:getShelf() == 3, "corrupt shelf payload not skipped")
expect(db:getBook("junk") == nil, "corrupt book payload must read as missing")

-- ── durability: close + new instance on the same file ──────────────────────
db:close()
local reopened = LibraryDB:new(settings)
expect(uids(reopened:getChapters("b1")) == "2,1", "catalog did not survive reopen")
expect(#reopened:getShelf() == 3 and reopened:getShelfArchives()[1].name == "G",
    "shelf did not survive reopen")
expect(reopened:getBook("old").intro == "detail", "book detail did not survive reopen")

-- ── account isolation ───────────────────────────────────────────────────────
account = { user_vid = "reader-2" }
local other_path = reopened:databasePath()
paths[other_path] = true
expect(other_path ~= path, "accounts share a database file")
expect(reopened:getChapters("b1") == nil and reopened:getBook("old") == nil
    and #reopened:getShelf() == 0, "data leaked into another account")
expect(reopened:putChapters("b1", { { chapterUid = 5 } }), "second account write")
account = { user_vid = "reader-1" }
expect(uids(reopened:getChapters("b1")) == "2,1", "second account overwrote the first")
account = { user_vid = "reader-2" }
expect(uids(reopened:getChapters("b1")) == "5", "second account catalog lost")
reopened:close()

for candidate in pairs(paths) do
    os.remove(candidate); os.remove(candidate .. "-wal"); os.remove(candidate .. "-shm")
end
os.remove(root)
helper.cleanup()
print(("library_db_durability_spec: %d checks"):format(checks))
