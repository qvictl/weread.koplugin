local Cookie = {}

function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        table.insert(parts, key .. "=" .. value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Cookie.merge(cookies, updates)
    local merged = {}
    for key, value in pairs(cookies or {}) do
        merged[key] = value
    end
    for key, value in pairs(updates or {}) do
        merged[key] = value
    end
    return merged
end

local ALLOWED = {
    ptcz = true,
    RK = true,
    pgv_pvid = true,
}

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }

-- Days since 1970-01-01 for a proleptic Gregorian date (no time zone involved).
local function days_from_civil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- HTTP dates -> UTC epoch seconds: IMF-fixdate "Wed, 21 Oct 2026 07:28:00 GMT",
-- RFC 850 "Wednesday, 21-Oct-26 07:28:00 GMT" and asctime "Wed Oct 21 07:28:00 2026".
function Cookie.parse_http_date(text)
    text = tostring(text or "")
    local d, mon, y, hh, mm, ss = text:match(
        "%f[%d](%d%d?)[ %-](%a%a%a)%a*[ %-](%d%d%d?%d?)%s+(%d%d?):(%d%d):(%d%d)%f[%D]")
    if not d then
        mon, d, hh, mm, ss, y = text:match(
            "(%a%a%a)%s+(%d%d?)%s+(%d%d?):(%d%d):(%d%d)%s+(%d%d%d%d)%f[%D]")
    end
    local month = mon and MONTHS[mon:lower()]
    if not month then return nil end
    y, d, hh, mm, ss = tonumber(y), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss)
    if y < 70 then y = y + 2000 elseif y < 100 then y = y + 1900 end
    -- Out-of-range fields make the date invalid (RFC 6265 5.1.1): an invalid
    -- Expires is ignored, it must not turn into a past date and delete a cookie.
    local month_days = { 31, (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28,
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if y < 1601 or d < 1 or d > month_days[month] or hh > 23 or mm > 59 or ss > 59 then
        return nil
    end
    return days_from_civil(y, month, d) * 86400 + hh * 3600 + mm * 60 + ss
end

-- Splits one Set-Cookie value (LuaSocket joins repeated headers with ", ")
-- into { name, value, max_age, expires } records.
local function parse_set_cookie(header)
    -- Within one cookie, attributes follow ";"; LuaSocket joins repeated
    -- Set-Cookie headers with ",". So a segment after ";" is always an
    -- attribute (known or not, e.g. "Comment=x"), and one after "," starts a
    -- new cookie unless it continues an Expires date ("Wed, 21 Oct ...").
    local cookies, current, last_attr = {}, nil, nil
    local text = tostring(header)
    local pos, delimiter = 1, ","
    while pos <= #text + 1 do
        local stop = text:find("[;,\r\n]", pos) or (#text + 1)
        local segment = text:sub(pos, stop - 1):match("^%s*(.-)%s*$")
        local name, value = segment:match("^([^=%s]+)%s*=%s*(.*)$")
        local attr = name and name:lower()
        if segment == "" then -- luacheck: ignore 542
            -- Empty segment (";;" or trailing ","): keep the previous context.
        elseif delimiter == "," and not name and last_attr == "expires" and current then
            current.expires = current.expires .. ", " .. segment
            last_attr = nil
        elseif delimiter == "," and name then
            current = { name = name, value = value }
            cookies[#cookies + 1] = current
            last_attr = nil
        elseif current and attr == "max-age" then
            current.max_age = tonumber(value)
            last_attr = attr
        elseif current and attr == "expires" then
            current.expires = value
            last_attr = attr
        else
            last_attr = attr
        end
        delimiter = text:sub(stop, stop)
        if delimiter == "\r" or delimiter == "\n" then delimiter = "," end
        pos = stop + 1
    end
    return cookies
end

-- A cookie is deleted by an empty value, Max-Age <= 0 or (without Max-Age,
-- which takes precedence) an Expires date that is not in the future.
local function is_deletion(cookie, now)
    if cookie.value == "" then return true end
    if cookie.max_age then return cookie.max_age <= 0 end
    if cookie.expires then
        local expires = Cookie.parse_http_date(cookie.expires)
        return expires ~= nil and expires <= now
    end
    return false
end

-- `now` (UTC epoch seconds) defaults to os.time(); specs pass a fixed value.
function Cookie.merge_set_cookie(cookies, set_cookie, now)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value, now)
        end
        return cookies
    end
    now = now or os.time()
    for _, cookie in ipairs(parse_set_cookie(set_cookie)) do
        local name = cookie.name
        if name:match("^wr_") or ALLOWED[name] then
            if is_deletion(cookie, now) then
                cookies[name] = nil
            else
                cookies[name] = cookie.value
            end
        end
    end
    return cookies
end

function Cookie.has_login_cookie(cookies)
    -- Modern WeRead uses wr_gid instead of wr_skey; fall back to wr_gid as the login credential.
    if cookies and type(cookies.wr_skey) == "string" and #cookies.wr_skey >= 8 then
        return true
    end
    return cookies and type(cookies.wr_gid) == "string" and #cookies.wr_gid >= 5
end

return Cookie
