-- scripts/test_loop.lua
--
-- The whole loop the addon is for, on real recipe data: plan with some stock
-- owned, buy the plan's shopping list, then craft point by point while the
-- path is calculated again at every skill (as it is in game) from what is
-- left in the bags. With average luck a player who follows what the planner
-- shows must not have to buy more than one who simply follows the plan that
-- was shopped for - and far less than without the remembered route, where the
-- planner wanders between routes that are all nearly free once the reagents
-- are in the bags.
--
-- The calculations go through Pathfinder:BuildPath, so the remembered route
-- is kept, carried on and replaced exactly as in the addon.
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
    { name = "forever_leatherworking_117_200", interface = 16001, camelot = true, prof = "leatherworking", from = 117, to = 200 },
    { name = "vanilla_engineering_100_200", interface = 11508, prof = "engineering", from = 100, to = 200 },
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
        LazyProf.PriceManager = {
            PeekPriceInfo = function() return { price = 1, source = "TSM" } end,
            GetPrices = function(_, ids)
                local out = {}
                for _, id in ipairs(ids) do out[id] = prices[id] end
                return out
            end,
        }
        LazyProf.db.profile.strategy = "cheapest"
        LazyProf.db.profile.saleValueMode = "none"
        local milestones = { case.to }
        local store = LazyProf.CharStore:Profession(case.prof)

        -- Twenty of every fourth reagent are owned before any planning.
        local ids = {}
        for itemId in pairs(prices) do ids[#ids + 1] = itemId end
        table.sort(ids)
        local inventory = {}
        for i, itemId in ipairs(ids) do
            if i % 4 == 0 then inventory[itemId] = 20 end
        end

        -- One calculation of the addon at `skill` with `stock` in the bags.
        local function calculate(skill, stock)
            LazyProf.Inventory.ScanAll = function() return stock, bagsOf(stock) end
            return PF:BuildPath({
                profKey = case.prof, profData = { name = case.prof, milestones = milestones },
                recipes = known(), startSkill = skill, actualSkill = skill, hasProfession = true,
            })
        end
        local function keptOf(route)
            for _, candidate in ipairs(route.candidates) do
                if candidate.key == route.kept then return candidate end
            end
        end

        -- The first plan, and its whole list bought.
        store.route = nil
        local first = calculate(case.from, inventory)
        local ranges = PF:RouteRanges(first.steps, case.from)
        local list = keptOf(first.route).spend
        local held = {}
        for itemId, count in pairs(inventory) do held[itemId] = count end
        for _, row in ipairs(PF:Account(first.steps, inventory, bagsOf(inventory), prices, {}).missing.rows) do
            if row.toBuy > 0 then held[row.itemId] = (held[row.itemId] or 0) + row.toBuy end
        end
        T.check("fixture: the first plan uses the owned stock", first.route.kept == "stock", first.route.kept)
        T.check("fixture: there is a list to buy", list > 0)

        -- Holding the list, the same calculation again (the window reopened,
        -- item data arrived): the same plan, nothing to buy, however often.
        local function shape(steps)
            local out = {}
            for _, step in ipairs(steps) do
                out[#out + 1] = string.format("%.4f-%.4f %s x%d", step.skillStart, step.skillEnd, tostring(step.recipe.id), step.quantity)
            end
            return table.concat(out, "\n")
        end
        local planned = shape(first.steps)
        for round = 1, 3 do
            local again = calculate(case.from, held)
            T.check("after shopping, calculation " .. round .. ": the same steps", shape(again.steps) == planned)
            T.eq("after shopping, calculation " .. round .. ": nothing to buy", keptOf(again.route).spend, 0)
        end

        -- Craft from `from` to the target one skill point at a time with
        -- average luck (1 / chance crafts per point, fractions carried), buying
        -- whatever a craft lacks. mode: "plan" follows the route that was
        -- shopped for; "memory" follows the addon's calculations as they are;
        -- "scratch" follows them with the remembered route wiped before each.
        local function simulate(mode)
            local have = {}
            for itemId, count in pairs(held) do have[itemId] = count end
            store.route = ranges
            local bought, carried, switches = 0, 0, 0
            for skill = case.from, case.to - 1 do
                local recipe
                if mode == "plan" then
                    for _, range in ipairs(ranges) do
                        if skill >= math.floor(range.from) and skill < range.to then recipe = byId[range.recipeId] end
                    end
                else
                    if mode == "scratch" then store.route = nil end
                    local path = calculate(skill, have)
                    if mode == "memory" and path.route.kept ~= "previous" then switches = switches + 1 end
                    local step = path.steps[1]
                    if step and step.skillStart <= skill then recipe = byId[step.recipe.id] end
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
        store.route = nil
    end)
end

T.finish()
