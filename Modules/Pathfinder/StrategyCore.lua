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

-- The lowest skill above `skill` at which a recipe becomes learnable; false
-- when there is none. (A run is cut there: the new recipe may be better.)
local function NextUnlock(recipes, skill)
    local unlock = false
    for _, recipe in ipairs(recipes or {}) do
        local required = recipe.skillRequired
        if required > skill and (not unlock or required < unlock) then
            unlock = required
        end
    end
    return unlock
end

-- How many of `quantity` crafts a green bridge gets: it stops at the skill
-- where the recipe's chance falls under Constants.BRIDGE_MIN_CHANCE.
local function BridgeCut(strategy, recipe, skill, quantity, racialBonus)
    local minChance = LazyProf.Constants.BRIDGE_MIN_CHANCE
    local allowed, simSkill = 0, skill
    while allowed < quantity
            and Utils.GetSkillUpChance(simSkill - racialBonus, recipe.skillRange) >= minChance do
        allowed = allowed + 1
        simSkill = simSkill + strategy:GetExpectedSkillups(recipe, simSkill, racialBonus)
    end
    return math.max(1, allowed)
end

-- What one craft of `recipe` costs in reagents at `skill`, counting owned
-- stock against the whole run the recipe would get, not against one craft:
-- owning enough for a single craft must not make a run of fifty look free.
-- For a reagent the character owns, the run's quantity is worked out first
-- (strategy:CalculateQuantity, cut like a bridge when ctx.bridge is set) and
-- the reagent costs
--   price x max(0, count x quantity - owned) / quantity
-- per craft. A reagent with nothing owned costs price x count, exactly as it
-- always did, so with an empty inventory the result is unchanged to the bit.
-- ctx: the run's scoring context or nil ({ recipes, bridge, costMemo, ... }).
--   Within one scoring pass (same skill, same stock) a recipe's result is
--   kept in ctx.costMemo, and the next recipe unlock is looked up once.
-- Returns cost, priced. priced is false when a reagent that has to be bought
-- has no price (or one not above zero); such a reagent adds nothing to the
-- cost. A reagent the stock covers for the whole run needs no price.
local function ReagentCostPerCraft(strategy, recipe, skill, targetSkill, inventory, prices, racialBonus, ctx)
    local memo = ctx and ctx.costMemo
    local known = memo and memo[recipe]
    if known then
        return known[1], known[2]
    end

    local cost, priced = 0, true
    local quantity
    for _, reagent in ipairs(recipe.reagents) do
        local price = prices[reagent.itemId]
        local hasPrice = (price ~= nil and price > 0)
        if not hasPrice then
            price = 0
        end
        local owned = inventory[reagent.itemId] or 0
        if owned <= 0 then
            if not hasPrice then priced = false end
            cost = cost + (price * reagent.count)
        else
            if not quantity then
                local unlock
                if ctx then
                    if ctx.unlockSkill ~= skill then
                        ctx.unlockSkill = skill
                        ctx.unlock = NextUnlock(ctx.recipes, skill)
                    end
                    unlock = ctx.unlock
                end
                quantity = math.max(1, strategy:CalculateQuantity(recipe, skill, targetSkill,
                    ctx and ctx.recipes, racialBonus, unlock))
                if ctx and ctx.bridge then
                    quantity = BridgeCut(strategy, recipe, skill, quantity, racialBonus)
                end
            end
            local toBuy = math.max(0, reagent.count * quantity - owned)
            if toBuy > 0 then
                if not hasPrice then priced = false end
                cost = cost + price * toBuy / quantity
            end
        end
    end

    if memo then
        memo[recipe] = { cost, priced }
    end
    return cost, priced
end

-- Score every candidate and return the alternatives list, best (lowest score) first.
-- ScoreRecipe is called with the superset
-- (recipe, skill, targetSkill, inventory, prices, racialBonus, purchasedRecipes, scoreCtx);
-- a strategy ignores what it does not use. scoreCtx is the run's context
-- (see Run): { rankSale, sale, recipes }; this pass also marks it as a bridge
-- pass or not and starts a fresh per-recipe cost memo.
local function ScoreCandidates(strategy, candidates, skill, targetSkill, inventory, prices, racialBonus, purchasedRecipes, label, scoreCtx, bridge)
    local effectiveSkill = skill - racialBonus
    if scoreCtx then
        scoreCtx.bridge = bridge or nil
        scoreCtx.costMemo = {}
    end
    if strategy.logScoring and LazyProf:IsDebugEnabled("scoring") then
        LazyProf:Debug("scoring", "=== Scoring candidates at skill " .. skill .. " (effective: " .. effectiveSkill .. ")"
            .. (label or "") .. " ===")
    end
    local alternatives = {}
    for _, recipe in ipairs(candidates) do
        local score = strategy:ScoreRecipe(recipe, skill, targetSkill, inventory, prices, racialBonus, purchasedRecipes, scoreCtx)
        local color = Utils.GetSkillColor(effectiveSkill, recipe.skillRange)
        local expectedSkillups = strategy:GetExpectedSkillups(recipe, skill, racialBonus)

        -- Per-craft cost for display, by the same rule the scoring uses
        local craftCost = ReagentCostPerCraft(strategy, recipe, skill, targetSkill, inventory, prices,
            racialBonus, scoreCtx)

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
    ReagentCostPerCraft = ReagentCostPerCraft,

    -- pins: optional pin list (Modules/Pathfinder/Pins.lua); with none the
    -- loop's output is what the optimizer picks.
    -- ctx: optional { rankSale = { [recipeId] = copper }, sale = { [recipeId] = copper } }
    --   rankSale  what one craft sells for, for the recipes whose ranking may
    --             use it (a strategy that ranks by cost takes it off)
    --   sale      what one craft sells for, put on the steps (saleEach, sale)
    -- Without ctx the output is exactly what it was before sale values existed.
    Run = function(_core, self, currentSkill, targetSkill, recipes, inventory, prices, racialBonus, pins, ctx)
        racialBonus = racialBonus or 0
        local scoreCtx = { rankSale = ctx and ctx.rankSale or nil, sale = ctx and ctx.sale or nil, recipes = recipes }
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
                simulatedInventory, prices, racialBonus, purchasedRecipes, nil, scoreCtx)
            local best, bestScore = PickBest(alternatives, pinnedId)
            local bridge = false

            -- (1) Bridge: nothing to choose while green recipes are excluded by the
            -- setting - allow green ones whose chance is still >= BRIDGE_MIN_CHANCE.
            if not best and not LazyProf.db.profile.includeGreenRecipes then
                local minChance = LazyProf.Constants.BRIDGE_MIN_CHANCE
                local effectiveSkill = simulatedSkill - racialBonus
                local wideCandidates = self:GetCandidates(recipes, simulatedSkill, racialBonus, true)
                local wideAlternatives = ScoreCandidates(self, wideCandidates, simulatedSkill, targetSkill,
                    simulatedInventory, prices, racialBonus, purchasedRecipes, " [bridge: green allowed]", scoreCtx, true)
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
                    quantity = BridgeCut(self, best, simulatedSkill, quantity, racialBonus)
                end

                local totalSkillups, totalCost = self:CalculateTotalCostAndSkillups(best, simulatedSkill, quantity, simulatedInventory, prices, racialBonus, purchasedRecipes)

                -- Add step to path (with alternatives for UI). What its
                -- crafts sell for rides along when sale values were given.
                local saleEach = scoreCtx.sale and scoreCtx.sale[best.id] or nil
                table.insert(path, {
                    recipe = best,
                    quantity = quantity,
                    skillStart = simulatedSkill,
                    skillEnd = math.min(simulatedSkill + totalSkillups, targetSkill),
                    totalCost = totalCost,
                    alternatives = alternatives,
                    bridge = bridge or nil,
                    saleEach = saleEach,
                    sale = saleEach and (saleEach * quantity) or nil,
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
