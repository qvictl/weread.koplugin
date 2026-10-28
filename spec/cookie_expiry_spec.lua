package.path = "./?.lua;./?/init.lua;" .. package.path

-- Set-Cookie parsing: Max-Age=0 and past Expires delete a cookie (Max-Age
-- wins over Expires), future dates keep it, the comma inside an Expires date
-- does not split the header, attributes are never stored as cookies, and only
-- WeRead / allowed names are kept.
local Cookie = require("weread.lib.cookie")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local NOW = 1800000000 -- 2027-01-15T08:00:00Z

expect(Cookie.parse_http_date("Wed, 21 Oct 2026 07:28:00 GMT") == 1792567680, "RFC 1123 date")
expect(Cookie.parse_http_date("Thursday, 01-Jan-70 00:00:00 GMT") == 0, "RFC 850 date with a 2-digit year")
expect(Cookie.parse_http_date("Sat, 29 Feb 2032 23:59:59 GMT") == 1961711999, "leap day")
expect(Cookie.parse_http_date("not a date") == nil and Cookie.parse_http_date(nil) == nil, "garbage date")

local function merge(start, header) return Cookie.merge_set_cookie(start, header, NOW) end

local c = merge({ wr_skey = "old" }, "wr_skey=new; Path=/; HttpOnly")
expect(c.wr_skey == "new", "plain update")
c = merge({ wr_skey = "old" }, "wr_skey=gone; Max-Age=0; Path=/")
expect(c.wr_skey == nil, "Max-Age=0 did not delete")
c = merge({ wr_skey = "old" }, "wr_skey=gone; max-age=-1")
expect(c.wr_skey == nil, "negative Max-Age did not delete")
c = merge({ wr_skey = "old" }, "wr_skey=gone; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/")
expect(c.wr_skey == nil, "past Expires did not delete")
c = merge({ wr_skey = "old" }, "wr_skey=kept; Expires=Wed, 21 Oct 2099 07:28:00 GMT")
expect(c.wr_skey == "kept", "future Expires deleted the cookie")
c = merge({ wr_skey = "old" }, "wr_skey=kept; Max-Age=3600; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
expect(c.wr_skey == "kept", "Max-Age must take precedence over Expires")
c = merge({ wr_skey = "old" }, "wr_skey=kept; Expires=someday")
expect(c.wr_skey == "kept", "unparseable Expires deleted the cookie")
c = merge({ wr_skey = "old" }, "wr_skey=; Path=/")
expect(c.wr_skey == nil, "empty value did not delete")

-- Out-of-range fields make a date invalid; an invalid Expires never deletes.
for _, bad in ipairs({ "Thu Jan  1 24:00:00 1970", "Thu, 01 Jan 1970 00:60:00 GMT",
        "Thu, 01 Jan 1970 00:00:60 GMT", "Thu, 32 Jan 1970 00:00:00 GMT", "Thu, 00 Jan 1970 00:00:00 GMT",
        "Fri, 29 Feb 2030 00:00:00 GMT", "Mon, 01 Jan 1600 00:00:00 GMT",
        "Thu, 01 Jan 1970 00:00:000 GMT", "Thu, 101 Jan 1970 00:00:00 GMT", "Thu Jan  1 00:00:00 19700" }) do
    expect(Cookie.parse_http_date(bad) == nil, "invalid date accepted: " .. bad)
    c = merge({ wr_skey = "old" }, "wr_skey=XXX-new; Expires=" .. bad)
    expect(c.wr_skey == "XXX-new", "invalid Expires deleted the cookie: " .. bad)
end

-- asctime dates, and attributes unknown to the parser stay on their cookie.
expect(Cookie.parse_http_date("Thu Jan  1 00:00:00 1970") == 0, "asctime date")
expect(Cookie.parse_http_date("Wed Oct 21 07:28:00 2026") == 1792567680, "asctime date with a 2-digit day")
c = merge({ wr_skey = "old" }, "wr_skey=gone; Expires=Thu Jan  1 00:00:00 1970")
expect(c.wr_skey == nil, "past asctime Expires did not delete")
c = merge({ wr_skey = "old" }, "wr_skey=new; Comment=ignored; Max-Age=0")
expect(c.wr_skey == nil and c.Comment == nil, "unknown attribute split the cookie from its Max-Age")
c = merge({ wr_skey = "old" }, "wr_skey=new; wr_vid=attr; Path=/")
expect(c.wr_skey == "new" and c.wr_vid == nil, "an attribute after ';' was stored as a cookie")

-- LuaSocket joins repeated Set-Cookie headers with ", ".
c = merge({ wr_skey = "a", wr_vid = "1", wr_name = "n" },
    "wr_skey=; Path=/, wr_vid=2; Max-Age=0, wr_name=x; Expires=Thu, 01 Jan 1970 00:00:00 GMT, "
    .. "wr_gid=abcde; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/; HttpOnly, other=1, ptcz=p")
expect(c.wr_skey == nil and c.wr_vid == nil and c.wr_name == nil, "joined deletions not applied")
expect(c.wr_gid == "abcde" and c.ptcz == "p", "joined updates not applied")
expect(c.other == nil and c.Path == nil and c.Expires == nil and c.path == nil, "foreign names or attributes stored")

-- Table form (several headers) and the default clock.
c = Cookie.merge_set_cookie({}, { "wr_a=1; Path=/", "wr_b=2; Max-Age=0" }, NOW)
expect(c.wr_a == "1" and c.wr_b == nil, "table form")
c = Cookie.merge_set_cookie({ wr_a = "1" }, "wr_a=2; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
expect(c.wr_a == nil, "default clock: 1970 is in the past")
expect(Cookie.merge_set_cookie(nil, "") == nil, "empty header returns the input")

print(string.format("cookie_expiry_spec: %d checks", checks))
