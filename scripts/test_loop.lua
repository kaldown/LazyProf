-- scripts/test_loop.lua
--
-- The whole loop the addon is for, on real recipe data: plan with some stock
-- owned, buy the plan's shopping list, then craft point by point while the
-- planner is asked again at every skill (as it is in game) with what is left
-- in the bags. With average luck a player who follows what the planner shows
-- must not have to buy more than one who simply follows the plan that was
-- shopped for - and far less than without the remembered route, where the
-- planner wanders between routes that are all nearly free once the reagents
-- are in the bags.
--
-- Run from the addon root:  lua5.1 scripts/test_loop.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

local FILES = {
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
    "Modules/Pricing/SaleValue.lua",
    "Modules/Pathfinder/MaterialResolver.lua",
    "Modules/Pathfinder/Pathfinder.lua",
}

local CASES = {
    { name = "tbc_leatherworking_300_375", interface = 20505, prof = "leatherworking", from = 300, to = 375,
      withoutMemory = true },
    { name = "forever_leatherworking_117_300", interface = 16001, camelot = true, prof = "leatherworking", from = 117, to = 300 },
}

local function bagsOf(inventory)
    local breakdown = {}
    for itemId, count in pairs(inventory) do breakdown[itemId] = { bags = count } end
    return breakdown
end

for _, case in ipairs(CASES) do
    T.section(case.name, function()
        local CraftLib = harness.loadCraftLib(case.interface, { sod = case.sod, camelot = case.camelot })
        local LazyProf = harness.loadLazyProf(FILES)
        LazyProf.Client = LazyProf.Client or {}
        LazyProf.Client.PlayerSkill = function() return 0 end
        LazyProf.Client.GetItemInfo = function() return nil end
        LazyProf.PriceManager = { PeekPriceInfo = function() return { price = 1, source = "TSM" } end }
        local PF, Utils = LazyProf.Pathfinder, LazyProf.Utils
        local prof = CraftLib:GetProfession(case.prof)
        local byId = {}
        local function known()
            local recipes = Utils.DeepCopy(prof.recipes)
            for _, r in ipairs(recipes) do
                r.learned = true
                byId[r.id] = r
            end
            return recipes
        end
        local prices = harness.priceTable(known())

        -- Twenty of every fourth reagent are owned before any planning.
        local ids = {}
        for itemId in pairs(prices) do ids[#ids + 1] = itemId end
        table.sort(ids)
        local inventory = {}
        for i, itemId in ipairs(ids) do
            if i % 4 == 0 then inventory[itemId] = 20 end
        end

        local function plan(from, stock, previous)
            LazyProf.db.profile.strategy = "cheapest"
            LazyProf.RecipeAvailability:BeginRecalc()
            LazyProf.SelfFound:BeginRecalc({})
            local steps, _, route = PF:PlanRoutes({
                strategy = LazyProf.PathfinderStrategies.cheapest, strategyName = "cheapest",
                startSkill = from, targetSkill = case.to, recipes = known(), prices = prices, racialBonus = 0, pins = {},
                inventory = stock, sourceBreakdown = bagsOf(stock), previous = previous,
            })
            LazyProf.SelfFound:EndRecalc()
            LazyProf.RecipeAvailability:EndRecalc()
            return steps, route
        end
        local function keptOf(route)
            for _, candidate in ipairs(route.candidates) do
                if candidate.key == route.kept then return candidate end
            end
        end

        -- The first plan, and its whole list bought.
        local first, firstRoute = plan(case.from, inventory, nil)
        local ranges = PF:RouteRanges(first)
        local list = keptOf(firstRoute).spend
        local held = {}
        for itemId, count in pairs(inventory) do held[itemId] = count end
        for _, row in ipairs(PF:Account(first, inventory, bagsOf(inventory), prices, {}).missing.rows) do
            if row.toBuy > 0 then held[row.itemId] = (held[row.itemId] or 0) + row.toBuy end
        end
        T.check("fixture: the first plan uses the owned stock", firstRoute.kept == "stock", firstRoute.kept)
        T.check("fixture: there is a list to buy", list > 0)

        -- Craft from `from` to the target one skill point at a time with
        -- average luck (1 / chance crafts per point, fractions carried), buying
        -- whatever a craft lacks. mode: "plan" follows the route that was
        -- shopped for; "memory" follows the planner with the remembered route
        -- handed on as the addon does; "scratch" follows the planner without it.
        local function simulate(mode)
            local have = {}
            for itemId, count in pairs(held) do have[itemId] = count end
            local memory = ranges
            local bought, carried, switches = 0, 0, 0
            for skill = case.from, case.to - 1 do
                local recipe
                if mode == "plan" then
                    for _, range in ipairs(ranges) do
                        if skill >= math.floor(range.from) and skill < range.to then recipe = byId[range.recipeId] end
                    end
                else
                    local steps, route = plan(skill, have, mode == "memory" and memory or nil)
                    if mode == "memory" then
                        if route.kept == "previous" then
                            memory = PF:ExtendRanges(memory, steps, skill)
                        else
                            memory = (#steps > 0) and PF:RouteRanges(steps) or nil
                            switches = switches + 1
                        end
                    end
                    if steps[1] and steps[1].skillStart <= skill then recipe = byId[steps[1].recipe.id] end
                end
                if recipe then
                    local chance = Utils.GetSkillUpChance(skill, recipe.skillRange)
                    local crafts = 1
                    if chance > 0 then
                        carried = carried + 1 / chance
                        crafts = math.floor(carried + 1e-9)
                        carried = carried - crafts
                    end
                    for _, reagent in ipairs(recipe.reagents) do
                        local need = reagent.count * crafts
                        local got = have[reagent.itemId] or 0
                        if got < need then
                            bought = bought + (need - got) * (prices[reagent.itemId] or 0)
                            got = need
                        end
                        have[reagent.itemId] = got - need
                    end
                end
            end
            return bought, switches
        end

        local byPlan = simulate("plan")
        local byMemory, switches = simulate("memory")
        print(string.format("INFO: %s: list %d; bought later following the plan %d, following the planner %d (%d route changes)",
            case.name, list, byPlan, byMemory, switches))
        T.check("following the planner costs no more than following the plan that was shopped for (within 1% of the list)",
            byMemory <= byPlan + 0.01 * list, string.format("%d vs %d, list %d", byMemory, byPlan, list))
        T.check("the planner rarely leaves the plan in hand", switches <= 5, switches)

        if case.withoutMemory then
            local fromScratch = simulate("scratch")
            print(string.format("INFO: %s: without the remembered route %d is bought later", case.name, fromScratch))
            T.check("fixture: without the remembered route more is bought later", fromScratch > byMemory + 0.01 * list,
                string.format("%d vs %d", fromScratch, byMemory))
        end
    end)
end

T.finish()
