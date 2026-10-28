package.path = "./?.lua;./?/init.lua;" .. package.path

-- LuaJIT returns 0, or true on Lua 5.2-compatible builds (Ubuntu 26.04).
local function sh_ok(command)
    local status = os.execute(command)
    return status == 0 or status == true
end

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
-- Every package.preload stub and package.loaded module this spec installs or
-- loads is put back afterwards, so a shared process (dofile) sees no leftovers.
local saved_preload, saved_loaded = {}, {}
for name, loader in pairs(package.preload) do saved_preload[name] = loader end
for name, module in pairs(package.loaded) do saved_loaded[name] = module end
local function restore_package_state()
    for name in pairs(package.preload) do
        if saved_preload[name] == nil then package.preload[name] = nil end
    end
    for name, loader in pairs(saved_preload) do package.preload[name] = loader end
    for name in pairs(package.loaded) do
        if saved_loaded[name] == nil then package.loaded[name] = nil end
    end
    for name, module in pairs(saved_loaded) do package.loaded[name] = module end
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
            if sh_ok("mkdir '" .. path .. "' 2>/dev/null") then return true end
            return nil, "cannot create " .. path
        end,
    }
end

local root = os.tmpname()
os.remove(root)
assert(sh_ok("mkdir -p '" .. root .. "/settings' '" .. root .. "/data'"))
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

-- The temporary tree and module state are cleaned up even when a check fails;
-- the original error (with traceback) is re-raised afterwards.
local function run_spec()
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
    assert(sh_ok("mkdir -p '" .. stuck_dir .. "/metadata.json/keep'"))
    ok, err = pcall(reopened.put_book, reopened, "b3",
        { bookId = "b3", title = "Stuck", cache_dir = stuck_dir })
    expect(not ok and tostring(err):find("Could not save book data", 1, true),
        "failed rename was not reported")
    expect(not exists(stuck_dir .. "/metadata.json.tmp"), "temporary file left after a failed rename")
    expect(is_dir(stuck_dir .. "/metadata.json/keep"), "failed write damaged the existing entry")
    expect(reopened:get_book("b3") == nil, "failed rename still indexed the book")

    -- ── failed writes: existing book, reading_state.json fails ─────────────────
    -- BookStore.save writes metadata.json first, then reading_state.json. When
    -- the second write fails put_book reports it and the index entry stays as
    -- it was. There is no cross-file atomicity, so the record files are not
    -- checked for the previous content.
    local partial_dir = root .. "/partial"
    reopened:put_book("b4", { bookId = "b4", title = "Partial", chapter_uid = 1, cache_dir = partial_dir })
    expect(reopened:get_book_dirs().b4 == partial_dir, "existing book not indexed")
    assert(os.remove(partial_dir .. "/reading_state.json"))
    assert(sh_ok("mkdir -p '" .. partial_dir .. "/reading_state.json/keep'"))
    ok, err = pcall(reopened.put_book, reopened, "b4",
        { bookId = "b4", title = "Partial", chapter_uid = 2, cache_dir = partial_dir })
    expect(not ok and tostring(err):find("Could not save book data", 1, true),
        "failed reading_state.json write of an existing book was not reported")
    expect(reopened:get_book_dirs().b4 == partial_dir, "failed write changed the index entry")
    expect(not exists(partial_dir .. "/reading_state.json.tmp"),
        "temporary file left after a failed reading_state.json write")
    expect(is_dir(partial_dir .. "/reading_state.json/keep"), "failed write damaged the existing entry")

    -- The same failure while moving the book to another directory must not
    -- redirect the index entry to the half-written directory.
    local moved_dir = root .. "/moved"
    assert(sh_ok("mkdir -p '" .. moved_dir .. "/reading_state.json/keep'"))
    ok, err = pcall(reopened.put_book, reopened, "b4",
        { bookId = "b4", title = "Moved", chapter_uid = 3, cache_dir = moved_dir })
    expect(not ok and tostring(err):find("Could not save book data", 1, true),
        "failed reading_state.json write in the new directory was not reported")
    expect(reopened:get_book_dirs().b4 == partial_dir, "failed write redirected the index entry")

    -- ── delete_book only drops the index entry and persists on flush ───────────
    reopened:delete_book("missing") -- no-op
    reopened:delete_book("b1")
    expect(reopened:get_book("b1") == nil, "deleted book still readable")
    reopened:flush()
    local third = Settings:new()
    expect(third:get_book("b1") == nil, "book deletion not persisted")
    expect(read_file(book_dir .. "/metadata.json"), "delete_book must not remove downloaded files")
    expect(third:get("api_key") == "key-1", "credentials lost across reopen")
end

local spec_ok, spec_err = xpcall(run_spec, debug.traceback)
restore_package_state()
os.execute("rm -rf '" .. root .. "'")
if not spec_ok then error(spec_err, 0) end
print(("settings_book_store_reopen_spec: %d checks"):format(checks))
