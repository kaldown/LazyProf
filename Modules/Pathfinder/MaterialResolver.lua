-- Modules/Pathfinder/MaterialResolver.lua
-- Resolves intermediate materials (e.g., smelt ore into bars) for cost optimization
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.MaterialResolver = {}
local Resolver = LazyProf.MaterialResolver

-- Reference to CraftLib
local CraftLib = _G.CraftLib

-- Cache for player's known professions
local playerProfessions = nil

-- Get player's profession names (cached)
local function GetPlayerProfessions()
    if playerProfessions then return playerProfessions end

    playerProfessions = {}
    local prof1, prof2, archaeology, fishing, cooking, firstAid = GetProfessions()

    local function addProf(index)
        if index then
            local name = GetProfessionInfo(index)
            if name then
                playerProfessions[name:lower()] = true
            end
        end
    end

    addProf(prof1)
    addProf(prof2)
    addProf(archaeology)
    addProf(fishing)
    addProf(cooking)
    addProf(firstAid)

    return playerProfessions
end

-- Clear profession cache (call on login/profession change)
function Resolver:ClearCache()
    playerProfessions = nil
end

-- Check if player can likely craft this recipe
-- For v1, we assume trainer recipes are known if player has the profession
local function CanPlayerCraft(recipeInfo)
    local professions = GetPlayerProfessions()

    -- Check if player has this profession
    local profName = recipeInfo.professionKey
    if not profName then return false end

    -- Map profession keys to display names (CraftLib uses lowercase keys)
    local profDisplayName = profName:lower()
    if not professions[profDisplayName] then
        return false
    end

    -- For v1, we only handle trainer recipes (safe assumption player knows them)
    local recipe = recipeInfo.recipe
    if recipe.source and recipe.source.type then
        if recipe.source.type == "trainer" then
            return true
        end
    end

    -- Skip non-trainer recipes for v1 (drops, reputation, etc.)
    return false
end

-- Resolve a material: determine if it should be crafted or bought
-- Returns: { shouldCraft = bool, craftRecipe = recipe/nil, sourceItems = {}, craftCost = num, buyCost = num }
function Resolver:ResolveMaterial(itemId, quantity, inventory, prices, visitedSet, resolutionMode)
    -- Default to cost-compare if not specified
    resolutionMode = resolutionMode or Constants.MATERIAL_RESOLUTION.COST_COMPARE

    -- If mode is NONE, never craft
    if resolutionMode == Constants.MATERIAL_RESOLUTION.NONE then
        local buyCost = (prices[itemId] or 0) * quantity
        return {
            shouldCraft = false,
            craftRecipe = nil,
            sourceItems = {},
            craftCost = 0,
            buyCost = buyCost,
            effectiveCost = buyCost,
        }
    end

    -- Loop detection
    visitedSet = visitedSet or {}
    if visitedSet[itemId] then
        -- Circular dependency - fall back to buying
        local buyCost = (prices[itemId] or 0) * quantity
        return {
            shouldCraft = false,
            craftRecipe = nil,
            sourceItems = {},
            craftCost = 0,
            buyCost = buyCost,
            effectiveCost = buyCost,
        }
    end

    -- Check if CraftLib can tell us how to craft this item
    if not CraftLib or not CraftLib.GetRecipeByProduct then
        local buyCost = (prices[itemId] or 0) * quantity
        return {
            shouldCraft = false,
            craftRecipe = nil,
            sourceItems = {},
            craftCost = 0,
            buyCost = buyCost,
            effectiveCost = buyCost,
        }
    end

    local recipes = CraftLib:GetRecipeByProduct(itemId)
    if not recipes or #recipes == 0 then
        -- Item is not craftable
        local buyCost = (prices[itemId] or 0) * quantity
        return {
            shouldCraft = false,
            craftRecipe = nil,
            sourceItems = {},
            craftCost = 0,
            buyCost = buyCost,
            effectiveCost = buyCost,
        }
    end

    -- Find a recipe the player can craft
    local bestCraftOption = nil
    local bestCraftCost = math.huge

    for _, recipeInfo in ipairs(recipes) do
        if CanPlayerCraft(recipeInfo) then
            local recipe = recipeInfo.recipe
            local yield = recipeInfo.yield or 1

            -- Calculate how many times we need to craft
            local craftsNeeded = math.ceil(quantity / yield)

            -- Mark as visited to prevent loops
            visitedSet[itemId] = true

            -- Calculate cost of source materials
            local craftCost = 0
            local sourceItems = {}
            local canCraft = true

            for _, reagent in ipairs(recipe.reagents) do
                local reagentNeeded = reagent.count * craftsNeeded
                local reagentInInventory = inventory[reagent.itemId] or 0
                local reagentToBuy = math.max(0, reagentNeeded - reagentInInventory)

                -- For ALWAYS_CRAFT mode, we don't recursively resolve (v1 simplification)
                -- For COST_COMPARE mode, we also don't recurse in v1 (single level)
                local reagentPrice = prices[reagent.itemId] or 0
                local reagentCost = reagentPrice * reagentToBuy

                if reagentPrice == 0 and reagentToBuy > 0 then
                    -- Can't get price for required material, skip this recipe
                    canCraft = false
                    break
                end

                craftCost = craftCost + reagentCost
                table.insert(sourceItems, {
                    itemId = reagent.itemId,
                    name = reagent.name,
                    totalNeeded = reagentNeeded,
                    fromInventory = math.min(reagentInInventory, reagentNeeded),
                    toBuy = reagentToBuy,
                    cost = reagentCost,
                })
            end

            -- Clear visited
            visitedSet[itemId] = nil

            if canCraft and craftCost < bestCraftCost then
                bestCraftCost = craftCost
                bestCraftOption = {
                    recipe = recipe,
                    professionKey = recipeInfo.professionKey,
                    yield = yield,
                    craftsNeeded = craftsNeeded,
                    sourceItems = sourceItems,
                }
            end
        end
    end

    -- Calculate buy cost
    local buyCost = (prices[itemId] or 0) * quantity

    -- No craftable recipe found
    if not bestCraftOption then
        return {
            shouldCraft = false,
            craftRecipe = nil,
            sourceItems = {},
            craftCost = 0,
            buyCost = buyCost,
            effectiveCost = buyCost,
        }
    end

    -- Decide: craft or buy?
    local shouldCraft = false
    if resolutionMode == Constants.MATERIAL_RESOLUTION.ALWAYS_CRAFT then
        shouldCraft = true
    elseif resolutionMode == Constants.MATERIAL_RESOLUTION.COST_COMPARE then
        shouldCraft = bestCraftCost < buyCost
    end

    return {
        shouldCraft = shouldCraft,
        craftRecipe = bestCraftOption.recipe,
        professionKey = bestCraftOption.professionKey,
        yield = bestCraftOption.yield,
        craftsNeeded = bestCraftOption.craftsNeeded,
        sourceItems = bestCraftOption.sourceItems,
        craftCost = bestCraftCost,
        buyCost = buyCost,
        effectiveCost = shouldCraft and bestCraftCost or buyCost,
    }
end

-- Get effective price for a material (considering crafting)
-- This is the main entry point for the pricing system
function Resolver:GetEffectivePrice(itemId, inventory, prices, resolutionMode)
    local result = self:ResolveMaterial(itemId, 1, inventory, prices, {}, resolutionMode)

    -- Return effective per-unit cost
    if result.shouldCraft and result.craftsNeeded and result.yield then
        -- Cost per crafted item
        return result.craftCost / (result.craftsNeeded * result.yield)
    end

    return prices[itemId] or 0
end
