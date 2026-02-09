-- Modules/Pathfinder/Strategies/Fastest.lua
-- Optimizes for fewest crafts (fastest leveling), ignoring cost
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.PathfinderStrategies = LazyProf.PathfinderStrategies or {}

LazyProf.PathfinderStrategies.fastest = {
    name = "Fastest",

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

            -- Score all candidates and build alternatives list
            local effectiveSkill = simulatedSkill - racialBonus
            local alternatives = {}
            for _, recipe in ipairs(candidates) do
                local score = self:ScoreRecipe(recipe, simulatedSkill, targetSkill, racialBonus)
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
    -- We want highest skillup chance, so return negative of expected skillups
    -- Orange (1.0) -> -1.0, Yellow (0.5) -> -0.5, Green (0.25) -> -0.25
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    ScoreRecipe = function(self, recipe, currentSkill, targetSkill, racialBonus)
        racialBonus = racialBonus or 0
        local effectiveSkill = currentSkill - racialBonus

        -- Unavailable recipes: display-only in alternatives, never auto-selected
        if recipe._isUnavailable then
            return math.huge
        end

        local expected = self:GetExpectedSkillups(recipe, currentSkill, racialBonus)

        if expected <= 0 then
            return math.huge
        end

        -- Return negative so higher skillup chance = lower score = better
        -- Add small tiebreaker: prefer recipes that stay orange longer
        -- Use effective skill for color comparison
        local orangeRange = recipe.skillRange.yellow - effectiveSkill
        local tiebreaker = -orangeRange / 1000

        return -expected + tiebreaker
    end,

    -- Calculate total cost and skillups for a given quantity
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    CalculateTotalCostAndSkillups = function(self, recipe, currentSkill, quantity, inventory, prices, racialBonus)
        racialBonus = racialBonus or 0
        -- Calculate total cost (still track it for display)
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

    -- Get expected skillups using continuous linear formula
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    GetExpectedSkillups = function(self, recipe, currentSkill, racialBonus)
        racialBonus = racialBonus or 0
        local effectiveSkill = currentSkill - racialBonus
        return Utils.GetSkillUpChance(effectiveSkill, recipe.skillRange)
    end,

    -- Calculate how many crafts until next breakpoint
    -- Breakpoints: gray, target, new recipe unlocks, or color changes
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    CalculateQuantity = function(self, recipe, currentSkill, targetSkill, recipes, racialBonus)
        racialBonus = racialBonus or 0
        local quantity = 0
        local simSkill = currentSkill

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

        -- Color-change breakpoints: even though skill-up probability is now continuous
        -- (no discrete jump at yellow/green), we still re-evaluate at these boundaries
        -- because a different recipe may become more cost-effective after a color transition.
        if yellowAt > currentSkill and yellowAt < nextBreakpoint then
            nextBreakpoint = yellowAt
        end
        if greenAt > currentSkill and greenAt < nextBreakpoint then
            nextBreakpoint = greenAt
        end

        -- Dynamic cap: ~5 expected skill points per step before re-evaluation
        local initialExpected = self:GetExpectedSkillups(recipe, currentSkill, racialBonus)
        local maxQuantity = math.max(5, math.min(50, math.ceil(5 / math.max(0.01, initialExpected))))

        -- Craft until breakpoint, target, or max iterations
        while simSkill < targetSkill and simSkill < nextBreakpoint and quantity < maxQuantity do
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
