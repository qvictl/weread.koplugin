-- A chapter worker reads the accepted state through overlays and returns only
-- its writes. The parent applies them after its account/cancellation checks.
local M = {}

local function copy(values)
    if not values then return nil end
    local result = {}
    for key, value in pairs(values) do result[key] = value end
    return result
end

local function tracked_map(original)
    local map = { original = original, writes = {}, touched = {} }
    map.proxy = setmetatable({}, {
        __index = function(_, key)
            if map.touched[key] then return map.writes[key] end
            return original and original[key]
        end,
        __newindex = function(_, key, value)
            map.touched[key], map.writes[key] = true, value
        end,
    })
    return map
end

local function changes(map)
    local result
    for key in pairs(map.touched) do
        local value = map.writes[key]
        local previous = map.original and map.original[key]
        if value ~= previous then
            result = result or {}
            if value == nil then
                result.remove = result.remove or {}
                result.remove[#result.remove + 1] = key
            else
                result.set = result.set or {}
                result.set[key] = value
            end
        end
    end
    return result
end

local function nested_changes(map)
    if map.current == map.proxy then return changes(map) end
    if map.current == nil then
        if map.original ~= nil then return { clear = true } end
        return nil
    end
    -- Content replaces the bounded suffix cache when full. Merging that
    -- replacement would resurrect evicted cursors and defeat the bound.
    return { replace = true, set = copy(map.current) }
end

function M.begin(parent)
    local original = parent.used_asset_names
    local names = tracked_map(original)
    local nested = {}
    for _, key in ipairs({ "__remote_image_hrefs", "__next_asset_suffix" }) do
        local map = tracked_map(original and original[key])
        map.current = map.original and map.proxy or nil
        nested[key] = map
    end
    local metatable = getmetatable(names.proxy)
    local read, write = metatable.__index, metatable.__newindex
    metatable.__index = function(object, key)
        local map = nested[key]
        if map then return map.current end
        return read(object, key)
    end
    metatable.__newindex = function(object, key, value)
        local map = nested[key]
        if map then
            -- Keep nil as an explicit reset: falling through to the old map
            -- here would undo Content's resource-extraction rollback.
            map.current = value
        else write(object, key, value) end
    end
    local css = parent.css
    local child = {
        css = css,
        workspace = copy(parent.workspace),
        used_asset_names = names.proxy,
    }
    return child, function()
        local delta = { names = changes(names) }
        if child.css ~= css then delta.css = { value = child.css } end
        delta.remote_images = nested_changes(nested.__remote_image_hrefs)
        delta.asset_suffixes = nested_changes(nested.__next_asset_suffix)
        return delta
    end
end

local function apply_map(original, delta)
    if delta.clear then return nil end
    local result = delta.replace and {} or original or {}
    for key, value in pairs(delta.set or {}) do result[key] = value end
    for _, key in ipairs(delta.remove or {}) do result[key] = nil end
    return result
end

function M.apply(parent, delta)
    if delta.css then parent.css = delta.css.value end
    if delta.names or delta.remote_images or delta.asset_suffixes then
        local names = parent.used_asset_names or {}
        if delta.names then names = apply_map(names, delta.names) end
        if delta.remote_images then
            names.__remote_image_hrefs = apply_map(names.__remote_image_hrefs, delta.remote_images)
        end
        if delta.asset_suffixes then
            names.__next_asset_suffix = apply_map(names.__next_asset_suffix, delta.asset_suffixes)
        end
        parent.used_asset_names = names
    end
    return parent
end

return M
