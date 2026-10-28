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
            local book = { book_id = "literal", title = "Synthetic book", author = "Synthetic author" }
            local chapter = { chapterUid = 1, chapterIdx = 1, title = "Synthetic chapter" }
            local ok, err = Content.save_catalog_cache(H.runtime().client, settings, book, { chapter })
            H.check(ok, "catalog saves with literal directory characters", tostring(err))
            H.equal(book.cache_dir, settings.cache_dir .. "/literal", "book pins the exact directory")
            H.equal(lfs.attributes(book.cache_dir .. "/catalog.json", "mode"), "file", "catalog on disk")
            local single = Content.save_chapter_epub(settings, book, chapter, "<p>synthetic chapter</p>")
            local full = Content.save_book_epub(settings, book,
                { chapter }, { ["1"] = "<p>synthetic chapter</p>" }, "full")
            local article = Content.save_mp_article_html(settings, book,
                { title = "Synthetic article" }, "<p>synthetic article</p>")
            for _, path in ipairs({ single, full, article }) do
                H.check(path:sub(1, #book.cache_dir + 1) == book.cache_dir .. "/",
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
end
