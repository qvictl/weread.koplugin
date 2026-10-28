package.path = "./?.lua;./?/init.lua;" .. package.path

-- Per-book thought storage (thoughts.db) against a real SQLite file: schema
-- creation and legacy-table migration, chapter replace semantics, lookups by
-- (chapter, range), transactional rollback, durability across handles and
-- reopen, and corrupt/missing database handling.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local SQ = require("spec.helpers.ljsqlite3_ffi")

local warnings = {}
package.preload["weread.lib.logger"] = function()
    return {
        dbg = function() end,
        info = function() end,
        err = function() end,
        warn = function(...)
            local parts = {}
            for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
            warnings[#warnings + 1] = table.concat(parts, " ")
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function() return SQ.lfs() end

-- The binding module is resolved lazily on every open(); start "unavailable".
local binding_available = false
local open_hook
package.preload["lua-ljsqlite3/init"] = function()
    if not binding_available then error("module 'lua-ljsqlite3/init' not found") end
    return {
        open = function(path)
            if open_hook then return open_hook(path) end
            return SQ.open(path)
        end,
    }
end

local ThoughtDB = require("weread.lib.thought_db")

local root = SQ.tempdir()
local book_dir = root .. "/book-a"
local db_path = book_dir .. "/thoughts.db"

local function review(range, page_reviews)
    return { range = range, pageReviews = page_reviews }
end
local function page(content, nick, likes, abstract)
    return {
        likesCount = likes,
        review = { content = content, author = nick and { nick = nick } or nil, abstract = abstract },
    }
end
local function count_rows(conn, chapter_uid)
    local rows = SQ.rows(conn, "SELECT COUNT(*) FROM review_items WHERE chapter_uid=?", chapter_uid)
    return tonumber(rows[1][1])
end

-- ── argument validation ─────────────────────────────────────────────────────
for _, bad in ipairs({ false, 7, "" }) do
    expect(ThoughtDB.open(bad) == nil, "open accepted an invalid book_dir")
    expect(ThoughtDB.remove_db(bad) == false, "remove_db accepted an invalid book_dir")
end
expect(ThoughtDB.open(nil) == nil and ThoughtDB.remove_db(nil) == false, "nil book_dir")

-- ── binding unavailable ─────────────────────────────────────────────────────
expect(ThoughtDB.open(book_dir) == nil, "open must fail softly without lua-ljsqlite3")
expect(not SQ.exists(db_path), "no database file may be created without the binding")
expect(#warnings == 1 and warnings[1]:find("unavailable", 1, true), "missing binding not logged")
binding_available = true
-- A failed require leaves a sentinel in package.loaded; clear it like a fresh process.
package.loaded["lua-ljsqlite3/init"] = nil

-- ── SQ3.open failure ────────────────────────────────────────────────────────
open_hook = function() error("disk I/O error") end
expect(ThoughtDB.open(book_dir) == nil, "open error must return nil")
expect(warnings[#warnings]:find("open failed", 1, true), "open failure not logged")
open_hook = function() return nil end
expect(ThoughtDB.open(book_dir) == nil, "nil connection must return nil")
open_hook = nil

-- ── schema creation, directory creation, legacy table drop ─────────────────
-- Seed a development-era "reviews" table that open() must drop.
SQ.lfs().mkdir(book_dir)
local seed = SQ.open(db_path)
seed:exec("CREATE TABLE reviews (chapter_uid INTEGER, payload TEXT)")
seed:exec("INSERT INTO reviews VALUES (1, 'legacy')")
seed:close()

local db = ThoughtDB.open(book_dir)
expect(db ~= nil, "open failed on a valid directory")
local tables = {}
for _, row in ipairs(SQ.rows(db, "SELECT name FROM sqlite_master WHERE type='table'")) do
    tables[row[1]] = true
end
expect(tables.review_items, "review_items table not created")
expect(not tables.reviews, "legacy reviews table was not dropped")
local journal = SQ.rows(db, "PRAGMA journal_mode")[1][1]
expect(journal == "wal", "database not switched to WAL: " .. tostring(journal))

-- open() creates a missing book directory (one level, like libkoreader-lfs
-- mkdir; the cache root above it already exists in production).
expect(SQ.lfs().mkdir(root .. "/nested") == true, "could not create the parent directory")
local fresh_dir = root .. "/nested/book-b"
local fresh = ThoughtDB.open(fresh_dir)
expect(fresh ~= nil and SQ.exists(fresh_dir .. "/thoughts.db"), "missing book directory not created")
expect(#ThoughtDB.getReviewItems(fresh, 1, "1-2") == 0, "fresh database is not empty")
ThoughtDB.close(fresh)

-- ── putReviews / getReviewItems ─────────────────────────────────────────────
expect(ThoughtDB.putReviews(nil, 1, {}) == false, "nil db accepted")
expect(ThoughtDB.putReviews(db, 1, "x") == false, "non-table reviews accepted")
expect(ThoughtDB.getReviewItems(nil, 1, "1-2") == nil, "nil db lookup must return nil")

local ok = ThoughtDB.putReviews(db, 101, {
    review("10-20", {
        page("first thought", "Alice", 3, "quoted text"),
        page("second thought", nil, nil, "ignored abstract"),
    }),
    review("30-40", { page("other range", "Bob", "7") }),
    review("", { page("empty range") }),           -- skipped
    { pageReviews = { page("no range") } },        -- skipped
    "not a table",                                  -- skipped
    review("50-60", {}),                            -- no pageReviews -> no rows
    review("30-40", { page("replacement", "Carol", 1) }), -- duplicate range: last wins
})
expect(ok == true, "putReviews failed")
expect(count_rows(db, 101) == 3, "unexpected stored row count: " .. count_rows(db, 101))

local items = ThoughtDB.getReviewItems(db, 101, "10-20")
expect(#items == 2, "range lookup returned " .. #items .. " items")
expect(items[1].abstract == "quoted text" and items[1].author == "Alice"
    and items[1].content == "first thought" and tonumber(items[1].likes_count) == 3,
    "first item fields")
-- Only the first page review carries the quoted abstract; anonymous authors get a placeholder.
expect(items[2].abstract == nil and items[2].content == "second thought"
    and items[2].author ~= nil and items[2].author ~= "" and tonumber(items[2].likes_count) == 0,
    "second item fields")

items = ThoughtDB.getReviewItems(db, 101, "30-40")
expect(#items == 1 and items[1].content == "replacement" and items[1].author == "Carol",
    "duplicate range did not keep the last review")
expect(#ThoughtDB.getReviewItems(db, 101, "50-60") == 0, "empty pageReviews produced rows")
expect(#ThoughtDB.getReviewItems(db, 101, "99-100") == 0, "unknown range returned rows")
expect(#ThoughtDB.getReviewItems(db, 999, "10-20") == 0, "unknown chapter returned rows")

-- Thought links carry the chapter uid as text: lookup must match numeric storage.
items = ThoughtDB.getReviewItems(db, "101", "10-20")
expect(#items == 2, "string chapter uid did not match the stored integer uid")

-- Second chapter is independent.
expect(ThoughtDB.putReviews(db, 202, { review("10-20", { page("chapter two", "Dan", 0) }) }),
    "second chapter write failed")
expect(ThoughtDB.getReviewItems(db, 202, "10-20")[1].content == "chapter two"
    and #ThoughtDB.getReviewItems(db, 101, "10-20") == 2, "chapters leaked into each other")

-- Rewriting a chapter replaces only that chapter's rows.
expect(ThoughtDB.putReviews(db, 101, { review("70-80", { page("fresh", "Eve", 2) }) }),
    "chapter rewrite failed")
expect(#ThoughtDB.getReviewItems(db, 101, "10-20") == 0, "stale range survived a rewrite")
expect(ThoughtDB.getReviewItems(db, 101, "70-80")[1].content == "fresh", "rewrite not stored")
expect(count_rows(db, 202) == 1, "rewrite touched another chapter")
-- Idempotent rewrite with the same payload.
expect(ThoughtDB.putReviews(db, 101, { review("70-80", { page("fresh", "Eve", 2) }) }), "rewrite")
expect(count_rows(db, 101) == 1, "repeating the same write duplicated rows")
-- An empty list clears the chapter.
expect(ThoughtDB.putReviews(db, 202, {}) == true, "empty write failed")
expect(count_rows(db, 202) == 0, "empty write did not clear the chapter")

-- ── transactional rollback ──────────────────────────────────────────────────
db:exec([[CREATE TRIGGER reject_boom BEFORE INSERT ON review_items
    WHEN NEW.content = 'boom' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END]])
local warn_count = #warnings
expect(ThoughtDB.putReviews(db, 101, {
    review("1-2", { page("would be inserted first", "A", 0) }),
    review("3-4", { page("boom", "B", 0) }),
}) == false, "failed insert reported success")
expect(#warnings == warn_count + 1 and warnings[#warnings]:find("write failed", 1, true),
    "failed chapter write not logged")
expect(#ThoughtDB.getReviewItems(db, 101, "1-2") == 0, "partial write was not rolled back")
expect(ThoughtDB.getReviewItems(db, 101, "70-80")[1].content == "fresh",
    "failed write deleted the previous chapter rows")
db:exec("DROP TRIGGER reject_boom")
-- The connection remains usable after a rollback.
expect(ThoughtDB.putReviews(db, 303, { review("5-6", { page("after rollback", "F", 0) }) }),
    "connection unusable after rollback")

-- BEGIN failing (caller already inside a transaction) must not roll back the caller's work.
db:exec("BEGIN")
db:exec("INSERT INTO review_items VALUES (404, '9-9', 1, NULL, 'Caller', 'outer', 0)")
expect(ThoughtDB.putReviews(db, 405, { review("1-1", { page("inner", "G", 0) }) }) == false,
    "nested BEGIN was not reported as a failure")
db:exec("COMMIT")
expect(ThoughtDB.getReviewItems(db, 404, "9-9")[1].content == "outer",
    "putReviews rolled back a transaction it did not open")
expect(count_rows(db, 405) == 0, "nested write leaked rows")

-- ── durability: second handle and reopen ───────────────────────────────────
local reader = ThoughtDB.open(book_dir)
expect(reader ~= nil, "second handle failed to open")
expect(ThoughtDB.getReviewItems(reader, 101, "70-80")[1].content == "fresh",
    "committed rows not visible to a concurrent handle")
expect(ThoughtDB.putReviews(reader, 101, { review("70-80", { page("from reader", "H", 5) }) }),
    "write through second handle failed")
expect(ThoughtDB.getReviewItems(db, 101, "70-80")[1].content == "from reader",
    "first handle did not see the second handle's commit")
ThoughtDB.close(reader)
ThoughtDB.close(db)
ThoughtDB.close(db) -- double close is harmless
ThoughtDB.close(nil)

db = ThoughtDB.open(book_dir)
items = ThoughtDB.getReviewItems(db, 101, "70-80")
expect(#items == 1 and items[1].content == "from reader" and items[1].author == "H"
    and tonumber(items[1].likes_count) == 5, "rows did not survive close/reopen")
expect(ThoughtDB.getReviewItems(db, 303, "5-6")[1].content == "after rollback",
    "reopen (CREATE IF NOT EXISTS) lost data")

-- Book isolation: another book directory has its own database.
local other = ThoughtDB.open(root .. "/book-c")
expect(#ThoughtDB.getReviewItems(other, 101, "70-80") == 0, "books shared a thought database")
ThoughtDB.close(other)

-- ── query failures ──────────────────────────────────────────────────────────
db:exec("DROP TABLE review_items")
expect(ThoughtDB.getReviewItems(db, 101, "70-80") == nil, "prepare failure must return nil")
expect(ThoughtDB.putReviews(db, 101, { review("1-2", { page("x", "y", 0) }) }) == false,
    "write against a missing table must fail")
ThoughtDB.close(db)

local closed = {}
local function scripted_db(steps)
    return {
        prepare = function()
            local index = 0
            return {
                reset = function(self) return self end,
                bind = function(self) return self end,
                step = function()
                    index = index + 1
                    local next_step = steps[index]
                    if next_step == "error" then error("SQLITE_IOERR") end
                    return next_step
                end,
                close = function() closed[#closed + 1] = true end,
            }
        end,
    }
end
closed = {}
expect(ThoughtDB.getReviewItems(scripted_db({ "error" }), 1, "1-2") == nil,
    "first-step failure must return nil")
expect(#closed == 1, "statement leaked after first-step failure")
closed = {}
expect(ThoughtDB.getReviewItems(scripted_db({ { "a", "b", "c", 1 }, "error" }), 1, "1-2") == nil,
    "mid-iteration failure must not return partial results")
expect(#closed == 1, "statement leaked after mid-iteration failure")
expect(ThoughtDB.getReviewItems({ prepare = function() return nil end }, 1, "1-2") == nil,
    "nil statement must return nil")

-- ── corrupt database file ──────────────────────────────────────────────────
local corrupt_dir = root .. "/corrupt"
SQ.lfs().mkdir(corrupt_dir)
local file = assert(io.open(corrupt_dir .. "/thoughts.db", "wb"))
file:write(string.rep("this is not an sqlite database\n", 200))
file:close()
local closes_before = SQ.closed
expect(ThoughtDB.open(corrupt_dir) == nil, "corrupt database must fail to open")
expect(SQ.closed == closes_before + 1, "handle leaked after schema failure")
expect(warnings[#warnings]:find("schema init failed", 1, true), "schema failure not logged")

-- ── remove_db ───────────────────────────────────────────────────────────────
expect(SQ.exists(db_path), "database file missing before removal")
for _, suffix in ipairs({ "-wal", "-shm" }) do
    local sidecar = assert(io.open(db_path .. suffix, "wb"))
    sidecar:write("x")
    sidecar:close()
end
expect(ThoughtDB.remove_db(book_dir) == true, "remove_db failed")
expect(not SQ.exists(db_path) and not SQ.exists(db_path .. "-wal")
    and not SQ.exists(db_path .. "-shm"), "database or sidecars survived removal")
expect(ThoughtDB.remove_db(book_dir) == true, "removing a missing database must succeed")
db = ThoughtDB.open(book_dir)
expect(#ThoughtDB.getReviewItems(db, 101, "70-80") == 0, "removed database kept rows")
ThoughtDB.close(db)

SQ.rmtree(root)
print(("thought_db_persistence_spec: %d checks"):format(checks))
