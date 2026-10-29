-- @title Chapter workers send only current changes and retain accepted history
-- @timeout 120
-- @no_coverage Actual worker result-file sizes, heap samples and UI heartbeat.
-- Two real chapters, with explicitly seeded synthetic historical maps. This
-- is not an 811-chapter download or a measurement on Kindle hardware.
return function(H)
    local UIManager = require("ui/uimanager")
    local Worker = require("weread.lib.background_worker")
    local Content = require("weread.lib.content")
    local buffer = require("string.buffer")
    local plugin, book, chapters, png
    local phase, original_stage, original_run, worker_decode
    local returned_bytes, largest_response, peak_growth = 0, 0, 0
    local running, last, gap = true, H.now_ms(), 0
    local baseline_heap = collectgarbage("count")
    local function beat()
        local now = H.now_ms()
        gap, last = math.max(gap, now - last), now
        peak_growth = math.max(peak_growth, collectgarbage("count") - baseline_heap)
        if running then UIManager:scheduleIn(0.05, beat) end
    end
    local function write(path, bytes)
        local file = assert(io.open(path, "wb"))
        assert(file:write(bytes)); assert(file:close())
    end
    local function seed(job)
        local names = { ["existing.png"] = true, ["already-cached.png"] = true,
            __remote_image_hrefs = { ["https://weread.qq.com/mock/illustration.png"] = "images/already-cached.png" },
            __next_asset_suffix = { __count = 1024 } }
        for index = 1, 1024 do names.__next_asset_suffix["cursor-" .. index .. ".png"] = 3 end
        for index = 1, phase.history do
            local name = string.format("historic-%05d.png", index)
            names[name] = true
            names.__remote_image_hrefs["https://weread.qq.com/mock/history/" .. index .. "?padding=" .. ("x"):rep(120)]
                = "images/" .. name
        end
        job.state.used_asset_names = names
        job.seeded_names, job.seeded_suffixes = names, names.__next_asset_suffix
        write(job.workspace.asset_dir .. "/existing.png", png)
        write(job.workspace.asset_dir .. "/already-cached.png", png)
        phase.full_state_bytes = #buffer.encode(job.state)
        phase.seeded = true
        baseline_heap = collectgarbage("count")
    end
    local function start(history, archive, count)
        phase = { history = history, archive = archive, responses = {}, failures_checked = 0 }
        H.call(function()
            local selected = {}
            for index = 1, count do
                local chapter = {}
                for key, value in pairs(chapters[index]) do chapter[key] = value end
                chapter.tar = "https://weread.qq.com/mock/resource-archive/" .. archive .. ".tar"
                selected[index] = chapter
            end
            H.check(plugin.downloader:start(book, selected, "full", {
                silent_completion = true, offer_read = false, include_annotations = false,
                on_complete = function(ok, value) phase.result = { ok = ok, value = value } end,
            }), "real Downloader accepts the job")
            phase.job = plugin.downloader._active_job
        end)
    end
    local function archive_entries(path)
        return H.call(function()
            local archive = require("ffi/archiver").Reader:new()
            assert(archive:open(path))
            local names, values = {}, {}
            for entry in archive:iterate() do
                if entry.mode == "file" then names[#names + 1] = entry.path end
            end
            for _, name in ipairs(names) do
                local bytes = assert(archive:extractToMemory(name))
                if name == "OEBPS/content.opf" then
                    -- Packaging wall-clock time differs between the runs;
                    -- every other metadata, text and image byte must match.
                    local replacements
                    bytes, replacements = bytes:gsub('(<meta property="dcterms:modified">)[^<]+(</meta>)', "%1BUILD-TIME%2")
                    H.equal(replacements, 1, "only the publication timestamp is normalized")
                end
                values[name] = bytes
            end
            archive:close()
            return values
        end)
    end
    local function check_cancelled_state()
        local job = phase.job
        H.equal(job.completed_count, 0, "rejected chapter creates no checkpoint")
        H.check(job.state.used_asset_names == job.seeded_names, "accepted name table survives")
        H.check(job.state.used_asset_names.__next_asset_suffix == job.seeded_suffixes,
            "rejected chapter cannot advance or evict accepted suffix cursors")
        H.equal(job.seeded_suffixes.__count, 1024, "old cursor count survives rejection")
        H.equal(job.state.used_asset_names["existing-2.png"], nil, "rejected new name is absent")
        H.equal(job.state.css, nil, "rejected chapter stylesheet is absent")
    end
    local ok, err = xpcall(function()
        H.step("install observers and prepare real HTTP fixtures", function()
            plugin = H.wait_until("plugin attached", H.plugin, 20)
            H.call(function()
                book = plugin.client:get_book_info("900001")
                Content.ensure_reader_state(plugin.client, book)
                chapters = Content.fetch_catalog(plugin.client, book)
                png = plugin.client:get_binary("https://weread.qq.com/mock/illustration.png")
                local cache = plugin.settings:get("cache", {})
                cache.download_book_images = true
                plugin.settings:set("cache", cache)
                original_stage, original_run = plugin.downloader._setStage, plugin.downloader._runInterruptible
                plugin.downloader._setStage = function(self, job, ...)
                    if phase and not phase.seeded and job.workspace then seed(job) end
                    return original_stage(self, job, ...)
                end
                plugin.downloader._runInterruptible = function(self, job, task)
                    local before_bytes, before_heap = returned_bytes, collectgarbage("count")
                    local completed, value = pcall(original_run, self, job, task)
                    if not completed then
                        if phase and phase.archive == "initial" then
                            check_cancelled_state()
                            local lfs = require("libs/libkoreader-lfs")
                            H.equal(lfs.attributes(job.workspace.asset_dir .. "/existing-2.png"), nil,
                                "failed extraction removes its completed new image")
                            H.equal(lfs.attributes(job.workspace.asset_dir .. "/existing-3.png"), nil,
                                "failed extraction removes its partial new image")
                            H.check(lfs.attributes(job.workspace.asset_dir .. "/existing.png"),
                                "rollback preserves the previously accepted image")
                            phase.failures_checked = phase.failures_checked + 1
                        end
                        error(value, 0)
                    end
                    if phase and type(value) == "table" and value.xhtml then
                        local bytes = returned_bytes - before_bytes
                        largest_response = math.max(largest_response, bytes)
                        phase.responses[#phase.responses + 1] = { bytes = bytes,
                            heap_growth_kb = collectgarbage("count") - before_heap,
                            full_state = value.state ~= nil, delta = value.state_delta }
                    end
                    return value
                end
                worker_decode = Worker._decode
                Worker._decode = function(self, path, ...)
                    local value, raw = worker_decode(self, path, ...)
                    if type(raw) == "string" and path:find(".result.", 1, true) then
                        returned_bytes = returned_bytes + #raw
                    end
                    return value, raw
                end
                beat()
            end)
        end)
        local control
        H.step("control download has real images, old URL reuse and cursor eviction", function()
            start(0, "retry", 2)
            H.wait_until("control EPUB complete", function() return phase.result end, 25)
            H.check(phase.result.ok, "control download succeeds", tostring(phase.result.value))
            H.equal(#phase.responses, 2, "one combined source/images response per chapter")
            H.equal(phase.job.state.used_asset_names.__next_asset_suffix.__count, 1,
                "full cursor cache was replaced, not merged")
            H.equal(phase.job.state.used_asset_names.__next_asset_suffix["existing.png"], 6,
                "same-name suffix cursor continues across chapters")
            control = archive_entries(phase.result.value)
            H.equal(control["OEBPS/images/cover.png"], png, "raw binary cover survives the real worker result codec")
            H.equal(control["OEBPS/images/already-cached.png"], png, "existing URL keeps its existing image")
            H.check(control["OEBPS/images/existing-2.png"] and control["OEBPS/images/existing-5.png"],
                "all newly extracted images enter the EPUB")
            H.close_dialogs()
        end)
        H.step("8192 seeded names and URLs do not cross the actual worker result channel", function()
            local before_images = H.mock_state().started_counts["/mock/illustration.png"] or 0
            start(8192, "retry", 2)
            H.wait_until("seeded EPUB complete", function() return phase.result end, 25)
            H.check(phase.result.ok, "seeded download succeeds", tostring(phase.result.value))
            H.check(phase.full_state_bytes > 1024 * 1024, "synthetic historical state exceeds 1 MiB")
            H.metric("seeded_full_state_bytes", phase.full_state_bytes)
            H.equal(#phase.responses, 2, "two real chapter workers returned")
            for index, response in ipairs(phase.responses) do
                H.metric("state_delta_result_" .. index .. "_bytes", response.bytes)
                H.metric("state_delta_result_" .. index .. "_receive_heap_change_kb", response.heap_growth_kb)
                H.check(not response.full_state and type(response.delta) == "table", "worker sends delta only " .. index)
                H.check(response.bytes > 0 and response.bytes < 64 * 1024,
                    "actual worker result is nonempty and bounded by this chapter " .. index,
                    tostring(response.bytes))
                H.equal(response.delta.names.set["historic-08192.png"], nil, "historical names stay off wire")
            end
            H.equal(H.mock_state().started_counts["/mock/illustration.png"] or 0, before_images,
                "accepted old URL is reused without HTTP")
            H.check(phase.job.state.used_asset_names["historic-00001.png"]
                and phase.job.state.used_asset_names["historic-08192.png"], "earlier names remain accepted")
            local actual = archive_entries(phase.result.value)
            for name, bytes in pairs(control) do H.equal(actual[name], bytes, "EPUB entry matches control: " .. name) end
            for name in pairs(actual) do H.check(control[name] ~= nil, "no history-only assets enter EPUB: " .. name) end
            H.close_dialogs()
        end)
        H.step("cancelled real resource HTTP never publishes child state", function()
            H.mock_control({ match = "/mock/resource-archive/retry.tar", hold_response = true, times = 0 })
            local before = H.mock_state().started_counts["/mock/resource-archive/retry.tar"] or 0
            start(8192, "retry", 1)
            H.wait_until("resource request held", function()
                return (H.mock_state().started_counts["/mock/resource-archive/retry.tar"] or 0) > before
            end, 10)
            local started = H.now_ms()
            H.tap_exact(H.tr("Cancel download"))
            H.wait_until("cancel finishes", function() return phase.result end, 3)
            H.metric("state_delta_cancel_ms", H.now_ms() - started)
            H.check(not phase.result.ok, "cancel is not a completed chapter")
            check_cancelled_state()
            H.mock_control({ hold_response = false, match = "", times = 0 })
            H.close_dialogs()
        end)
        H.step("failed real extraction leaves parent state and old files intact", function()
            start(8192, "initial", 1)
            H.wait_until("failed archive retries finish", function() return phase.result end, 25)
            H.check(not phase.result.ok, "truncated resource cannot complete a chapter")
            check_cancelled_state()
            H.check(phase.failures_checked >= 1, "actual extraction failures checked before final job cleanup")
            H.close_dialogs()
        end)
        H.metric("state_delta_largest_worker_result_bytes", largest_response)
        H.metric("state_delta_sampled_lua_growth_kb", math.ceil(peak_growth))
        H.metric("state_delta_heartbeat_gap_ms", gap)
        H.check(gap < 800, "real worker transfer retains UI heartbeat", tostring(gap))
    end, debug.traceback)
    running = false
    H.mock_control({ hold_response = false, match = "", delay = 0, times = 0 })
    H.call(function()
        if plugin then
            if original_stage then plugin.downloader._setStage = original_stage end
            if original_run then plugin.downloader._runInterruptible = original_run end
        end
        if worker_decode then Worker._decode = worker_decode end
    end)
    if not ok then error(err, 0) end
end
