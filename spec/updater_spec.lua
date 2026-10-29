package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload.device = function()
    return { unpackArchive = function() return true end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, scheduleIn = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, value) return value end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(value) return value end,
        T = function(template, ...)
            local values = { ... }
            return (template:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end

local Updater = require("weread.lib.updater")

expect(Updater.MAX_PACKAGE_BYTES == 10 * 1024 * 1024,
    "update package limit must be 10 MiB")

expect(Updater.compare_versions("1.2.3", "1.2.2") == 1,
    "newer version was not detected")
expect(Updater.compare_versions("v1.2.3", "1.2.3") == 0,
    "v-prefixed version should compare equally")
expect(Updater.compare_versions("1.2.2", "1.2.3") == -1,
    "older version was not detected")
expect(Updater.compare_versions("invalid", "1.2.3") == nil,
    "invalid version should be rejected")
expect(Updater.compare_versions("1.2.3-beta", "1.2.3") == nil,
    "non-release version should be rejected")

local direct_first = Updater.candidate_urls(Updater.API_URL, false)
expect(#direct_first == 4 and direct_first[1] == Updater.API_URL
    and direct_first[2]:find("gh%-proxy.com"),
    "direct-first source order was wrong")
local proxy_first = Updater.candidate_urls(Updater.API_URL, true)
expect(#proxy_first == 4 and proxy_first[1]:find("gh%-proxy.com")
    and proxy_first[4] == Updater.API_URL,
    "proxy-first source order was wrong")
expect(#Updater.candidate_urls("https://example.com/update.zip", true) == 0,
    "untrusted update URL should not receive proxy candidates")

local release, release_err = Updater.parse_release({
    tag_name = "v0.7.0",
    draft = false,
    prerelease = false,
    body = "## What's Changed\n\n**Added** `updates`",
    html_url = "https://github.com/qvictl/weread.koplugin/releases/tag/v0.7.0",
    assets = {
        {
            name = "weread.koplugin-v0.7.0.zip",
            browser_download_url = "https://github.com/qvictl/weread.koplugin/releases/download/v0.7.0/weread.koplugin-v0.7.0.zip",
            size = 1234,
        },
        {
            name = "weread.koplugin-v0.7.0.zip.sha256",
            browser_download_url = "https://github.com/qvictl/weread.koplugin/releases/download/v0.7.0/weread.koplugin-v0.7.0.zip.sha256",
        },
    },
})
expect(release ~= nil and release_err == nil, "valid release was rejected")
expect(release.version == "0.7.0" and release.archive_size == 1234,
    "release metadata was parsed incorrectly")
expect(release.notes:find("Added updates", 1, true) ~= nil,
    "release notes were not normalized")

local function parse_notes(notes)
    return assert(Updater.parse_release{
        tag_name = "v0.7.0", body = notes,
        assets = {
            { name = "weread.koplugin-v0.7.0.zip", browser_download_url = release.archive_url },
            { name = "weread.koplugin-v0.7.0.zip.sha256", browser_download_url = release.checksum_url },
        },
    }).notes
end
local long_notes = string.rep("中文更新内容，支持完整滚动阅读。\n", 120) .. "最后一条更新"
expect(parse_notes(long_notes) == long_notes, "long release notes were truncated")
local bounded_notes = parse_notes(string.rep("中", Updater.MAX_NOTES_BYTES))
expect(#bounded_notes <= Updater.MAX_NOTES_BYTES
    and bounded_notes:gsub("中", "") == "...", "notes limit split a UTF-8 character")

local missing, missing_err = Updater.parse_release({
    tag_name = "v0.7.0",
    assets = {},
})
expect(missing == nil and missing_err:find("checksum", 1, true),
    "release without checksum should be rejected")

local foreign = Updater.parse_release({
    tag_name = "v0.7.0",
    assets = {
        { name = "weread.koplugin-v0.7.0.zip", browser_download_url = "https://example.com/plugin.zip" },
        { name = "weread.koplugin-v0.7.0.zip.sha256", browser_download_url = "https://example.com/plugin.sha256" },
    },
})
expect(foreign == nil, "foreign download URL should be rejected")

package.loaded["ltn12"] = {
    sink = {
        file = function(file)
            return function(chunk)
                if chunk then file:write(chunk) else file:close() end
                return 1
            end
        end,
        table = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    },
}
package.loaded["socket"] = {
    skip = function(count, ...)
        return select(count + 1, ...)
    end,
}
package.loaded["socketutil"] = {
    FILE_BLOCK_TIMEOUT = 1,
    FILE_TOTAL_TIMEOUT = 1,
    LARGE_BLOCK_TIMEOUT = 1,
    LARGE_TOTAL_TIMEOUT = 1,
    set_timeout = function() end,
    reset_timeout = function() end,
}
local request_count = 0
package.loaded["socket/http"] = {
    request = function(options)
        request_count = request_count + 1
        local ok, err = options.sink("abc")
        if not ok then return nil, err end
        ok, err = options.sink("def")
        if not ok then return nil, err end
        options.sink(nil)
        return 1, 200, {}, "OK"
    end,
}

local update_state = { prefer_proxy = false }
local updater = Updater:new{
    settings = {
        get = function() return update_state end,
        set = function() end,
        flush = function() end,
    },
    current_version = "0.6.0",
    plugin_dir = "/tmp/weread.koplugin",
}
updater:cache_release(release)
expect(updater:should_notify("0.7.0"), "new release should notify by default")
expect(not updater:should_notify("0.6.0") and not updater:should_notify("0.5.0"),
    "current or older release should not notify")
local before_snooze = os.time()
updater:snooze_update("0.7.0")
expect(update_state.snooze_until >= before_snooze + 86400
    and not updater:should_notify("0.7.0"), "snooze must suppress the version for 24 hours")
expect(updater:should_notify("0.8.0"), "snooze must not hide a newer version")
local reloaded = Updater:new{
    settings = updater.settings, current_version = "0.6.0", plugin_dir = updater.plugin_dir,
}
expect(not reloaded:should_notify("0.7.0"), "snooze must survive instance recreation")
update_state.snooze_until = os.time()
expect(reloaded:should_notify("0.7.0"), "snooze should expire after 24 hours")
updater:skip_update("0.7.0")
updater:cache_release(release)
expect(not reloaded:should_notify("0.7.0") and reloaded:should_notify("0.8.0"),
    "skipped version must survive checks and leave newer releases visible")
expect(reloaded:cached_release().version == "0.7.0", "skipping must preserve manual update")
local backup_exists, purged_path = true, nil
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        if path == updater.plugin_dir .. ".backup" and backup_exists then
            return "directory"
        end
    end,
}
package.loaded["ffi/util"] = {
    purgeDir = function(path) purged_path = path end,
}
local cleanup_ok, cleanup_err = updater:cleanup_backup()
expect(cleanup_ok == true and cleanup_err == nil
        and purged_path == updater.plugin_dir .. ".backup",
    "successful startup should remove the previous update backup")
backup_exists, purged_path = false, nil
cleanup_ok, cleanup_err = updater:cleanup_backup()
expect(cleanup_ok == true and cleanup_err == nil and purged_path == nil,
    "backup cleanup should be a no-op when no backup exists")
local progress = {}
local download_path = "/tmp/weread-updater-progress-spec.bin"
local downloaded, download_err = updater:_http_get(
    Updater.RELEASE_PREFIX .. "v0.7.0/test.zip",
    download_path,
    function(received, total)
        progress[#progress + 1] = { received, total }
    end,
    6,
    Updater.MAX_PACKAGE_BYTES)
expect(downloaded == true and download_err == nil,
    "streaming download failed")
expect(#progress == 2 and progress[1][1] == 3 and progress[2][1] == 6
    and progress[2][2] == 6,
    "streaming download did not report real byte progress")
local downloaded_file = assert(io.open(download_path, "rb"))
expect(downloaded_file:read("*a") == "abcdef",
    "streaming download wrote unexpected content")
downloaded_file:close()
os.remove(download_path)

request_count = 0
local oversized, oversized_err = updater:_http_get_with_mirrors(
    Updater.RELEASE_PREFIX .. "v0.7.0/test.zip",
    download_path, nil, 0, 5)
expect(oversized == nil and oversized_err == "download exceeds size limit",
    "streaming download should stop as soon as it exceeds the size limit")
expect(request_count == 1,
    "size-limit failures should not retry the download through mirrors")
expect(io.open(download_path, "rb") == nil,
    "oversized partial download should be removed")

-- The package checksum is computed chunk by chunk through ffi/sha2 instead of
-- reading the whole archive into memory.
local Crypto = require("weread.lib.crypto")
local sha_chunks = {}
package.loaded["ffi/sha2"] = {
    sha256 = function(message)
        assert(message == nil, "package hash must use the chunked API")
        local parts = {}
        local function append(chunk)
            if chunk == nil then return Crypto.sha256_hex(table.concat(parts)):upper() end
            sha_chunks[#sha_chunks + 1] = #chunk
            parts[#parts + 1] = chunk
            return append
        end
        return append
    end,
}
package.loaded["ffi/archiver"] = {
    Reader = {
        new = function()
            return { open = function() return false end, close = function() end,
                err = "fixture archive not opened" }
        end,
    },
}
local install_root = os.tmpname() .. "-weread-install"
os.remove(install_root)
os.execute("mkdir -p '" .. install_root .. "/weread.koplugin'")
local package_body = string.rep("weread", 30000)
local install_updater = Updater:new{
    settings = { data_dir = install_root, get = function() return update_state end },
    current_version = "0.6.0",
    plugin_dir = install_root .. "/weread.koplugin",
}
package.loaded["util"] = {
    makePath = function(path) return os.execute("mkdir -p '" .. path .. "'") == 0 or true end,
}
local checksum_text = Crypto.sha256_hex(package_body)
function install_updater:_http_get_with_mirrors(url, destination)
    local file = assert(io.open(destination, "wb"))
    file:write(url == "checksum" and (checksum_text .. "  plugin.zip\n") or package_body)
    file:close()
    return true
end
local install_ok, install_err = install_updater:install_release{
    archive_url = "archive", checksum_url = "checksum", version = "0.7.0",
}
expect(not install_ok and install_err == "fixture archive not opened",
    "a matching checksum should pass verification: " .. tostring(install_err))
expect(#sha_chunks > 1 and sha_chunks[1] == 64 * 1024,
    "the package was not hashed in 64 KiB chunks")
checksum_text = string.rep("0", 64)
install_ok, install_err = install_updater:install_release{
    archive_url = "archive", checksum_url = "checksum", version = "0.7.0",
}
expect(not install_ok and install_err == "SHA-256 verification failed",
    "a mismatching checksum must be rejected")
package.loaded["ffi/sha2"] = nil
package.loaded["ffi/archiver"] = nil

-- After an in-place install the running process keeps the old code; the
-- backup must survive new plugin instances until KOReader restarts.
expect(install_updater:installed_version() == nil and not install_updater:restart_pending(),
    "no _meta.lua means no pending restart")
local meta_file = assert(io.open(install_root .. "/weread.koplugin/_meta.lua", "w"))
meta_file:write('return { version = "0.7.0" }\n')
meta_file:close()
expect(install_updater:installed_version() == "0.7.0" and install_updater:restart_pending(),
    "a newer _meta.lua on disk must report a pending restart")
backup_exists, purged_path = true, nil
package.loaded["libs/libkoreader-lfs"].attributes = function(path)
    if path == install_updater.plugin_dir .. ".backup" and backup_exists then
        return "directory"
    end
end
expect(install_updater:cleanup_backup() == true and purged_path == nil,
    "the update backup must be kept while a restart is pending")
os.execute("rm -rf '" .. install_root .. "'")

local updater_source = assert(io.open("weread/lib/updater.lua", "r")):read("*a")
expect(updater_source:find('require("ui/', 1, true) == nil,
    "core updater must not import UI modules")

local meta = assert(io.open("_meta.lua", "r")):read("*a")
local main = assert(io.open("main.lua", "r")):read("*a")
local meta_version = meta:match('version%s*=%s*"([^"]+)"')
local main_version = main:match('version%s*=%s*"([^"]+)"')
expect(meta_version == main_version, "main.lua and _meta.lua versions must match")

-- Prior published installations must recognize this release's actual assets;
-- after restart its actual main.lua version must suppress the same update.
local release_tag = "v" .. meta_version
local archive_name = "weread.koplugin-" .. release_tag .. ".zip"
local published = assert(Updater.parse_release{
    tag_name = release_tag, draft = false, prerelease = false,
    assets = {
        { name = archive_name, browser_download_url = Updater.RELEASE_PREFIX .. release_tag .. "/" .. archive_name },
        { name = archive_name .. ".sha256",
            browser_download_url = Updater.RELEASE_PREFIX .. release_tag .. "/" .. archive_name .. ".sha256" },
    },
})
local upgrade_state = {}
local upgrade_settings = {
    get = function() return upgrade_state end,
    set = function(_, _, value) upgrade_state = value end,
    flush = function() end,
}
for _, previous_version in ipairs({ "1.6.90", "1.6.91" }) do
    local previous_install = Updater:new{
        settings = upgrade_settings, current_version = previous_version, plugin_dir = "/unused/weread.koplugin",
    }
    previous_install:cache_release(published)
    expect(previous_install:has_update() and previous_install:available_version() == meta_version
        and previous_install:should_notify(published.version), previous_version .. " cannot discover the new package")
end
local restarted_install = Updater:new{
    settings = upgrade_settings, current_version = main_version, plugin_dir = "/unused/weread.koplugin",
}
expect(not restarted_install:has_update() and not restarted_install:should_notify(published.version),
    "restarted release offered its own package again")

print(("updater_spec: %d checks"):format(checks))
