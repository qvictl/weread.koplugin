-- Turns a caught Lua error into text that is fit to show the user.
--
-- error(msg) with the default level prefixes the message with the raising
-- source position ("plugins/weread.koplugin/weread/lib/content.lua:1699: "),
-- and every error(e) re-raise adds another one. Raise user-facing errors with
-- error(msg, 0); this module strips any position that still slips through so
-- source paths never reach a dialog. Logs keep the raw error.
local ErrorText = {}

-- One leading "<chunk>:<line>: " position: a *.lua path (LuaJIT may shorten it
-- to ".../file.lua") or a loadstring chunk name ([string "..."]).
local POSITION_PATTERNS = {
    "^%s*[^%s]-%.lua:%d+:%s*",
    '^%s*%[string ".-"%]:%d+:%s*',
}

local function strip_one(text)
    for _i, pattern in ipairs(POSITION_PATTERNS) do
        local stripped, count = text:gsub(pattern, "", 1)
        if count > 0 then return stripped end
    end
    return nil
end

-- Remove every leading source position (re-raised errors stack them). Text
-- that is nothing but positions is returned unchanged, so a dialog never ends
-- up empty.
function ErrorText.strip_position(text)
    text = tostring(text)
    local result = text
    while true do
        local stripped = strip_one(result)
        if not stripped then break end
        result = stripped
    end
    if result == "" then return text end
    return result
end

-- First line of the error (worker errors carry a traceback), without source
-- positions, capped at 300 bytes.
function ErrorText.display(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    text = ErrorText.strip_position(text)
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

return ErrorText
