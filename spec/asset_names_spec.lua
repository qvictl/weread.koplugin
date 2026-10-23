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

print(string.format("asset_names_spec: %d checks", checks))
