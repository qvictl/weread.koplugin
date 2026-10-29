package.path = "./?.lua;./?/init.lua;" .. package.path

local ChapterState = require("weread.lib.chapter_state")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end
local function plain(value)
    if type(value) ~= "table" then return true end
    if getmetatable(value) then return false end
    for key, item in pairs(value) do if not plain(key) or not plain(item) then return false end end
    return true
end

local parent = { workspace = { path = "original", resumable = true } }
local workspace = parent.workspace
local child, collect = ChapterState.begin(parent)
child.workspace.path = "worker scratch"
child.css = "p { color: black; }"
child.used_asset_names["one.png"] = true
child.used_asset_names.__remote_image_hrefs = { ["https://synthetic.invalid/one"] = "images/one.png" }
child.used_asset_names.__next_asset_suffix = { __count = 1, ["one.png"] = 3 }
expect(parent.css == nil and parent.used_asset_names == nil, "worker must not mutate accepted parent")
expect(parent.workspace.path == "original", "workspace mutations stay in worker")
local delta = collect()
expect(plain(delta), "wire delta must have no overlay metatables")
expect(ChapterState.apply(parent, delta) == parent, "apply preserves state identity")
expect(parent.css == child.css and parent.used_asset_names["one.png"], "first chapter publishes css and names")
expect(parent.workspace == workspace and workspace.path == "original", "apply preserves accepted workspace")

child, collect = ChapterState.begin(parent)
expect(child.used_asset_names["one.png"], "old name remains visible to the worker")
expect(child.used_asset_names.__remote_image_hrefs["https://synthetic.invalid/one"] == "images/one.png",
    "old remote URL remains visible")
local before = clone(parent)
child.used_asset_names["two.png"] = true
local remote = child.used_asset_names.__remote_image_hrefs
remote["https://synthetic.invalid/two"] = "images/two.png"
child.used_asset_names.__remote_image_hrefs = remote -- Content assigns an existing map back.
local suffixes = child.used_asset_names.__next_asset_suffix
suffixes["one.png"] = 4
suffixes.__count = suffixes.__count + 1
child.used_asset_names.__next_asset_suffix = suffixes
expect(equal(parent, before), "nested writes, including existing cursor keys, must remain isolated")
delta = collect()
expect(delta.css == nil and delta.names.set["one.png"] == nil, "unchanged css and names stay off wire")
expect(not delta.remote_images.replace and not delta.asset_suffixes.replace, "same nested map uses a delta")
expect(delta.asset_suffixes.set["one.png"] == 4 and delta.asset_suffixes.set.__count == 2,
    "existing counter and count mutations are captured")
ChapterState.apply(parent, delta)
expect(parent.used_asset_names["one.png"] and parent.used_asset_names["two.png"], "merge retains earlier assets")
expect(parent.used_asset_names.__remote_image_hrefs["https://synthetic.invalid/one"] == "images/one.png",
    "merge retains earlier remote URLs")

child, collect = ChapterState.begin(parent)
child.used_asset_names.__next_asset_suffix = nil
expect(child.used_asset_names.__next_asset_suffix == nil, "rollback nil must not fall back to old cursors")
expect(parent.used_asset_names.__next_asset_suffix["one.png"] == 4, "rollback must not reset the parent")
delta = collect()
ChapterState.apply(parent, delta)
expect(parent.used_asset_names.__next_asset_suffix == nil, "accepted explicit cursor reset is applied")

local names = { __next_asset_suffix = { __count = 1024 } }
for index = 1, 1024 do
    names["old-" .. index .. ".png"] = true
    names.__next_asset_suffix["old-" .. index .. ".png"] = 3
end
parent = { used_asset_names = names }
child, collect = ChapterState.begin(parent)
child.used_asset_names.__next_asset_suffix = { __count = 1, ["new.png"] = 3 }
delta = collect()
expect(delta.asset_suffixes.replace and delta.asset_suffixes.set.__count == 1, "bounded cache replacement is explicit")
expect(names.__next_asset_suffix.__count == 1024, "cache replacement does not mutate accepted cursors")
ChapterState.apply(parent, delta)
expect(names.__next_asset_suffix.__count == 1 and names.__next_asset_suffix["old-1.png"] == nil,
    "replacing the cursor cache must not merge evicted cursors back")
expect(names["old-1.png"] and names["old-1024.png"], "cursor eviction must retain authoritative used names")

child, collect = ChapterState.begin(parent)
child.used_asset_names.__next_asset_suffix = nil
child.used_asset_names.__next_asset_suffix = { __count = 1, ["retry.png"] = 3 }
delta = collect()
expect(delta.asset_suffixes.replace and delta.asset_suffixes.set["new.png"] == nil,
    "reset followed by retry creates a replacement, not an inherited map")

child, collect = ChapterState.begin(parent)
child.used_asset_names["temporary.png"] = true
child.used_asset_names["temporary.png"] = nil
expect(next(collect()) == nil, "rolled-back new names must not create a delta")
child.used_asset_names["old-1.png"] = nil
delta = collect()
expect(delta.names.remove[1] == "old-1.png", "deleting an accepted name is explicit")
ChapterState.apply(parent, delta)
expect(names["old-1.png"] == nil and names["old-2.png"], "only requested deletions are applied")

parent = { css = "original", used_asset_names = { __next_asset_suffix = { __count = 1, a = 3 } } }
before = clone(parent)
child = ChapterState.begin(parent)
local ok = pcall(function()
    child.css = "failed stylesheet"
    child.used_asset_names["failed.png"] = true
    child.used_asset_names.__next_asset_suffix.a = 90
    error("synthetic cancelled/failed worker")
end)
expect(not ok and equal(parent, before), "discarded failed/cancelled work must leave accepted state intact")
child, collect = ChapterState.begin(parent)
child.css = ""
delta = collect()
expect(delta.css and delta.css.value == "", "empty css is a real value")
ChapterState.apply(parent, delta)
child, collect = ChapterState.begin(parent)
child.css = nil
delta = collect()
expect(delta.css ~= nil and delta.css.value == nil, "clearing css must survive serialization")
ChapterState.apply(parent, delta)
expect(parent.css == nil, "explicit css clear is applied")

parent = {}
child, collect = ChapterState.begin(parent)
child.used_asset_names.__remote_image_hrefs = { a = "images/a.png" }
delta = collect()
child.used_asset_names.__remote_image_hrefs.b = "images/b.png"
expect(delta.remote_images.set.b == nil, "collected payload is detached from subsequent child writes")
child, collect = ChapterState.begin(parent)
expect(next(collect()) == nil, "untouched empty state stays empty")

-- Real Content operations must produce the same names, cache and XHTML as
-- carrying the full state, including repeated URLs and same-name suffixes.
local Content = require("weread.lib.content")
local requests = 0
local client = { get_binary = function()
    requests = requests + 1
    return "\137PNG\r\n\26\n" .. "synthetic image"
end }
local function html(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        parts[#parts + 1] = '<img src="https://synthetic.invalid/a.png?version=' .. id .. '"/>'
    end
    return table.concat(parts)
end
parent = { css = "fixed", used_asset_names = {} }
Content.download_remote_images(client, html({ 1, 2 }), parent.used_asset_names)
local expected = clone(parent)
local expected_html, expected_assets = Content.download_remote_images(client, html({ 1, 3, 4, 3 }), expected.used_asset_names)
before = clone(parent)
requests = 0
child, collect = ChapterState.begin(parent)
local actual_html, actual_assets = Content.download_remote_images(client, html({ 1, 3, 4, 3 }), child.used_asset_names)
expect(actual_html == expected_html and equal(actual_assets, expected_assets), "real Content output matches full-state output")
expect(requests == 2, "cached and repeated URLs do not trigger extra downloads")
expect(equal(parent, before), "real Content does not mutate accepted parent maps")
delta = collect()
expect(plain(delta), "real Content result remains codec-compatible plain data")
ChapterState.apply(parent, delta)
expect(equal(parent, expected), "real Content delta applies to the same final state")

-- Exercise Content's actual bounded-cache replacement rather than merely
-- constructing a replacement-shaped payload in this test.
parent = { used_asset_names = { ["fresh.png"] = true, __next_asset_suffix = { __count = 1024 } } }
for index = 1, 1024 do
    parent.used_asset_names["taken-" .. index .. ".png"] = true
    parent.used_asset_names.__next_asset_suffix["taken-" .. index .. ".png"] = 3
end
before = clone(parent)
expected = clone(parent)
local expected_name = Content._unique_asset_name(expected.used_asset_names, "fresh.png", ".png")
child, collect = ChapterState.begin(parent)
expect(Content._unique_asset_name(child.used_asset_names, "fresh.png", ".png") == expected_name,
    "real capped cursor replacement preserves file names")
delta = collect()
expect(delta.asset_suffixes.replace and delta.asset_suffixes.set.__count == 1,
    "actual Content cap emits a whole replacement")
expect(equal(parent, before), "actual Content cap cannot evict accepted parent cursors early")
ChapterState.apply(parent, delta)
expect(equal(parent, expected), "actual Content cap applies exactly the full-state result")

-- A valid image followed by a truncated TAR entry writes a real file before
-- extraction fails. Rollback must remove it and explicitly hide old cursors
-- inside the child, while failed work leaves the accepted parent unchanged.
local function quoted(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local directory = os.tmpname()
os.remove(directory)
os.execute("mkdir -p " .. quoted(directory .. "/incoming") .. " " .. quoted(directory .. "/images"))
local function tar_header(name, size)
    return name .. string.rep("\0", 100 - #name) .. string.rep("\0", 24)
        .. string.format("%011o", size) .. "\0" .. string.rep("\0", 20) .. "0" .. string.rep("\0", 355)
end
local png = "\137PNG\r\n\26\n" .. "synthetic image"
local tar = tar_header("taken.png", #png) .. png .. string.rep("\0", (512 - #png % 512) % 512)
    .. tar_header("broken.png", 90) .. png:sub(1, 8)
parent = { used_asset_names = { ["taken.png"] = true, ["taken-2.png"] = true,
    __next_asset_suffix = { __count = 1, ["taken.png"] = 3 } } }
before = clone(parent)
child = ChapterState.begin(parent)
local disk_client = { download_to_file = function(_, _, path)
    local output = assert(io.open(path, "wb"))
    assert(output:write(tar))
    assert(output:close())
end }
local called, error_text = pcall(Content.download_chapter_assets_to_files, disk_client,
    { book_id = "1" }, { chapterUid = 1, tar = "https://synthetic.invalid/chapter.tar" },
    child.used_asset_names, { incoming_dir = directory .. "/incoming", asset_dir = directory .. "/images" })
expect(not called and tostring(error_text):find("truncated TAR entry", 1, true), "real extraction must fail after partial output")
local output = io.open(directory .. "/images/taken-3.png", "rb")
if output then output:close() end
expect(output == nil and not child.used_asset_names["taken-3.png"], "real rollback removes the file and allocated name")
expect(child.used_asset_names.__next_asset_suffix == nil, "real rollback must hide the old cursor map")
expect(equal(parent, before), "discarded extraction failure must not mutate parent maps")
os.execute("rmdir " .. quoted(directory .. "/incoming") .. " " .. quoted(directory .. "/images") .. " " .. quoted(directory))

local has_buffer, buffer = pcall(require, "string.buffer")
if has_buffer then
    parent = { used_asset_names = {} }
    for index = 1, 10000 do parent.used_asset_names["old-" .. index .. ".png"] = true end
    child, collect = ChapterState.begin(parent)
    child.used_asset_names["new.png"] = true
    local encoded = buffer.encode({ { ok = true, value = { state_delta = collect() } }, n = 1 })
    expect(#encoded < 512, "wire size must depend on the current chapter, not 10,000 accepted names")
    local received = buffer.decode(encoded)[1].value.state_delta
    ChapterState.apply(parent, received)
    expect(parent.used_asset_names["old-10000.png"] and parent.used_asset_names["new.png"],
        "actual codec roundtrip preserves history and applies current chapter")
else
    print("chapter_state_spec: string.buffer unavailable in this standalone interpreter; native codec checks skipped")
end
print("chapter_state_spec: " .. checks .. " checks passed")
