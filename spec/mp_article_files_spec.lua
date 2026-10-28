-- Real filesystem checks for staged MP article publication and rollback.
package.path = "./?.lua;" .. package.path
local checks = 0
local function expect(value, label)
    checks = checks + 1
    assert(value, label)
end
local function quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
local function command_ok(command)
    local ok = os.execute(command)
    return ok == true or ok == 0
end
local function mkdir(path) assert(command_ok("mkdir -p -- " .. quote(path))) end
local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local bytes = file:read("*a"); file:close(); return bytes
end
local function write(path, bytes)
    local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
end
local function mode(path)
    if command_ok("test -L " .. quote(path)) then return "link" end
    if command_ok("test -d " .. quote(path)) then return "directory" end
    if read(path) then return "file" end
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key) local value = mode(path); return key and value or value and { mode = value } end,
        symlinkattributes = function(path, key) local value = mode(path); return key and value or value and { mode = value } end,
        dir = function(path)
            local listing = assert(io.popen("ls -A -- " .. quote(path)))
            local names = { ".", ".." }
            for name in listing:lines() do names[#names + 1] = name end
            listing:close()
            local index = 0
            return function() index = index + 1; return names[index] end
        end,
    }
end
package.preload["ffi/util"] = function()
    return { purgeDir = function(path) return command_ok("rm -rf -- " .. quote(path)) end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local Files = require("weread.lib.mp_article_files")
local Content = require("weread.lib.content")
local root = os.tmpname(); os.remove(root); mkdir(root)
local rename = os.rename
local ok, err = xpcall(function()
    local settings = { cache_dir = root }
    local article = { reviewId = "synthetic", title = "Article" }
    local function prepare()
        local book = { book_id = "MP_WXS_1" }
        local download = Files.prepare(settings, book, article)
        expect(book.cache_dir == nil, "preparing a worker mutated parent book state")
        local old_assets = download.target_dir .. "/" .. download.asset_prefix .. "1-111111"
        mkdir(old_assets); write(old_assets .. "/img.png", "old image")
        write(download.target_html, "old HTML")
        write(download.target_dir .. "/Other.html", "<img src=\"" .. old_assets:match("[^/]+$") .. "/img.png\">")
        mkdir(download.stage_assets); write(download.stage_assets .. "/img.png", "new image")
        write(download.stage_html, "new HTML")
        return download, old_assets
    end
    local download, old_assets = prepare()
    expect(Files.cleanup(download), "cancel cleanup failed")
    expect(read(download.target_html) == "old HTML" and read(old_assets .. "/img.png") == "old image",
        "cancellation modified old HTML or images")
    expect(mode(download.workspace.path) == nil, "cancel left a partial workspace")

    for _, failure in ipairs({ "assets", "backup", "publish", "persist" }) do
        download, old_assets = prepare()
        rawset(os, "rename", function(from, to)
            if failure == "assets" and from == download.stage_assets
                or failure == "backup" and to == download.backup_html
                or failure == "publish" and from == download.stage_html then
                return nil, "injected " .. failure .. " failure"
            end
            return rename(from, to)
        end)
        local path, message, keep = Files.commit(download, function()
            if failure == "persist" then error("injected metadata failure") end
        end)
        rawset(os, "rename", rename)
        expect(path == nil and message:find("injected", 1, true) and not keep,
            failure .. " did not report a recoverable publication failure")
        expect(read(download.target_html) == "old HTML" and read(old_assets .. "/img.png") == "old image",
            failure .. " damaged the previous article")
        expect(mode(download.target_assets) == nil, failure .. " left an unpublished image directory")
        Files.cleanup(download)
    end

    download, old_assets = prepare()
    rawset(os, "rename", function(from, to)
        if from == download.stage_html or from == download.backup_html then return nil, "injected disk failure" end
        return rename(from, to)
    end)
    local path, message, keep = Files.commit(download)
    rawset(os, "rename", rename)
    expect(path == nil and keep and message:find("rollback", 1, true), "failed rollback was hidden")
    expect(read(download.backup_html) == "old HTML" and read(old_assets .. "/img.png") == "old image",
        "failed rollback lost the previous article bytes")
    Files.cleanup(download)

    download, old_assets = prepare()
    local persisted = false
    expect(Files.commit(download, function() persisted = true end) == download.target_html and persisted,
        "successful publication did not complete parent persistence")
    expect(read(download.target_html) == "new HTML" and read(download.target_assets .. "/img.png") == "new image",
        "successful publication mismatched HTML and images")
    expect(read(old_assets .. "/img.png") == "old image"
        and read(download.target_dir .. "/Other.html"):find(old_assets:match("[^/]+$"), 1, true),
        "redownload removed images another HTML can still reference")
    Files.cleanup(download)

    download = prepare()
    mkdir(download.target_assets)
    write(download.target_assets .. "/existing.png", "preexisting version")
    path, message = Files.commit(download)
    expect(path == nil and message:find("already exists", 1, true), "version collision was overwritten")
    expect(read(download.target_assets .. "/existing.png") == "preexisting version"
        and read(download.target_html) == "old HTML", "collision damaged published files")
    Files.cleanup(download)

    download = prepare()
    local ffiutil = require("ffi/util")
    local purge = ffiutil.purgeDir
    ffiutil.purgeDir = function() return nil, "injected resource cleanup failure" end
    path, message = Files.commit(download, function() error("metadata failure") end)
    ffiutil.purgeDir = purge
    expect(path == nil and message:find("image cleanup failed", 1, true)
        and read(download.target_html) == "old HTML", "resource cleanup failure was hidden or lost old HTML")
    purge(download.target_assets)
    Files.cleanup(download)

    local book = { book_id = "atomic-html" }
    local old = Content.save_mp_article_html(settings, book, article, "old body")
    local bytes = read(old)
    local open = io.open
    rawset(io, "open", function(path2, flags)
        if path2 == old .. ".part" and flags == "wb" then
            return { write = function() return nil, "disk full" end, close = function() return true end }
        end
        return open(path2, flags)
    end)
    local saved = pcall(Content.save_mp_article_html, settings, book, article, "replacement body")
    rawset(io, "open", open)
    expect(not saved and read(old) == bytes, "short HTML write overwrote the previous article")
end, debug.traceback)
rawset(os, "rename", rename)
os.execute("rm -rf -- " .. quote(root))
assert(ok, err)
print(("mp_article_files_spec: %d checks"):format(checks))
