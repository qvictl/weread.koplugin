-- Free-memory check before forking the whole KOReader process.
--
-- A fork shares pages until either side writes them, and a GC cycle in the
-- child writes to every live object: on a 512 MB device without swap a fork
-- under memory pressure thrashes the whole system instead of failing.

local MemoryGate = {}

MemoryGate.DEFAULT_MIN_AVAILABLE_KB = 64 * 1024
-- A download worker inherits the parent's Lua heap. Every page the child (or
-- its GC) writes is copied, so require room for the parent heap on top of a
-- fixed floor that keeps the Kindle framework and page cache breathing.
MemoryGate.FORK_FLOOR_KB = 96 * 1024
MemoryGate.FORK_HEADROOM_KB = 48 * 1024

function MemoryGate.parse_available_kb(raw)
    local values = {}
    for key, value in tostring(raw or ""):gmatch("([%a_]+):%s*(%d+)%s*kB") do
        values[key] = tonumber(value)
    end
    if values.MemAvailable then return values.MemAvailable end
    if values.MemFree then
        return values.MemFree + (values.Buffers or 0) + (values.Cached or 0)
    end
end

-- Resident set size of the current process from /proc/self/status.
function MemoryGate.parse_rss_kb(raw)
    return tonumber(tostring(raw or ""):match("VmRSS:%s*(%d+)%s*kB"))
end

local function read_proc(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

function MemoryGate.read_meminfo()
    return read_proc("/proc/meminfo")
end

function MemoryGate.read_self_status()
    return read_proc("/proc/self/status")
end

function MemoryGate.fork_requirement_kb(heap_kb)
    return math.max(MemoryGate.FORK_FLOOR_KB,
        math.ceil((tonumber(heap_kb) or 0) + MemoryGate.FORK_HEADROOM_KB))
end

-- Full collection (twice, so finalizers and their garbage go too) before the
-- fork, then MemAvailable >= max(96 MB, Lua heap + 48 MB).
-- Returns ok, available_kb, required_kb. Unknown memory counts as ok.
function MemoryGate.check_fork(read_memory)
    collectgarbage("collect")
    collectgarbage("collect")
    local required = MemoryGate.fork_requirement_kb(collectgarbage("count"))
    local available = MemoryGate.parse_available_kb(
        (read_memory or MemoryGate.read_meminfo)())
    if available and available < required then
        return false, available, required
    end
    return true, available, required
end

-- Collects garbage in the parent first (so the child inherits a compact heap),
-- then compares available memory to the floor. Returns ok, available_kb.
-- Unknown memory (no /proc/meminfo) counts as ok.
function MemoryGate.check(min_kb, read_memory)
    collectgarbage("collect")
    local available = MemoryGate.parse_available_kb((read_memory or MemoryGate.read_meminfo)())
    if available and available < (min_kb or MemoryGate.DEFAULT_MIN_AVAILABLE_KB) then
        return false, available
    end
    return true, available
end

return MemoryGate
