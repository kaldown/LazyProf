-- Modules/Recipes/Availability.lua
-- Checks recipe availability based on possession, source type, and AH listings
local ADDON_NAME, LazyProf = ...

LazyProf.RecipeAvailability = {}
local Availability = LazyProf.RecipeAvailability

-- Check if a recipe is available to obtain
-- Returns: isAvailable (boolean), sourceInfo (table or nil)
-- sourceInfo = { type = "learned|inventory|trainer|vendor|ah", ... }
function Availability:IsRecipeAvailable(recipe)
    -- TODO: Implement in subsequent tasks
    return true, nil
end

-- Get the recipe item ID from source data
-- For vendor/drop sources, this is the physical recipe item that teaches the spell
-- Returns: itemId (number or nil)
function Availability:GetRecipeItemId(recipe)
    if not recipe.source then
        return nil
    end

    -- Vendor and drop sources have itemId for the recipe item
    if recipe.source.itemId then
        return recipe.source.itemId
    end

    return nil
end

-- Find a recipe item in player's inventory (bags, bank, alts)
-- Returns: location info table or nil
-- location = { type = "bags|bank|alt", count = N, character = "Name" (for alts) }
function Availability:FindRecipeInInventory(itemId)
    if not itemId then
        return nil
    end

    -- Check bags first (always available)
    local bagCount = GetItemCount(itemId, false)  -- false = bags only
    if bagCount and bagCount > 0 then
        return { type = "bags", count = bagCount }
    end

    -- Check bank (requires Syndicator and setting enabled)
    if LazyProf.db.profile.includeBankItems then
        local bankItems = LazyProf.Inventory:ScanBank()
        if bankItems[itemId] and bankItems[itemId] > 0 then
            return { type = "bank", count = bankItems[itemId] }
        end
    end

    -- Check alts (requires Syndicator and setting enabled)
    if LazyProf.db.profile.includeAltCharacters then
        local _, itemsByCharacter = LazyProf.Inventory:ScanAlts()
        if itemsByCharacter[itemId] then
            -- Find first alt with this item
            for charName, count in pairs(itemsByCharacter[itemId]) do
                if count > 0 then
                    return { type = "alt", count = count, character = charName }
                end
            end
        end
    end

    return nil
end

-- Check if an item is listed on the Auction House
-- Returns: price (copper), source ("TSM"|"Auctionator") or nil, nil if not listed
function Availability:GetAHPrice(itemId)
    if not itemId then
        return nil, nil
    end

    -- Try TSM first (uses DBMinBuyout - nil means no listings)
    if TSM_API then
        local itemString = "i:" .. itemId
        local price = TSM_API.GetCustomPriceValue("DBMinBuyout", itemString)
        if price and price > 0 then
            return price, "TSM"
        end
    end

    -- Fallback to Auctionator
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local price = Auctionator.API.v1.GetAuctionPriceByItemID("LazyProf", itemId)
        if price and price > 0 then
            return price, "Auctionator"
        end
    end

    return nil, nil
end
