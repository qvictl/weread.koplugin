-- BookStore durability and caching with KOReader's lfs/fsync helpers faked:
-- fsync before rename, ".bak" rotation and recovery, no shell spawns, and the
-- per-Settings file cache that keeps get_book/put_book off the disk.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

-- Deterministic JSON stand-in: sorted, nested serialisation; decode via load.
local function serialize(value)
    if type(value) == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _i, key in ipairs(keys) do
            parts[#parts + 1] = "[" .. string.format("%q", key) .. "]=" .. serialize(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end
local decodes = 0
package.preload["json"] = function()
    return {
        encode = function(value) return serialize(value) end,
        decode = function(text)
            decodes = decodes + 1
            local chunk = assert(loadstring("return " .. text))
            return chunk()
        end,
    }
end

local raw_open = io.open
local function is_dir(path)
    local handle = raw_open(path .. "/.", "rb")
    if handle then handle:close() return true end
    return false
end
local function file_size(path)
    if is_dir(path) then return nil end
    local file = raw_open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

local mkdirs = 0
-- Modification times come from a counter bumped by every rename into place.
local mtimes = {}
local clock = 0
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local attributes
            if is_dir(path) then
                attributes = { mode = "directory", size = 0, modification = 0 }
            else
                local size = file_size(path)
                if size then
                    attributes = { mode = "file", size = size, modification = mtimes[path] or 0 }
                end
            end
            if field then return attributes and attributes[field] end
            return attributes
        end,
        mkdir = function(path)
            mkdirs = mkdirs + 1
            return os.execute("mkdir '" .. path .. "' 2>/dev/null") == 0 or true
        end,
    }
end
local fsynced_files, fsynced_dirs = 0, 0
package.preload["ffi/util"] = function()
    return {
        fsyncOpenedFile = function(file)
            file:flush()
            fsynced_files = fsynced_files + 1
        end,
        fsyncDirectory = function() fsynced_dirs = fsynced_dirs + 1 end,
    }
end

local real_rename = os.rename
local renames = {}
os.rename = function(from, to) -- luacheck: ignore 122
    local ok, err = real_rename(from, to)
    if ok and from ~= to then
        renames[#renames + 1] = { from, to }
        clock = clock + 1
        mtimes[to] = clock
        mtimes[from] = nil
    end
    return ok, err
end
local real_execute = os.execute
local shell_spawns = 0
os.execute = function(command) -- luacheck: ignore 122
    if not tostring(command):match("^mkdir '") then shell_spawns = shell_spawns + 1 end
    return real_execute(command)
end

local BookStore = require("weread.lib.book_store")
local root = os.tmpname() .. "-weread-durability"
os.remove(root)
local settings = { cache_dir = root }

local function read(path)
    local file = raw_open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end
local function write(path, data)
    local file = assert(raw_open(path, "wb"))
    file:write(data)
    file:close()
end

-- First save creates the directory without a shell and fsyncs every file.
local ok, index = BookStore.save(settings, "42", {
    title = "First", progress = 10, cached_chapters = { ["9"] = "a.epub" },
})
expect(ok == true, "initial save failed")
local dir = index.cache_dir
local metadata_path = dir .. "/metadata.json"
local state_path = dir .. "/reading_state.json"
expect(mkdirs > 0 and shell_spawns == 0, "directory creation must use lfs, not a shell")
expect(fsynced_files == 2 and fsynced_dirs == 2,
    "every written file and its directory must be fsynced")
expect(read(metadata_path .. ".bak") == nil, "a first write has nothing to back up")

-- Unchanged save: no rename, no fsync, no reads (the cache holds the bytes).
local renames_before, fsyncs_before = #renames, fsynced_files
local reads = 0
io.open = function(path, mode) -- luacheck: ignore 122
    if mode == "rb" and path:match("%.json$") then reads = reads + 1 end
    return raw_open(path, mode)
end
ok = BookStore.save(settings, "42", BookStore.load(settings, "42", index))
expect(ok == true and #renames == renames_before and fsynced_files == fsyncs_before,
    "unchanged book data was rewritten")
expect(reads == 0, "cached book files were read again")

-- Repeated loads decode nothing and hand out private copies.
local decodes_before = decodes
local first = BookStore.load(settings, "42", index)
first.cached_chapters["10"] = "b.epub"
first.title = "mutated"
local second = BookStore.load(settings, "42", index)
expect(decodes == decodes_before and reads == 0, "cached load touched the disk")
expect(second.title == "First" and second.cached_chapters["10"] == nil,
    "caller mutation leaked into the shared cache")

-- Changing only the reading state rewrites only reading_state.json, keeping
-- the previous version as .bak.
local previous_state = read(state_path)
renames_before = #renames
second.progress = 55
ok = BookStore.save(settings, "42", second)
io.open = raw_open -- luacheck: ignore 122
expect(ok == true, "reading-state save failed")
local touched = {}
for i = renames_before + 1, #renames do touched[#touched + 1] = renames[i][2] end
expect(#touched == 2 and touched[1] == state_path .. ".bak" and touched[2] == state_path,
    "only reading_state.json should rotate and be replaced: " .. table.concat(touched, ","))
expect(read(state_path .. ".bak") == previous_state, "previous state was not kept as .bak")

-- A zero-length main file (hard reboot on vfat) falls back to the backup.
write(metadata_path .. ".bak", read(metadata_path))
write(metadata_path, "")
mtimes[metadata_path] = 999
local restored = BookStore.load(settings, "42", index)
expect(restored.title == "First" and restored.cached_chapters["9"] == "a.epub",
    "empty metadata.json was not recovered from metadata.json.bak")

-- Missing and corrupt main files fall back too.
os.remove(metadata_path)
expect(BookStore.load(settings, "42", index).title == "First",
    "missing metadata.json was not recovered from metadata.json.bak")
write(metadata_path, "{ corrupt")
mtimes[metadata_path] = 1000
expect(BookStore.load(settings, "42", index).title == "First",
    "corrupt metadata.json was not recovered from metadata.json.bak")

-- Saving over a corrupt file must not clobber the good backup.
local good_backup = read(metadata_path .. ".bak")
ok = BookStore.save(settings, "42", { title = "Second", cache_dir = dir })
expect(ok == true and read(metadata_path .. ".bak") == good_backup,
    "a corrupt main file replaced the good backup")
expect(BookStore.load(settings, "42", index).title == "Second", "new metadata not loaded")

-- An out-of-process writer is noticed through size/mtime.
local external = read(metadata_path):gsub("Second", "External!")
write(metadata_path, external)
mtimes[metadata_path] = 2000
expect(BookStore.load(settings, "42", index).title == "External!",
    "external change was hidden by the cache")

-- Removing a split file removes its backup so stale state cannot reappear.
ok = BookStore.save(settings, "42", { title = "Third", cache_dir = dir })
expect(ok == true and read(state_path) == nil and read(state_path .. ".bak") == nil,
    "removed reading state left a backup behind")
expect(BookStore.load(settings, "42", index).progress == nil,
    "removed reading state reappeared from its backup")

os.rename = real_rename -- luacheck: ignore 122
os.execute = real_execute -- luacheck: ignore 122
real_execute("rm -rf '" .. root .. "'")

print(("book_store_durability_spec: %d checks"):format(checks))
