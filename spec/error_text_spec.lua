-- Errors shown to the user never carry a Lua source position such as
-- ".../weread/lib/content.lua:1699: ". Covers the display helper (defensive
-- stripping) and the content raise sites on the download path.
-- Run with: luajit spec/error_text_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function has_position(text)
    return tostring(text):find("%.lua:%d+:") ~= nil
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["ui/time"] = function() return { now = function() return 0 end } end
package.preload["ffi/util"] = function() return { template = function(text) return text end } end
package.preload["weread.lib.i18n"] = function() return { tr = function(text) return text end } end
package.preload["weread.lib.reader_state"] = function()
    return { apply_to_book = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/web/reader/" .. tostring(book_id) .. tostring(chapter_uid or "")
        end,
        make_content_params = function() return {} end,
    }
end

local ErrorText = require("weread.lib.error_text")
local strip, display = ErrorText.strip_position, ErrorText.display

-- strip_position: one or several stacked positions, any path shape.
expect(strip("plugins/weread.koplugin/weread/lib/content.lua:1699: /web/book/chapter/e_0 failed: HTTP unknown (timeout)")
    == "/web/book/chapter/e_0 failed: HTTP unknown (timeout)", "single position kept")
expect(strip(".../weread/lib/content.lua:1746: .../weread/lib/content.lua:1699: HTTP nil (timeout)")
    == "HTTP nil (timeout)", "stacked re-raise positions kept")
expect(strip("./weread/lib/client.lua:532: HTTP 502, content_type=unknown") == "HTTP 502, content_type=unknown",
    "relative path position kept")
expect(strip('[string "chunk"]:3: boom') == "boom", "loadstring chunk position kept")
expect(strip("C:\\koreader\\plugins\\weread.koplugin\\main.lua:12:no space") == "no space",
    "Windows path position kept")
-- Messages without a leading position are left alone, including text that
-- merely mentions a .lua file later on.
expect(strip("network is not connected") == "network is not connected", "plain message changed")
expect(strip("Could not open /mnt/us/koreader/x.lua:3: denied") == "Could not open /mnt/us/koreader/x.lua:3: denied",
    "a position in the middle of a message was stripped")
expect(strip("weread/lib/content.lua:12:") == "weread/lib/content.lua:12:", "position-only text became empty")
expect(strip(42) == "42", "non-string error not converted")

-- display: first line only, no position, capped length.
local traceback = "./weread/lib/content.lua:1746: ./weread/lib/content.lua:1699: "
    .. "/web/book/chapter/e_0 failed: HTTP unknown (timeout)\nstack traceback:\n\tweread/lib/content.lua:1699: in function"
expect(display(traceback) == "/web/book/chapter/e_0 failed: HTTP unknown (timeout)",
    "worker error displayed with position or traceback: " .. display(traceback))
local long = display("weread/lib/x.lua:1: " .. string.rep("a", 400))
expect(#long == 303 and long:sub(-3) == "..." and not has_position(long), "long error not capped")
expect(display("network is not connected") == "network is not connected", "plain message changed by display")

-- Every UI module's display_error goes through the same helper.
local PluginUtil = require("weread.lib.plugin_util")
expect(PluginUtil.display_error(traceback) == "/web/book/chapter/e_0 failed: HTTP unknown (timeout)",
    "PluginUtil.display_error leaked a source position")

-- Content raise sites on the download path use level 0.
local Content = require("weread.lib.content")
local function fake_client(code, status, body)
    return {
        json_encode = function() return "{}" end,
        request = function() return body, code, {}, status end,
        get_text = function() return "<html></html>" end,
        json_decode = function() return {} end,
    }
end
local function raised(fn, ...)
    local ok, err = pcall(fn, ...)
    expect(not ok, "expected an error")
    return tostring(err)
end
local book = { book_id = "b1", psvts = "p" }
local chapter = { chapterUid = 7 }

local err = raised(Content.fetch_chapter_shard, fake_client(nil, "timeout"), {}, book, chapter, "/web/book/chapter/e_0")
expect(err == "/web/book/chapter/e_0 failed: HTTP unknown (timeout)", "shard transport error: " .. err)
err = raised(Content.fetch_chapter_shard, fake_client(503), {}, book, chapter, "/web/book/chapter/e_1")
expect(err == "/web/book/chapter/e_1 failed: HTTP 503", "shard status error: " .. err)
err = raised(Content.fetch_chapter_shard, fake_client(200, nil, "{}"), {}, book, chapter, "/web/book/chapter/e_3")
expect(err == "/web/book/chapter/e_3 returned empty object", "empty shard error: " .. err)
err = raised(Content.fetch_chapter_shard, fake_client(200, nil, "x"), {}, book, nil, "/web/book/chapter/e_0")
expect(err == "chapter is required", "missing chapter error: " .. err)

-- fetch_chapter_xhtml re-raises the e_0 failure unchanged (no second prefix).
local real_ensure = Content.ensure_reader_state
Content.ensure_reader_state = function(_client, target) target.psvts = "p" end
err = raised(Content.fetch_chapter_xhtml, fake_client(nil, "wantread"), {}, { book_id = "b1" }, chapter)
Content.ensure_reader_state = real_ensure
expect(err == "/web/book/chapter/e_0 failed: HTTP unknown (wantread)", "re-raised e_0 error: " .. err)

-- A reader page without psvts.
local real_extract = Content.extract_reader_state
Content.extract_reader_state = function() return {} end
err = raised(Content.ensure_reader_state, fake_client(200), { book_id = "b1" })
Content.extract_reader_state = real_extract
expect(err == "reader.psvts not found", "missing psvts error: " .. err)

print(("error_text_spec: %d checks"):format(checks))
