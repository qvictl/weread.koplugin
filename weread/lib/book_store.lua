local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local logger = require("weread.lib.logger")

local BookStore = {}

local reading_fields = {
    app_id = true,
    chapter_idx = true,
    chapter_offset = true,
    chapter_uid = true,
    last_local_position = true,
    last_pull_at = true,
    last_remote_position = true,
    last_sync_error = true,
    last_upload_at = true,
    last_uploaded_position = true,
    pclts = true,
    pending_upload_position = true,
    pending_upload_reason = true,
    progress = true,
    psvts = true,
    read_context_updated_at = true,
    read_session_entered_at = true,
    read_session_id = true,
    reader_url = true,
    summary = true,
    token = true,
    verified_at = true,
    verified_source = true,
}

local article_fields = {
    mp_articles = true,
    mp_articles_time = true,
}

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "weread"
end

local function dirname(path)
    if type(path) == "string" then
        return path:match("^(.*)/[^/]+$")
    end
end

local function resolved_dir(settings, book_id, book)
    if type(book) == "table" and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local dir = type(book) == "table"
        and dirname(book.cached_full_book or book.cached_file) or nil
    if not dir and type(book) == "table" and type(book.cached_chapters) == "table" then
        for _uid, path in pairs(book.cached_chapters) do
            dir = dirname(path)
            if dir then break end
        end
    end
    return dir or (settings.cache_dir .. "/" .. basename_safe(book_id))
end

local function encode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(value)
    end
    return json:encode(value)
end

local function decode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(value)
    end
    return json:decode(value)
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function decode_table(content)
    if type(content) ~= "string" or content == "" then return nil end
    local ok, value = pcall(decode, content)
    return ok and type(value) == "table" and value or nil
end

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = deepcopy(item) end
    return copy
end

-- KOReader provides lfs and the fsync helpers. Plain LuaJIT specs do not, so
-- every use below degrades to the portable behaviour (no stat cache, no fsync).
local function load_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and type(lfs) == "table" then return lfs end
    ok, lfs = pcall(require, "lfs")
    if ok and type(lfs) == "table" then return lfs end
    return nil
end
local lfs = load_lfs()
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil or type(ffiutil) ~= "table" then ffiutil = nil end

local function stat(path)
    if not lfs then return nil end
    local attributes = lfs.attributes(path)
    if type(attributes) == "table" and attributes.mode == "file" then
        return attributes
    end
    return nil
end

local function make_path(path)
    if not lfs then
        -- Only reachable outside KOReader (plain LuaJIT specs).
        os.execute("mkdir -p '" .. tostring(path):gsub("'", "'\\''") .. "'")
        return true
    end
    if lfs.attributes(path, "mode") == "directory" then return true end
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    for component in path:gmatch("[^/]+") do
        prefix = prefix .. component .. "/"
        if not lfs.attributes(prefix, "mode") then
            local ok, err = lfs.mkdir(prefix)
            if not ok and lfs.attributes(prefix, "mode") ~= "directory" then
                return nil, err
            end
        end
    end
    return true
end

local function fsync_file(file)
    if ffiutil and ffiutil.fsyncOpenedFile then
        pcall(ffiutil.fsyncOpenedFile, file)
    else
        file:flush()
    end
end

local function fsync_dir(path)
    if ffiutil and ffiutil.fsyncDirectory then
        pcall(ffiutil.fsyncDirectory, path)
    end
end

-- Per-Settings cache of the JSON files this process last read or wrote:
-- path -> { content, size, mtime, value }. A size/mtime mismatch (another
-- process wrote the file) or a missing stat forces a re-read, so the cache
-- only skips I/O for files we have already seen in their current state.
local function file_cache(settings)
    if type(settings) ~= "table" or not lfs then return nil end
    local cache = rawget(settings, "_book_file_cache")
    if not cache then
        cache = {}
        rawset(settings, "_book_file_cache", cache)
    end
    return cache
end

local function cached_entry(cache, path, attributes)
    local entry = cache and cache[path]
    if entry and attributes and entry.size == attributes.size
        and entry.mtime == attributes.modification then
        return entry
    end
    return nil
end

local function remember(cache, path, content, value)
    if not cache then return end
    local attributes = stat(path)
    if attributes then
        cache[path] = {
            content = content,
            value = value,
            size = attributes.size,
            mtime = attributes.modification,
        }
    else
        cache[path] = nil
    end
end

-- Returns a decoded table owned by the cache; callers must copy before
-- mutating. A missing, empty or corrupt file falls back to the ".bak" copy
-- kept by write_json, which covers hard reboots in the middle of a rename on
-- vfat (where rename-over is not atomic).
local function read_json(cache, path)
    local attributes = stat(path)
    local entry = cached_entry(cache, path, attributes)
    if entry then
        if entry.value == nil then entry.value = decode_table(entry.content) end
        if entry.value then return entry.value end
    end
    -- Without lfs (plain specs) there is no stat: always try the main file.
    if (attributes == nil and lfs == nil) or (attributes and (attributes.size or 0) > 0) then
        local content = read_file(path)
        local value = decode_table(content)
        if value then
            remember(cache, path, content, value)
            return value
        end
        if content and content ~= "" then
            logger.warn("book store file is corrupt, trying backup:", path)
        end
    end
    local backup = path .. ".bak"
    if lfs and not stat(backup) then return nil end
    local value = decode_table(read_file(backup))
    if value then
        logger.warn("book store file restored from backup:", path)
    end
    return value
end

local function remove_json(cache, path)
    for _i, candidate in ipairs({ path, path .. ".bak", path .. ".tmp" }) do
        if not lfs or stat(candidate) then os.remove(candidate) end
    end
    if cache then cache[path] = nil end
end

-- Durable replace: write <path>.tmp, fsync it, keep the previous good file as
-- <path>.bak, then move the new file into place and fsync the directory. On
-- vfat a crash can leave <path> missing, never half-written; read_json then
-- falls back to <path>.bak.
local function write_json(cache, path, value)
    local ok, content = pcall(encode, value)
    if not ok then return false, content end
    local attributes = stat(path)
    local entry = cached_entry(cache, path, attributes)
    local current
    if entry then
        current = entry.content
    elseif attributes or not lfs then
        current = read_file(path)
    end
    -- Byte compare; encoder key order can vary, which only costs an extra write.
    if current == content then
        if not entry then remember(cache, path, content, nil) end
        return true
    end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local write_ok, write_err = file:write(content)
    if write_ok then fsync_file(file) end
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err
    end
    -- Only rotate a file that still decodes: never replace a good backup with
    -- a corrupt leftover from an earlier crash.
    if current and current ~= "" and (entry or decode_table(current)) then
        os.remove(path .. ".bak")
        os.rename(path, path .. ".bak")
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        if cache then cache[path] = nil end
        return false, rename_err
    end
    fsync_dir(path)
    remember(cache, path, content, nil)
    return true
end

local function merge(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
end

local function has_values(value)
    return next(value) ~= nil
end

BookStore.resolved_dir = resolved_dir

-- Preserve the UI's existing cache while a one-off import touches many books.
-- load() returns private copies; releasing these entries cannot discard edits
-- held by callers. A previously unparsed entry keeps its original JSON bytes.
local weak_cache_identity = { __mode = "v" }

function BookStore.cache_mark(settings)
    local mark = {}
    for path, entry in pairs(rawget(settings, "_book_file_cache") or {}) do
        mark[path] = setmetatable({ entry = entry, had_value = entry.value ~= nil }, weak_cache_identity)
    end
    return mark
end

function BookStore.release_cache_since(settings, mark)
    for path, entry in pairs(rawget(settings, "_book_file_cache") or {}) do
        local previous = mark[path]
        if not previous then
            settings._book_file_cache[path] = nil
        elseif previous.entry == entry and not previous.had_value then
            entry.value = nil
        end
    end
end

function BookStore.load(settings, book_id, index)
    local cache = file_cache(settings)
    local book = {}
    merge(book, index)
    local dir = resolved_dir(settings, book_id, index)
    -- Cached tables are shared; hand callers private copies they can mutate.
    merge(book, deepcopy(read_json(cache, dir .. "/metadata.json")))
    merge(book, deepcopy(read_json(cache, dir .. "/reading_state.json")))
    merge(book, deepcopy(read_json(cache, dir .. "/articles.json")))
    book.book_id = book.book_id or book.bookId or tostring(book_id)
    book.cache_dir = dir
    return book
end

function BookStore.save(settings, book_id, book)
    local cache = file_cache(settings)
    book = type(book) == "table" and book or {}
    local dir = resolved_dir(settings, book_id, book)

    local metadata = { book_id = book.book_id or book.bookId or tostring(book_id) }
    local reading_state = {}
    local articles = {}
    for key, value in pairs(book) do
        if article_fields[key] then
            articles[key] = value
        elseif reading_fields[key] then
            reading_state[key] = value
        elseif key ~= "chapters" and key ~= "cache_dir" and key ~= "bookId" then
            metadata[key] = value
        end
    end

    -- Only create the directory when the first write fails because it is
    -- missing; util.makePath-style lfs calls never spawn a shell.
    local ok, err = write_json(cache, dir .. "/metadata.json", metadata)
    if not ok then
        make_path(dir)
        ok, err = write_json(cache, dir .. "/metadata.json", metadata)
    end
    if not ok then return false, err end
    if has_values(reading_state) then
        ok, err = write_json(cache, dir .. "/reading_state.json", reading_state)
        if not ok then return false, err end
    else
        remove_json(cache, dir .. "/reading_state.json")
    end
    if has_values(articles) then
        ok, err = write_json(cache, dir .. "/articles.json", articles)
        if not ok then return false, err end
    else
        remove_json(cache, dir .. "/articles.json")
    end
    return true, { cache_dir = dir }
end

function BookStore.is_minimal_index(books)
    for _book_id, record in pairs(books or {}) do
        if type(record) ~= "table" then return false end
        for key in pairs(record) do
            if key ~= "cache_dir" then return false end
        end
    end
    return true
end

return BookStore
