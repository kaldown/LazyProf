-- Modules/Pathfinder/StrategyCore.lua
-- The one simulation loop shared by every pathfinder strategy.
-- A strategy supplies ScoreRecipe, GetCandidates, CalculateQuantity,
-- CalculateTotalCostAndSkillups, GetExpectedSkillups, ConsumeReagents and
-- FindNextRecipeSkill, plus an optional `logScoring` flag that enables the
-- per-skill scoring debug output.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

-- ScoreRecipe is called with the superset
-- (recipe, skill, targetSkill, inventory, prices, racialBonus, purchasedRecipes);
-- a strategy ignores what it does not use.
LazyProf.StrategyCore = {
    Run = function(_core, self, currentSkill, targetSkill, recipes, inventory, prices, racialBonus, pinnedRecipes)
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
            if self.logScoring and LazyProf:IsDebugEnabled("scoring") then
                LazyProf:Debug("scoring", "=== Scoring candidates at skill " .. simulatedSkill .. " (effective: " .. effectiveSkill .. ") ===")
            end
            local alternatives = {}
            for _, recipe in ipairs(candidates) do
                local score = self:ScoreRecipe(recipe, simulatedSkill, targetSkill, simulatedInventory, prices, racialBonus, purchasedRecipes)
                local color = Utils.GetSkillColor(effectiveSkill, recipe.skillRange)
                local expectedSkillups = self:GetExpectedSkillups(recipe, simulatedSkill, racialBonus)

                -- Calculate per-craft cost for display
                local craftCost = 0
                for _, reagent in ipairs(recipe.reagents) do
                    local price = prices[reagent.itemId] or 0
                    local owned = simulatedInventory[reagent.itemId] or 0
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

            -- Debug: log top 10 (guarded - this string + FormatMoney building is the
            -- bulk of the eager debug cost and would otherwise run even with debug off)
            if self.logScoring and LazyProf:IsDebugEnabled("scoring") then
                for i = 1, math.min(10, #alternatives) do
                    local d = alternatives[i]
                    LazyProf:Debug("scoring", string.format("  #%d: %s | score=%.2f | color=%s | skillup=%.2f | cost=%s",
                        i, d.recipe.name, d.score, d.color, d.expectedSkillups, Utils.FormatMoney(d.craftCost)))
                end
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

            if self.logScoring and not pinnedId and LazyProf:IsDebugEnabled("scoring") then
                LazyProf:Debug("scoring", ">>> WINNER: " .. best.name .. " with score " .. string.format("%.2f", bestScore))
            end

            -- Calculate how many to craft (pass recipes for breakpoint detection)
            local quantity = self:CalculateQuantity(best, simulatedSkill, targetSkill, recipes, racialBonus)
            local totalSkillups, totalCost = self:CalculateTotalCostAndSkillups(best, simulatedSkill, quantity, simulatedInventory, prices, racialBonus, purchasedRecipes)

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
}
