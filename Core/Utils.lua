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

-- Skill-up probability: continuous linear interpolation from yellow to gray.
--
-- Formula: chance = (gray - effectiveSkill) / (gray - yellow), clamped to [0, 1]
--
-- This replaces the old flat model (orange=100%, yellow=50%, green=25%, gray=0%).
-- The real WoW formula is a smooth linear decline: 100% at the yellow threshold,
-- ~50% at the green threshold, and 0% at gray. No discrete color-band steps.
--
-- Source: Wowpedia "Profession" article, AzerothCore issue #14518,
--         Wowhead comment #479890 on spell 56462.
--
-- effectiveSkill: player's current skill minus any racial bonus (caller handles this)
-- skillRange: recipe's { orange, yellow, green, gray } threshold table
-- Returns: 0.0 to 1.0 (probability of gaining a skill point per craft)
function Utils.GetSkillUpChance(effectiveSkill, skillRange)
    local gray = skillRange.gray
    local yellow = skillRange.yellow

    -- Guard: degenerate recipe where yellow >= gray has no valid skillup range
    if yellow >= gray then
        return 0
    end

    local chance = (gray - effectiveSkill) / (gray - yellow)

    -- Clamp to [0, 1]:
    --   > 1.0 in orange range (effectiveSkill < yellow) -> 100%
    --   < 0.0 in gray range (effectiveSkill >= gray)    -> 0%
    return math.max(0, math.min(1, chance))
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

-- Get player faction ("Alliance" or "Horde")
function Utils.GetPlayerFaction()
    local _, race = UnitRace("player")
    local horde = { Orc = true, Troll = true, Tauren = true, Scourge = true, BloodElf = true }
    return horde[race] and "Horde" or "Alliance"
end

-- Get vendors filtered by faction (returns array)
function Utils.GetVendorsForFaction(source, faction, showAll)
    if not source or not source.vendors then return {} end
    if showAll then return source.vendors end

    local filtered = {}
    for _, vendor in ipairs(source.vendors) do
        if not vendor.faction or vendor.faction == faction or vendor.faction == "Neutral" then
            table.insert(filtered, vendor)
        end
    end
    return filtered
end

-- Count total vendors for a source
function Utils.GetVendorCount(source)
    if not source or not source.vendors then return 0 end
    return #source.vendors
end

-- Get Wowhead TBC URL for a spell
function Utils.GetWowheadUrl(spellId)
    return "https://www.wowhead.com/tbc/spell=" .. tostring(spellId)
end

-- Get human-readable description for recipe source (short version for list display)
function Utils.GetSourceDescription(source)
    if not source then return "Unknown" end

    local sourceType = source.type

    if sourceType == "trainer" then
        -- For trainers, show specific NPC if available, otherwise generic
        if source.npcName and source.npcName ~= "Any Cooking Trainer" then
            return source.npcName
        end
        return source.npcName or "Any Trainer"

    elseif sourceType == "vendor" then
        -- For vendors, show count or specific vendor if only one
        if source.vendors then
            local count = #source.vendors
            if count == 1 then
                local v = source.vendors[1]
                return v.npcName .. " (" .. v.location .. ")"
            else
                -- Filter by player faction for display count
                local playerFaction = Utils.GetPlayerFaction()
                local forFaction = Utils.GetVendorsForFaction(source, playerFaction, false)
                local factionCount = #forFaction
                if factionCount > 0 then
                    return factionCount .. " vendor" .. (factionCount > 1 and "s" or "")
                else
                    return count .. " vendor" .. (count > 1 and "s" or "") .. " (other faction)"
                end
            end
        end
        return source.npcName or "Vendor"

    elseif sourceType == "quest" then
        if source.questName then
            return "Quest: " .. source.questName
        end
        return "Quest"

    elseif sourceType == "drop" then
        if source.npcName then
            return "Drop: " .. source.npcName
        end
        return "World Drop"

    elseif sourceType == "world_drop" then
        return "World Drop"

    elseif sourceType == "reputation" then
        if source.factionName and source.level then
            return source.factionName .. " (" .. source.level .. ")"
        end
        return "Reputation"

    elseif sourceType == "discovery" then
        return "Discovery"
    end

    return sourceType or "Unknown"
end

-- Get detailed source info for side panel
function Utils.GetSourceDetails(source, showAllFactions)
    if not source then return nil end

    local details = {
        type = source.type,
        vendors = {},
        quest = nil,
        trainer = nil,
    }

    if source.type == "vendor" and source.vendors then
        local playerFaction = Utils.GetPlayerFaction()
        details.vendors = Utils.GetVendorsForFaction(source, playerFaction, showAllFactions)
        details.recipeItemId = source.itemId
        details.cost = source.cost

    elseif source.type == "quest" then
        details.quest = {
            id = source.questId,
            name = source.questName,
            location = source.location,
            faction = source.faction,
        }

    elseif source.type == "trainer" then
        details.trainer = {
            npcName = source.npcName,
            cost = source.trainingCost or source.cost,
            note = source.note,
        }
    end

    return details
end

-- Racial profession bonuses (TBC)
-- These bonuses extend how long recipes stay orange/yellow/green
local RACIAL_PROFESSION_BONUSES = {
    Gnome = { profession = "engineering", bonus = 15 },
    BloodElf = { profession = "enchanting", bonus = 10 },
    Draenei = { profession = "jewelcrafting", bonus = 5 },
}

-- Get racial profession bonus for current player and profession
-- Returns bonus amount (0 if no racial bonus applies)
function Utils.GetRacialProfessionBonus(professionKey)
    if not professionKey then return 0 end

    local _, race = UnitRace("player")
    local racialData = RACIAL_PROFESSION_BONUSES[race]

    if racialData and racialData.profession == professionKey:lower() then
        return racialData.bonus
    end

    return 0
end

-- Get player race name (for UI display)
function Utils.GetPlayerRace()
    local _, race = UnitRace("player")
    return race
end

-- Add combat lockdown handling to a frame.
-- Registers PLAYER_REGEN_DISABLED/ENABLED to auto-hide during combat and restore after.
-- Call once after the frame is created.
function Utils.AddCombatLockdown(frame)
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:HookScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if self:IsShown() then
                self._wasShownBeforeCombat = true
                self:Hide()
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if self._wasShownBeforeCombat then
                self._wasShownBeforeCombat = nil
                self:Show()
            end
        end
    end)
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
