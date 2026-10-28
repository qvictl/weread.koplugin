-- weread.lib.cookie: Cookie header building, jar merging, Set-Cookie
-- parsing (allow-list, attributes, deletion) and login detection.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Cookie = require("weread.lib.cookie")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local function count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

-- to_header(): deterministic order, empty jars produce no header value
expect(Cookie.to_header({ wr_vid = "42", RK = "rk", wr_skey = "s" }) == "RK=rk; wr_skey=s; wr_vid=42",
    "Cookie header must be sorted name=value pairs")
expect(Cookie.to_header({}) == "" and Cookie.to_header(nil) == "", "empty jar must produce an empty header")

-- merge(): non-destructive, updates win
do
    local base = { wr_skey = "old", wr_vid = "1" }
    local merged = Cookie.merge(base, { wr_skey = "new", ptcz = "p" })
    expect(merged.wr_skey == "new" and merged.wr_vid == "1" and merged.ptcz == "p", "merge result wrong")
    expect(base.wr_skey == "old" and base.ptcz == nil and merged ~= base, "merge mutated its input")
    expect(count(Cookie.merge(nil, nil)) == 0 and Cookie.merge(nil, { a = "1" }).a == "1",
        "merge must tolerate nil jars")
end

-- merge_set_cookie(): no-op inputs return the jar unchanged
do
    local jar = { wr_skey = "s" }
    expect(Cookie.merge_set_cookie(jar, nil) == jar and Cookie.merge_set_cookie(jar, "") == jar,
        "empty Set-Cookie must return the same jar")
    expect(jar.wr_skey == "s" and count(jar) == 1, "empty Set-Cookie changed the jar")
    expect(Cookie.merge_set_cookie(nil, "") == nil, "empty Set-Cookie with no jar must stay nil")
end

-- merge_set_cookie(): attributes are not cookies; only WeRead/QQ names are kept
do
    local jar = { wr_gid = "gid-1" }
    local returned = Cookie.merge_set_cookie(jar,
        "wr_skey=abc123; Path=/; Domain=.weread.qq.com; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly; Secure")
    expect(returned == jar, "merge_set_cookie must update the jar in place")
    expect(jar.wr_skey == "abc123" and jar.wr_gid == "gid-1", "WeRead cookie not merged")
    expect(jar.Path == nil and jar.Domain == nil and jar.Expires == nil and count(jar) == 2,
        "cookie attributes were stored as cookies")

    Cookie.merge_set_cookie(jar,
        "ptcz=p1; Path=/, RK=rk1; Path=/, pgv_pvid=pv1, sessionid=leak, rk=lower, WR_SKEY=upper, wr_name=YWJj==")
    expect(jar.ptcz == "p1" and jar.RK == "rk1" and jar.pgv_pvid == "pv1", "allow-listed QQ cookies not merged")
    expect(jar.sessionid == nil and jar.rk == nil and jar.WR_SKEY == nil,
        "cookies outside the allow-list were stored")
    expect(jar.wr_name == "YWJj==", "cookie value containing '=' was truncated")
    expect(jar.wr_skey == "abc123", "a differently-cased name overwrote wr_skey")
end

-- merge_set_cookie(): empty values delete; LuaSocket header lists are merged in order
do
    local jar = { wr_skey = "s", wr_vid = "1", ptcz = "p" }
    Cookie.merge_set_cookie(jar, "wr_skey=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/")
    expect(jar.wr_skey == nil and jar.wr_vid == "1", "expired (empty) cookie was not removed")

    Cookie.merge_set_cookie(jar, { "wr_vid=2; Path=/", "wr_vid=3", "", "ptcz=" })
    expect(jar.wr_vid == "3" and jar.ptcz == nil, "list of Set-Cookie headers merged incorrectly")

    local fresh = Cookie.merge_set_cookie(nil, "wr_ticket=t\r\nwr_rt=r")
    expect(type(fresh) == "table" and fresh.wr_ticket == "t" and fresh.wr_rt == "r",
        "missing jar must be created; CR/LF must end a value")
end

-- has_login_cookie(): wr_skey (>= 8 chars) or wr_gid (>= 5 chars)
expect(Cookie.has_login_cookie({ wr_skey = "12345678" }) == true, "8-char wr_skey must count as logged in")
expect(not Cookie.has_login_cookie({ wr_skey = "1234567" }), "short wr_skey must not count as logged in")
expect(Cookie.has_login_cookie({ wr_skey = "short", wr_gid = "12345" }) == true, "wr_gid fallback ignored")
expect(not Cookie.has_login_cookie({ wr_gid = "1234" }), "short wr_gid counted as logged in")
expect(not Cookie.has_login_cookie({ wr_skey = 123456789, wr_gid = 123456 }), "non-string cookies counted")
expect(not Cookie.has_login_cookie({}) and not Cookie.has_login_cookie(nil), "empty jar counted as logged in")

print(("cookie_spec: %d checks"):format(checks))
