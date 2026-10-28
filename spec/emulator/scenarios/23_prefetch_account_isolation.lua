-- @title Prefetch result isolation across queued QR login completion
-- @timeout 60
return function(H)
    local plugin, book, chapters, state = nil, nil, nil, {}
    local function with_response_gate(action, endpoint)
        H.mock_control({ match = endpoint or "/web/book/chapter/e_0", delay = 0, times = 0, hold_response = true })
        local ok, err = xpcall(action, debug.traceback)
        H.mock_control({ hold_response = false })
        if not ok then error(err, 0) end
    end
    H.step("setup a real chapter worker", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        book, chapters = H.call(function()
            local Content = require("weread.lib.content")
            local value = plugin.client:get_book_info("900001")
            Content.ensure_reader_state(plugin.client, value)
            return value, Content.fetch_catalog(plugin.client, value)
        end)
    end)
    H.step("queued QR completion must discard old-account prefetch metadata", function()
        local requests_before = H.mock_state().started_counts["/web/book/chapter/e_0"] or 0
        with_response_gate(function()
            H.call(function()
                plugin.settings:delete_book("900001")
                plugin.settings:set("account", { user_vid = "900099" })
                plugin.downloader:start(book, {chapters[2]}, "chapter", {
                    prefetch = true, single_chapter = true, include_annotations = false,
                    silent_completion = true, offer_read = false,
                    on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
                })
            end)
            H.wait_until("chapter request reached synthetic service", function()
                return (H.mock_state().started_counts["/web/book/chapter/e_0"] or 0) > requests_before
            end, 5)
            H.call(function()
                plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                    accessToken = "mock-access-token", refreshToken = "mock-refresh-token" },
                    plugin.qr_login.generation)
            end)
            H.wait_until("queued QR credentials committed before releasing the old response", function()
                return plugin.settings:get("account", {}).user_vid == "900000"
            end, 10)
            H.check(not state.done, "old worker response remains pending until account change commits")
        end)
        H.wait_until("new login and completed prefetch", function()
            return state.done and plugin.settings:get("account", {}).user_vid == "900000"
        end, 20)
        H.equal(plugin.settings:get_book("900001"), nil, "old prefetch must not write BookRecords after account switch")
        H.check(not state.ok and state.value == "account_changed", "old account result must be discarded")
        H.equal(plugin.library_db:getBook("900001"), nil, "old prefetch does not write new-account SQLite")
        H.equal(plugin.downloader._standby_ref or 0, 0, "discard releases standby")
        H.equal(plugin.downloader._active_job, nil, "discard releases active job")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)
    H.step("same-account ticket rotation still accepts a real chapter worker", function()
        state = {}
        H.close_dialogs()
        local requests_before = H.mock_state().started_counts["/web/book/chapter/e_0"] or 0
        with_response_gate(function()
            H.call(function()
                plugin.downloader:start(book, {chapters[3]}, "chapter", {
                    prefetch = true, single_chapter = true, include_annotations = false,
                    silent_completion = true, offer_read = false,
                    on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
                })
            end)
            H.wait_until("same-account chapter request reached synthetic service", function()
                return (H.mock_state().started_counts["/web/book/chapter/e_0"] or 0) > requests_before
            end, 5)
            H.call(function()
                plugin.settings:update_auth({ wr_ticket = "same-account-rotated-ticket" })
            end)
            H.check(not state.done, "worker response remains pending until ticket rotation commits")
        end)
        H.wait_until("same-account prefetch saved", function() return state.done end, 20)
        H.check(state.ok, "same-account rotation must accept the downloaded chapter", tostring(state.value))
        local record = plugin.settings:get_book("900001")
        H.equal(record.cached_chapters["3"], state.value, "real chapter path persisted")
        local file = io.open(state.value, "rb")
        H.check(file, "accepted EPUB exists on disk")
        file:close()
        H.equal(plugin.settings:get("wr_ticket"), "same-account-rotated-ticket", "parent ticket remains rotated")
        H.equal(plugin.downloader._active_job, nil, "accepted job releases active slot")
        H.equal(plugin.downloader._standby_ref or 0, 0, "accepted job releases standby")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)
    H.step("queued prefetch rejects new credentials before any chapter request", function()
        H.close_dialogs()
        state = {}
        local worker = plugin.downloader.background_worker
        local blocker_done
        local chapter_before = H.mock_state().started_counts["/web/book/chapter/e_0"] or 0
        local blocker_before = H.mock_state().started_counts["/book/getprogress"] or 0
        with_response_gate(function()
            H.call(function()
                plugin.settings:delete_book("900001")
                plugin.settings:set("account", { user_vid = "900099" })
                -- Hold the actual shared worker under the same kind used by
                -- annotation sync; this task only performs a synthetic lookup.
                local started = worker:start{
                    kind = "annotation",
                    task = function() return plugin.client:get_progress("900001") end,
                    on_done = function() blocker_done = true end,
                }
                H.check(started, "shared annotation worker started")
                plugin.downloader:start({ book_id = "900001", title = book.title }, {chapters[4]}, "chapter", {
                    prefetch = true, single_chapter = true, include_annotations = false,
                    silent_completion = true, offer_read = false,
                    on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
                })
            end)
            H.wait_until("prefetch queued behind the held shared worker", function()
                return worker.pending and (H.mock_state().started_counts["/book/getprogress"] or 0) > blocker_before
            end, 5)
            H.call(function()
                plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                    accessToken = "mock-access-token", refreshToken = "mock-refresh-token" },
                    plugin.qr_login.generation)
            end)
            H.wait_until("new account commits before queued task can launch", function()
                return plugin.settings:get("account", {}).user_vid == "900000"
            end, 10)
            H.check(not state.done and worker.pending, "old-account request is still queued")
        end, "/book/getprogress")
        H.wait_until("shared worker and rejected queued task finish", function()
            return blocker_done and state.done and not worker.job and not worker.pending
        end, 10)
        H.equal(H.mock_state().started_counts["/web/book/chapter/e_0"] or 0, chapter_before,
            "queued old-account task must not request a chapter with new credentials")
        H.check(not state.ok and state.value == "account_changed", "queued account change is reported")
        H.equal(plugin.settings:get_book("900001"), nil, "queued task does not write BookRecords")
        H.equal(plugin.downloader._active_job, nil, "queued rejection releases downloader")
        H.equal(plugin.downloader._standby_ref or 0, 0, "queued rejection releases standby")
        H.mock_control({ match = "", delay = 0, times = 0 })
    end)

end
