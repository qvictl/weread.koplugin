-- Free-memory check before forking the whole KOReader process.
--
-- A fork shares pages until either side writes them, and a GC cycle in the
-- child writes to every live object: on a 512 MB device without swap a fork
-- under memory pressure thrashes the whole system instead of failing.

local MemoryGate = {}

MemoryGate.DEFAULT_MIN_AVAILABLE_KB = 64 * 1024

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

function MemoryGate.read_meminfo()
    local file = io.open("/proc/meminfo", "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
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
