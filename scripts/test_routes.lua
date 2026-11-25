-- scripts/test_routes.lua
--
-- The route the planner keeps. Cheapest ranks recipes by what a craft costs
-- after what it sells for and builds candidate routes (market prices / ranked
-- with sale value), keeping the one the player pays least for - so no route
-- is dearer for the player than the market-price route.
--
-- Run from the addon root:  lua5.1 scripts/test_routes.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

local STRATEGY_FILES = {
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Client/Family.lua",
    "Core/Client/Classic.lua",
    "Core/Config.lua",
    "Core/CharStore.lua",
    "Modules/Recipes/Availability.lua",
    "Modules/Recipes/SelfFound.lua",
    "Modules/Pathfinder/Pins.lua",
    "Modules/Pathfinder/StrategyCore.lua",
    "Modules/Pathfinder/Strategies/Cheapest.lua",
    "Modules/Pathfinder/Strategies/Fastest.lua",
}

-- A fresh addon with synthetic recipes. An unlearned recipe is obtainable
-- when the fixture gives it a `_testSource` (what availability would resolve).
local function load(files)
    harness.stubWow({ interface = 11508 })
    local LazyProf = harness.loadLazyProf(files or STRATEGY_FILES)
    LazyProf.RecipeAvailability.IsRecipeAvailable = function(_, recipe)
        return recipe._testSource ~= nil, recipe._testSource
    end
    return LazyProf
end

local function recipe(id, name, opts)
    opts = opts or {}
    return {
        id = id, name = name, itemId = opts.itemId, learned = not opts.source,
        skillRequired = opts.required or opts.orange or 100,
        skillRange = { orange = opts.orange or 100, yellow = opts.yellow or 120,
                       green = opts.green or 130, gray = opts.gray or 140 },
        reagents = opts.reagents,
        _testSource = opts.source,
    }
end

local function run(LazyProf, strategyName, from, to, recipes, inventory, prices, ctx)
    local strategy = LazyProf.PathfinderStrategies[strategyName]
    LazyProf.db.profile.strategy = strategyName
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local steps, meta = strategy:Calculate(from, to, recipes, inventory or {}, prices, 0, {}, ctx)
    LazyProf.SelfFound:EndRecalc()
    LazyProf.RecipeAvailability:EndRecalc()
    return steps, meta
end

local function onlyRecipe(steps)
    local id
    for _, step in ipairs(steps) do
        if id and step.recipe.id ~= id then return "mixed" end
        id = step.recipe.id
    end
    return id
end

-- The owner's example: two recipes need the same leather, one sells for 30s
-- more but its pattern has to be bought.
local LEATHER = 10
local function example()
    local gauntlets = recipe(1, "Wicked Leather Gauntlets", { itemId = 501,
        reagents = { { itemId = LEATHER, count = 4, name = "Leather" } } })
    local shoes = recipe(2, "Blue Suede Shoes", { itemId = 502,
        reagents = { { itemId = LEATHER, count = 4, name = "Leather" } },
        source = { type = "ah", price = 20000, source = "TSM" } })
    return { gauntlets, shoes }, { [LEATHER] = 1000 }, { [1] = 500, [2] = 3500 }
end

T.section("ranking by cost after the sale", function()
    local LazyProf = load()
    local recipes, prices, sale = example()

    local steps = run(LazyProf, "cheapest", 100, 120, recipes, {}, prices)
    T.eq("without sale values the learned recipe is cheaper", onlyRecipe(steps), 1)
    T.check("and steps carry no sale fields", steps[1].saleEach == nil and steps[1].sale == nil)

    recipes = example()
    steps = run(LazyProf, "cheapest", 100, 120, recipes, {}, prices, { rankSale = sale, sale = sale })
    T.eq("with sale values the one that sells for more wins, pattern included", onlyRecipe(steps), 2)
    T.eq("a step carries what one craft sells for", steps[1].saleEach, 3500)
    T.eq("and the amount for its crafts", steps[1].sale, 3500 * steps[1].quantity)

    -- Sale values known but not offered for ranking: the route does not move,
    -- the steps still say what they sell for.
    recipes = example()
    steps = run(LazyProf, "cheapest", 100, 120, recipes, {}, prices, { rankSale = {}, sale = sale })
    T.eq("not offered for ranking: the route does not move", onlyRecipe(steps), 1)
    T.eq("the steps still carry the sale value", steps[1].saleEach, 500)

    -- Fastest ignores cost and sale alike, and still carries the value.
    recipes = example()
    steps = run(LazyProf, "fastest", 100, 120, recipes, {}, prices, { rankSale = sale, sale = sale })
    T.check("fastest: steps carry the sale value of their recipe",
        steps[1].saleEach == sale[steps[1].recipe.id])
end)

T.section("the zero floor", function()
    local LazyProf = load()
    local cheapest = LazyProf.PathfinderStrategies.cheapest
    local mat = { { itemId = 20, count = 1, name = "Mat" } }
    -- At skill 100: O is orange (chance 1), Y is half way from yellow to grey (chance 0.5).
    local orange = recipe(1, "O", { orange = 100, yellow = 150, green = 160, gray = 170, reagents = mat })
    local yellow = recipe(2, "Y", { orange = 80, yellow = 90, green = 105, gray = 110, required = 80, reagents = mat })
    local prices = { [20] = 100 }
    local ctx = { rankSale = { [1] = 300, [2] = 300 } }
    T.eq("fixture: Y's chance is one half", cheapest:GetExpectedSkillups(yellow, 100, 0), 0.5)
    local scoreO = cheapest:ScoreRecipe(orange, 100, 200, {}, prices, 0, {}, ctx)
    local scoreY = cheapest:ScoreRecipe(yellow, 100, 200, {}, prices, 0, {}, ctx)
    T.check("a recipe that pays for itself does not win by having the lower chance", scoreO < scoreY,
        tostring(scoreO) .. " vs " .. tostring(scoreY))
    T.check("its cost is floored at zero, not negative", scoreY > -1 and scoreO > -1)

    -- A sale value below the cost is simply taken off.
    local part = cheapest:ScoreRecipe(orange, 100, 200, {}, prices, 0, {}, { rankSale = { [1] = 40 } })
    local full = cheapest:ScoreRecipe(orange, 100, 200, {}, prices, 0, {})
    T.eq("a smaller sale value comes off the cost per skill-up", full - part, 40)
    T.eq("no context: the score is the old one", cheapest:ScoreRecipe(orange, 100, 200, {}, prices, 0, {}, nil), full)
    T.eq("an empty context: the same", cheapest:ScoreRecipe(orange, 100, 200, {}, prices, 0, {}, {}), full)
end)

T.section("no sale values: the planner's output is unchanged", function()
    local CraftLib = harness.loadCraftLib(16001, { camelot = true })
    local LazyProf = harness.loadLazyProf(STRATEGY_FILES)
    local prof = CraftLib:GetProfession("tailoring")
    local function fresh()
        local recipes = LazyProf.Utils.DeepCopy(prof.recipes)
        for _, r in ipairs(recipes) do r.learned = false end
        return recipes
    end
    local prices = harness.priceTable(fresh())
    local function text(ctx)
        local steps, meta = run(LazyProf, "cheapest", 1, 300, fresh(), {}, prices, ctx)
        return harness.formatSteps(steps, meta)
    end
    local f = assert(io.open("scripts/snapshots/forever_tailoring_1_300_cheapest.txt", "r"))
    local snapshot = f:read("*a")
    f:close()
    T.check("no context: the snapshot", text(nil) == snapshot)
    T.check("an empty context: the snapshot", text({}) == snapshot)
    T.check("empty sale tables: the snapshot", text({ rankSale = {}, sale = {} }) == snapshot)
end)

-- Owned stock in the scoring ------------------------------------------------------

T.section("stock scoring: nothing owned is the old score, to the last bit", function()
    local LazyProf = load()
    local cheapest = LazyProf.PathfinderStrategies.cheapest
    local Utils = LazyProf.Utils
    local prices = { [61] = 33.3, [62] = 0.7, [63] = 1234.5 }
    local recipes = {
        recipe(1, "One", { reagents = { { itemId = 61, count = 3 }, { itemId = 62, count = 7 } } }),
        recipe(2, "Two", { yellow = 104, green = 112, gray = 121, reagents = { { itemId = 63, count = 1 }, { itemId = 61, count = 2 } } }),
        recipe(3, "Three", { orange = 90, yellow = 95, green = 108, gray = 131, required = 90,
            reagents = { { itemId = 62, count = 11 } } }),
    }
    -- The score as it was computed before stock was scored against the run.
    local function old(r, skill, target)
        local actualCost = 0
        for _, reagent in ipairs(r.reagents) do
            local price = prices[reagent.itemId]
            local toBuy = math.max(0, reagent.count - 0)
            actualCost = actualCost + (price * toBuy)
        end
        local expected = Utils.GetSkillUpChance(skill, r.skillRange)
        local costPerSkillup = actualCost / expected
        local rangeBonus = 0
        if r.skillRange.gray > skill then
            rangeBonus = -(math.min(r.skillRange.gray, target) - skill) * 0.001
        end
        return costPerSkillup + rangeBonus + (-expected / 100)
    end
    local same = true
    local detail = ""
    for _, r in ipairs(recipes) do
        for _, skill in ipairs({ 100, 103.25, 107.5 }) do
            for _, inventory in ipairs({ {}, { [61] = 0, [62] = 0, [63] = 0 } }) do
                local got = cheapest:ScoreRecipe(r, skill, 150, inventory, prices, 0, {}, { recipes = recipes })
                local want = old(r, skill, 150)
                if got ~= want then
                    same = false
                    detail = string.format("%s at %s: %.17g vs %.17g", r.name, tostring(skill), got, want)
                end
            end
        end
    end
    T.check("every score equals the old formula exactly", same, detail)
end)

T.section("stock scoring: against the whole run, not one craft", function()
    local LazyProf = load()
    local X, Y = 70, 71
    local function fixture()
        return {
            recipe(1, "A", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    local prices = { [X] = 100, [Y] = 300 }

    -- Stock for a single craft of the dear recipe does not make a run of five look free.
    local steps = run(LazyProf, "cheapest", 100, 110, fixture(), { [Y] = 1 }, prices)
    T.eq("one Y owned: the route does not move", onlyRecipe(steps), 1)
    T.eq("fixture: a run is five crafts", steps[1].quantity, 5)
    local altB
    for _, alt in ipairs(steps[1].alternatives) do
        if alt.recipe.id == 2 then altB = alt end
    end
    T.eq("the other recipe's shown cost per craft counts the run: 4 of 5 bought", altB.craftCost, 300 * 4 / 5)
    for _, alt in ipairs(steps[1].alternatives) do
        if alt.recipe.id == 1 then T.eq("nothing owned of X: its cost per craft is its price", alt.craftCost, 100) end
    end

    -- Three owned: two of five bought is 120 a craft, still dearer than 100.
    steps = run(LazyProf, "cheapest", 100, 110, fixture(), { [Y] = 3 }, prices)
    T.eq("three Y owned: still the cheap recipe", onlyRecipe(steps), 1)

    -- Four owned: one of five bought is 60 a craft: the stock is worth using.
    steps = run(LazyProf, "cheapest", 100, 110, fixture(), { [Y] = 4 }, prices)
    T.eq("four Y owned: the first run uses them", steps[1].recipe.id, 2)
    T.eq("and what it pays is the one missing", steps[1].totalCost, 300)
    T.eq("the next run is back on the cheap recipe", steps[2].recipe.id, 1)

    -- Ten owned cover two runs; the third has nothing left.
    steps = run(LazyProf, "cheapest", 100, 115, fixture(), { [Y] = 10 }, prices)
    T.eq("ten Y owned: first run", steps[1].recipe.id, 2)
    T.eq("ten Y owned: second run", steps[2].recipe.id, 2)
    T.eq("ten Y owned: the third run has no stock left", steps[3].recipe.id, 1)
    T.eq("the stocked runs cost nothing", steps[1].totalCost + steps[2].totalCost, 0)

    -- The shared helper: an unpriced reagent counts as zero and is flagged.
    local cheapest = LazyProf.PathfinderStrategies.cheapest
    local odd = recipe(3, "Odd", { reagents = { { itemId = X, count = 2 }, { itemId = 999, count = 1 } } })
    local cost, priced = LazyProf.StrategyCore.ReagentCostPerCraft(cheapest, odd, 100, 110, {}, prices, 0, { recipes = { odd } })
    T.eq("unpriced reagent: the priced part", cost, 200)
    T.check("unpriced reagent: flagged", priced == false)
    T.eq("and the score stays out of reach", cheapest:ScoreRecipe(odd, 100, 110, {}, prices, 0, {}, { recipes = { odd } }), math.huge)
    cost, priced = LazyProf.StrategyCore.ReagentCostPerCraft(cheapest, fixture()[1], 100, 110, {}, prices, 0, { recipes = fixture() })
    T.check("all priced", priced == true and cost == 100)

    -- A reagent without a price that the stock covers for the whole run costs
    -- nothing and does not block the recipe; a part that must be bought does.
    local unpricedOwned = recipe(4, "Owned odd", { reagents = { { itemId = X, count = 1 }, { itemId = 999, count = 1 } } })
    cost, priced = LazyProf.StrategyCore.ReagentCostPerCraft(cheapest, unpricedOwned, 100, 110, { [999] = 500 }, prices, 0,
        { recipes = { unpricedOwned } })
    T.check("unpriced but owned for the whole run: priced", priced == true and cost == 100, tostring(cost))
    cost, priced = LazyProf.StrategyCore.ReagentCostPerCraft(cheapest, unpricedOwned, 100, 110, { [999] = 3 }, prices, 0,
        { recipes = { unpricedOwned } })
    T.check("unpriced and only partly owned: not priced", priced == false)

    -- Nothing owned (or zero counts): the run's quantity is never needed.
    local noQuantity = setmetatable({ CalculateQuantity = function() error("quantity asked for with nothing owned") end },
        { __index = cheapest })
    local ok, err = pcall(function()
        for _, inventory in ipairs({ {}, { [X] = 0, [Y] = 0 } }) do
            local c = LazyProf.StrategyCore.ReagentCostPerCraft(noQuantity, fixture()[2], 100, 110, inventory, prices, 0,
                { recipes = fixture() })
            assert(c == 300, "cost " .. tostring(c))
        end
    end)
    T.check("nothing owned: price x count without working out a quantity", ok, err)

    -- The run's quantity honours the recipe list: a recipe unlocking at 102
    -- cuts the run to two crafts, which two owned Y cover.
    local function withUnlock()
        local recipes = fixture()
        recipes[#recipes + 1] = recipe(5, "Later", { orange = 102, required = 102, yellow = 130, green = 140, gray = 150,
            reagents = { { itemId = 74, count = 1, name = "W" } } })
        return recipes
    end
    local unlockPrices = { [X] = 100, [Y] = 300, [74] = 5000 }
    local list = withUnlock()
    cost = LazyProf.StrategyCore.ReagentCostPerCraft(cheapest, list[2], 100, 110, { [Y] = 2 }, unlockPrices, 0, { recipes = list })
    T.eq("a run cut short by a recipe unlock: two owned cover it", cost, 0)
    steps = run(LazyProf, "cheapest", 100, 110, withUnlock(), { [Y] = 2 }, unlockPrices)
    T.check("and the route uses them for that short run", steps[1].recipe.id == 2 and steps[1].quantity == 2,
        tostring(steps[1].recipe.id) .. " x" .. tostring(steps[1].quantity))

    -- The racial bonus moves the colour change that ends a run: a recipe
    -- yellow at 104 runs four crafts from 100, five with a bonus of 15.
    local short = recipe(6, "Short", { yellow = 104, green = 110, gray = 120, reagents = { { itemId = Y, count = 1, name = "Y" } } })
    cost = LazyProf.StrategyCore.ReagentCostPerCraft(cheapest, short, 100, 130, { [Y] = 4 }, prices, 0, { recipes = { short } })
    T.eq("no bonus: four crafts, four owned", cost, 0)
    cost = LazyProf.StrategyCore.ReagentCostPerCraft(cheapest, short, 100, 130, { [Y] = 4 }, prices, 15, { recipes = { short } })
    T.eq("bonus 15: five crafts, one of them bought", cost, 300 * 1 / 5)

    -- The quantity of a recipe is worked out once per scoring pass (it is
    -- needed for the score and for the shown cost), plus once for the chosen run.
    local calls = 0
    local original = cheapest.CalculateQuantity
    cheapest.CalculateQuantity = function(self, r, skill, ...)
        if r.id == 2 and skill == 100 then calls = calls + 1 end
        return original(self, r, skill, ...)
    end
    run(LazyProf, "cheapest", 100, 105, fixture(), { [Y] = 5 }, prices)
    cheapest.CalculateQuantity = original
    T.eq("quantity worked out once for scoring and once for the run", calls, 2)
end)

T.section("stock scoring: the next recipe unlock is found per skill, and it is the nearest", function()
    local LazyProf = load()
    local X, Y = 70, 71
    local function fixture()
        return {
            recipe(1, "A", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
            recipe(5, "At 102", { orange = 102, required = 102, yellow = 130, green = 140, gray = 150,
                reagents = { { itemId = 74, count = 1, name = "W" } } }),
            recipe(6, "At 104", { orange = 104, required = 104, yellow = 130, green = 140, gray = 150,
                reagents = { { itemId = 74, count = 1, name = "W" } } }),
        }
    end
    local prices = { [X] = 100, [Y] = 300, [74] = 5000 }
    local steps = run(LazyProf, "cheapest", 100, 110, fixture(), { [Y] = 1 }, prices)
    local function costOfB(step)
        for _, alt in ipairs(step.alternatives) do
            if alt.recipe.id == 2 then return alt.craftCost end
        end
    end
    T.check("fixture: runs are cut at 102 and at 104", steps[1].skillEnd == 102 and steps[2].skillEnd == 104)
    T.eq("at 100 the nearest unlock (102) cuts the run to two crafts: one of two bought", costOfB(steps[1]), 300 * 1 / 2)
    T.eq("at 102 the unlock is looked up again (104): again one of two bought", costOfB(steps[2]), 300 * 1 / 2)
    T.eq("at 104 no unlock is left: a run of five, four bought", costOfB(steps[3]), 300 * 4 / 5)

    -- Both strategies: a known next unlock gives the same quantity as walking the list.
    local same = true
    for _, name in ipairs({ "cheapest", "fastest" }) do
        local strategy = LazyProf.PathfinderStrategies[name]
        local list = fixture()
        for _, r in ipairs(list) do
            for _, skill in ipairs({ 100, 101.5, 102, 103, 104, 108 }) do
                local unlock = false
                for _, other in ipairs(list) do
                    if other.skillRequired > skill and (not unlock or other.skillRequired < unlock) then unlock = other.skillRequired end
                end
                if strategy:CalculateQuantity(r, skill, 120, list, 0) ~= strategy:CalculateQuantity(r, skill, 120, list, 0, unlock) then
                    same = false
                end
            end
        end
    end
    T.check("a known next unlock gives the same quantity as walking the recipe list", same)
end)

T.section("stock scoring: only a bridge pass is scored as a bridge", function()
    local LazyProf = load()
    local X, Y = 70, 71
    LazyProf.db.profile.includeGreenRecipes = true   -- green recipes are ordinary candidates: no bridge
    local function greens()
        return {
            recipe(1, "G1", { orange = 60, required = 60, yellow = 80, green = 100, gray = 120, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "G2", { orange = 60, required = 60, yellow = 80, green = 100, gray = 120, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    local prices = { [X] = 100, [Y] = 300 }
    local full = LazyProf.PathfinderStrategies.cheapest:CalculateQuantity(greens()[2], 114, 125, greens(), 0)
    local steps = run(LazyProf, "cheapest", 114, 125, greens(), { [Y] = 20 }, prices)
    T.check("fixture: not a bridge step", not steps[1].bridge)
    local shown
    for _, alt in ipairs(steps[1].alternatives) do
        if alt.recipe.id == 2 then shown = alt.craftCost end
    end
    T.eq("an ordinary pass counts the stock against the full run", shown, 300 * (full - 20) / full)
    LazyProf.db.profile.includeGreenRecipes = false
end)

T.section("stock scoring: a green bridge is scored by the crafts it really gets", function()
    local LazyProf = load()
    local X, Y = 70, 71
    LazyProf.db.profile.includeGreenRecipes = false
    local function bridge()
        return {
            recipe(1, "G1", { orange = 60, required = 60, yellow = 80, green = 100, gray = 120, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "G2", { orange = 60, required = 60, yellow = 80, green = 100, gray = 120, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    local prices = { [X] = 100, [Y] = 300 }
    local steps = run(LazyProf, "cheapest", 114, 125, bridge(), {}, prices)
    T.check("fixture: a bridge step", steps[1].bridge == true)
    T.eq("fixture: nothing owned, the cheap recipe bridges", steps[1].recipe.id, 1)
    local crafts = steps[1].quantity
    T.check("fixture: the bridge is cut short of the full run",
        crafts < LazyProf.PathfinderStrategies.cheapest:CalculateQuantity(bridge()[2], 114, 125, bridge(), 0))

    -- Stock that covers every craft the bridge really makes: free, so it is used.
    steps = run(LazyProf, "cheapest", 114, 125, bridge(), { [Y] = crafts }, prices)
    T.eq("stock covering the cut run is used", steps[1].recipe.id, 2)
    T.eq("and costs nothing", steps[1].totalCost, 0)
end)

-- Candidate routes ---------------------------------------------------------------

local ROUTE_FILES = {}
for _, file in ipairs(STRATEGY_FILES) do ROUTE_FILES[#ROUTE_FILES + 1] = file end
ROUTE_FILES[#ROUTE_FILES + 1] = "Modules/Pricing/SaleValue.lua"
ROUTE_FILES[#ROUTE_FILES + 1] = "Modules/Pathfinder/MaterialResolver.lua"
ROUTE_FILES[#ROUTE_FILES + 1] = "Modules/Pathfinder/Pathfinder.lua"

-- The planner with nothing craftable and every price a real one.
local function loadRoutes()
    local LazyProf = load(ROUTE_FILES)
    _G.CraftLib = { GetRecipeByProduct = function() return nil end }
    LazyProf.Client.PlayerSkill = function() return 0 end
    LazyProf.Client.GetItemInfo = function() return nil end
    LazyProf.PriceManager = {
        PeekPriceInfo = function() return { price = 1, source = "TSM" } end,
        IsRealSource = function(info) return info ~= nil and info.source == "TSM" end,
        MarketPrice = function() return nil end,
    }
    return LazyProf
end

local function plan(LazyProf, strategyName, from, to, recipes, prices, sale, inventory, breakdown, strategy, pins, previous,
                    racialBonus)
    LazyProf.db.profile.strategy = strategyName
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local steps, meta, route = LazyProf.Pathfinder:PlanRoutes({
        strategy = strategy or LazyProf.PathfinderStrategies[strategyName], strategyName = strategyName,
        startSkill = from, targetSkill = to, recipes = recipes, prices = prices, racialBonus = racialBonus or 0,
        pins = pins or {},
        inventory = inventory or {}, sourceBreakdown = breakdown or {}, sale = sale, previous = previous,
    })
    LazyProf.SelfFound:EndRecalc()
    LazyProf.RecipeAvailability:EndRecalc()
    return steps, meta, route
end

local function candidate(route, key)
    for _, c in ipairs(route.candidates) do
        if c.key == key then return c end
    end
end

T.section("candidates: the owner's example", function()
    local LazyProf = loadRoutes()
    local recipes, prices, values = example()
    local steps, meta, route = plan(LazyProf, "cheapest", 100, 120, recipes, prices, { values = values, rank = values })
    T.eq("two candidates", #route.candidates, 2)
    T.eq("the first is the market-price route", route.candidates[1].key, "market")
    T.eq("the second ranks with sale values", route.candidates[2].key, "sale")
    T.eq("market route: 80000 of leather, ten gauntlets' worth back twice over", candidate(route, "market").net, 80000 - 20 * 500)
    T.eq("market route: what is spent", candidate(route, "market").spend, 80000)
    T.eq("market route: what comes back", candidate(route, "market").sale, 10000)
    T.eq("sale route: leather and the pattern, less twenty shoes", candidate(route, "sale").net, 80000 + 20000 - 20 * 3500)
    T.eq("the cheaper one for the player is kept", route.kept, "sale")
    T.eq("and its steps are returned", onlyRecipe(steps), 2)
    T.check("with its meta", meta.complete == true and #meta.gaps == 0)
    T.check("both are eligible", candidate(route, "market").eligible and candidate(route, "sale").eligible)
    T.eq("no gaps: no gap length", candidate(route, "sale").gapLength, 0)
end)

T.section("candidates: costed with what the player owns", function()
    local LazyProf = loadRoutes()
    -- A: X at 100, sells 10. B: Y at 150, sells 80. Ranked with sale values B
    -- nets less per craft (70 against 90), so with nothing owned it wins.
    local function fixture()
        return {
            recipe(1, "A", { itemId = 701, reagents = { { itemId = 50, count = 1, name = "X" } } }),
            recipe(2, "B", { itemId = 702, reagents = { { itemId = 51, count = 1, name = "Y" } } }),
        }
    end
    local prices = { [50] = 100, [51] = 150 }
    local values = { [1] = 10, [2] = 80 }
    local steps, _, route = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, { values = values, rank = values })
    T.eq("nothing owned: market route", candidate(route, "market").net, 20 * 100 - 20 * 10)
    T.eq("nothing owned: sale route", candidate(route, "sale").net, 20 * 150 - 20 * 80)
    T.eq("nothing owned: the sale route is kept", route.kept, "sale")

    -- Twenty X in the bags: the market route costs nothing now.
    steps, _, route = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, { values = values, rank = values },
        { [50] = 20 }, { [50] = { bags = 20 } })
    T.eq("stock owned: the market route only sells", candidate(route, "market").net, -200)
    T.eq("stock owned: nothing is spent on it", candidate(route, "market").spend, 0)
    T.eq("stock owned: the sale route still buys everything", candidate(route, "sale").net, 1400)
    T.eq("stock owned: the market route is kept", route.kept, "market")
    T.eq("and returned", onlyRecipe(steps), 1)
end)

T.section("candidates: pins hold in every candidate", function()
    local LazyProf = loadRoutes()
    local recipes, prices, values = example()
    local pins = {}
    LazyProf.Pins.Add(pins, 100, 120, 1)
    local steps, _, route = plan(LazyProf, "cheapest", 100, 120, recipes, prices, { values = values, rank = values },
        nil, nil, nil, pins)
    T.eq("two candidates are still built", #route.candidates, 2)
    T.eq("the pinned recipe in the market route", candidate(route, "market").net, 70000)
    T.eq("and in the sale route, although the other would rank better", candidate(route, "sale").net, 70000)
    T.eq("every step is the pinned recipe", onlyRecipe(steps), 1)
end)

T.section("candidates: nothing to rank by", function()
    local LazyProf = loadRoutes()
    local recipes, prices, values = example()
    local direct = run(LazyProf, "cheapest", 100, 120, example(), {}, prices)

    local steps, _, route = plan(LazyProf, "cheapest", 100, 120, recipes, prices, nil)
    T.eq("no sale table: one candidate", #route.candidates, 1)
    T.eq("it is the market-price route", route.kept, "market")
    T.eq("the same steps as a plain run", harness.formatSteps(steps), harness.formatSteps(direct))

    recipes = example()
    steps, _, route = plan(LazyProf, "cheapest", 100, 120, recipes, prices, { values = values, rank = {} })
    T.eq("sale values that may not rank: still one candidate", #route.candidates, 1)
    T.eq("whose net counts what the crafts sell for", route.candidates[1].net, 80000 - 20 * 500)
    T.eq("and whose steps carry the value", steps[1].saleEach, 500)
end)

T.section("candidates: the zero floor cannot make the route dearer", function()
    local LazyProf = loadRoutes()
    -- Q is cheaper to make and sells for far more; P is dearer, barely pays
    -- for itself and stays useful longer. With both floored at zero the
    -- sale-value ranking prefers P (longer range); the player is better off with Q.
    local function fixture()
        local q = recipe(1, "Q", { itemId = 601, orange = 100, yellow = 110, green = 115, gray = 118,
            reagents = { { itemId = 30, count = 1, name = "Q mat" } } })
        local p = recipe(2, "P", { itemId = 602, orange = 100, yellow = 130, green = 150, gray = 160,
            reagents = { { itemId = 31, count = 1, name = "P mat" } } })
        return { q, p }
    end
    local prices = { [30] = 100, [31] = 140 }
    local values = { [1] = 500, [2] = 150 }
    local ranked = run(LazyProf, "cheapest", 100, 120, fixture(), {}, prices, { rankSale = values, sale = values })
    T.eq("fixture: ranking with sale values picks P throughout", onlyRecipe(ranked), 2)
    local market = run(LazyProf, "cheapest", 100, 120, fixture(), {}, prices)
    T.eq("fixture: the market route starts with Q", market[1].recipe.id, 1)

    local steps, _, route = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, { values = values, rank = values })
    T.check("the sale route would cost the player more", candidate(route, "sale").net > candidate(route, "market").net,
        tostring(candidate(route, "sale").net) .. " vs " .. tostring(candidate(route, "market").net))
    T.eq("so the market route is kept", route.kept, "market")
    T.eq("and returned", steps[1].recipe.id, 1)
end)

T.section("candidates: a route that covers less cannot win", function()
    local LazyProf = loadRoutes()
    local a = recipe(1, "A", { reagents = { { itemId = 40, count = 1, name = "Mat" } } })
    local prices = { [40] = 100 }
    local function fake(secondGaps, secondQuantity)
        local calls = 0
        return { Calculate = function()
            calls = calls + 1
            if calls == 1 then
                return { { recipe = a, quantity = 10, skillStart = 100, skillEnd = 110, totalCost = 1000 } },
                    { complete = true, gaps = {} }
            end
            return { { recipe = a, quantity = secondQuantity, skillStart = 100, skillEnd = 105, totalCost = 500 } },
                { complete = #secondGaps == 0, gaps = secondGaps }
        end }
    end
    local sale = { values = { [1] = 10 }, rank = { [1] = 10 } }

    local steps, meta, route = plan(LazyProf, "cheapest", 100, 110, { a }, prices, sale, nil, nil,
        fake({ { from = 105, to = 110, reason = "no recipe" } }, 5))
    T.check("the second candidate is cheaper", route.candidates[2].net < route.candidates[1].net)
    T.eq("its gap length is known", route.candidates[2].gapLength, 5)
    T.check("but it leaves five points uncovered: not eligible", route.candidates[2].eligible == false)
    T.eq("the full route is kept", route.kept, "market")
    T.eq("with its steps", steps[1].quantity, 10)
    T.check("and its meta", meta.complete == true)

    -- Within one skill point of the market route's coverage it may win.
    steps, meta, route = plan(LazyProf, "cheapest", 100, 110, { a }, prices, sale, nil, nil,
        fake({ { from = 109.5, to = 110, reason = "no recipe" } }, 9))
    T.check("half a point short: eligible", route.candidates[2].eligible == true)
    T.eq("and kept, being cheaper", route.kept, "sale")
    T.eq("its steps", steps[1].quantity, 9)

    -- A tie keeps the earlier candidate.
    steps, meta, route = plan(LazyProf, "cheapest", 100, 110, { a }, prices, sale, nil, nil, fake({}, 10))
    T.eq("fixture: same amount", route.candidates[2].net, route.candidates[1].net)
    T.eq("a tie keeps the earlier candidate", route.kept, "market")
end)

T.section("candidates: owned stock can shape the route", function()
    local LazyProf = loadRoutes()
    local X, Y = 70, 71
    local function fixture(extra)
        local recipes = {
            recipe(1, "A", { itemId = 801, yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { itemId = 802, yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
        for _, r in ipairs(extra or {}) do recipes[#recipes + 1] = r end
        return recipes
    end

    -- Ten Y in the bank: making B costs nothing, although Y is dearer than X.
    local prices = { [X] = 100, [Y] = 120 }
    local steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil,
        { [Y] = 10 }, { [Y] = { bank = 10 } })
    T.eq("two candidates: market and stock", #route.candidates, 2)
    T.eq("the second is the stock route", route.candidates[2].key, "stock")
    T.eq("market route: ten X to buy", candidate(route, "market").net, 1000)
    T.eq("stock route: nothing to buy", candidate(route, "stock").net, 0)
    T.eq("the stock route is kept", route.kept, "stock")
    T.eq("and returned", onlyRecipe(steps), 2)

    -- The old trap: one Y owned, Y far dearer. The stock route does not move,
    -- and a tie keeps the market route.
    prices = { [X] = 100, [Y] = 300 }
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil, { [Y] = 1 }, { [Y] = { bags = 1 } })
    T.eq("one Y owned: a stock route is still planned", route.candidates[2].key, "stock")
    T.eq("it costs what the market route costs", candidate(route, "stock").net, candidate(route, "market").net)
    T.eq("the market route is kept", route.kept, "market")
    T.eq("all on the cheap recipe", onlyRecipe(steps), 1)

    -- Stock no recipe on the path can use: no third route is planned.
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil, { [555] = 40 }, { [555] = { bags = 40 } })
    T.eq("irrelevant stock: one candidate", #route.candidates, 1)
    -- Nor for a reagent of a recipe that is grey before the start.
    local old = recipe(3, "Old", { orange = 50, yellow = 60, green = 70, gray = 80, required = 50,
        reagents = { { itemId = 72, count = 1, name = "Z" } } })
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture({ old }), prices, nil, { [72] = 40 }, { [72] = { bags = 40 } })
    T.eq("stock for a recipe out of range: one candidate", #route.candidates, 1)
    -- Nor when nothing is owned at all.
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil, {}, {})
    T.eq("nothing owned: one candidate", #route.candidates, 1)

    -- With sale values too: market, sale, stock, in that order; the stock
    -- route ranks with sale values as well.
    local values = { [1] = 10, [2] = 20 }
    prices = { [X] = 100, [Y] = 120 }
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, { values = values, rank = values },
        { [Y] = 10 }, { [Y] = { bags = 10 } })
    T.eq("three candidates", #route.candidates, 3)
    T.check("in the order market, sale, stock", route.candidates[1].key == "market"
        and route.candidates[2].key == "sale" and route.candidates[3].key == "stock")
    T.eq("market: ten X bought, ten A sold", candidate(route, "market").net, 1000 - 100)
    T.eq("stock: nothing bought, ten B sold", candidate(route, "stock").net, -200)
    T.eq("the stock route is kept", route.kept, "stock")

    -- Fastest never plans a stock route.
    steps, _, route = plan(LazyProf, "fastest", 100, 110, fixture(), prices, nil, { [Y] = 10 }, { [Y] = { bags = 10 } })
    T.eq("fastest: one candidate even with stock", #route.candidates, 1)
end)

T.section("candidates: the stock route obeys pins, sale values and coverage", function()
    local LazyProf = loadRoutes()
    local X, Y = 70, 71
    local function fixture(extra)
        local recipes = {
            recipe(1, "A", { itemId = 801, yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { itemId = 802, yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
        for _, r in ipairs(extra or {}) do recipes[#recipes + 1] = r end
        return recipes
    end
    local prices = { [X] = 100, [Y] = 120 }

    -- Pinned to A: the stock route may not use the ten Y either.
    local pins = {}
    LazyProf.Pins.Add(pins, 100, 110, 1)
    local steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil,
        { [Y] = 10 }, { [Y] = { bags = 10 } }, nil, pins)
    T.check("pinned: a stock route is still planned", candidate(route, "stock") ~= nil)
    T.eq("pinned: it buys ten X like the market route", candidate(route, "stock").net, 1000)
    T.eq("pinned: every step is the pinned recipe", onlyRecipe(steps), 1)

    -- Ranked with sale values: with one X owned A costs 80 a craft for the
    -- run; B costs 100 and sells for 60, so by net B wins - only when the
    -- stock route ranks with sale values.
    local salePrices = { [X] = 100, [Y] = 100 }
    local values = { [2] = 60 }
    steps, _, route = plan(LazyProf, "cheapest", 100, 105, fixture(), salePrices, { values = values, rank = values },
        { [X] = 1 }, { [X] = { bags = 1 } })
    T.eq("the stock route ranks with sale values: five B, 500 spent, 300 back", candidate(route, "stock").net, 200)

    -- A stock route that leaves more of the range uncovered cannot win.
    local a = fixture()[1]
    local calls = 0
    local fake = { Calculate = function()
        calls = calls + 1
        if calls < 2 then
            return { { recipe = a, quantity = 10, skillStart = 100, skillEnd = 110, totalCost = 1000 } }, { complete = true, gaps = {} }
        end
        return { { recipe = a, quantity = 5, skillStart = 100, skillEnd = 105, totalCost = 0 } },
            { complete = false, gaps = { { from = 105, to = 110, reason = "no recipe" } } }
    end }
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil, { [X] = 5 }, { [X] = { bags = 5 } }, fake)
    T.eq("fixture: the second candidate is the stock route", route.candidates[2].key, "stock")
    T.check("it is cheaper", route.candidates[2].net < route.candidates[1].net)
    T.check("but covers less: not eligible", route.candidates[2].eligible == false)
    T.eq("the market route is kept", route.kept, "market")

    -- The strategy is handed only the stock it can use.
    local seen
    local spy = { Calculate = function(_, _, _, _, inventory)
        seen = inventory
        return { { recipe = a, quantity = 10, skillStart = 100, skillEnd = 110, totalCost = 0 } }, { complete = true, gaps = {} }
    end }
    local old = recipe(3, "Old", { orange = 50, yellow = 60, green = 70, gray = 80, required = 50,
        reagents = { { itemId = 72, count = 1, name = "Z" } } })
    plan(LazyProf, "cheapest", 100, 110, fixture({ old }), prices, nil,
        { [Y] = 10, [72] = 7, [555] = 40, [X] = 0 }, { [Y] = { bags = 10 } }, spy)
    local keys = {}
    for itemId, count in pairs(seen or {}) do keys[#keys + 1] = itemId .. "=" .. count end
    table.sort(keys)
    T.eq("only owned reagents of usable recipes reach the strategy", table.concat(keys, " "), "71=10")

    -- A recipe kept alive only by the racial bonus counts as usable.
    local alive = recipe(4, "Alive", { orange = 55, yellow = 75, green = 85, gray = 95, required = 55,
        reagents = { { itemId = 73, count = 1, name = "V" } } })
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture({ alive }), prices, nil, { [73] = 3 }, { [73] = { bags = 3 } })
    T.eq("grey without a bonus: its reagent does not count", #route.candidates, 1)
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture({ alive }), prices, nil, { [73] = 3 }, { [73] = { bags = 3 } },
        nil, nil, nil, 15)
    T.eq("with a bonus of 15 it is usable: a stock route is planned", #route.candidates, 2)

    -- A recipe that can only be learned above the target does not count.
    local later = recipe(5, "Later", { orange = 120, required = 120, yellow = 140, green = 150, gray = 160,
        reagents = { { itemId = 75, count = 1, name = "U" } } })
    steps, _, route = plan(LazyProf, "cheapest", 100, 110, fixture({ later }), prices, nil, { [75] = 9 }, { [75] = { bags = 9 } })
    T.eq("a recipe learnable only above the target: its reagent does not count", #route.candidates, 1)
end)

-- What the player holds after buying a route's whole shopping list.
local function afterShopping(LazyProf, steps, inventory, breakdown, prices)
    local account = LazyProf.Pathfinder:Account(steps, inventory, breakdown, prices, {})
    local held, where = {}, {}
    for itemId, count in pairs(inventory) do held[itemId] = count end
    for itemId, sources in pairs(breakdown) do
        where[itemId] = {}
        for key, count in pairs(sources) do where[itemId][key] = count end
    end
    for _, row in ipairs(account.missing.rows) do
        if row.toBuy > 0 then
            held[row.itemId] = (held[row.itemId] or 0) + row.toBuy
            where[row.itemId] = where[row.itemId] or {}
            where[row.itemId].bags = (where[row.itemId].bags or 0) + row.toBuy
        end
    end
    return held, where
end

T.section("candidates: the plan that was shopped for stays", function()
    local LazyProf = loadRoutes()
    local PF = LazyProf.Pathfinder
    local X, Y = 70, 71
    -- A: X at 1s, orange until 130. B: Y at 3s, yellow at 105, grey at 115.
    local function fixture()
        return {
            recipe(1, "A", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { yellow = 105, green = 110, gray = 115, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    local prices = { [X] = 100, [Y] = 300 }
    local inventory, breakdown = { [Y] = 5 }, { [Y] = { bags = 5 } }

    local steps, _, route = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, inventory, breakdown)
    T.eq("first plan: the stock route is kept", route.kept, "stock")
    T.eq("first plan: the owned Y is used first", steps[1].recipe.id, 2)
    T.eq("first plan: fifteen X to buy", candidate(route, "stock").spend, 1500)

    -- The ranges of the kept route, as they are remembered.
    local ranges = PF:RouteRanges(steps)
    T.eq("remembered as one range per run of a recipe", #ranges, 2)
    T.check("first range", ranges[1].recipeId == 2 and ranges[1].from == 100 and ranges[1].to == 105)
    T.check("second range", ranges[2].recipeId == 1 and ranges[2].from == 105 and ranges[2].to == 120)

    -- The player buys the list and comes back. Planned from scratch the
    -- planner drifts: every recipe is free at first, the long-lived one is
    -- used up first and the Y is left to go grey.
    local held, where = afterShopping(LazyProf, steps, inventory, breakdown, prices)
    local drift, _, driftRoute = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, held, where)
    T.check("fixture: planned from scratch, more has to be bought", candidate(driftRoute, driftRoute.kept).spend > 0,
        candidate(driftRoute, driftRoute.kept).spend)

    local again, _, againRoute = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, held, where, nil, nil, ranges)
    T.check("the remembered plan is a candidate", candidate(againRoute, "previous") ~= nil)
    T.eq("holding its list, it needs nothing bought", candidate(againRoute, "previous").spend, 0)
    T.eq("and it is kept", againRoute.kept, "previous")
    T.eq("the Y is still used first", again[1].recipe.id, 2)
    local function shape(list)
        local out = {}
        for _, step in ipairs(list) do
            out[#out + 1] = string.format("%.2f-%.2f %s x%d", step.skillStart, step.skillEnd, tostring(step.recipe.id), step.quantity)
        end
        return table.concat(out, " | ")
    end
    T.eq("the same runs as the plan that was shopped for", shape(again), shape(steps))

    -- Carrying on from a later skill, mid-run: the remembered recipe is held
    -- to the end of its range and no further.
    for _, at in ipairs({ 101, 102, 103, 104 }) do
        local later = plan(LazyProf, "cheapest", at, 120, fixture(), prices, nil, held, where, nil, nil, ranges)
        T.eq("from " .. at .. ": still the Y recipe first", later[1].recipe.id, 2)
        T.eq("from " .. at .. ": only up to the end of its range", later[1].skillEnd, 105)
        T.eq("from " .. at .. ": then the other recipe", later[2].recipe.id, 1)
    end
    -- The plan's own bounds are expected skills, with fractions. Carried on
    -- from the skill it was planned at they are used as they are; from a
    -- later (whole) skill they are read as whole skills, so the point from
    -- 105 to 106 belongs to the recipe that starts at 105.25, not to one more
    -- craft of the recipe before it.
    local fractional = { at = 100, { from = 100, to = 105.25, recipeId = 2 }, { from = 105.25, to = 120, recipeId = 1 } }
    local function craftsOf(list, recipeId)
        local crafts = 0
        for _, step in ipairs(list) do
            if step.recipe.id == recipeId then crafts = crafts + step.quantity end
        end
        return crafts
    end
    local sameSkill = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, held, where, nil, nil, fractional)
    T.eq("from the skill it was planned at: the first recipe goes on to its exact end (six crafts)", craftsOf(sameSkill, 2), 6)
    local laterSkill = plan(LazyProf, "cheapest", 104, 120, fixture(), prices, nil, held, where, nil, nil, fractional)
    T.eq("from a later skill: one craft to 105, not two", craftsOf(laterSkill, 2), 1)
    T.check("then the next recipe from 105", laterSkill[2].recipe.id == 1 and laterSkill[2].skillStart == 105)
    local atBoundary = plan(LazyProf, "cheapest", 105, 120, fixture(), prices, nil, held, where, nil, nil, fractional)
    T.eq("at 105 itself the next recipe is used", atBoundary[1].recipe.id, 1)

    -- A range end that is a hair above where a replayed run lands does not
    -- cost one more craft.
    local hair = { { from = 100, to = 105.0000001, recipeId = 2 }, { from = 105.0000001, to = 120, recipeId = 1 } }
    local hairSteps = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, held, where, nil, nil, hair)
    T.eq("a range end a hair above the landing skill: no extra craft", hairSteps[1].quantity, 5)

    -- A pin of the player wins where it applies; the rest of the remembered
    -- plan stays.
    local pins = {}
    LazyProf.Pins.Add(pins, 100, 102, 1)
    local pinned = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, held, where, nil, pins, ranges)
    T.eq("a pin wins over the remembered plan", pinned[1].recipe.id, 1)
    local back
    for _, step in ipairs(pinned) do
        if step.skillStart >= 102 and step.skillStart < 105 then back = step.recipe.id end
    end
    T.eq("past the pin, the remembered recipe is back for the rest of its range", back, 2)

    -- A remembered plan that ended below the start is not replayed.
    local _, _, late = plan(LazyProf, "cheapest", 121, 125, fixture(), prices, nil, held, where, nil, nil, ranges)
    T.check("a plan the skill has passed is not a candidate", candidate(late, "previous") == nil)
    -- Nor is one built for Fastest, or when nothing usable is owned (nothing
    -- was bought for it, so nothing can be stranded).
    local _, _, fast = plan(LazyProf, "fastest", 100, 120, fixture(), prices, nil, held, where, nil, nil, ranges)
    T.eq("fastest: one candidate", #fast.candidates, 1)
    local _, _, bare = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, {}, {}, nil, nil, ranges)
    T.check("nothing owned: the remembered plan is not replayed", candidate(bare, "previous") == nil)

    -- A remembered plan that would cost more than the market route is not kept.
    local dear = { { from = 100, to = 120, recipeId = 2 } }
    local _, _, dearRoute = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, { [X] = 1 }, { [X] = { bags = 1 } },
        nil, nil, dear)
    T.check("a remembered plan that is dearer is a candidate", candidate(dearRoute, "previous") ~= nil)
    T.check("but is not kept", dearRoute.kept ~= "previous")

    -- Saved data that is not what it should be is ignored, never an error.
    for label, bad in pairs({
        number = 5, string = "route", empty = {}, numbers = { 1, 2, 3 }, booleans = { true },
        ["string bounds"] = { { from = "a", to = "b", recipeId = 2 } },
        ["table bound"] = { { from = {}, to = 120, recipeId = 2 } },
        ["no recipe"] = { { from = 100, to = 120 } },
        inverted = { { from = 120, to = 100, recipeId = 2 } },
        mixed = { 7, { from = 100, to = 105, recipeId = 2 }, "x", { from = 105, to = 120, recipeId = 1 } },
    }) do
        local ok, err = pcall(plan, LazyProf, "cheapest", 100, 120, fixture(), prices, nil, held, where, nil, nil, bad)
        T.check("malformed memory (" .. label .. "): no error", ok, err)
    end
    local _, _, mixedRoute = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, held, where, nil, nil,
        { 7, { from = 100, to = 105, recipeId = 2 }, "x", { from = 105, to = 120, recipeId = 1 } })
    T.eq("the well-formed part of it is still used", mixedRoute.kept, "previous")
end)

T.section("the planner always finishes", function()
    local LazyProf = load()
    local cheapest = LazyProf.PathfinderStrategies.cheapest
    local X, Y = 70, 71
    local prices = { [X] = 100, [Y] = 300 }
    -- A step limit turns an endless loop into a failed check instead of a hung suite.
    local function bounded(from, to, recipes, inventory, pins, ctx)
        local steps = 0
        local original = cheapest.CalculateTotalCostAndSkillups
        cheapest.CalculateTotalCostAndSkillups = function(...)
            steps = steps + 1
            if steps > 5000 then error("the planner does not finish") end
            return original(...)
        end
        LazyProf.db.profile.strategy = "cheapest"
        LazyProf.RecipeAvailability:BeginRecalc()
        LazyProf.SelfFound:BeginRecalc({})
        local ok, result, meta = pcall(cheapest.Calculate, cheapest, from, to, recipes, inventory or {}, prices, 0, pins or {}, ctx)
        LazyProf.SelfFound:EndRecalc()
        LazyProf.RecipeAvailability:EndRecalc()
        cheapest.CalculateTotalCostAndSkillups = original
        return ok, result, meta
    end

    -- A remembered range that ends where its recipe goes grey, with green
    -- recipes allowed: close to grey a craft gains next to nothing.
    LazyProf.db.profile.includeGreenRecipes = true
    local function fading()
        return {
            recipe(1, "Fading", { orange = 60, required = 60, yellow = 80, green = 100, gray = 125,
                reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "Other", { orange = 60, required = 60, yellow = 150, green = 160, gray = 170,
                reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    for label, memory in pairs({
        ["exact bounds"] = { at = 100, { from = 100, to = 125.00000000000001, recipeId = 1 }, { from = 125.00000000000001, to = 140, recipeId = 2 } },
        ["whole bounds"] = { at = 90, { from = 100, to = 125.00000000000001, recipeId = 1 }, { from = 125.00000000000001, to = 140, recipeId = 2 } },
        ["no end in sight"] = { at = 100, { from = 100, to = 200, recipeId = 1 } },
    }) do
        local ok, steps = bounded(100, 140, fading(), { [X] = 5 }, nil, { replay = memory })
        T.check("a remembered range ending at the grey point (" .. label .. "): finishes", ok, steps)
        if ok then
            T.check("and reaches the target (" .. label .. ")", steps[#steps].skillEnd == 140, steps[#steps].skillEnd)
        end
    end
    -- The same for a pin of the player.
    local pins = {}
    LazyProf.Pins.Add(pins, 100, 125, 1)
    local ok, steps = bounded(100, 140, fading(), {}, pins)
    T.check("a pin ending at the grey point: finishes", ok, steps)
    pins = {}
    LazyProf.Pins.Add(pins, 100, 140, 1)
    ok, steps = bounded(100, 140, fading(), {}, pins)
    T.check("a pin reaching past the grey point: finishes", ok, steps)
    LazyProf.db.profile.includeGreenRecipes = false

    -- A pinned recipe that can never give a point (yellow and grey at the
    -- same skill): the range is a gap, not an endless run.
    local function dead()
        return {
            recipe(1, "Dead", { orange = 100, yellow = 105, green = 105, gray = 105, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "Fine", { orange = 100, yellow = 150, green = 160, gray = 170, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    pins = {}
    LazyProf.Pins.Add(pins, 100, 110, 1)
    local meta
    ok, steps, meta = bounded(100, 120, dead(), {}, pins)
    T.check("a pinned recipe that gives no points: finishes", ok, steps)
    if ok then
        T.check("no step is made of crafts that gain nothing", (function()
            for _, step in ipairs(steps) do
                if step.skillEnd <= step.skillStart then return false end
            end
            return true
        end)())
        T.check("the path still reaches the target or says where it could not", steps[#steps].skillEnd == 120 or #meta.gaps > 0)
    end
end)

T.section("carrying on through a green bridge", function()
    local LazyProf = load()
    local X, Y = 70, 71
    LazyProf.db.profile.includeGreenRecipes = false
    -- Both recipes are green from 100 and grey at 120; at 114 only a bridge can use them.
    local function greens()
        return {
            recipe(1, "G1", { orange = 60, required = 60, yellow = 80, green = 100, gray = 120, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "G2", { orange = 60, required = 60, yellow = 80, green = 100, gray = 120, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    local prices = { [X] = 100, [Y] = 300 }
    local free = run(LazyProf, "cheapest", 114, 125, greens(), {}, prices)
    T.check("fixture: left alone, the cheap recipe bridges", free[1].bridge == true and free[1].recipe.id == 1)

    -- The remembered route used the dear one: the bridge carries on with it.
    local memory = { at = 114, { from = 114, to = 125, recipeId = 2 } }
    local steps = run(LazyProf, "cheapest", 114, 125, greens(), {}, prices, { replay = memory })
    T.check("the remembered recipe is used for the bridge", steps[1].bridge == true and steps[1].recipe.id == 2,
        tostring(steps[1].recipe.id))
    T.eq("for as many crafts as a bridge gets", steps[1].quantity, free[1].quantity)

    -- Past the point where its chance is under the bridge's floor it is not
    -- carried on with: a memory does not force crafts the planner would not make.
    local meta
    steps, meta = run(LazyProf, "cheapest", 117, 125, greens(), {}, prices, { replay = memory })
    T.eq("under the chance floor: no step", #steps, 0)
    T.check("but a gap, as without the memory", #meta.gaps == 1 and meta.gaps[1].from == 117)
end)

T.section("ranges are held exactly: no cracks, no overruns", function()
    local LazyProf = loadRoutes()
    local X, Y = 70, 71
    local function fixture()
        return {
            recipe(1, "A", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    local prices = { [X] = 100, [Y] = 300 }
    local stock, where = { [Y] = 50, [X] = 50 }, { [Y] = { bags = 50 }, [X] = { bags = 50 } }
    local function craftsOf(list, recipeId, below)
        local crafts = 0
        for _, step in ipairs(list) do
            if step.recipe.id == recipeId and (not below or step.skillStart < below) then crafts = crafts + step.quantity end
        end
        return crafts
    end

    -- Carried on from the skill it was planned at: a range end a hair above
    -- where the run lands costs no extra craft, and the next range starts there.
    local hair = { at = 100, { from = 100, to = 103.0000001, recipeId = 2 }, { from = 103.0000001, to = 120, recipeId = 1 } }
    local steps = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, stock, where, nil, nil, hair)
    T.eq("a range end a hair above the landing skill: three crafts, not four", craftsOf(steps, 2), 3)
    T.eq("and the next range's recipe takes over at once", craftsOf(steps, 1), 17)

    -- Carried on from a later skill: the bounds are whole skills, at the
    -- start of a range and at its end (103.6 reads as 103).
    local fractional = { at = 100, { from = 100, to = 103.6, recipeId = 2 }, { from = 103.6, to = 120, recipeId = 1 } }
    steps = plan(LazyProf, "cheapest", 101, 120, fixture(), prices, nil, stock, where, nil, nil, fractional)
    T.eq("from a later skill the run ends at the whole skill: two crafts to 103", craftsOf(steps, 2), 2)
    T.eq("then the next recipe for the rest", craftsOf(steps, 1), 17)

    -- A run the planner chooses freely stops where a pin or a remembered
    -- range begins, instead of carrying on into it.
    local later = { at = 100, { from = 103, to = 120, recipeId = 2 } }
    steps = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, stock, where, nil, nil, later)
    T.eq("a free run stops where the remembered range begins: three crafts of the free choice", craftsOf(steps, 1), 3)
    T.eq("and the remembered recipe has its whole range", craftsOf(steps, 2), 17)
    local pins = {}
    LazyProf.Pins.Add(pins, 103, 106, 2)
    steps = plan(LazyProf, "cheapest", 100, 120, fixture(), prices, nil, {}, {}, nil, pins)
    T.eq("a free run stops where a pin begins", craftsOf(steps, 1, 104), 3)
    T.eq("the pinned recipe has exactly its range", craftsOf(steps, 2), 3)
end)

T.section("candidates: the plan in hand is planned like the stock route beyond what it remembers", function()
    local LazyProf = loadRoutes()
    local X, Y = 70, 71
    local function fixture()
        return {
            recipe(1, "A", { itemId = 801, yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { itemId = 802, yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    -- Remembered: A up to 105. Beyond that nothing is remembered.
    local memory = { { from = 100, to = 105, recipeId = 1 } }

    -- With ten Y owned, the part beyond the memory uses them (B costs nothing there).
    local prices = { [X] = 100, [Y] = 120 }
    local _, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil,
        { [Y] = 10 }, { [Y] = { bags = 10 } }, nil, nil, memory)
    T.eq("beyond the memory the owned stock is used: five X bought, nothing else", candidate(route, "previous").spend, 500)

    -- With sale values, the part beyond the memory is ranked with them: one X
    -- owned makes A cost 80 a craft there, B costs 100 and sells for 60.
    local salePrices = { [X] = 100, [Y] = 100 }
    local values = { [2] = 60 }
    _, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), salePrices, { values = values, rank = values },
        { [X] = 1 }, { [X] = { bags = 1 } }, nil, nil, memory)
    T.eq("beyond the memory recipes are ranked with sale values: 4 X and 5 Y bought, 300 back",
        candidate(route, "previous").net, 400 + 500 - 300)

    -- The coverage rule holds for it too.
    local a = fixture()[1]
    local fake = { Calculate = function(_, _, _, _, _, _, _, _, ctx)
        if ctx and ctx.replay then
            return { { recipe = a, quantity = 1, skillStart = 100, skillEnd = 101, totalCost = 0 } },
                { complete = false, gaps = { { from = 101, to = 110, reason = "no recipe" } } }
        end
        return { { recipe = a, quantity = 10, skillStart = 100, skillEnd = 110, totalCost = 1000 } }, { complete = true, gaps = {} }
    end }
    _, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil, { [Y] = 1 }, { [Y] = { bags = 1 } }, fake, nil, memory)
    T.check("a plan in hand that covers less is not eligible", candidate(route, "previous").eligible == false)
    T.check("and is not kept, however cheap", route.kept ~= "previous")
end)

T.section("the remembered route: what is kept of it and what is added", function()
    local LazyProf = loadRoutes()
    local PF = LazyProf.Pathfinder
    local a = recipe(1, "A", {})
    local b = recipe(2, "B", {})
    local function step(r, from, to) return { recipe = r, quantity = 1, skillStart = from, skillEnd = to } end

    -- The skill a route was planned from is the start skill, also when the
    -- path begins with a gap.
    local ranges = PF:RouteRanges({ step(a, 105, 110) }, 100)
    T.eq("planned-at is the start skill, not the first step's", ranges.at, 100)
    T.eq("without a start skill it is the first step's", PF:RouteRanges({ step(a, 105, 110) }).at, 105)

    -- Carrying on keeps the remembered ranges and where they were planned from.
    local remembered = { at = 100, { from = 100, to = 110, recipeId = 1 }, { from = 110, to = 120, recipeId = 2 } }
    local extended = PF:ExtendRanges(remembered, { step(a, 104, 110), step(b, 110, 120), step(a, 120, 130) }, 104)
    T.eq("planned-at survives", extended.at, 100)
    T.eq("what lies beyond the remembered end is added", #extended, 3)
    T.check("the remembered ranges are unchanged", extended[1].from == 100 and extended[1].to == 110 and extended[2].to == 120)
    T.check("the addition starts where the memory ended", extended[3].from == 120 and extended[3].to == 130 and extended[3].recipeId == 1)

    -- A hole in the middle (a pin was reset there) is filled from what was planned.
    local holed = { at = 100, { from = 100, to = 105, recipeId = 1 }, { from = 115, to = 120, recipeId = 2 } }
    local filled = PF:ExtendRanges(holed, { step(a, 100, 105), step(b, 105, 112), step(a, 112, 116), step(b, 116, 120) }, 100)
    local text = {}
    for _, range in ipairs(filled) do text[#text + 1] = string.format("%g-%g:%s", range.from, range.to, tostring(range.recipeId)) end
    T.eq("a hole is filled, remembered ranges win where they exist", table.concat(text, " "),
        "100-105:1 105-112:2 112-115:1 115-120:2")
    T.eq("planned-at survives the filling", filled.at, 100)

    -- Ranges the skill has passed are dropped.
    local pruned = PF:ExtendRanges(remembered, { step(b, 112, 120) }, 112)
    T.check("ranges below the current skill are dropped", #pruned == 1 and pruned[1].from == 110)

    -- Clipping for a pin keeps planned-at too.
    LazyProf.CharStore:Profession("alchemy").route = { at = 100, { from = 100, to = 120, recipeId = 1 } }
    PF:ForgetRoute("alchemy", 105, 110)
    local clipped = LazyProf.CharStore:Profession("alchemy").route
    T.check("clipped around the pin", #clipped == 2 and clipped[1].to == 105 and clipped[2].from == 110)
    T.eq("planned-at survives the clipping", clipped.at, 100)
end)

T.section("candidates: the remembered plan never forces a recipe the planner would refuse", function()
    local LazyProf = loadRoutes()
    local X, Y = 70, 71
    -- B is unlearned: its pattern is on the auction house for 5s.
    local function fixture(source)
        local b = recipe(2, "B", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } },
            source = source })
        b.learned = false   -- not known whether or not a source resolves
        return {
            recipe(1, "A", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            b,
        }
    end
    local prices = { [X] = 100, [Y] = 10 }
    local listed = { type = "ah", price = 500, source = "TSM" }
    local stock, where = { [X] = 1 }, { [X] = { bags = 1 } }
    local memory = { { from = 100, to = 120, recipeId = 2 } }

    local steps, _, route = plan(LazyProf, "cheapest", 100, 120, fixture(listed), prices, nil, stock, where, nil, nil, memory)
    T.eq("fixture: while the pattern is listed the remembered plan is followed", onlyRecipe(steps), 2)

    -- The listing is gone: B cannot be obtained, so it is not replayed.
    steps, _, route = plan(LazyProf, "cheapest", 100, 120, fixture(nil), prices, nil, stock, where, nil, nil, memory)
    T.eq("pattern no longer obtainable: the planner's own choice", onlyRecipe(steps), 1)
    for _, c in ipairs(route.candidates) do
        T.check("no candidate is costed as if the pattern were free (" .. c.key .. ")", c.spend >= 1900, c.spend)
    end

    -- A reagent that lost its price: the recipe cannot be costed, so it is not replayed.
    steps = plan(LazyProf, "cheapest", 100, 120, fixture(listed), { [X] = 100 }, nil, stock, where, nil, nil, memory)
    T.eq("reagent without a price: the planner's own choice", onlyRecipe(steps), 1)

    -- The player's own pin still may: that is a choice, not a memory.
    local pins = {}
    LazyProf.Pins.Add(pins, 100, 120, 2)
    steps = plan(LazyProf, "cheapest", 100, 120, fixture(nil), prices, nil, stock, where, nil, pins, nil)
    T.eq("a pin on an unobtainable recipe is still obeyed", onlyRecipe(steps), 2)
end)

T.section("candidates: the plan in hand is kept unless another route is clearly cheaper", function()
    local LazyProf = loadRoutes()
    local X, Y = 70, 71
    local function fixture()
        return {
            recipe(1, "A", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = X, count = 1, name = "X" } } }),
            recipe(2, "B", { yellow = 130, green = 140, gray = 150, reagents = { { itemId = Y, count = 1, name = "Y" } } }),
        }
    end
    local a = fixture()[1]
    -- Canned routes: market 1000, a challenger, and the remembered plan.
    local function canned(challengerCost, previousCost, marketCost)
        local calls = 0
        return { Calculate = function(_, _, _, _, _, _, _, _, ctx)
            calls = calls + 1
            local cost = (ctx and ctx.replay) and previousCost or ((calls == 1) and (marketCost or 1000) or challengerCost)
            return { { recipe = a, quantity = cost / 100, skillStart = 100, skillEnd = 110, totalCost = cost } },
                { complete = true, gaps = {} }
        end }
    end
    -- The margin's yardstick is the market route with NOTHING owned: here the
    -- market route takes ten X, four of which are owned.
    do
        local _, _, owned = plan(LazyProf, "cheapest", 100, 110, fixture(), { [X] = 100, [Y] = 100 }, nil,
            { [X] = 4, [Y] = 1 }, { [X] = { bags = 4 }, [Y] = { bags = 1 } }, canned(600, 600), nil,
            { { from = 100, to = 110, recipeId = 1 } })
        T.eq("fixture: with the stock the market route costs 600", owned.candidates[1].spend, 600)
        T.eq("the margin is 5% of its cost with nothing owned (1000)", owned.keepMargin, 50)
    end
    local prices = { [X] = 100, [Y] = 100 }
    local memory = { { from = 100, to = 110, recipeId = 1 } }
    -- Y is owned (so the stock route and the remembered plan are planned)
    -- but the canned routes only use X: each costs what it says.
    local stock, where = { [Y] = 1 }, { [Y] = { bags = 1 } }
    local function kept(challengerCost, previousCost, marketCost)
        local _, _, route = plan(LazyProf, "cheapest", 100, 110, fixture(), prices, nil, stock, where,
            canned(challengerCost, previousCost, marketCost), nil, memory)
        return route.kept, route
    end
    local name, route = kept(800, 800)
    T.eq("fixture: market, stock, previous", #route.candidates, 3)
    T.eq("a tie with the best other route: the plan in hand stays", name, "previous")
    T.eq("slightly dearer than the best other route (within 5% of the market route's full cost): stays", kept(800, 840), "previous")
    T.eq("clearly dearer than the best other route: replaced", kept(800, 900), "stock")
    T.eq("dearer than the market route, however little: replaced", kept(1000, 1010), "market")
    T.eq("cheaper than everything: stays", kept(900, 500), "previous")
    T.eq("the margin is measured on the market route with nothing owned", route.keepMargin, 50)
end)

T.section("candidates: fastest keeps its single run", function()
    local LazyProf = loadRoutes()
    local recipes, prices, values = example()
    local steps, _, route = plan(LazyProf, "fastest", 100, 120, recipes, prices, { values = values, rank = values })
    T.eq("one candidate", #route.candidates, 1)
    T.eq("named after the strategy", route.kept, "fastest")
    -- Worked out here from the steps it returned: leather, the pattern when
    -- shoes are on the route, and what each craft sells for.
    local spend, back, shoes = 0, 0, false
    for _, step in ipairs(steps) do
        spend = spend + step.quantity * 4 * 1000
        back = back + step.quantity * values[step.recipe.id]
        if step.recipe.id == 2 then shoes = true end
    end
    if shoes then spend = spend + 20000 end
    T.check("fixture: the run has steps", #steps > 0 and spend > 0)
    T.eq("what it spends, by the same accounting", route.candidates[1].spend, spend)
    T.eq("what comes back", route.candidates[1].sale, back)
    T.eq("its net", route.candidates[1].net, spend - back)
    T.check("its steps carry the sale value", steps[1].saleEach == values[steps[1].recipe.id])
end)

T.section("the whole calculation", function()
    local LazyProf = loadRoutes()
    local PF = LazyProf.Pathfinder
    local sell = { [501] = 500, [502] = 3500, [503] = 100, [504] = 100 }
    LazyProf.Client.GetItemInfo = function(_, itemId)
        if not sell[itemId] then return nil end
        return "Item " .. itemId, nil, 1, 1, 1, "", "", 1, "", "icon", sell[itemId]
    end
    LazyProf.PriceManager.GetPrices = function(_, ids)
        local prices = {}
        for _, id in ipairs(ids) do prices[id] = (id == LEATHER) and 1000 or nil end
        return prices
    end
    local milestones = { 75, 150, 225, 300 }
    local function build(profKey)
        local recipes = example()
        -- Grey long before the start (80), and grey at 95: only a racial
        -- bonus of 15 keeps the second one in range at skill 100.
        recipes[#recipes + 1] = recipe(3, "Old Boots", { itemId = 503, orange = 50, yellow = 60, green = 70, gray = 80,
            reagents = { { itemId = LEATHER, count = 1, name = "Leather" } } })
        recipes[#recipes + 1] = recipe(4, "Old Gloves", { itemId = 504, orange = 55, yellow = 75, green = 85, gray = 95,
            reagents = { { itemId = LEATHER, count = 1, name = "Leather" } } })
        return PF:BuildPath({
            profKey = profKey or "leatherworking", profData = { name = "Leatherworking", milestones = milestones },
            recipes = recipes, startSkill = 100, actualSkill = 100, hasProfession = true,
        })
    end
    PF:SetTargetSkill("leatherworking", 120, 100, milestones)
    PF:SetTargetSkill("engineering", 120, 100, milestones)

    local path = build()
    T.eq("the path carries the sale table", path.sale.values[2], 3500)
    T.eq("its mode", path.sale.mode, "vendor")
    T.eq("the route that was kept", path.route.kept, "sale")
    T.eq("the steps are that route's", onlyRecipe(path.steps), 2)
    T.eq("both candidates are reported", #path.route.candidates, 2)
    T.check("a recipe grey before the start is not looked up", path.sale.values[3] == nil and path.sale.values[4] == nil)

    -- The racial bonus reaches the sale table: a gnome's +15 Engineering
    -- keeps the recipe that goes grey at 95 in range.
    _G.CraftLib.GetActiveProfile = function() return "TBC" end
    _G.UnitRace = function() return "Gnome", "Gnome" end
    local gnome = build("engineering")
    T.eq("fixture: the bonus is in force", gnome.racialBonus, 15)
    T.eq("a recipe the racial bonus keeps alive is looked up", gnome.sale.values[4], 100)
    T.check("one that is grey even so is not", gnome.sale.values[3] == nil)
    _G.CraftLib.GetActiveProfile = nil
    _G.UnitRace = function() return "Human", "Human" end

    -- The kept route is remembered per character and profession.
    local store = LazyProf.CharStore:Profession("leatherworking")
    local remembered = store.route
    T.check("the kept route is remembered", type(remembered) == "table" and #remembered == 1 and remembered[1].recipeId == 2)
    T.check("with its range", remembered[1].from == 100 and remembered[1].to == 120)

    -- With reagents in hand the next calculation plans it as a candidate, and
    -- while it is kept the memory is left as it was (not rewritten from the replay).
    LazyProf.Inventory.ScanAll = function() return { [LEATHER] = 80 }, { [LEATHER] = { bags = 80 } } end
    store.route = { { from = 100, to = 110, recipeId = 2 }, { from = 110, to = 120, recipeId = 2 } }
    path = build()
    T.eq("with reagents in hand the remembered plan is kept", path.route.kept, "previous")
    T.check("and the memory keeps its two ranges as they were", #store.route == 2 and store.route[1].from == 100
        and store.route[1].to == 110 and store.route[2].from == 110 and store.route[2].to == 120)
    -- A raised target: what lies beyond the remembered plan is added to it.
    -- (Sale values off and plenty of leather owned, so every route costs the
    -- same nothing and the plan in hand stays.)
    LazyProf.db.profile.saleValueMode = "none"
    LazyProf.Inventory.ScanAll = function() return { [LEATHER] = 400 }, { [LEATHER] = { bags = 400 } } end
    store.route = { at = 100, { from = 100, to = 110, recipeId = 1 }, { from = 110, to = 120, recipeId = 1 } }
    PF:SetTargetSkill("leatherworking", 130, 100, milestones)
    path = build()
    T.eq("a raised target: the plan in hand is still kept", path.route.kept, "previous")
    T.check("its remembered part stays", store.route[1].from == 100 and store.route[1].to == 110 and store.route[2].to == 120)
    T.check("what lies beyond it is added", store.route[#store.route].to == 130, store.route[#store.route].to)
    T.eq("and it still knows where it was planned from", store.route.at, 100)
    PF:SetTargetSkill("leatherworking", 120, 100, milestones)
    LazyProf.db.profile.saleValueMode = "vendor"

    -- When another route is kept, that route is what is remembered from then on.
    store.route = { at = 100, { from = 100, to = 120, recipeId = 1 } }   -- gauntlets: clearly dearer by net than shoes
    LazyProf.Inventory.ScanAll = function() return { [LEATHER] = 1 }, { [LEATHER] = { bags = 1 } } end
    path = build()
    T.check("fixture: the plan in hand was a candidate and lost", path.route.kept ~= "previous"
        and path.route.candidates[#path.route.candidates].key == "previous", path.route.kept)
    T.eq("the newly kept route replaces the memory", store.route[1].recipeId, 2)
    T.eq("with the skill it was planned at", store.route.at, 100)
    LazyProf.Inventory.ScanAll = function() return {}, {} end

    -- Choosing a recipe for a range forgets what was remembered there, and
    -- only there; resetting it does the same, so the planner chooses again.
    store.route = { { from = 100, to = 110, recipeId = 2 }, { from = 110, to = 120, recipeId = 2 } }
    PF:PinRange("leatherworking", 104, 112, 1)
    T.eq("pinning clips the remembered ranges around the pin", #store.route, 2)
    T.check("the part before the pin stays", store.route[1].from == 100 and store.route[1].to == 104)
    T.check("the part after the pin stays", store.route[2].from == 112 and store.route[2].to == 120)
    store.route = { { from = 100, to = 120, recipeId = 1 } }
    PF:UnpinAt("leatherworking", 105)
    T.eq("unpinning forgets the pin's range", #store.route, 2)
    T.check("and keeps the rest", store.route[1].to == 104 and store.route[2].from == 112)
    PF:UnpinAt("leatherworking", 105)
    T.eq("unpinning where no pin is changes nothing", #store.route, 2)
    PF:PinRange("leatherworking", 100, 120, 1)
    T.check("a pin over everything leaves nothing remembered", store.route == nil or #store.route == 0)
    store.route = { { from = 100, to = 120, recipeId = 2 } }
    PF:ClearPins("leatherworking")
    T.check("clearing the pins forgets the route", store.route == nil)

    -- A what-if from skill 1 neither uses nor replaces the memory.
    build()
    local before = store.route
    T.check("fixture: remembered again", before ~= nil)
    local whatIf = PF:BuildPath({
        profKey = "leatherworking", profData = { name = "Leatherworking", milestones = milestones },
        recipes = example(), startSkill = 100, actualSkill = 100, hasProfession = true, planFromOne = true, planning = true,
    })
    T.check("a what-if does not replace the remembered route", store.route == before)
    for _, c in ipairs(whatIf.route.candidates) do
        T.check("a what-if does not replay it (" .. c.key .. ")", c.key ~= "previous")
    end
    -- Fastest has one route; a look at it leaves the memory alone.
    LazyProf.db.profile.strategy = "fastest"
    local fastPath = PF:BuildPath({
        profKey = "leatherworking", profData = { name = "Leatherworking", milestones = milestones },
        recipes = example(), startSkill = 100, actualSkill = 100, hasProfession = true,
    })
    T.eq("fastest: its own route", fastPath.route.kept, "fastest")
    T.check("fastest: the remembered route is still there", store.route == before)
    LazyProf.db.profile.strategy = "cheapest"
    -- Nothing left to plan: nothing to remember.
    PF:SetTargetSkill("leatherworking", 101, 100, milestones)
    local done = PF:BuildPath({
        profKey = "leatherworking", profData = { name = "Leatherworking", milestones = milestones },
        recipes = example(), startSkill = 101, actualSkill = 101, hasProfession = true,
    })
    T.check("fixture: nothing left", #done.steps == 0)
    T.check("an empty path forgets the route", store.route == nil)
    PF:SetTargetSkill("leatherworking", 120, 100, milestones)

    -- The stock the scan reports reaches the planner.
    local stockMeta = { bagsOnly = true }
    LazyProf.Inventory.ScanAll = function() return { [LEATHER] = 80 }, { [LEATHER] = { bank = 80 } }, stockMeta end
    path = build()
    T.check("scanned stock: what the scan says of it travels on the path", path.stockMeta == stockMeta)
    local stockCandidate
    for _, c in ipairs(path.route.candidates) do
        if c.key == "stock" then stockCandidate = c end
    end
    T.check("scanned stock: a stock route is planned", stockCandidate ~= nil)
    T.eq("scanned stock: the leather in the bank is not bought again", stockCandidate and stockCandidate.spend, 0)
    T.eq("scanned stock: the market route is costed with it too", path.route.candidates[1].spend, 0)
    T.check("scanned stock: the path carries it", path.inventory[LEATHER] == 80)
    LazyProf.Inventory.ScanAll = function() return {}, {} end
    store.route = nil
    T.check("a scan with nothing to say: nothing on the path", build().stockMeta == nil)
    store.route = nil

    LazyProf.db.profile.saleValueMode = "none"
    path = build()
    T.eq("sale values off: the market route", path.route.kept, "market")
    T.eq("with the learned recipe", onlyRecipe(path.steps), 1)
    T.check("and nothing counted as sold", next(path.sale.values) == nil)
    LazyProf.db.profile.saleValueMode = "vendor"
end)

-- Property: on real recipe data the kept route never costs the player more than
-- the market-price route, whatever is owned and whatever the crafts sell for;
-- and with neither, the route is the snapshot's.
local CASES = {
    { name = "tbc_leatherworking_300_375", interface = 20505, prof = "leatherworking", from = 300, to = 375 },
    { name = "vanilla_enchanting_1_300", interface = 11508, prof = "enchanting", from = 1, to = 300 },
    { name = "tbc_engineering_1_375", interface = 20505, prof = "engineering", from = 1, to = 375 },
    { name = "wotlk_alchemy_1_450", interface = 30403, prof = "alchemy", from = 1, to = 450 },
    { name = "sod_tailoring_1_300", interface = 11508, sod = true, prof = "tailoring", from = 1, to = 300 },
    { name = "forever_tailoring_1_300", interface = 16001, camelot = true, prof = "tailoring", from = 1, to = 300 },
    { name = "forever_alchemy_1_300", interface = 16001, camelot = true, prof = "alchemy", from = 1, to = 300 },
    { name = "forever_tailoring_1_225", interface = 16001, camelot = true, prof = "tailoring", from = 1, to = 225 },
}

T.section("property: never dearer than the market route", function()
    local kept = {}
    for _, case in ipairs(CASES) do
        local CraftLib = harness.loadCraftLib(case.interface, { sod = case.sod, camelot = case.camelot })
        local LazyProf = harness.loadLazyProf(ROUTE_FILES)
        LazyProf.Client = LazyProf.Client or {}
        LazyProf.Client.PlayerSkill = function() return 0 end
        LazyProf.Client.GetItemInfo = function() return nil end
        LazyProf.PriceManager = { PeekPriceInfo = function() return { price = 1, source = "TSM" } end }
        local prof = CraftLib:GetProfession(case.prof)
        local function fresh()
            local recipes = LazyProf.Utils.DeepCopy(prof.recipes)
            for _, r in ipairs(recipes) do r.learned = false end
            return recipes
        end
        local prices = harness.priceTable(fresh())

        -- Synthetic sale values on every third recipe, synthetic stock of
        -- every fourth reagent.
        local values, n = {}, 0
        for _, r in ipairs(fresh()) do
            n = n + 1
            if n % 3 == 0 then values[r.id] = (r.id * 13) % 400 end
        end
        local ids = {}
        for itemId in pairs(prices) do ids[#ids + 1] = itemId end
        table.sort(ids)
        local inventory, breakdown = {}, {}
        for i, itemId in ipairs(ids) do
            if i % 4 == 0 then
                inventory[itemId] = 20
                breakdown[itemId] = { bags = 20 }
            end
        end

        for _, variant in ipairs({
            { label = "sale", sale = { values = values, rank = values } },
            { label = "stock", inventory = inventory, breakdown = breakdown },
            { label = "sale and stock", sale = { values = values, rank = values }, inventory = inventory, breakdown = breakdown },
        }) do
            local steps, meta, route = plan(LazyProf, "cheapest", case.from, case.to, fresh(), prices, variant.sale,
                variant.inventory, variant.breakdown)
            local market, keptCandidate = candidate(route, "market"), candidate(route, route.kept)
            T.check(case.name .. " (" .. variant.label .. "): the kept route is not dearer than the market route",
                keptCandidate.net <= market.net, tostring(keptCandidate.net) .. " vs " .. tostring(market.net))
            T.check(case.name .. " (" .. variant.label .. "): more than one route was planned", #route.candidates > 1)
            kept[#kept + 1] = string.format("%s (%s): kept %s of %d", case.name, variant.label, route.kept, #route.candidates)
        end

        -- Buy the kept route's whole list, come back and plan again: the
        -- plan that was shopped for needs nothing more, and whatever is kept
        -- costs the player no more than it. (Recipes are known here, so
        -- "spend" is reagents only.)
        local function known()
            local recipes = fresh()
            for _, r in ipairs(recipes) do r.learned = true end
            return recipes
        end
        local first, _, firstRoute = plan(LazyProf, "cheapest", case.from, case.to, known(), prices, nil, inventory, breakdown)
        local held, where = afterShopping(LazyProf, first, inventory, breakdown, prices)
        local _, _, secondRoute = plan(LazyProf, "cheapest", case.from, case.to, known(), prices, nil, held, where,
            nil, nil, LazyProf.Pathfinder:RouteRanges(first))
        local previous = candidate(secondRoute, "previous")
        T.check(case.name .. ": the plan that was shopped for is a candidate", previous ~= nil)
        T.eq(case.name .. ": holding its list, it needs nothing bought", previous and previous.spend, 0)
        T.check(case.name .. ": what is kept after shopping costs no more than it",
            candidate(secondRoute, secondRoute.kept).net <= (previous and previous.net or -math.huge))
        kept[#kept + 1] = string.format("%s (after shopping for the %s route): kept %s", case.name, firstRoute.kept, secondRoute.kept)

        local steps, meta, route = plan(LazyProf, "cheapest", case.from, case.to, fresh(), prices, nil, {}, {})
        local f = assert(io.open("scripts/snapshots/" .. case.name .. "_cheapest.txt", "r"))
        local snapshot = f:read("*a")
        f:close()
        T.check(case.name .. ": no sale values, no stock: the snapshot's route",
            harness.formatSteps(steps, meta) == snapshot and #route.candidates == 1)
    end
    for _, line in ipairs(kept) do print("INFO: " .. line) end
end)

T.finish()
