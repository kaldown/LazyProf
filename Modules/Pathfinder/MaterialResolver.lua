-- Modules/Pathfinder/MaterialResolver.lua
-- Craft or buy: for a reagent the shopping list needs, decides whether the
-- character makes it from its own reagents (e.g. smelt ore into bars) or buys
-- it. One level deep. Used by the shopping list only; path scoring always
-- uses market prices.
--
-- The decision per item:
--   an explicit choice ("craft" / "buy", set per character in the Shopping
--   tab) wins, under every strategy;
--   otherwise ("automatic") the material-resolution setting decides, as it
--   always has: never, when cheaper, or always - and only under the Cheapest
--   strategy (the caller passes the mode).
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.MaterialResolver = {}
local Resolver = LazyProf.MaterialResolver

-- Can this character craft the recipe? It can when the recipe is in the
-- learned-recipe list the profession window filled for that profession
-- (matched by profession key). When that list is empty - the profession
-- window was never opened on this character - fall back to the older guess:
-- the character has the profession and the recipe is trainer-taught.
function Resolver:CanCraft(recipeInfo)
    local profKey = recipeInfo and recipeInfo.professionKey
    local recipe = recipeInfo and recipeInfo.recipe
    if not (profKey and recipe) then return false end

    local cache = LazyProf.db and LazyProf.db.char and LazyProf.db.char.learnedRecipes
    local learned = cache and cache[profKey]
    if type(learned) == "table" and next(learned) ~= nil then
        return learned[recipe.id] and true or false
    end

    if (LazyProf.Client:PlayerSkill(profKey) or 0) <= 0 then
        return false
    end
    -- A trainer recipe that needs a specialization the character does not
    -- know is not one it can have learned (P121).
    if LazyProf.RecipeAvailability and LazyProf.RecipeAvailability:SpecializationBlocks(recipe) then
        return false
    end
    return (recipe.source and recipe.source.type == "trainer") or false
end

-- Recipes of the data that make an item and that this character can craft.
function Resolver:CraftOptions(itemId)
    local CraftLib = _G.CraftLib
    local options = {}
    if not (CraftLib and CraftLib.GetRecipeByProduct) then return options end
    for _, recipeInfo in ipairs(CraftLib:GetRecipeByProduct(itemId) or {}) do
        if self:CanCraft(recipeInfo) then
            options[#options + 1] = recipeInfo
        end
    end
    return options
end

local function BuyResult(prices, itemId, quantity, craftable)
    local buyCost = (prices[itemId] or 0) * quantity
    return {
        shouldCraft = false,
        craftable = craftable or false,
        craftRecipe = nil,
        sourceItems = {},
        craftCost = 0,
        buyCost = buyCost,
        effectiveCost = buyCost,
    }
end

-- Resolve a material: determine if it should be crafted or bought.
-- choice: "craft" | "buy" | nil (automatic: resolutionMode decides)
-- Returns: { shouldCraft, craftable, craftRecipe, professionKey, sourceItems,
--            craftCost, buyCost, effectiveCost, yield, craftsNeeded }
function Resolver:ResolveMaterial(itemId, quantity, inventory, prices, visitedSet, resolutionMode, choice)
    -- Default to cost-compare if not specified
    resolutionMode = resolutionMode or Constants.MATERIAL_RESOLUTION.COST_COMPARE

    -- Loop detection: a circular dependency falls back to buying
    visitedSet = visitedSet or {}
    if visitedSet[itemId] then
        return BuyResult(prices, itemId, quantity, false)
    end

    local options = self:CraftOptions(itemId)
    local craftable = #options > 0
    if not craftable then
        return BuyResult(prices, itemId, quantity, false)
    end

    -- What decides: the player's choice, else the setting.
    local mode = resolutionMode
    if choice == "buy" then
        mode = Constants.MATERIAL_RESOLUTION.NONE
    elseif choice == "craft" then
        mode = Constants.MATERIAL_RESOLUTION.ALWAYS_CRAFT
    end
    if mode == Constants.MATERIAL_RESOLUTION.NONE then
        return BuyResult(prices, itemId, quantity, true)
    end

    -- Find the cheapest recipe the player can craft
    local bestCraftOption = nil
    local bestCraftCost = math.huge

    for _, recipeInfo in ipairs(options) do
        local recipe = recipeInfo.recipe
        local yield = recipeInfo.yield or 1

        -- Calculate how many times we need to craft
        local craftsNeeded = math.ceil(quantity / yield)

        -- Calculate cost of source materials (single level, no recursion)
        local craftCost = 0
        local sourceItems = {}
        local usable = true

        for _, reagent in ipairs(recipe.reagents) do
            local reagentNeeded = reagent.count * craftsNeeded
            local reagentInInventory = inventory[reagent.itemId] or 0
            local reagentToBuy = math.max(0, reagentNeeded - reagentInInventory)
            local reagentPrice = prices[reagent.itemId] or 0
            local reagentCost = reagentPrice * reagentToBuy

            -- No price for a material that must be bought: the comparison
            -- cannot be made, so this recipe is skipped - unless the player
            -- said "I craft it", which needs no comparison.
            if reagentPrice == 0 and reagentToBuy > 0 and choice ~= "craft" then
                usable = false
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

        if usable and craftCost < bestCraftCost then
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

    -- No usable recipe found
    if not bestCraftOption then
        return BuyResult(prices, itemId, quantity, true)
    end

    -- Decide: craft or buy?
    local buyCost = (prices[itemId] or 0) * quantity
    local shouldCraft = false
    if mode == Constants.MATERIAL_RESOLUTION.ALWAYS_CRAFT then
        shouldCraft = true
    elseif mode == Constants.MATERIAL_RESOLUTION.COST_COMPARE then
        shouldCraft = bestCraftCost < buyCost
    end

    return {
        shouldCraft = shouldCraft,
        craftable = true,
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
function Resolver:GetEffectivePrice(itemId, inventory, prices, resolutionMode)
    local result = self:ResolveMaterial(itemId, 1, inventory, prices, {}, resolutionMode)

    -- Return effective per-unit cost
    if result.shouldCraft and result.craftsNeeded and result.yield then
        -- Cost per crafted item
        return result.craftCost / (result.craftsNeeded * result.yield)
    end

    return prices[itemId] or 0
end
