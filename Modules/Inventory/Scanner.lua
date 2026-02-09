-- Modules/Inventory/Scanner.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Inventory = {}
local Inventory = LazyProf.Inventory

-- Scan bags and return item counts
function Inventory:ScanBags()
    local items = {}

    for bag = 0, 4 do
        local numSlots = C_Container and C_Container.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local itemId, count
            if C_Container then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info then
                    itemId = info.itemID
                    count = info.stackCount
                end
            else
                local _, itemCount, _, _, _, _, itemLink = GetContainerItemInfo(bag, slot)
                if itemLink then
                    itemId = tonumber(itemLink:match("item:(%d+)"))
                    count = itemCount
                end
            end

            if itemId and count then
                items[itemId] = (items[itemId] or 0) + count
            end
        end
    end

    return items
end

-- Scan bank via Syndicator API (requires Baganator addon)
function Inventory:ScanBank()
    if not Syndicator or not Syndicator.API then
        return {}
    end

    local items = {}
    local characterName = Syndicator.API.GetCurrentCharacter()
    if not characterName then
        return items
    end

    local character = Syndicator.API.GetByCharacterFullName(characterName)
    if not character then
        return items
    end

    -- Scan bank bags
    if character.bank then
        for _, bag in ipairs(character.bank) do
            if bag then
                for _, slot in ipairs(bag) do
                    if slot and slot.itemID then
                        items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                    end
                end
            end
        end
    end

    -- Scan bank tabs (newer bank system)
    if character.bankTabs then
        for _, tab in ipairs(character.bankTabs) do
            if tab and tab.slots then
                for _, slot in ipairs(tab.slots) do
                    if slot and slot.itemID then
                        items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                    end
                end
            end
        end
    end

    return items
end

-- Scan alt characters via Syndicator API
function Inventory:ScanAlts()
    if not Syndicator or not Syndicator.API then
        return {}, {}  -- items, itemsByCharacter
    end

    local items = {}
    local itemsByCharacter = {}  -- For UI: { [itemId] = { charName = count, ... } }
    local currentChar = Syndicator.API.GetCurrentCharacter()
    local allChars = Syndicator.API.GetAllCharacters()

    if not allChars then
        return items, itemsByCharacter
    end

    for _, charName in ipairs(allChars) do
        if charName ~= currentChar then
            local charData = Syndicator.API.GetByCharacterFullName(charName)
            if charData then
                -- Scan bags
                for _, bag in ipairs(charData.bags or {}) do
                    if bag then
                        for _, slot in ipairs(bag) do
                            if slot and slot.itemID then
                                local itemId = slot.itemID
                                local count = slot.itemCount or 1
                                items[itemId] = (items[itemId] or 0) + count

                                -- Track per-character for UI
                                itemsByCharacter[itemId] = itemsByCharacter[itemId] or {}
                                itemsByCharacter[itemId][charName] = (itemsByCharacter[itemId][charName] or 0) + count
                            end
                        end
                    end
                end

                -- Scan bank
                for _, bag in ipairs(charData.bank or {}) do
                    if bag then
                        for _, slot in ipairs(bag) do
                            if slot and slot.itemID then
                                local itemId = slot.itemID
                                local count = slot.itemCount or 1
                                items[itemId] = (items[itemId] or 0) + count

                                -- Track per-character for UI
                                itemsByCharacter[itemId] = itemsByCharacter[itemId] or {}
                                itemsByCharacter[itemId][charName] = (itemsByCharacter[itemId][charName] or 0) + count
                            end
                        end
                    end
                end
            end
        end
    end

    return items, itemsByCharacter
end

-- Scan all inventory sources based on settings
-- Returns: combinedInventory, bankInventory, altInventory, altItemsByCharacter
function Inventory:ScanAll()
    local items = self:ScanBags()
    local bankItems = {}
    local altItems = {}
    local altItemsByCharacter = {}

    -- Include bank in combined inventory for shopping list
    local bagCount = 0
    for _ in pairs(items) do bagCount = bagCount + 1 end
    LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in bags", bagCount))

    if LazyProf.db.profile.includeBankItems then
        bankItems = self:ScanBank()
        local bankCount = 0
        for _ in pairs(bankItems) do bankCount = bankCount + 1 end
        LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in bank", bankCount))
        for itemId, count in pairs(bankItems) do
            items[itemId] = (items[itemId] or 0) + count
        end
    else
        LazyProf:Debug("pathfinder", "Inventory scan: bank disabled")
    end

    -- Include alts for shopping list
    if LazyProf.db.profile.includeAltCharacters then
        altItems, altItemsByCharacter = self:ScanAlts()
        local altCount = 0
        for _ in pairs(altItems) do altCount = altCount + 1 end
        LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items from alts", altCount))
        for itemId, count in pairs(altItems) do
            items[itemId] = (items[itemId] or 0) + count
        end
    else
        LazyProf:Debug("pathfinder", "Inventory scan: alts disabled")
    end

    return items, bankItems, altItems, altItemsByCharacter
end

-- Get count of specific item in bags
function Inventory:GetItemCount(itemId)
    local items = self:ScanBags()
    return items[itemId] or 0
end

-- Check if we have enough materials for a recipe
function Inventory:HasMaterials(recipe, inventory)
    inventory = inventory or self:ScanBags()

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        if have < reagent.count then
            return false
        end
    end
    return true
end

-- Get missing materials for a recipe (quantity needed - quantity owned)
function Inventory:GetMissingMaterials(recipe, quantity, inventory)
    inventory = inventory or self:ScanBags()
    local missing = {}

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        local need = reagent.count * quantity
        local short = math.max(0, need - have)

        if short > 0 then
            table.insert(missing, {
                itemId = reagent.itemId,
                have = have,
                need = need,
                missing = short,
            })
        end
    end

    return missing
end
