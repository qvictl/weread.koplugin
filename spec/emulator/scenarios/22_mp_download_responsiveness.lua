-- @title MP article worker publication, real cancellation and account isolation
-- @timeout 90
-- @no_coverage Timing measures the real event loop, without LuaCov overhead.
return function(H)
    local prepare_login = dofile(os.getenv("WEREAD_TEST_HARNESS_DIR") .. "/qr_credentials.lua")
    local UIManager = require("ui/uimanager")
    local Content = require("weread.lib.content")
    local lfs = require("libs/libkoreader-lfs")
    local plugin, book, path, old_bytes, old_image
    local article = { reviewId = "mock-mp-article", bookId = "MP_WXS_900000", title = "Synthetic article" }
    local function read(name)
        local file = assert(io.open(name, "rb")); local bytes = file:read("*a"); file:close(); return bytes
    end
    local function workspaces()
        local count = 0
        for name in lfs.dir(book.cache_dir) do
            if name:match("^%.weread%-download%-%d+%-%d+$") then count = count + 1 end
        end
        return count
    end
    local function seed()
        path = Content.save_mp_article_html(plugin.settings, book, article,
            '<p>Old article body.</p><img src="legacy-assets/old.png"/>')
        require("util").makePath(book.cache_dir .. "/legacy-assets")
        old_image = book.cache_dir .. "/legacy-assets/old.png"
        local file = assert(io.open(old_image, "wb")); file:write("previous image bytes"); file:close()
        old_bytes = read(path)
    end
    local function with_hook(object, key, replacement, action)
        local original
        H.call(function() original = object[key]; object[key] = replacement end)
        local ok, err = xpcall(action, debug.traceback)
        H.call(function() object[key] = original end)
        if not ok then error(err, 0) end
    end
    H.step("setup", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            book = { book_id = "MP_WXS_900000", title = "合成公众号" }
            local cache = plugin.settings:get("cache"); cache.download_mp_images = true
            plugin.settings:set("cache", cache)
            seed()
            plugin.settings:put_book(book.book_id, book)
            plugin.settings:flush()
        end)
    end)
    for _, endpoint in ipairs({ "/web/mp/content", "/mock/illustration.png" }) do
        H.step("cancel during " .. endpoint, function()
            local previous = H.input_window()
            local workspace
            local arrived_before = H.mock_state().started_counts[endpoint] or 0
            local create = Content.create_download_workspace
            H.mock_control({ match = endpoint, delay = 1.5, times = 0 })
            with_hook(Content, "create_download_workspace", function(...)
                workspace = create(...)
                return workspace
            end, function()
                H.call(function() plugin:downloadMPArticleAndRead(book, article) end)
                H.wait_until("actual article worker running", function()
                    local job = plugin.downloader._active_job
                    return job and job.worker_handle
                        and (H.mock_state().started_counts[endpoint] or 0) > arrived_before
                        and (endpoint == "/web/mp/content"
                        or job.stage_title:find(H.tr("Downloading images: %1"):gsub("%%1", ""), 1, true))
                end, 8)
            end)
            local started = H.now_ms()
            H.tap_exact(H.tr("Cancel download"))
            H.wait_until("cancel tap dismisses the download dialog", function()
                return H.input_window() == previous
            end, 5)
            local elapsed = H.now_ms() - started
            H.wait_until("cancelled worker collected and staging removed", function()
                return not plugin.downloader._active_job and not plugin.downloader.background_worker.job
                    and workspace and not lfs.attributes(workspace.path)
            end, 8)
            H.metric(endpoint == "/web/mp/content" and "mp_content_cancel_ms" or "mp_image_cancel_ms", elapsed)
            H.check(elapsed < 800, "cancel completes within original UI budget", tostring(elapsed))
            H.equal(read(path), old_bytes, "cancel preserves previously published article")
            H.equal(read(old_image), "previous image bytes", "cancel preserves prior image resources")
            H.equal(workspaces(), 0, "cancel removes article workspace")
            H.equal(H.input_window(), previous, "cancel does not open a reader")
            H.mock_control({ match = "", delay = 0, times = 0 })
        end)
    end
    H.step("publication rename failure preserves old resources", function()
        local rename = os.rename
        local injected = false
        with_hook(os, "rename", function(from, to)
            if not injected and to == path and from:find("/.weread-download-", 1, true) then
                injected = true
                return nil, "injected article publication failure"
            end
            return rename(from, to)
        end, function()
            H.call(function() plugin:downloadMPArticleAndRead(book, article) end)
            H.wait_until("failed publication released downloader", function()
                return injected and not plugin.downloader._active_job
            end, 10)
        end)
        H.equal(read(path), old_bytes, "failed commit preserves old article bytes")
        H.equal(read(old_image), "previous image bytes", "failed commit preserves prior image resources")
        H.equal(workspaces(), 0, "failed commit removes partial staging")
        H.equal(plugin.downloader._standby_ref or 0, 0, "failed commit releases standby")
        H.close_dialogs()
    end)
    H.step("queued QR completion discards an old-account download", function()
        local apply_login = prepare_login(H, plugin)
        H.mock_control({ match = "/web/mp/content", delay = 1.5, times = 0 })
        local previous_record = { book_id = book.book_id, cache_dir = H.env.evidence .. "/previous-directory" }
        H.call(function()
            plugin.settings:put_book(book.book_id, previous_record)
            plugin.library_db:putBook(previous_record)
            plugin.settings:set("account", { user_vid = "900099" })
            plugin:downloadMPArticleAndRead(book, article)
            UIManager:scheduleIn(0.35, function()
                apply_login()
            end)
        end)
        H.wait_until("new login and old worker completion", function()
            return plugin.settings:get("account", {}).user_vid == "900000"
                and not plugin.downloader._active_job and not plugin.downloader.background_worker.job
        end, 10)
        H.equal(read(path), old_bytes, "account switch preserves old article bytes")
        H.equal(read(old_image), "previous image bytes", "account switch preserves prior image resources")
        H.equal(workspaces(), 0, "account switch removes old job workspace")
        H.check(not H.reader(), "account discard does not open old article")
        H.equal(plugin.settings:get_book(book.book_id).cache_dir, previous_record.cache_dir,
            "old job cannot rewrite BookRecords under new account")
        H.equal(plugin.library_db:getBook(book.book_id).cache_dir, previous_record.cache_dir,
            "old job cannot rewrite new-account SQLite")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)
    H.step("delayed successful download stays responsive and opens matching assets", function()
        H.mock_control({ match = "/web/mp/content", delay = 1.5, times = 0 })
        local running, last, max_gap = true, H.now_ms(), 0
        local function beat()
            if not running then return end
            local now = H.now_ms(); max_gap, last = math.max(max_gap, now - last), now
            UIManager:scheduleIn(0.05, beat)
        end
        H.call(function() beat(); plugin:downloadMPArticleAndRead(book, article) end)
        H.wait_until("downloaded HTML opened", function() return H.reader() end, 15)
        H.call(beat); running = false
        H.metric("mp_download_heartbeat_gap_ms", max_gap)
        H.check(max_gap < 800, "article download keeps event loop responsive", tostring(max_gap))
        local html = read(path)
        H.check(html:find("Synthetic article body.", 1, true), "new article body published")
        local image = html:match('src="([^" ]+%.png)"')
        H.check(image and image:match("^%.weread%-mp%-.+-assets%-%d+%-%d+/"), "HTML refers to a versioned local image")
        H.check(lfs.attributes(book.cache_dir .. "/" .. image, "mode") == "file", "referenced image actually published")
        H.equal(plugin.settings:get_book(book.book_id).cache_dir, book.cache_dir, "parent record has final directory")
        H.equal(workspaces(), 0, "successful worker workspace removed")
        H.equal(read(old_image), "previous image bytes", "redownload keeps resources other HTML can reference")
        H.equal(plugin.downloader._standby_ref or 0, 0, "success releases standby")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)
end
