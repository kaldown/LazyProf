-- scripts/test_account.lua
--
-- The one accounting of what the player pays: the shopping computation over a
-- set of craft steps (stock taken off, craft-or-buy applied, recipe costs
-- added), minus what the crafts sell for. Every total the window shows and
-- the planner's choice between candidate routes come from it.
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

T.finish()
