-- @title Resource archive failure removes partial images and can be retried
-- @timeout 30
-- Real filesystem and Content's streaming TAR reader, with a synthetic
-- archive supplied at the download boundary. Other chapters' images survive.
return function(H)
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
            local function entry(name, data)
                local header = name .. string.rep("\0", 100 - #name) .. string.rep("\0", 24)
                    .. string.format("%011o\0", #data) .. string.rep("\0", 20) .. "0"
                    .. string.rep("\0", 355)
                return header .. data .. string.rep("\0", (512 - #data % 512) % 512)
            end
            local complete = entry("first/existing.png", png .. "complete")
            local partial = entry("second/existing.png", png .. string.rep("x", 128 * 1024))
            local bytes = complete .. partial:sub(1, 512 + 66000)
            local client = { download_to_file = function(_self, _url, path)
                local file = assert(io.open(path, "wb"))
                assert(file:write(bytes))
                assert(file:close())
            end }
            local keep = assert(io.open(workspace.asset_dir .. "/existing.png", "wb"))
            keep:write(png .. "existing")
            keep:close()
            local names = { ["existing.png"] = true }
            local chapter = { chapterUid = 1, tar = "https://synthetic.invalid/resources.tar" }
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
            bytes = complete .. partial .. string.rep("\0", 1024)
            local assets = Content.download_chapter_assets_to_files(
                client, { book_id = "synthetic" }, chapter, names, workspace)
            H.equal(#assets, 2, "retry extracts both images")
            H.equal(assets[1].href, "images/existing-2.png", "retry reuses complete image name")
            H.equal(assets[2].href, "images/existing-3.png", "retry reuses partial image name")
            H.equal(lfs.attributes(assets[2].path, "size"), #png + 128 * 1024, "retried image is complete")

            local chunks = {}
            for i = 1, 512 do
                chunks[i] = entry("directory-" .. i .. "/existing.png", png .. tostring(i))
            end
            bytes = table.concat(chunks) .. string.rep("\0", 1024)
            -- Match the serialization boundary between actual chapter workers.
            local buffer = require("string.buffer")
            names = buffer.decode(buffer.encode(names))
            local started = os.clock()
            local many = Content.download_chapter_assets_to_files(
                client, { book_id = "synthetic" }, chapter, names, workspace)
            H.metric("colliding_asset_extract_cpu_ms", (os.clock() - started) * 1000)
            H.equal(#many, 512, "bulk chapter retains every colliding image")
            for i, asset in ipairs(many) do
                H.equal(asset.href, "images/existing-" .. (i + 3) .. ".png", "stable image suffix " .. i)
                local image = assert(io.open(asset.path, "rb"))
                local content = image:read("*a")
                image:close()
                H.equal(content, png .. tostring(i), "distinct image bytes " .. i)
            end
            H.equal(lfs.attributes(workspace.asset_dir .. "/existing.png", "size"), #png + #"existing",
                "bulk extraction preserves the previous chapter's image")
        end)
    end)
end
