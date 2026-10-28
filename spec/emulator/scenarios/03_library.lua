-- @title Bookshelf sync, pagination, groups, pre-paint taps and chapter list
-- @timeout 150
-- Real shelf flow: /shelf/sync through the mock, the LibraryView with its
-- page bar (26 books over several pages, Next/Previous), the group menu,
-- taps queued before the view's first paint (must propagate, not crash),
-- a shelf filter toggled on and off again by re-tapping it, and a title tap
-- that opens the book page and its 6-chapter list.
return function(H)
    local UIManager = require("ui/uimanager")

    local plugin
    local TARGET = "山谷来信 · 离线测试"
    local CHAPTERS = { "第1章 启程", "第2章 雨中的小站", "第3章 山间来信", "第4章 海边的夜晚", "第5章 重逢", "第6章 归途" }

    local function painted(dimen)
        return type(dimen) == "table" and type(dimen.x) == "number" and (dimen.w or 0) > 0 and (dimen.h or 0) > 0
    end

    -- Exact-text tap (H.tap_text is a substring match).
    local function tap_exact(text, root_fn, timeout)
        local target = H.wait_until("exact text '" .. text .. "' painted", function()
            local root = root_fn and root_fn() or nil
            if root_fn and not root then return nil end
            local found
            H.walk(function(widget, chain, depth)
                if rawget(widget, "text") == text then
                    for i = depth, 1, -1 do
                        local d = rawget(chain[i], "dimen")
                        if painted(d) then
                            found = d
                            return true
                        end
                    end
                end
            end, root)
            return found
        end, timeout or 15)
        local x, y = math.floor(target.x + target.w / 2), math.floor(target.y + target.h / 2)
        H.log("tap exact", text, "@", x, y)
        H.tap_at(x, y)
    end

    local function shelf_view()
        local view = plugin.shelf_view
        return view and UIManager:isWidgetShown(view) and view or nil
    end

    -- Waits for a shown shelf view (different from `old`) whose rows painted.
    local function wait_shelf(description, old, pred)
        return H.wait_until(description, function()
            local view = shelf_view()
            if not view or view == old then return nil end
            local rows = view._item_rows or {}
            if #rows == 0 or not painted(rows[1].frame and rows[1].frame.dimen) then return nil end
            if pred and not pred(view) then return nil end
            return view
        end, 30)
    end

    local function page_titles(view)
        return H.call(function()
            local out = {}
            for _i, row in ipairs(view._item_rows or {}) do out[#out + 1] = row.text end
            return out
        end)
    end

    local function page_label(view)
        return (H.tr("%1/%2 pages"):gsub("%%1", tostring(view.page)):gsub("%%2", tostring(view.page_count)))
    end

    H.step("plugin ready", function()
        plugin = H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
    end)

    local first_view
    H.step("open bookshelf (sync from mock)", function()
        local t0 = H.now_ms()
        H.call(function() plugin:showBookshelf() end)
        first_view = wait_shelf("LibraryView painted")
        H.metric("shelf_open_ms", H.now_ms() - t0)
        local syncs = H.mock_requests(function(event) return event.api == "/shelf/sync" end)
        H.equal(#syncs, 1, "one /shelf/sync request")
        H.equal(#(first_view.books or {}), 26, "26 books in the All view")
        H.equal(first_view.total_books, 26, "total book count")
        H.check(first_view.paged, "list is paginated")
        H.check(first_view.page_count >= 2, "more than one page", tostring(first_view.page_count))
        H.equal(first_view.page, 1, "starts at page 1")
        H.metric("shelf_page_size", first_view.page_size)
        H.metric("shelf_page_count", first_view.page_count)
        H.check(H.has_text(page_label(first_view), first_view), "page indicator", page_label(first_view))
        H.shot("shelf_page1")
    end)

    local target_page
    H.step("paginate with Next / Previous", function()
        local seen, all = {}, {}
        local view = first_view
        local count = view.page_count
        for page = 1, count do
            local titles = page_titles(view)
            H.check(#titles > 0 and #titles <= view.page_size, "rows on page " .. page, tostring(#titles))
            for _i, title in ipairs(titles) do
                H.check(not seen[title], "title not repeated across pages", title)
                seen[title] = page
                all[#all + 1] = title
            end
            if page < count then
                local old = view
                tap_exact(H.tr("Next"), shelf_view)
                view = wait_shelf("page " .. (page + 1), old, function(v) return v.page == page + 1 end)
                H.check(H.has_text(page_label(view), view), "indicator on page " .. (page + 1), page_label(view))
                if page == 1 then H.shot("shelf_page2") end
            end
        end
        H.equal(#all, 26, "26 distinct titles over all pages")
        target_page = seen[TARGET]
        H.check(target_page, "target book listed", TARGET)
        local last_titles = page_titles(view)
        local old = view
        tap_exact(H.tr("Previous"), shelf_view)
        view = wait_shelf("previous page", old, function(v) return v.page == count - 1 end)
        local previous_titles = page_titles(view)
        H.check(previous_titles[1] ~= last_titles[1], "Previous shows different titles")
        H.equal(seen[previous_titles[1]], count - 1, "Previous shows the earlier page's titles")
        H.check(H.has_text(page_label(view), view), "indicator after Previous", page_label(view))
    end)

    H.step("switch shelf group", function()
        local view = shelf_view()
        local all_label = (H.tr("Books · %1"):gsub("%%1", H.tr("All")))
        H.call(function() view:showSourceMenu() end)
        tap_exact("旅途")
        local group_view = wait_shelf("group 旅途", view, function(v) return v.group_label == "旅途" end)
        H.equal(#group_view.books, 15, "books in group 旅途")
        H.equal(group_view.page, 1, "group starts at page 1")
        H.check(H.has_text((H.tr("Books · %1"):gsub("%%1", "旅途")), group_view), "header names the group")
        H.shot("shelf_group")
        H.call(function() group_view:showSourceMenu() end)
        tap_exact(H.tr("All books"))
        local back = wait_shelf("all books again", group_view, function(v) return v.group_label == nil end)
        H.equal(#back.books, 26, "All view restored")
        H.check(H.has_text(all_label, back), "header back to All", all_label)
    end)

    H.step("re-tapping the active filter clears it", function()
        local option = H.tr("Only show unfinished books")
        local function shelf_settings()
            return H.call(function() return plugin.settings:get("shelf") or {} end)
        end
        local function choose_filter(view)
            H.call(function() view.on_filter() end)
            tap_exact(option, function()
                for _i, entry in ipairs(UIManager._window_stack or {}) do
                    if H.has_text(H.tr("Filter by"), entry.widget) then return entry.widget end
                end
            end)
        end
        local view = shelf_view()
        choose_filter(view)
        local filtered = wait_shelf("unfinished filter on", view, function(v)
            return v.filter_label == H.tr("Unfinished")
        end)
        H.equal(shelf_settings().filter_reading, "unfinished", "filter saved")
        H.equal(#filtered.books, 26, "mock books are all unfinished")
        choose_filter(filtered)
        local cleared = wait_shelf("filter cleared by the second tap", filtered, function(v)
            return v.filter_label == H.tr("All")
        end)
        H.equal(shelf_settings().filter_reading, nil, "cleared filter saved")
        H.equal(#cleared.books, 26, "All view after clearing")
    end)

    H.step("taps before the first paint do not crash", function()
        H.close_dialogs()
        H.check(not shelf_view(), "shelf closed")
        local outcome = H.call(function()
            local Event = require("ui/event")
            local Geom = require("ui/geometry")
            local time = require("ui/time")
            local Screen = require("device").screen
            -- Cached shelf: shown synchronously, nothing painted yet.
            plugin:showBookshelf()
            local view = plugin.shelf_view
            local row = view._item_rows[1]
            local result = {
                unpainted = row.frame.dimen == nil,
                direct = row:onTapShelfRow(),
            }
            -- Queued taps: one inside the rows' (0, 0) placeholder range,
            -- one where the first row is going to be painted.
            for _i, pos in ipairs({ { Screen:getWidth() - 40, 10 }, { 300, 150 } }) do
                UIManager:sendEvent(Event:new("Gesture", {
                    ges = "tap",
                    pos = Geom:new{ x = pos[1], y = pos[2], w = 0, h = 0 },
                    time = time.now(),
                }))
            end
            result.view = view
            return result
        end)
        H.check(outcome.unpainted, "row was not painted when tapped")
        H.check(outcome.direct == false, "unpainted row lets the tap propagate", tostring(outcome.direct))
        H.sleep(1)
        H.check(H.call(function() return true end), "UI loop alive")
        local view = H.wait_until("pre-tapped shelf still shown and painted", function()
            local v = shelf_view()
            return v == outcome.view and v._item_rows[1].frame.dimen and v or nil
        end, 10)
        H.check(not plugin._book_detail_view, "no book opened by a stray tap")
        H.shot("shelf_after_prepaint_taps")
        -- A painted row now handles a direct tap.
        H.check(painted(view._item_rows[1].frame.dimen), "row painted")
    end)

    H.step("tap title → book page → 6 chapters", function()
        local view = shelf_view()
        if view.page ~= target_page then
            H.call(function() view:requestPage(target_page) end)
            view = wait_shelf("target page", view, function(v) return v.page == target_page end)
        end
        local t0 = H.now_ms()
        tap_exact(TARGET, shelf_view)
        local detail = H.wait_until("book detail view", function()
            local d = plugin._book_detail_view
            return d and UIManager:isWidgetShown(d) and H.has_text(H.tr("☷ Chapter list"), d) and d or nil
        end, 30)
        H.metric("book_detail_ms", H.now_ms() - t0)
        H.check(H.has_text(TARGET, detail), "detail shows the title")
        H.check(H.has_text("测试作者", detail), "detail shows the author")
        -- The shelf snapshot already carries the details (no /book/info).
        H.check(H.has_text(TARGET, detail) and detail.data and detail.data.title == TARGET, "detail is for the tapped book")
        H.shot("book_detail")
        t0 = H.now_ms()
        tap_exact(H.tr("☷ Chapter list"), function() return plugin._book_detail_view end)
        local list = H.wait_until("chapter list view", function()
            local l = plugin._chapter_list_view
            return l and UIManager:isWidgetShown(l) and l or nil
        end, 30)
        H.metric("chapter_list_ms", H.now_ms() - t0)
        H.equal(#list.chapters, 6, "6 chapters in the catalog")
        H.check(#H.mock_requests(function(event) return event.path == "/web/book/chapterInfos" end) >= 1,
            "catalog fetched from the mock")
        H.wait_until("chapter rows painted", function() return H.has_text(CHAPTERS[6], list) end, 10)
        for _i, title in ipairs(CHAPTERS) do
            H.check(H.has_text(title, list), "chapter row", title)
        end
        H.shot("chapter_list")
    end)

    H.step("close everything", function()
        H.close_dialogs()
        H.wait_until("all WeRead windows closed", function()
            return not shelf_view() and not plugin._chapter_list_view and not plugin._book_detail_view
                and H.top_window() == H.file_manager()
        end, 10)
        H.check(H.call(function() return true end), "UI loop alive after closing")
    end)
end
