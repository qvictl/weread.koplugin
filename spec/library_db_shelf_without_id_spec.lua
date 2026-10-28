package.path = "./?.lua;./?/init.lua;" .. package.path

-- Regression: a shelf entry without a book id must be skipped, not abort the
-- whole snapshot. LibraryDB's encode() returned the encoded payload as its
-- error value on success, so cacheShelf raised it for id-less entries and
-- rolled the offline shelf back.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function() return { open = helper.connect } end
local LibraryDB = require("weread.lib.library_db")

local user = os.tmpname()
os.remove(user)
local settings = { data_dir = "/tmp", get = function() return { user_vid = user } end }
local db = LibraryDB:new(settings)
local path = db:databasePath()

expect(db:cacheShelf({ { bookId = "old", title = "Old" } }), "seed shelf write failed")
expect(db:cacheShelf({
    { bookId = "b1", title = "One" },
    { title = "entry without an id" },
    { book_id = "b2", title = "Two" },
}, {}), "an id-less shelf entry aborted the snapshot")
local shelf = db:getShelf()
expect(#shelf == 2 and shelf[1].bookId == "b1" and shelf[2].book_id == "b2",
    "id-less entry was not skipped or the snapshot was rolled back")
db:close()

os.remove(path); os.remove(path .. "-wal"); os.remove(path .. "-shm")
helper.cleanup()
print(("library_db_shelf_without_id_spec: %d checks"):format(checks))
