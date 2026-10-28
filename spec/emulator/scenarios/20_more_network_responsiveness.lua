-- @title Reviews, catalogs, statistics and cache scans keep the UI responsive
-- @timeout 100
-- @no_coverage Timing measures the real event loop, without LuaCov overhead.
return function(H)
    local UIManager = require("ui/uimanager")
    local TrapWidget = require("ui/widget/trapwidget")
    local Content = require("weread.lib.content")
    local lfs = require("libs/libkoreader-lfs")
    local ffiutil = require("ffi/util")
    local plugin, book, catalog_done
    local imported, new_dir = {}, H.env.evidence .. "/new-cache"
    H.step("setup", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        book = H.call(function()
            local target = H.runtime().client:get_book_info("900001")
            for index, id in ipairs({ "900002", "900003" }) do
                local fixture = { book_id = id, title = "Synthetic imported book " .. index }
                if index == 2 then fixture.cache_dir = new_dir .. "/" .. id end
                imported[id] = Content.save_chapter_epub(plugin.settings, fixture,
                    { chapterUid = 1, title = "Imported chapter" }, "<p>Synthetic import fixture</p>", {}, "")
            end
            return target
        end)
    end)
    local cases = {
        { name = "reviews", api = "/review/list", start = function() plugin:showBookReviews(book) end },
        { name = "catalog", api = "/web/book/chapterInfos", start = function()
            catalog_done = false
            plugin:loadChapters(book, function() catalog_done = true end, true)
        end },
        { name = "statistics", api = "/readdata/detail", start = function() plugin:loadReadStats("monthly") end },
        { name = "scan", api = "/shelf/sync", start = function() plugin:confirmScanLocalCache() end },
        { name = "new_dir", api = "/shelf/sync", start = function()
            plugin:offerScanNewDir(new_dir, "Synthetic scan finished")
        end },
    }
    local gaps = {}
    for _, case in ipairs(cases) do
        H.step(case.name .. " network delay", function()
            H.mock_control({ match = case.api, delay = 1.5, times = 0 })
            local running, last, max_gap = true, H.now_ms(), 0
            local function beat()
                if not running then return end
                local now = H.now_ms()
                max_gap, last = math.max(max_gap, now - last), now
                UIManager:scheduleIn(0.05, beat)
            end
            local prior = #H.mock_requests(function(event) return event.api == case.api or event.path == case.api end)
            H.call(function() beat(); case.start() end)
            H.sleep(0.2)
            H.wait_until(case.name .. " completed", function()
                local count = #H.mock_requests(function(event) return event.api == case.api or event.path == case.api end)
                local top = H.input_window()
                return count > prior and not plugin.busy_message
                    and (not top or getmetatable(top) ~= TrapWidget)
            end, 20)
            if case.name == "reviews" then
                local view = H.input_window()
                H.equal(view.book_title, book.title, "review view belongs to requested book")
                H.equal(#view.result.items, 1, "mock review rendered in parent view")
            elseif case.name == "statistics" then
                H.equal(H.input_window().data.mode, "monthly", "requested statistics view rendered")
                H.equal(H.input_window().data.total_read_time, 7200, "mock statistics actually rendered")
            elseif case.name == "catalog" then
                H.check(catalog_done, "catalog callback delivered in parent")
                H.equal(#plugin.library_db:getChapters("900001"), 6, "catalog persisted in SQLite")
                H.equal(#Content.load_catalog_cache(plugin.client, plugin.settings, book), 6,
                    "worker catalog published to final cache")
            elseif case.name == "new_dir" then
                H.tap_exact(H.tr("Import"))
                H.wait_until("new directory import persisted", function()
                    return plugin.settings:get_book("900003")
                end, 5)
            end
            local imported_id = case.name == "scan" and "900002" or case.name == "new_dir" and "900003"
            if imported_id then
                local record = plugin.settings:get_book(imported_id)
                H.equal(record.cached_file, imported[imported_id], "real EPUB imported into BookRecords")
                H.equal(plugin.library_db:getBook(imported_id).cache_dir, record.cache_dir,
                    "same import persisted in account SQLite")
                H.call(function() plugin:showBookMenu(record) end)
                H.equal(plugin._book_detail_view.data.title, record.title, "imported book opens its parent view")
            end
            H.sleep(0.1)
            running = false
            gaps[case.name] = max_gap
            H.metric(case.name .. "_heartbeat_gap_ms", max_gap)
            H.mock_control({ match = "", delay = 0, times = 0 })
            H.call(function() plugin:closeWeReadUI() end)
            H.close_dialogs()
        end)
    end
    H.step("UI budget", function()
        for name, gap in pairs(gaps) do
            H.check(gap < 800, name .. " request keeps the event loop responsive", tostring(gap))
        end
    end)
    for _, case in ipairs(cases) do
        H.step(case.name .. " cancellation", function()
            local previous = H.input_window()
            local prior = #H.mock_requests(function(event) return event.api == case.api or event.path == case.api end)
            book.psvts = "parent-session"
            H.mock_control({ match = case.api, delay = 1.5, times = 0 })
            H.call(case.start)
            H.wait_until("dismissable request shown", function()
                return getmetatable(H.input_window()) == TrapWidget
            end, 5)
            H.sleep(0.2)
            local started = H.now_ms()
            H.tap_at(580, 20)
            H.wait_until("request dismissed", function() return H.input_window() == previous end, 5)
            local elapsed = H.now_ms() - started
            H.metric(case.name .. "_cancel_ms", elapsed)
            H.check(elapsed < 800, "tap cancels without waiting for HTTP", tostring(elapsed))
            H.equal(plugin.busy_message, nil, "busy state released on cancel")
            H.sleep(1.7)
            H.check(#H.mock_requests(function(event) return event.api == case.api or event.path == case.api end) > prior,
                "cancelled worker reached the delayed endpoint")
            H.equal(H.input_window(), previous, "cancelled response does not reopen UI")
            if case.name == "catalog" then
                H.check(not catalog_done, "cancelled catalog does not call its parent callback")
                H.equal(book.psvts, "parent-session", "cancelled reader state does not overwrite parent state")
            end
            H.mock_control({ match = "", delay = 0, times = 0 })
        end)
    end
    H.step("reader URL alone stages and publishes a catalog under its resolved ID", function()
        local target = { reader_url = require("weread.lib.protocol").reader_url("900005") }
        local delivered
        H.call(function() plugin:loadChapters(target, function(chapters) delivered = chapters end, true) end)
        H.wait_until("URL-only catalog delivered", function() return delivered end, 10)
        H.equal(target.book_id, "900005", "reader URL resolves book identity")
        H.equal(#Content.load_catalog_cache(plugin.client, plugin.settings, target), 6,
            "URL-only catalog published to resolved book directory")
        H.equal(#plugin.library_db:getChapters("900005"), 6, "URL-only catalog persisted to SQLite")
    end)
    H.step("cancel while the child holds a complete staged catalog", function()
        local original_save, original_prepare = Content.save_catalog_cache, Content.create_download_workspace
        local workspace, callback, old_bytes
        local path = Content.catalog_cache_path(plugin.settings, book)
        local function read_file(name)
            local file = assert(io.open(name, "rb")); local bytes = file:read("*a"); file:close(); return bytes
        end
        old_bytes = read_file(path)
        local observed, observe_err = xpcall(function()
            H.call(function()
                Content.create_download_workspace = function(...)
                    workspace = original_prepare(...)
                    return workspace
                end
                Content.save_catalog_cache = function(...)
                    local ok, value = original_save(...)
                    -- Parent observes the staged file then cancels this worker;
                    -- there is no expiring observation window.
                    while not lfs.attributes(workspace.path .. "/parent-released", "mode") do
                        ffiutil.usleep(10000)
                    end
                    return ok, value
                end
                plugin:loadChapters(book, function() callback = true end, true)
            end)
            H.wait_until("child has written complete staged catalog", function()
                return workspace and lfs.attributes(workspace.path .. "/catalog.json", "mode") == "file"
                    and getmetatable(H.input_window()) == TrapWidget
            end, 10)
        end, debug.traceback)
        H.call(function() Content.save_catalog_cache, Content.create_download_workspace = original_save, original_prepare end)
        if not observed then
            if workspace then
                local release = io.open(workspace.path .. "/parent-released", "wb")
                if release then release:close() end
            end
            error(observe_err, 0)
        end
        H.tap_at(580, 20)
        H.wait_until("catalog staging cleaned on cancellation", function()
            return not lfs.attributes(workspace.path) and not plugin.busy_message
        end, 5)
        H.equal(read_file(path), old_bytes, "cancel preserves previously published catalog bytes")
        H.check(not callback, "cancelled staged catalog does not deliver parent callback")
    end)
    H.step("account switch discards a worker catalog before publication", function()
        local original_prepare = Content.create_download_workspace
        local workspace, callback
        local path = Content.catalog_cache_path(plugin.settings, book)
        local file = assert(io.open(path, "rb")); local old_bytes = file:read("*a"); file:close()
        book.psvts = "parent-account-session"
        H.mock_control({ match = "/web/book/chapterInfos", delay = 1.5, times = 0 })
        local completed, complete_err = xpcall(function()
            H.call(function()
                plugin.library_db:putChapters("900001", {})
                plugin.settings:set("account", { user_vid = "900099" })
                Content.create_download_workspace = function(...)
                    workspace = original_prepare(...)
                    return workspace
                end
                plugin:loadChapters(book, function() callback = true end, true)
                UIManager:scheduleIn(0.35, function()
                    plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                        accessToken = "mock-access-token", refreshToken = "mock-refresh-token" },
                        plugin.qr_login.generation)
                end)
            end)
            H.wait_until("new account signed in and old catalog discarded", function()
                return workspace and plugin.settings:get("account", {}).user_vid == "900000"
                    and not plugin.busy_message and not lfs.attributes(workspace.path)
            end, 10)
        end, debug.traceback)
        H.call(function() Content.create_download_workspace = original_prepare end)
        if not completed then error(complete_err, 0) end
        H.mock_control({ match = "", delay = 0, times = 0 })
        file = assert(io.open(path, "rb")); local current = file:read("*a"); file:close()
        H.equal(current, old_bytes, "account discard preserves published catalog")
        H.equal(plugin.library_db:getChapters("900001"), nil, "old catalog not written into new account SQLite")
        H.equal(book.psvts, "parent-account-session", "old response does not overwrite parent session")
        H.check(not callback, "discarded catalog does not invoke parent callback")
        H.close_dialogs()
    end)
    H.step("QR completion after a real scan checkpoint isolates subsequent writes", function()
        local root = H.env.evidence .. "/slow-cache"
        local attributes = lfs.attributes
        local schedule, refresh = UIManager.scheduleIn, plugin.refreshCacheManagement
        local checkpoint_seen, qr_completed, refreshed, writes = false, false, false, {}
        local put_book = plugin.settings.put_book
        local previous_dir = plugin.settings.cache_dir
        local scanned, scan_err = xpcall(function()
            H.call(function()
                require("util").makePath(root .. "/900004")
                for index = 1, 1000 do
                    local file = assert(io.open(root .. "/900004/" .. index .. ".epub", "wb")); file:close()
                end
                plugin.settings:set("account", { user_vid = "900099" })
                plugin.settings.cache_dir = root
                lfs.attributes = function(path, ...)
                    if path:sub(1, #root + 1) == root .. "/" then ffiutil.usleep(1000) end
                    return attributes(path, ...)
                end
                plugin.settings.put_book = function(self, id, value)
                    writes[#writes + 1] = self:get("account", {}).user_vid
                    return put_book(self, id, value)
                end
                plugin.refreshCacheManagement = function() refreshed = true end
                UIManager.scheduleIn = function(self, delay, fn, ...)
                    if plugin._cache_import and not checkpoint_seen then
                        checkpoint_seen = true
                        schedule(self, delay, function()
                            plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                                accessToken = "mock-access-token", refreshToken = "mock-refresh-token" },
                                plugin.qr_login.generation)
                        end)
                    end
                    return schedule(self, delay, fn, ...)
                end
                plugin:confirmScanLocalCache()
            end)
            H.wait_until("queued real QR completion stops old-account scan", function()
                qr_completed = plugin.settings:get("account", {}).user_vid == "900000"
                return checkpoint_seen and qr_completed and not plugin._cache_import and not plugin.busy_message
            end, 15)
        end, debug.traceback)
        H.call(function()
            lfs.attributes, UIManager.scheduleIn = attributes, schedule
            plugin.refreshCacheManagement, plugin.settings.put_book = refresh, put_book
            plugin.settings.cache_dir = previous_dir
        end)
        if not scanned then error(scan_err, 0) end
        H.equal(#writes, 0, "scan stopped before committing a partially inspected old-account book")
        H.equal(plugin.settings:get_book("900004"), nil, "new account BookRecords remains untouched")
        H.equal(plugin.library_db:getBook("900004"), nil, "new account SQLite remains untouched")
        H.check(not refreshed, "discarded scan does not reopen cache UI")
    end)

end
