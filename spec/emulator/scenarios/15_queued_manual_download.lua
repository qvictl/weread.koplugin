-- @title A manual download queued behind a prefetch is not lost
-- @timeout 120
-- A chapter prefetch is running when the reader starts a manual download:
-- the prefetch is cancelled and the manual download waits for its worker to
-- stop. A new prefetch request arriving in that window (the next page turn)
-- must be refused instead of replacing the queued manual download, which
-- then runs and completes.
local BOOK_ID = "900001"

return function(H)
    local Content = require("weread.lib.content")

    local function downloader() return H.runtime().downloader end

    local function prefetch_options(state)
        return {
            single_chapter = true, include_annotations = false, prefetch = true,
            silent_completion = true, offer_read = false,
            on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
        }
    end

    local book, chapters
    H.step("setup", function()
        H.wait_until("weread plugin attached", function() return H.plugin() end, 20)
        book, chapters = H.call(function()
            local client = H.runtime().client
            local info = client:get_book_info(BOOK_ID)
            Content.ensure_reader_state(client, info)
            return info, Content.fetch_catalog(client, info)
        end)
        H.check(#chapters >= 4, "catalog chapters", tostring(#chapters))
    end)

    H.step("prefetch, then manual download, then another prefetch", function()
        -- Slow chapter requests keep the first prefetch worker busy.
        H.mock_control({ match = "/web/book/chapter/", delay = 1.5, times = 0 })
        local first = {}
        H.check(H.call(function()
            return downloader():start(book, { chapters[2] }, "chapter", prefetch_options(first))
        end), "prefetch started")
        H.wait_until("prefetch job active", function()
            local job = downloader()._active_job
            return job and job.prefetch and job or nil
        end, 15)

        local manual, late = {}, {}
        local started, queued_manual, late_started, still_queued = H.call(function()
            local d = downloader()
            local ok = d:start(book, { chapters[3] }, "chapter", {
                single_chapter = true, include_annotations = false,
                silent_completion = true, offer_read = false,
                on_complete = function(ok2, value) manual.done, manual.ok, manual.value = true, ok2, value end,
            })
            local pending = d._pending_start
            local queued = pending and not (pending.options and pending.options.prefetch) or false
            -- Same UI tick as a page turn right after the tap.
            local late_ok = d:start(book, { chapters[4] }, "chapter", prefetch_options(late))
            pending = d._pending_start
            return ok, queued, late_ok, pending and not (pending.options and pending.options.prefetch) or false
        end)
        H.check(started, "manual download accepted")
        H.check(queued_manual, "manual download queued behind the stopping prefetch")
        H.check(not late_started, "later prefetch refused while the manual download waits")
        H.check(still_queued, "manual download still queued")

        H.mock_control({ match = "", delay = 0, times = 0 })
        H.wait_until("manual download completed", function() return manual.done end, 60)
        H.check(manual.ok, "manual download succeeded", tostring(manual.value))
        H.wait_until("downloader idle", function() return not downloader()._active_job end, 30)
        H.close_dialogs()
    end)
end
