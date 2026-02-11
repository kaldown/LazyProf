-- Modules/Recipes/Availability.lua
-- Checks recipe availability based on possession, source type, and AH listings
local ADDON_NAME, LazyProf = ...

LazyProf.RecipeAvailability = {}
local Availability = LazyProf.RecipeAvailability

-- Check if a recipe is available to obtain
-- Returns: isAvailable (boolean), sourceInfo (table or nil)
-- sourceInfo contains details for tooltip display
function Availability:IsRecipeAvailable(recipe)
    -- 1. Already learned - always available
    if recipe.learned then
        return true, { type = "learned" }
    end

    -- 2. Check if we have the recipe item in inventory
    local recipeItemId = self:GetRecipeItemId(recipe)
    if recipeItemId then
        local location = self:FindRecipeInInventory(recipeItemId)
        if location then
            return true, {
                type = "inventory",
                location = location,
                itemId = recipeItemId
            }
        end
    end

    -- 3. Check source-based availability
    local source = recipe.source
    if not source then
        -- No source data - can't determine availability
        return false, nil
    end

    -- Trainer recipes - always available if requirements met
    if source.type == "trainer" then
        if self:MeetsTrainerRequirements(source) then
            return true, {
                type = "trainer",
                cost = source.trainingCost or source.cost,
                npcName = source.npcName
            }
        end
        -- Doesn't meet requirements, fall through to check AH
    end

    -- Vendor recipes - always available (player can travel)
    if source.type == "vendor" then
        return true, {
            type = "vendor",
            cost = source.cost,
            vendors = source.vendors,
            itemId = source.itemId
        }
    end

    -- 4. Quest/Rep/Drop/World Drop - check AH
    if recipeItemId then
        local ahPrice, ahSource = self:GetAHPrice(recipeItemId)
        if ahPrice then
            return true, {
                type = "ah",
                price = ahPrice,
                source = ahSource,
                itemId = recipeItemId
            }
        end
    end

    -- 5. Not available
    return false, nil
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

-- Find a recipe item in player's inventory (bags, bank, mail, alts, etc.)
-- Returns: location info table or nil
-- location = { type = "bags|bank|mail|alt", count = N, character = "Name" (for alts) }
function Availability:FindRecipeInInventory(itemId)
    if not itemId then
        return nil
    end

    -- Use ScanAll to check all enabled sources at once
    local combined, sourceBreakdown = LazyProf.Inventory:ScanAll()

    if not combined[itemId] or combined[itemId] <= 0 then
        return nil
    end

    -- Check sourceBreakdown to find WHERE the item is
    local bd = sourceBreakdown[itemId]
    if not bd then
        return nil
    end

    -- Return the first source that has the item (priority order)
    if (bd.bags or 0) > 0 then
        return { type = "bags", count = bd.bags }
    end
    if (bd.bank or 0) > 0 then
        return { type = "bank", count = bd.bank }
    end
    if (bd.mail or 0) > 0 then
        return { type = "mail", count = bd.mail }
    end
    if bd.alts then
        for charName, charSources in pairs(bd.alts) do
            local charTotal = 0
            for _, count in pairs(charSources) do
                charTotal = charTotal + count
            end
            if charTotal > 0 then
                return { type = "alt", count = charTotal, character = charName }
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

-- Check if player meets trainer requirements (faction, honor, reputation)
-- Currently simplified: returns true for basic trainers
-- Returns: boolean
function Availability:MeetsTrainerRequirements(source)
    if not source then
        return false
    end

    -- Check faction requirement
    if source.faction then
        local playerFaction = UnitFactionGroup("player")
        if source.faction ~= playerFaction and source.faction ~= "Neutral" then
            return false
        end
    end

    -- Future: Check honor requirements
    -- Future: Check reputation requirements

    -- Basic trainer with no special requirements
    return true
end
