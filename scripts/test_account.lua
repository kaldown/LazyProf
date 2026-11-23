-- scripts/test_account.lua
--
-- The one accounting of what the player pays: the shopping computation over a
-- set of craft steps (stock taken off, craft-or-buy applied, recipe costs
-- added), minus what the crafts sell for. The planner's choice between
-- candidate routes comes from it, and so does the receipt the window shows:
-- the second half of this file checks, on real recipe data, that the
-- receipt's amounts are the shopping list's and agree with the stages.
--
-- Run from the addon root:  lua5.1 scripts/test_account.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Client/Family.lua",
    "Core/Client/Classic.lua",
    "Core/Config.lua",
    "Core/CharStore.lua",
    "Modules/Pathfinder/Pins.lua",
    "Modules/Pathfinder/MaterialResolver.lua",
    "Modules/Pathfinder/Pathfinder.lua",
})
local PF = LazyProf.Pathfinder

-- Items: 10 Bolt (made from 3x 11 Cloth by tailoring recipe 500, known), 12 Thread.
local BOLT, CLOTH, THREAD = 10, 11, 12
local NAMES = { [BOLT] = "Bolt", [CLOTH] = "Cloth", [THREAD] = "Thread" }
local PRODUCERS = {
    [BOLT] = { { professionKey = "tailoring", recipe = { id = 500, name = "Bolt of Cloth", source = { type = "vendor" },
        reagents = { { itemId = CLOTH, count = 3, name = "Cloth" } } } } },
}
_G.CraftLib = { GetRecipeByProduct = function(_, itemId) return PRODUCERS[itemId] end }
LazyProf.Client.PlayerSkill = function() return 0 end
LazyProf.Client.GetItemInfo = function(_, itemId) return NAMES[itemId] end
LazyProf.PriceManager = { PeekPriceInfo = function() return { price = 1, source = "TSM" } end }
LazyProf.db.profile.strategy = "cheapest"
LazyProf.db.profile.materialResolution = "cost"
LazyProf.db.char.learnedRecipes = { tailoring = { [500] = true } }

local SHIRT = { id = 1, name = "Shirt", learned = true, reagents = {
    { itemId = BOLT, count = 2, name = "Bolt" }, { itemId = THREAD, count = 1, name = "Thread" } } }
local HAT = { id = 2, name = "Hat", learned = false, _sourceInfo = { type = "vendor", cost = 250 }, reagents = {
    { itemId = CLOTH, count = 1, name = "Cloth" } } }
local STEPS = { { recipe = SHIRT, quantity = 10, skillStart = 1 }, { recipe = HAT, quantity = 5, skillStart = 20 } }
local PRICES = { [BOLT] = 500, [CLOTH] = 100, [THREAD] = 10 }

local function sum(list, key)
    local total = 0
    for _, entry in ipairs(list) do total = total + (entry[key] or 0) end
    return total
end

T.section("account", function()
    local inventory, breakdown = { [CLOTH] = 15 }, { [CLOTH] = { bags = 5, bank = 10 } }
    local a = PF:Account(STEPS, inventory, breakdown, PRICES, { [1] = 30 })
    T.check("it carries the shopping list it was made from", type(a.missing) == "table" and type(a.missing.rows) == "table")
    T.eq("reagents: the rows' costs added up", a.reagents, sum(a.missing.rows, "cost"))
    T.eq("reagents: 50 cloth and 10 thread", a.reagents, 5000 + 100)
    T.eq("recipes: the recipe rows added up", a.recipes, sum(a.missing.recipeRows, "cost"))
    T.eq("recipes: the hat's pattern", a.recipes, 250)
    T.eq("spend", a.spend, 5350)
    T.eq("sale: ten shirts at 30, hats sell for nothing known", a.sale, 300)
    T.eq("net", a.net, 5050)

    local b = PF:Account(STEPS, inventory, breakdown, PRICES, nil)
    T.eq("no sale values: nothing comes back", b.sale, 0)
    T.eq("no sale values: net is what is spent", b.net, b.spend)

    local empty = PF:Account({}, {}, {}, PRICES, { [1] = 30 })
    T.eq("no steps: nothing spent", empty.spend, 0)
    T.eq("no steps: nothing back", empty.net, 0)
end)

T.section("what the owned stock saves", function()
    local inventory, breakdown = { [CLOTH] = 15 }, { [CLOTH] = { bags = 5, bank = 10 } }
    local a = PF:Account(STEPS, inventory, breakdown, PRICES)
    -- With nothing owned: 65 cloth, 10 thread, the pattern.
    T.eq("the same list with nothing owned, less what is spent", PF:StockSaving(STEPS, PRICES, a.spend), 6850 - 5350)
    local none = PF:Account(STEPS, {}, {}, PRICES)
    T.eq("nothing owned: nothing saved", PF:StockSaving(STEPS, PRICES, none.spend), 0)
    T.eq("never below zero", PF:StockSaving(STEPS, PRICES, 999999), 0)
end)

-- The receipt's sums on real recipe data: every case the path snapshots use
-- (scripts/test_paths.lua), planned by the Cheapest strategy as that file
-- does, then folded into stages with learn steps and accounted over the
-- stages' quantities - with synthetic sale values and stock, with the margin
-- off and on, and for a character that crafts nothing itself and one that
-- can make every trainer-taught reagent.
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
    "Modules/Pathfinder/MaterialResolver.lua",
    "Modules/Pathfinder/Pathfinder.lua",
    "Modules/Guide/Stages.lua",
}
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

T.section("receipt invariants on the snapshot fixtures", function()
    local withCrafted, withoutCrafted, withFees, withSale, withStock = 0, 0, 0, 0, 0
    for _, case in ipairs(CASES) do
        local CraftLib = harness.loadCraftLib(case.interface, { sod = case.sod, camelot = case.camelot })
        local LP = harness.loadLazyProf(STRATEGY_FILES)
        local skill = 0
        -- (The Forever cases install no client adapter from these files.)
        LP.Client = LP.Client or {}
        LP.Client.PlayerSkill = function() return skill end
        LP.Client.GetItemInfo = function() return nil end
        LP.PriceManager = { PeekPriceInfo = function() return { price = 1, source = "TSM" } end }
        LP.db.profile.strategy = "cheapest"
        local prof = CraftLib:GetProfession(case.prof)
        assert(prof, case.name .. ": no profession data")
        local recipes = LP.Utils.DeepCopy(prof.recipes)
        for _, r in ipairs(recipes) do r.learned = false end
        local prices = harness.priceTable(recipes)

        LP.RecipeAvailability:BeginRecalc()
        LP.SelfFound:BeginRecalc({})
        local steps, meta = LP.PathfinderStrategies.cheapest:Calculate(case.from, case.to,
            LP.Utils.DeepCopy(recipes), {}, prices, 0, {})
        LP.SelfFound:EndRecalc()
        LP.RecipeAvailability:EndRecalc()
        local path = { steps = steps, gaps = meta.gaps, complete = meta.complete, prices = prices,
            currentSkill = case.from, actualSkill = case.from, targetSkill = case.to, racialBonus = 0,
            milestones = prof.milestones }

        -- Synthetic sale values on every third recipe, synthetic stock of
        -- every fourth reagent (in the bags).
        local values, n = {}, 0
        for _, r in ipairs(recipes) do
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

        for _, margin in ipairs({ 0, 15 }) do
            for _, crafts in ipairs({ false, true }) do
                skill = crafts and 300 or 0
                local label = string.format("%s (margin %d, %s): ", case.name, margin,
                    crafts and "makes reagents" or "makes nothing")
                local stages, totals = LP.Stages.Build(path, { inventory = inventory, prices = prices,
                    marginPercent = margin, includeLearn = true, sale = values })
                local account = LP.Pathfinder:Account(LP.Stages.ShoppingSteps(stages), inventory, breakdown, prices, values)
                local rows, recipeRows = account.missing.rows, account.missing.recipeRows

                local crafted = false
                for _, row in ipairs(rows) do
                    if row.crafted then crafted = true end
                end
                local fees = 0
                for _, stage in ipairs(stages) do
                    if stage.kind == "learn" then fees = fees + stage.fee end
                end

                T.eq(label .. "reagents are the shopping rows' costs", account.reagents, sum(rows, "cost"))
                T.eq(label .. "recipes are the recipe rows", account.recipes, sum(recipeRows, "cost"))
                T.eq(label .. "and the learn steps' fees", account.recipes, fees)
                T.eq(label .. "spend less back is the net", account.spend - account.sale, account.net)
                local saving = totals.columnPay - account.reagents
                T.eq(label .. "cost column + recipes - the saving of making reagents = You spend",
                    totals.columnPay + account.recipes - saving, account.spend)
                if not crafted then
                    T.eq(label .. "nothing made: the cost column is the reagents amount", totals.columnPay, account.reagents)
                end
                T.eq(label .. "back from selling is what the stages' crafts sell for", account.sale, totals.shownSale)

                if crafted then withCrafted = withCrafted + 1 else withoutCrafted = withoutCrafted + 1 end
                if fees > 0 then withFees = withFees + 1 end
                if account.sale > 0 then withSale = withSale + 1 end
                if LP.Pathfinder:StockSaving(LP.Stages.ShoppingSteps(stages), prices, account.spend) > 0 then
                    withStock = withStock + 1
                end
            end
        end
    end
    -- The fixtures really exercise what the equalities are about.
    T.check("some lists make reagents", withCrafted > 0, withCrafted)
    T.check("some lists make none", withoutCrafted >= #CASES * 2, withoutCrafted)
    T.check("some paths have recipes to pay for", withFees > 0, withFees)
    T.check("crafts sell for something in every case", withSale == #CASES * 4, withSale)
    T.check("the stock saves something in every case", withStock == #CASES * 4, withStock)
end)

T.finish()
