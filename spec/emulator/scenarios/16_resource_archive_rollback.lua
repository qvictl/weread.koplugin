-- @title Resource archive failure removes partial images and can be retried
-- @timeout 30
-- Real Client downloads from the local mock, filesystem and streaming TAR
-- reader. Other chapters' images survive failed extraction and retries;
-- colliding source paths keep pointing to their own image bytes.
return function(H)
    H.wait_until("weread plugin attached", H.plugin, 20)
    H.step("failed chapter resource extraction rolls back and retries cleanly", function()
        H.call(function()
            local Content = require("weread.lib.content")
            local lfs = require("libs/libkoreader-lfs")
            local util = require("util")
            local root = H.env.evidence .. "/resource-workspace"
            local workspace = { incoming_dir = root .. "/incoming", asset_dir = root .. "/assets" }
            assert(util.makePath(workspace.incoming_dir))
            assert(util.makePath(workspace.asset_dir))
            local png = "\137PNG\r\n\026\n"
            local client = H.runtime().client
            local resource_url = "https://weread.qq.com/mock/resource-archive/"
            local keep = assert(io.open(workspace.asset_dir .. "/existing.png", "wb"))
            keep:write(png .. "existing")
            keep:close()
            local names = { ["existing.png"] = true }
            local chapter = { chapterUid = 1, tar = resource_url .. "initial.tar" }
            local ok, err = pcall(Content.download_chapter_assets_to_files,
                client, { book_id = "synthetic" }, chapter, names, workspace)
            H.check(not ok and tostring(err):find("truncated TAR entry", 1, true), "truncation is reported")
            H.equal(lfs.attributes(workspace.asset_dir .. "/existing-2.png"), nil, "completed image rolled back")
            H.equal(lfs.attributes(workspace.asset_dir .. "/existing-3.png"), nil, "partial image rolled back")
            H.equal(lfs.attributes(workspace.incoming_dir .. "/chapter-1.tar"), nil, "incoming TAR removed")
            H.check(names["existing-2.png"] == nil and names["existing-3.png"] == nil,
                "failed attempt released its asset names")
            H.check(names["existing.png"] and lfs.attributes(workspace.asset_dir .. "/existing.png"),
                "previous chapter asset is preserved")
            chapter.tar = resource_url .. "retry.tar"
            local assets = Content.download_chapter_assets_to_files(
                client, { book_id = "synthetic" }, chapter, names, workspace)
            H.equal(#assets, 2, "retry extracts both images")
            H.equal(assets[1].href, "images/existing-2.png", "retry reuses complete image name")
            H.equal(assets[2].href, "images/existing-3.png", "retry reuses partial image name")
            H.equal(lfs.attributes(assets[2].path, "size"), #png + 128 * 1024, "retried image is complete")

            chapter.tar = resource_url .. "bulk.tar"
            -- Match the serialization boundary between actual chapter workers.
            local buffer = require("string.buffer")
            names = buffer.decode(buffer.encode(names))
            H.check(names.__next_asset_suffix and names.__next_asset_suffix["existing.png"] == 4,
                "actual worker serialization preserves the next suffix cursor")
            local started = os.clock()
            local many, source_map = Content.download_chapter_assets_to_files(
                client, { book_id = "synthetic" }, chapter, names, workspace)
            H.metric("colliding_asset_extract_cpu_ms", (os.clock() - started) * 1000)
            H.equal(#many, 512, "bulk chapter retains every colliding image")
            for i, asset in ipairs(many) do
                H.equal(asset.href, "images/existing-" .. (i + 3) .. ".png", "stable image suffix " .. i)
                local image = assert(io.open(asset.path, "rb"))
                local content = image:read("*a")
                image:close()
                H.equal(content, png .. tostring(i), "distinct image bytes " .. i)
                local html = '<img src="directory-' .. i .. '/existing.png"/>'
                H.equal(Content.rewrite_image_sources(html, source_map),
                    '<img src="../' .. asset.href .. '"/>', "source path selects its own image " .. i)
            end
            H.equal(Content.rewrite_image_sources('<img src="existing.png"/>', source_map),
                '<img src="existing.png"/>', "ambiguous basename is not silently redirected")
            H.equal(lfs.attributes(workspace.asset_dir .. "/existing.png", "size"), #png + #"existing",
                "bulk extraction preserves the previous chapter's image")
            chapter.tar = resource_url .. "cover.tar"
            local covers = Content.download_chapter_assets_to_files(
                client, { book_id = "synthetic" }, chapter, names, workspace)
            H.equal(covers[1].href, "images/Cover-jpg-2.png",
                "MIME extension mismatch cannot loop within the reserved cover prefix")
        end)
    end)
end
