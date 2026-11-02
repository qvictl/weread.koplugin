-- @title Catalog, EPUB and article output preserve literal cache directory names
-- @timeout 30
-- Uses ordinary legal directory characters: apostrophe, spaces and a literal
-- dollar-prefixed name. No account requests or private book data are used.
return function(H)
    H.step("save all output formats in the exact selected directory", function()
        H.wait_until("plugin attached", function() return H.plugin() end, 20)
        H.call(function()
            local Content = require("weread.lib.content")
            local lfs = require("libs/libkoreader-lfs")
            local settings = { cache_dir = H.env.evidence .. "/reader's $WEREAD_LITERAL_DIRECTORY with spaces" }
            local book = { book_id = "literal-catalog", title = "Synthetic book", author = "Synthetic author" }
            local chapter = { chapterUid = 1, chapterIdx = 1, title = "Synthetic chapter" }
            local ok, err = Content.save_catalog_cache(H.runtime().client, settings, book, { chapter })
            H.check(ok, "catalog saves with literal directory characters", tostring(err))
            H.equal(book.cache_dir, settings.cache_dir .. "/literal-catalog", "book pins the exact directory")
            H.equal(lfs.attributes(book.cache_dir .. "/catalog.json", "mode"), "file", "catalog on disk")
            local single_book = { book_id = "literal-single", title = "Synthetic single" }
            local full_book = { book_id = "literal-full", title = "Synthetic full" }
            local article_book = { book_id = "literal-article" }
            local single = Content.save_chapter_epub(settings, single_book, chapter, "<p>synthetic chapter</p>")
            local full = Content.save_book_epub(settings, full_book,
                { chapter }, { ["1"] = "<p>synthetic chapter</p>" }, "full")
            local article = Content.save_mp_article_html(settings, article_book,
                { title = "Synthetic article" }, "<p>synthetic article</p>")
            for _, output in ipairs({ { single, single_book }, { full, full_book }, { article, article_book } }) do
                local path, record = output[1], output[2]
                local expected_dir = settings.cache_dir .. "/" .. record.book_id
                H.equal(record.cache_dir, expected_dir, "output pins its own literal directory")
                H.equal(lfs.attributes(expected_dir, "mode"), "directory", "output creates its own directory")
                H.check(path:sub(1, #expected_dir + 1) == expected_dir .. "/",
                    "output stays in literal book directory", path)
                H.equal(lfs.attributes(path, "mode"), "file", "output exists")
                H.equal(lfs.attributes(path .. ".part"), nil, "successful save leaves no temporary file")
            end
            local archive = require("ffi/archiver").Reader:new()
            H.check(archive:open(full), "real libarchive opens the literal-path EPUB")
            for _ in archive:iterate() do end
            local chapter_text = archive:extractToMemory("OEBPS/text/chapter-001.xhtml")
            archive:close()
            H.check(chapter_text and chapter_text:find("synthetic chapter", 1, true),
                "EPUB chapter content survives literal-path packaging")
        end)
    end)
    H.step("download directory validation preserves existing files", function()
        H.call(function()
            local Cache = require("weread.ui.cache")
            local util = require("util")
            local lfs = require("libs/libkoreader-lfs")
            local directory = H.env.evidence .. "/reader's $WEREAD_PROBE_DIRECTORY with spaces"
            H.check(util.makePath(directory), "create synthetic selected folder")
            local sentinel_path = directory .. "/.weread_write_test"
            local sentinel = assert(io.open(sentinel_path, "wb"))
            sentinel:write("synthetic existing user file")
            sentinel:close()
            local first = assert(io.open(directory .. "/.weread_write_test.1", "wb"))
            first:write("occupied candidate")
            first:close()
            H.check(util.makePath(directory .. "/.weread_write_test.2"), "create existing candidate folder")
            local nested = assert(io.open(directory .. "/.weread_write_test.2/keep.txt", "wb"))
            nested:write("nested user data")
            nested:close()
            H.check(lfs.link(directory .. "/absent-target", directory .. "/.weread_write_test.3", true),
                "create synthetic dangling candidate link")
            H.check(Cache.validateDownloadDir({}, directory), "accept writable folder containing old probe name")
            local retained = io.open(sentinel_path, "rb")
            H.check(retained ~= nil, "validation does not delete an existing file")
            local bytes = retained:read("*a")
            retained:close()
            H.equal(bytes, "synthetic existing user file", "validation does not truncate an existing file")
            H.equal(lfs.attributes(directory, "mode"), "directory", "selected directory remains available")
            for _, expected in ipairs({ { "/.weread_write_test.1", "occupied candidate" },
                { "/.weread_write_test.2/keep.txt", "nested user data" } }) do
                local file = assert(io.open(directory .. expected[1], "rb"))
                H.equal(file:read("*a"), expected[2], "existing candidate data remains intact")
                file:close()
            end
            H.equal(lfs.symlinkattributes(directory .. "/.weread_write_test.3", "mode"), "link",
                "validation does not follow or remove the dangling candidate link")
            H.equal(lfs.attributes(directory .. "/absent-target"), nil, "validation does not create a link target")
            H.equal(lfs.attributes(directory .. "/.weread_write_test.4"), nil, "claimed probe directory is removed")
            H.check(Cache.validateDownloadDir({}, directory), "repeated validation preserves the same files")
        end)
    end)
end
