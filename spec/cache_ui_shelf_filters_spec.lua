-- Bookshelf sort and filter options kept in weread/ui/cache.lua: summaries,
-- the option dialogs (deferred close, toggling, persistence) and the
-- downloaded/finished filters applied to shelf books.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local shown, closed, ticks = {}, {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function(_self, widget) closed[#closed + 1] = widget end,
        nextTick = function(_self, callback) ticks[#ticks + 1] = callback end,
        scheduleIn = function() error("unexpected schedule") end,
    }
end
local function run_ticks()
    while #ticks > 0 do table.remove(ticks, 1)() end
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_self, options) options.kind = "buttons" return options end }
end
for _i, name in ipairs({ "ui/widget/confirmbox", "ui/widget/pathchooser", "weread.lib.scan" }) do
    package.preload[name] = function() return {} end
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local existing = {}
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return path ~= nil and existing[path] == true end,
    }
end

local Cache = require("weread.ui.cache")

local store = { shelf = {} }
local flushes = 0
local record_lookups = 0
local records = {}
local host = {
    settings = {
        get = function(_self, key) return store[key] end,
        set = function(_self, key, value) store[key] = value end,
        flush = function() flushes = flushes + 1 end,
        get_book = function(_self, id) record_lookups = record_lookups + 1 return records[id] end,
    },
    shelf_filters = {},
}
for key, value in pairs(Cache) do host[key] = value end

-- 1. Sort summary follows the stored order, defaulting to newest first.
local summaries = { time_desc = "Newest", time_asc = "Oldest", default = "Default", name_asc = "A–Z", name_desc = "Z–A" }
for key, short in pairs(summaries) do
    store.shelf.sort_order = key
    expect(host:shelfSortSummary() == short, "sort summary wrong for " .. key)
end
store.shelf.sort_order = nil
expect(host:shelfSortSummary() == "Newest", "missing sort order did not default to newest")
store.shelf.sort_order = "bogus"
expect(host:shelfSortSummary() == "Newest", "unknown sort order did not default to newest")

-- 2. The sort dialog marks the current order; picking another one saves it
-- and refreshes only after the dialog closes on the next tick.
store.shelf.sort_order = "name_asc"
local sorted = 0
host:showShelfSortOptions(function() sorted = sorted + 1 end)
local dialog = shown[#shown]
expect(dialog.kind == "buttons" and dialog.title == "Sort by" and #dialog.buttons == 5, "sort dialog not shown")
local checked = {}
for index, row in ipairs(dialog.buttons) do
    if row[1].checked_func() then checked[#checked + 1] = index end
end
expect(#checked == 1 and checked[1] == 4, "current sort order was not the only checked option")
dialog.buttons[2][1].callback()
expect(sorted == 0 and #closed == 0 and store.shelf.sort_order == "name_asc",
    "sort applied before the button repaint")
run_ticks()
expect(closed[1] == dialog and store.shelf.sort_order == "time_asc" and flushes == 1 and sorted == 1,
    "picked sort order was not saved and applied")
-- A missing stored order marks "Default".
store.shelf.sort_order = nil
host:showShelfSortOptions(function() end)
expect(shown[#shown].buttons[3][1].checked_func() and not shown[#shown].buttons[1][1].checked_func(),
    "missing sort order did not check Default")

-- 3. Filter summary and dialog.
local filters = host.shelf_filters
expect(host:shelfFilterSummary() == "All", "empty filters not summarized as All")
filters.reading, filters.download = "finished", "downloaded"
expect(host:shelfFilterSummary() == "Finished / Downloaded", "combined filters wrong: " .. host:shelfFilterSummary())
filters.reading, filters.download = nil, nil

local changed = 0
host:showShelfFilterOptions(function() changed = changed + 1 end)
dialog = shown[#shown]
expect(dialog.title == "Filter by" and #dialog.buttons == 5, "filter dialog not shown")
expect(dialog.buttons[1][1].checked_func(), "All was not checked without filters")
local before_changes = changed
local function state()
    return tostring(filters.reading) .. "|" .. tostring(filters.download)
end
local function tap(index)
    local state_before, changes = state(), changed
    dialog.buttons[index][1].callback()
    expect(changed == changes and state() == state_before, "filter applied before the button repaint")
    run_ticks()
end
tap(2) -- finished
expect(filters.reading == "finished" and store.shelf.filter_reading == "finished" and changed == before_changes + 1,
    "finished filter not applied and saved")
tap(5) -- not downloaded
expect(filters.reading == "finished" and filters.download == "not_downloaded"
        and store.shelf.filter_download == "not_downloaded",
    "a second dimension replaced the first")
expect(dialog.buttons[2][1].checked_func() and dialog.buttons[5][1].checked_func()
        and not dialog.buttons[1][1].checked_func(),
    "checked marks do not follow the filters")
tap(3) -- unfinished replaces finished in the same dimension
expect(filters.reading == "unfinished", "same-dimension option did not replace the filter")
expect(filters.download == "not_downloaded" and store.shelf.filter_reading == "unfinished",
    "replacing a filter touched the other dimension")
tap(1) -- All clears everything
expect(filters.reading == nil and filters.download == nil and store.shelf.filter_download == nil,
    "All did not clear every filter")
expect(changed == before_changes + 4, "not every filter change refreshed the shelf")

-- 4. Download state of shelf books.
expect(host:bookRecordHasDownload(nil) == false and host:bookRecordHasDownload("x") == false,
    "a missing record counted as downloaded")
existing["/b/full.epub"] = true
expect(host:bookRecordHasDownload({ cached_full_book = "/b/full.epub" }), "full book not detected")
expect(not host:bookRecordHasDownload({ cached_full_book = "/b/gone.epub", cached_file = "/b/gone2.epub" }),
    "deleted files counted as downloaded")
existing["/b/ch2.epub"] = true
expect(host:bookRecordHasDownload({ cached_chapters = { a = "/b/ch1.epub", b = "/b/ch2.epub" } }),
    "a single downloaded chapter not detected")

records.r1 = { cached_file = "/b/full.epub" }
expect(host:isBookDownloaded({ title = "no id" }) == false, "a book without id counted as downloaded")
expect(host:isBookDownloaded({ bookId = "r1" }) == true and record_lookups == 1, "record lookup not used")
local saved = { r2 = { cached_file = "/b/missing.epub" } }
local memo = {}
expect(host:isBookDownloaded({ book_id = "r2" }, saved, memo) == false and memo.r2 == false
        and record_lookups == 1,
    "saved records were not used or the result not memoized")
saved.r2.cached_file = "/b/full.epub"
expect(host:isBookDownloaded({ book_id = "r2" }, saved, memo) == false, "memoized result was not reused")

-- 5. Filters applied to shelf books.
saved = { done = { cached_file = "/b/full.epub" }, todo = {} }
local done = { book_id = "done", finishReading = 1 }
local todo = { book_id = "todo", finishReading = 0 }
local function visible(reading, download)
    host.shelf_filters = { reading = reading, download = download }
    local ids = {}
    for _i, book in ipairs({ done, todo }) do
        if host:bookMatchesFilters(book, saved, {}) then ids[#ids + 1] = book.book_id end
    end
    return table.concat(ids, ",")
end
expect(visible(nil, nil) == "done,todo", "no filter hid books")
expect(visible("finished", nil) == "done", "finished filter wrong")
expect(visible("unfinished", nil) == "todo", "unfinished filter wrong")
expect(visible(nil, "downloaded") == "done", "downloaded filter wrong")
expect(visible(nil, "not_downloaded") == "todo", "not-downloaded filter wrong")
expect(visible("finished", "not_downloaded") == "", "combined filters wrong")
host.shelf_filters = nil
expect(host:bookMatchesFilters(todo, saved), "missing filter table hid a book")

print(("cache_ui_shelf_filters_spec: %d checks"):format(checks))
