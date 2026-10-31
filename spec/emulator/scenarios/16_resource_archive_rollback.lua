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

            -- Python's standard USTAR writer splits these long source paths
            -- across the name and prefix fields. Exercise both real readers.
            chapter.tar = resource_url .. "ustar.tar"
            local streamed, stream_map = Content.download_chapter_assets_to_files(
                client, { book_id = "synthetic" }, chapter, {}, workspace)
            local memory, memory_map = Content.download_chapter_assets(
                client, { book_id = "synthetic" }, chapter, {})
            H.equal(#streamed, 3, "USTAR streaming retains all images")
            H.equal(#memory, 3, "USTAR in-memory parsing retains all images")
            for i, letter in ipairs({ "a", "b" }) do
                local html = '<img src="section-' .. string.rep(letter, 96) .. '/pic.png"/>'
                H.equal(Content.rewrite_image_sources(html, stream_map),
                    '<img src="../' .. streamed[i].href .. '"/>', "USTAR streaming source identity " .. i)
                H.equal(Content.rewrite_image_sources(html, memory_map),
                    '<img src="../' .. memory[i].href .. '"/>', "USTAR in-memory source identity " .. i)
                local image = assert(io.open(streamed[i].path, "rb"))
                local bytes = image:read("*a")
                image:close()
                H.equal(bytes, png .. letter, "USTAR streaming image bytes " .. i)
                H.equal(memory[i].data, bytes, "USTAR readers agree on bytes " .. i)
            end
            local spaced = '<img src="section-' .. string.rep("a", 96) .. '/pic.png "/>'
            H.equal(Content.rewrite_image_sources(spaced, stream_map),
                '<img src="../' .. streamed[3].href .. '"/>', "USTAR streaming retains name whitespace")
            H.equal(Content.rewrite_image_sources(spaced, memory_map),
                '<img src="../' .. memory[3].href .. '"/>', "USTAR in-memory parsing retains name whitespace")
            local image = assert(io.open(streamed[3].path, "rb"))
            local bytes = image:read("*a")
            image:close()
            H.equal(bytes, png .. "spaced-name", "USTAR spaced-name image bytes")
            H.equal(memory[3].data, bytes, "USTAR readers agree on spaced-name image bytes")
            for _, mapping in ipairs({ stream_map, memory_map }) do
                H.equal(Content.rewrite_image_sources('<img src="pic.png"/>', mapping),
                    '<img src="pic.png"/>', "USTAR prefixes do not claim a bare source path")
            end

            -- References are URI paths; the archive contains literal names.
            -- Fetch actual bytes through both readers, including names which
            -- would collide if decoded twice or treated as form data.
            chapter.tar = resource_url .. "uri.tar"
            local uri_streamed, uri_stream_map = Content.download_chapter_assets_to_files(
                client, { book_id = "synthetic" }, chapter, names, workspace)
            local uri_memory, uri_memory_map = Content.download_chapter_assets(
                client, { book_id = "synthetic" }, chapter, {})
            local refs = { "chapter%20one/pic.png", "chapter%20two/pic.png", "first/pic.png%20",
                "second/pic.png%20", "literal/pic.png%2520", "literal/pic.png%252520",
                "reserved/q%3F%23.png?ignored=1&amp;x=2#fragment", "utf8/%E6%8F%92%e5%9b%be.png",
                "plus/a+b.png", "percent/100%25.png", "amp/a%26b.png" }
            H.equal(#uri_streamed, #refs, "URI streaming retains all literal archive names")
            H.equal(#uri_memory, #refs, "URI memory retains all literal archive names")
            for i, ref in ipairs(refs) do
                local html = '<img src="' .. ref .. '"/>'
                H.equal(Content.rewrite_image_sources(html, uri_stream_map),
                    '<img src="../' .. uri_streamed[i].href .. '"/>', "URI streaming identity " .. i)
                H.equal(Content.rewrite_image_sources(html, uri_memory_map),
                    '<img src="../' .. uri_memory[i].href .. '"/>', "URI memory identity " .. i)
                local file = assert(io.open(uri_streamed[i].path, "rb"))
                local payload = file:read("*a")
                file:close()
                H.equal(payload, png .. tostring(i), "URI streaming image bytes " .. i)
                H.equal(uri_memory[i].data, payload, "URI readers agree on image bytes " .. i)
            end
            for _, mapping in ipairs({ uri_stream_map, uri_memory_map }) do
                for _, ref in ipairs({ "pic.png%20", "missing/pic.png%20", "literal/pic.png%20",
                    "plus%2Fa+b.png", "prefix%00/a+b.png" }) do
                    local html = '<img src="' .. ref .. '"/>'
                    H.equal(Content.rewrite_image_sources(html, mapping), html,
                        "ambiguous or invalid URI does not select unrelated data: " .. ref)
                end
            end
            local preserved = assert(io.open(workspace.asset_dir .. "/existing.png", "rb"))
            H.equal(preserved:read("*a"), png .. "existing", "URI extraction preserves previous chapter data")
            preserved:close()
        end)
    end)
end
