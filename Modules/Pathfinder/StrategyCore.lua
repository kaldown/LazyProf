-- Modules/Pathfinder/StrategyCore.lua
-- The one simulation loop shared by every pathfinder strategy.
-- A strategy supplies ScoreRecipe, GetCandidates, CalculateQuantity,
-- CalculateTotalCostAndSkillups, GetExpectedSkillups, ConsumeReagents and
-- FindNextRecipeSkill, plus an optional `logScoring` flag that enables the
-- per-skill scoring debug output.
--
-- Run returns `steps, meta` with meta = { complete = bool, gaps = { {from, to, reason}, ... } }.
-- When no recipe can be chosen at the simulated skill the loop never stops
-- silently: (1) with green recipes excluded by the setting it retries with
-- green allowed, keeping only recipes whose skill-up chance is at least
-- Constants.BRIDGE_MIN_CHANCE, and marks that step `bridge = true`; (2) else it
-- records a gap up to the next skill where a recipe becomes learnable and
-- continues there; (3) with no such skill it records a gap up to the target.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

local GAP_NO_RECIPE = "no recipe"

-- Score every candidate and return the alternatives list, best (lowest score) first.
-- ScoreRecipe is called with the superset
-- (recipe, skill, targetSkill, inventory, prices, racialBonus, purchasedRecipes);
-- a strategy ignores what it does not use.
local function ScoreCandidates(strategy, candidates, skill, targetSkill, inventory, prices, racialBonus, purchasedRecipes, label)
    local effectiveSkill = skill - racialBonus
    if strategy.logScoring and LazyProf:IsDebugEnabled("scoring") then
        LazyProf:Debug("scoring", "=== Scoring candidates at skill " .. skill .. " (effective: " .. effectiveSkill .. ")"
            .. (label or "") .. " ===")
    end
    local alternatives = {}
    for _, recipe in ipairs(candidates) do
        local score = strategy:ScoreRecipe(recipe, skill, targetSkill, inventory, prices, racialBonus, purchasedRecipes)
        local color = Utils.GetSkillColor(effectiveSkill, recipe.skillRange)
        local expectedSkillups = strategy:GetExpectedSkillups(recipe, skill, racialBonus)

        -- Calculate per-craft cost for display
        local craftCost = 0
        for _, reagent in ipairs(recipe.reagents) do
            local price = prices[reagent.itemId] or 0
            local owned = inventory[reagent.itemId] or 0
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
    if strategy.logScoring and LazyProf:IsDebugEnabled("scoring") then
        for i = 1, math.min(10, #alternatives) do
            local d = alternatives[i]
            LazyProf:Debug("scoring", string.format("  #%d: %s | score=%.2f | color=%s | skillup=%.2f | cost=%s",
                i, d.recipe.name, d.score, d.color, d.expectedSkillups, Utils.FormatMoney(d.craftCost)))
        end
    end
    return alternatives
end

-- Select the best available recipe (unavailable ones are never auto-selected);
-- a pinned recipe overrides the optimizer. `accept`, when given, must also hold
-- for the chosen recipe, pinned or not.
local function PickBest(alternatives, pinnedId, accept)
    local best, bestScore
    for _, alt in ipairs(alternatives) do
        if not alt.recipe._isUnavailable and (not accept or accept(alt.recipe)) then
            best = alt.recipe
            bestScore = alt.score
            break
        end
    end

    if pinnedId then
        for _, alt in ipairs(alternatives) do
            if alt.recipe.id == pinnedId and (not accept or accept(alt.recipe)) then
                best = alt.recipe
                bestScore = alt.score
                LazyProf:Debug("scoring", ">>> PINNED: " .. best.name .. " (overriding optimizer)")
                break
            end
        end
    end
    return best, bestScore
end

-- Record a gap; a gap that starts where the previous one ended extends it.
local function AddGap(gaps, from, to, reason)
    local last = gaps[#gaps]
    if last and last.to == from and last.reason == reason then
        last.to = to
    else
        table.insert(gaps, { from = from, to = to, reason = reason })
    end
    if LazyProf:IsDebugEnabled("scoring") then
        LazyProf:Debug("scoring", string.format("GAP: no recipe for %.2f-%.2f (%s)", from, to, reason))
    end
end

LazyProf.StrategyCore = {
    -- pins: optional pin list (Modules/Pathfinder/Pins.lua); with none the
    -- loop's output is what the optimizer picks.
    Run = function(_core, self, currentSkill, targetSkill, recipes, inventory, prices, racialBonus, pins)
        racialBonus = racialBonus or 0
        local path = {}
        local gaps = {}
        local simulatedSkill = currentSkill
        local simulatedInventory = Utils.DeepCopy(inventory)
        local purchasedRecipes = {}  -- Track recipes we've "bought" in simulation

        while simulatedSkill < targetSkill do
            local pinnedId = LazyProf.Pins.Find(pins, simulatedSkill)

            -- Get craftable recipes that can still give skillups
            -- Use effective skill (base - bonus) for color calculations
            local candidates = self:GetCandidates(recipes, simulatedSkill, racialBonus)
            local alternatives = ScoreCandidates(self, candidates, simulatedSkill, targetSkill,
                simulatedInventory, prices, racialBonus, purchasedRecipes)
            local best, bestScore = PickBest(alternatives, pinnedId)
            local bridge = false

            -- (1) Bridge: nothing to choose while green recipes are excluded by the
            -- setting - allow green ones whose chance is still >= BRIDGE_MIN_CHANCE.
            if not best and not LazyProf.db.profile.includeGreenRecipes then
                local minChance = LazyProf.Constants.BRIDGE_MIN_CHANCE
                local effectiveSkill = simulatedSkill - racialBonus
                local wideCandidates = self:GetCandidates(recipes, simulatedSkill, racialBonus, true)
                local wideAlternatives = ScoreCandidates(self, wideCandidates, simulatedSkill, targetSkill,
                    simulatedInventory, prices, racialBonus, purchasedRecipes, " [bridge: green allowed]")
                best, bestScore = PickBest(wideAlternatives, pinnedId, function(recipe)
                    return Utils.GetSkillUpChance(effectiveSkill, recipe.skillRange) >= minChance
                end)
                if best then
                    alternatives = wideAlternatives
                    bridge = true
                end
            end

            if best then
                if self.logScoring and not pinnedId and LazyProf:IsDebugEnabled("scoring") then
                    LazyProf:Debug("scoring", ">>> WINNER: " .. best.name .. " with score " .. string.format("%.2f", bestScore)
                        .. (bridge and " (bridge)" or ""))
                end

                -- Calculate how many to craft (pass recipes for breakpoint detection)
                local quantity = self:CalculateQuantity(best, simulatedSkill, targetSkill, recipes, racialBonus)

                -- A bridge stops at the skill where its chance falls under the floor,
                -- so the gap (if any) starts there.
                if bridge then
                    local minChance = LazyProf.Constants.BRIDGE_MIN_CHANCE
                    local allowed, simSkill = 0, simulatedSkill
                    while allowed < quantity
                            and Utils.GetSkillUpChance(simSkill - racialBonus, best.skillRange) >= minChance do
                        allowed = allowed + 1
                        simSkill = simSkill + self:GetExpectedSkillups(best, simSkill, racialBonus)
                    end
                    quantity = math.max(1, allowed)
                end

                local totalSkillups, totalCost = self:CalculateTotalCostAndSkillups(best, simulatedSkill, quantity, simulatedInventory, prices, racialBonus, purchasedRecipes)

                -- Add step to path (with alternatives for UI)
                table.insert(path, {
                    recipe = best,
                    quantity = quantity,
                    skillStart = simulatedSkill,
                    skillEnd = math.min(simulatedSkill + totalSkillups, targetSkill),
                    totalCost = totalCost,
                    alternatives = alternatives,
                    bridge = bridge or nil,
                })

                -- Mark recipe as purchased in simulation (so future evaluations don't re-add cost)
                if not best.learned and best._sourceInfo then
                    purchasedRecipes[best.id] = true
                end

                -- Update simulation
                simulatedSkill = path[#path].skillEnd
                simulatedInventory = self:ConsumeReagents(simulatedInventory, best, quantity)
            else
                -- (2) Gap up to the next skill where a recipe becomes learnable,
                -- (3) or up to the target when there is none.
                local nextSkill = self:FindNextRecipeSkill(recipes, simulatedSkill, targetSkill, racialBonus)
                if nextSkill then
                    AddGap(gaps, simulatedSkill, nextSkill, GAP_NO_RECIPE)
                    simulatedSkill = nextSkill
                else
                    AddGap(gaps, simulatedSkill, targetSkill, GAP_NO_RECIPE)
                    break
                end
            end
        end

        return path, { complete = (#gaps == 0), gaps = gaps }
    end,
}
