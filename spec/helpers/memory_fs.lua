-- In-memory filesystem for specs of code that walks, moves and deletes
-- directories through libkoreader-lfs, os.remove, os.execute ("mkdir -p" /
-- "mv -f" with single-quoted arguments) and io.open. Nothing touches the real
-- disk: every path the code under test reaches must exist in the fake tree,
-- and an unexpected shell command raises.
local M = {}

local Fs = {}
Fs.__index = Fs

local function parent_of(path)
    return path:match("^(.*)/[^/]+$")
end

-- Split a POSIX shell command line into words, honouring single quotes and
-- backslash escapes outside quotes ('\'' sequences).
local function shell_words(command)
    local words, current, in_quote, escaped, has_word = {}, {}, false, false, false
    for index = 1, #command do
        local char = command:sub(index, index)
        if escaped then
            current[#current + 1] = char
            escaped = false
        elseif in_quote then
            if char == "'" then in_quote = false else current[#current + 1] = char end
        elseif char == "'" then
            in_quote = true
            has_word = true
        elseif char == "\\" then
            escaped = true
            has_word = true
        elseif char == " " then
            if has_word then
                words[#words + 1] = table.concat(current)
                current, has_word = {}, false
            end
        else
            if char:match("[%$`;|&<>\"]") then
                error("unquoted shell metacharacter in command: " .. command, 0)
            end
            current[#current + 1] = char
            has_word = true
        end
    end
    assert(not in_quote and not escaped, "unterminated quote in command: " .. command)
    if has_word then words[#words + 1] = table.concat(current) end
    return words
end

function M.new()
    local self = setmetatable({
        nodes = {},        -- path -> { mode = "directory"|"file"|"link", size = n }
        removed = {},      -- paths deleted, in order
        commands = {},     -- shell commands run, in order
        fail_remove = {},  -- path -> error text: os.remove/rmdir fail
        unreadable = {},   -- path -> true: lfs.dir raises
        readonly = {},     -- directory -> true: io.open of a child fails
        mkdir_fails = {},  -- path -> true: "mkdir -p" leaves it missing
        mv_fails = {},     -- source path -> true: "mv -f" of it exits non-zero
    }, Fs)
    return self
end

function Fs:mkdir(path)
    local parent = parent_of(path)
    if parent and parent ~= "" and not self.nodes[parent] then self:mkdir(parent) end
    if not self.nodes[path] then self.nodes[path] = { mode = "directory" } end
    return self
end

function Fs:file(path, size)
    local parent = parent_of(path)
    if parent and parent ~= "" then self:mkdir(parent) end
    self.nodes[path] = { mode = "file", size = size or 0 }
    return self
end

function Fs:exists(path)
    return self.nodes[path] ~= nil
end

function Fs:is_file(path)
    local node = type(path) == "string" and self.nodes[path]
    return node and node.mode == "file" or false
end

function Fs:children(path)
    local names = {}
    for entry in pairs(self.nodes) do
        if parent_of(entry) == path then names[#names + 1] = entry:match("([^/]+)$") end
    end
    table.sort(names)
    return names
end

local function stat(self, path, what, follow)
    local node = self.nodes[path]
    if not node then return nil end
    local mode = node.mode
    if follow and mode == "link" then mode = "directory" end
    if what == "mode" then return mode end
    if what == "size" then return node.size or 0 end
    return { mode = mode, size = node.size or 0 }
end

function Fs:lfs()
    local fs = self
    return {
        attributes = function(path, what) return stat(fs, path, what, true) end,
        symlinkattributes = function(path, what) return stat(fs, path, what, false) end,
        dir = function(path)
            if fs.unreadable[path] then error("cannot open " .. path .. ": Permission denied") end
            local node = fs.nodes[path]
            if not node or node.mode ~= "directory" then
                error("cannot open " .. tostring(path) .. ": No such directory")
            end
            local names = { ".", ".." }
            for _i, name in ipairs(fs:children(path)) do names[#names + 1] = name end
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        rmdir = function(path)
            if fs.fail_remove[path] then return nil, fs.fail_remove[path] end
            if #fs:children(path) > 0 then return nil, "Directory not empty" end
            fs.nodes[path] = nil
            fs.removed[#fs.removed + 1] = path
            return true
        end,
    }
end

function Fs:remove(path)
    if self.fail_remove[path] then return nil, self.fail_remove[path] end
    local node = self.nodes[path]
    if not node then return nil, path .. ": No such file or directory" end
    assert(node.mode ~= "directory" or #self:children(path) == 0, "os.remove of a non-empty directory: " .. path)
    self.nodes[path] = nil
    self.removed[#self.removed + 1] = path
    return true
end

function Fs:execute(command)
    self.commands[#self.commands + 1] = command
    local words = shell_words(command)
    if words[1] == "mkdir" and words[2] == "-p" and #words == 3 then
        if not self.mkdir_fails[words[3]] then self:mkdir(words[3]) end
        return 0
    end
    if words[1] == "mv" and words[2] == "-f" and #words == 4 then
        local src, dst = words[3], words[4]
        if self.mv_fails[src] or not self.nodes[src] then return 256 end
        local moved = {}
        for path, node in pairs(self.nodes) do
            if path == src or path:sub(1, #src + 1) == src .. "/" then
                moved[dst .. path:sub(#src + 1)] = node
                self.nodes[path] = nil
            end
        end
        for path, node in pairs(moved) do self.nodes[path] = node end
        return 0
    end
    error("unexpected shell command: " .. command, 0)
end

function Fs:open(path, mode)
    local parent = parent_of(path)
    if self.readonly[parent] then return nil, path .. ": Permission denied" end
    local node = self.nodes[parent]
    if not node or node.mode ~= "directory" then return nil, path .. ": No such file or directory" end
    assert(mode == "w", "unexpected io.open mode " .. tostring(mode))
    local fs = self
    fs.nodes[path] = { mode = "file", size = 0 }
    return {
        write = function(handle, data)
            fs.nodes[path].size = fs.nodes[path].size + #data
            return handle
        end,
        close = function() return true end,
    }
end

-- Route libkoreader-lfs, os.remove, os.execute and io.open (for paths inside
-- the fake tree) to this filesystem. Returns a function restoring the real ones.
function Fs:install()
    local fs = self
    local lfs = self:lfs()
    local real_preload = package.preload["libs/libkoreader-lfs"]
    local real_loaded = package.loaded["libs/libkoreader-lfs"]
    package.preload["libs/libkoreader-lfs"] = function() return lfs end
    package.loaded["libs/libkoreader-lfs"] = lfs
    local real_remove, real_execute, real_open = os.remove, os.execute, io.open
    rawset(os, "remove", function(path) return fs:remove(path) end)
    rawset(os, "execute", function(command) return fs:execute(command) end)
    rawset(io, "open", function(path, mode)
        local root = type(path) == "string" and path:match("^(/[^/]+)")
        if root and fs.nodes[root] then return fs:open(path, mode) end
        return real_open(path, mode)
    end)
    return function()
        rawset(os, "remove", real_remove)
        rawset(os, "execute", real_execute)
        rawset(io, "open", real_open)
        package.preload["libs/libkoreader-lfs"] = real_preload
        package.loaded["libs/libkoreader-lfs"] = real_loaded
    end
end

return M
