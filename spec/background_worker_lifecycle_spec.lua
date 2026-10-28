-- Job lifecycle edge cases of the forked background worker: launch failures
-- and memory cooldown, the child-side context (progress, sleep, cancel,
-- errors), stalled children, malformed/partial/stale result files, pending
-- replacement/cancel, poll scheduling and the default runner/clock.
-- Run from the repo root with:
--   luajit spec/background_worker_lifecycle_spec.lua

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local temp_dir = os.tmpname()
os.remove(temp_dir)
assert(os.execute("mkdir -p '" .. temp_dir .. "'"))

-- In-memory JSON: encode returns a key, decode fails for anything else
-- (a truncated or corrupt file).
local encoded, sequence = {}, 0
package.preload["json"] = function()
    return {
        encode = function(value)
            if type(value) == "table" and type(value.value) == "table" and value.value.unencodable then
                error("cannot encode function")
            end
            sequence = sequence + 1
            local key = "encoded-" .. tostring(sequence)
            encoded[key] = value
            return key
        end,
        decode = function(raw)
            local value = encoded[raw]
            if value == nil then error("unexpected character at position 1") end
            return value
        end,
    }
end
local FFIUtil = { isAndroid = function() return false end }
package.preload["ffi/util"] = function() return FFIUtil end
local mono = 0
local TimeStub = {
    now = function() return mono * 1000000 end,
    to_number = function(value) return value / 1000000 end,
}
package.preload["ui/time"] = function() return TimeStub end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function() end }
end
local warnings = {}
package.preload["logger"] = function()
    return {
        dbg = function() end, info = function() end, err = function() end,
        warn = function(...) warnings[#warnings + 1] = table.concat({ ... }, " ") end,
    }
end
local mkdir_calls = {}
local mkdir_result = true
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            if field == "mode" then
                local status = os.execute("test -d '" .. path .. "'")
                if status == 0 or status == true then return "directory" end
            end
            local file = io.open(path, "rb")
            if not file then return nil end
            file:close()
            return field and "file" or { mode = "file" }
        end,
        mkdir = function(path)
            mkdir_calls[#mkdir_calls + 1] = path
            if mkdir_result then os.execute("mkdir -p '" .. path .. "'") end
            return mkdir_result
        end,
    }
end

local BackgroundWorker = require("weread.lib.background_worker")

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end
local function write_file(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end
local function exists(path) return read_file(path) ~= nil end

-- Fake runner/scheduler: children run only when the spec calls them.
local scheduled, children, done, terminated = {}, {}, {}, {}
local next_pid, clock = 500, 100
local runner = {
    run = function(callback)
        next_pid = next_pid + 1
        children[next_pid] = callback
        done[next_pid] = false
        return next_pid
    end,
    is_done = function(pid)
        if done[pid] == "throw" then error("waitpid interrupted") end
        return done[pid] == true
    end,
    terminate = function(pid)
        terminated[pid] = (terminated[pid] or 0) + 1
        done[pid] = true
    end,
}
local scheduler = {
    scheduleIn = function(_self, delay, callback)
        scheduled[#scheduled + 1] = { delay = delay, callback = callback }
    end,
}
local function new_worker(options)
    options = options or {}
    options.temp_dir = options.temp_dir or temp_dir
    if options.runner == nil then options.runner = runner end
    if options.runner == false then options.runner = nil end
    options.scheduler = options.scheduler or scheduler
    options.now = options.now or function() return clock end
    options.read_memory = options.read_memory or function() return "MemAvailable: 262144 kB\n" end
    return BackgroundWorker:new(options)
end
local function poll()
    local entry = table.remove(scheduled, 1)
    expect(entry ~= nil, "worker did not schedule a poll")
    entry.callback()
    return entry
end
local function finish(pid)
    children[pid]()
    done[pid] = true
end

---------------------------------------------------------------------------
-- Launch failures: no runner, refused fork, fork ENOMEM with cooldown, a
-- busy worker without queueing.
do
    local results = {}
    local worker = new_worker { runner = false }
    expect(not worker:available(), "worker without runner claimed to be available")
    local ok, err = worker:start {
        task = function() end,
        on_done = function(value) results[#results + 1] = value end,
    }
    expect(not ok and err == "worker_unavailable" and results[1].error == "worker_unavailable",
        "missing runner was not reported")

    local failing = {
        run = function() return nil, "fork: Resource temporarily unavailable" end,
        is_done = function() return true end,
        terminate = function() end,
    }
    worker = new_worker { runner = failing }
    results = {}
    ok, err = worker:start {
        task = function() end,
        on_done = function(value) results[#results + 1] = value end,
    }
    expect(not ok and err:find("Resource temporarily unavailable", 1, true)
        and results[1].ok == false and results[1].available_kb == 262144,
        "refused fork was not reported with the free memory")
    expect(not worker:busy() and #scheduled == 0, "refused fork left a job or poll behind")

    local forks = 0
    local enomem = {
        run = function()
            forks = forks + 1
            error("fork failed: Cannot allocate memory")
        end,
        is_done = function() return true end,
        terminate = function() end,
    }
    worker = new_worker { runner = enomem }
    results = {}
    ok, err = worker:start {
        task = function() end,
        on_done = function(value) results[#results + 1] = value end,
    }
    expect(not ok and err == "low_memory" and results[1].error == "low_memory",
        "fork ENOMEM was not reported as low_memory")
    clock = clock + 10
    ok, err = worker:start {
        task = function() end,
        on_done = function(value) results[#results + 1] = value end,
    }
    expect(not ok and err == "low_memory" and forks == 1 and results[2].error == "low_memory",
        "worker forked again during the memory cooldown")
    clock = clock + 21
    worker.runner = runner
    ok = worker:start { task = function() return "after cooldown" end }
    expect(ok and worker:busy(), "worker did not recover after the memory cooldown")
    finish(next_pid)
    poll()

    -- Busy without queue: refused, the running job is untouched.
    worker = new_worker()
    ok = worker:start { task = function() return 1 end }
    local running_pid = next_pid
    local busy_ok, busy_err = worker:start { task = function() return 2 end }
    expect(ok and not busy_ok and busy_err == "worker_busy" and worker.job.pid == running_pid,
        "busy worker accepted an unqueued job")
    finish(running_pid)
    poll()
    scheduled = {}
end

---------------------------------------------------------------------------
-- Child context: progress delivery, sleep, cancellation and task errors.
do
    local worker = new_worker()
    local progress, result, launched = {}, nil, nil
    local usleeps = {}
    FFIUtil.usleep = function(us) usleeps[#usleeps + 1] = us end
    local ok, handle = worker:start {
        task = function(context)
            context.emit { stage = "source", attempt = 1 }
            context.sleep(0.25)
            context.emit "not a table"
            context.checkCancelled()
            return { pages = 3, token = context.token }
        end,
        on_launch = function(pid, available_kb) launched = { pid, available_kb } end,
        on_progress = function(value) progress[#progress + 1] = value end,
        on_done = function(value) result = value end,
    }
    local pid = next_pid
    expect(ok and launched[1] == pid and launched[2] == 262144,
        "on_launch did not receive the pid and free memory")
    children[pid]()
    local slept = 0
    for _, us in ipairs(usleeps) do
        expect(us <= 100000, "child sleep slice too long: " .. us)
        slept = slept + us
    end
    expect(#usleeps >= 3 and math.abs(slept - 250000) < 1000,
        "child sleep was not sliced into short cancellable naps")
    -- The second emit (a non-table) replaced the first progress file.
    poll()
    expect(#progress == 1 and progress[1].task_token == handle.token
        and progress[1].stage == nil, "latest progress state was not delivered")
    poll()
    expect(#progress == 1, "unchanged progress was delivered twice")
    done[pid] = true
    poll()
    expect(result.ok and result.value.pages == 3 and result.value.token == handle.token,
        "task result was not delivered")
    local job_files = { "progress.json", "result.json", "cancel" }
    for _, suffix in ipairs(job_files) do
        local path = temp_dir .. "/prefetch-" .. handle.token .. "." .. suffix
        expect(not exists(path) and not exists(path .. ".tmp"), "job file left behind: " .. suffix)
    end

    -- A task error is reported with its message; nothing is cancelled.
    result = nil
    worker:start {
        task = function() error("HTTP 500 from chapter") end,
        on_done = function(value) result = value end,
    }
    finish(next_pid)
    poll()
    expect(result.ok == false and not result.cancelled
        and result.error:find("HTTP 500", 1, true), "task error was not reported")

    -- Cancelled while sleeping: the child stops and reports cancellation.
    result = nil
    local reached_end = false
    handle = select(2, worker:start {
        task = function(context)
            context.sleep(5)
            reached_end = true
        end,
        on_done = function(value) result = value end,
    })
    pid = next_pid
    expect(worker:cancel(handle, "document_closed"), "running job did not accept cancel")
    expect(exists(worker.job.cancel_path), "cancel marker was not written for the child")
    usleeps = {}
    children[pid]()
    expect(not reached_end and #usleeps == 0, "cancelled child kept sleeping")
    done[pid] = true
    poll()
    expect(result.ok == false and result.cancelled == true and result.error == "cancelled",
        "cancelled child did not report cancellation")
    expect(not terminated[pid], "child that exited on its own was killed")

    -- Cancelled before the task even ran.
    result = nil
    local ran = false
    handle = select(2, worker:start {
        task = function() ran = true end,
        on_done = function(value) result = value end,
    })
    worker:cancel(handle)
    finish(next_pid)
    poll()
    expect(not ran and result.cancelled and result.error == "cancelled",
        "pre-cancelled child still ran its task")

    -- A result that cannot be encoded leaves no file: reported as missing.
    result = nil
    worker:start {
        task = function() return { unencodable = true } end,
        on_done = function(value) result = value end,
    }
    finish(next_pid)
    poll()
    expect(result.ok == false and result.error == "worker_no_result",
        "unencodable result was not reported as missing")
    FFIUtil.usleep = nil
    scheduled = {}
end

---------------------------------------------------------------------------
-- Malformed, stale and partial result/progress files.
do
    local worker = new_worker()
    local result
    local progress = {}
    local ok, handle = worker:start {
        task = function() return "unused" end,
        on_progress = function(value) progress[#progress + 1] = value end,
        on_done = function(value) result = value end,
    }
    local pid = next_pid
    local job = worker.job
    -- Corrupt progress and a progress file of another job are ignored.
    write_file(job.progress_path, "{\"stage\":")
    poll()
    write_file(job.progress_path, require("json").encode { task_token = "other", stage = "x" })
    poll()
    expect(#progress == 0, "corrupt or foreign progress was delivered")
    -- Only a partial (.tmp) result exists when the child dies.
    write_file(job.result_path .. ".tmp", "{\"ok\":tr")
    done[pid] = true
    poll()
    expect(result.ok == false and result.error == "worker_no_result" and not result.cancelled,
        "dead child without a result was not reported")
    expect(not exists(job.result_path .. ".tmp"), "partial result file was left behind")
    expect(ok and handle, "stale-result job did not start")

    -- A corrupt result file.
    result = nil
    worker:start {
        task = function() return "unused" end,
        on_done = function(value) result = value end,
    }
    write_file(worker.job.result_path, "garbage")
    done[next_pid] = true
    poll()
    expect(result.ok == false and result.error == "worker_no_result",
        "corrupt result file was accepted")

    -- A leftover result of a previous job with the same path is rejected.
    result = nil
    worker:start {
        task = function() return "unused" end,
        on_done = function(value) result = value end,
    }
    write_file(worker.job.result_path, require("json").encode {
        ok = true, value = "stale", task_token = "previous-job",
    })
    done[next_pid] = true
    poll()
    expect(result.ok == false and result.value == nil,
        "a result with another job's token was accepted")

    -- is_done throwing is retried on the next poll, not treated as done.
    result = nil
    worker:start {
        task = function() return "eventually" end,
        on_done = function(value) result = value end,
    }
    pid = next_pid
    children[pid]()
    done[pid] = "throw"
    poll()
    expect(result == nil and worker:busy() and #scheduled == 1,
        "is_done failure did not reschedule the poll")
    done[pid] = true
    poll()
    expect(result.ok and result.value == "eventually", "result lost after is_done failure")

    -- A throwing on_done is logged and the worker moves on.
    local before = #warnings
    worker:start {
        task = function() return 1 end,
        on_done = function() error("listener gone") end,
    }
    finish(next_pid)
    poll()
    expect(#warnings == before + 1 and warnings[#warnings]:find("listener gone", 1, true),
        "throwing completion callback was not logged")
    expect(not worker:busy(), "throwing completion callback wedged the worker")
    scheduled = {}
end

---------------------------------------------------------------------------
-- Stalled children time out on the per-job timeout; progress keeps a slow
-- child alive; a child ignoring cancel is killed after the grace period.
do
    local now_mono = 0
    local worker = new_worker { clock = function() return now_mono end, timeout = 60 }
    local result
    worker:start {
        timeout = 30,
        task = function() return "slow" end,
        on_progress = function() end,
        on_done = function(value) result = value end,
    }
    local pid = next_pid
    local job = worker.job
    now_mono = 25
    write_file(job.progress_path, require("json").encode {
        task_token = job.request.token, stage = "images",
    })
    poll()
    now_mono = 50
    poll()
    expect(not terminated[pid] and result == nil, "child with recent progress was killed")
    now_mono = 55
    poll()
    expect(terminated[pid] == 1 and result.ok == false and result.error == "worker_timeout"
        and result.cancelled == false, "stalled child was not timed out")

    -- Cancel: marker written, killed only after the grace period, once.
    result = nil
    worker = new_worker { clock = function() return now_mono end, cancel_grace = 5 }
    local handle = select(2, worker:start {
        task = function() return "ignores cancel" end,
        on_done = function(value) result = value end,
    })
    pid = next_pid
    now_mono = 100
    worker:cancel(handle, "cache_cleanup")
    worker:cancel(handle, "second reason")
    expect(#scheduled == 1, "repeated cancel scheduled more than one poll")
    now_mono = 104
    poll()
    expect(not terminated[pid] and result == nil, "child killed before the cancel grace")
    now_mono = 105
    poll()
    expect(terminated[pid] == 1 and result.cancelled == true and result.error == "cache_cleanup",
        "child ignoring cancel was not killed with the first reason")

    -- Cancel with an unwritable temp dir kills the child at once.
    local doomed_dir = temp_dir .. "/doomed"
    os.execute("mkdir -p '" .. doomed_dir .. "'")
    worker = new_worker { temp_dir = doomed_dir, clock = function() return now_mono end }
    result = nil
    handle = select(2, worker:start {
        task = function() return "x" end,
        on_done = function(value) result = value end,
    })
    pid = next_pid
    os.execute("rm -rf '" .. doomed_dir .. "'")
    expect(worker:cancel(handle, "document_closed"), "cancel failed without a temp dir")
    expect(terminated[pid] == 1, "child was not killed when the cancel marker could not be written")
    poll()
    expect(terminated[pid] == 1 and result.cancelled and result.error == "document_closed",
        "unwritable cancel did not report cancellation")

    -- Cancelling an unknown or finished request is a no-op.
    expect(worker:cancel({ token = "nobody" }) == false and worker:cancel(nil) == false,
        "cancel of an idle worker claimed success")
    scheduled = {}
end

---------------------------------------------------------------------------
-- Pending queue: replacement completes the dropped request, cancel of a
-- pending request, poll scheduling of an idle worker.
do
    local worker = new_worker()
    local events = {}
    local function job(name, extra)
        local options = {
            task = function() return name end,
            queue = true,
            on_done = function(value) events[#events + 1] = { name = name, value = value } end,
        }
        for key, value in pairs(extra or {}) do options[key] = value end
        return options
    end
    worker:start(job("active", { kind = "annotation" }))
    local active_pid = next_pid
    local pending_b = select(2, worker:start(job("b", { kind = "chapter", replace_active = true })))
    expect(worker.pending == pending_b and not worker.job.cancel_requested_at,
        "different-kind replacement cancelled the active job")
    worker:start(job("c"))
    expect(#events == 1 and events[1].name == "b" and events[1].value.cancelled
        and events[1].value.error == "replaced", "replaced pending job was not completed")
    local pending_d = select(2, worker:start(job("d")))
    expect(worker:cancel(pending_d, "document_closed"), "pending job did not accept cancel")
    expect(#events == 3 and events[3].name == "d" and events[3].value.error == "document_closed"
        and worker.pending == nil, "cancelled pending job was not completed")
    expect(not worker.job.cancel_requested_at, "cancelling a pending job touched the active one")
    finish(active_pid)
    poll()
    expect(events[4].name == "active" and events[4].value.ok and not worker:busy(),
        "active job did not finish")
    expect(next_pid == active_pid, "a dropped pending job was launched")

    -- An idle poll (e.g. after a cancel race) just starts nothing.
    worker:_schedule()
    worker:_schedule()
    expect(#scheduled == 1 and scheduled[1].delay == 0.25, "duplicate idle poll was scheduled")
    poll()
    expect(not worker:busy() and #scheduled == 0, "idle poll started work")

    -- A superseded poll task does nothing.
    worker:start(job("e"))
    local stale = table.remove(scheduled, 1).callback
    worker.poll_task = nil
    finish(next_pid)
    stale()
    expect(worker:busy(), "superseded poll task reaped the job")
    worker:_schedule()
    poll()
    expect(not worker:busy(), "fresh poll did not reap the job")
    scheduled = {}
end

---------------------------------------------------------------------------
-- Construction defaults: temp dir creation, default runner, monotonic clock.
do
    mkdir_calls = {}
    local fresh_dir = temp_dir .. "/fresh"
    local worker = new_worker { temp_dir = fresh_dir }
    expect(mkdir_calls[1] == fresh_dir and worker:available(), "temp dir was not created")
    mkdir_result = false
    worker = new_worker { temp_dir = temp_dir .. "/denied" }
    expect(not worker:available(), "worker without a temp dir claimed to be available")
    mkdir_result = true

    -- No subprocess support (or Android): no runner.
    local default = BackgroundWorker:new { temp_dir = temp_dir, scheduler = scheduler }
    expect(not default:available(), "worker without runInSubProcess claimed to be available")
    local forks, waits, kills = {}, {}, {}
    FFIUtil.runInSubProcess = function(callback, with_pipe, double_fork)
        forks[#forks + 1] = { callback = callback, with_pipe = with_pipe, double_fork = double_fork }
        return 900 + #forks
    end
    FFIUtil.isSubProcessDone = function(pid, wait) waits[#waits + 1] = { pid, wait }; return true end
    FFIUtil.terminateSubProcess = function(pid) kills[#kills + 1] = pid end
    FFIUtil.isAndroid = function() return true end
    default = BackgroundWorker:new { temp_dir = temp_dir, scheduler = scheduler }
    expect(not default:available(), "Android must not fork background workers")
    FFIUtil.isAndroid = function() return false end
    mono = 1000
    default = BackgroundWorker:new {
        temp_dir = temp_dir, scheduler = scheduler,
        read_memory = function() return "MemAvailable: 262144 kB\n" end,
    }
    expect(default:available(), "default runner was not used")
    local result
    local handle = select(2, default:start {
        task = function() return "forked" end,
        on_done = function(value) result = value end,
    })
    expect(#forks == 1 and forks[1].with_pipe == false and forks[1].double_fork == false,
        "default runner did not fork without a pipe")
    default:cancel(handle, "x")
    mono = mono + 6
    FFIUtil.isSubProcessDone = function(pid, wait) waits[#waits + 1] = { pid, wait }; return false end
    poll()
    expect(kills[1] == 901, "default runner did not terminate after the cancel grace")
    expect(waits[1][1] == 901 and waits[1][2] == false, "default runner waited blocking")
    FFIUtil.isSubProcessDone = function() return true end
    poll()
    expect(result and result.cancelled and result.error == "x", "default runner job not reaped")

    -- Without ui/time.to_number the clock falls back to os.time.
    TimeStub.to_number = nil
    default = BackgroundWorker:new { temp_dir = temp_dir, scheduler = scheduler }
    local value = default.clock()
    expect(type(value) == "number" and math.abs(value - os.time()) <= 1,
        "clock did not fall back to os.time")
    TimeStub.to_number = function(raw) return raw / 1000000 end

    -- Default memory reader reads /proc/meminfo (if present).
    local kb = default:availableMemoryKB()
    expect(kb == nil or (type(kb) == "number" and kb > 0), "default memory reader returned junk")
    FFIUtil.runInSubProcess, FFIUtil.isSubProcessDone, FFIUtil.terminateSubProcess = nil, nil, nil
    scheduled = {}
end

os.execute("rm -rf '" .. temp_dir .. "'")
print(("background_worker_lifecycle_spec: %d checks"):format(checks))
