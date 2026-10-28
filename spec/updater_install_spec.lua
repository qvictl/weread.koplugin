package.path = "./?.lua;./?/init.lua;" .. package.path

-- Behavioural coverage of weread/lib/updater.lua beyond updater_spec.lua:
-- version/metadata edge cases, the release check over mirrors, and the
-- install pipeline (download, SHA-256 verification, extraction, backup and
-- rollback) against a real temporary directory tree.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function contains(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

package.preload["weread.lib.logger"] = function()
    local function noop() end
    return { info = noop, warn = noop, err = noop }
end

local Updater = require("weread.lib.updater")
local Crypto = require("weread.lib.crypto")

local PREFIX = Updater.RELEASE_PREFIX

-- Filesystem helpers --------------------------------------------------------

local function sh(command)
    local result = os.execute(command)
    return result == 0 or result == true
end

local function quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
local function is_dir(path) return sh("test -d " .. quote(path)) end
local function exists(path) return sh("test -e " .. quote(path)) end

local function write_file(path, data)
    sh("mkdir -p " .. quote(path:match("^(.*)/[^/]+$")))
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local root = os.tmpname()
os.remove(root)
assert(sh("mkdir -p " .. quote(root)))

-- KOReader module stubs (installed into package.loaded so they can be
-- swapped per scenario) ----------------------------------------------------

package.loaded["ffi/util"] = {
    purgeDir = function(path) sh("rm -rf " .. quote(path)) end,
}
local make_path_error
package.loaded["util"] = {
    makePath = function(path)
        if make_path_error then return nil, make_path_error end
        return sh("mkdir -p " .. quote(path))
    end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, _mode) return is_dir(path) and "directory" or nil end,
    mkdir = function(path)
        if sh("mkdir " .. quote(path) .. " 2>/dev/null") then return true end
        return nil, "mkdir failed"
    end,
}

-- Archive fixtures: the downloaded "zip" body is a key into this table.
local archives = {}
package.loaded["ffi/archiver"] = {
    Reader = {
        new = function()
            local reader = {}
            function reader:open(path)
                self.fixture = archives[read_file(path) or ""]
                if not self.fixture then self.err = "not a zip archive" end
                return self.fixture ~= nil
            end
            function reader:iterate()
                local index = 0
                return function()
                    index = index + 1
                    local entry = self.fixture.entries[index]
                    if not entry and self.fixture.post_err then self.err = self.fixture.post_err end
                    return entry
                end
            end
            function reader:extractToPath(path, destination)
                local entry
                for _i, candidate in ipairs(self.fixture.entries) do
                    if candidate.path == path then entry = candidate end
                end
                if entry.fail then self.err = entry.fail; return false end
                if path:sub(-1) == "/" then return sh("mkdir -p " .. quote(destination)) end
                write_file(destination, entry.content or "")
                return true
            end
            function reader:close() self.closed = true end
            return reader
        end,
    },
}

local function plugin_archive(version, extra)
    local entries = {
        { path = "weread.koplugin/" },
        { path = "weread.koplugin/_meta.lua", content = 'return { version = "' .. version .. '" }\n' },
        { path = "weread.koplugin/main.lua", content = "return 'new main'\n" },
        { path = "weread.koplugin/weread/lib/feature.lua", content = "return 'new'\n" },
    }
    for _i, entry in ipairs(extra or {}) do entries[#entries + 1] = entry end
    return { entries = entries }
end

-- HTTP stubs: `server[url]` is { code, body } or a function(url) returning
-- those; unknown URLs fail like a refused connection.
local server, requests = {}, {}
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
package.loaded["socket"] = { skip = function(count, ...) return select(count + 1, ...) end }
local timeouts = {}
package.loaded["socketutil"] = {
    FILE_BLOCK_TIMEOUT = "file-block", FILE_TOTAL_TIMEOUT = "file-total",
    LARGE_BLOCK_TIMEOUT = "large-block", LARGE_TOTAL_TIMEOUT = "large-total",
    set_timeout = function(_self, block, total) timeouts[#timeouts + 1] = block .. "/" .. total end,
    reset_timeout = function() timeouts[#timeouts + 1] = "reset" end,
}
package.loaded["socket/http"] = {
    request = function(options)
        requests[#requests + 1] = options.url
        local response = server[options.url]
        if type(response) == "function" then response = response(options.url) end
        if not response then return nil, "connection refused" end
        local body = response[2] or ""
        for start = 1, #body, 7 do
            local ok, err = options.sink(body:sub(start, start + 6))
            if not ok then return nil, err end
        end
        options.sink(nil)
        return 1, response[1], {}, "status"
    end,
}

local json_bodies = {}
package.loaded["json"] = {
    decode = function(text)
        local value = json_bodies[text]
        if value == nil then error("unexpected token") end
        return value
    end,
}

local function make_settings(state, data_dir)
    local settings = { state = state or {}, data_dir = data_dir, sets = 0, flushes = 0 }
    function settings:get(key) assert(key == "update"); return self.state end
    function settings:set(key, value)
        assert(key == "update")
        self.state = value
        self.sets = self.sets + 1
    end
    function settings:flush() self.flushes = self.flushes + 1 end
    return settings
end

local function reset_network()
    server, requests, timeouts = {}, {}, {}
end

-- compare_versions / candidate_urls / parse_release ------------------------

do
    local compare = Updater.compare_versions
    expect(compare("1.10.0", "1.9.9") == 1, "components compare numerically, not lexically")
    expect(compare("2.0.0", "1.99.99") == 1 and compare("0.0.9", "0.1.0") == -1,
        "higher components dominate lower ones")
    expect(compare("1.2.3", "v1.2.4") == -1, "a v prefix is accepted on either side")
    expect(compare("01.002.0003", "1.2.3") == 0, "leading zeros do not matter")
    for _i, bad in ipairs({ "1.2", "1.2.3.4", " 1.2.3", "1.2.3 ", "V1.2.3", "vv1.2.3", "", 123 }) do
        expect(compare(bad, "1.2.3") == nil and compare("1.2.3", bad) == nil,
            "malformed version rejected: " .. tostring(bad))
    end
    expect(compare(nil, "1.2.3") == nil and compare("1.2.3", nil) == nil, "missing version rejected")

    local release_url = PREFIX .. "v1.0.0/weread.koplugin-v1.0.0.zip"
    local candidates = Updater.candidate_urls(release_url, false)
    expect(#candidates == 1 + #Updater.GITHUB_MIRRORS and candidates[1] == release_url
        and candidates[2] == Updater.GITHUB_MIRRORS[1] .. release_url,
        "release downloads may use mirrors after the direct URL")
    expect(#Updater.candidate_urls(nil) == 0 and #Updater.candidate_urls(42) == 0,
        "non-string URLs are not allowed")
    expect(#Updater.candidate_urls("https://github.com/other/repo/releases/download/x.zip") == 0,
        "other repositories are not allowed")
end

do
    local function assets(version, overrides)
        local list = {
            { name = "weread.koplugin-v" .. version .. ".zip",
              browser_download_url = PREFIX .. "v" .. version .. "/weread.koplugin-v" .. version .. ".zip",
              size = 2048 },
            { name = "weread.koplugin-v" .. version .. ".zip.sha256",
              browser_download_url = PREFIX .. "v" .. version .. "/weread.koplugin-v" .. version .. ".zip.sha256" },
        }
        for index, value in pairs(overrides or {}) do list[index] = value end
        return list
    end
    local function release(fields)
        local data = { tag_name = "v1.4.0", assets = assets("1.4.0") }
        for key, value in pairs(fields or {}) do data[key] = value end
        return data
    end

    local parsed = assert(Updater.parse_release(release({
        body = "\r\n# Title\r\n## Fixes\r\n- `code` **bold**\r\n", html_url = "https://example/rel",
    })))
    expect(parsed.version == "1.4.0" and parsed.archive_size == 2048, "release parsed")
    expect(parsed.notes == "Title\nFixes\n- code bold", "notes normalized: " .. tostring(parsed.notes))
    expect(parsed.release_url == "https://example/rel", "release page kept")
    expect(Updater.parse_release(release({ body = "  \n " })).notes == nil, "blank notes dropped")
    expect(Updater.parse_release(release()).notes == nil, "missing notes dropped")

    local function rejected(data, needle, message)
        local value, err = Updater.parse_release(data)
        expect(value == nil and contains(err, needle), message .. ": " .. tostring(err))
    end
    rejected(nil, "invalid release metadata", "nil metadata")
    rejected("{}", "invalid release metadata", "non-table metadata")
    rejected(release({ draft = true }), "invalid release metadata", "drafts are never offered")
    rejected(release({ prerelease = true }), "invalid release metadata", "prereleases are never offered")
    rejected(release({ tag_name = "1.4.0" }), "invalid release tag", "tag without v")
    rejected(release({ tag_name = "v1.4.0-rc1" }), "invalid release tag", "pre-release suffix")
    rejected(release({ tag_name = 140 }), "invalid release tag", "non-string tag")
    rejected(release({ assets = {} }), "missing", "no assets")
    rejected(release({ assets = assets("1.4.0", { [1] = { name = "other.zip" } }) }), "missing",
        "missing archive")
    rejected(release({ assets = assets("1.4.0", { [2] = { name = "other.sha256" } }) }), "missing",
        "missing checksum")
    rejected(release({ assets = assets("1.3.0") }), "missing", "assets of another version")
    rejected(release({ assets = assets("1.4.0", { [1] = { name = "weread.koplugin-v1.4.0.zip",
        browser_download_url = PREFIX .. "x.zip", size = Updater.MAX_PACKAGE_BYTES + 1 } }) }),
        "too large", "oversized packages")

    local exact = Updater.parse_release(release({ assets = assets("1.4.0", { [1] = {
        name = "weread.koplugin-v1.4.0.zip", browser_download_url = PREFIX .. "x.zip",
        size = tostring(Updater.MAX_PACKAGE_BYTES) } }) }))
    expect(exact and exact.archive_size == Updater.MAX_PACKAGE_BYTES, "size at the limit accepted")
    local unsized = Updater.parse_release(release({ assets = assets("1.4.0", { [1] = {
        name = "weread.koplugin-v1.4.0.zip", browser_download_url = PREFIX .. "x.zip" } }) }))
    expect(unsized and unsized.archive_size == nil, "missing size tolerated")
end

-- Construction and cached state ---------------------------------------------

do
    local ok, err = pcall(Updater.new, Updater, { current_version = "1.0.0" })
    expect(not ok and contains(err, "settings required"), "settings are mandatory")
    ok, err = pcall(Updater.new, Updater, { settings = make_settings() })
    expect(not ok and contains(err, "current_version required"), "current version is mandatory")
    local derived = Updater:new{ settings = make_settings(), current_version = "1.0.0" }
    expect(read_file(derived.plugin_dir .. "/weread/lib/updater.lua") ~= nil,
        "plugin directory derived from the module location")

    local settings = make_settings({ available_version = "" })
    local updater = Updater:new{ settings = settings, current_version = "1.0.0", plugin_dir = root .. "/p" }
    expect(not updater:has_update() and updater:available_version() == nil and updater:cached_release() == nil,
        "no cached update")
    local before = os.time()
    updater:cache_release({ version = "1.1.0", archive_url = "a", checksum_url = "c" })
    local state = settings.state
    expect(settings.sets == 1 and settings.flushes == 1, "state persisted and flushed")
    expect(state.last_check >= before and state.archive_size == 0 and state.release_notes == ""
        and state.release_url == "", "check time and defaults recorded")
    local cached = updater:cached_release()
    expect(cached.version == "1.1.0" and cached.archive_url == "a" and cached.notes == nil,
        "cached release restored without empty notes")
    expect(updater:available_version() == "1.1.0", "available version reported")

    updater.current_version = "1.1.0"
    expect(not updater:has_update() and updater:cached_release() == nil,
        "a cached release equal to the running version is not an update")
    updater.current_version = "1.0.0"
    updater:clear_available_update()
    expect(state.available_version == "" and state.archive_url == "" and state.checksum_url == ""
        and state.last_check >= before, "clearing drops the release but keeps the check time")
    expect(not updater:has_update(), "cleared update no longer offered")

    -- should_notify: skipped versions stay hidden, snoozes are per version.
    settings.state = { skipped_version = "1.2.0", snoozed_version = "1.3.0", snooze_until = os.time() + 60 }
    expect(not updater:should_notify("1.2.0") and not updater:should_notify("1.3.0")
        and updater:should_notify("1.4.0"), "skip and snooze are version specific")
    expect(not updater:should_notify("garbage"), "malformed versions never notify")
    settings.state.snooze_until = "not-a-number"
    expect(updater:should_notify("1.3.0"), "a corrupt snooze deadline does not block forever")
end

-- HTTP and mirror fallback ---------------------------------------------------

do
    reset_network()
    local settings = make_settings({ prefer_proxy = false })
    local updater = Updater:new{ settings = settings, current_version = "1.0.0", plugin_dir = root .. "/p" }

    server[Updater.API_URL] = { 200, "hello world, this is the api" }
    local body = updater:_http_get(Updater.API_URL)
    expect(body == "hello world, this is the api", "in-memory GET returns the whole body")
    expect(timeouts[1] == "large-block/large-total" and timeouts[2] == "reset",
        "API requests use the large timeouts and reset them")

    local destination = root .. "/download.bin"
    server[PREFIX .. "missing.zip"] = { 404, "not found page" }
    local ok, err = updater:_http_get(PREFIX .. "missing.zip", destination)
    expect(ok == nil and contains(err, "HTTP 404"), "HTTP errors reported")
    expect(not exists(destination), "the error page is not left on disk")
    expect(timeouts[3] == "file-block/file-total", "downloads use the file timeouts")

    ok, err = updater:_http_get(PREFIX .. "nowhere.zip")
    expect(ok == nil and contains(err, "connection refused"), "transport errors reported")

    ok, err = updater:_http_get(PREFIX .. "missing.zip", root .. "/no/such/dir/file.zip")
    expect(ok == nil and contains(err, "cannot create download file"), "unwritable destination reported")

    -- Mirrors: direct fails, the second mirror answers.
    reset_network()
    local url = PREFIX .. "v1.1.0/pkg.zip"
    server[url] = { 502, "bad gateway" }
    server[Updater.GITHUB_MIRRORS[2] .. url] = { 200, "payload" }
    local progress = {}
    ok, err = updater:_http_get_with_mirrors(url, destination, function(received, total)
        progress[#progress + 1] = received .. "/" .. tostring(total)
    end, 7)
    expect(ok == true and err == nil and read_file(destination) == "payload", "mirror download succeeded")
    expect(#requests == 3 and requests[1] == url and requests[2] == Updater.GITHUB_MIRRORS[1] .. url,
        "sources tried in order until one succeeds")
    expect(progress[1] == "0/7" and progress[#progress] == "7/7", "progress restarts per source")

    settings.state.prefer_proxy = true
    reset_network()
    server[Updater.GITHUB_MIRRORS[1] .. url] = { 200, "proxied" }
    ok = updater:_http_get_with_mirrors(url, destination)
    expect(ok == true and #requests == 1 and requests[1] == Updater.GITHUB_MIRRORS[1] .. url,
        "proxy preference tries a mirror first")

    reset_network()
    ok, err = updater:_http_get_with_mirrors(url, destination)
    expect(ok == nil and contains(err, "connection refused") and #requests == 1 + #Updater.GITHUB_MIRRORS,
        "all sources failing reports the last error")
    ok, err = updater:_http_get_with_mirrors("https://evil.example/pkg.zip", destination)
    expect(ok == nil and contains(err, "not allowed") and #requests == 1 + #Updater.GITHUB_MIRRORS,
        "untrusted URLs are never requested")
    os.remove(destination)
end

-- fetch_release ---------------------------------------------------------------

do
    reset_network()
    local updater = Updater:new{ settings = make_settings({}), current_version = "1.0.0", plugin_dir = root .. "/p" }
    json_bodies["REL"] = {
        tag_name = "v1.5.0", body = "notes",
        assets = {
            { name = "weread.koplugin-v1.5.0.zip", browser_download_url = PREFIX .. "v1.5.0/a.zip", size = 10 },
            { name = "weread.koplugin-v1.5.0.zip.sha256", browser_download_url = PREFIX .. "v1.5.0/a.sha256" },
        },
    }
    json_bodies["PRE"] = { tag_name = "v1.6.0", prerelease = true, assets = {} }
    server[Updater.API_URL] = { 200, "REL" }
    local release = updater:fetch_release()
    expect(release and release.version == "1.5.0" and release.notes == "notes", "latest release fetched")

    server[Updater.API_URL] = { 200, "PRE" }
    local value, err = updater:fetch_release()
    expect(value == nil and contains(err, "invalid release metadata"), "a prerelease is not offered")

    server[Updater.API_URL] = { 200, "<html>rate limited</html>" }
    value, err = updater:fetch_release()
    expect(value == nil and contains(err, "invalid GitHub response"), "invalid JSON rejected")

    server[Updater.API_URL] = { 403, "{}" }
    value, err = updater:fetch_release()
    expect(value == nil and contains(err, "HTTP"), "HTTP failure on every source reported")

    server[Updater.API_URL] = { 200, "REL" }
    local json = package.loaded["json"]
    package.loaded["json"] = nil
    package.preload["json"] = function() error("module 'json' not found") end
    value, err = updater:fetch_release()
    expect(value == nil and contains(err, "JSON support unavailable"), "missing JSON module reported")
    package.preload["json"] = nil
    package.loaded["json"] = json
end

-- install_release ------------------------------------------------------------------

local env_count = 0
local function new_env(version, archive, checksum_override)
    reset_network()
    env_count = env_count + 1
    local env = { dir = root .. "/env" .. env_count }
    env.plugin_dir = env.dir .. "/plugins/weread.koplugin"
    env.data_dir = env.dir .. "/data"
    write_file(env.plugin_dir .. "/_meta.lua", 'return { version = "1.0.0" }\n')
    write_file(env.plugin_dir .. "/main.lua", "return 'old main'\n")
    write_file(env.plugin_dir .. "/marker.txt", "old")
    sh("mkdir -p " .. quote(env.data_dir))
    local body = "ARCHIVE#" .. env_count
    archives[body] = archive or plugin_archive(version or "1.1.0")
    env.release = {
        version = version or "1.1.0",
        archive_url = PREFIX .. "v1.1.0/weread.koplugin-v1.1.0.zip",
        checksum_url = PREFIX .. "v1.1.0/weread.koplugin-v1.1.0.zip.sha256",
        archive_size = #body,
    }
    server[env.release.archive_url] = { 200, body }
    server[env.release.checksum_url] = { 200, checksum_override or (Crypto.sha256_hex(body):upper() .. "  weread.koplugin.zip\n") }
    env.updater = Updater:new{
        settings = make_settings({}, env.data_dir), current_version = "1.0.0", plugin_dir = env.plugin_dir,
    }
    env.progress = {}
    env.install = function()
        return env.updater:install_release(env.release, function(event)
            env.progress[#env.progress + 1] = event
        end)
    end
    return env
end

local function expect_untouched(env, label)
    expect(read_file(env.plugin_dir .. "/marker.txt") == "old"
        and read_file(env.plugin_dir .. "/main.lua") == "return 'old main'\n",
        label .. ": installed plugin must be untouched")
    expect(not exists(env.plugin_dir .. ".backup"), label .. ": no backup created")
    expect(not exists(env.data_dir .. "/update-stage"), label .. ": staging directory removed")
    expect(not exists(env.data_dir .. "/weread-update.zip")
        and not exists(env.data_dir .. "/weread-update.zip.sha256"), label .. ": downloads removed")
end

do
    -- Successful install with backup.
    local env = new_env()
    write_file(env.plugin_dir .. ".backup/stale.txt", "stale backup")
    write_file(env.data_dir .. "/update-stage/leftover.txt", "previous attempt")
    local ok, err = env.install()
    expect(ok == true and err == nil, "install succeeded: " .. tostring(err))
    expect(read_file(env.plugin_dir .. "/weread/lib/feature.lua") == "return 'new'\n"
        and not exists(env.plugin_dir .. "/marker.txt"), "new plugin activated")
    expect(read_file(env.plugin_dir .. ".backup/marker.txt") == "old"
        and not exists(env.plugin_dir .. ".backup/stale.txt"), "previous plugin kept as the only backup")
    expect(not exists(env.data_dir .. "/update-stage") and not exists(env.data_dir .. "/weread-update.zip")
        and not exists(env.data_dir .. "/weread-update.zip.sha256"), "staging files cleaned up")
    expect(env.updater:installed_version() == "1.1.0" and env.updater:restart_pending(),
        "installed version reported, restart pending")

    local stages, last_percent, monotonic = {}, -1, true
    for _i, event in ipairs(env.progress) do
        if stages[#stages] ~= event.stage then stages[#stages + 1] = event.stage end
        if event.percent < last_percent then monotonic = false end
        last_percent = event.percent
        if event.stage == "downloading" then
            expect(event.percent >= 5 and event.percent <= 75 and event.total == env.release.archive_size,
                "download progress within its band")
        end
    end
    expect(table.concat(stages, ",") == "preparing,downloading,checksum,verifying,extracting,installing,complete",
        "progress stages in order: " .. table.concat(stages, ","))
    expect(monotonic and last_percent == 100, "progress never goes backwards and ends at 100")
end

do
    -- A bare lower-case checksum (leading blanks, no file name) is accepted.
    local env = new_env()
    local body = "ARCHIVE#" .. env_count
    server[env.release.checksum_url] = { 200, "  " .. Crypto.sha256_hex(body) }
    expect(env.install() == true, "bare lower-case checksum accepted")
end

do
    -- Download failures leave the installed plugin untouched.
    local env = new_env()
    server[env.release.archive_url] = { 404, "gone" }
    local ok, err = env.install()
    expect(ok == nil and contains(err, "HTTP"), "archive download failure reported")
    expect_untouched(env, "archive download failure")

    env = new_env()
    server[env.release.checksum_url] = nil
    ok, err = env.install()
    expect(ok == nil and contains(err, "connection refused"), "checksum download failure reported")
    expect_untouched(env, "checksum download failure")

    env = new_env()
    env.release.archive_url = "https://evil.example/pkg.zip"
    ok, err = env.install()
    expect(ok == nil and contains(err, "not allowed") and #requests == 0, "untrusted package URL refused")
    expect_untouched(env, "untrusted package URL")
end

do
    -- Checksum verification.
    local cases = {
        { string.rep("0", 64), "mismatching checksum" },
        { "abc123  weread.koplugin.zip", "short checksum" },
        { "not a checksum", "non-hex checksum" },
        { "", "empty checksum" },
        { Crypto.sha256_hex("x") .. "0", "overlong checksum" },
    }
    for _i, case in ipairs(cases) do
        local env = new_env(nil, nil, case[1])
        local ok, err = env.install()
        expect(ok == nil and contains(err, "SHA-256 verification failed"), case[2] .. " rejected: " .. tostring(err))
        expect_untouched(env, case[2])
    end
    local env = new_env(nil, nil, string.rep("a", 5000))
    local ok, err = env.install()
    expect(ok == nil and contains(err, "invalid checksum file"), "oversized checksum file rejected")
    expect_untouched(env, "oversized checksum file")
end

do
    -- Unsafe archive paths abort before anything leaves the staging directory.
    local unsafe = { "../evil.lua", "/abs/evil.lua", "other/evil.lua", "weread.koplugin/../../evil.lua",
        "weread.koplugin\\evil.lua", "weread.koplugin/a/..", "" }
    for _i, path in ipairs(unsafe) do
        local env = new_env("1.1.0", plugin_archive("1.1.0", { { path = path, content = "evil" } }))
        local ok, err = env.install()
        expect(ok == nil and contains(err, "unsafe path"), "unsafe path rejected: " .. path)
        expect_untouched(env, "unsafe path " .. path)
        expect(not exists(env.dir .. "/evil.lua") and not exists(env.data_dir .. "/evil.lua"),
            "nothing written outside the stage: " .. path)
    end
    local env = new_env("1.1.0", plugin_archive("1.1.0", { { path = false } }))
    expect(contains(select(2, env.install()), "unsafe path"), "non-string archive path rejected")
end

do
    -- Broken archives and invalid packages.
    local env = new_env("1.1.0", plugin_archive("1.1.0", { { path = "weread.koplugin/big.bin", fail = "disk full" } }))
    local ok, err = env.install()
    expect(ok == nil and contains(err, "disk full"), "extraction failure reported")
    expect_untouched(env, "extraction failure")

    local truncated = plugin_archive("1.1.0")
    truncated.post_err = "truncated archive"
    env = new_env("1.1.0", truncated)
    ok, err = env.install()
    expect(ok == nil and contains(err, "truncated archive"), "archive read error reported")
    expect_untouched(env, "truncated archive")

    env = new_env("1.1.0", plugin_archive("1.0.9"))
    ok, err = env.install()
    expect(ok == nil and contains(err, "structure or version is invalid"), "version mismatch rejected")
    expect_untouched(env, "version mismatch")

    local no_main = plugin_archive("1.1.0")
    table.remove(no_main.entries, 3)
    env = new_env("1.1.0", no_main)
    ok, err = env.install()
    expect(ok == nil and contains(err, "structure or version is invalid"), "package without main.lua rejected")
    expect_untouched(env, "missing main.lua")

    env = new_env()
    make_path_error = "permission denied"
    ok, err = env.install()
    make_path_error = nil
    expect(ok == nil and contains(err, "cannot create staging directory")
        and contains(err, "permission denied") and #requests == 0, "staging failure reported before downloading")

    -- Without util.makePath the staging directory is created through lfs.
    local util = package.loaded["util"]
    package.loaded["util"] = nil
    package.preload["util"] = function() error("module 'util' not found") end
    env = new_env()
    ok, err = env.install()
    expect(ok == true and err == nil and read_file(env.plugin_dir .. ".backup/marker.txt") == "old",
        "install works with the lfs fallback: " .. tostring(err))
    env = new_env()
    sh("rm -rf " .. quote(env.data_dir))
    ok, err = env.install()
    expect(ok == nil and contains(err, "cannot create staging directory") and contains(err, "mkdir failed"),
        "lfs fallback failure reported")
    expect(read_file(env.plugin_dir .. "/marker.txt") == "old", "plugin untouched when staging fails")
    package.preload["util"] = nil
    package.loaded["util"] = util
end

do
    -- Activation failure restores the previous plugin from the backup.
    local real_rename = os.rename
    local env = new_env()
    os.rename = function(from, to) -- luacheck: ignore 122
        if from == env.data_dir .. "/update-stage/weread.koplugin" then return nil, "simulated EXDEV" end
        return real_rename(from, to)
    end
    local ok, err = env.install()
    os.rename = real_rename -- luacheck: ignore 122
    expect(ok == nil and contains(err, "simulated EXDEV"), "activation failure reported")
    expect_untouched(env, "activation failure")
    expect(env.progress[#env.progress].stage == "installing", "no completion reported after a rollback")

    -- Backup failure: nothing is moved.
    env = new_env()
    os.rename = function(from, to) -- luacheck: ignore 122
        if from == env.plugin_dir then return nil, "simulated EBUSY" end
        return real_rename(from, to)
    end
    ok, err = env.install()
    os.rename = real_rename -- luacheck: ignore 122
    expect(ok == nil and contains(err, "simulated EBUSY"), "backup failure reported")
    expect_untouched(env, "backup failure")
end

-- cleanup_backup ---------------------------------------------------------------------

do
    local env = new_env()
    write_file(env.plugin_dir .. ".backup/marker.txt", "old")
    local ok, err = env.updater:cleanup_backup()
    expect(ok == true and err == nil and not exists(env.plugin_dir .. ".backup"),
        "backup removed once the running version is installed")

    write_file(env.plugin_dir .. ".backup/marker.txt", "old")
    local purge = package.loaded["ffi/util"].purgeDir
    package.loaded["ffi/util"].purgeDir = function() error("device busy") end
    ok, err = env.updater:cleanup_backup()
    expect(ok == nil and contains(tostring(err), "device busy"), "backup removal failure reported")
    package.loaded["ffi/util"].purgeDir = nil
    ok, err = env.updater:cleanup_backup()
    expect(ok == nil and contains(err, "cleanup unavailable") and exists(env.plugin_dir .. ".backup"),
        "missing cleanup support reported and the backup kept")
    package.loaded["ffi/util"].purgeDir = purge

    -- An oversized _meta.lua is not trusted as a version source.
    write_file(env.plugin_dir .. "/_meta.lua", 'return { version = "9.9.9" }\n' .. string.rep("-", 70000))
    expect(env.updater:installed_version() == nil and not env.updater:restart_pending(),
        "an oversized _meta.lua is ignored")
end

sh("rm -rf " .. quote(root))
expect(not exists(root), "temporary tree removed")

print(("updater_install_spec: %d checks passed"):format(checks))
