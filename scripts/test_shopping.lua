-- scripts/test_shopping.lua
--
-- The shopping list as one row per item (need / have / to buy / cost, where
-- to collect owned stock, whether a known recipe makes it) and the
-- per-item craft-or-buy choice. The older per-source lists stay as they were.
--
-- Run from the addon root:  lua5.1 scripts/test_shopping.lua

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

-- Items: 10 Bolt (made from 3x 11 Cloth by tailoring recipe 500), 12 Thread
-- (vendor), 13 Bar (made from 2x 14 Ore by mining recipe 600, trainer-taught).
local BOLT, CLOTH, THREAD, BAR, ORE = 10, 11, 12, 13, 14
local NAMES = { [BOLT] = "Bolt", [CLOTH] = "Cloth", [THREAD] = "Thread", [BAR] = "Bar", [ORE] = "Ore" }
local PRODUCERS = {
    [BOLT] = { { professionKey = "tailoring", recipe = { id = 500, name = "Bolt of Cloth", source = { type = "vendor" },
        reagents = { { itemId = CLOTH, count = 3, name = "Cloth" } } } } },
    [BAR] = { { professionKey = "mining", recipe = { id = 600, name = "Smelt Bar", source = { type = "trainer" },
        reagents = { { itemId = ORE, count = 2, name = "Ore" } } } } },
}
_G.CraftLib = { GetRecipeByProduct = function(_, itemId) return PRODUCERS[itemId] end }

local skills = {}
LazyProf.Client.PlayerSkill = function(_, key) return skills[key] or 0 end
LazyProf.Client.GetItemInfo = function(_, itemId) return NAMES[itemId] end
local bags = {}
LazyProf.Inventory.ScanBags = function() return bags end
LazyProf.PriceManager = {
    PeekPriceInfo = function(_, itemId)
        if itemId == THREAD then return { price = 10, source = "Vendor", detail = "TSM" } end
        return { price = 1, source = "TSM", detail = "DBRecent" }
    end,
}

local R1 = { id = 1, name = "Shirt", learned = true, reagents = {
    { itemId = BOLT, count = 2, name = "Bolt" }, { itemId = THREAD, count = 1, name = "Thread" } } }
local R2 = { id = 2, name = "Bag", learned = true, reagents = {
    { itemId = CLOTH, count = 1, name = "Cloth" }, { itemId = BAR, count = 1, name = "Bar" } } }
local STEPS = { { recipe = R1, quantity = 10, skillStart = 1 }, { recipe = R2, quantity = 5, skillStart = 20 } }
local PRICES = { [BOLT] = 500, [CLOTH] = 100, [THREAD] = 10, [BAR] = 300, [ORE] = 200 }

local function calc(opts)
    opts = opts or {}
    bags = opts.bags or { [CLOTH] = 5 }
    local inventory = opts.inventory or { [CLOTH] = 15 }
    local breakdown = opts.breakdown or { [CLOTH] = { bags = 5, bank = 10 } }
    return PF:CalculateMissingMaterials(STEPS, inventory, breakdown, opts.prices or PRICES)
end
local function rowOf(result, itemId)
    for _, row in ipairs(result.rows) do
        if row.itemId == itemId then return row end
    end
end
local function listHas(list, itemId)
    for _, entry in ipairs(list) do
        if entry.itemId == itemId then return entry end
    end
end
local function choose(itemId, choice)
    LazyProf.CharStore:Get().craftChoices[itemId] = choice
end

LazyProf.db.profile.strategy = "cheapest"
LazyProf.db.profile.materialResolution = "cost"
LazyProf.db.char.learnedRecipes = { tailoring = { [500] = true } }

T.section("rows, automatic choice", function()
    local m = calc()
    T.check("rows are returned beside the lists", type(m.rows) == "table" and type(m.fromAH) == "table")
    local bolt, cloth, thread, bar = rowOf(m, BOLT), rowOf(m, CLOTH), rowOf(m, THREAD), rowOf(m, BAR)
    T.check("a row for every needed item, none for an unused one",
        bolt and cloth and thread and bar and not rowOf(m, ORE))

    T.eq("bolt: need", bolt.need, 20)
    T.check("bolt: a known recipe makes it", bolt.craftable == true)
    T.check("bolt: crafted because that is cheaper", bolt.crafted == true)
    T.check("bolt: no explicit choice", bolt.choice == nil)
    T.eq("bolt: nothing to buy", bolt.toBuy, 0)
    T.eq("bolt: the recipe that makes it", bolt.craftRecipeName, "Bolt of Cloth")
    T.eq("bolt: child row for the cloth it takes", bolt.children[1].itemId, CLOTH)
    T.eq("bolt: child need", bolt.children[1].need, 60)

    T.eq("cloth: need covers direct use and the bolts", cloth.need, 65)
    T.eq("cloth: have counts every source", cloth.have, 15)
    T.eq("cloth: in bags", cloth.inBags, 5)
    T.eq("cloth: to collect from the bank", cloth.sources.bank, 10)
    T.eq("cloth: to buy", cloth.toBuy, 50)
    T.eq("cloth: unit price", cloth.unitPrice, 100)
    T.eq("cloth: cost", cloth.cost, 5000)
    T.check("cloth: not craftable", cloth.craftable == false)

    T.eq("thread: to buy", thread.toBuy, 10)
    T.eq("thread: cost", thread.cost, 100)
    T.check("thread: marked as a vendor item", thread.isVendor == true)
    T.eq("thread: price source", thread.priceSource, "Vendor")
    T.check("cloth: not a vendor item", cloth.isVendor == false)

    T.check("bar: the character cannot make it (no mining)", bar.craftable == false and not bar.crafted)
    T.eq("bar: to buy", bar.toBuy, 5)

    T.eq("rows in the order the items are first used", m.rows[1].firstUsedAtSkill, 1)
    T.check("later items after", m.rows[#m.rows].firstUsedAtSkill == 20)

    -- The older lists still say the same.
    T.check("lists: bolts to craft", listHas(m.toCraft, BOLT) and listHas(m.toCraft, BOLT).quantity == 20)
    T.eq("lists: cloth from the bank", listHas(m.fromBank, CLOTH).missing, 10)
    T.eq("lists: cloth to buy", listHas(m.fromAH, CLOTH).missing, 50)
    T.eq("lists: thread to buy", listHas(m.fromAH, THREAD).missing, 10)
    T.check("lists: no bolts to buy", listHas(m.fromAH, BOLT) == nil)
    T.eq("to-buy total", m.buyTotal, 5000 + 100 + 1500)
end)

T.section("explicit choices", function()
    choose(BOLT, "buy")
    local m = calc()
    local bolt, cloth = rowOf(m, BOLT), rowOf(m, CLOTH)
    T.check("buy: not crafted, still craftable", bolt.crafted == false and bolt.craftable == true)
    T.eq("buy: the choice is on the row", bolt.choice, "buy")
    T.eq("buy: all bolts bought", bolt.toBuy, 20)
    T.eq("buy: cost", bolt.cost, 10000)
    T.eq("buy: cloth only for its direct use", cloth.need, 5)
    T.eq("buy: cloth covered by the bags", cloth.toBuy, 0)
    T.check("buy: nothing to craft", #m.toCraft == 0)
    T.check("buy: no children", bolt.children == nil)

    -- Fastest: automatic never crafts; an explicit craft does.
    choose(BOLT, nil)
    LazyProf.db.profile.strategy = "fastest"
    m = calc()
    T.check("fastest, automatic: not crafted (as before)", rowOf(m, BOLT).crafted == false)
    T.check("fastest, automatic: still offered", rowOf(m, BOLT).craftable == true)
    choose(BOLT, "craft")
    m = calc()
    T.check("fastest, craft chosen: crafted", rowOf(m, BOLT).crafted == true)
    T.eq("fastest, craft chosen: the choice is on the row", rowOf(m, BOLT).choice, "craft")
    LazyProf.db.profile.strategy = "cheapest"

    -- Craft chosen although buying is cheaper.
    choose(BOLT, "craft")
    m = calc({ prices = { [BOLT] = 50, [CLOTH] = 100, [THREAD] = 10, [BAR] = 300, [ORE] = 200 } })
    T.check("craft chosen wins over the price comparison", rowOf(m, BOLT).crafted == true)
    choose(BOLT, nil)
    m = calc({ prices = { [BOLT] = 50, [CLOTH] = 100, [THREAD] = 10, [BAR] = 300, [ORE] = 200 } })
    T.check("automatic buys when buying is cheaper", rowOf(m, BOLT).crafted == false)

    -- Setting "none": automatic never crafts, an explicit craft still does.
    LazyProf.db.profile.materialResolution = "none"
    m = calc()
    T.check("resolution off, automatic: not crafted", rowOf(m, BOLT).crafted == false)
    choose(BOLT, "craft")
    m = calc()
    T.check("resolution off, craft chosen: crafted", rowOf(m, BOLT).crafted == true)
    choose(BOLT, nil)
    LazyProf.db.profile.materialResolution = "cost"
end)

T.section("who can craft", function()
    -- Mining: no learned cache. Without the profession: no.
    local m = calc()
    T.check("no cache, no profession: not craftable", rowOf(m, BAR).craftable == false)
    -- With the profession and a trainer-taught recipe: yes (the old test, as a fallback).
    skills.mining = 120
    m = calc()
    T.check("no cache, has the profession, trainer recipe: craftable", rowOf(m, BAR).craftable == true)
    T.check("automatic still buys when crafting is dearer", rowOf(m, BAR).crafted == false)
    choose(BAR, "craft")
    m = calc()
    local bar, ore = rowOf(m, BAR), rowOf(m, ORE)
    T.check("craft chosen: bars are crafted", bar.crafted == true)
    T.check("craft chosen: the ore appears", ore ~= nil and ore.need == 10 and ore.toBuy == 10)
    choose(BAR, nil)
    -- A learned cache that does not hold the recipe: no, whatever the profession.
    LazyProf.db.char.learnedRecipes.mining = { [999] = true }
    m = calc()
    T.check("cache present without the recipe: not craftable", rowOf(m, BAR).craftable == false)
    LazyProf.db.char.learnedRecipes.mining = { [600] = true }
    m = calc()
    T.check("cache holds the recipe: craftable", rowOf(m, BAR).craftable == true)
    -- A non-trainer recipe without a cache: no (it cannot be assumed known).
    LazyProf.db.char.learnedRecipes.tailoring = nil
    skills.tailoring = 200
    m = calc()
    T.check("no cache, vendor-taught recipe: not craftable", rowOf(m, BOLT).craftable == false)
    LazyProf.db.char.learnedRecipes.tailoring = { [500] = true }
    LazyProf.db.char.learnedRecipes.mining = nil
    skills = {}
end)

T.section("edges", function()
    -- Fully owned in the bags: a row, nothing to buy, in no list.
    local m = calc({ bags = { [CLOTH] = 5, [THREAD] = 10 }, inventory = { [CLOTH] = 15, [THREAD] = 10 },
        breakdown = { [CLOTH] = { bags = 5, bank = 10 }, [THREAD] = { bags = 10 } } })
    local thread = rowOf(m, THREAD)
    T.check("owned in the bags: still a row", thread ~= nil and thread.need == 10 and thread.have == 10)
    T.eq("owned in the bags: nothing to buy", thread.toBuy, 0)
    T.check("owned in the bags: in no list", listHas(m.fromAH, THREAD) == nil and listHas(m.fromBank, THREAD) == nil)

    -- No price: the row says so, totals stay numbers.
    m = calc({ prices = { [BOLT] = 500, [CLOTH] = 100, [BAR] = 300, [ORE] = 200 } })
    thread = rowOf(m, THREAD)
    T.check("no price: unit price unknown", thread.unitPrice == nil)
    T.eq("no price: cost is zero, not an error", thread.cost, 0)
    T.check("no price: flagged", thread.unpriced == true)
    T.check("the total is still a number", type(m.buyTotal) == "number")

    -- Alts and other sources are reported per row.
    m = calc({ bags = {}, inventory = { [THREAD] = 6 },
        breakdown = { [THREAD] = { mail = 2, alts = { ["Alt-Realm"] = { bags = 4 } } } } })
    thread = rowOf(m, THREAD)
    T.eq("mail count on the row", thread.sources.mail, 2)
    T.eq("alt count on the row", thread.sources.alts, 4)
    T.eq("buy the rest", thread.toBuy, 4)

    -- Recipe fees still come back for the footer.
    local unlearned = { id = 3, name = "Hat", learned = false, _sourceInfo = { type = "vendor", cost = 250 },
        reagents = { { itemId = THREAD, count = 1, name = "Thread" } } }
    local m2 = PF:CalculateMissingMaterials({ { recipe = unlearned, quantity = 1, skillStart = 1 } }, {}, {}, PRICES)
    T.eq("recipe costs", m2.recipeCosts, 250)

    local empty = PF:CalculateMissingMaterials({}, {}, {}, PRICES)
    T.eq("no steps: no rows", #empty.rows, 0)
    T.eq("no steps: zero total", empty.buyTotal, 0)
end)

T.finish()
