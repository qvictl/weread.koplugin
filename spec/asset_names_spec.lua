package.path = "./?.lua;./?/init.lua;" .. package.path
for _, name in ipairs({ "ui/uimanager", "ui/widget/infomessage", "libs/libkoreader-lfs" }) do
    package.preload[name] = package.preload[name] or function() return {} end
end
local ok, Content = pcall(require, "weread.lib.content")
if not ok then
    print("asset_names_spec: skipped (" .. tostring(Content):sub(1, 80) .. ")")
    return
end
local name = Content._unique_asset_name

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local used = {}
expect(name(used, "photo", ".jpg") == "photo.jpg", "plain name kept")
expect(name(used, "Photo", ".jpg") == "Photo-2.jpg", "case-insensitive duplicate renamed (FAT storage)")
expect(name(used, "cover", ".jpg") == "cover-2.jpg", "cover.* is reserved for the EPUB cover")
local odd = name(used, "a&b #1%.png", ".png")
expect(not odd:find("[&#% ]"), "href-breaking characters removed: " .. odd)
expect(name(used, "图", ".png") == "img.png", "name without ASCII falls back to img")

local resumed = {}
resumed["chapter.png"] = true -- as rebuilt from the workspace (lowercased)
expect(name(resumed, "Chapter", ".png") == "Chapter-2.png", "resumed names are honoured")

local sparse = { ["photo.png"] = true, ["photo-3.png"] = true }
expect(name(sparse, "Photo", ".png") == "Photo-2.png", "resume fills the first unused suffix")
expect(name(sparse, "photo", ".png") == "photo-4.png", "cursor still checks names occupied before resume")
expect(name(sparse, "photo-4", ".png") == "photo-4-2.png", "numbered stems have an independent suffix")
expect(name(sparse, "photo", ".jpg") == "photo.jpg", "extensions have independent suffixes")

-- Count map accesses instead of relying on machine speed to detect the old
-- quadratic scan. The set is a proxy so reads of occupied names count too.
local probes, backing = 0, {}
local many = setmetatable({}, {
    __index = function(_, key) probes = probes + 1; return backing[key] end,
    __newindex = function(_, key, value) backing[key] = value end,
})
for i = 1, 512 do
    local expected = i == 1 and "image.png" or "image-" .. i .. ".png"
    expect(name(many, "image", ".png") == expected, "dense collision sequence changed at " .. i)
end
expect(probes < 512 * 12, "collision lookup work must grow linearly: " .. probes)

-- Chapter workers receive a newly decoded table, so module-local cursors
-- would be lost at precisely the boundary that matters for a long book.
local transferred = {}
for key, value in pairs(backing) do
    if type(value) == "table" then
        local copy = {}
        for k, v in pairs(value) do copy[k] = v end
        transferred[key] = copy
    else
        transferred[key] = value
    end
end
expect(name(transferred, "IMAGE", ".png") == "IMAGE-513.png", "worker transfer preserves case-insensitive sequence")

print(string.format("asset_names_spec: %d checks", checks))
