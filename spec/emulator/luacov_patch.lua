-- KOReader userpatch (installed as patches/1-weread-luacov.lua by
-- scripts/run_emulator_scenarios.py --coverage). Priority 1 ("early") runs
-- before PluginLoader, so the plugin's module-level code is counted too.
--
-- LuaJIT has one global debug hook, so coroutines (Trapper, the scenario)
-- are covered. The JIT is switched off so line hooks fire for every line.
-- Forked workers (ffi/util runInSubProcess) leave with C._exit(), which
-- skips Lua exit handlers: wrap the child function so each child writes its
-- own per-PID stats file before exiting. The parent saves on os.exit().
local dir = os.getenv("WEREAD_LUACOV_DIR")
local src = os.getenv("WEREAD_LUACOV_SRC")
if not dir or dir == "" or not src or src == "" then return end

package.path = src .. "/?.lua;" .. package.path
local ffi = require("ffi")
pcall(ffi.cdef, "int getpid(void);")
local function statsfile()
    return string.format("%s/luacov.stats.%d.out", dir, ffi.C.getpid())
end

if jit then
    jit.off()
    jit.flush()
end

local runner = require("luacov.runner")
runner.init({
    statsfile = statsfile(),
    include = {
        "weread%.koplugin/+main$",
        "weread%.koplugin/+weread/",
        "weread%.koplugin/+integrations/",
    },
    exclude = { "luacov" },
    savestepsize = 1000000000,
    runreport = false,
    deletestats = false,
    tick = false,
})

local ffiutil = require("ffi/util")
local run_in_subprocess = ffiutil.runInSubProcess
ffiutil.runInSubProcess = function(func, ...)
    return run_in_subprocess(function(...)
        local results = { pcall(func, ...) }
        pcall(function()
            runner.configuration.statsfile = statsfile()
            runner.save_stats()
        end)
        if not results[1] then error(results[2], 0) end
        return unpack(results, 2, table.maxn(results))
    end, ...)
end
