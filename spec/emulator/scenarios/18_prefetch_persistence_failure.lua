-- @title A failed prefetch result save releases the downloader for manual downloads
-- @timeout 90
local BOOK_ID = "900001"

return function(H)
    local book, chapters
    H.step("setup", function()
        H.wait_until("plugin attached", function() return H.plugin() end, 20)
        book, chapters = H.call(function()
            local content = require("weread.lib.content")
            local client = H.runtime().client
            local info = client:get_book_info(BOOK_ID)
            content.ensure_reader_state(client, info)
            return info, content.fetch_catalog(client, info)
        end)
    end)

    H.step("parent result save fails after a real chapter worker succeeds", function()
        local state, job = {}, nil
        H.check(H.call(function()
            local runtime = H.runtime()
            local settings = runtime.settings
            local original = settings.put_book
            settings.put_book = function() error("injected parent book save failure") end
            local started = runtime.downloader:start(book, { chapters[2] }, "chapter", {
                prefetch = true, single_chapter = true, include_annotations = false,
                silent_completion = true, offer_read = false,
                on_complete = function(ok, value)
                    settings.put_book = original
                    state.done, state.ok, state.value = true, ok, value
                end,
            })
            job = runtime.downloader._active_job
            if not started then settings.put_book = original end
            return started
        end), "prefetch starts")
        H.wait_until("prefetch completion despite save failure", function() return state.done end, 30)
        H.check(not state.ok and tostring(state.value):find("injected parent book save failure", 1, true),
            "failed result save is reported", tostring(state.value))
        H.equal(H.runtime().downloader._active_job, nil, "active job released")
        H.equal(job.standby_guard, nil, "standby inhibition released")
        H.equal(job.worker_handle, nil, "finished worker handle released")
    end)

    H.step("a subsequent manual chapter download completes", function()
        local state = {}
        H.check(H.call(function()
            return H.runtime().downloader:start(book, { chapters[3] }, "chapter", {
                single_chapter = true, include_annotations = false,
                silent_completion = true, offer_read = false,
                on_complete = function(ok, value) state.done, state.ok, state.value = true, ok, value end,
            })
        end), "manual download accepted after failed prefetch")
        H.wait_until("manual download completes", function() return state.done end, 30)
        H.check(state.ok, "manual download succeeds", tostring(state.value))
        local file = io.open(state.value, "rb")
        H.check(file, "manual EPUB exists")
        file:close()
        H.equal(H.runtime().downloader._active_job, nil, "downloader idle")
        H.close_dialogs()
    end)
end
