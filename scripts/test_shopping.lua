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

T.section("a function of its arguments", function()
    -- The bags' count comes from the source breakdown; nothing is scanned here.
    local m = calc({ bags = { [CLOTH] = 99 } })   -- a scan would say 99, the breakdown says 5
    T.eq("bags come from the breakdown", rowOf(m, CLOTH).inBags, 5)
    T.eq("and what is left to buy follows it", rowOf(m, CLOTH).toBuy, 50)

    -- Asked with nothing owned, it answers for empty bags whatever the bags hold.
    bags = { [CLOTH] = 99, [THREAD] = 99 }
    m = PF:CalculateMissingMaterials(STEPS, {}, {}, PRICES)
    T.eq("nothing owned: all the cloth is bought", rowOf(m, CLOTH).toBuy, 65)
    T.eq("nothing owned: all the thread is bought", rowOf(m, THREAD).toBuy, 10)
    T.eq("nothing owned: the total", m.buyTotal, 6500 + 100 + 1500)
end)

T.section("owned stock of a crafted reagent", function()
    -- Eight bolts in the bank: they are used first, the other twelve are made.
    local m = calc({ bags = {}, inventory = { [BOLT] = 8 }, breakdown = { [BOLT] = { bank = 8 } } })
    local bolt, cloth = rowOf(m, BOLT), rowOf(m, CLOTH)
    T.check("still crafted", bolt.crafted == true)
    T.eq("only the rest is crafted", bolt.craftQuantity, 12)
    T.eq("have counts the bank", bolt.have, 8)
    T.eq("the row says where the owned ones are", bolt.sources.bank, 8)
    T.eq("collect them from the bank first", listHas(m.fromBank, BOLT) and listHas(m.fromBank, BOLT).missing, 8)
    T.eq("to craft: twelve", listHas(m.toCraft, BOLT).quantity, 12)
    T.eq("cloth for twelve bolts and the direct use", cloth.need, 36 + 5)
    T.eq("nothing of the bolts is bought", bolt.toBuy, 0)
    T.eq("the total", m.buyTotal, 4100 + 100 + 1500)

    -- The bank covers them all: nothing is crafted, nothing bought.
    m = calc({ bags = {}, inventory = { [BOLT] = 25 }, breakdown = { [BOLT] = { bank = 25 } } })
    bolt, cloth = rowOf(m, BOLT), rowOf(m, CLOTH)
    T.check("covered by the bank: not crafted", bolt.crafted == false)
    T.eq("covered by the bank: nothing to buy", bolt.toBuy, 0)
    T.eq("covered by the bank: collect twenty", listHas(m.fromBank, BOLT).missing, 20)
    T.eq("covered by the bank: cloth only for its direct use", cloth.need, 5)
end)

T.section("a crafted reagent that is also the source of another", function()
    -- Plates are made from bars (recipe 700, known); bars are also used
    -- directly and, by choice, smelted from ore. One level deep: the bars
    -- the plates take are bought, and that purchase is on the bar's row.
    local PLATE = 15
    NAMES[PLATE] = "Plate"
    PRODUCERS[PLATE] = { { professionKey = "tailoring", recipe = { id = 700, name = "Make Plate", source = { type = "trainer" },
        reagents = { { itemId = BAR, count = 2, name = "Bar" } } } } }
    LazyProf.db.char.learnedRecipes = { tailoring = { [500] = true, [700] = true }, mining = { [600] = true } }
    choose(BAR, "craft")
    local R3 = { id = 3, name = "Armor", learned = true, reagents = {
        { itemId = PLATE, count = 1, name = "Plate" }, { itemId = BAR, count = 1, name = "Bar" } } }
    local prices = { [PLATE] = 900, [BAR] = 300, [ORE] = 200 }
    local m = PF:CalculateMissingMaterials({ { recipe = R3, quantity = 3, skillStart = 1 } }, {}, {}, prices)
    local plate, bar, ore = rowOf(m, PLATE), rowOf(m, BAR), rowOf(m, ORE)
    T.check("plates are crafted (600 of bars against 900)", plate.crafted == true and plate.craftQuantity == 3)
    T.check("bars for the direct use are smelted", bar.crafted == true and bar.craftQuantity == 3)
    T.eq("the bar row needs the direct ones and the plates' ones", bar.need, 3 + 6)
    T.eq("the plates' bars are bought", bar.toBuy, 6)
    T.eq("and paid for on the row", bar.cost, 1800)
    T.eq("ore for the smelted bars", ore.toBuy, 6)
    T.eq("the total counts both", m.buyTotal, 1800 + 1200)
    choose(BAR, nil)
    PRODUCERS[PLATE], NAMES[PLATE] = nil, nil
    LazyProf.db.char.learnedRecipes = { tailoring = { [500] = true } }
end)

T.section("craft or buy does not count stock twice", function()
    -- Bars are used directly and plates are made from bars. Bars smelt from
    -- ore (156 a bar against 465), plates cost 289 to buy against 930 of bars.
    local PLATE = 15
    NAMES[PLATE] = "Plate"
    PRODUCERS[PLATE] = { { professionKey = "tailoring", recipe = { id = 700, name = "Make Plate", source = { type = "trainer" },
        reagents = { { itemId = BAR, count = 2, name = "Bar" } } } } }
    local savedBar = PRODUCERS[BAR]
    PRODUCERS[BAR] = { { professionKey = "tailoring", recipe = { id = 600, name = "Smelt Bar", source = { type = "trainer" },
        reagents = { { itemId = ORE, count = 3, name = "Ore" } } } } }
    LazyProf.db.char.learnedRecipes = { tailoring = { [500] = true, [600] = true, [700] = true } }
    local steps = {
        { recipe = { id = 1, name = "A", learned = true, reagents = { { itemId = BAR, count = 4, name = "Bar" } } }, quantity = 5, skillStart = 1 },
        { recipe = { id = 2, name = "B", learned = true, reagents = { { itemId = PLATE, count = 4, name = "Plate" } } }, quantity = 6, skillStart = 10 },
    }
    local prices = { [ORE] = 52, [BAR] = 465, [PLATE] = 289 }

    local none = PF:CalculateMissingMaterials(steps, {}, {}, prices)
    T.check("nothing owned: bars are smelted, plates bought", rowOf(none, BAR).crafted == true and rowOf(none, PLATE).crafted == false)
    T.eq("nothing owned: the total", none.buyTotal, 60 * 52 + 24 * 289)

    -- 35 bars owned: 20 go to the direct use, 15 are left - not enough to
    -- make plates cheaper than buying them.
    local with = PF:CalculateMissingMaterials(steps, { [BAR] = 35 }, { [BAR] = { bags = 35 } }, prices)
    T.check("with 35 bars: plates are still bought", rowOf(with, PLATE).crafted == false)
    T.eq("with 35 bars: no bars to buy", rowOf(with, BAR).toBuy, 0)
    T.eq("with 35 bars: only the plates are paid for", with.buyTotal, 24 * 289)
    T.check("owning stock never makes the list dearer", with.buyTotal <= none.buyTotal)
    T.eq("and the saving is what the smelting would have cost", PF:StockSaving(steps, prices, with.buyTotal), 60 * 52)

    -- Enough bars left over after the direct use: now the plates are made.
    local plenty = PF:CalculateMissingMaterials(steps, { [BAR] = 68 }, { [BAR] = { bags = 68 } }, prices)
    T.check("with 68 bars: plates are made from the 48 left over", rowOf(plenty, PLATE).crafted == true)
    T.eq("with 68 bars: nothing to buy", plenty.buyTotal, 0)

    -- Two crafted reagents share a source: the stock goes to the first one only.
    local X1, X2, S = 21, 22, 23
    NAMES[X1], NAMES[X2], NAMES[S] = "X1", "X2", "S"
    PRODUCERS[X1] = { { professionKey = "tailoring", recipe = { id = 801, name = "Make X1", source = { type = "trainer" },
        reagents = { { itemId = S, count = 1, name = "S" } } } } }
    PRODUCERS[X2] = { { professionKey = "tailoring", recipe = { id = 802, name = "Make X2", source = { type = "trainer" },
        reagents = { { itemId = S, count = 1, name = "S" } } } } }
    LazyProf.db.char.learnedRecipes.tailoring[801] = true
    LazyProf.db.char.learnedRecipes.tailoring[802] = true
    local shared = {
        { recipe = { id = 3, name = "C", learned = true, reagents = {
            { itemId = X1, count = 1, name = "X1" }, { itemId = X2, count = 1, name = "X2" } } }, quantity = 10, skillStart = 1 },
    }
    local sharedPrices = { [X1] = 80, [X2] = 90, [S] = 100 }
    local m = PF:CalculateMissingMaterials(shared, { [S] = 10 }, { [S] = { bags = 10 } }, sharedPrices)
    T.check("shared source: the first reagent is made from the stock", rowOf(m, X1).crafted == true)
    T.check("shared source: the second is bought (the stock is spoken for)", rowOf(m, X2).crafted == false)
    T.eq("shared source: the total", m.buyTotal, 900)

    PRODUCERS[PLATE], PRODUCERS[X1], PRODUCERS[X2] = nil, nil, nil
    PRODUCERS[BAR] = savedBar
    LazyProf.db.char.learnedRecipes = { tailoring = { [500] = true } }
end)

-- Every cost is whole copper and the total adds up the rounded costs, so
-- the Cost column of the shopping table adds up to the total shown under it.
T.section("whole copper", function()
    local prices = { [BOLT] = 500, [CLOTH] = 0.4, [THREAD] = 33.3, [BAR] = 300.5, [ORE] = 200 }
    choose(BOLT, "buy")
    local m = calc({ prices = prices, inventory = {}, breakdown = {}, bags = {} })
    local cloth, thread, bar = rowOf(m, CLOTH), rowOf(m, THREAD), rowOf(m, BAR)
    T.eq("5 cloth at 0.4", cloth.cost, 2)
    T.eq("10 thread at 33.3", thread.cost, 333)
    T.eq("5 bars at 300.5", bar.cost, 1503)
    local sum = 0
    for _, row in ipairs(m.rows) do
        sum = sum + row.cost
        T.eq(tostring(row.name) .. ": a whole amount", row.cost, math.floor(row.cost))
    end
    T.eq("the total is the sum of the rows", m.buyTotal, sum)
    T.eq("to the copper", m.buyTotal, 10000 + 2 + 333 + 1503)
    T.eq("the old per-source list carries the same amount", listHas(m.fromAH, BAR).estimatedCost, 1503)
    choose(BOLT, nil)

    local hat = { id = 40, name = "Hat", learned = false, _sourceInfo = { type = "ah", price = 250.5 },
        reagents = { { itemId = THREAD, count = 1, name = "Thread" } } }
    m = PF:CalculateMissingMaterials({ { recipe = hat, quantity = 1, skillStart = 1 } }, {}, {}, PRICES)
    T.eq("a recipe's price is whole copper", m.recipeRows[1].cost, 251)
    T.eq("and so is their sum", m.recipeCosts, 251)
end)

T.section("recipes to learn", function()
    local function unlearned(id, name, info)
        return { id = id, name = name, learned = false, _sourceInfo = info,
            reagents = { { itemId = THREAD, count = 1, name = "Thread" } } }
    end
    local steps = {
        { recipe = unlearned(31, "Zebra Hat", { type = "vendor", cost = 250 }), quantity = 1, skillStart = 1 },
        { recipe = unlearned(32, "Free Hat", { type = "inventory" }), quantity = 1, skillStart = 2 },
        { recipe = unlearned(33, "Auction Hat", { type = "ah", price = 400 }), quantity = 1, skillStart = 3 },
        { recipe = unlearned(33, "Auction Hat", { type = "ah", price = 400 }), quantity = 2, skillStart = 4 },
        { recipe = R1, quantity = 1, skillStart = 5 },
    }
    local m = PF:CalculateMissingMaterials(steps, {}, {}, PRICES)
    T.eq("one row per recipe that costs something", #m.recipeRows, 2)
    T.eq("by name", m.recipeRows[1].name, "Auction Hat")
    T.eq("its price", m.recipeRows[1].cost, 400)
    T.eq("where it comes from", m.recipeRows[1].sourceInfo.type, "ah")
    T.eq("the other", m.recipeRows[2].cost, 250)
    T.eq("the sum is the recipe costs", m.recipeCosts, 650)
    T.eq("no steps: no rows", #PF:CalculateMissingMaterials({}, {}, {}, PRICES).recipeRows, 0)
end)

T.finish()
