-- Publish one MP article after its worker has finished. Versioned image
-- directories keep the previous HTML and its resources intact until commit.
local Content = require("weread.lib.content")
local Crypto = require("weread.lib.crypto")
local FFIUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local M = {}

function M.prepare(settings, book, article)
    local book_id = book.book_id or book.bookId
    local target_dir = Content.book_resolved_dir(settings, book_id, book)
    local target_book = { book_id = book_id, cache_dir = target_dir }
    local key = tostring(article.reviewId or "")
    if key == "" then key = tostring(article.originalId or "") end
    if key == "" then key = tostring(article.sourceUrl or article.title or "") end
    local prefix = ".weread-mp-" .. Crypto.sha256_hex(key):sub(1, 20) .. "-assets-"
    local workspace = Content.create_download_workspace(settings, target_book)
    local name = prefix .. assert(workspace.path:match("(%d+%-%d+)$"))
    local stage_book = { book_id = book_id, cache_dir = workspace.path }
    return {
        workspace = workspace, stage_book = stage_book, target_dir = target_dir,
        stage_html = Content.mp_article_path(settings, stage_book, article),
        target_html = Content.mp_article_path(settings, target_book, article),
        backup_html = workspace.path .. "/.previous-html",
        asset_prefix = prefix, asset_name = name,
        stage_assets = workspace.path .. "/" .. name, target_assets = target_dir .. "/" .. name,
    }
end

function M.cleanup(download)
    if download.keep_workspace then return nil, "article recovery files retained" end
    return Content.cleanup_download_workspace(download.workspace)
end

function M.commit(download, persist)
    local moved_assets, backed_up, published = false, false, false
    local function move(from, to)
        local ok, err = os.rename(from, to)
        if not ok then error(err or "could not publish article file", 0) end
    end
    local ok, err = pcall(function()
        assert(lfs.attributes(download.stage_html, "mode") == "file", "article worker returned no HTML")
        if lfs.attributes(download.stage_assets, "mode") == "directory" then
            assert(not lfs.symlinkattributes(download.target_assets), "article image version already exists")
            move(download.stage_assets, download.target_assets)
            moved_assets = true
        end
        if lfs.attributes(download.target_html, "mode") then
            move(download.target_html, download.backup_html)
            backed_up = true
        end
        move(download.stage_html, download.target_html)
        published = true
        if persist then persist(download.target_html, download.target_dir) end
    end)
    if not ok then
        local restored = true
        if published then
            -- Move the new HTML aside before putting its predecessor back.
            restored = os.rename(download.target_html, download.stage_html) and true or false
        end
        if backed_up then restored = os.rename(download.backup_html, download.target_html) and true or false end
        if restored and moved_assets then
            local called, removed, remove_err = pcall(FFIUtil.purgeDir, download.target_assets)
            if not called or not removed then
                err = tostring(err) .. "; image cleanup failed: " .. tostring(remove_err or removed)
            end
        end
        download.keep_workspace = download.keep_workspace or not restored
        if download.keep_workspace then
            err = tostring(err) .. "; rollback incomplete, recovery files retained at " .. download.workspace.path
        end
        return nil, tostring(err), download.keep_workspace
    end
    -- Older HTML files may still reference any previous image version. Keep
    -- those directories until the user clears the whole book cache.
    return download.target_html
end

return M
