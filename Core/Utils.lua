-- Core/Utils.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Utils = {}
local Utils = LazyProf.Utils

-- Deep copy a table
function Utils.DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for k, v in pairs(orig) do
            copy[Utils.DeepCopy(k)] = Utils.DeepCopy(v)
        end
        setmetatable(copy, Utils.DeepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- Sum values in a table by key
function Utils.Sum(tbl, key)
    local total = 0
    for _, v in ipairs(tbl) do
        total = total + (v[key] or 0)
    end
    return total
end

-- Filter table by predicate
function Utils.Filter(tbl, predicate)
    local result = {}
    for _, v in ipairs(tbl) do
        if predicate(v) then
            table.insert(result, v)
        end
    end
    return result
end

-- Find minimum by scorer function
function Utils.MinBy(tbl, scorer)
    local minItem, minScore = nil, math.huge
    for _, item in ipairs(tbl) do
        local score = scorer(item)
        if score < minScore then
            minItem, minScore = item, score
        end
    end
    return minItem, minScore
end

-- Format copper as gold string
function Utils.FormatMoney(copper)
    if not copper or copper == 0 then
        return "0c"
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100

    local str = ""
    if gold > 0 then str = str .. gold .. "g " end
    if silver > 0 then str = str .. silver .. "s " end
    if cop > 0 or str == "" then str = str .. cop .. "c" end
    return str:trim()
end

-- Get skill color based on current skill vs recipe ranges
function Utils.GetSkillColor(currentSkill, skillRange)
    if currentSkill < skillRange.orange then
        return "orange"
    elseif currentSkill < skillRange.yellow then
        return "orange"
    elseif currentSkill < skillRange.green then
        return "yellow"
    elseif currentSkill < skillRange.gray then
        return "green"
    else
        return "gray"
    end
end

-- Check if table contains value
function Utils.Contains(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end

-- Get item info with caching
local itemCache = {}
function Utils.GetItemInfo(itemId)
    if itemCache[itemId] then
        return unpack(itemCache[itemId])
    end
    local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
    if name then
        itemCache[itemId] = {name, link, icon}
        return name, link, icon
    end
    return nil
end
