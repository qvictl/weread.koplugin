-- A cloud position written into a book record must not be mistaken for a
-- position this device reported itself (read_report/progress_sync only let
-- an older local position through when the cloud equals one of "ours").
package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["weread.lib.logger"] = function()
    local noop = function() end
    local logger = { info = noop, warn = noop, err = noop, dbg = noop }
    logger.scoped = function() return logger end
    return logger
end

local ReaderState = require("weread.lib.reader_state")

local book = { chapter_uid = 3, chapter_offset = 10, progress = 40, reported_local = true }
ReaderState.apply_to_book(book, {
    current_chapter = { chapterUid = 33, chapterIdx = 3, chapterOffset = 10 },
    progress = { progress = 40 },
})
assert(book.chapter_uid == 33, "cloud chapter applied")
assert(book.reported_local == false, "cloud position still marked as reported by this device")
print("reader_state_reported_local_spec: 2 checks")
