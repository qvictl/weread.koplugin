-- Run with KOReader's LuaJIT (string.buffer required), from the plugin root:
--   /path/to/koreader/luajit spec/benchmarks/chapter_state.lua 811 10 delta
-- Arguments: chapters, unique remote images per chapter, full|delta.
-- Synthetic Content work only: no HTTP, fork, pipe or device measurements.
package.path = "./?.lua;./?/init.lua;" .. package.path
local buffer = require("string.buffer")
local ChapterState = require("weread.lib.chapter_state")
local Content = require("weread.lib.content")
local chapters, images = assert(tonumber(arg[1])), assert(tonumber(arg[2]))
local mode = assert(arg[3])
assert(chapters >= 1 and images >= 0 and (mode == "full" or mode == "delta"))
local png = "\137PNG\r\n\26\n" .. "synthetic image"
local client = { get_binary = function() return png end }
local function source(chapter)
    local parts = { "<html><body>", ("<p>Self-written synthetic text.</p>"):rep(180) }
    for image = 1, images do
        parts[#parts + 1] = string.format(
            '<img src="https://synthetic.invalid/book/figure-%08d.png?token=%s"/>',
            (chapter - 1) * images + image, ("a1b2c3d4"):rep(12))
    end
    parts[#parts + 1] = "</body></html>"
    return table.concat(parts)
end
local parent = {
    css = "p { line-height: 1.5; } img { max-width: 100%; }",
    workspace = { path = "/synthetic/cache/.weread-download-resume-full", resumable = true },
    used_asset_names = {},
}
for chapter = 1, chapters - 1 do
    Content.download_remote_images(client, source(chapter), parent.used_asset_names)
end
local child, collect
if mode == "delta" then
    child, collect = ChapterState.begin(parent)
else
    -- Only prepares an independent fixture, outside measured work. A real
    -- worker inherits this memory through fork rather than this clone.
    child = buffer.decode(buffer.encode(parent))
end
local xhtml, assets = Content.download_remote_images(client, source(chapters), child.used_asset_names)
for _, asset in ipairs(assets) do
    asset.path = parent.workspace.path .. "/images/" .. asset.href:match("([^/]+)$")
    asset.size, asset.data, asset.store = #asset.data, nil, true
end
local result = { xhtml = xhtml, assets = assets, finalized = true, book = { book_id = "synthetic" } }
local started = os.clock()
if mode == "delta" then result.state_delta = collect() else result.state = child end
local collect_us = (os.clock() - started) * 1000000
local value = { { ok = true, value = result }, n = 1 }
local repetitions = 60
for _ = 1, 10 do buffer.encode(value) end
started = os.clock()
for _ = 1, repetitions do buffer.encode(value) end
local encode_us = (os.clock() - started) * 1000000 / repetitions
local encoded = buffer.encode(value)
-- Release worker-only references before measuring the parent's decode.
child, collect, value, result, assets, xhtml, client, png = nil, nil, nil, nil, nil, nil, nil, nil -- luacheck: ignore 311
collectgarbage("collect")
local baseline = collectgarbage("count")
collectgarbage("stop")
started = os.clock()
local response = buffer.decode(encoded)[1].value
local cold_decode_us = (os.clock() - started) * 1000000
local decode_heap_kb = collectgarbage("count") - baseline
started = os.clock()
if mode == "delta" then parent = ChapterState.apply(parent, response.state_delta) else parent = response.state end
local apply_us = (os.clock() - started) * 1000000
local names, urls = 0, 0
for key in pairs(parent.used_asset_names) do
    if key ~= "__remote_image_hrefs" and key ~= "__next_asset_suffix" then names = names + 1 end
end
for _ in pairs(parent.used_asset_names.__remote_image_hrefs or {}) do urls = urls + 1 end
assert(names == chapters * images and urls == chapters * images)
collectgarbage("restart")
local times = {}
for index = 1, repetitions do
    started = os.clock()
    local decoded = buffer.decode(encoded)
    times[index] = (os.clock() - started) * 1000000
    assert(decoded[1].ok)
end
table.sort(times)
print("chapters\timages\tmode\twire_bytes\tcollect_us\tencode_us\tcold_decode_us\twarm_decode_median_us\tapply_us\tdecode_heap_kb")
print(string.format("%d\t%d\t%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f", chapters, images, mode,
    #encoded, collect_us, encode_us, cold_decode_us, times[math.ceil(repetitions / 2)], apply_us, decode_heap_kb))
