-- @title Prefetch result isolation across queued QR login completion
-- @timeout 60
return function(H)
    local UIManager = require("ui/uimanager")
    local plugin, book, chapters, state = nil, nil, nil, {}
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
        H.mock_control({ match = "/web/book/chapter/e_0", delay = 1.5, times = 0 })
        H.call(function()
            plugin.settings:delete_book("900001")
            plugin.settings:set("account", { user_vid = "900099" })
            plugin.downloader:start(book, {chapters[2]}, "chapter", {
                prefetch = true, single_chapter = true, include_annotations = false,
                silent_completion = true, offer_read = false,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
            UIManager:scheduleIn(0.35, function()
                plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                    accessToken = "mock-access-token", refreshToken = "mock-refresh-token" },
                    plugin.qr_login.generation)
            end)
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
        H.mock_control({ match = "/web/book/chapter/e_0", delay = 1.5, times = 0 })
        H.call(function()
            plugin.downloader:start(book, {chapters[3]}, "chapter", {
                prefetch = true, single_chapter = true, include_annotations = false,
                silent_completion = true, offer_read = false,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
            UIManager:scheduleIn(0.35, function()
                plugin.settings:update_auth({ wr_ticket = "same-account-rotated-ticket" })
            end)
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
end
