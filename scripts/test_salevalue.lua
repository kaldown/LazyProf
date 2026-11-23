-- scripts/test_salevalue.lua
--
-- What one craft of a recipe sells for: the vendor price of the crafted item
-- (default), its auction price after the cut, or nothing - and for which
-- recipes that value may be used when ranking.
--
-- Run from the addon root:  lua5.1 scripts/test_salevalue.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 11508 })
local clock = 100
_G.GetTime = function() return clock end
local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Client/Family.lua",
    "Core/Client/Classic.lua",
    "Core/Config.lua",
    "Modules/Pricing/SaleValue.lua",
})
local SV = LazyProf.SaleValue

local function recipe(id, itemId, opts)
    opts = opts or {}
    return {
        id = id, name = "Recipe " .. id, itemId = itemId,
        skillRequired = opts.required or 1,
        skillRange = { orange = 1, yellow = 50, green = 75, gray = opts.gray or 100 },
        reagents = opts.reagents or { { itemId = 900, count = 1, name = "Leather" } },
    }
end

-- Injected item data: sell = { [itemId] = copper }, an item missing from
-- `sell` is not loaded; market = { [itemId] = copper }.
local function deps(sell, market, asked)
    return {
        sellPrice = function(itemId)
            if asked then asked[#asked + 1] = itemId end
            local value = sell[itemId]
            if value == nil then return nil, false end
            return value, true
        end,
        marketPrice = function(itemId) return market and market[itemId] or nil end,
    }
end

T.section("one craft", function()
    local value, source, loading = SV.Of(recipe(1, 501), "vendor", deps({ [501] = 45 }))
    T.eq("vendor: the crafted item's sell price", value, 45)
    T.eq("vendor: its source", source, "vendor")
    T.check("vendor: not loading", loading == false)

    value, source = SV.Of(recipe(2, nil), "vendor", deps({}))
    T.eq("no crafted item (an enchant): nothing", value, 0)
    T.check("no crafted item: no source", source == nil)

    value, source = SV.Of(recipe(3, 503), "vendor", deps({ [503] = 0 }))
    T.eq("not sellable: nothing", value, 0)
    T.check("not sellable: no source", source == nil)

    value, source, loading = SV.Of(recipe(4, 504), "vendor", deps({}))
    T.eq("item data not loaded: nothing yet", value, 0)
    T.check("item data not loaded: flagged as loading", loading == true)

    value, source = SV.Of(recipe(5, 505), "auction", deps({ [505] = 400 }, { [505] = 1000 }))
    T.eq("auction: the market price less the 5% cut", value, 950)
    T.eq("auction: its source", source, "auction")

    value, source = SV.Of(recipe(6, 506), "auction", deps({ [506] = 500 }, { [506] = 400 }))
    T.eq("auction: never below the vendor value", value, 500)
    T.eq("auction: then it is a vendor sale", source, "vendor")

    value, source = SV.Of(recipe(7, 507), "auction", deps({ [507] = 120 }, {}))
    T.eq("auction: no market price falls back to the vendor value", value, 120)
    T.eq("auction: fallback source", source, "vendor")

    value = SV.Of(recipe(8, 508), "auction", deps({ [508] = 0 }, { [508] = 33 }))
    T.eq("auction: whole copper, rounded down", value, 31)

    value, source, loading = SV.Of(recipe(9, 509), "none", deps({ [509] = 45 }, { [509] = 1000 }))
    T.eq("do not count: nothing", value, 0)
    T.check("do not count: no source, not loading", source == nil and loading == false)
end)

T.section("the table of one calculation", function()
    local real = { [900] = true, [901] = false }
    local recipes = {
        recipe(1, 501),
        recipe(2, 502, { reagents = { { itemId = 900, count = 2 }, { itemId = 901, count = 1 } } }),
        recipe(3, nil),
        recipe(4, 504),
    }
    local sale = SV:Build(recipes, {
        mode = "vendor", from = 1, to = 300, racialBonus = 0,
        deps = deps({ [501] = 45, [502] = 80 }),
        isRealPrice = function(itemId) return real[itemId] end,
    })
    T.eq("mode is kept", sale.mode, "vendor")
    T.eq("value by recipe id", sale.values[1], 45)
    T.eq("source by recipe id", sale.sources[1], "vendor")
    T.eq("a recipe with an estimated reagent price still sells", sale.values[2], 80)
    T.eq("ranking uses the value of a really priced recipe", sale.rank[1], 45)
    T.check("ranking leaves out a recipe with an estimated reagent price", sale.rank[2] == nil)
    T.check("nothing for a recipe without an item", sale.values[3] == nil)
    T.check("nothing yet for an item still loading", sale.values[4] == nil)
    T.eq("one item is loading", sale.loading, 1)

    -- Two recipes make the same item: it is one item loading, not two.
    local twins = { recipe(5, 505), recipe(6, 505), recipe(7, 506) }
    local twinSale = SV:Build(twins, { mode = "vendor", from = 1, to = 300, deps = deps({}),
        isRealPrice = function() return true end })
    T.eq("a shared crafted item is counted as loading once", twinSale.loading, 2)

    -- Each reagent is asked about once per calculation, however many recipes use it.
    local askedReal = {}
    local many = {}
    for i = 1, 5 do many[i] = recipe(20 + i, 520 + i) end
    local sell = {}
    for i = 1, 5 do sell[520 + i] = 10 end
    SV:Build(many, { mode = "vendor", from = 1, to = 300, deps = deps(sell),
        isRealPrice = function(itemId) askedReal[#askedReal + 1] = itemId; return true end })
    T.eq("a reagent's price is checked once per calculation", #askedReal, 1)

    sale = SV:Build(recipes, { mode = "none", from = 1, to = 300, deps = deps({ [501] = 45 }) })
    T.check("do not count: empty", next(sale.values) == nil and next(sale.rank) == nil and sale.loading == 0)
    T.eq("do not count: mode", sale.mode, "none")
end)

T.section("only recipes that can be on the path are looked up", function()
    local asked = {}
    local recipes = {
        recipe(1, 601, { required = 1, gray = 100 }),     -- grey before the start
        recipe(2, 602, { required = 100, gray = 200 }),   -- usable
        recipe(3, 603, { required = 226, gray = 300 }),   -- learnable only above the target
        recipe(4, 604, { required = 1, gray = 140 }),     -- grey at 140, kept alive by a racial bonus of 15
    }
    local sale = SV:Build(recipes, { mode = "vendor", from = 150, to = 225, racialBonus = 15,
        deps = deps({ [601] = 1, [602] = 2, [603] = 3, [604] = 4 }, nil, asked),
        isRealPrice = function() return true end })
    table.sort(asked)
    T.eq("two items asked for", #asked, 2)
    T.check("the usable one and the one the racial bonus keeps", asked[1] == 602 and asked[2] == 604)
    T.check("no value for the others", sale.values[1] == nil and sale.values[3] == nil)
end)

T.section("waiting for item data", function()
    -- The module's own lookups: item info through the client adapter.
    local info = {}
    LazyProf.Client.GetItemInfo = function(_, itemId)
        if not info[itemId] then return nil end
        return "Item", nil, 1, 1, 1, "", "", 1, "", "icon", info[itemId]
    end
    -- Reagent 900 has an auction price, reagent 901 only the sell estimate.
    LazyProf.PriceManager = { MarketPrice = function() return nil end,
        PeekPriceInfo = function(_, itemId) return { source = (itemId == 901) and "VendorSell" or "TSM" } end,
        IsRealSource = function(i) return i.source == "TSM" end }
    local recipes = { recipe(1, 701), recipe(2, 702),
        recipe(3, 703, { reagents = { { itemId = 900, count = 1 }, { itemId = 901, count = 1 } } }) }
    local opts = { mode = "vendor", from = 1, to = 300 }
    info[702] = 60
    info[703] = 70

    clock = 100
    local sale = SV:Build(recipes, opts)
    T.eq("vendor value through the adapter (11th item-info return)", sale.values[2], 60)
    T.eq("real prices rank", sale.rank[2], 60)
    T.eq("a recipe with an estimated reagent price sells", sale.values[3], 70)
    T.check("but is not offered for ranking (the price manager's record decides)", sale.rank[3] == nil)
    T.eq("the missing item counts as loading", sale.loading, 1)
    T.eq("and still does when asked later", SV:LoadingCount(sale), 1)
    clock = 119
    T.eq("still loading within twenty seconds", SV:Build(recipes, opts).loading, 1)
    T.eq("the earlier table agrees", SV:LoadingCount(sale), 1)
    clock = 121
    T.eq("no longer counted as loading after that", SV:Build(recipes, opts).loading, 0)
    T.eq("the earlier table says so too, without being rebuilt", SV:LoadingCount(sale), 0)
    T.eq("no table: nothing loading", SV:LoadingCount(nil), 0)
    T.eq("nothing is being waited for any more", SV:WaitingCount(), 0)
    clock = 100

    -- The data arrives after all: it was still being waited for.
    info[701] = 30
    T.check("an arrival for a waited item is reported", SV:OnItemInfo(701, true) == true)
    T.check("only once", SV:OnItemInfo(701, true) == false)
    T.eq("and its value is there", SV:Build(recipes, opts).values[1], 30)
    T.check("an unrelated item is not reported", SV:OnItemInfo(999, true) == false)

    -- A failed load ends the waiting for the session.
    local more = { recipe(4, 704) }
    clock = 200
    local waitingSale = SV:Build(more, opts)
    T.eq("a new missing item is loading", waitingSale.loading, 1)
    T.eq("one item is being waited for", SV:WaitingCount(), 1)
    T.check("its failed load is reported", SV:OnItemInfo(704, false) == true)
    T.eq("a table built before the failure stops counting it", SV:LoadingCount(waitingSale), 0)
    T.eq("and it stops counting as loading", SV:Build(more, opts).loading, 0)
    clock = 500
    T.eq("for good", SV:Build(more, opts).loading, 0)
end)

T.finish()
