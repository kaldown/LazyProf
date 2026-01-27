-- Modules/Pathfinder/Strategies/Cheapest.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.PathfinderStrategies = LazyProf.PathfinderStrategies or {}

LazyProf.PathfinderStrategies.cheapest = {
    name = "Cheapest",

    -- Calculate optimal path from currentSkill to targetSkill
    Calculate = function(self, currentSkill, targetSkill, recipes, inventory, prices)
        local path = {}
        local simulatedSkill = currentSkill
        local simulatedInventory = Utils.DeepCopy(inventory)

        while simulatedSkill < targetSkill do
            -- Get craftable recipes that can still give skillups
            local candidates = self:GetCandidates(recipes, simulatedSkill)

            if #candidates == 0 then
                LazyProf:Debug("scoring", "No candidates at skill " .. simulatedSkill)
                break
            end

            -- DEBUG: Log all candidates and their scores at this skill level
            LazyProf:Debug("scoring", "=== Scoring candidates at skill " .. simulatedSkill .. " ===")
            local debugScores = {}
            for _, recipe in ipairs(candidates) do
                local score = self:ScoreRecipe(recipe, simulatedSkill, targetSkill, simulatedInventory, prices)
                table.insert(debugScores, { recipe = recipe, score = score })
            end
            -- Sort by score (lowest first)
            table.sort(debugScores, function(a, b) return a.score < b.score end)
            -- Log top 10 candidates
            for i = 1, math.min(10, #debugScores) do
                local d = debugScores[i]
                local color = Utils.GetSkillColor(simulatedSkill, d.recipe.skillRange)
                local expectedSkillups = self:GetExpectedSkillups(d.recipe, simulatedSkill)

                -- Calculate both costs for debug display
                local theoreticalCost = 0
                local actualCost = 0
                for _, reagent in ipairs(d.recipe.reagents) do
                    local price = prices[reagent.itemId] or 0
                    local owned = LazyProf.db.profile.useOwnedMaterials and (simulatedInventory[reagent.itemId] or 0) or 0
                    local toBuy = math.max(0, reagent.count - owned)
                    theoreticalCost = theoreticalCost + (price * reagent.count)
                    actualCost = actualCost + (price * toBuy)
                end

                local costDisplay = Utils.FormatMoney(actualCost)
                if LazyProf.db.profile.useOwnedMaterials and actualCost ~= theoreticalCost then
                    costDisplay = costDisplay .. " (market: " .. Utils.FormatMoney(theoreticalCost) .. ")"
                end

                LazyProf:Debug("scoring", string.format("  #%d: %s | score=%.2f | color=%s | skillup=%.2f | cost=%s",
                    i, d.recipe.name, d.score, color, expectedSkillups, costDisplay))
            end

            -- Score each by TOTAL cost per expected skillup (for full quantity until gray)
            local best, bestScore = Utils.MinBy(candidates, function(recipe)
                return self:ScoreRecipe(recipe, simulatedSkill, targetSkill, simulatedInventory, prices)
            end)

            if not best then
                LazyProf:Debug("scoring", "No best recipe found at skill " .. simulatedSkill)
                break
            end

            LazyProf:Debug("scoring", ">>> WINNER: " .. best.name .. " with score " .. string.format("%.2f", bestScore))

            -- Calculate how many to craft (pass recipes for breakpoint detection)
            local quantity = self:CalculateQuantity(best, simulatedSkill, targetSkill, recipes)
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
    -- Score based on cost-per-skillup at CURRENT skill level, with bonuses for flexibility
    -- IMPORTANT: Uses actualCost (materials to buy) not theoreticalCost (full market value)
    ScoreRecipe = function(self, recipe, currentSkill, targetSkill, inventory, prices)
        -- Calculate actual cost per craft (only count materials we need to BUY)
        local theoreticalCost = 0
        local actualCost = 0

        for _, reagent in ipairs(recipe.reagents) do
            local price = prices[reagent.itemId]

            -- Preserve existing nil/zero price rejection
            -- If any reagent has no price, we can't calculate cost
            if not price or price <= 0 then
                return math.huge
            end

            local needed = reagent.count
            local owned = 0

            -- Only consider owned materials if useOwnedMaterials is enabled
            if LazyProf.db.profile.useOwnedMaterials then
                owned = inventory[reagent.itemId] or 0
            end

            local toBuy = math.max(0, needed - owned)

            theoreticalCost = theoreticalCost + (price * needed)
            actualCost = actualCost + (price * toBuy)
        end

        -- Get expected skillups at current skill level
        local expectedSkillups = self:GetExpectedSkillups(recipe, currentSkill)

        if expectedSkillups <= 0 then
            return math.huge
        end

        -- Base score: ACTUAL cost per skillup (what you actually pay)
        local costPerSkillup = actualCost / expectedSkillups

        -- Bonus for recipes that stay useful longer (higher gray point)
        -- Prefer recipes that won't need to be replaced soon
        local rangeBonus = 0
        if recipe.skillRange.gray > currentSkill then
            -- How many more skill points until this recipe goes gray?
            local remainingRange = math.min(recipe.skillRange.gray, targetSkill) - currentSkill
            -- Small bonus per skill point of remaining usefulness
            rangeBonus = -remainingRange * 0.001
        end

        -- Tiebreaker: prefer higher difficulty (better skillup rate)
        local difficultyBonus = -expectedSkillups / 100

        return costPerSkillup + rangeBonus + difficultyBonus
    end,

    -- Calculate total cost and skillups for a given quantity (used after best is chosen)
    CalculateTotalCostAndSkillups = function(self, recipe, currentSkill, quantity, inventory, prices)
        -- Calculate total cost
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

    -- Calculate how many crafts until next breakpoint
    -- Breakpoints: gray, target, new recipe unlocks, or color changes
    CalculateQuantity = function(self, recipe, currentSkill, targetSkill, recipes)
        local quantity = 0
        local simSkill = currentSkill

        -- Find next breakpoint where we should re-evaluate
        local nextBreakpoint = recipe.skillRange.gray  -- default: stop at gray

        -- Check for new recipe unlocks
        if recipes then
            for _, r in ipairs(recipes) do
                if r.skillRequired > currentSkill and r.skillRequired < nextBreakpoint then
                    nextBreakpoint = r.skillRequired
                end
            end
        end

        -- Check for color changes of current recipe (yellow and green boundaries)
        -- Only consider boundaries above current skill
        if recipe.skillRange.yellow > currentSkill and recipe.skillRange.yellow < nextBreakpoint then
            nextBreakpoint = recipe.skillRange.yellow
        end
        if recipe.skillRange.green > currentSkill and recipe.skillRange.green < nextBreakpoint then
            nextBreakpoint = recipe.skillRange.green
        end

        -- Craft until breakpoint, target, or max iterations
        while simSkill < targetSkill and simSkill < nextBreakpoint and quantity < 100 do
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
