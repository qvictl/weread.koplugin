-- @title Offline shelf snapshot survives a shelf entry without a book id
-- @timeout 90
-- The first shelf open syncs from the service and stores the snapshot in
-- the library database; the second open must be served from that snapshot
-- without another /shelf/sync. The synced shelf contains one entry without
-- any book id: it is skipped, it must not roll the whole snapshot back
-- (which made every later open hit the network again, or fail offline).
return function(H)
    local UIManager = require("ui/uimanager")

    local plugin

    local function shelf_view()
        local view = plugin.shelf_view
        return view and UIManager:isWidgetShown(view) and view or nil
    end

    local function wait_shelf(description, old)
        return H.wait_until(description, function()
            local view = shelf_view()
            if not view or view == old then return nil end
            local rows = view._item_rows or {}
            local dimen = rows[1] and rows[1].frame and rows[1].frame.dimen
            if not (type(dimen) == "table" and (dimen.w or 0) > 0) then return nil end
            return view
        end, 30)
    end

    local function shelf_syncs()
        return #H.mock_requests(function(event) return event.api == "/shelf/sync" end)
    end

    local function close_shelf()
        H.close_dialogs()
        H.wait_until("shelf closed", function() return not shelf_view() end, 10)
    end

    H.step("plugin ready", function()
        plugin = H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        H.mock_control({ shelf_idless_entry = true })
    end)

    local first
    H.step("first open syncs the shelf", function()
        H.call(function() plugin:showBookshelf() end)
        first = wait_shelf("shelf painted after sync")
        H.equal(shelf_syncs(), 1, "one /shelf/sync request")
        local stored = H.call(function()
            local books = plugin.library_db and plugin.library_db:getShelf() or nil
            return books and #books or nil
        end)
        H.equal(stored, 26, "snapshot stored in the library database")
        close_shelf()
    end)

    H.step("second open uses the stored snapshot", function()
        H.call(function() plugin:showBookshelf() end)
        local view = wait_shelf("shelf painted from the snapshot", first)
        H.equal(view.total_books, 26, "all books with an id from the snapshot")
        H.equal(shelf_syncs(), 1, "no second /shelf/sync request")
        H.shot("shelf_from_snapshot")
        close_shelf()
        H.mock_control({ shelf_idless_entry = false })
    end)
end
