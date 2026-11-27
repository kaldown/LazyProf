-- Modules/Pathfinder/Strategies/Cheapest.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.PathfinderStrategies = LazyProf.PathfinderStrategies or {}

LazyProf.PathfinderStrategies.cheapest = {
    name = "Cheapest",
    logScoring = true,

    -- Calculate optimal path from currentSkill to targetSkill
    -- racialBonus: skill bonus from racial trait (e.g., Gnome +15 Engineering)
    --              This extends how long recipes stay orange/yellow/green
    -- pinnedRecipes: optional pin list ({ from, to, recipeId } ranges, see Pins.lua) overriding best picks
    -- ctx: optional sale values, see StrategyCore.Run
    Calculate = function(self, currentSkill, targetSkill, recipes, inventory, prices, racialBonus, pinnedRecipes, ctx)
        return LazyProf.StrategyCore:Run(self, currentSkill, targetSkill, recipes, inventory, prices, racialBonus, pinnedRecipes, ctx)
    end,

    -- Get recipes that can be crafted and give skillups at current skill
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    -- includeGreen: optional; true allows green recipes regardless of the setting
    --               (used to bridge a range with no orange/yellow recipe)
    GetCandidates = function(self, recipes, currentSkill, racialBonus, includeGreen)
        racialBonus = racialBonus or 0
        local allowGreen = includeGreen or LazyProf.db.profile.includeGreenRecipes
        local candidates = {}
        -- Effective skill for color calculations (racial bonus extends color ranges)
        local effectiveSkill = currentSkill - racialBonus

        for _, recipe in ipairs(recipes) do
            -- Can learn/craft at current skill? (uses base skill, not effective)
            if currentSkill >= recipe.skillRequired then
                -- Not gray yet? (uses effective skill for color check)
                if effectiveSkill < recipe.skillRange.gray then
                    -- Skip green recipes unless setting enabled
                    local color = Utils.GetSkillColor(effectiveSkill, recipe.skillRange)
                    if color == "green" and not allowGreen then
                        -- Green recipes excluded by setting
                    elseif LazyProf.RecipeAvailability:SpecializationBlocks(recipe) then
                        -- Needs a specialization the character does not know
                        -- (or one the data cannot name): left out entirely, so
                        -- it is never an alternative, a pin or a remembered
                        -- route's pick, and no pattern in the bags or Self-Found
                        -- rule can bring it back (P121).
                    elseif recipe.learned then
                        -- Already learned - always available
                        recipe._isUnavailable = nil
                        recipe._sourceInfo = nil
                        LazyProf.SelfFound:MarkRecipe(recipe)
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
                        LazyProf.SelfFound:MarkRecipe(recipe)
                        table.insert(candidates, recipe)
                    end
                end
            end
        end

        return candidates
    end,

    -- Score recipe: lower = better
    -- Score based on cost-per-skillup at CURRENT skill level, with bonuses for flexibility
    -- IMPORTANT: Uses the cost of the materials to buy, not their full market value
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    -- purchasedRecipes: table of recipe IDs already "bought" in this simulation
    -- ctx: optional run context (StrategyCore.Run); ctx.rankSale[recipeId] is
    --      what one craft sells for, when that may be used for ranking
    -- Returns score, leaves. `leaves` is set only for a recipe that costs
    -- nothing once what its craft sells for is taken off (or its reagents are
    -- owned): what one craft leaves the player, at least zero. The zero floor
    -- cannot tell such recipes apart, so they are ranked by it, first
    -- (StrategyCore.ScoreCandidates; ruling P130).
    ScoreRecipe = function(self, recipe, currentSkill, targetSkill, inventory, prices, racialBonus, purchasedRecipes, ctx)
        racialBonus = racialBonus or 0
        purchasedRecipes = purchasedRecipes or {}
        local effectiveSkill = currentSkill - racialBonus

        -- Unavailable recipes: display-only in alternatives, never auto-selected
        if recipe._isUnavailable then
            return math.huge
        end

        -- Cost per craft: only what has to be BOUGHT, with owned stock counted
        -- against the whole run (StrategyCore.ReagentCostPerCraft). A reagent
        -- without a price makes the cost unknown: the recipe is not ranked.
        local actualCost, priced = LazyProf.StrategyCore.ReagentCostPerCraft(self, recipe, currentSkill, targetSkill,
            inventory, prices, racialBonus, ctx)
        if not priced then
            return math.huge
        end
        local reagentCost = actualCost

        -- Add recipe acquisition cost for unlearned recipes (amortized over expected uses)
        -- Free if: already learned, already purchased in simulation, or recipe item in inventory
        -- Costs if: trainer, vendor, or AH purchase required
        local recipeCost = 0
        if not recipe.learned and not purchasedRecipes[recipe.id] and recipe._sourceInfo then
            local srcType = recipe._sourceInfo.type
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

        -- What the craft sells for comes off its cost, down to zero and no
        -- further: with a negative cost the cost per skill-up would improve
        -- as the skill-up chance falls, so a recipe that pays for itself
        -- would rank better the less often it gives a point.
        local saleValue = ctx and ctx.rankSale and ctx.rankSale[recipe.id]
        if saleValue and saleValue > 0 then
            actualCost = math.max(0, actualCost - saleValue)
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

        -- A recipe that costs nothing: what one craft leaves the player. Per
        -- craft, not per skill-up, and with the recipe's fee spread over the
        -- skill points left rather than over the crafts (spread over crafts,
        -- the share per craft would shrink as the chance falls): a lower
        -- chance never makes it larger.
        local leaves = nil
        if actualCost <= 0 then
            local feePerPoint = 0
            if recipeCost > 0 then
                local stopAt = math.min(targetSkill, recipe.skillRange.gray + racialBonus)
                feePerPoint = recipeCost / math.max(1, math.ceil(stopAt - currentSkill))
            end
            leaves = math.max(0, (saleValue or 0) - reagentCost - feePerPoint)
        end

        return costPerSkillup + rangeBonus + difficultyBonus, leaves
    end,

    -- Calculate total cost and skillups for a given quantity (used after best is chosen)
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    -- purchasedRecipes: table of recipe IDs already "bought" in this simulation (skip their acquisition cost)
    CalculateTotalCostAndSkillups = function(self, recipe, currentSkill, quantity, inventory, prices, racialBonus, purchasedRecipes)
        racialBonus = racialBonus or 0
        purchasedRecipes = purchasedRecipes or {}
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
        -- Skip if already purchased in a prior step of this simulation
        if not recipe.learned and not purchasedRecipes[recipe.id] and recipe._sourceInfo then
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
            local skillupChance = Utils.GetSkillUpChance(effSkill, recipe.skillRange)

            if skillupChance <= 0 then
                break
            end

            -- Expected crafts for 1 skill point at this probability
            totalCrafts = totalCrafts + (1 / skillupChance)
            simSkill = simSkill + 1
        end

        return math.max(1, totalCrafts)  -- At least 1 to avoid division by zero
    end,

    -- Calculate how many crafts until next breakpoint
    -- Breakpoints: gray, target, new recipe unlocks, or color changes
    -- racialBonus: extends color ranges (e.g., Gnome +15 Engineering)
    -- nextUnlock: optional; the lowest skill above currentSkill at which a recipe
    --             unlocks when the caller already knows it (false: none), so
    --             the recipe list is not walked again
    CalculateQuantity = function(self, recipe, currentSkill, targetSkill, recipes, racialBonus, nextUnlock)
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
        if nextUnlock ~= nil then
            if nextUnlock and nextUnlock < nextBreakpoint then
                nextBreakpoint = nextUnlock
            end
        elseif recipes then
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
