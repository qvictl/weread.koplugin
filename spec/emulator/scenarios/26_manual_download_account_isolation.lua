-- @title Manual chapter downloads reject responses from an earlier account
-- @timeout 90
return function(H)
    local without_ui_dns = dofile(os.getenv("WEREAD_TEST_HARNESS_DIR") .. "/no_ui_dns.lua")
    local plugin, book, chapters
    H.step("setup manual chapter download", function()
        plugin = H.wait_until("plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            local Content = require("weread.lib.content")
            book = plugin.client:get_book_info("900001")
            Content.ensure_reader_state(plugin.client, book)
            chapters = Content.fetch_catalog(plugin.client, book)
            plugin.settings:delete_book("900001")
            plugin.settings:set("account", { user_vid = "900099" })
        end)
    end)
    for _, mode in ipairs({ "single", "full", "ticket" }) do
        H.step(mode .. " manual response retains its accepting account", function()
            local result, job
            H.call(function()
                plugin.settings:delete_book("900001")
                plugin.settings:set("account", { user_vid = "900099" })
            end)
            local before = H.mock_state().started_counts["/web/book/chapter/e_0"] or 0
            H.mock_control({ match = "/web/book/chapter/e_0", times = 0, hold_response = true })
            local ok, err = xpcall(function()
                without_ui_dns(H, function()
                    plugin.downloader:start(book, {chapters[6]}, mode == "full" and "full" or "chapter", {
                        single_chapter = mode ~= "full", include_annotations = false,
                        silent_completion = true, offer_read = false,
                        on_complete = function(done, value) result = { ok = done, value = value } end,
                    })
                    job = plugin.downloader._active_job
                end)
                H.wait_until("real manual chapter request reaches service", function()
                    return (H.mock_state().started_counts["/web/book/chapter/e_0"] or 0) > before
                end, 10)
                if mode == "ticket" then
                    H.call(function() plugin.settings:update_auth({ wr_ticket = "manual-rotated-ticket" }) end)
                else
                    H.call(function()
                        plugin.qr_login:_complete({ succeed = true, webLoginVid = "900000",
                            accessToken = "mock-access-token", refreshToken = "mock-refresh-token" },
                            plugin.qr_login.generation)
                    end)
                    H.wait_until("QR login commits before manual worker returns", function()
                        return plugin.settings:get("account", {}).user_vid == "900000"
                    end, 10)
                end
                H.check(not result, "manual worker remains held until parent mutation")
            end, debug.traceback)
            H.mock_control({ hold_response = false })
            if not ok then error(err, 0) end
            H.wait_until("manual job finishes", function() return result end, 20)
            if mode == "ticket" then
                H.check(result.ok, "same-account ticket rotation accepts manual download")
                local file = assert(io.open(result.value, "rb")); file:close()
                H.equal(plugin.settings:get_book("900001").cached_chapters["6"], result.value,
                    "accepted manual path persists")
                H.equal(plugin.settings:get("wr_ticket"), "manual-rotated-ticket", "new parent ticket survives")
            else
                H.equal(plugin.settings:get_book("900001"), nil, "old manual result must not write new-account BookRecords")
                H.equal(plugin.library_db:getBook("900001"), nil, "old manual result must not write new-account SQLite")
                H.check(not result.ok and result.value == "account_changed", "manual account change is reported")
                if mode == "full" then
                    H.check(job.workspace and require("libs/libkoreader-lfs").attributes(job.workspace.path, "mode") == "directory",
                        "account rejection retains the resumable checkpoint")
                    H.equal(job.completed_count, 0, "discarded response is not checkpointed")
                end
            end
            H.equal(plugin.downloader._active_job, nil, "manual rejection releases active job")
            H.equal(plugin.downloader._standby_ref or 0, 0, "manual rejection releases standby")
            H.mock_control({ match = "", times = 0 })
        end)
    end
end
