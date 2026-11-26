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

-- Skill ranges (pins, remembered routes) are read this far below their
-- written bounds: a range covers [from - tolerance, to - tolerance). A run
-- that lands a hair under a fractional end then does not get one more craft,
-- the next range takes over exactly where the run stops, and the sliver just
-- under a recipe's grey point - where a craft gains next to nothing - belongs
-- to no range.
local RANGE_END_TOLERANCE = 1e-6

-- The range (a pin, or a remembered route's range) covering `skill`, nil when
-- none does. `whole`: read the bounds as whole skills (see Run, ctx.replay).
local function FindRange(ranges, skill, whole)
    for _, range in ipairs(ranges) do
        local from, to = range.from, range.to
        if whole then
            from, to = math.floor(from), math.floor(to)
        end
        if skill >= from - RANGE_END_TOLERANCE and skill < to - RANGE_END_TOLERANCE then
            return range
        end
    end
    return nil
end

-- Where the next range above `skill` begins whose recipe can be crafted for
-- skill-ups at that point (canBegin(recipeId, skill)); nil when there is none.
-- A range whose recipe cannot be used there (not learnable yet, grey, gone)
-- changes nothing, so no run is cut for it.
local function NextRangeStart(ranges, skill, whole, canBegin)
    local nextStart
    for _, range in ipairs(ranges) do
        local from = whole and math.floor(range.from) or range.from
        if from - RANGE_END_TOLERANCE > skill and (not nextStart or from < nextStart)
                and canBegin(range.recipeId, from) then
            nextStart = from
        end
    end
    return nextStart
end

-- The scored entry of a remembered recipe, when the planner could choose it
-- itself: it is among the candidates, obtainable and its cost is known.
-- (A pin is the player's choice and may override that; a memory may not.)
local function Replayable(alternatives, recipeId, accept)
    for _, alt in ipairs(alternatives) do
        if alt.recipe.id == recipeId then
            if not alt.recipe._isUnavailable and alt.score < math.huge and (not accept or accept(alt.recipe)) then
                return alt
            end
            return nil
        end
    end
    return nil
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
    -- ctx: optional { rankSale = { [recipeId] = copper }, sale = { [recipeId] = copper },
    --                 replay = { { from, to, recipeId }, ... } }
    --   rankSale  what one craft sells for, for the recipes whose ranking may
    --             use it (a strategy that ranks by cost takes it off)
    --   sale      what one craft sells for, put on the steps (saleEach, sale)
    --   replay    a remembered route to carry on with: where no pin applies,
    --             the remembered recipe of the range covering the simulated
    --             skill is used when the planner could choose it itself, and
    --             its run ends where the range ends. The route's bounds are
    --             expected skills, with fractions; carried on from the very
    --             skill it was planned at (replay.at) they are used as they
    --             are and the same steps come out. From any other skill the
    --             simulation is out of step with them, and the bounds are
    --             read as whole skills - a real skill is a whole number, and
    --             a recipe was meant to change at one. Otherwise every change
    --             of recipe would cost the earlier recipe one more craft.
    -- Without ctx the output is exactly what it was before sale values existed.
    Run = function(_core, self, currentSkill, targetSkill, recipes, inventory, prices, racialBonus, pins, ctx)
        racialBonus = racialBonus or 0
        local scoreCtx = { rankSale = ctx and ctx.rankSale or nil, sale = ctx and ctx.sale or nil, recipes = recipes }
        local replay = ctx and ctx.replay or nil
        local wholeBounds = replay ~= nil and replay.at ~= currentSkill

        -- Can the recipe be crafted for skill-ups at `skill`? (For cutting a
        -- run where a pin or a remembered range begins.) Not one that needs a
        -- specialization the character lacks: it is never a candidate (P121),
        -- so a pin or range naming it must cut nothing either.
        local recipeById
        local function canBegin(recipeId, skill)
            if not recipeById then
                recipeById = {}
                for _, recipe in ipairs(recipes) do
                    recipeById[recipe.id] = recipe
                end
            end
            local recipe = recipeById[recipeId]
            return recipe ~= nil and skill >= recipe.skillRequired
                and (skill - racialBonus) < recipe.skillRange.gray
                and not LazyProf.RecipeAvailability:SpecializationBlocks(recipe)
        end
        local path = {}
        local gaps = {}
        local simulatedSkill = currentSkill
        local simulatedInventory = Utils.DeepCopy(inventory)
        local purchasedRecipes = {}  -- Track recipes we've "bought" in simulation

        while simulatedSkill < targetSkill do
            -- The player's pin covering this skill, if any
            local pin = pins and FindRange(pins, simulatedSkill) or nil
            local pinnedId = pin and pin.recipeId or nil

            -- Get craftable recipes that can still give skillups
            -- Use effective skill (base - bonus) for color calculations
            local candidates = self:GetCandidates(recipes, simulatedSkill, racialBonus)
            local alternatives = ScoreCandidates(self, candidates, simulatedSkill, targetSkill,
                simulatedInventory, prices, racialBonus, purchasedRecipes, nil, scoreCtx)
            local best, bestScore = PickBest(alternatives, pinnedId)
            local bridge = false

            -- Carrying on with a remembered route: its recipe for this skill,
            -- unless the player pinned something here.
            local range = (replay and not pinnedId) and FindRange(replay, simulatedSkill, wholeBounds) or nil
            local followed = nil
            if range then
                local alt = Replayable(alternatives, range.recipeId)
                if alt then
                    best, bestScore, followed = alt.recipe, alt.score, range
                end
            end

            -- (1) Bridge: nothing to choose while green recipes are excluded by the
            -- setting - allow green ones whose chance is still >= BRIDGE_MIN_CHANCE.
            local worthIt = nil
            if not best and not LazyProf.db.profile.includeGreenRecipes then
                local minChance = LazyProf.Constants.BRIDGE_MIN_CHANCE
                local effectiveSkill = simulatedSkill - racialBonus
                local wideCandidates = self:GetCandidates(recipes, simulatedSkill, racialBonus, true)
                local wideAlternatives = ScoreCandidates(self, wideCandidates, simulatedSkill, targetSkill,
                    simulatedInventory, prices, racialBonus, purchasedRecipes, " [bridge: green allowed]", scoreCtx, true)
                local function overFloor(recipe)
                    return Utils.GetSkillUpChance(effectiveSkill, recipe.skillRange) >= minChance
                end
                best, bestScore = PickBest(wideAlternatives, pinnedId, overFloor)
                if range then
                    local alt = Replayable(wideAlternatives, range.recipeId, overFloor)
                    if alt then
                        best, bestScore, followed = alt.recipe, alt.score, range
                    end
                end
                if best then
                    alternatives = wideAlternatives
                    bridge = true
                    worthIt = overFloor
                end
            end

            -- Make the step. A recipe held by a pin or a remembered range that
            -- cannot move the skill (at its grey point a craft gains nothing)
            -- gives way once to the planner's own choice; a choice that cannot
            -- move the skill either is no recipe at all.
            local made = false
            local pinned = (pin ~= nil and best ~= nil and best.id == pinnedId)
            for attempt = 1, 2 do
                if not best then break end

                if self.logScoring and not pinnedId and LazyProf:IsDebugEnabled("scoring") then
                    LazyProf:Debug("scoring", ">>> WINNER: " .. best.name .. " with score " .. string.format("%.2f", bestScore)
                        .. (bridge and " (bridge)" or ""))
                end

                -- Calculate how many to craft (pass recipes for breakpoint detection).
                -- A run that follows a pin or a remembered range ends with it:
                -- the recipe was chosen for that skill range, not beyond. And
                -- no run carries on into a pin or a remembered range that
                -- begins further on.
                local runEnd = targetSkill
                if followed then
                    local rangeEnd = wholeBounds and math.floor(followed.to) or followed.to
                    runEnd = math.min(runEnd, rangeEnd - RANGE_END_TOLERANCE)
                elseif pinned then
                    runEnd = math.min(runEnd, pin.to - RANGE_END_TOLERANCE)
                end
                local nextPin = (pins and #pins > 0) and NextRangeStart(pins, simulatedSkill, false, canBegin) or nil
                if nextPin then
                    runEnd = math.min(runEnd, nextPin - RANGE_END_TOLERANCE)
                end
                if replay and not pinned then
                    local nextRange = NextRangeStart(replay, simulatedSkill, wholeBounds, canBegin)
                    if nextRange then
                        runEnd = math.min(runEnd, nextRange - RANGE_END_TOLERANCE)
                    end
                end
                local quantity = self:CalculateQuantity(best, simulatedSkill, runEnd, recipes, racialBonus)

                -- A bridge stops at the skill where its chance falls under the floor,
                -- so the gap (if any) starts there.
                if bridge then
                    quantity = BridgeCut(self, best, simulatedSkill, quantity, racialBonus)
                end

                local totalSkillups, totalCost = self:CalculateTotalCostAndSkillups(best, simulatedSkill, quantity, simulatedInventory, prices, racialBonus, purchasedRecipes)
                local skillEnd = math.min(simulatedSkill + totalSkillups, targetSkill)

                if skillEnd > simulatedSkill then
                    -- Add step to path (with alternatives for UI). What its
                    -- crafts sell for rides along when sale values were given.
                    local saleEach = scoreCtx.sale and scoreCtx.sale[best.id] or nil
                    table.insert(path, {
                        recipe = best,
                        quantity = quantity,
                        skillStart = simulatedSkill,
                        skillEnd = skillEnd,
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
                    simulatedSkill = skillEnd
                    simulatedInventory = self:ConsumeReagents(simulatedInventory, best, quantity)
                    made = true
                    break
                end

                if attempt == 1 and (pinned or followed) then
                    best, bestScore = PickBest(alternatives, nil, worthIt)
                    pinned, followed = false, nil
                else
                    break
                end
            end

            if not made then
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
