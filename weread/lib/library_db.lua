-- SQLite-backed offline index for shelf entries, book details, and catalogs.
-- Downloaded EPUB/HTML files remain in the ordinary cache directory; this
-- database only stores small, queryable metadata needed to browse offline.

local logger = require("weread.lib.logger")
local Crypto = require("weread.lib.crypto")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local LibraryDB = {}
LibraryDB.__index = LibraryDB

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    return ok and SQ3 or nil
end

local function encode(value)
    if not ok_json then return nil, "JSON module is not available" end
    local ok, result = pcall(function()
        return json.encode and json.encode(value) or json:encode(value)
    end)
    if ok then return result, nil end
    return nil, result
end

local function decode(value)
    if type(value) ~= "string" or value == "" or not ok_json then return nil end
    local ok, result = pcall(function()
        return json.decode and json.decode(value) or json:decode(value)
    end)
    return ok and type(result) == "table" and result or nil
end

local function close_statement(stmt)
    if stmt then pcall(function() stmt:close() end) end
end

local function close_db(db)
    if db then pcall(function() db:close() end) end
end

local ffi_getpid
local function current_pid()
    if ffi_getpid == nil then
        ffi_getpid = false
        local ok, ffi = pcall(require, "ffi")
        if ok then
            -- KOReader usually declares getpid already; a redefinition error
            -- is harmless as long as the symbol resolves.
            pcall(ffi.cdef, "int getpid(void);")
            if pcall(function() return ffi.C.getpid() end) then
                ffi_getpid = function() return tonumber(ffi.C.getpid()) end
            end
        end
    end
    return ffi_getpid and ffi_getpid() or nil
end

-- One connection per process and database, shared by every LibraryDB
-- instance (the plugin is instantiated again for each FileManager/Reader).
-- Opening per call re-ran the PRAGMAs and the whole schema, and closing the
-- last WAL connection checkpointed and fsynced the database every time.
-- The owning pid is recorded because background workers fork the UI
-- process: a child must neither use nor close the parent's handle (SQLite
-- connections must not cross fork), it opens its own instead.
local shared = { db = nil, path = nil, pid = nil }
local schema_ready = {}
local inherited = {}

function LibraryDB:new(settings)
    local data_dir = settings.data_dir or settings.cache_dir or "."
    return setmetatable({
        settings = settings,
        data_dir = data_dir,
    }, self)
end

-- The hash keeps the user VID out of filenames while giving each login a
-- stable database that can be reused when the user switches back.
function LibraryDB:accountKey()
    local account = self.settings:get("account", {})
    local user_vid = type(account) == "table" and account.user_vid or nil
    if user_vid == nil or tostring(user_vid) == "" then return nil end
    return string.sub(Crypto.sha256_hex("weread-library:" .. tostring(user_vid)), 1, 20)
end

function LibraryDB:databasePath()
    local account_key = self:accountKey()
    if not account_key then return nil end
    return self.data_dir .. "/library-" .. account_key .. ".db"
end

LibraryDB._getpid = current_pid

local function init_schema(db)
    db:exec("PRAGMA journal_mode=WAL")
    db:exec("PRAGMA synchronous=NORMAL")
    db:exec([[
        CREATE TABLE IF NOT EXISTS books (
            book_id           TEXT PRIMARY KEY,
            kind              TEXT NOT NULL DEFAULT 'book',
            payload           TEXT NOT NULL,
            on_shelf          INTEGER NOT NULL DEFAULT 0,
            shelf_position    INTEGER,
            shelf_updated_at  INTEGER,
            detail_updated_at INTEGER,
            detail_payload    TEXT
        ) WITHOUT ROWID
    ]])
    db:exec([[
        CREATE TABLE IF NOT EXISTS chapters (
            book_id      TEXT NOT NULL,
            chapter_uid  TEXT NOT NULL,
            position     INTEGER NOT NULL,
            payload      TEXT NOT NULL,
            updated_at   INTEGER NOT NULL,
            PRIMARY KEY (book_id, chapter_uid)
        ) WITHOUT ROWID
    ]])
    db:exec([[
        CREATE TABLE IF NOT EXISTS shelf_state (
            name TEXT PRIMARY KEY,
            payload TEXT NOT NULL
        ) WITHOUT ROWID
    ]])
    -- Adds the richer detail snapshot for databases created by an early
    -- development build. Duplicate-column errors are intentionally ignored.
    pcall(function() db:exec("ALTER TABLE books ADD COLUMN detail_payload TEXT") end)
    db:exec("CREATE INDEX IF NOT EXISTS chapters_position ON chapters(book_id, position)")
end

-- Close the shared connection of this process (account switch, teardown,
-- or after an error left it in an unknown state).
function LibraryDB:close()
    if shared.db and shared.pid == LibraryDB._getpid() then
        close_db(shared.db)
    end
    shared.db, shared.path, shared.pid = nil, nil, nil
end

-- Finish a database operation: keep the shared connection after success,
-- drop it after a failure so the next call starts from a fresh handle.
function LibraryDB:_done(ok)
    if ok then return end
    -- Re-check the schema on the next open as well: the failure may come
    -- from a database file that was removed or replaced underneath us.
    if shared.path then schema_ready[shared.path] = nil end
    self:close()
end

function LibraryDB:open()
    local path = self:databasePath()
    if not path then
        logger.info("library_db skipped without an identified account")
        return nil
    end
    local pid = LibraryDB._getpid()
    if shared.db and shared.path == path and shared.pid == pid then
        return shared.db
    end
    if shared.db and shared.pid ~= pid then
        -- Inherited across fork: abandon it without closing. Keep it
        -- referenced so no garbage-collection finalizer closes it here.
        inherited[#inherited + 1] = shared.db
        shared.db, shared.path, shared.pid = nil, nil, nil
        schema_ready = {}
    end
    self:close()
    local SQ3 = getSQ3()
    if not SQ3 then
        logger.warn("library_db lua-ljsqlite3 unavailable")
        return nil
    end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then
        logger.warn("library_db open failed:", path, db)
        return nil
    end
    if not schema_ready[path] then
        local schema_ok, schema_err = pcall(init_schema, db)
        if not schema_ok then
            logger.warn("library_db schema init failed:", schema_err)
            close_db(db)
            return nil
        end
        schema_ready[path] = true
    end
    shared.db, shared.path, shared.pid = db, path, pid
    return db
end

function LibraryDB:cacheShelf(books, archives)
    local db = self:open()
    if not db or type(books) ~= "table" then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        db:exec("UPDATE books SET on_shelf=0, shelf_position=NULL")
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, on_shelf, shelf_position, shelf_updated_at)
            VALUES (?, ?, ?, 1, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                payload=excluded.payload,
                on_shelf=1,
                shelf_position=excluded.shelf_position,
                shelf_updated_at=excluded.shelf_updated_at
        ]])
        local now = os.time()
        for position, book in ipairs(books) do
            local book_id = book.book_id or book.bookId
            local payload, encode_err = encode(book)
            if book_id and payload then
                local kind = tostring(book_id):match("^MP_WXS_") and "mp" or "book"
                stmt:reset():bind(tostring(book_id), kind, payload, position, now):step()
            elseif encode_err then
                error(encode_err)
            end
        end
        close_statement(stmt)
        stmt = nil
        -- Keep groups and their membership in the same snapshot as the books.
        if archives ~= nil then
            local payload, encode_err = encode(archives)
            if not payload then error(encode_err) end
            stmt = db:prepare([[
                INSERT INTO shelf_state (name, payload) VALUES ('archives', ?)
                ON CONFLICT(name) DO UPDATE SET payload=excluded.payload
            ]])
            stmt:reset():bind(payload):step()
            close_statement(stmt)
            stmt = nil
        end
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    self:_done(ok)
    if not ok then logger.warn("library_db shelf write failed:", err) end
    return ok
end

function LibraryDB:getShelfArchives()
    local db = self:open()
    if not db then return nil end
    local stmt, archives
    local ok = pcall(function()
        stmt = db:prepare("SELECT payload FROM shelf_state WHERE name='archives'")
        local row = stmt:reset():step()
        archives = row and decode(row[1]) or nil
    end)
    close_statement(stmt)
    self:_done(ok)
    return ok and archives or nil
end

function LibraryDB:getShelf()
    local db = self:open()
    if not db then return nil end
    local books = {}
    local stmt
    -- The step loop runs inside pcall as well: a stepping error used to
    -- escape here and leak the statement and the connection.
    local ok, err = pcall(function()
        stmt = db:prepare([[
            SELECT payload FROM books
            WHERE on_shelf=1
            ORDER BY shelf_position, book_id
        ]])
        local row = stmt:reset():step()
        while row do
            local book = decode(row[1])
            if book then books[#books + 1] = book end
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    self:_done(ok)
    if not ok then logger.warn("library_db shelf read failed:", err) end
    return ok and books or nil
end

-- The catalog lives in the chapters table. Embedding it in the book payload
-- re-encoded every chapter on each book write and decoded it on each read.
local function book_payload(book)
    if book.chapters == nil then return encode(book) end
    local copy = {}
    for key, value in pairs(book) do
        if key ~= "chapters" then copy[key] = value end
    end
    return encode(copy)
end

function LibraryDB:putBook(book)
    if type(book) ~= "table" then return false end
    local book_id = book.book_id or book.bookId
    local payload = book_payload(book)
    if not book_id or not payload then return false end
    local db = self:open()
    if not db then return false end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, detail_payload, detail_updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                detail_payload=excluded.detail_payload,
                detail_updated_at=excluded.detail_updated_at
        ]])
        local kind = tostring(book_id):match("^MP_WXS_") and "mp" or "book"
        stmt:reset():bind(tostring(book_id), kind, payload, payload, os.time()):step()
    end)
    close_statement(stmt)
    self:_done(ok)
    if not ok then logger.warn("library_db book write failed:", err) end
    return ok
end

function LibraryDB:getBook(book_id)
    if not book_id then return nil end
    local db = self:open()
    if not db then return nil end
    local stmt
    local result
    local ok = pcall(function()
        stmt = db:prepare("SELECT COALESCE(detail_payload, payload) FROM books WHERE book_id=?")
        local row = stmt:reset():bind(tostring(book_id)):step()
        result = row and decode(row[1]) or nil
    end)
    close_statement(stmt)
    self:_done(ok)
    return ok and result or nil
end

function LibraryDB:putChapters(book_id, chapters)
    if not book_id or type(chapters) ~= "table" then return false end
    local db = self:open()
    if not db then return false end
    local transaction_open = false
    local stmt, delete_stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        delete_stmt = db:prepare("DELETE FROM chapters WHERE book_id=?")
        delete_stmt:reset():bind(tostring(book_id)):step()
        close_statement(delete_stmt)
        delete_stmt = nil
        stmt = db:prepare([[
            INSERT INTO chapters (book_id, chapter_uid, position, payload, updated_at)
            VALUES (?, ?, ?, ?, ?)
        ]])
        local now = os.time()
        for position, chapter in ipairs(chapters) do
            local uid = chapter.chapterUid or chapter.chapterId or position
            local payload, encode_err = encode(chapter)
            if payload then
                stmt:reset():bind(tostring(book_id), tostring(uid), position, payload, now):step()
            else
                error(encode_err)
            end
        end
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(delete_stmt)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    self:_done(ok)
    if not ok then logger.warn("library_db catalog write failed:", err) end
    return ok
end

-- Number of cached catalog entries, without decoding them.
function LibraryDB:countChapters(book_id)
    if not book_id then return nil end
    local db = self:open()
    if not db then return nil end
    local stmt, count
    local ok = pcall(function()
        stmt = db:prepare("SELECT COUNT(*) FROM chapters WHERE book_id=?")
        local row = stmt:reset():bind(tostring(book_id)):step()
        count = row and tonumber(row[1]) or 0
    end)
    close_statement(stmt)
    self:_done(ok)
    return ok and count or nil
end

function LibraryDB:getChapters(book_id)
    if not book_id then return nil end
    local db = self:open()
    if not db then return nil end
    local chapters = {}
    local stmt
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT payload FROM chapters WHERE book_id=? ORDER BY position
        ]])
        local row = stmt:reset():bind(tostring(book_id)):step()
        while row do
            local chapter = decode(row[1])
            if chapter then chapters[#chapters + 1] = chapter end
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    self:_done(ok)
    return ok and #chapters > 0 and chapters or nil
end

return LibraryDB
