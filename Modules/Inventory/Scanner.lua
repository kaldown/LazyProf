-- Modules/Inventory/Scanner.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Inventory = {}
local Inventory = LazyProf.Inventory

-- ============================================================================
-- Layer 1: Source Providers
-- Each returns {[itemId] = count}
-- ============================================================================

-- Scan bags using native WoW API (no Syndicator dependency)
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

-- Scan bags from Syndicator character data (for alts)
function Inventory:ScanBagsSyndicator(charData)
    local items = {}
    if not charData or not charData.bags then return items end

    for _, bag in ipairs(charData.bags) do
        if bag then
            for _, slot in ipairs(bag) do
                if slot and slot.itemID then
                    items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                end
            end
        end
    end

    return items
end

-- Scan bank via Syndicator character data
function Inventory:ScanBank(charData)
    local items = {}
    if not charData then return items end

    -- Legacy bank bags
    if charData.bank then
        for _, bag in ipairs(charData.bank) do
            if bag then
                for _, slot in ipairs(bag) do
                    if slot and slot.itemID then
                        items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                    end
                end
            end
        end
    end

    -- Modern bank tabs
    if charData.bankTabs then
        for _, tab in ipairs(charData.bankTabs) do
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

-- Scan mail from Syndicator character data
function Inventory:ScanMail(charData)
    local items = {}
    if not charData or not charData.mail then return items end

    for _, mailItem in ipairs(charData.mail) do
        if mailItem and mailItem.itemID then
            items[mailItem.itemID] = (items[mailItem.itemID] or 0) + (mailItem.itemCount or 1)
        end
    end

    return items
end

-- Scan active auctions from Syndicator character data
function Inventory:ScanAuctions(charData)
    local items = {}
    if not charData or not charData.auctions then return items end

    for _, auction in ipairs(charData.auctions) do
        if auction and auction.itemID then
            items[auction.itemID] = (items[auction.itemID] or 0) + (auction.itemCount or 1)
        end
    end

    return items
end

-- Scan guild bank via Syndicator API
function Inventory:ScanGuildBank()
    local items = {}
    if not Syndicator or not Syndicator.API then return items end

    local guildName = Syndicator.API.GetCurrentGuild()
    if not guildName then return items end

    local guildData = Syndicator.API.GetByGuildFullName(guildName)
    if not guildData or not guildData.bank then return items end

    for _, tab in ipairs(guildData.bank) do
        if tab and tab.isViewable and tab.slots then
            for _, slot in ipairs(tab.slots) do
                if slot and slot.itemID then
                    items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                end
            end
        end
    end

    return items
end

-- ============================================================================
-- Layer 2: Aggregator
-- Orchestrates which sources to scan based on config, merges results
-- ============================================================================

-- Per-character sources scanned via Syndicator charData
local PER_CHAR_SOURCES = {
    { key = "bank",     configKey = "includeBankItems" },
    { key = "mail",     configKey = nil },  -- always on
    { key = "auctions", configKey = nil },  -- always on
}

-- Merge items from a source into combined inventory and sourceBreakdown
local function mergeSource(items, sourceKey, charName, combined, breakdown)
    for itemId, count in pairs(items) do
        combined[itemId] = (combined[itemId] or 0) + count

        if not breakdown[itemId] then
            breakdown[itemId] = {}
        end

        if charName then
            -- Alt character source
            if not breakdown[itemId].alts then
                breakdown[itemId].alts = {}
            end
            if not breakdown[itemId].alts[charName] then
                breakdown[itemId].alts[charName] = {}
            end
            breakdown[itemId].alts[charName][sourceKey] = (breakdown[itemId].alts[charName][sourceKey] or 0) + count
        else
            -- Current character or global source
            breakdown[itemId][sourceKey] = (breakdown[itemId][sourceKey] or 0) + count
        end
    end
end

-- Frame-level cache: ScanAll is called many times per frame (once per recipe in
-- GetCandidates). Cache results so only the first call per frame does real work.
local scanCache = { time = 0, combined = nil, breakdown = nil }

-- Scan all inventory sources based on settings
-- Returns: combinedInventory, sourceBreakdown
function Inventory:ScanAll()
    -- Return cached results if called again in the same frame
    local now = GetTime()
    if scanCache.combined and scanCache.time == now then
        return scanCache.combined, scanCache.breakdown
    end

    local combined = {}
    local breakdown = {}

    -- 1. Current character bags (native API, always on)
    local bagItems = self:ScanBags()
    mergeSource(bagItems, "bags", nil, combined, breakdown)

    local bagCount = 0
    for _ in pairs(bagItems) do bagCount = bagCount + 1 end
    LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in bags", bagCount))

    -- 2. Current character Syndicator sources (bank, mail, auctions)
    if Syndicator and Syndicator.API then
        local charName = Syndicator.API.GetCurrentCharacter()
        local charData = charName and Syndicator.API.GetByCharacterFullName(charName)

        if charData then
            for _, source in ipairs(PER_CHAR_SOURCES) do
                if not source.configKey or LazyProf.db.profile[source.configKey] then
                    local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                    local items = self[scanMethod](self, charData)
                    mergeSource(items, source.key, nil, combined, breakdown)

                    local count = 0
                    for _ in pairs(items) do count = count + 1 end
                    LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in %s", count, source.key))
                else
                    LazyProf:Debug("pathfinder", "Inventory scan: " .. source.key .. " disabled")
                end
            end
        end

        -- 3. Alt characters (if enabled)
        if LazyProf.db.profile.includeAltCharacters then
            local currentChar = Syndicator.API.GetCurrentCharacter()
            local allChars = Syndicator.API.GetAllCharacters()
            local totalAltItems = 0

            if allChars then
                for _, altName in ipairs(allChars) do
                    if altName ~= currentChar then
                        local altData = Syndicator.API.GetByCharacterFullName(altName)
                        if altData then
                            -- Bags
                            local altBags = self:ScanBagsSyndicator(altData)
                            mergeSource(altBags, "bags", altName, combined, breakdown)

                            -- Bank, mail, auctions (respecting config for bank)
                            for _, source in ipairs(PER_CHAR_SOURCES) do
                                if not source.configKey or LazyProf.db.profile[source.configKey] then
                                    local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                                    local items = self[scanMethod](self, altData)
                                    mergeSource(items, source.key, altName, combined, breakdown)
                                end
                            end

                            for itemId in pairs(altBags) do totalAltItems = totalAltItems + 1 end
                        end
                    end
                end
            end

            LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items from alts", totalAltItems))
        else
            LazyProf:Debug("pathfinder", "Inventory scan: alts disabled")
        end

        -- 4. Guild bank (if enabled)
        if LazyProf.db.profile.includeGuildBank then
            local guildItems = self:ScanGuildBank()
            mergeSource(guildItems, "guildBank", nil, combined, breakdown)

            local guildCount = 0
            for _ in pairs(guildItems) do guildCount = guildCount + 1 end
            LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in guild bank", guildCount))
        else
            LazyProf:Debug("pathfinder", "Inventory scan: guild bank disabled")
        end
    end

    scanCache.time = now
    scanCache.combined = combined
    scanCache.breakdown = breakdown

    return combined, breakdown
end

-- Invalidate the ScanAll cache (call when inventory changes mid-frame)
function Inventory:InvalidateCache()
    scanCache.time = 0
    scanCache.combined = nil
    scanCache.breakdown = nil
end

-- ============================================================================
-- Utility methods (unchanged)
-- ============================================================================

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
