-- @title Metadata-scale cache import responsiveness and correctness
-- @timeout 300
-- @no_coverage The fixture has real files; it is opt-in, not part of CI shards.
return function(H)
    local UIManager = require("ui/uimanager")
    local root = assert(os.getenv("WEREAD_SCAN_ROOT"))
    local count = assert(tonumber(os.getenv("WEREAD_SCAN_BOOKS")))
    local chapters = assert(tonumber(os.getenv("WEREAD_SCAN_CHAPTERS")))
    local plugin
    local function marker(name)
        local file = assert(io.open(H.env.evidence .. "/" .. name, "wb"))
        file:write("ready"); file:close()
    end
    H.step("seed real metadata for moved cached chapters", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            plugin.settings.cache_dir = root
            for index = 0, count - 1 do
                local id = tostring(950000 + index)
                local old = root .. "/_previous/" .. id
                local cached = {}
                for chapter = 1, chapters do
                    cached[tostring(chapter)] = old .. "/" .. string.format("chapter-%04d.epub", chapter)
                end
                plugin.settings:put_book(id, { book_id = id, title = "Synthetic scan " .. index,
                    cache_dir = old, cached_file = old .. "/missing.epub", cached_chapters = cached })
            end
            plugin.settings:flush()
            collectgarbage("collect")
        end)
    end)
    H.step("import through the actual cache command", function()
        local done, finished_ms
        local started_ms, last, max_gap = H.now_ms(), H.now_ms(), 0
        local running = true
        local function beat()
            if not running then return end
            local now = H.now_ms()
            max_gap, last = math.max(max_gap, now - last), now
            UIManager:scheduleIn(0.05, beat)
        end
        local baseline = H.rss_kb()
        local max_load, max_save = 0, 0
        H.call(function()
            local store = require("weread.lib.book_store")
            local load, save = store.load, store.save
            store.load = function(...)
                local started = H.now_ms()
                local value = load(...)
                max_load = math.max(max_load, H.now_ms() - started)
                return value
            end
            store.save = function(...)
                local started = H.now_ms()
                local first, second = save(...)
                max_save = math.max(max_save, H.now_ms() - started)
                return first, second
            end
            local refresh = plugin.refreshCacheManagement
            plugin.refreshCacheManagement = function(self, message)
                local result = refresh(self, message)
                done, finished_ms = message, H.now_ms()
                plugin.refreshCacheManagement = refresh
                store.load, store.save = load, save
                marker("scan-complete")
                return result
            end
            marker("scan-start")
            beat()
            plugin:confirmScanLocalCache()
        end)
        H.wait_until("scan reports its result", function() return done end, 240)
        H.call(beat)
        running = false
        H.metric("scan_ms", finished_ms - started_ms)
        H.metric("heartbeat_gap_ms", max_gap)
        H.metric("parent_baseline_rss_kb", baseline)
        H.metric("max_book_load_ms", max_load)
        H.metric("max_book_save_ms", max_save)
        local expected = H.tr("Scan complete. %1 added, %2 updated."):gsub("%%1", "0"):gsub("%%2", tostring(count))
        H.equal(done, expected, "all moved books were reported as updated")
        H.call(function()
            local entries, bytes, cached_paths = 0, 0, 0
            for _, entry in pairs(rawget(plugin.settings, "_book_file_cache") or {}) do
                entries, bytes = entries + 1, bytes + #(entry.content or "")
                for _ in pairs(entry.value and entry.value.cached_chapters or {}) do
                    cached_paths = cached_paths + 1
                end
            end
            H.metric("file_cache_entries", entries)
            H.metric("file_cache_json_bytes", bytes)
            H.metric("file_cache_decoded_chapter_paths", cached_paths)
            collectgarbage("collect")
            H.metric("post_scan_lua_kb", math.floor(collectgarbage("count")))
            H.metric("post_scan_rss_kb", H.rss_kb())
        end)
        H.call(function()
            for index = 0, count - 1 do
                local id = tostring(950000 + index)
                local record = plugin.settings:get_book(id)
                H.equal(record.cache_dir, root .. "/" .. id, "book directory rebound")
                H.check(record.cached_file:sub(1, #record.cache_dir + 1) == record.cache_dir .. "/",
                    "main EPUB rebound to new directory")
                for chapter = 1, chapters do
                    H.equal(record.cached_chapters[tostring(chapter)],
                        record.cache_dir .. "/" .. string.format("chapter-%04d.epub", chapter),
                        "cached chapter rebound")
                end
            end
        end)
        H.metric("books_verified", count)
        H.metric("chapters_verified", count * chapters)
        H.check(max_gap < 800, "cache import keeps the UI responsive", tostring(max_gap))
    end)
end
