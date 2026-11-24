-- Modules/Pathfinder/Pathfinder.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.Pathfinder = {}
local Pathfinder = LazyProf.Pathfinder

-- Current calculated path
Pathfinder.currentPath = nil

-- Prices of every reagent of the recipes, and of what those reagents are
-- made from (for the craft-or-buy comparison of the shopping list).
local function CollectPrices(recipes)
    local reagentIds = {}
    local seenIds = {}
    for _, recipe in ipairs(recipes) do
        for _, reagent in ipairs(recipe.reagents) do
            if not seenIds[reagent.itemId] then
                seenIds[reagent.itemId] = true
                table.insert(reagentIds, reagent.itemId)
            end
        end
    end

    local CraftLib = _G.CraftLib
    if CraftLib and CraftLib.GetRecipeByProduct then
        for itemId in pairs(seenIds) do
            local craftRecipes = CraftLib:GetRecipeByProduct(itemId)
            if craftRecipes then
                for _, recipeInfo in ipairs(craftRecipes) do
                    if recipeInfo.recipe and recipeInfo.recipe.reagents then
                        for _, reagent in ipairs(recipeInfo.recipe.reagents) do
                            if not seenIds[reagent.itemId] then
                                seenIds[reagent.itemId] = true
                                table.insert(reagentIds, reagent.itemId)
                            end
                        end
                    end
                end
            end
        end
    end

    return LazyProf.PriceManager:GetPrices(reagentIds)
end

-- Run the strategy and build the path object.
-- run: { profKey, profData, recipes, startSkill, actualSkill, reason, planning,
--        hasProfession, planFromOne }
-- The path runs from startSkill to the profession's target (GetTargetSkill).
-- When the start is already at or past the target there is nothing to plan:
-- no steps, no gaps, path.nothingLeft = true.
function Pathfinder:BuildPath(run)
    local profKey, profData = run.profKey, run.profData
    local startSkill, actualSkill = run.startSkill, run.actualSkill
    local milestones = profData.milestones
    local targetSkill = self:GetTargetSkill(profKey, milestones)

    LazyProf:Debug("pathfinder", string.format("Calculating path: %s %d -> %d (actual skill: %d)%s%s",
        profData.name, startSkill, targetSkill, actualSkill,
        run.planning and " (planning)" or "",
        run.reason and (" [" .. run.reason .. "]") or ""))
    LazyProf:Debug("pathfinder", string.format("Settings: strategy=%s, bank=%s, alts=%s, greenRecipes=%s",
        LazyProf.db.profile.strategy,
        tostring(LazyProf.db.profile.includeBankItems),
        tostring(LazyProf.db.profile.includeAltCharacters),
        tostring(LazyProf.db.profile.includeGreenRecipes)))

    -- Pins the real skill has passed are done with; the rest override the
    -- optimizer over their skill range.
    local pins = self:GetPins(profKey)
    if run.hasProfession ~= false then
        LazyProf.Pins.Prune(pins, actualSkill)
    end
    if #pins > 0 and LazyProf:IsDebugEnabled("pathfinder") then
        local pinDetails = {}
        for _, pin in ipairs(pins) do
            table.insert(pinDetails, string.format("%.2f-%.2f -> recipe %s", pin.from, pin.to, tostring(pin.recipeId)))
        end
        LazyProf:Debug("pathfinder", string.format("Active pins (%d): %s", #pins, table.concat(pinDetails, ", ")))
    end

    -- Get inventory (bags + all enabled sources); stockMeta says how old the
    -- remembered part of it is (nil when none of it is remembered)
    local inventory, sourceBreakdown, stockMeta = LazyProf.Inventory:ScanAll()

    -- Log owned materials summary (guarded: GetItemInfo + string building per
    -- owned item runs every recalc and is wasted when debug logging is off)
    if LazyProf:IsDebugEnabled("pathfinder") then
        local ownedCount = 0
        local ownedParts = {}
        for itemId, qty in pairs(inventory) do
            if qty > 0 then
                ownedCount = ownedCount + 1
                if ownedCount <= 15 then
                    local name = Utils.GetItemInfo(itemId)
                    table.insert(ownedParts, string.format("%dx %s", qty, name or itemId))
                end
            end
        end
        if ownedCount > 0 then
            local suffix = ownedCount > 15 and string.format(" ... and %d more", ownedCount - 15) or ""
            LazyProf:Debug("pathfinder", string.format("Owned materials (%d items): %s%s", ownedCount, table.concat(ownedParts, ", "), suffix))
        else
            LazyProf:Debug("pathfinder", "Owned materials: none")
        end
    end

    local prices = CollectPrices(run.recipes)

    -- Get strategy
    local strategyName = LazyProf.db.profile.strategy
    local strategy = LazyProf.PathfinderStrategies[strategyName]
    if not strategy then
        LazyProf:Debug("pathfinder", "Unknown strategy: " .. tostring(strategyName))
        return nil
    end

    -- Get racial profession bonus
    local racialBonus = Utils.GetRacialProfessionBonus(profKey)
    if racialBonus > 0 then
        LazyProf:Debug("pathfinder", string.format("Racial bonus detected: +%d for %s", racialBonus, tostring(profKey)))
    end

    -- What one craft of each usable recipe sells for (by the setting)
    local sale = LazyProf.SaleValue:Build(run.recipes, {
        mode = LazyProf.db.profile.saleValueMode,
        from = startSkill, to = targetSkill, racialBonus = racialBonus,
    })
    -- Crafted items still without data: redraw once when the wait is over.
    if sale.loading > 0 and LazyProf.ScheduleSaleLoadingRefresh then
        LazyProf:ScheduleSaleLoadingRefresh()
    end

    -- Plan the candidate routes and keep the one the player pays least for.
    -- Memoize recipe availability for the duration of this synchronous scoring
    -- pass (IsRecipeAvailable is called per unlearned candidate per step).
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc(inventory)
    -- The route the last calculation kept for this profession is planned as
    -- a candidate too (Cheapest only; Fastest has one route, and a what-if
    -- from skill 1 is not the plan the player follows: neither uses or
    -- replaces what is remembered).
    local store = LazyProf.CharStore:Profession(profKey)
    local remembers = (strategyName == Constants.STRATEGY.CHEAPEST) and not run.planFromOne
    local steps, meta, route = self:PlanRoutes({
        strategy = strategy, strategyName = strategyName,
        startSkill = startSkill, targetSkill = targetSkill, recipes = run.recipes,
        prices = prices, racialBonus = racialBonus, pins = pins,
        inventory = inventory, sourceBreakdown = sourceBreakdown, sale = sale,
        previous = remembers and store.route or nil,
    })
    LazyProf.SelfFound:EndRecalc()
    LazyProf.RecipeAvailability:EndRecalc()
    if remembers then
        if #steps == 0 then
            store.route = nil
        elseif route.kept == "previous" then
            -- The plan in hand goes on: its remembered ranges stay as they
            -- are (rewriting them from each replay would let rounding creep
            -- in), and what was planned beyond them is added.
            store.route = self:ExtendRanges(store.route, steps, startSkill)
        else
            store.route = self:RouteRanges(steps, startSkill)
        end
    end

    -- Build result (totals cover the steps the path has; gaps add nothing)
    local path = {
        profession = profData.name,
        professionKey = profKey,
        planning = run.planning or nil,
        hasProfession = run.hasProfession,
        planFromOne = run.planFromOne or nil,
        currentSkill = startSkill,
        actualSkill = actualSkill,
        targetSkill = targetSkill,
        capSkill = milestones[#milestones],
        milestones = milestones,
        racialBonus = racialBonus,
        steps = steps,
        complete = meta.complete,
        gaps = meta.gaps,
        nothingLeft = (#steps == 0 and #meta.gaps == 0) or nil,
        -- The sum of the planner's step costs. For the market and sale
        -- routes that is the market cost; for a route planned with stock it
        -- is what the simulated stock does not cover. Nothing shown to the
        -- player reads it: totals come from the stages and from Account.
        totalCost = Utils.Sum(steps, "totalCost"),
        -- What the stage builder and the shopping list are computed from
        prices = prices,
        inventory = inventory,
        sourceBreakdown = sourceBreakdown,
        stockMeta = stockMeta,
        -- What the crafts sell for (SaleValue:Build) and which candidate
        -- route was kept (PlanRoutes)
        sale = sale,
        route = route,
    }

    if LazyProf:IsDebugEnabled("pathfinder") then
        LazyProf:Debug("pathfinder", string.format("Path calculated: %d steps, %d gaps, %s total",
            #steps, #meta.gaps, Utils.FormatMoney(path.totalCost)))
        local parts = {}
        for _, candidate in ipairs(route.candidates) do
            parts[#parts + 1] = string.format("%s=%s%s", candidate.key, tostring(candidate.net),
                candidate.eligible and "" or " (covers less)")
        end
        LazyProf:Debug("pathfinder", string.format("Route kept: %s (net copper per candidate: %s)",
            route.kept, table.concat(parts, ", ")))
    end

    return path
end

-- Skill points the gaps leave uncovered.
local function GapLength(gaps)
    local length = 0
    for _, gap in ipairs(gaps or {}) do
        length = length + (gap.to - gap.from)
    end
    return length
end

-- A candidate may leave this much more of the range uncovered than the
-- market-price route and still be kept (a bridge can stop at a fractional skill).
local GAP_TOLERANCE = 1

-- The owned stock a route from startSkill to targetSkill can use: the counts
-- of the reagents of recipes that can be on it. nil when there is none. (The
-- strategy copies its inventory at every step, so it is handed this and not
-- the whole scan.)
local function UsableStock(recipes, inventory, startSkill, targetSkill, racialBonus)
    if not inventory or next(inventory) == nil then return nil end
    local stock
    for _, recipe in ipairs(recipes) do
        local range = recipe.skillRange
        if (recipe.skillRequired or 0) <= targetSkill
                and (not range or (range.gray or math.huge) + racialBonus > startSkill) then
            for _, reagent in ipairs(recipe.reagents or {}) do
                local owned = inventory[reagent.itemId] or 0
                if owned > 0 then
                    stock = stock or {}
                    stock[reagent.itemId] = owned
                end
            end
        end
    end
    return stock
end

-- A route as it is remembered between calculations: one { from, to, recipeId }
-- per run of a recipe (consecutive steps of one recipe joined), in skill
-- order, and `at`, the skill it was planned from (startSkill; the first
-- step's start when not given).
function Pathfinder:RouteRanges(steps, startSkill)
    local ranges = {}
    if type(startSkill) == "number" then
        ranges.at = startSkill
    elseif steps and steps[1] then
        ranges.at = steps[1].skillStart
    end
    local last
    for _, step in ipairs(steps or {}) do
        local id = step.recipe and step.recipe.id
        if id and step.skillStart and step.skillEnd then
            if last and last.recipeId == id and last.to == step.skillStart then
                last.to = step.skillEnd
            else
                last = { from = step.skillStart, to = step.skillEnd, recipeId = id }
                ranges[#ranges + 1] = last
            end
        end
    end
    return ranges
end

-- A remembered route carried on: its ranges that reach past `startSkill`,
-- unchanged, plus every part of what `steps` plan that no remembered range
-- covers (beyond its end after a raised target; a hole left by a pin that was
-- reset). It keeps the skill it was planned from.
function Pathfinder:ExtendRanges(remembered, steps, startSkill)
    local kept = {}
    for _, range in ipairs(remembered or {}) do
        if type(range) == "table" and type(range.to) == "number" and type(range.from) == "number"
                and range.recipeId ~= nil and range.to > range.from and range.to > startSkill then
            kept[#kept + 1] = range
        end
    end
    if #kept == 0 then
        return self:RouteRanges(steps, startSkill)
    end
    table.sort(kept, function(a, b) return a.from < b.from end)

    local ranges = {}
    for _, range in ipairs(kept) do ranges[#ranges + 1] = range end
    for _, planned in ipairs(self:RouteRanges(steps)) do
        -- Walk the remembered ranges and keep the pieces of `planned` between them.
        local from = planned.from
        for _, range in ipairs(kept) do
            if range.to > from and range.from < planned.to then
                if range.from > from then
                    ranges[#ranges + 1] = { from = from, to = range.from, recipeId = planned.recipeId }
                end
                from = math.max(from, range.to)
            end
        end
        if from < planned.to then
            ranges[#ranges + 1] = { from = from, to = planned.to, recipeId = planned.recipeId }
        end
    end
    table.sort(ranges, function(a, b) return a.from < b.from end)
    if type(remembered.at) == "number" then
        ranges.at = remembered.at
    end
    return ranges
end

-- The well-formed ranges of a remembered route that reach past `startSkill`
-- (saved data may be anything), with the skill it was planned at (`at`) when
-- that is known. nil when nothing is left to carry on with.
local function ValidRanges(previous, startSkill)
    if type(previous) ~= "table" then return nil end
    local ranges
    for _, range in ipairs(previous) do
        if type(range) == "table" and type(range.from) == "number" and type(range.to) == "number"
                and range.recipeId ~= nil and range.to > range.from and range.to > startSkill then
            ranges = ranges or {}
            ranges[#ranges + 1] = range
        end
    end
    if ranges and type(previous.at) == "number" then
        ranges.at = previous.at
    end
    return ranges
end

-- Remove [from, to) from a list of remembered ranges, keeping what lies on
-- either side of it. Returns the new list (nil when nothing is left).
local function ClipRanges(ranges, from, to)
    local kept = {}
    for _, range in ipairs(ValidRanges(ranges, -math.huge) or {}) do
        if range.to <= from or range.from >= to then
            kept[#kept + 1] = range
        else
            if range.from < from then
                kept[#kept + 1] = { from = range.from, to = from, recipeId = range.recipeId }
            end
            if range.to > to then
                kept[#kept + 1] = { from = to, to = range.to, recipeId = range.recipeId }
            end
        end
    end
    if #kept == 0 then return nil end
    if type(ranges) == "table" and type(ranges.at) == "number" then
        kept.at = ranges.at
    end
    return kept
end

-- The plan in hand is kept unless another route saves more than this share
-- of what the market route costs with nothing owned. Each replanning rounds
-- crafts a little differently, so two routes that really cost the same differ
-- by a craft or two; switching on that would strand what was bought.
local KEEP_MARGIN = 0.05

-- Plan the candidate routes of one calculation and keep the one the player
-- pays least for.
-- args: strategy, strategyName, startSkill, targetSkill, recipes, prices,
--       racialBonus, pins, inventory, sourceBreakdown (the real stock),
--       sale (SaleValue:Build; may be nil), previous (the route the last
--       calculation kept, as RouteRanges gives it; may be nil)
-- Cheapest builds, in this order:
--   market  market prices, nothing owned, sale values not used for ranking -
--           the route as it was before sale values and stock counted. Always.
--   sale    the same, ranking by cost after what the craft sells for. Only
--           when some recipe has a sale value that may be used for ranking.
--   stock   as "sale" (with whatever sale values may rank), and the owned
--           stock is given to the strategy, which scores it against whole
--           runs. Only when the character owns a reagent a usable recipe takes.
--   previous  the route kept by the last calculation (args.previous, see
--           RouteRanges), carried on from the current skill: where the
--           player pinned nothing, each remembered recipe is used to the end
--           of its skill range (when the planner could still choose it), and
--           whatever lies beyond the remembered route is planned like
--           "stock". Only when such a route reaches past the start and the
--           character owns a usable reagent (nothing was bought for a route
--           while nothing is owned, so nothing can be stranded).
-- Every candidate is costed the same way - Account over its steps with the
-- real stock: what is left to buy, plus recipes, minus what the crafts sell
-- for. Of market, sale and stock the lowest amount wins; a tie keeps the
-- earlier one. The previous route - the plan in hand - is kept instead when
-- it costs no more than the market route and no more than that winner plus a
-- small margin (KEEP_MARGIN): once the player holds the reagents of a plan,
-- many routes cost next to nothing, and without this the planner would wander
-- between them and strand what was bought.
-- Because the market route is always a candidate and the plan in hand is
-- never kept above it, the kept route never costs the player more than the
-- market route by this accounting. A candidate that leaves more of the range
-- uncovered than the market route cannot win by doing less.
-- Any other strategy is one run, costed the same way.
-- Returns steps, meta, route = { kept = key, candidates = { { key, net,
-- spend, sale, gapLength, eligible }, ... }, keepMargin = copper or nil,
-- ms = milliseconds or nil }.
function Pathfinder:PlanRoutes(args)
    local strategy = args.strategy
    local sale = args.sale or {}
    local saleValues = sale.values or {}
    local startedAt = debugprofilestop and debugprofilestop() or nil

    local function build(key, inventory, rankSale, replay)
        local steps, meta = strategy:Calculate(args.startSkill, args.targetSkill, args.recipes, inventory,
            args.prices, args.racialBonus, args.pins, { rankSale = rankSale, sale = saleValues, replay = replay })
        local account = self:Account(steps, args.inventory, args.sourceBreakdown, args.prices, saleValues)
        return {
            key = key, steps = steps, meta = meta,
            net = account.net, spend = account.spend, sale = account.sale,
            gapLength = GapLength(meta.gaps), eligible = true,
        }
    end

    local built = {}
    local previous
    if args.strategyName == Constants.STRATEGY.CHEAPEST then
        built[1] = build("market", {}, nil)
        if sale.rank and next(sale.rank) ~= nil then
            built[#built + 1] = build("sale", {}, sale.rank)
        end
        local stock = UsableStock(args.recipes, args.inventory, args.startSkill, args.targetSkill,
            args.racialBonus or 0)
        if stock then
            built[#built + 1] = build("stock", stock, sale.rank)
            local replay = ValidRanges(args.previous, args.startSkill)
            if replay then
                previous = build("previous", stock, sale.rank, replay)
            end
        end
    else
        built[1] = build(args.strategyName or "route", {}, nil)
    end

    local market = built[1]
    local kept = market
    for i = 2, #built do
        local candidate = built[i]
        candidate.eligible = candidate.gapLength <= market.gapLength + GAP_TOLERANCE
        if candidate.eligible and candidate.net < kept.net then
            kept = candidate
        end
    end

    -- The plan in hand stays unless it is dearer than the market route or
    -- another route is clearly cheaper.
    local keepMargin
    if previous then
        built[#built + 1] = previous
        previous.eligible = previous.gapLength <= market.gapLength + GAP_TOLERANCE
        keepMargin = KEEP_MARGIN * self:Account(market.steps, {}, {}, args.prices).spend
        if previous.eligible and previous.net <= market.net and previous.net <= kept.net + keepMargin then
            kept = previous
        end
    end

    local route = { kept = kept.key, candidates = {}, keepMargin = keepMargin }
    for i, candidate in ipairs(built) do
        route.candidates[i] = {
            key = candidate.key, net = candidate.net, spend = candidate.spend, sale = candidate.sale,
            gapLength = candidate.gapLength, eligible = candidate.eligible,
        }
    end
    if startedAt then
        route.ms = debugprofilestop() - startedAt
    end
    return kept.steps, kept.meta, route
end

-- Calculate the path for the open profession, from the character's real skill.
-- reason: optional string describing what triggered this calculation
function Pathfinder:Calculate(reason)
    -- Get active profession
    local profData = LazyProf.Professions:GetActive()
    if not profData then
        LazyProf:Debug("pathfinder", "No active profession detected")
        return nil
    end

    -- Get current skill level
    local _, currentSkill = LazyProf.Client:GetLine()
    if not currentSkill then
        LazyProf:Debug("pathfinder", "Could not get current skill")
        return nil
    end

    local profKey = LazyProf.Professions.active
    self.currentPath = self:BuildPath({
        profKey = profKey,
        profData = profData,
        -- Recipes with learned status from the open window
        recipes = LazyProf.Professions:GetRecipesWithLearnedStatus(profKey),
        startSkill = currentSkill,
        actualSkill = currentSkill,
        hasProfession = true,
        reason = reason,
    })
    return self.currentPath
end

-- Calculate the path for any profession, without its window (planning).
-- A profession the character has is planned from the real skill; one not
-- learned yet from 1. opts.planFromOne plans a learned profession from 1 as a
-- what-if (the window then lists the runs already done too, dimmed).
-- opts: { planFromOne = bool, reason = string }
function Pathfinder:CalculateForProfession(profKey, opts)
    opts = opts or {}
    local profData = LazyProf.Professions:Get(profKey)
    if not profData then
        LazyProf:Debug("pathfinder", "Profession not found: " .. tostring(profKey))
        return nil
    end

    -- A learned profession starts at 1, not 0
    local realSkill = LazyProf.Client:PlayerSkill(profKey) or 0
    local hasProfession = realSkill > 0
    local actualSkill = math.max(1, realSkill)
    local planFromOne = hasProfession and opts.planFromOne and true or false
    local startSkill = (hasProfession and not planFromOne) and actualSkill or 1

    -- Learned status from the cache the profession window fills
    local recipes = LazyProf.Utils.DeepCopy(profData.recipes)
    local cachedLearned = LazyProf.db.char.learnedRecipes and LazyProf.db.char.learnedRecipes[profKey] or {}
    for _, recipe in ipairs(recipes) do
        recipe.learned = cachedLearned[recipe.id] or false
    end

    return self:BuildPath({
        profKey = profKey,
        profData = profData,
        recipes = recipes,
        startSkill = startSkill,
        actualSkill = actualSkill,
        hasProfession = hasProfession,
        planFromOne = planFromOne,
        planning = true,
        reason = opts.reason,
    })
end

-- The skill a profession's path runs to: the target the player set for it,
-- never above the last cap; the last cap when none is set.
function Pathfinder:GetTargetSkill(profKey, milestones)
    local cap = milestones[#milestones]
    local stored = profKey and LazyProf.CharStore:Profession(profKey).target
    if stored and stored < cap then
        return stored
    end
    return cap
end

-- Set a profession's target from what the player typed. The value is clamped
-- to [real skill + 1, last cap]; returns the value in force so the input box
-- can show the correction. A target equal to the cap is stored as "none", so
-- it follows the cap.
function Pathfinder:SetTargetSkill(profKey, value, actualSkill, milestones)
    local cap = milestones[#milestones]
    value = math.floor(tonumber(value) or cap)
    local low = math.min((actualSkill or 0) + 1, cap)
    value = math.max(low, math.min(cap, value))
    LazyProf.CharStore:Profession(profKey).target = (value < cap) and value or nil
    return value
end

-- Whole copper: a price can be a fraction of a copper, a cost that is shown
-- and added up cannot.
local function WholeCopper(copper)
    return math.floor(copper + 0.5)
end

-- One-time cost of getting an unlearned recipe (0 when learned, free or
-- unknown), in whole copper.
local function RecipeCost(recipe)
    local info = recipe and not recipe.learned and recipe._sourceInfo
    if not info then return 0 end
    if info.type == "trainer" or info.type == "vendor" then
        return WholeCopper(info.cost or 0)
    elseif info.type == "ah" then
        return WholeCopper(info.price or 0)
    end
    return 0
end

-- Calculate the shopping list of a set of steps (path steps, or the craft
-- stages' { recipe, quantity, skillStart } entries). This is the addon's one
-- accounting of what the player pays for reagents and recipes (see Account).
-- The stock comes only from its arguments: `inventory` is what the character
-- owns across the enabled sources and `sourceBreakdown` says where (bags,
-- bank, mail, auctions, guildBank, alts). Nothing is scanned here, so it can
-- be asked "what if nothing were owned" with two empty tables. (It also
-- reads the settings that decide craft-or-buy - the strategy, the material
-- resolution mode, the per-item choices - and the price manager's record of
-- where each price came from.)
-- Returns the per-source lists { fromBank, fromMail, fromAuctions,
-- fromGuildBank, fromAlts, toCraft, fromAH, recipeCosts } and, for the
-- Shopping tab, one row per item in `rows`:
--   itemId, name, icon, link, firstUsedAtSkill
--   need        how many the steps use (as a reagent, and to craft other rows)
--   have        how many the character owns across the enabled sources
--   inBags      of those, in the bags
--   sources     what to collect first: { bank, mail, auctions, guildBank, alts } counts
--   toBuy       what is left to buy
--   unitPrice   nil when the item has no price (unpriced = true); cost = unitPrice x toBuy,
--               in whole copper
--   priceSource the price's source ("Vendor", "TSM", ...); isVendor = sold by a vendor
--   craftable   a recipe the character can craft makes it
--   choice      the player's choice for the item ("craft" / "buy"), nil = automatic
--   crafted     the item is crafted, not bought: craftRecipeName, professionKey,
--               craftQuantity, craftCost and children = { { itemId, name, need }, ... }.
--               Owned stock of the item itself is used before any is crafted;
--               what other crafted reagents take of it is bought (resolution is
--               one level deep) and shows as the row's toBuy and cost.
-- buyTotal, the sum of the rows' (whole-copper) costs, and recipeRows = { { recipe, name,
-- cost, sourceInfo, currency }, ... }: one per unlearned recipe that costs
-- something, by name - gold (cost), a currency (the source's currency table;
-- cost is 0 when it is the only price) or both; recipeCosts is the gold.
function Pathfinder:CalculateMissingMaterials(steps, inventory, sourceBreakdown, prices)
    local needed = {}

    -- Sum up all reagents needed (preserve name from CraftLib as fallback)
    for _, step in ipairs(steps) do
        for _, reagent in ipairs(step.recipe.reagents) do
            local itemId = reagent.itemId
            if not needed[itemId] then
                needed[itemId] = { count = 0, nameFromData = reagent.name, firstUsedAtSkill = step.skillStart }
            else
                needed[itemId].firstUsedAtSkill = math.min(needed[itemId].firstUsedAtSkill, step.skillStart)
            end
            needed[itemId].count = needed[itemId].count + (reagent.count * step.quantity)
        end
    end

    -- Automatic craft-or-buy follows the setting, under the Cheapest strategy
    -- only; an explicit per-item choice applies under both strategies.
    local resolutionMode = Constants.MATERIAL_RESOLUTION.NONE
    if LazyProf.db.profile.strategy == Constants.STRATEGY.CHEAPEST then
        resolutionMode = LazyProf.db.profile.materialResolution
    end
    local choices = LazyProf.CharStore and LazyProf.CharStore:Get().craftChoices or {}

    -- Track intermediate crafts and resolved materials
    local toCraft = {}
    local resolvedNeeded = {} -- Final materials after resolution
    local bankPurpose = {}    -- Track why bank items are needed (for annotations)
    local rowsById = {}       -- one shopping row per item

    local function addResolved(itemId, count, nameFromData, firstUsedAtSkill)
        local entry = resolvedNeeded[itemId]
        if not entry then
            entry = { count = 0, nameFromData = nameFromData, firstUsedAtSkill = firstUsedAtSkill }
            resolvedNeeded[itemId] = entry
        else
            entry.firstUsedAtSkill = math.min(entry.firstUsedAtSkill, firstUsedAtSkill)
        end
        entry.count = entry.count + count
    end

    -- Helper: get per-source count from sourceBreakdown
    local function getSourceCount(itemId, sourceKey)
        local bd = sourceBreakdown and sourceBreakdown[itemId]
        if not bd then return 0 end
        return bd[sourceKey] or 0
    end

    -- What the craft-or-buy comparison may count on as stock for making
    -- other reagents: what is owned, less what the steps use of it directly;
    -- every crafted reagent then takes its share off, so no unit is counted
    -- twice. Items are decided in a fixed order (first use, then id).
    local available = {}
    for itemId, count in pairs(inventory) do
        available[itemId] = count
    end
    local order = {}
    for itemId, data in pairs(needed) do
        available[itemId] = math.max(0, (available[itemId] or 0) - data.count)
        order[#order + 1] = itemId
    end
    table.sort(order, function(a, b)
        local skillA, skillB = needed[a].firstUsedAtSkill, needed[b].firstUsedAtSkill
        if skillA ~= skillB then return skillA < skillB end
        return a < b
    end)

    -- Process each needed material through MaterialResolver
    for _, itemId in ipairs(order) do
        local data = needed[itemId]
        local need = data.count
        local inBags = getSourceCount(itemId, "bags")
        -- Owned stock of the item itself (every enabled source) is used
        -- before any of it is crafted.
        local owned = math.min(need, inventory[itemId] or 0)
        local toMake = need - owned
        local choice = choices[itemId]
        local resolution = nil
        if LazyProf.MaterialResolver then
            -- Asked for at least one so "can the character craft it" is known
            -- even when the stock already covers the need.
            resolution = LazyProf.MaterialResolver:ResolveMaterial(
                itemId, math.max(toMake, 1), available, prices, {}, resolutionMode, choice
            )
        end
        local craftable = resolution and resolution.craftable or false

        if toMake > 0 and resolution and resolution.shouldCraft and resolution.craftRecipe then
            -- Add to toCraft list
            local name, link, icon = Utils.GetItemInfo(itemId)
            name = name or data.nameFromData or "Unknown"
            icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"
            local recipeName = resolution.craftRecipe.name or "Unknown Recipe"

            -- Calculate source material breakdown
            local sourceFromBank = 0
            local sourceFromAH = 0
            local sourceMaterialName = ""
            local children = {}

            for _, source in ipairs(resolution.sourceItems) do
                sourceFromBank = sourceFromBank + source.fromInventory
                sourceFromAH = sourceFromAH + source.toBuy
                sourceMaterialName = source.name or "Unknown"
                available[source.itemId] = math.max(0, (available[source.itemId] or 0) - source.fromInventory)

                addResolved(source.itemId, source.totalNeeded, source.name, data.firstUsedAtSkill)
                children[#children + 1] = { itemId = source.itemId, name = source.name or "Unknown", need = source.totalNeeded }

                if source.fromInventory > 0 then
                    bankPurpose[source.itemId] = string.format("for %s", recipeName:lower())
                end
            end

            -- Build source description for UI
            local totalSourceNeeded = sourceFromBank + sourceFromAH
            local sourceDesc = string.format("%dx %s", totalSourceNeeded, sourceMaterialName)
            local usingDesc = ""
            if sourceFromBank > 0 and sourceFromAH > 0 then
                usingDesc = string.format("%dx from inventory + %dx from AH", sourceFromBank, sourceFromAH)
            elseif sourceFromBank > 0 then
                usingDesc = string.format("%dx from inventory", sourceFromBank)
            else
                usingDesc = string.format("%dx from AH", sourceFromAH)
            end

            table.insert(toCraft, {
                itemId = itemId,
                name = name,
                icon = icon,
                link = link,
                quantity = toMake,
                recipeName = recipeName,
                professionKey = resolution.professionKey,
                sourceDesc = sourceDesc,
                usingDesc = usingDesc,
                craftCost = resolution.craftCost,
                sourceItems = resolution.sourceItems,
                firstUsedAtSkill = data.firstUsedAtSkill,
            })

            -- The owned part goes through the same waterfall as bought
            -- reagents, so it shows under "collect first".
            if owned > 0 then
                addResolved(itemId, owned, data.nameFromData, data.firstUsedAtSkill)
            end

            rowsById[itemId] = {
                itemId = itemId, name = name, icon = icon, link = link,
                firstUsedAtSkill = data.firstUsedAtSkill,
                need = need, have = inventory[itemId] or 0, inBags = inBags, sources = {},
                toBuy = 0, cost = 0, unitPrice = prices[itemId],
                craftable = true, choice = choice, crafted = true,
                craftRecipeName = recipeName, professionKey = resolution.professionKey,
                craftQuantity = toMake, craftCost = resolution.craftCost, children = children,
                ownedUse = owned,
            }
        else
            -- Bought (or already owned): its full need goes on, so an item
            -- that is also the source of a crafted one is counted once, whole.
            addResolved(itemId, need, data.nameFromData, data.firstUsedAtSkill)
            rowsById[itemId] = { itemId = itemId, craftable = craftable, choice = choice, crafted = false }
        end
    end

    -- Categorize resolved materials by source (waterfall: most accessible first)
    local fromBank = {}
    local fromMail = {}
    local fromAuctions = {}
    local fromGuildBank = {}
    local fromAlts = {}
    local fromAH = {}

    -- Helper: get total alt count for an item across all sources
    local function getAltTotal(itemId)
        local bd = sourceBreakdown and sourceBreakdown[itemId]
        if not bd or not bd.alts then return 0 end
        local total = 0
        for _, charSources in pairs(bd.alts) do
            for _, count in pairs(charSources) do
                total = total + count
            end
        end
        return total
    end

    local pm = LazyProf.PriceManager

    for itemId, data in pairs(resolvedNeeded) do
        local need = data.count
        local inBags = getSourceCount(itemId, "bags")
        local totalHave = inventory[itemId] or 0

        -- How many do we still need after bags?
        local remaining = math.max(0, need - inBags)

        local name, link, icon = Utils.GetItemInfo(itemId)
        local price = prices[itemId] or 0
        name = name or data.nameFromData or "Unknown"
        icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"

        -- Waterfall: bank -> mail -> auctions -> guildBank -> alts -> AH

        -- 1. Bank
        local inBank = getSourceCount(itemId, "bank")
        local fromBankCount = math.min(remaining, inBank)
        remaining = remaining - fromBankCount

        -- 2. Mail
        local inMail = getSourceCount(itemId, "mail")
        local fromMailCount = math.min(remaining, inMail)
        remaining = remaining - fromMailCount

        -- 3. Auctions (active AH listings)
        local inAuctions = getSourceCount(itemId, "auctions")
        local fromAuctionsCount = math.min(remaining, inAuctions)
        remaining = remaining - fromAuctionsCount

        -- 4. Guild bank
        local inGuildBank = getSourceCount(itemId, "guildBank")
        local fromGuildBankCount = math.min(remaining, inGuildBank)
        remaining = remaining - fromGuildBankCount

        -- 5. Alts (with per-character breakdown)
        local fromAltCount = 0
        local altCharacters = {}
        local bd = sourceBreakdown and sourceBreakdown[itemId]
        if remaining > 0 and bd and bd.alts then
            local altRemaining = remaining
            for charName, charSources in pairs(bd.alts) do
                local charTotal = 0
                for _, count in pairs(charSources) do
                    charTotal = charTotal + count
                end
                local useFromChar = math.min(altRemaining, charTotal)
                if useFromChar > 0 then
                    fromAltCount = fromAltCount + useFromChar
                    altRemaining = altRemaining - useFromChar
                    table.insert(altCharacters, { name = charName, count = useFromChar })
                end
                if altRemaining <= 0 then break end
            end
            remaining = remaining - fromAltCount
        end

        -- 6. AH (remainder)
        local fromAHCount = remaining

        -- The item's shopping row
        local row = rowsById[itemId] or { itemId = itemId, craftable = false, crafted = false }
        rowsById[itemId] = row
        local info = pm and pm.PeekPriceInfo and pm:PeekPriceInfo(itemId) or nil
        local sources = {
            bank = fromBankCount, mail = fromMailCount, auctions = fromAuctionsCount,
            guildBank = fromGuildBankCount, alts = fromAltCount,
        }
        if row.crafted then
            -- `need` here is the owned part used before crafting plus what
            -- other crafted reagents take of this one; the latter is bought.
            row.need = row.need + (need - (row.ownedUse or 0))
            row.sources = sources
            row.toBuy = fromAHCount
            row.cost = WholeCopper(price * fromAHCount)
            row.unpriced = (fromAHCount > 0 and prices[itemId] == nil) or nil
            row.priceSource = info and info.source or nil
            row.isVendor = (info ~= nil and info.source == "Vendor")
        else
            row.name, row.icon, row.link = name, icon, link
            row.firstUsedAtSkill = data.firstUsedAtSkill
            row.need = need
            row.have = totalHave
            row.inBags = inBags
            row.sources = sources
            row.toBuy = fromAHCount
            row.unitPrice = prices[itemId]
            row.unpriced = (prices[itemId] == nil) or nil
            row.cost = WholeCopper(price * fromAHCount)
            row.priceSource = info and info.source or nil
            row.isVendor = (info ~= nil and info.source == "Vendor")
        end

        -- Build result entries for each source
        if fromBankCount > 0 then
            local purpose = bankPurpose[itemId]
            table.insert(fromBank, {
                itemId = itemId,
                name = name,
                icon = icon,
                link = link,
                have = inBank,
                need = fromBankCount,
                missing = fromBankCount,
                estimatedCost = 0,
                purpose = purpose,
                firstUsedAtSkill = data.firstUsedAtSkill,
            })
        end

        if fromMailCount > 0 then
            table.insert(fromMail, {
                itemId = itemId,
                name = name,
                icon = icon,
                link = link,
                have = inMail,
                missing = fromMailCount,
                firstUsedAtSkill = data.firstUsedAtSkill,
            })
        end

        if fromAuctionsCount > 0 then
            table.insert(fromAuctions, {
                itemId = itemId,
                name = name,
                icon = icon,
                link = link,
                have = inAuctions,
                missing = fromAuctionsCount,
                firstUsedAtSkill = data.firstUsedAtSkill,
            })
        end

        if fromGuildBankCount > 0 then
            table.insert(fromGuildBank, {
                itemId = itemId,
                name = name,
                icon = icon,
                link = link,
                have = inGuildBank,
                missing = fromGuildBankCount,
                firstUsedAtSkill = data.firstUsedAtSkill,
            })
        end

        if fromAltCount > 0 then
            table.insert(fromAlts, {
                itemId = itemId,
                name = name,
                icon = icon,
                link = link,
                missing = fromAltCount,
                have = getAltTotal(itemId),
                characters = altCharacters,
                firstUsedAtSkill = data.firstUsedAtSkill,
            })
        end

        if fromAHCount > 0 then
            table.insert(fromAH, {
                itemId = itemId,
                name = name,
                icon = icon,
                link = link,
                have = totalHave,
                need = need,
                missing = fromAHCount,
                estimatedCost = WholeCopper(price * fromAHCount),
                firstUsedAtSkill = data.firstUsedAtSkill,
            })
        end
    end

    -- Sort by skill level when materials are first consumed, then by name
    local function sortBySkillThenName(a, b)
        if a.firstUsedAtSkill ~= b.firstUsedAtSkill then
            return a.firstUsedAtSkill < b.firstUsedAtSkill
        end
        return (a.name or "") < (b.name or "")
    end
    table.sort(fromBank, sortBySkillThenName)
    table.sort(fromMail, sortBySkillThenName)
    table.sort(fromAuctions, sortBySkillThenName)
    table.sort(fromGuildBank, sortBySkillThenName)
    table.sort(fromAlts, sortBySkillThenName)
    table.sort(fromAH, sortBySkillThenName)
    table.sort(toCraft, sortBySkillThenName)

    local rows = {}
    local buyTotal = 0
    for _, row in pairs(rowsById) do
        rows[#rows + 1] = row
        buyTotal = buyTotal + (row.cost or 0)
    end
    table.sort(rows, sortBySkillThenName)

    -- One-time costs of the recipes still to learn
    local seenRecipes = {}
    local recipeRows = {}
    local recipeCosts = 0
    for _, step in ipairs(steps) do
        local recipe = step.recipe
        if not seenRecipes[recipe.id] then
            seenRecipes[recipe.id] = true
            local cost = RecipeCost(recipe)
            -- A recipe paid for with a currency costs something too.
            local info = (not recipe.learned) and recipe._sourceInfo or nil
            local currency = (info and Utils.FormatCurrency(info.currency)) and info.currency or nil
            if cost > 0 or currency then
                recipeRows[#recipeRows + 1] = {
                    recipe = recipe, name = recipe.name or "Unknown", cost = cost, sourceInfo = recipe._sourceInfo,
                    currency = currency,
                }
                recipeCosts = recipeCosts + cost
            end
        end
    end
    table.sort(recipeRows, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.recipe.id) < tostring(b.recipe.id)
    end)

    return {
        fromBank = fromBank,
        fromMail = fromMail,
        fromAuctions = fromAuctions,
        fromGuildBank = fromGuildBank,
        fromAlts = fromAlts,
        toCraft = toCraft,
        fromAH = fromAH,
        recipeCosts = recipeCosts,
        recipeRows = recipeRows,
        rows = rows,
        buyTotal = buyTotal,
    }
end

-- What a set of craft steps costs the player: the shopping list of the steps
-- (CalculateMissingMaterials), minus what the crafts sell for. The choice
-- between candidate routes uses this, and totals shown to the player are to
-- be built from it and from nothing else.
--   saleValues  { [recipeId] = copper per craft } or nil
-- Returns { missing, reagents, recipes, spend, sale, net }:
--   reagents = the shopping rows' costs, recipes = the recipes still to learn,
--   spend = reagents + recipes, sale = crafts x sale value, net = spend - sale.
function Pathfinder:Account(steps, inventory, sourceBreakdown, prices, saleValues)
    local missing = self:CalculateMissingMaterials(steps, inventory or {}, sourceBreakdown or {}, prices or {})
    local sale = 0
    if saleValues then
        for _, step in ipairs(steps) do
            sale = sale + step.quantity * (saleValues[step.recipe.id] or 0)
        end
    end
    local spend = missing.buyTotal + missing.recipeCosts
    return {
        missing = missing,
        reagents = missing.buyTotal,
        recipes = missing.recipeCosts,
        spend = spend,
        sale = sale,
        net = spend - sale,
    }
end

-- How much less the player spends on the steps thanks to owned stock: the
-- same accounting with nothing owned, minus `spend`. Never below zero.
function Pathfinder:StockSaving(steps, prices, spend)
    local without = self:Account(steps, {}, {}, prices)
    return math.max(0, without.spend - (spend or 0))
end

-- The step the arrow points at: the first step the player's real skill has not
-- finished. Inside a gap, or past the last step, there is no step to point at
-- (returns nil). A path without a real skill (actualSkill nil) points at its
-- first step.
function Pathfinder:GetArrowStep(path)
    if not path or not path.steps or #path.steps == 0 then
        return nil
    end
    local actual = path.actualSkill
    if not actual then
        return path.steps[1]
    end
    for _, gap in ipairs(path.gaps or {}) do
        if actual >= gap.from and actual < gap.to then
            return nil
        end
    end
    for _, step in ipairs(path.steps) do
        if step.skillEnd and step.skillEnd > actual then
            return step
        end
    end
    return nil  -- past the last step: nothing left to point at
end

-- Pins (see Modules/Pathfinder/Pins.lua): saved per character and profession.

-- Choosing or resetting a recipe over a skill range is the player planning
-- that range again: what the last calculation remembered there (see
-- PlanRoutes, "previous") is dropped, so the planner's own choice comes back
-- where a pin was removed. The rest of the remembered route stays. Without a
-- range everything remembered is dropped.
function Pathfinder:ForgetRoute(profKey, from, to)
    if not profKey then return end
    local store = LazyProf.CharStore:Profession(profKey)
    if from and to then
        store.route = ClipRanges(store.route, from, to)
    else
        store.route = nil
    end
end

-- The profession's pin list (the saved table itself).
function Pathfinder:GetPins(profKey)
    if not profKey then return {} end
    return LazyProf.CharStore:Profession(profKey).pins
end

-- Recipe id pinned at a skill, nil when none.
function Pathfinder:PinnedAt(profKey, skill)
    return LazyProf.Pins.Find(self:GetPins(profKey), skill)
end

-- Pin a recipe over a skill range; it replaces any pin it overlaps. The
-- caller recalculates.
function Pathfinder:PinRange(profKey, from, to, recipeId)
    LazyProf.Pins.Add(self:GetPins(profKey), from, to, recipeId)
    self:ForgetRoute(profKey, from, to)
    LazyProf:Debug("pathfinder", string.format("Pinned recipe %s for %s %.2f-%.2f",
        tostring(recipeId), tostring(profKey), from, to))
end

-- Remove the pin covering a skill.
function Pathfinder:UnpinAt(profKey, skill)
    for _, pin in ipairs(self:GetPins(profKey)) do
        if skill >= pin.from and skill < pin.to then
            self:ForgetRoute(profKey, pin.from, pin.to)
            break
        end
    end
    if LazyProf.Pins.RemoveAt(self:GetPins(profKey), skill) then
        LazyProf:Debug("pathfinder", string.format("Unpinned %s at %.2f", tostring(profKey), skill))
    end
end

-- Remove every pin of a profession.
function Pathfinder:ClearPins(profKey)
    self:ForgetRoute(profKey)
    local pins = self:GetPins(profKey)
    for i = #pins, 1, -1 do
        pins[i] = nil
    end
end
