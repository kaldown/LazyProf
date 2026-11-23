-- scripts/test_routes.lua
--
-- The route the planner keeps. Cheapest ranks recipes by what a craft costs
-- after what it sells for, can let owned stock shape the route, and builds up
-- to three candidate routes (market prices / with sale value / with stock and
-- sale value), keeping the one the player pays least for - so no route is
-- dearer for the player than the market-price route.
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

T.finish()
