package.path = "./?.lua;./?/init.lua;" .. package.path
local dirs = {}
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path, what)
        if dirs[path] then return what == "mode" and "directory" or { mode = "directory" } end
    end }
end
for _, name in ipairs({ "ui/uimanager", "ui/widget/infomessage" }) do
    package.preload[name] = package.preload[name] or function() return {} end
end
local Content = require("weread.lib.content")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local purged = {}
local function purge(path) purged[#purged + 1] = path; return true end
local settings = { cache_dir = "/mnt/us/books" }

dirs["/mnt/us/books/123"] = true
expect(Content.remove_book_dir(settings, "123", { cache_dir = "/mnt/us/books/123" }, purge),
    "per-book directory is removed")
expect(purged[1] == "/mnt/us/books/123", "purged the book directory")

-- A record whose cached file sits directly in the download root (or a user
-- library folder) must not delete that folder.
local ok = Content.remove_book_dir(settings, "456",
    { cached_file = "/mnt/us/books/Some Book.epub" }, purge)
expect(not ok and #purged == 1, "download root was not refused")
ok = Content.remove_book_dir(settings, "789",
    { cached_file = "/mnt/us/documents/My Library/x.epub" }, purge)
expect(not ok and #purged == 1, "user library folder was not refused")
ok = Content.remove_book_dir(settings, "1", { cache_dir = "/" }, purge)
expect(not ok and #purged == 1, "root was not refused")

-- Missing directory: nothing to do.
expect(Content.remove_book_dir(settings, "555", nil, purge) and #purged == 1,
    "missing directory is a no-op")

print(string.format("remove_book_dir_spec: %d checks", checks))
