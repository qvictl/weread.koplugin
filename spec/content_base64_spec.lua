-- The lookup-table base64 decoder must produce exactly what the original
-- bit-string decoder produced, for every input the content API can send.
-- Run with: luajit spec/content_base64_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end

local Content = require("weread.lib.content")
local decode = Content._base64_decode
expect(type(decode) == "function", "base64 decoder is not exposed for specs")

-- Verbatim copy of the decoder used up to v1.6.0 (weread/lib/content.lua).
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function old_base64_decode(data)
    data = data:gsub("-", "+"):gsub("_", "/")
    local pad = #data % 4
    if pad > 0 then
        data = data .. string.rep("=", 4 - pad)
    end
    data = data:gsub("[^" .. b64chars .. "=]", "")
    return (data:gsub(".", function(char)
        if char == "=" then
            return ""
        end
        local bits = ""
        local index = b64chars:find(char, 1, true) - 1
        for bit = 6, 1, -1 do
            bits = bits .. (index % 2 ^ bit - index % 2 ^ (bit - 1) > 0 and "1" or "0")
        end
        return bits
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
        if #bits ~= 8 then
            return ""
        end
        local byte = 0
        for i = 1, 8 do
            if bits:sub(i, i) == "1" then
                byte = byte + 2 ^ (8 - i)
            end
        end
        return string.char(byte)
    end))
end

local function encode(raw)
    local out = {}
    for index = 1, #raw, 3 do
        local a, b, c = raw:byte(index, index + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chunk = {
            b64chars:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1),
            b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1),
            b and b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=",
            c and b64chars:sub(n % 64 + 1, n % 64 + 1) or "=",
        }
        out[#out + 1] = table.concat(chunk)
    end
    return table.concat(out)
end

local function random_bytes(length)
    local bytes = {}
    for index = 1, length do bytes[index] = string.char(math.random(0, 255)) end
    return table.concat(bytes)
end

local stray = { " ", "\n", "\r\n", "\t", "=", "*", ".", "!", "\0", "\255", "\195\169", "==" }
local function sprinkle(text)
    local pieces = {}
    for index = 1, #text do
        pieces[#pieces + 1] = text:sub(index, index)
        if math.random() < 0.05 then pieces[#pieces + 1] = stray[math.random(#stray)] end
    end
    return table.concat(pieces)
end

local function same(input, label)
    local expected = old_base64_decode(input)
    local actual = decode(input)
    expect(actual == expected, ("%s: decoders disagree for %q"):format(label, input:sub(1, 80)))
end

math.randomseed(20261027)
same("", "empty")
same("====", "only padding")
same("A", "single char")
same("QQ", "two chars")
same("QUI", "three chars")
same("QUJD", "one quad")
same("QUJD\n", "trailing newline")
same("Q=UJD", "padding in the middle")
for _i = 1, 400 do
    local raw = random_bytes(math.random(0, 200))
    local standard = encode(raw)
    expect(decode(standard) == raw, "standard base64 did not round-trip")
    same(standard, "standard")
    local url_safe = standard:gsub("+", "-"):gsub("/", "_")
    same(url_safe, "url-safe")
    same((url_safe:gsub("=", "")), "url-safe without padding")
    same((standard:gsub("=", "")), "missing padding")
    same(sprinkle(standard), "stray characters")
    same(sprinkle(url_safe), "url-safe with stray characters")
end
-- Arbitrary alphabet soup of every length, including lengths % 4 == 1.
local soup = b64chars .. "-_"
for length = 0, 64 do
    local chars = {}
    for index = 1, length do
        local pick = math.random(#soup)
        chars[index] = soup:sub(pick, pick)
    end
    same(table.concat(chars), "alphabet soup length " .. length)
end
-- Large input crosses the output chunk boundary several times.
local big_raw = random_bytes(100 * 1024 + 7)
local big = encode(big_raw)
expect(decode(big) == big_raw, "large input did not round-trip")
same((big:gsub("+", "-"):gsub("/", "_")), "large url-safe input")

-- The new decoder must not produce the old one's ~46x garbage.
collectgarbage("collect")
collectgarbage("stop")
local before = collectgarbage("count")
decode(big)
local new_kb = collectgarbage("count") - before
before = collectgarbage("count")
old_base64_decode(big)
local old_kb = collectgarbage("count") - before
collectgarbage("restart")
expect(new_kb * 5 < old_kb, ("new decoder allocated %.0f KB vs old %.0f KB"):format(new_kb, old_kb))

print(("content_base64_spec: %d checks (alloc new=%.0f KB old=%.0f KB)"):format(checks, new_kb, old_kb))
