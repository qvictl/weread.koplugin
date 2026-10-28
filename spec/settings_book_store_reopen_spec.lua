package.path = "./?.lua;./?/init.lua;" .. package.path

-- Settings + BookStore on a real temporary directory: book records and
-- preferences survive a fresh Settings instance on the same files, failed book
-- writes leave neither the index nor stray ".tmp" files behind, and the
-- legacy-key cleanup works with LuaSettings stores that lack delSetting.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

-- Deterministic JSON / LuaSettings serialisation; decode via loadstring.
local function serialize(value)
    if type(value) == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _i, key in ipairs(keys) do
            local encoded_key = type(key) == "string" and string.format("%q", key) or tostring(key)
            parts[#parts + 1] = "[" .. encoded_key .. "]=" .. serialize(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end
local function deserialize(text)
    local chunk = assert(loadstring("return " .. text))
    return chunk()
end
package.preload["json"] = function()
    return { encode = serialize, decode = deserialize }
end
package.preload["weread.lib.logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end
local function is_dir(path)
    local handle = io.open(path .. "/.", "rb")
    if handle then handle:close() return true end
    return false
end
local function exists(path) return read_file(path) ~= nil or is_dir(path) end

-- lfs over the real filesystem; mkdir reports failures like the real module.
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local attributes
            if is_dir(path) then
                attributes = { mode = "directory", size = 0, modification = 0 }
            else
                local content = read_file(path)
                if content then
                    attributes = { mode = "file", size = #content, modification = 0 }
                end
            end
            if field then return attributes and attributes[field] end
            return attributes
        end,
        mkdir = function(path)
            if os.execute("mkdir '" .. path .. "' 2>/dev/null") == 0 then return true end
            return nil, "cannot create " .. path
        end,
    }
end

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p '" .. root .. "/settings' '" .. root .. "/data'") == 0)
package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return root .. "/data" end,
        getSettingsDir = function() return root .. "/settings" end,
    }
end

-- LuaSettings: values persist to the file only on flush(). `with_del` toggles
-- delSetting so both store generations are exercised.
local with_del = true
local flushes = 0
package.preload["luasettings"] = function()
    return {
        open = function(_self, path)
            local content = read_file(path)
            local data = content and deserialize(content) or {}
            local store = {}
            function store.readSetting(_store, key, default)
                local value = data[key]
                if value == nil then return default end
                return value
            end
            function store.saveSetting(_store, key, value) data[key] = value end
            if with_del then
                function store.delSetting(_store, key) data[key] = nil end
            end
            function store.flush()
                flushes = flushes + 1
                local file = assert(io.open(path, "wb"))
                file:write(serialize(data))
                file:close()
            end
            return store
        end,
    }
end

local Settings = require("weread.lib.settings")
local settings_file = root .. "/settings/weread.lua"

-- ── first start: directories, defaults, legacy cleanup without delSetting ───
-- Pre-existing file from an old plugin version with legacy keys.
local seed = assert(io.open(settings_file, "wb"))
seed:write(serialize({
    auth_schema_version = Settings.AUTH_SCHEMA_VERSION,
    api_key = "key-1",
    config_loaded = true,
    curl_payload = "legacy",
    cache = { download_images = false },
}))
seed:close()
with_del = false
local settings = Settings:new()
expect(is_dir(root .. "/data/weread") and is_dir(root .. "/data/weread/cache"),
    "data and cache directories not created")
local persisted = deserialize(read_file(settings_file))
expect(persisted.config_loaded == nil and persisted.curl_payload == nil,
    "legacy keys not removed through saveSetting(nil) when delSetting is missing")
expect(persisted.cache.download_book_images == false and persisted.cache.download_images == nil,
    "legacy image preference not migrated")
expect(persisted.api_key == "key-1", "current-schema credentials must survive startup")

settings:set("scratch", "value")
settings:delete("scratch")
expect(settings:get("scratch", "fallback") == "fallback",
    "delete without delSetting did not clear the value")
with_del = true

-- get_all exposes every default, with stored values winning.
local all = settings:get_all()
expect(all.api_key == "key-1" and type(all.sync) == "table" and type(all.read_report) == "table",
    "get_all did not merge defaults and stored values")
expect(all.cache.download_book_images == false, "get_all lost the migrated preference")
expect(settings:get_download_dir() == settings.cache_dir, "download dir accessor")

-- Empty Set-Cookie headers are ignored without flushing.
local flushes_before = flushes
expect(settings:merge_set_cookie(nil) == false and settings:merge_set_cookie("") == false,
    "empty Set-Cookie reported a change")
expect(flushes == flushes_before, "empty Set-Cookie flushed the settings file")

-- ── put_book: records land on disk and survive a new Settings instance ──────
settings:put_book("b1", {
    bookId = "b1", title = "Durable",
    chapter_uid = 12, chapter_offset = 0.5,            -- reading_state.json
    mp_articles = { "a1" },                            -- articles.json
    chapters = { { chapterUid = 1 } },                 -- never stored here
})
local book_dir = settings.cache_dir .. "/b1"
for _, name in ipairs({ "metadata.json", "reading_state.json", "articles.json" }) do
    expect(read_file(book_dir .. "/" .. name), name .. " not written")
    expect(not exists(book_dir .. "/" .. name .. ".tmp"), name .. ".tmp left behind")
end
local metadata = deserialize(read_file(book_dir .. "/metadata.json"))
expect(metadata.title == "Durable" and metadata.chapters == nil and metadata.chapter_uid == nil,
    "fields were not split between the record files")
settings:set_download_dir(root .. "/downloads")
settings:flush()

local reopened = Settings:new()
expect(reopened.cache_dir == root .. "/downloads", "download dir not restored on reopen")
local book = reopened:get_book("b1")
expect(book and book.title == "Durable" and book.chapter_uid == 12
    and book.chapter_offset == 0.5 and book.mp_articles[1] == "a1",
    "book record did not survive a new Settings instance")
expect(book.cache_dir == book_dir, "book dir must stay where it was written")
expect(book.chapters == nil, "catalog leaked into the record files")
expect(reopened:get_book_dirs().b1 == book_dir, "index does not resolve the stored directory")

-- Updating reading progress keeps the record on the original directory, and
-- dropping reading/article fields removes their files.
book.chapter_uid = 13
reopened:put_book("b1", book)
expect(deserialize(read_file(book_dir .. "/reading_state.json")).chapter_uid == 13,
    "progress update not written in place")
reopened:put_book("b1", { bookId = "b1", title = "Durable", cache_dir = book_dir })
expect(not exists(book_dir .. "/reading_state.json") and not exists(book_dir .. "/articles.json"),
    "empty reading state / articles files were not removed")
expect(reopened:get_book("b1").chapter_uid == nil, "removed reading state still loaded")

-- ── failed writes: blocked directory ────────────────────────────────────────
-- A regular file where a parent directory should be: mkdir fails, put_book
-- raises and the index is not updated.
local blocker = root .. "/blocker"
local handle = assert(io.open(blocker, "wb"))
handle:write("not a directory")
handle:close()
local ok, err = pcall(reopened.put_book, reopened, "b2",
    { bookId = "b2", title = "Blocked", cache_dir = blocker .. "/b2" })
expect(not ok and tostring(err):find("Could not save book data", 1, true),
    "blocked book directory did not raise")
expect(reopened:get_book("b2") == nil, "failed put_book still indexed the book")
expect(read_file(blocker) == "not a directory", "blocking file was modified")

-- ── failed writes: target replaced by a directory ──────────────────────────
-- metadata.json is a non-empty directory: the rename into place fails, the
-- temporary file is removed and the previous record files are untouched.
local stuck_dir = root .. "/stuck"
assert(os.execute("mkdir -p '" .. stuck_dir .. "/metadata.json/keep'") == 0)
ok, err = pcall(reopened.put_book, reopened, "b3",
    { bookId = "b3", title = "Stuck", cache_dir = stuck_dir })
expect(not ok and tostring(err):find("Could not save book data", 1, true),
    "failed rename was not reported")
expect(not exists(stuck_dir .. "/metadata.json.tmp"), "temporary file left after a failed rename")
expect(is_dir(stuck_dir .. "/metadata.json/keep"), "failed write damaged the existing entry")
expect(reopened:get_book("b3") == nil, "failed rename still indexed the book")

-- ── delete_book only drops the index entry and persists on flush ───────────
reopened:delete_book("missing") -- no-op
reopened:delete_book("b1")
expect(reopened:get_book("b1") == nil, "deleted book still readable")
reopened:flush()
local third = Settings:new()
expect(third:get_book("b1") == nil, "book deletion not persisted")
expect(read_file(book_dir .. "/metadata.json"), "delete_book must not remove downloaded files")
expect(third:get("api_key") == "key-1", "credentials lost across reopen")

os.execute("rm -rf '" .. root .. "'")
print(("settings_book_store_reopen_spec: %d checks"):format(checks))
