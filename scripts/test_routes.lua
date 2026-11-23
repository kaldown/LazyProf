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

local function plan(LazyProf, strategyName, from, to, recipes, prices, sale, inventory, breakdown, strategy, pins)
    LazyProf.db.profile.strategy = strategyName
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local steps, meta, route = LazyProf.Pathfinder:PlanRoutes({
        strategy = strategy or LazyProf.PathfinderStrategies[strategyName], strategyName = strategyName,
        startSkill = from, targetSkill = to, recipes = recipes, prices = prices, racialBonus = 0, pins = pins or {},
        inventory = inventory or {}, sourceBreakdown = breakdown or {}, sale = sale,
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

    LazyProf.db.profile.saleValueMode = "none"
    path = build()
    T.eq("sale values off: the market route", path.route.kept, "market")
    T.eq("with the learned recipe", onlyRecipe(path.steps), 1)
    T.check("and nothing counted as sold", next(path.sale.values) == nil)
    LazyProf.db.profile.saleValueMode = "vendor"
end)

T.finish()
