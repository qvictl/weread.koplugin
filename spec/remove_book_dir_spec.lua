-- Book cache directories are deleted without a shell, and only when the
-- resolved directory is a per-book one.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- A tiny in-memory filesystem: path -> "directory" | "file" | "link".
local fs = {}
local removed = {}
local function children(path)
    local names = {}
    for entry in pairs(fs) do
        local parent, name = entry:match("^(.*)/([^/]+)$")
        if parent == path then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end
package.preload["libs/libkoreader-lfs"] = function()
    local function attributes(path, what)
        local mode = fs[path]
        if mode == "link" then mode = "directory" end -- links resolve to their target
        if not mode then return nil end
        if what then return mode end
        return { mode = mode }
    end
    return {
        attributes = attributes,
        symlinkattributes = function(path, what)
            local mode = fs[path]
            if not mode then return nil end
            if what then return mode end
            return { mode = mode }
        end,
        dir = function(path)
            assert(fs[path] == "directory", "listed a non-directory: " .. path)
            local names = { ".", ".." }
            for _i, name in ipairs(children(path)) do names[#names + 1] = name end
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        rmdir = function(path)
            assert(#children(path) == 0, "rmdir of a non-empty directory: " .. path)
            fs[path] = nil
            removed[#removed + 1] = path
            return true
        end,
    }
end
local real_remove = os.remove
os.remove = function(path)
    if fs[path] then
        assert(fs[path] ~= "directory" or #children(path) == 0, "removed a non-empty directory")
        fs[path] = nil
        removed[#removed + 1] = path
        return true
    end
    return nil, "missing"
end

for _i, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/pathchooser",
    "weread.lib.scan", "ui/uimanager",
}) do
    package.preload[name] = function() return {} end
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end, T = function(text) return text end }
end
package.preload["weread.lib.content"] = function()
    local Content = {}
    function Content.book_dir_name(book_id)
        return (tostring(book_id):gsub("[^%w%._-]", "_"))
    end
    function Content.book_resolved_dir(settings, book_id, book)
        if book and book.cache_dir then return book.cache_dir end
        local dir = book and type(book.cached_file) == "string"
            and book.cached_file:match("^(.*)/[^/]+$")
        return dir or (settings.cache_dir .. "/" .. Content.book_dir_name(book_id))
    end
    return Content
end

local Cache = require("weread.ui.cache")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local host = {
    settings = { cache_dir = "/mnt/us/books", default_cache_dir = "/data/weread/cache" },
}
for key, value in pairs(Cache) do host[key] = value end

-- A per-book directory is removed recursively, without following links.
fs["/mnt/us/books"] = "directory"
fs["/mnt/us/books/123"] = "directory"
fs["/mnt/us/books/123/a.epub"] = "file"
fs["/mnt/us/books/123/images"] = "directory"
fs["/mnt/us/books/123/images/1.jpg"] = "file"
fs["/mnt/us/books/123/outside"] = "link"
fs["/mnt/us/documents"] = "directory"
fs["/mnt/us/documents/keep.pdf"] = "file"
expect(host:removeBookDir("123", { cache_dir = "/mnt/us/books/123" }), "per-book directory was not removed")
expect(fs["/mnt/us/books/123"] == nil and fs["/mnt/us/books/123/images/1.jpg"] == nil,
    "book directory contents remain")
expect(fs["/mnt/us/books"] == "directory", "download root was removed")
expect(fs["/mnt/us/documents/keep.pdf"] == "file", "a symlink target outside the book was deleted")

-- A record whose file sits directly in the download root or a user library
-- folder must not delete that folder.
fs["/mnt/us/books/Some Book.epub"] = "file"
local before = #removed
expect(not host:removeBookDir("456", { cached_file = "/mnt/us/books/Some Book.epub" }),
    "download root was not refused")
expect(not host:removeBookDir("789", { cached_file = "/mnt/us/documents/keep.pdf" }),
    "user library folder was not refused")
expect(not host:removeBookDir("1", { cache_dir = "/" }), "filesystem root was not refused")
expect(not host:removeBookDir("cache", { cache_dir = "/data/weread/cache" }),
    "default download root was not refused")
expect(not host:removeBookDir("123", { cache_dir = "/mnt/us/documents/../books/123" }),
    "relative path components were not refused")
expect(not host:removeBookDir("123", { cache_dir = "relative/123" }), "relative path was not refused")
expect(#removed == before, "a refused directory was touched")

-- Missing directory: nothing to do.
expect(host:removeBookDir("555", nil), "missing directory is not a no-op")

-- No shell is involved at all.
local real_execute = os.execute
os.execute = function() error("shell used to delete a book") end
fs["/mnt/us/books/abc"] = "directory"
fs["/mnt/us/books/abc/x"] = "file"
expect(host:removeBookDir("abc", nil), "default per-book directory was not removed")
os.execute = real_execute
os.remove = real_remove

print(string.format("remove_book_dir_spec: %d checks", checks))
