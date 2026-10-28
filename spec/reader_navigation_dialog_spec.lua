-- Reader quick menu actions for a regular WeRead book: which buttons are
-- enabled for single chapters, the last chapter and full-book EPUBs, what
-- each callback does, and closing the book back to the file browser.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local dialogs = 0
local options, callbacks
package.preload["weread.ui.end_of_book_dialog"] = function()
    return { show = function(given_options, given_callbacks)
        dialogs = dialogs + 1
        options, callbacks = given_options, given_callbacks
    end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end

local Navigation = require("weread.ui.reader_navigation")

local chapters = {
    { chapterUid = 11, title = "One" },
    { chapterUid = 12, title = "Two" },
    { chapterUid = 13, title = "Three" },
}
local books = { ["100"] = { book_id = "100", title = "Book" } }
local chapter_info = { 2, chapters[2], false }
local calls = {}
local function record(name)
    return function(_self, ...) calls[#calls + 1] = { name = name, args = { ... } } end
end
local notice
local ui_events = {}
local ui = {
    document = { file = "/books/100/12.epub" },
    onClose = function() ui_events[#ui_events + 1] = "close" end,
    showFileManager = function(_self, file) ui_events[#ui_events + 1] = "files:" .. tostring(file) end,
}
local loaded_for
local host = {
    ui = ui,
    settings = require("spec.helpers.book_settings").install({
        get = function(_self, _key, default) return default end,
    }, books),
    ensureChaptersLoaded = function(_self, book) loaded_for = book return chapters end,
    getChapterInfoFromFile = function(_self, book, file)
        expect(book == books["100"] and file == "/books/100/12.epub", "chapter lookup got the wrong book or file")
        return chapter_info[1], chapter_info[2], chapter_info[3]
    end,
    showTransientInfo = function(_self, text, timeout) notice = { text = text, timeout = timeout } end,
    showBookshelf = record("bookshelf"),
    showSearch = record("search"),
    showChapterList = record("chapter_list"),
    openChapter = record("open_chapter"),
    showCurrentBookDetails = record("details"),
    showReadStats = record("stats"),
    onWeReadSyncProgress = record("sync"),
    toggleAnnotationVisibility = record("toggle"),
}
for key, value in pairs(Navigation) do
    if host[key] == nil then host[key] = value end
end
local function last_call() return calls[#calls] end

-- 1. A single downloaded chapter with a successor enables every action.
expect(host:showEndOfBookDialog("100") == true and dialogs == 1, "quick menu not shown")
expect(loaded_for == books["100"], "chapters not loaded for the book")
expect(options.show_chapter_nav == true and options.show_next_chapter == true,
    "regular chapter hid the chapter navigation row")
expect(options.enable_chapter_list and options.enable_next_chapter and options.enable_book_details
        and options.enable_sync_progress and options.annotations_visible,
    "regular chapter did not enable every action")
callbacks.on_next()
expect(last_call().name == "open_chapter" and last_call().args[1] == books["100"]
        and last_call().args[2] == chapters[3],
    "next chapter did not open the successor")
callbacks.on_chapter_list()
expect(last_call().name == "chapter_list" and last_call().args[1] == books["100"], "chapter list not opened")
callbacks.on_book_details()
expect(last_call().name == "details", "book details not opened")
callbacks.on_sync_progress()
expect(last_call().name == "sync", "progress sync not started")
callbacks.on_bookshelf()
expect(last_call().name == "bookshelf", "bookshelf not opened")
callbacks.on_search()
expect(last_call().name == "search", "search not opened")
expect(notice == nil, "an available action showed a notice")

-- 2. On the last chapter "next" explains instead of opening anything.
chapter_info = { 3, chapters[3], false }
host:showEndOfBookDialog("100")
expect(options.enable_next_chapter == false and options.enable_chapter_list, "last chapter enabled next")
local call_count = #calls
callbacks.on_next()
expect(#calls == call_count and notice.text == "You have reached the last chapter." and notice.timeout == 1,
    "last chapter did not explain")

-- 3. A full-book EPUB has no chapter successor even mid-book, and an
-- unmapped document has no current chapter.
chapter_info = { 1, chapters[1], true }
host:showEndOfBookDialog("100")
expect(options.enable_next_chapter == false and options.enable_chapter_list, "full book enabled next chapter")
chapter_info = { nil, nil, nil }
host:showEndOfBookDialog("100")
expect(options.enable_next_chapter == false and options.enable_sync_progress, "unmapped chapter enabled next")

-- 4. Chapters that cannot be loaded disable the chapter list.
host.ensureChaptersLoaded = function() return nil end
host:showEndOfBookDialog("100")
expect(options.enable_chapter_list == false and options.enable_next_chapter == false
        and options.enable_book_details,
    "missing chapters left chapter actions enabled")
-- The row stays visible (disabled) so the global quick menu keeps its layout.
expect(options.show_chapter_nav == true and options.show_next_chapter == true,
    "missing chapters hid the chapter navigation row")
notice = nil
call_count = #calls
callbacks.on_chapter_list()
expect(#calls == call_count and notice.text == "This action requires an open WeRead book.",
    "unavailable chapter list did not explain")
notice = nil
callbacks.on_next()
expect(notice.text == "You have reached the last chapter.", "next without chapters on a WeRead book wrong")

-- 5. An unknown book id behaves like a local document.
notice = nil
host:showEndOfBookDialog("missing")
expect(options.enable_book_details == false and options.enable_sync_progress == false, "unknown book enabled actions")
expect(options.show_chapter_nav == true and options.show_next_chapter == true
        and options.enable_chapter_list == false and options.enable_next_chapter == false,
    "a local document hid or enabled the chapter navigation row")
call_count = #calls
callbacks.on_book_details()
expect(#calls == call_count and notice.text == "This action requires an open WeRead book.",
    "details without a book did not explain")
notice = nil
callbacks.on_next()
expect(#calls == call_count and notice.text == "This action requires an open WeRead book.",
    "next without a book did not explain")

-- 6. Without an open document there is no quick menu.
host.ui = { document = nil }
local before = dialogs
expect(host:showEndOfBookDialog("100") == false and dialogs == before, "quick menu shown without a document")

-- 7. Closing the book reopens the file browser on the book file.
host.ui = ui
host:showEndOfBookDialog("100")
callbacks.on_close_book()
expect(ui_events[1] == "close" and ui_events[2] == "files:/books/100/12.epub" and #ui_events == 2,
    "closing the book did not return to the file browser")
local bare_ui = { document = { file = "/x.epub" }, onClose = function(self) self.closed = true end }
host.ui = bare_ui
host:showEndOfBookDialog(nil)
callbacks.on_close_book()
expect(bare_ui.closed, "reader without a file manager was not closed")
host.ui = nil
callbacks.on_close_book() -- reader already gone: nothing to do
expect(true)

print(("reader_navigation_dialog_spec: %d checks"):format(checks))
