-- Run from the repository root: luajit scripts/benchmark_asset_names.lua [baseline SHA]
-- Measures synthetic same-basename image allocations, without network or disk I/O.
package.path = "./?.lua;./?/init.lua;" .. package.path
for _, key in ipairs({ "ui/uimanager", "ui/widget/infomessage", "libs/libkoreader-lfs" }) do
    package.preload[key] = function() return {} end
end

local revision = arg[1]
if revision then
    assert(#revision == 40 and revision:match("^[0-9a-f]+$"), "baseline must be a full commit SHA")
    package.preload["weread.lib.content"] = function()
        local pipe = assert(io.popen("git show " .. revision .. ":weread/lib/content.lua"))
        local source = pipe:read("*a")
        assert(pipe:close())
        return assert(loadstring(source, "@baseline/content.lua"))()
    end
end

local name = require("weread.lib.content")._unique_asset_name
local warm = {}
for _ = 1, 100 do name(warm, "same-image", ".png") end
warm = nil
for _, count in ipairs({ 1000, 2000 }) do
    collectgarbage("collect")
    local before_kb = collectgarbage("count")
    local used, digest = {}, 0
    local started = os.clock()
    for _ = 1, count do
        local value = name(used, "same-image", ".png")
        for i = 1, #value do digest = (digest * 33 + value:byte(i)) % 2147483647 end
    end
    local elapsed_ms = (os.clock() - started) * 1000
    collectgarbage("collect")
    print(string.format("count=%d cpu_ms=%.3f retained_heap_kib=%.1f names_digest=%d", count,
        elapsed_ms, collectgarbage("count") - before_kb, digest))
end
