-- Per-book record access that works with both settings storage layouts.
--
-- Newer Settings objects expose per-book accessors (get_book, get_books,
-- put_book, delete_book) so one book can be read or written without loading
-- and re-saving every record. Older ones only offer get/set("books"), which
-- touch the whole collection. Feature-detect the accessors and fall back to
-- the collection calls, so callers never depend on which layout is present.

local BookRecords = {}

function BookRecords.get(settings, book_id)
    if book_id == nil then return nil end
    if type(settings.get_book) == "function" then
        return settings:get_book(book_id)
    end
    local books = settings:get("books", {}) or {}
    return books[book_id]
end

function BookRecords.all(settings)
    if type(settings.get_books) == "function" then
        return settings:get_books() or {}
    end
    return settings:get("books", {}) or {}
end

function BookRecords.put(settings, book_id, record)
    if book_id == nil then return end
    if type(settings.put_book) == "function" then
        return settings:put_book(book_id, record)
    end
    local books = settings:get("books", {}) or {}
    books[book_id] = record
    settings:set("books", books)
end

function BookRecords.delete(settings, book_id)
    if book_id == nil then return end
    if type(settings.delete_book) == "function" then
        return settings:delete_book(book_id)
    end
    local books = settings:get("books", {}) or {}
    if books[book_id] == nil then return end
    books[book_id] = nil
    settings:set("books", books)
end

-- Replace a set of records that were loaded together with BookRecords.all().
-- `books` is the full table after the caller's edits; ids missing from it are
-- deleted when `deleted_ids` lists them.
function BookRecords.put_many(settings, books, deleted_ids)
    if type(settings.put_book) ~= "function" then
        -- The collection call writes every record once; looping over put()
        -- would rewrite the whole collection once per book.
        settings:set("books", books)
        return
    end
    for book_id, record in pairs(books) do
        settings:put_book(book_id, record)
    end
    for _i, book_id in ipairs(deleted_ids or {}) do
        BookRecords.delete(settings, book_id)
    end
end

return BookRecords
