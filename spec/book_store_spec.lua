package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local encoded_values = {}
local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = deepcopy(item) end
    return copy
end

local function canonical(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _i, key in ipairs(keys) do
        local item = value[key]
        if item == nil then item = value[tonumber(key)] end
        parts[#parts + 1] = key .. "=" .. canonical(item)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

package.preload["json"] = function()
    return {
        encode = function(value)
            local token = "json-fixture-" .. canonical(value)
            encoded_values[token] = deepcopy(value)
            return token
        end,
        decode = function(token)
            assert(encoded_values[token], "unknown JSON fixture token")
            return deepcopy(encoded_values[token])
        end,
    }
end

local BookStore = require("weread.lib.book_store")
local root = os.tmpname() .. "-weread-book-store"
os.remove(root)
local settings = { cache_dir = root }

local ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Fixture book",
    author = "Fixture author",
    progress = 37,
    chapter_uid = 9,
    mp_articles = { { title = "Fixture article" } },
    chapters = { { chapterUid = 9 } },
})
expect(ok == true, "split book save failed")
expect(index.cache_dir == root .. "/book_42",
    "book id was not sanitized for the cache directory")
expect(BookStore.is_minimal_index({ ["book/42"] = index }),
    "saved index was not minimal")
expect(not BookStore.is_minimal_index({
    ["book/42"] = { cache_dir = index.cache_dir, title = "legacy" },
}), "legacy inline metadata was accepted as a minimal index")

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

expect(exists(index.cache_dir .. "/metadata.json"),
    "metadata file was not written")
expect(exists(index.cache_dir .. "/reading_state.json"),
    "reading-state file was not written")
expect(exists(index.cache_dir .. "/articles.json"),
    "article file was not written")

local loaded = BookStore.load(settings, "book/42", index)
expect(loaded.title == "Fixture book" and loaded.author == "Fixture author",
    "metadata did not round-trip")
expect(loaded.progress == 37 and loaded.chapter_uid == 9,
    "reading state did not round-trip")
expect(loaded.mp_articles[1].title == "Fixture article",
    "article data did not round-trip")
expect(loaded.chapters == nil,
    "large chapter catalog should not be stored in the book record")
expect(loaded.cache_dir == index.cache_dir,
    "resolved cache directory did not round-trip")

local renames = 0
local real_rename = os.rename
os.rename = function(...) -- luacheck: ignore 122
    renames = renames + 1
    return real_rename(...)
end
ok = BookStore.save(settings, "book/42", loaded)
os.rename = real_rename -- luacheck: ignore 122
expect(ok == true, "unchanged save failed")
expect(renames == 0, "unchanged book data was rewritten")

ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Metadata only",
    cache_dir = index.cache_dir,
})
expect(ok == true, "metadata-only update failed")
expect(not exists(index.cache_dir .. "/reading_state.json")
    and not exists(index.cache_dir .. "/articles.json"),
    "stale split files were not removed")
loaded = BookStore.load(settings, "book/42", index)
expect(loaded.title == "Metadata only"
    and loaded.progress == nil and loaded.mp_articles == nil,
    "removed split state reappeared after reload")

-- A scan releases only newly warmed data. Existing parsed UI entries and
-- caller-owned unsaved changes remain intact.
local warm = { content = "kept", value = { title = "UI" } }
local cold = { content = "cold" }
settings._book_file_cache = { warm = warm, cold = cold }
local mark = BookStore.cache_mark(settings)
local private = BookStore.load(settings, "book/42", index)
private.title = "Unsaved UI edit"
cold.value = { cached_chapters = { ["1"] = "old path" } }
settings._book_file_cache.new = { content = "new" }
BookStore.release_cache_since(settings, mark)
expect(settings._book_file_cache.new == nil, "scan-only entries retained")
expect(settings._book_file_cache.warm == warm and warm.value.title == "UI", "existing UI cache changed")
expect(cold.value == nil and cold.content == "cold", "previously cold entry retained decoded paths")
expect(private.title == "Unsaved UI edit", "release discarded caller-owned changes")
expect(BookStore.load(settings, "book/42", index).title == "Metadata only", "release lost persisted data")

-- Marks must not extend the lifetime of old bytes/decoded payloads after
-- save replaces an existing parsed or unparsed file entry.
local parsed = { content = string.rep("old JSON", 1000), value = { cached_chapters = { "old path" } } }
local unparsed = { content = string.rep("cold JSON", 1000) }
local old_refs = setmetatable({ parsed, unparsed, parsed.value }, { __mode = "v" })
settings._book_file_cache = { parsed = parsed, unparsed = unparsed }
local rewrite_mark = BookStore.cache_mark(settings)
local replacement = { content = "new JSON", value = { title = "newly parsed after rewrite" } }
settings._book_file_cache.parsed, settings._book_file_cache.unparsed = replacement, replacement
parsed, unparsed = nil, nil
collectgarbage("collect")
expect(old_refs[1] == nil and old_refs[2] == nil and old_refs[3] == nil,
    "cache mark retained replaced entry payloads")
BookStore.release_cache_since(settings, rewrite_mark)
expect(replacement.value.title == "newly parsed after rewrite",
    "release confused a replacement with the original cold entry")

os.remove(index.cache_dir .. "/metadata.json")
os.remove(index.cache_dir)
os.remove(root)

print(("book_store_spec: %d checks"):format(checks))
