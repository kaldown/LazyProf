-- Modules/Pathfinder/Strategies/Fastest.lua
-- Optimizes for fewest crafts (fastest leveling), ignoring cost
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.PathfinderStrategies = LazyProf.PathfinderStrategies or {}

LazyProf.PathfinderStrategies.fastest = {
    name = "Fastest",

    -- Calculate optimal path from currentSkill to targetSkill
    Calculate = function(self, currentSkill, targetSkill, recipes, inventory, prices)
        local path = {}
        local simulatedSkill = currentSkill
        local simulatedInventory = Utils.DeepCopy(inventory)

        while simulatedSkill < targetSkill do
            -- Get craftable recipes that can still give skillups
            local candidates = self:GetCandidates(recipes, simulatedSkill)

            if #candidates == 0 then
                if LazyProf.Debug then LazyProf:Debug("No candidates at skill " .. simulatedSkill) end
                break
            end

            -- Score each by expected skillups per craft (higher = better = fewer crafts)
            local best, bestScore = Utils.MinBy(candidates, function(recipe)
                return self:ScoreRecipe(recipe, simulatedSkill, targetSkill)
            end)

            if not best then
                if LazyProf.Debug then LazyProf:Debug("No best recipe found at skill " .. simulatedSkill) end
                break
            end

            -- Calculate how many to craft
            local quantity = self:CalculateQuantity(best, simulatedSkill, targetSkill)
            local totalSkillups, totalCost = self:CalculateTotalCostAndSkillups(best, simulatedSkill, quantity, simulatedInventory, prices)

            -- Add step to path
            table.insert(path, {
                recipe = best,
                quantity = quantity,
                skillStart = simulatedSkill,
                skillEnd = math.min(simulatedSkill + totalSkillups, targetSkill),
                totalCost = totalCost,
            })

            -- Update simulation
            simulatedSkill = path[#path].skillEnd
            simulatedInventory = self:ConsumeReagents(simulatedInventory, best, quantity)
        end

        return path
    end,

    -- Get recipes that can be crafted and give skillups at current skill
    GetCandidates = function(self, recipes, currentSkill)
        local candidates = {}

        for _, recipe in ipairs(recipes) do
            -- Can learn/craft at current skill?
            if currentSkill >= recipe.skillRequired then
                -- Not gray yet?
                if currentSkill < recipe.skillRange.gray then
                    -- Check config for unlearned recipes
                    if recipe.learned or LazyProf.db.profile.suggestUnlearnedRecipes then
                        table.insert(candidates, recipe)
                    end
                end
            end
        end

        return candidates
    end,

    -- Score recipe: lower = better
    -- We want highest skillup chance, so return negative of expected skillups
    -- Orange (1.0) -> -1.0, Yellow (0.5) -> -0.5, Green (0.25) -> -0.25
    ScoreRecipe = function(self, recipe, currentSkill, targetSkill)
        local expected = self:GetExpectedSkillups(recipe, currentSkill)

        if expected <= 0 then
            return math.huge
        end

        -- Return negative so higher skillup chance = lower score = better
        -- Add small tiebreaker: prefer recipes that stay orange longer
        local orangeRange = recipe.skillRange.yellow - currentSkill
        local tiebreaker = -orangeRange / 1000

        return -expected + tiebreaker
    end,

    -- Calculate total cost and skillups for a given quantity
    CalculateTotalCostAndSkillups = function(self, recipe, currentSkill, quantity, inventory, prices)
        -- Calculate total cost (still track it for display)
        local totalCost = 0
        for _, reagent in ipairs(recipe.reagents) do
            local have = inventory[reagent.itemId] or 0
            local totalNeed = reagent.count * quantity
            local needToBuy = math.max(0, totalNeed - have)
            local price = prices[reagent.itemId] or 0
            totalCost = totalCost + (price * needToBuy)
        end

        -- Calculate total skillups
        local totalSkillups = 0
        local simSkill = currentSkill
        for i = 1, quantity do
            local expected = self:GetExpectedSkillups(recipe, simSkill)
            totalSkillups = totalSkillups + expected
            simSkill = simSkill + expected
        end

        return totalSkillups, totalCost
    end,

    -- Get expected skillups based on color
    GetExpectedSkillups = function(self, recipe, currentSkill)
        local color = Utils.GetSkillColor(currentSkill, recipe.skillRange)
        return Constants.SKILLUP_CHANCE[color] or 0
    end,

    -- Calculate how many crafts until gray or target reached
    CalculateQuantity = function(self, recipe, currentSkill, targetSkill)
        local quantity = 0
        local simSkill = currentSkill

        -- Craft until gray or target reached, max 100 iterations
        while simSkill < targetSkill and simSkill < recipe.skillRange.gray and quantity < 100 do
            quantity = quantity + 1
            local expected = self:GetExpectedSkillups(recipe, simSkill)
            simSkill = simSkill + expected
        end

        return math.max(1, quantity)
    end,

    -- Consume reagents from inventory
    ConsumeReagents = function(self, inventory, recipe, quantity)
        local inv = Utils.DeepCopy(inventory)

        for _, reagent in ipairs(recipe.reagents) do
            local consumed = reagent.count * quantity
            inv[reagent.itemId] = math.max(0, (inv[reagent.itemId] or 0) - consumed)
        end

        return inv
    end,
}
