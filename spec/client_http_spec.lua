-- HTTP layer of weread.lib.client: request construction, credential scoping,
-- timeouts, redirects, error reporting, file downloads and cookie renewal.
-- LuaSocket is faked (spec/helpers/client_http_fake.lua); cookie and protocol
-- are the real modules. Error texts are matched by substring only.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local Fake = require("spec.helpers.client_http_fake")
local fake = Fake.install()
local header = Fake.header

local Client = require("weread.lib.client")
local WeRead = require("weread.lib.protocol")

local function respond(response)
    fake.responses[#fake.responses + 1] = response
end

local function raises(fn, ...)
    local ok, err = pcall(fn, ...)
    return not ok, tostring(err)
end

local function timeouts_balanced(label)
    expect(not fake.timeout_active, label .. ": socket timeout left active")
    expect(fake.resets == #fake.timeouts, label .. ": set_timeout/reset_timeout unbalanced ("
        .. #fake.timeouts .. " set, " .. fake.resets .. " reset)")
end

local function read_file(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local data = handle:read("*a")
    handle:close()
    return data
end

local function write_file(path, data)
    local handle = assert(io.open(path, "wb"))
    handle:write(data)
    handle:close()
end

local settings = Fake.settings({ cookies = { wr_skey = "XXX-skey-12345", wr_vid = "42" } })
local client = Client:new(settings)

-- request(): defaults ---------------------------------------------------------
do
    fake.reset()
    respond({ code = 200, body = "plain" })
    local text, code, headers, status = client:request({ url = "https://weread.qq.com/web/a" })
    expect(text == "plain" and code == 200 and type(headers) == "table" and status == nil,
        "GET result was not returned")
    local req = fake.requests[1]
    expect(req.method == "GET" and req.body == nil and req.redirect == false,
        "body-less request must be a GET with LuaSocket redirects disabled")
    expect(header(req.headers, "User-Agent") == WeRead.USER_AGENT
        and header(req.headers, "Accept") == "application/json, text/plain, */*",
        "default User-Agent/Accept missing")
    expect(header(req.headers, "Content-Length") == nil, "GET carried a Content-Length")
    expect(header(req.headers, "Cookie") == "wr_skey=XXX-skey-12345; wr_vid=42",
        "WeRead cookies were not attached in sorted order")
    expect(req.timeout_active and req.timeout[1] == 15 and req.timeout[2] == -1,
        "default 15 s block timeout was not active during the request")
    timeouts_balanced("default request")
end

-- request(): body, timeouts and header overrides
do
    fake.reset()
    respond({ code = 201, body = "" })
    respond({ code = 200, body = "" })
    respond({ code = 200, body = "" })
    client:request({ url = "https://weread.qq.com/web/p", body = "abc=1", timeout = 4 })
    client:request({ url = "https://weread.qq.com/web/p", timeout = { 6 } })
    client:request({ url = "https://weread.qq.com/web/p", method = "PUT",
        headers = { accept = "text/csv", ["X-Extra"] = "1" } })
    local post, single, custom = fake.requests[1], fake.requests[2], fake.requests[3]
    expect(post.method == "POST" and post.body == "abc=1"
        and header(post.headers, "Content-Length") == "5",
        "body did not turn the request into a POST with Content-Length")
    expect(post.timeout[1] == 4 and post.timeout[2] == -1, "numeric timeout was not used as block timeout")
    expect(single.timeout[1] == 6 and single.timeout[2] == 6,
        "single-element timeout table must reuse the block timeout as total timeout")
    local accept, accept_count = header(custom.headers, "Accept")
    expect(custom.method == "PUT" and accept == "text/csv" and accept_count == 1
        and custom.headers["X-Extra"] == "1",
        "caller headers must replace defaults case-insensitively without duplicates")
    timeouts_balanced("timeout variants")
end

-- request(): credentials only go to WeRead hosts, and only over https
do
    fake.reset()
    local urls = {
        { "https://i.weread.qq.com:443/api", true },
        { "http://WEREAD.QQ.COM/web", false },
        { "https://weread.qq.com.evil.example/steal", false },
        { "https://evilweread.qq.com/steal", false },
        { "https://weread.qq.com@evil.example/steal", false },
        { "https://cdn.example.net/weread.qq.com/", false },
        { "not a url", false },
    }
    for _, case in ipairs(urls) do
        respond({ code = 200, body = "" })
        client:request({ url = case[1] })
    end
    for index, case in ipairs(urls) do
        local cookie = header(fake.requests[index].headers, "Cookie")
        expect((cookie ~= nil) == case[2], "cookie scoping wrong for " .. case[1])
    end
    respond({ code = 200, body = "" })
    client:request({ url = "https://weread.qq.com/web/a", skip_cookie = true })
    expect(header(fake.requests[#fake.requests].headers, "Cookie") == nil, "skip_cookie still sent cookies")

    -- Credential headers passed by the caller are dropped (and logged) for a
    -- non-https URL, and kept for https.
    respond({ code = 200, body = "" })
    client:request({ url = "http://weread.qq.com/web/a", headers = {
        Authorization = "Bearer XXX-token", Cookie = "wr_vid=XXX-explicit", ["X-Skey"] = "XXX-skey", Accept = "a/b",
    } })
    local plain = fake.requests[#fake.requests].headers
    expect(header(plain, "Authorization") == nil and header(plain, "Cookie") == nil and header(plain, "X-Skey") == nil,
        "explicit credential headers were sent over http")
    expect(header(plain, "Accept") == "a/b", "a non-credential header was dropped")
    expect(fake.log_text():find("HTTP credentials dropped", 1, true), "dropping credentials was not logged")
    respond({ code = 200, body = "" })
    client:request({ url = "https://weread.qq.com/web/a", headers = { Authorization = "Bearer XXX-token" } })
    expect(header(fake.requests[#fake.requests].headers, "Authorization") == "Bearer XXX-token",
        "https request lost its explicit credential header")

    local empty = Client:new(Fake.settings({ cookies = {} }))
    respond({ code = 200, body = "" })
    empty:request({ url = "https://weread.qq.com/web/a" })
    expect(header(fake.requests[#fake.requests].headers, "Cookie") == nil, "empty cookie jar produced a Cookie header")
end

-- request(): Set-Cookie persistence is scoped and can be suppressed
do
    fake.reset()
    settings.merged = {}
    respond({ code = 200, body = "", headers = { ["SET-COOKIE"] = "wr_skey=fresh; Path=/" } })
    respond({ code = 200, body = "", headers = { ["set-cookie"] = "wr_skey=evil" } })
    respond({ code = 200, body = "", headers = { ["set-cookie"] = "wr_skey=XXX-unconfirmed" } })
    respond({ code = 200, body = "", headers = { ["set-cookie"] = "wr_skey=XXX-unrequested" } })
    client:request({ url = "https://weread.qq.com/web/a" })
    client:request({ url = "https://cdn.example.net/a" })
    client:request({ url = "https://weread.qq.com/web/a", persist_response_cookies = false })
    client:request({ url = "https://weread.qq.com/web/a", skip_cookie = true })
    expect(#settings.merged == 1 and settings.merged[1] == "wr_skey=fresh; Path=/",
        "only WeRead responses with persistence enabled may update the cookie jar")
end

-- request(): HTTP errors are returned, transport failures raise; timeouts reset
do
    fake.reset()
    respond({ code = 502, body = "<html>Bad gateway</html>", headers = { ["Content-Type"] = "text/html" } })
    local text, code = client:request({ url = "https://weread.qq.com/web/a", diagnostic_api = "/probe" })
    expect(text == "<html>Bad gateway</html>" and code == 502, "4xx/5xx must be returned to the caller")
    expect(fake.requests[1].options.diagnostic_api == nil, "diagnostic_api leaked into LuaSocket options")
    local log = fake.log_text()
    expect(log:find("status= 502", 1, true) and log:find("api= /probe", 1, true)
        and log:find("Bad gateway", 1, true), "HTTP failure was not logged with status/api/body")

    fake.logs = {}
    respond({ fail = "timeout" })
    local _, missing_code, _, status = client:request({ url = "https://weread.qq.com/web/a" })
    expect(missing_code == nil and status == "timeout", "transport status must be surfaced when no HTTP code arrived")
    expect(fake.log_text():find("timeout", 1, true), "missing HTTP status was not logged")

    respond({ raise = "ssl handshake failed" })
    local raised, err = raises(client.request, client, { url = "https://weread.qq.com/web/a" })
    expect(raised and err:find("ssl handshake failed", 1, true), "transport exception was swallowed")
    timeouts_balanced("error paths")
end

-- request_follow(): relative locations, callback, same-origin credentials
do
    fake.reset()
    local hops = {}
    respond({ code = 302, body = "", headers = { Location = "next?x=1" } })
    respond({ code = 301, body = "", headers = { location = "/root" } })
    respond({ code = 200, body = "done" })
    local text, code, _, _, final_url = client:request_follow({
        url = "https://weread.qq.com/web/dir/start",
        headers = { Authorization = "Bearer keep" },
        on_redirect = function(from, to, status) hops[#hops + 1] = { from, to, status } end,
    })
    expect(text == "done" and code == 200 and final_url == "https://weread.qq.com/root",
        "redirect chain did not end at the resolved final URL")
    expect(fake.requests[2].url == "https://weread.qq.com/web/dir/next?x=1",
        "relative Location was not resolved against the current directory")
    expect(#hops == 2 and hops[1][1] == "https://weread.qq.com/web/dir/start"
        and hops[1][3] == 302 and hops[2][2] == "https://weread.qq.com/root",
        "on_redirect was not told about every hop")
    for index = 1, 3 do
        expect(header(fake.requests[index].headers, "Authorization") == "Bearer keep",
            "same-origin redirect dropped the Authorization header")
        expect(fake.requests[index].method == "GET", "GET changed method across 301/302")
        expect(fake.requests[index].options.on_redirect == nil, "on_redirect leaked into LuaSocket options")
    end
    timeouts_balanced("redirect chain")
end

-- request_follow(): cross-origin 307 keeps the body but drops credentials;
-- automatic cookies are rebuilt per destination
do
    fake.reset()
    respond({ code = 307, body = "", headers = { location = "https://upload.example.net/put" } })
    respond({ code = 308, body = "", headers = { location = "https://weread.qq.com/web/back" } })
    respond({ code = 200, body = "ok" })
    client:request_follow({
        url = "https://weread.qq.com/web/upload",
        method = "POST",
        body = "payload",
        headers = { Authorization = "Bearer s", Cookie = "manual=1", Origin = "https://weread.qq.com",
            ["X-Trace"] = "t1" },
    })
    local first, foreign, back = fake.requests[1], fake.requests[2], fake.requests[3]
    expect(header(first.headers, "Cookie") == "manual=1", "caller Cookie header was not used on the first hop")
    expect(foreign.method == "POST" and foreign.body == "payload",
        "307 must repeat the method and body")
    expect(header(foreign.headers, "Authorization") == nil and header(foreign.headers, "Cookie") == nil
        and header(foreign.headers, "Origin") == nil,
        "credentials leaked to a foreign origin")
    expect(foreign.headers["X-Trace"] == "t1" and header(foreign.headers, "Content-Length") == "7",
        "non-credential headers must survive a 307")
    expect(back.method == "POST" and header(back.headers, "Cookie") == "wr_skey=XXX-skey-12345; wr_vid=42",
        "returning to WeRead must rebuild the WeRead cookie, not reuse the stripped one")
    expect(header(back.headers, "Authorization") == nil, "stripped Authorization came back after the redirect")
end

-- request_follow(): 301/302 downgrade non-GET to GET; scheme change is cross-origin
do
    fake.reset()
    respond({ code = 302, body = "", headers = { location = "/after" } })
    respond({ code = 200, body = "" })
    client:request_follow({ url = "https://weread.qq.com/form", method = "POST", body = "a=1",
        headers = { ["content-length"] = "3" } })
    local after = fake.requests[2]
    expect(after.method == "GET" and after.body == nil and header(after.headers, "Content-Length") == nil,
        "302 after POST must become a body-less GET")

    respond({ code = 301, body = "", headers = { location = "http://weread.qq.com/plain" } })
    local refused = raises(client.request_follow, client,
        { url = "https://weread.qq.com/secure", headers = { Authorization = "Bearer s" } })
    expect(refused and #fake.requests == 3, "https -> http redirect must be refused, not followed")
end

-- request_follow(): redirect without Location and the redirect limit
do
    fake.reset()
    respond({ code = 302, body = "moved", headers = {} })
    local text, code, _, _, final_url = client:request_follow({ url = "https://weread.qq.com/x" })
    expect(text == "moved" and code == 302 and final_url == "https://weread.qq.com/x",
        "3xx without Location must be returned as-is")

    for _ = 1, 3 do respond({ code = 302, body = "", headers = { location = "/loop" } }) end
    local raised = raises(client.request_follow, client, { url = "https://weread.qq.com/loop", maxredirects = 2 })
    expect(raised and #fake.requests == 4, "maxredirects option was not enforced (requests=" .. #fake.requests .. ")")
    expect(#fake.responses == 0, "redirect loop issued the wrong number of requests")
    timeouts_balanced("redirect limit")
end

-- post_json()
do
    fake.reset()
    respond({ code = 200, body = fake.json({ succ = 1, value = "v" }), headers = { ["X-Id"] = "7" } })
    local data, code, headers = client:post_json("https://weread.qq.com/web/api", { a = 1 })
    local req = fake.requests[1]
    expect(data.value == "v" and code == 200 and headers["X-Id"] == "7", "post_json result was not decoded")
    expect(req.method == "POST" and req.body == "<encoded#1>" and fake.encoded[1].a == 1,
        "post_json did not send the JSON-encoded payload")
    expect(header(req.headers, "Content-Type") == "application/json;charset=UTF-8"
        and header(req.headers, "Origin") == "https://weread.qq.com"
        and header(req.headers, "Referer") == "https://weread.qq.com/"
        and header(req.headers, "Content-Length") == tostring(#"<encoded#1>"),
        "post_json headers were wrong")

    respond({ code = 200, body = fake.json({}) })
    client:post_json("https://weread.qq.com/web/api", {}, { headers = { referer = "https://weread.qq.com/r" } })
    local referer, count = header(fake.requests[2].headers, "Referer")
    expect(referer == "https://weread.qq.com/r" and count == 1, "caller Referer was not honoured exactly once")

    respond({ code = 500, body = fake.json({ errCode = -2012, errMsg = "login\nexpired" }),
        headers = { ["Content-Type"] = "application/json" } })
    local raised, err = raises(client.post_json, client, "https://weread.qq.com/web/api", {})
    expect(raised and err:find("HTTP 500", 1, true) and err:find("-2012", 1, true)
        and err:find("login expired", 1, true),
        "HTTP error lost the status or the server's errCode/errMsg: " .. err)

    respond({ code = 200, body = "{ not json" })
    fake.logs = {}
    raised, err = raises(client.post_json, client, "https://weread.qq.com/web/api", {})
    expect(raised and err:find("invalid JSON", 1, true), "JSON decode failure did not raise")
    expect(fake.log_text():find("not json", 1, true), "undecodable body was not logged")

    fake.logs = {}
    respond({ code = 200, body = fake.json({ succ = 0 }) })
    local failed = client:post_json("https://weread.qq.com/web/api", {})
    expect(failed.succ == 0 and fake.log_text():find("reported an error", 1, true),
        "succ=0 must be returned to the caller and logged")
    fake.logs = {}
    respond({ code = 200, body = fake.json({ errcode = "0", succ = true }) })
    client:post_json("https://weread.qq.com/web/api", {})
    expect(fake.log_text() == "", "a successful API response was logged as an error")
    timeouts_balanced("post_json")
end

-- get_text(): does not follow redirects
do
    fake.reset()
    respond({ code = 200, body = "<p>hi</p>" })
    local text = client:get_text("https://weread.qq.com/web/page")
    local req = fake.requests[1]
    expect(text == "<p>hi</p>" and req.method == "GET", "get_text result wrong")
    expect(header(req.headers, "Accept"):find("text/html", 1, true)
        and header(req.headers, "Referer") == "https://weread.qq.com/", "get_text default headers wrong")
    respond({ code = 200, body = "" })
    client:get_text("https://weread.qq.com/web/page", { accept = "application/json", referer = "https://weread.qq.com/x" })
    expect(header(fake.requests[2].headers, "Accept") == "application/json"
        and header(fake.requests[2].headers, "Referer") == "https://weread.qq.com/x", "get_text overrides ignored")

    respond({ code = 302, body = "", headers = { location = "https://weread.qq.com/login" } })
    local raised, err = raises(client.get_text, client, "https://weread.qq.com/web/page")
    expect(raised and err:find("HTTP 302", 1, true) and #fake.requests == 3,
        "get_text must report a redirect instead of following it")
end

-- get_public_text(): follows redirects, never sends WeRead cookies off-site
do
    fake.reset()
    respond({ code = 301, body = "", headers = { location = "/s?__biz=1" } })
    respond({ code = 200, body = "article", headers = { ["Content-Type"] = "text/html; charset=utf-8" } })
    local text, meta = client:get_public_text("https://mp.weixin.qq.com/s/abc")
    expect(text == "article" and meta.code == 200 and meta.length == 7
        and meta.content_type == "text/html; charset=utf-8"
        and meta.url == "https://mp.weixin.qq.com/s?__biz=1", "public text meta was wrong")
    for _, req in ipairs(fake.requests) do
        expect(header(req.headers, "Cookie") == nil, "WeRead cookie sent to mp.weixin.qq.com")
        expect(header(req.headers, "Referer") == "https://mp.weixin.qq.com/", "public default Referer wrong")
    end
    respond({ code = 200, body = "" })
    client:get_public_text("https://mp.weixin.qq.com/s/x", { headers = { REFERER = "https://a.example/" } })
    local referer, count = header(fake.requests[3].headers, "Referer")
    expect(referer == "https://a.example/" and count == 1, "public Referer override duplicated or ignored")

    respond({ code = 404, body = "gone" })
    local raised, err = raises(client.get_public_text, client, "https://mp.weixin.qq.com/s/missing")
    expect(raised and err:find("HTTP 404", 1, true), "public 404 did not raise with its code")
    respond({ fail = "closed" })
    raised, err = raises(client.get_public_text, client, "https://mp.weixin.qq.com/s/slow")
    expect(raised and err:find("closed", 1, true), "public transport status was lost: " .. err)
    timeouts_balanced("get_public_text")
end

-- get_binary()
do
    fake.reset()
    respond({ code = 302, body = "", headers = { location = "https://cdn.example.net/img.png" } })
    respond({ code = 200, chunks = { "\137PNG", "\0\1" }, headers = { ["content-type"] = "image/png" } })
    local data, code, headers = client:get_binary("https://weread.qq.com/cover")
    expect(data == "\137PNG\0\1" and code == 200 and headers["content-type"] == "image/png",
        "binary body was not reassembled")
    expect(header(fake.requests[1].headers, "Accept") == "*/*"
        and header(fake.requests[2].headers, "Cookie") == nil
        and header(fake.requests[2].headers, "Referer") == "https://weread.qq.com/",
        "binary redirect leaked cookies or lost headers")
    respond({ code = 403, body = "denied" })
    local raised, err = raises(client.get_binary, client, "https://cdn.example.net/x")
    expect(raised and err:find("HTTP 403", 1, true), "binary 403 did not raise with its code")
    respond({ code = 302, body = "", headers = {} })
    raised, err = raises(client.get_binary, client, "https://cdn.example.net/y")
    expect(raised and err:find("HTTP 302", 1, true), "redirect without Location was treated as success")
end

-- download_to_file()
do
    fake.reset()
    local dest = os.tmpname()
    local part = dest .. ".part"
    write_file(dest, "previous good copy")
    write_file(part, "stale partial from a crashed run")

    respond({ code = 302, body = "redirect page", headers = { location = "https://cdn.example.net/f" } })
    respond({ code = 200, chunks = { "hello ", "world" }, headers = { ETag = "e1" } })
    local path, bytes, headers = client:download_to_file("https://weread.qq.com/f", dest,
        { referer = "https://weread.qq.com/book", timeout = { 5, 60 } })
    expect(path == dest and bytes == 11 and headers.ETag == "e1", "download result wrong")
    expect(read_file(dest) == "hello world", "download did not replace the file with the final body only")
    expect(read_file(part) == nil, "download left its .part file behind")
    local first, second = fake.requests[1], fake.requests[2]
    expect(header(first.headers, "Accept") == "*/*" and header(first.headers, "Referer") == "https://weread.qq.com/book"
        and header(first.headers, "Cookie") ~= nil and header(second.headers, "Cookie") == nil,
        "download headers/credential scoping wrong")
    expect(first.timeout[1] == 5 and first.timeout[2] == 60, "download timeout not applied")
    expect(first.options.max_bytes == nil and first.options.referer == nil and first.options.accept == nil,
        "download-only options leaked into LuaSocket options")

    -- Failures must leave an existing good file untouched and no .part behind.
    local failures = {
        { label = "empty body", response = { code = 200, body = "" }, needle = "empty body" },
        { label = "HTTP 404", response = { code = 404, body = "not found" }, needle = "HTTP 404" },
        { label = "transport raise", response = { raise = "connection reset" }, needle = "connection reset" },
        { label = "transport status", response = { fail = "timeout" }, needle = "timeout" },
        { label = "size limit", response = { code = 200, chunks = { "abc", "def" } }, opts = { max_bytes = 4 },
            needle = "size limit" },
    }
    for _, case in ipairs(failures) do
        write_file(dest, "previous good copy")
        respond(case.response)
        local raised, err = raises(client.download_to_file, client, "https://weread.qq.com/f", dest, case.opts)
        expect(raised, case.label .. ": download did not fail")
        if case.needle then
            expect(err:find(case.needle, 1, true), case.label .. ": error lost its cause: " .. err)
        end
        expect(read_file(part) == nil, case.label .. ": .part file left behind")
        expect(read_file(dest) == "previous good copy", case.label .. ": existing file was clobbered")
    end

    respond({ code = 200, chunks = { "ab", "cd" } })
    local _, exact = client:download_to_file("https://weread.qq.com/f", dest, { max_bytes = 4 })
    expect(exact == 4 and read_file(dest) == "abcd", "body exactly at max_bytes was rejected")

    -- Commit failure (destination is a non-empty directory): no .part left.
    local dir = dest .. ".dir"
    assert(os.execute("mkdir '" .. dir .. "'"))
    write_file(dir .. "/keep", "k")
    respond({ code = 200, body = "data" })
    local commit_failed = raises(client.download_to_file, client, "https://weread.qq.com/f", dir)
    expect(commit_failed and read_file(dir .. ".part") == nil and read_file(dir .. "/keep") == "k",
        "failed commit must remove the .part file and leave the destination alone")
    os.remove(dir .. "/keep")
    os.remove(dir)

    local before = #fake.requests
    local raised = raises(client.download_to_file, client, "https://weread.qq.com/f", dest .. ".missing-dir/x/y")
    expect(raised and #fake.requests == before, "unwritable destination must fail before any request")
    timeouts_balanced("download_to_file")
    os.remove(dest)
    os.remove(part)
end

-- renew_cookie()
do
    fake.reset()
    local jar = { wr_skey = "XXX-old-skey-1", wr_gid = "gid-12" }
    local renew_settings = Fake.settings({ cookies = jar })
    local renewer = Client:new(renew_settings)
    respond({
        code = 200,
        body = fake.json({ succ = 1 }),
        headers = {
            ["Set-Cookie"] = "wr_skey=XXX-new-skey-1; Path=/; Domain=.weread.qq.com, wr_vid=99; HttpOnly, tracking=x",
            ["x-wr-ticket"] = { "ticket-1", "ticket-2" },
            ["X-WRPA-0"] = "wrpa-1",
        },
    })
    local result = renewer:renew_cookie()
    local req = fake.requests[1]
    expect(result.succ == 1, "renewal result not returned")
    expect(req.url == "https://weread.qq.com/web/login/renewal" and req.method == "POST"
        and header(req.headers, "Cookie") == "wr_gid=gid-12; wr_skey=XXX-old-skey-1",
        "renewal request must POST the current cookies to the renewal endpoint")
    expect(fake.encoded[1].rq == "%2Fweb%2Fbook%2Fread" and fake.encoded[1].ql == false, "renewal payload wrong")
    expect(#renew_settings.merged == 0, "renewal cookies were persisted before success was confirmed")
    local update = renew_settings.auth_updates[1]
    expect(#renew_settings.auth_updates == 1 and update.options.replace_cookies == true, "renewal did not replace auth")
    local cookies = update.credentials.cookies
    expect(cookies.wr_skey == "XXX-new-skey-1" and cookies.wr_vid == "99" and cookies.wr_gid == "gid-12"
        and cookies.tracking == nil and cookies.Path == nil and cookies.Domain == nil,
        "renewed cookie jar was merged incorrectly")
    expect(update.credentials.wr_ticket == "ticket-1" and update.credentials.wr_wrpa == "wrpa-1",
        "renewal ticket headers were not captured")

    -- Success without new credentials still records an (empty) update.
    respond({ code = 200, body = fake.json({ succ = true }), headers = { ["x-wr-ticket"] = {}, ["x-wrpa-0"] = "" } })
    renewer:renew_cookie()
    local bare = renew_settings.auth_updates[2].credentials
    expect(bare.cookies == nil and bare.wr_ticket == nil and bare.wr_wrpa == nil,
        "renewal invented credentials that the server did not send")

    -- Rejected renewals must not touch stored credentials.
    local skey_before = jar.wr_skey
    local rejected = {
        { code = 200, body = fake.json({ succ = 0, errCode = -2012 }), headers = { ["set-cookie"] = "wr_skey=bad" } },
        { code = 401, body = fake.json({ errCode = -2010 }), headers = { ["set-cookie"] = "wr_skey=bad" } },
        { raise = "network down" },
    }
    for index, response in ipairs(rejected) do
        respond(response)
        local raised, err = raises(renewer.renew_cookie, renewer)
        expect(raised, "rejected renewal " .. index .. " did not raise")
        if response.code == 401 then
            expect(err:find("HTTP 401", 1, true), "renewal HTTP error lost its code")
        end
        expect(#renew_settings.auth_updates == 2 and #renew_settings.merged == 0,
            "rejected renewal " .. index .. " changed stored credentials")
    end
    expect(jar.wr_skey == skey_before and jar.wr_skey ~= "bad", "rejected renewal mutated the live cookie jar")
    timeouts_balanced("renew_cookie")
end

-- gateway(): bearer auth, no cookies, payload shape
do
    fake.reset()
    local keyed = Client:new(Fake.settings({ api_key = "k-123", cookies = { wr_skey = "XXX-skey-12345" } }))
    respond({ code = 200, body = fake.json({ ok = true }) })
    local result = keyed:gateway("/book/info", { bookId = "b1" })
    local req = fake.requests[1]
    expect(result.ok == true and req.url == "https://i.weread.qq.com/api/agent/gateway", "gateway URL/result wrong")
    expect(header(req.headers, "Authorization") == "Bearer k-123" and header(req.headers, "Cookie") == nil,
        "gateway must use the API key and never the cookie jar")
    local payload = fake.encoded[1]
    expect(payload.api_name == "/book/info" and payload.bookId == "b1" and payload.skill_version == WeRead.SKILL_VERSION,
        "gateway payload wrong")
    respond({ code = 200, body = fake.json({}) })
    keyed:gateway("/x", { skill_version = "9.9" })
    expect(fake.encoded[2].skill_version == "9.9", "explicit skill_version was overridden")

    local unkeyed = Client:new(Fake.settings({}))
    local raised = raises(unkeyed.gateway, unkeyed, "/book/info", {})
    expect(raised and #fake.requests == 2, "gateway without an API key must fail before sending")
end

-- test_mock_connection()
do
    fake.reset()
    respond({ code = 200, body = fake.json({ service = "weread-mock" }) })
    local endpoint = Client:test_mock_connection({ host = "192.168.1.5", port = 8765 })
    local req = fake.requests[1]
    expect(endpoint == "http://192.168.1.5:8765" and req.url == "http://192.168.1.5:8765/health"
        and req.proxy == endpoint, "mock probe must hit /health through the mock itself")
    expect(req.timeout[1] == 3 and req.timeout[2] == 3 and header(req.headers, "Cookie") == nil,
        "mock probe timeout/credentials wrong")
    respond({ code = 200, body = fake.json({ service = "something-else" }) })
    expect(raises(Client.test_mock_connection, Client, { host = "10.0.0.2", port = 80 }),
        "a non-mock service was accepted")
    respond({ code = 500, body = "" })
    expect(raises(Client.test_mock_connection, Client, { host = "10.0.0.2", port = 80 }),
        "a failing health check was accepted")
    expect(raises(Client.test_mock_connection, Client, { host = "8.8.8.8", port = 80 }) and #fake.requests == 3,
        "a public address must be rejected without probing it")
    timeouts_balanced("mock probe")
end

-- JSON backend selection: rapidjson fallback, and a clear failure without one
do
    local function reload(json_loader, rapidjson_loader)
        package.loaded["weread.lib.client"], package.loaded["json"], package.loaded["rapidjson"] = nil, nil, nil
        package.preload["json"], package.preload["rapidjson"] = json_loader, rapidjson_loader
        return require("weread.lib.client")
    end
    local function missing() error("module not installed") end

    fake.reset()
    local RapidClient = reload(missing, function()
        return {
            encode = function() return "rapid" end,
            decode = function(text) return { echoed = text } end,
        }
    end)
    respond({ code = 200, body = "{}" })
    local data = RapidClient:new(settings):post_json("https://weread.qq.com/web/api", {})
    expect(fake.requests[1].body == "rapid" and data.echoed == "{}", "rapidjson fallback was not used")

    local NoJsonClient = reload(missing, missing)
    local plain = NoJsonClient:new(settings)
    expect(raises(plain.post_json, plain, "https://weread.qq.com/web/api", {}) and #fake.requests == 1,
        "post_json without a JSON module must fail before sending")
    expect(raises(plain.json_decode, plain, "{}"), "json_decode without a JSON module did not fail")
end

print(("client_http_spec: %d checks"):format(checks))
