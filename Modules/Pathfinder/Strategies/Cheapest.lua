-- Modules/Pathfinder/Strategies/Cheapest.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.PathfinderStrategies = LazyProf.PathfinderStrategies or {}

LazyProf.PathfinderStrategies.cheapest = {
    name = "Cheapest",

    -- Calculate optimal path from currentSkill to targetSkill
    -- racialBonus: skill bonus from racial trait (e.g., Gnome +15 Engineering)
    --              This extends how long recipes stay orange/yellow/green
    -- pinnedRecipes: optional table { [skillLevel] = recipeId } to override best picks
    Calculate = function(self, currentSkill, targetSkill, recipes, inventory, prices, racialBonus, pinnedRecipes)
        racialBonus = racialBonus or 0
        pinnedRecipes = pinnedRecipes or {}
        local path = {}
        local simulatedSkill = currentSkill
        local simulatedInventory = Utils.DeepCopy(inventory)
        local purchasedRecipes = {}  -- Track recipes we've "bought" in simulation

        while simulatedSkill < targetSkill do
            -- Get craftable recipes that can still give skillups
            -- Use effective skill (base - bonus) for color calculations
            local candidates = self:GetCandidates(recipes, simulatedSkill, racialBonus)

            if #candidates == 0 then
                -- No candidates at current skill - find the next skill level where a recipe becomes available
                local nextSkill = self:FindNextRecipeSkill(recipes, simulatedSkill, targetSkill, racialBonus)
                if nextSkill then
                    LazyProf:Debug("scoring", "No candidates at skill " .. simulatedSkill .. ", skipping to " .. nextSkill)
                    simulatedSkill = nextSkill
                else
                    LazyProf:Debug("scoring", "No candidates at skill " .. simulatedSkill .. " and no higher recipes available")
                    break
                end
            end

            -- Score all candidates and build alternatives list (also used for debug logging)
            local effectiveSkill = simulatedSkill - racialBonus
            LazyProf:Debug("scoring", "=== Scoring candidates at skill " .. simulatedSkill .. " (effective: " .. effectiveSkill .. ") ===")
            local alternatives = {}
            for _, recipe in ipairs(candidates) do
                local score = self:ScoreRecipe(recipe, simulatedSkill, targetSkill, simulatedInventory, prices, racialBonus, purchasedRecipes)
                local color = Utils.GetSkillColor(effectiveSkill, recipe.skillRange)
                local expectedSkillups = self:GetExpectedSkillups(recipe, simulatedSkill, racialBonus)

                -- Calculate per-craft cost for display
                local craftCost = 0
                for _, reagent in ipairs(recipe.reagents) do
                    local price = prices[reagent.itemId] or 0
                    local owned = LazyProf.db.profile.useOwnedMaterials and (simulatedInventory[reagent.itemId] or 0) or 0
                    local toBuy = math.max(0, reagent.count - owned)
                    craftCost = craftCost + (price * toBuy)
                end

                table.insert(alternatives, {
                    recipe = recipe,
                    score = score,
                    color = color,
                    expectedSkillups = expectedSkillups,
                    craftCost = craftCost,
                })
            end
            -- Sort by score (lowest = best first)
            table.sort(alternatives, function(a, b) return a.score < b.score end)

            -- Debug: log top 10
            for i = 1, math.min(10, #alternatives) do
                local d = alternatives[i]
                LazyProf:Debug("scoring", string.format("  #%d: %s | score=%.2f | color=%s | skillup=%.2f | cost=%s",
                    i, d.recipe.name, d.score, d.color, d.expectedSkillups, Utils.FormatMoney(d.craftCost)))
            end

            -- Select best available recipe (skip unavailable for auto-selection)
            local best, bestScore
            for _, alt in ipairs(alternatives) do
                if not alt.recipe._isUnavailable then
                    best = alt.recipe
                    bestScore = alt.score
                    break
                end
            end

            -- Check for pinned recipe override
            local pinnedId = pinnedRecipes[simulatedSkill]
            if pinnedId then
                for _, alt in ipairs(alternatives) do
                    if alt.recipe.id == pinnedId then
                        best = alt.recipe
                        bestScore = alt.score
                        LazyProf:Debug("scoring", ">>> PINNED: " .. best.name .. " (overriding optimizer)")
                        break
                    end
                end
            end

            if not best then
                LazyProf:Debug("scoring", "No best recipe found at skill " .. simulatedSkill)
                break
            end

            if not pinnedId then
                LazyProf:Debug("scoring", ">>> WINNER: " .. best.name .. " with score " .. string.format("%.2f", bestScore))
            end

            -- Calculate how many to craft (pass recipes for breakpoint detection)
            local quantity = self:CalculateQuantity(best, simulatedSkill, targetSkill, recipes, racialBonus)
            local totalSkillups, totalCost = self:CalculateTotalCostAndSkillups(best, simulatedSkill, quantity, simulatedInventory, prices, racialBonus)

            -- Add step to path (with alternatives for UI)
            table.insert(path, {
                recipe = best,
                quantity = quantity,
                skillStart = simulatedSkill,
                skillEnd = math.min(simulatedSkill + totalSkillups, targetSkill),
                totalCost = totalCost,
                alternatives = alternatives,
            })

            -- Mark recipe as purchased in simulation (so future evaluations don't re-add cost)
            if not best.learned and best._sourceInfo then
                purchasedRecipes[best.id] = true
            end

            -- Update simulation
            simulatedSkill = path[#path].skillEnd
            simulatedInventory = self:ConsumeReagents(simulatedInventory, best, quantity)
        end

        return path
    end,

    -- Get recipes that can be crafted and give skillups at current skill
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    GetCandidates = function(self, recipes, currentSkill, racialBonus)
        racialBonus = racialBonus or 0
        local candidates = {}
        -- Effective skill for color calculations (racial bonus extends color ranges)
        local effectiveSkill = currentSkill - racialBonus

        for _, recipe in ipairs(recipes) do
            -- Can learn/craft at current skill? (uses base skill, not effective)
            if currentSkill >= recipe.skillRequired then
                -- Not gray yet? (uses effective skill for color check)
                if effectiveSkill < recipe.skillRange.gray then
                    if recipe.learned then
                        -- Already learned - always available
                        recipe._isUnavailable = nil
                        recipe._sourceInfo = nil
                        table.insert(candidates, recipe)
                    else
                        -- Unlearned: check availability if setting enabled
                        if LazyProf.db.profile.suggestUnlearnedRecipes then
                            local isAvailable, sourceInfo = LazyProf.RecipeAvailability:IsRecipeAvailable(recipe)
                            if isAvailable then
                                recipe._sourceInfo = sourceInfo
                                recipe._isUnavailable = nil
                            else
                                recipe._sourceInfo = nil
                                recipe._isUnavailable = true
                            end
                        else
                            -- Setting off: include for display but mark unavailable
                            recipe._sourceInfo = nil
                            recipe._isUnavailable = true
                        end
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
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    -- purchasedRecipes: table of recipe IDs already "bought" in this simulation
    ScoreRecipe = function(self, recipe, currentSkill, targetSkill, inventory, prices, racialBonus, purchasedRecipes)
        racialBonus = racialBonus or 0
        purchasedRecipes = purchasedRecipes or {}
        local effectiveSkill = currentSkill - racialBonus

        -- Unavailable recipes: display-only in alternatives, never auto-selected
        if recipe._isUnavailable then
            return math.huge
        end

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

        -- Add recipe acquisition cost for unlearned recipes (amortized over expected uses)
        -- Free if: already learned, already purchased in simulation, or recipe item in inventory
        -- Costs if: trainer, vendor, or AH purchase required
        if not recipe.learned and not purchasedRecipes[recipe.id] and recipe._sourceInfo then
            local srcType = recipe._sourceInfo.type
            local recipeCost = 0
            if srcType == "trainer" or srcType == "vendor" then
                recipeCost = recipe._sourceInfo.cost or 0
            elseif srcType == "ah" then
                recipeCost = recipe._sourceInfo.price or 0
            end
            -- Amortize one-time cost over expected remaining crafts
            if recipeCost > 0 then
                local expectedCrafts = self:GetExpectedCraftsUntilGray(recipe, currentSkill, targetSkill, racialBonus)
                actualCost = actualCost + (recipeCost / expectedCrafts)
            end
            -- "learned" and "inventory" types are free - no cost added
        end

        -- Get expected skillups at current skill level (uses effective skill for color)
        local expectedSkillups = self:GetExpectedSkillups(recipe, currentSkill, racialBonus)

        if expectedSkillups <= 0 then
            return math.huge
        end

        -- Base score: ACTUAL cost per skillup (what you actually pay)
        local costPerSkillup = actualCost / expectedSkillups

        -- Bonus for recipes that stay useful longer (higher gray point)
        -- Prefer recipes that won't need to be replaced soon
        -- Use effective skill for gray comparison
        local rangeBonus = 0
        if recipe.skillRange.gray > effectiveSkill then
            -- How many more skill points until this recipe goes gray?
            local remainingRange = math.min(recipe.skillRange.gray, targetSkill - racialBonus) - effectiveSkill
            -- Small bonus per skill point of remaining usefulness
            rangeBonus = -remainingRange * 0.001
        end

        -- Tiebreaker: prefer higher difficulty (better skillup rate)
        local difficultyBonus = -expectedSkillups / 100

        return costPerSkillup + rangeBonus + difficultyBonus
    end,

    -- Calculate total cost and skillups for a given quantity (used after best is chosen)
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    CalculateTotalCostAndSkillups = function(self, recipe, currentSkill, quantity, inventory, prices, racialBonus)
        racialBonus = racialBonus or 0
        -- Calculate total cost
        local totalCost = 0
        for _, reagent in ipairs(recipe.reagents) do
            local have = inventory[reagent.itemId] or 0
            local totalNeed = reagent.count * quantity
            local needToBuy = math.max(0, totalNeed - have)
            local price = prices[reagent.itemId] or 0
            totalCost = totalCost + (price * needToBuy)
        end

        -- Add recipe acquisition cost (one-time, not per craft)
        if not recipe.learned and recipe._sourceInfo then
            local srcType = recipe._sourceInfo.type
            if srcType == "trainer" or srcType == "vendor" then
                totalCost = totalCost + (recipe._sourceInfo.cost or 0)
            elseif srcType == "ah" then
                totalCost = totalCost + (recipe._sourceInfo.price or 0)
            end
        end

        -- Calculate total skillups
        local totalSkillups = 0
        local simSkill = currentSkill
        for i = 1, quantity do
            local expected = self:GetExpectedSkillups(recipe, simSkill, racialBonus)
            totalSkillups = totalSkillups + expected
            simSkill = simSkill + expected
        end

        return totalSkillups, totalCost
    end,

    -- Get expected skillups based on color
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    GetExpectedSkillups = function(self, recipe, currentSkill, racialBonus)
        racialBonus = racialBonus or 0
        local effectiveSkill = currentSkill - racialBonus
        local color = Utils.GetSkillColor(effectiveSkill, recipe.skillRange)
        return Constants.SKILLUP_CHANCE[color] or 0
    end,

    -- Calculate expected number of crafts from currentSkill until recipe goes gray or target is reached
    -- Used to amortize one-time recipe acquisition costs
    GetExpectedCraftsUntilGray = function(self, recipe, currentSkill, targetSkill, racialBonus)
        racialBonus = racialBonus or 0
        local effectiveSkill = currentSkill - racialBonus

        -- Recipe already gray
        if effectiveSkill >= recipe.skillRange.gray then
            return 0
        end

        -- Stop at whichever comes first: target skill or gray
        local stopAt = math.min(targetSkill, recipe.skillRange.gray + racialBonus)

        local totalCrafts = 0
        local simSkill = currentSkill

        while simSkill < stopAt do
            local effSkill = simSkill - racialBonus
            local color = Utils.GetSkillColor(effSkill, recipe.skillRange)
            local skillupChance = Constants.SKILLUP_CHANCE[color] or 0

            if skillupChance <= 0 then
                break
            end

            -- Expected crafts for 1 skill point at this color
            totalCrafts = totalCrafts + (1 / skillupChance)
            simSkill = simSkill + 1
        end

        return math.max(1, totalCrafts)  -- At least 1 to avoid division by zero
    end,

    -- Calculate how many crafts until next breakpoint
    -- Breakpoints: gray, target, new recipe unlocks, or color changes
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    CalculateQuantity = function(self, recipe, currentSkill, targetSkill, recipes, racialBonus)
        racialBonus = racialBonus or 0
        local quantity = 0
        local simSkill = currentSkill
        local effectiveSkill = currentSkill - racialBonus

        -- Find next breakpoint where we should re-evaluate
        -- Racial bonus shifts when colors change (in base skill terms, add bonus to thresholds)
        local grayAt = recipe.skillRange.gray + racialBonus
        local yellowAt = recipe.skillRange.yellow + racialBonus
        local greenAt = recipe.skillRange.green + racialBonus
        local nextBreakpoint = grayAt  -- default: stop at gray

        -- Check for new recipe unlocks (uses base skill, not affected by racial bonus)
        if recipes then
            for _, r in ipairs(recipes) do
                if r.skillRequired > currentSkill and r.skillRequired < nextBreakpoint then
                    nextBreakpoint = r.skillRequired
                end
            end
        end

        -- Check for color changes of current recipe (yellow and green boundaries)
        -- Only consider boundaries above current skill
        if yellowAt > currentSkill and yellowAt < nextBreakpoint then
            nextBreakpoint = yellowAt
        end
        if greenAt > currentSkill and greenAt < nextBreakpoint then
            nextBreakpoint = greenAt
        end

        -- Craft until breakpoint, target, or max iterations
        while simSkill < targetSkill and simSkill < nextBreakpoint and quantity < 100 do
            quantity = quantity + 1
            local expected = self:GetExpectedSkillups(recipe, simSkill, racialBonus)
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

    -- Find the next skill level where a recipe becomes available
    -- Returns: skill level or nil if no recipes available above currentSkill
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    FindNextRecipeSkill = function(self, recipes, currentSkill, targetSkill, racialBonus)
        racialBonus = racialBonus or 0
        local nextSkill = nil
        for _, recipe in ipairs(recipes) do
            local required = recipe.skillRequired
            -- Recipe must be above current skill but not beyond target
            if required > currentSkill and required <= targetSkill then
                -- Recipe must not already be gray at that skill level
                -- With racial bonus, gray is reached at base skill = gray + racialBonus
                local grayAt = recipe.skillRange.gray + racialBonus
                if required < grayAt then
                    if not nextSkill or required < nextSkill then
                        nextSkill = required
                    end
                end
            end
        end
        return nextSkill
    end,
}
