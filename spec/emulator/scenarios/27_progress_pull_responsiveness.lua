-- @title Progress HTTP: responsive reader, cancellation, fresh positions and ownership
-- @timeout 90
-- @no_coverage Real UI heartbeat timing without instrumentation overhead.
return function(H)
    local UIManager = require("ui/uimanager")
    local TrapWidget = require("ui/widget/trapwidget")
    local ffiutil = require("ffi/util")
    local plugin, sync
    local function reset()
        H.call(function() sync:_close_choice("probe_reset"); plugin.read_report:stop("progress_probe") end)
        H.close_dialogs()
    end
    local function gate(action, endpoint)
        H.mock_control({ match = endpoint or "/book/getprogress", delay = 0, times = 0, hold_response = true })
        local ok, err = xpcall(action, debug.traceback)
        H.mock_control({ hold_response = false })
        if not ok then error(err, 0) end
    end
    local function with_child(action)
        local spawn, pid
        H.call(function()
            spawn = ffiutil.runInSubProcess
            ffiutil.runInSubProcess = function(...)
                local value, fd = spawn(...)
                if not pid then pid = value end
                return value, fd
            end
        end)
        local ok, err = xpcall(function() action(function() return pid end) end, debug.traceback)
        H.call(function() ffiutil.runInSubProcess = spawn end)
        if not ok then error(err, 0) end
        return pid
    end
    local function request_started(before)
        H.wait_until("actual progress HTTP reached service", function()
            return (H.mock_state().started_counts["/book/getprogress"] or 0) > before
        end, 5)
    end
    local function marker(value)
        H.call(function()
            local book = plugin.settings:get_book("900001")
            book.last_pull_at, book.last_sync_error = value, "probe-sentinel"
            plugin.settings:put_book("900001", book); plugin.settings:flush()
        end)
    end
    H.step("open a real full book without automatic networking", function()
        H.wait_until("plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            local p = H.plugin()
            local config = p.settings:get("sync")
            config.pull_on_open, config.upload_on_close, config.ask_on_conflict = false, false, true
            config.upload_interval_minutes = 0
            p.settings:set("sync", config)
            local report = p.settings:get("read_report"); report.enabled = false
            p.settings:set("read_report", report); p.settings:flush()
            local book = p.client:get_book_info("900001")
            p.settings:put_book("900001", book)
            p:confirmDownloadAllChapters(book)
        end)
        H.tap_exact(H.tr("Download")); H.tap_exact(H.tr("Read now"), 60)
        H.wait_until("reader and progress context ready", function()
            plugin = H.plugin(); sync = plugin and plugin.progress_sync
            return H.reader() and sync and sync.current_book_id == "900001" and not sync.pulling
        end, 30)
        reset()
    end)
    H.step("slow manual pull preserves heartbeat and parent result", function()
        local running, last, gap = true, H.now_ms(), 0
        local function tick()
            local now = H.now_ms(); gap = math.max(gap, now - last); last = now
            if running then UIManager:scheduleIn(0.1, tick) end
        end
        H.mock_control({ match = "/book/getprogress", delay = 1.5, times = 0 })
        H.call(function() UIManager:scheduleIn(0.1, tick); plugin:onWeReadSyncProgress() end)
        H.wait_until("manual progress pull finishes", function() return not sync.pulling end, 15)
        H.sleep(0.2)
        H.call(function() tick(); running = false end)
        H.metric("progress_pull_heartbeat_gap_ms", gap)
        local record = plugin.settings:get_book("900001")
        H.check(record.last_remote_position and record.last_pull_at, "parent stores normalized progress")
        H.check(gap < 800, "progress HTTP must not stall the UI loop", tostring(gap))
        H.mock_control({ match = "", delay = 0, times = 0 }); reset()
    end)
    H.step("ordinary reading does not cancel automatic HTTP and completion uses fresh position", function()
        H.mock_post("/__progress", { bookId = "900001", chapterUid = 6, chapterIdx = 6,
            chapterOffset = 900, updateTime = os.time() })
        local before = H.mock_state().started_counts["/book/getprogress"] or 0
        local turned, position
        gate(function()
            H.call(function() sync:_pull({ manual = false }) end)
            request_started(before)
            H.check(getmetatable(H.input_window()) ~= TrapWidget, "automatic pull has no input trap")
            local page = H.call(function() return H.reader():getCurrentPage() end)
            H.tap_at(550, 400)
            H.wait_until("real reading tap changes page", function() return H.reader():getCurrentPage() > page end, 5)
            turned = H.reader():getCurrentPage()
            position = H.call(function() return sync:capture_local() end)
            H.check(sync.pulling and sync.pull_request, "ordinary reading keeps the RPC alive")
        end)
        H.wait_until("automatic pull completes", function() return not sync.pulling end, 10)
        local stored = plugin.settings:get_book("900001").last_local_position
        H.check(require("weread.lib.position_mapper").same_position(stored, position),
            "HTTP completion persists the new reading position")
        H.equal(H.reader():getCurrentPage(), turned, "automatic conflict does not overwrite reading")
        H.check(sync.choice, "fresh conflict asks before moving progress")
        H.call(function() H.reader().rolling:onGotoViewRel(1) end)
        local latest = H.reader():getCurrentPage()
        H.tap_exact(H.tr("Use WeRead progress"))
        H.equal(H.reader():getCurrentPage(), latest, "stale prompt does not jump after a programmatic turn")
        H.equal(sync.choice, nil, "stale prompt releases choice state")
        reset()
    end)
    H.step("real manual Cancel kills the child and preserves parent state", function()
        marker(123)
        local before = H.mock_state().started_counts["/book/getprogress"] or 0
        local cancel_ms
        local pid = with_child(function()
            gate(function()
                H.call(function() plugin:onWeReadSyncProgress() end)
                request_started(before)
                H.wait_until("manual cancel UI painted", function() return getmetatable(H.input_window()) == TrapWidget end, 5)
                local started = H.now_ms(); H.tap_at(580, 20)
                H.wait_until("manual request cancelled", function() return not sync.pulling end, 5)
                cancel_ms = H.now_ms() - started
            end)
        end)
        H.wait_until("cancelled child actually exits", function() return pid and ffiutil.isSubProcessDone(pid) end, 8)
        H.metric("progress_pull_cancel_ms", cancel_ms)
        H.check(cancel_ms < 800, "manual cancellation does not wait for HTTP", tostring(cancel_ms))
        H.equal(plugin.settings:get_book("900001").last_pull_at, 123, "cancel has no late parent write")
        H.equal(plugin.settings:get_book("900001").last_sync_error, "probe-sentinel", "cancel has no false error")
        reset()
    end)
    H.step("missing catalog refresh performs HTTP in a worker and publishes parent data", function()
        H.call(function()
            local book = plugin.settings:get_book("900001")
            os.remove(require("weread.lib.content").catalog_cache_path(plugin.settings, book))
            plugin.library_db:putChapters("900001", {})
            local Memo = require("weread.lib.catalog_memo"); Memo.decoded, Memo.written = nil, {}
            sync.document_context = nil
            local position, reason = sync:capture_local()
            H.check(not position and reason == "catalog_unavailable", "catalog initially missing", tostring(reason))
        end)
        H.mock_control({ match = "/web/book/chapterInfos", delay = 1.5, times = 0 })
        H.call(function() plugin:onWeReadSyncProgress() end)
        H.wait_until("catalog and progress finish", function() return not sync.pulling end, 15)
        H.equal(#plugin.library_db:getChapters("900001"), 6, "parent SQLite catalog restored")
        H.equal(#require("weread.lib.content").load_catalog_cache(plugin.client, plugin.settings,
            plugin.settings:get_book("900001")), 6, "published catalog file restored")
        H.check(plugin.settings:get_book("900001").last_remote_position, "progress follows catalog refresh")
        H.mock_control({ match = "", delay = 0, times = 0 }); reset()
    end)
    H.step("gateway-only owner changes during defer issue no HTTP", function()
        local original = H.call(function()
            return { cookies = plugin.settings:get("cookies"), account = plugin.settings:get("account"),
                api_key = plugin.settings:get("api_key"), wr_ticket = plugin.settings:get("wr_ticket"),
                wr_wrpa = plugin.settings:get("wr_wrpa") }
        end)
        marker(345)
        local before = H.mock_state().started_counts["/book/getprogress"] or 0
        local ok, err = xpcall(function()
            H.call(function()
                plugin.settings:update_auth({ cookies = {}, api_key = "mock-owner-api-one" }, { replace_cookies = true })
                sync:sync_now()
                plugin.settings:update_auth({ api_key = "mock-owner-api-two" })
            end)
            H.wait_until("deferred old request rejected", function() return not sync.pulling end, 5)
            H.equal(H.mock_state().started_counts["/book/getprogress"] or 0, before, "old gateway request never starts")
            H.equal(plugin.settings:get_book("900001").last_pull_at, 345, "defer rejection does not persist")
        end, debug.traceback)
        H.call(function() plugin.settings:update_auth(original, { replace_cookies = true }); plugin:onWeReadAccountChanged() end)
        if not ok then error(err, 0) end
        reset()
    end)
    H.step("queued QR completion cancels old progress without new-owner writes", function()
        H.call(function()
            plugin.settings:update_auth({ account = { user_vid = "900099" }, api_key = "mock-old-api",
                cookies = { wr_vid = "900099", wr_skey = "mock-old-cookie" } }, { replace_cookies = true })
            plugin:onWeReadAccountChanged()
        end)
        marker(456)
        local before = H.mock_state().started_counts["/book/getprogress"] or 0
        local writes, put = 0
        local ok, err = xpcall(function()
            gate(function()
                H.call(function()
                    plugin:onWeReadSyncProgress()
                    put = plugin.settings.put_book
                    plugin.settings.put_book = function(settings, ...)
                        if settings:get("account", {}).user_vid == "900000" then writes = writes + 1 end
                        return put(settings, ...)
                    end
                end)
                request_started(before)
                H.call(function()
                    plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                        accessToken = "mock-access-token", refreshToken = "mock-refresh-token" }, plugin.qr_login.generation)
                end)
                H.wait_until("QR commits and old progress cancels", function()
                    return plugin.settings:get("account", {}).user_vid == "900000" and not sync.pulling
                end, 10)
            end)
        end, debug.traceback)
        H.call(function() if put then plugin.settings.put_book = put end end)
        if not ok then error(err, 0) end
        H.equal(writes, 0, "old progress never writes new-owner BookRecords")
        H.equal(plugin.settings:get_book("900001").last_pull_at, 456, "QR cancellation preserves old marker")
        H.check(not sync.pull_request and not sync.uploading and not plugin.read_report.job,
            "account invalidation clears both state machines")
        reset()
    end)
    H.step("closing the reader cancels automatic HTTP without a late popup", function()
        H.call(function() sync:on_reader_ready() end)
        H.wait_until("new account reader context ready", function() return sync.current_book_id == "900001" end, 5)
        marker(567)
        local before = H.mock_state().started_counts["/book/getprogress"] or 0
        local pid = with_child(function()
            gate(function()
                H.call(function() sync:_pull({ manual = false }) end)
                request_started(before)
                H.call(function() H.reader():onHome() end)
                H.wait_until("reader closed", function() return H.reader() == nil and H.file_manager() end, 10)
                H.check(not sync.pulling and not sync.pull_request, "close releases old pull state")
            end)
        end)
        H.wait_until("closed reader child exits", function() return pid and ffiutil.isSubProcessDone(pid) end, 8)
        H.equal(H.runtime().settings:get_book("900001").last_pull_at, 567, "close has no late progress write")
        H.check(not H.has_text(H.tr("Use WeRead progress")), "close has no late choice popup")
    end)
end
