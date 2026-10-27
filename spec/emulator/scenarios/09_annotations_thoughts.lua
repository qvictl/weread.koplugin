-- @title Annotations: synced underline is drawn, tapping it opens the thought popup
-- @timeout 150
-- A chapter of 900001 is downloaded through the plugin's chapter dialog and
-- opened via "Read now". The unified annotation sync fetches the chapter's
-- underline and thought from the mock (subprocess + SQLite), matches them to
-- document positions and draws the underline on the quote. A real tap on
-- the drawn underline opens the centered thought popup with the synthetic
-- thought; it pages with its Next button, closes with a tap outside, and the
-- reader keeps turning pages afterwards.
local BOOK_ID = "900001"
local QUOTE = "窗外的风穿过树梢，带来远处山谷的回声。"
local THOUGHT = "这是一条合成想法"

return function(H)
    local tr = H.tr

    local function has_dimen(widget)
        local d = rawget(widget, "dimen")
        return type(d) == "table" and type(d.x) == "number" and type(d.w) == "number"
            and d.w > 0 and d.h > 0
    end

    local function find_exact(label)
        local found
        H.walk(function(widget, chain, depth)
            if rawget(widget, "text") == label then
                for i = depth, 1, -1 do
                    if has_dimen(chain[i]) then
                        found = chain[i]
                        return true
                    end
                end
            end
        end)
        return found
    end

    local function tap_exact(label, timeout)
        local target = H.wait_until("button '" .. label .. "' painted", function()
            return find_exact(label)
        end, timeout or 15)
        local x = math.floor(target.dimen.x + target.dimen.w / 2)
        local y = math.floor(target.dimen.y + target.dimen.h / 2)
        H.log("tap button", label, "@", x, y)
        return H.tap_at(x, y)
    end

    local function annotation_requests()
        return #H.mock_requests(function(event)
            return event.api == "/book/underlines" or event.api == "/book/readreviews"
        end)
    end

    local function popup_showing()
        return require("weread.ui.thought_popup").isShowing()
    end

    local function popup_widget()
        local plugin = H.plugin()
        return plugin and plugin._current_thought_popup or nil
    end

    local chapter

    H.step("download chapter 1 through the plugin and open it", function()
        H.wait_until("weread plugin on FileManager", function() return H.plugin() end, 20)
        H.call(function()
            local settings = H.runtime().settings
            local cache = settings:get("cache")
            cache.show_annotations = true
            settings:set("cache", cache)
            settings:flush()
            local plugin = H.plugin()
            local book = plugin.client:get_book_info(BOOK_ID)
            plugin.settings:put_book(BOOK_ID, book)
            plugin.settings:flush()
            book = plugin.settings:get_book(BOOK_ID)
            plugin:loadChapters(book, function(list)
                chapter = list[1]
                plugin:downloadChapterAndRead(book, list[1])
            end)
        end)
        H.wait_until("chapter catalog loaded", function() return chapter end, 20)
        tap_exact(tr("Download"))
        tap_exact(tr("Read now"), 60)
        H.wait_until("ReaderUI ready", function()
            local reader = H.reader()
            return reader and reader.document and reader.postReaderReadyCallback == nil and reader.weread
        end, 30)
        H.check(H.call(function() return H.plugin():_xpointerOverlayPrototypeAvailable() end),
            "overlay available for the downloaded EPUB")
    end)

    H.step("sync underlines and thoughts for the open chapter", function()
        local before = annotation_requests()
        local plugin = H.plugin()
        H.call(function() plugin:startUnifiedAnnotationSync{ chapters = { chapter } } end)
        H.wait_until("annotation sync started", function()
            return plugin._external_annotation_sync ~= nil
        end, 15)
        local started = H.now_ms()
        H.wait_until("annotation sync finished", function()
            return plugin._external_annotation_sync == nil
        end, 40)
        H.metric("annotation_sync_ms", H.now_ms() - started)
        H.check(annotation_requests() >= before + 2, "underlines and thoughts fetched from the mock",
            tostring(annotation_requests() - before))
        local stored = H.call(function()
            local context = plugin:_prepareAnnotationContext(false)
            local uid = tostring(chapter.chapterUid)
            local source = context.store:get(BOOK_ID, "source", uid)
            local projection = context.store:get(BOOK_ID, "projection",
                context.store:projectionKey(context.document_key, uid))
            return {
                underlines = source and #(source.underlines or {}) or 0,
                mark = source and source.underlines and source.underlines[1]
                    and source.underlines[1].markText,
                reviews = source and #(source.reviews or {}) or 0,
                records = projection and #(projection.records or {}) or 0,
            }
        end)
        H.equal(stored.underlines, 1, "stored underlines for the chapter")
        H.equal(stored.mark, QUOTE, "stored underline quote")
        H.check(stored.reviews >= 1, "stored thoughts for the underline", tostring(stored.reviews))
        H.equal(stored.records, 1, "underline located in the document")
        H.close_dialogs() -- completion notice, if any
    end)

    local target
    H.step("underline is drawn on the quote on page 1", function()
        H.call(function()
            H.reader().rolling:onGotoPage(1)
        end)
        local overlay_state = H.wait_until("underline painted on page 1", function()
            local overlay = H.plugin()._xpointer_overlay
            if not overlay or #overlay.records == 0 then return nil end
            require("ui/uimanager"):forceRePaint()
            if #overlay.visible == 0 then return nil end
            return { records = #overlay.records, boxes = #overlay.visible, record = overlay.visible[1].record }
        end, 15)
        H.equal(overlay_state.records, 1, "overlay records")
        H.check(tostring(overlay_state.record.text or ""):find(QUOTE, 1, true),
            "drawn record is the synced quote", tostring(overlay_state.record.text))
        H.metric("underline_boxes", overlay_state.boxes)
        -- Tap the widest box (outside the page-turn edge zones).
        target = H.call(function()
            local overlay = H.plugin()._xpointer_overlay
            local width = H.screen():getWidth()
            local best
            for _i, entry in ipairs(overlay.visible) do
                local rect = entry.rect
                local x = rect.x + rect.w / 2
                if x > width * 0.25 and x < width * 0.75 and (not best or rect.w > best.w) then
                    best = rect
                end
            end
            return best and { x = math.floor(best.x + best.w / 2), y = math.floor(best.y + best.h / 2) }
        end)
        H.check(target, "an underline box away from the page-turn edges")
        H.shot("09-01-underline")
    end)

    local pages
    H.step("tapping the underline opens the thought popup", function()
        local page = H.call(function() return H.reader():getCurrentPage() end)
        H.log("tap underline @", target.x, target.y)
        H.tap_at(target.x, target.y)
        H.wait_until("thought popup shown", popup_showing, 10)
        H.wait_until("thought popup painted", function()
            local popup = popup_widget()
            return popup and popup._painted
        end, 10)
        H.equal(H.call(function() return H.reader():getCurrentPage() end), page,
            "the underline tap did not turn the page")
        local info = H.call(function()
            local popup = popup_widget()
            local first = popup.items and popup.items[1]
            return {
                content = first and first.content,
                abstract = first and first.abstract,
                pages = popup._page_starts and #popup._page_starts or 0,
                index = popup.page_index,
            }
        end)
        H.check(type(info.content) == "string" and info.content:find(THOUGHT, 1, true),
            "popup shows the synthetic thought", tostring(info.content))
        H.check(tostring(info.abstract or ""):find(QUOTE, 1, true) ~= nil, "popup is about the tapped quote")
        H.equal(info.index, 1, "popup opens on its first page")
        H.check(H.has_text("1 / " .. info.pages), "page indicator painted", "1 / " .. info.pages)
        pages = info.pages
        H.metric("popup_pages", pages)
        H.shot("09-02-thought-popup")
    end)

    H.step("popup pages with its Next button", function()
        H.check(pages > 1, "long synthetic thought spans several popup pages", tostring(pages))
        tap_exact(tr("Next") .. " ›")
        H.wait_until("popup on page 2", function()
            local popup = popup_widget()
            return popup and popup.page_index == 2
        end, 10)
        H.wait_text("2 / " .. pages, 10)
        H.shot("09-03-thought-popup-page-2")
    end)

    H.step("tap outside closes the popup; reader stays responsive", function()
        local box = H.call(function() return popup_widget().container.dimen end)
        H.check(box.y > 4, "room above the popup for an outside tap")
        H.tap_at(math.floor(H.screen():getWidth() / 2), math.floor(box.y / 2))
        H.wait_until("thought popup closed", function() return not popup_showing() end, 10)
        H.check(H.top_window() == H.reader(), "reader is the top window again")
        local page = H.call(function() return H.reader():getCurrentPage() end)
        local screen = H.screen()
        H.tap_at(math.floor(screen:getWidth() * 0.92), math.floor(screen:getHeight() * 0.5))
        H.wait_until("page turn after closing the popup", function()
            return H.reader():getCurrentPage() > page
        end, 10)
        H.check(not popup_showing(), "edge tap did not reopen a popup")
        H.shot("09-04-after-popup")
    end)
end
