-- scripts/test_prices.lua
--
-- Modules/Pricing: where each reagent price comes from. PriceManager records
-- the source of every price (vendor, TSM and which TSM value, Auctionator and
-- how many days ago it last saw the item, vendor sell estimate, no price yet),
-- summarizes a path's reagents (auction prices too old, reagents still without
-- a price) and dumps everything for /lp diag prices.
--
-- Run from the addon root:  lua5.1 scripts/test_prices.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

package.path = "./?.lua;" .. package.path

local failures, total = 0, 0
local function check(name, cond, detail)
    total = total + 1
    if cond then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
    end
end
local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then check(name .. " executed without error", false, err) end
end

string.trim = string.trim or function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- ===========================================================================
-- Stubs: TSM_API, Auctionator.API.v1, the client's item info, the clock.
-- ===========================================================================
local now = 1000
_G.time = function() return now end

-- TSM values by price source key, then item string.
local tsmValues
local function resetTsm()
    tsmValues = {
        DBRecent = { ["i:2589"] = 120, ["i:2770"] = 50 },
        DBMarket = { ["i:2589"] = 130, ["i:2592"] = 400 },
        DBMinBuyout = { ["i:5000"] = 1000 },
        vendorbuy = { ["i:2320"] = 10 },
    }
end
resetTsm()
local function installTsm()
    _G.TSM_API = {
        GetCustomPriceValue = function(source, itemString)
            return (tsmValues[source] or {})[itemString]
        end,
    }
end

local auctionatorPrices, auctionatorAges
local function resetAuctionator()
    auctionatorPrices = { [2589] = 125, [2592] = 900, [4306] = 300, [2770] = 45, [2320] = 15, [5000] = 800 }
    auctionatorAges = { [2589] = 1, [2592] = 1, [4306] = 5, [2770] = 0, [2320] = 0, [5000] = 0 }
end
resetAuctionator()
local function installAuctionator(withAge)
    local api = {
        GetAuctionPriceByItemID = function(caller, itemId)
            assert(caller == "LazyProf", "caller id")
            return auctionatorPrices[itemId]
        end,
        GetVendorPriceByItemID = function() return nil end,
    }
    if withAge then
        api.GetAuctionAgeByItemID = function(caller, itemId)
            assert(caller == "LazyProf", "caller id")
            return auctionatorAges[itemId]
        end
    end
    _G.Auctionator = { API = { v1 = api } }
end

local itemNames = { [2589] = "Linen Cloth", [2592] = "Wool Cloth", [2320] = "Coarse Thread",
                    [4306] = "Silk Cloth", [2996] = "Bolt of Linen Cloth", [8888] = "Unsellable Thing",
                    [2770] = "Copper Ore", [5000] = "Pattern: Test" }
local sellPrices = { [2589] = 13, [2592] = 33, [2320] = 2, [4306] = 150, [2996] = 40, [8888] = 0, [2770] = 5,
                     [5000] = 100 }

local function loadPricing(opts)
    opts = opts or {}
    _G.TSM_API = nil
    _G.Auctionator = nil
    if opts.tsm ~= false then installTsm() end
    if opts.auctionator ~= false then installAuctionator(opts.age ~= false) end
    local addon = {}
    function addon:Debug() end
    function addon:Print() end
    addon.db = {
        profile = {
            priceSourcePriority = opts.priority or { "tsm", "auctionator", "scanner" },
            tsmPriceSource = "DBRecent",
            useVendorSellFallback = opts.sellFallback ~= false,
        },
        char = {},
    }
    addon.Client = {
        GetItemInfo = function(_self, itemId)
            if opts.uncached and opts.uncached[itemId] then return nil end
            local name = itemNames[itemId]
            if not name then return nil end
            return name, nil, 1, 1, 1, "Trade Goods", "Cloth", 20, "", "icon", sellPrices[itemId]
        end,
    }
    assert(loadfile("Core/Constants.lua"))("LazyProf", addon)
    assert(loadfile("Core/Utils.lua"))("LazyProf", addon)
    for _, f in ipairs({ "TSM", "Auctionator", "Vendor", "VendorSell" }) do
        assert(loadfile("Modules/Pricing/Providers/" .. f .. ".lua"))("LazyProf", addon)
    end
    assert(loadfile("Modules/Pricing/PriceManager.lua"))("LazyProf", addon)
    assert(loadfile("Modules/Recipes/Availability.lua"))("LazyProf", addon)
    addon.PriceManager:Initialize()
    return addon
end

-- ===========================================================================
-- Market-only prices (what a crafted item sells for at auction)
-- ===========================================================================
section("market price", function()
    local p = "market price: "
    local addon = loadPricing()
    local pm = addon.PriceManager
    check(p .. "the first market source in the configured order", pm:MarketPrice(2589) == 120, pm:MarketPrice(2589))
    check(p .. "an item a vendor sells has no market price here (2320: vendor 10, auction 15)",
        pm:MarketPrice(2320) == nil, pm:MarketPrice(2320))
    check(p .. "no market data: nil, not the sell estimate", pm:MarketPrice(2996) == nil, pm:MarketPrice(2996))
    check(p .. "unknown item: nil, not the floor", pm:MarketPrice(424242) == nil)
    check(p .. "nothing is cached by it", pm.cache[2589] == nil and pm.cache[2996] == nil)

    -- Kept for as long as the reagent prices are: the sources are not asked
    -- again for every calculation.
    tsmValues.DBRecent["i:2589"] = 777
    check(p .. "a second lookup does not ask the sources again", pm:MarketPrice(2589) == 120, pm:MarketPrice(2589))
    check(p .. "an item without a market price is remembered as such", pm:MarketPrice(2996) == nil)
    now = now + 301
    check(p .. "after the cache time it is read again", pm:MarketPrice(2589) == 777, pm:MarketPrice(2589))
    now = 1000
    resetTsm()

    -- A fresh Auctionator price (seen today, auction house visited) wins,
    -- and leaving the auction house expires what was kept.
    check(p .. "before the visit: the configured order", pm:MarketPrice(2770) == 50, pm:MarketPrice(2770))
    pm:OnAuctionHouseVisited()
    check(p .. "a fresh scan wins over the configured order", pm:MarketPrice(2770) == 45, pm:MarketPrice(2770))

    -- It also says how old the price is, when its source knows (Auctionator).
    addon = loadPricing({ tsm = false })
    local price, age = addon.PriceManager:MarketPrice(4306)
    check(p .. "an Auctionator price comes with its age", age == 5, tostring(price) .. " " .. tostring(age))
    price, age = addon.PriceManager:MarketPrice(4306)
    check(p .. "and keeps it when cached", age == 5, tostring(age))
    addon = loadPricing()
    price, age = addon.PriceManager:MarketPrice(2589)
    check(p .. "a TSM price has no age", price == 120 and age == nil, tostring(price) .. " " .. tostring(age))

    addon = loadPricing({ tsm = false, auctionator = false })
    check(p .. "no auction addon: nil", addon.PriceManager:MarketPrice(2589) == nil)

    local real = addon.PriceManager.IsRealSource
    check(p .. "a vendor buy price is a real price", real({ source = "Vendor" }) == true)
    check(p .. "so are TSM and Auctionator prices", real({ source = "TSM" }) == true and real({ source = "Auctionator" }) == true)
    check(p .. "the sell estimate is not", real({ source = "VendorSell" }) == false)
    check(p .. "nor the floor or no price", real({ source = "floor" }) == false and real({ source = "none" }) == false)
    check(p .. "nor nothing", real(nil) == false)
end)

-- ===========================================================================
-- Where a price came from
-- ===========================================================================
section("provenance", function()
    local p = "provenance: "
    local addon = loadPricing()
    local pm = addon.PriceManager

    local info = pm:GetPriceInfo(2589)
    check(p .. "TSM price with the value that answered", info.price == 120 and info.source == "TSM"
        and info.detail == "DBRecent", info.source .. " " .. tostring(info.detail))
    check(p .. "GetPrice keeps its two returns", select(1, pm:GetPrice(2589)) == 120
        and select(2, pm:GetPrice(2589)) == "TSM")

    info = pm:GetPriceInfo(2592)
    check(p .. "TSM fallback value is named", info.price == 400 and info.detail == "DBMarket",
        tostring(info.detail))

    info = pm:GetPriceInfo(2320)
    check(p .. "vendor price names who recorded it", info.price == 10 and info.source == "Vendor"
        and info.detail == "TSM", tostring(info.detail))

    info = pm:GetPriceInfo(4306)
    check(p .. "Auctionator price carries its age in days", info.price == 300
        and info.source == "Auctionator" and info.ageDays == 5, tostring(info.ageDays))

    info = pm:GetPriceInfo(2996)
    check(p .. "no market price: vendor sell estimate", info.price == 40 and info.source == "VendorSell")

    check(p .. "read time recorded", info.timestamp == now)
    now = now + 10
    check(p .. "cached within the TTL", pm:GetPriceInfo(2996).timestamp == 1000)
    now = now + 400
    check(p .. "re-read after the TTL", pm:GetPriceInfo(2996).timestamp == now)
end)

section("no price yet", function()
    local p = "no price: "
    local addon = loadPricing({ uncached = { [7777] = true } })
    local pm = addon.PriceManager
    local info = pm:GetPriceInfo(7777)
    check(p .. "floor price, not cached", info.source == "floor" and info.price == addon.Constants.MIN_REAGENT_PRICE
        and pm.cache[7777] == nil)
    check(p .. "item data not loaded: still loading", info.detail == "loading", tostring(info.detail))
    check(p .. "remembered for refinement", pm.flooredItems[7777] == true)

    info = pm:GetPriceInfo(8888)
    check(p .. "loaded item without a sell value: unsellable", info.source == "floor"
        and info.detail == "unsellable", tostring(info.detail))

    addon = loadPricing({ sellFallback = false, uncached = { [7777] = true } })
    info = addon.PriceManager:GetPriceInfo(7777)
    check(p .. "without the sell fallback: none", info.source == "none" and info.price == nil)
end)

section("auctionator without the age call", function()
    local addon = loadPricing({ tsm = false, age = false })
    local info = addon.PriceManager:GetPriceInfo(4306)
    check("age: missing age call leaves the age unknown", info.source == "Auctionator"
        and info.price == 300 and info.ageDays == nil)
    addon = loadPricing({ tsm = false })
    auctionatorAges[4306] = nil
    info = addon.PriceManager:GetPriceInfo(4306)
    resetAuctionator()
    check("age: age call without data leaves the age unknown", info.source == "Auctionator"
        and info.price == 300 and info.ageDays == nil)
    check("age: undated price is not stale", addon.PriceManager:PathSummary(
        { steps = { { recipe = { reagents = { { itemId = 4306 } } } } } }).stale == 0)
end)

-- ===========================================================================
-- A price from an auction scan made today beats the configured order
-- ===========================================================================
section("fresh scan", function()
    local p = "fresh: "
    local addon = loadPricing()
    local pm = addon.PriceManager
    check(p .. "fresh age is 0 days", addon.Constants.AUCTION_FRESH_DAYS == 0,
        tostring(addon.Constants.AUCTION_FRESH_DAYS))

    local info = pm:GetPriceInfo(2770)
    check(p .. "no auction house visit this session: TSM first", info.source == "TSM" and info.price == 50,
        info.source .. " " .. tostring(info.price))
    pm:OnAuctionHouseVisited()
    info = pm:GetPriceInfo(2770)
    check(p .. "Auctionator seen today beats TSM", info.source == "Auctionator" and info.price == 45
        and info.ageDays == 0, info.source .. " " .. tostring(info.price))
    info = pm:GetPriceInfo(2589)
    check(p .. "Auctionator seen yesterday does not", info.source == "TSM" and info.price == 120,
        info.source .. " " .. tostring(info.price))
    info = pm:GetPriceInfo(2320)
    check(p .. "vendor price still comes first", info.source == "Vendor" and info.price == 10,
        info.source .. " " .. tostring(info.price))

    addon = loadPricing({ age = false })
    addon.PriceManager:OnAuctionHouseVisited()
    info = addon.PriceManager:GetPriceInfo(2770)
    check(p .. "without the age call the order holds", info.source == "TSM" and info.price == 50,
        info.source .. " " .. tostring(info.price))

    addon = loadPricing()
    addon.PriceManager:OnAuctionHouseVisited()
    auctionatorPrices[2770] = nil
    info = addon.PriceManager:GetPriceInfo(2770)
    resetAuctionator()
    check(p .. "an age without a price falls through to TSM", info.source == "TSM" and info.price == 50,
        info.source .. " " .. tostring(info.price))

    addon = loadPricing({ priority = { "auctionator", "tsm" } })
    info = addon.PriceManager:GetPriceInfo(2589)
    check(p .. "Auctionator first in the order: any age", info.source == "Auctionator" and info.price == 125,
        info.source .. " " .. tostring(info.price))

    -- Recipe items bought from the auction house follow the same rule.
    addon = loadPricing()
    local Av = addon.RecipeAvailability
    local price, source = Av:GetAHPrice(5000)
    check(p .. "recipe item: no visit this session: TSM first", price == 1000 and source == "TSM",
        tostring(price) .. " " .. tostring(source))
    addon.PriceManager:OnAuctionHouseVisited()
    price, source = Av:GetAHPrice(5000)
    check(p .. "recipe item: Auctionator today beats TSM min buyout", price == 800 and source == "Auctionator",
        tostring(price) .. " " .. tostring(source))
    auctionatorAges[5000] = 2
    price, source = Av:GetAHPrice(5000)
    check(p .. "recipe item: older Auctionator price does not", price == 1000 and source == "TSM",
        tostring(price) .. " " .. tostring(source))
    resetAuctionator()
    addon = loadPricing({ age = false })
    addon.PriceManager:OnAuctionHouseVisited()
    price, source = addon.RecipeAvailability:GetAHPrice(5000)
    check(p .. "recipe item: without the age call TSM first", price == 1000 and source == "TSM",
        tostring(price) .. " " .. tostring(source))
end)

section("auction house visit", function()
    local p = "visit: "
    local addon = loadPricing({ uncached = { [7777] = true } })
    local printed = 0
    function addon:Print() printed = printed + 1 end
    local pm = addon.PriceManager
    pm:GetPriceInfo(2589)
    pm:GetPriceInfo(7777)
    pm:OnAuctionHouseVisited()
    check(p .. "cached prices kept for readers of the last calculation", pm.cache[2589]
        and pm.cache[2589].price == 120, pm.cache[2589] and pm.cache[2589].price)
    check(p .. "items waiting for item data stay tracked", pm.flooredItems[7777] == true)
    check(p .. "nothing printed", printed == 0, printed)
    tsmValues.DBRecent["i:2589"] = 999
    local info = pm:GetPriceInfo(2589)
    resetTsm()
    check(p .. "next lookup re-reads the sources", info.price == 999, info.price)
end)

-- ===========================================================================
-- Text for one price
-- ===========================================================================
section("describe", function()
    local p = "describe: "
    local addon = loadPricing()
    local D = addon.PriceManager.DescribeSource
    check(p .. "TSM", D({ source = "TSM", detail = "DBRecent" }) == "TSM DBRecent")
    check(p .. "vendor", D({ source = "Vendor", detail = "Auctionator" }) == "vendor price (recorded by Auctionator)")
    check(p .. "Auctionator today", D({ source = "Auctionator", ageDays = 0 }) == "Auctionator, seen today")
    check(p .. "Auctionator 1 day", D({ source = "Auctionator", ageDays = 1 }) == "Auctionator, seen 1 day ago")
    check(p .. "Auctionator 4 days", D({ source = "Auctionator", ageDays = 4 }) == "Auctionator, seen 4 days ago")
    check(p .. "Auctionator undated", D({ source = "Auctionator" }) == "Auctionator")
    check(p .. "estimate", D({ source = "VendorSell" }) == "estimate from the vendor sell value")
    check(p .. "floor, loading", D({ source = "floor", detail = "loading" }) == "no price yet (item data still loading)")
    check(p .. "floor, unsellable",
        D({ source = "floor", detail = "unsellable" }) == "no price (no auction price, no vendor sell value)")
    check(p .. "none", D({ source = "none" }) == "no price (no auction price, vendor sell estimate off)")

    local L = addon.PriceManager.PriceLine
    check(p .. "price line", L({ price = 120, source = "TSM", detail = "DBRecent" }) == "Price: 1s 20c each, TSM DBRecent",
        L({ price = 120, source = "TSM", detail = "DBRecent" }))
    check(p .. "price line without a real price",
        L({ price = 1, source = "floor", detail = "loading" }) == "Price: no price yet (item data still loading)")
    check(p .. "price line, none", L({ source = "none" }) == "Price: no price (no auction price, vendor sell estimate off)")
end)

-- ===========================================================================
-- A path's reagents: counts by source, too-old auction prices, missing prices
-- ===========================================================================
-- Step 1 uses the first two reagents, step 2 all of them (so ids repeat).
local function pathWith(...)
    local reagents = {}
    for _, id in ipairs({ ... }) do reagents[#reagents + 1] = { itemId = id, count = 1 } end
    return { steps = {
        { recipe = { id = 1, reagents = { reagents[1], reagents[2] } } },
        { recipe = { id = 2, reagents = reagents } },
    } }
end

section("summary", function()
    local p = "summary: "
    local addon = loadPricing({ uncached = { [7777] = true } })
    local pm = addon.PriceManager
    local path = pathWith(2589, 2592, 2320, 4306, 2996, 7777, 8888)
    local ids = pm:PathReagentIds(path)
    check(p .. "unique reagent ids", #ids == 7, #ids)
    local s = pm:PathSummary(path)
    check(p .. "counts", s.total == 7 and s.tsm == 2 and s.vendor == 1 and s.auctionator == 1
        and s.estimate == 1 and s.loading == 1 and s.unpriced == 1,
        string.format("%d %d %d %d %d %d %d", s.total, s.tsm, s.vendor, s.auctionator, s.estimate, s.loading, s.unpriced))
    check(p .. "5-day-old Auctionator price is stale", s.stale == 1 and s.oldestAuctionatorDays == 5)

    -- Reports read the prices the calculation used, even past the cache TTL.
    local readAt = pm.cache[2589].timestamp
    tsmValues.DBRecent["i:2589"] = 999
    now = now + 10000
    s = pm:PathSummary(path)
    check(p .. "past the TTL the cached price is reported, not re-read",
        pm.cache[2589].timestamp == readAt and pm.cache[2589].price == 120)
    resetTsm()

    auctionatorAges[4306] = addon.Constants.PRICE_STALE_DAYS - 1
    pm.cache = {}
    s = pm:PathSummary(path)
    check(p .. "younger than the threshold is fresh", s.stale == 0)
    auctionatorAges[4306] = addon.Constants.PRICE_STALE_DAYS
    pm.cache = {}
    s = pm:PathSummary(path)
    check(p .. "at the threshold is stale", s.stale == 1)
    resetAuctionator()

    check(p .. "empty path", pm:PathSummary({ steps = {} }).total == 0 and pm:PathSummary(nil).total == 0)

    addon = loadPricing({ sellFallback = false, uncached = { [7777] = true } })
    s = addon.PriceManager:PathSummary(pathWith(2589, 7777))
    check(p .. "sell estimate off: no price counts as unpriced", s.unpriced == 1 and s.loading == 0)
end)

section("warnings", function()
    local p = "warnings: "
    local addon = loadPricing()
    local W = addon.PriceManager.SummaryLines
    local function texts(s)
        local out = {}
        for _, l in ipairs(W(s)) do out[#out + 1] = l.text end
        return table.concat(out, " | ")
    end
    local clean = { total = 5, tsm = 3, auctionator = 1, vendor = 1, estimate = 0, loading = 0, unpriced = 0, stale = 0 }
    local t = texts(clean)
    check(p .. "breakdown line", t == "Prices: TSM 3, Auctionator 1, vendor 1", t)

    local estimateOnly = { total = 4, tsm = 0, auctionator = 0, vendor = 0, estimate = 4, loading = 0, unpriced = 0,
                           stale = 0 }
    t = texts(estimateOnly)
    check(p .. "estimates only: noted, no diagnostic hint",
        t == "Prices: estimate 4 | 4 reagents have no auction price - cost uses the vendor sell value.", t)

    local bad = { total = 11, tsm = 3, auctionator = 2, vendor = 1, estimate = 2, loading = 1, unpriced = 2, stale = 2,
                  oldestAuctionatorDays = 6 }
    t = texts(bad)
    check(p .. "breakdown counts both kinds of none", t:find("estimate 2, none 3", 1, true) ~= nil, t)
    check(p .. "no price yet", t:find("1 reagent has no price yet - it updates by itself", 1, true) ~= nil, t)
    check(p .. "no price at all", t:find("2 reagents have no price at all - scan the auction house (needs TSM or Auctionator).", 1, true) ~= nil, t)
    check(p .. "stale auction prices", t:find("Auctionator prices up to 6 days old - rescan the auction house", 1, true) ~= nil, t)
    check(p .. "estimates", t:find("2 reagents have no auction price - cost uses the vendor sell value", 1, true) ~= nil, t)
    check(p .. "points at the diagnostic", t:find("/lp diag prices", 1, true) ~= nil, t)
    check(p .. "plain ASCII", not t:find("[\128-\255]"))
    check(p .. "nothing for no reagents", #W({ total = 0, tsm = 0, auctionator = 0, vendor = 0, estimate = 0,
        loading = 0, unpriced = 0, stale = 0 }) == 0)

    -- The lines that say something is wrong are marked, so the window can
    -- pick the first of them (the breakdown, the estimate note and the
    -- diagnostic hint are not problems).
    local function problems(s)
        local out = {}
        for _, l in ipairs(W(s)) do
            if l.problem then out[#out + 1] = l.text:match("^%d* ?%a+ %a+ %a+") or l.text end
        end
        return table.concat(out, " | ")
    end
    t = problems(bad)
    check(p .. "problem lines are marked, in order",
        t == "1 reagent has no | 2 reagents have no | Auctionator prices up", t)
    local marked = 0
    for _, l in ipairs(W(bad)) do
        if l.problem then
            marked = marked + 1
            check(p .. "a marked line is orange", l.r == 1 and l.g == 0.5 and l.b == 0, l.text)
        end
    end
    check(p .. "three problem lines of six", marked == 3 and #W(bad) == 6, marked)
    check(p .. "no problem when all prices are real", problems(clean) == "")
    check(p .. "an estimate is not a problem", problems(estimateOnly) == "")
end)

-- ===========================================================================
-- /lp diag prices
-- ===========================================================================
section("diagnostic", function()
    local p = "diag: "
    local addon = loadPricing({ uncached = { [7777] = true } })
    addon.Pathfinder = { currentPath = pathWith(2589, 2592, 2320, 4306, 2996, 7777) }
    local pm = addon.PriceManager
    local lines = {}
    local ok, err = pcall(pm.RunDiagnostic, pm, lines)
    check(p .. "no Lua error", ok, err)
    local text = table.concat(lines, "\n")
    print(text)
    check(p .. "providers line", text:find("tsm=true auctionator=true auctionatorAge=true", 1, true) ~= nil, text)
    check(p .. "TSM sync note", text:find("TSM does not tell other addons when its data was synced", 1, true) ~= nil)
    check(p .. "summary line",
        text:find("reagents=6 tsm=2 auctionator=1 vendor=1 estimate=1 loading=1 noPrice=0 stale=1", 1, true) ~= nil, text)
    check(p .. "item line names item, price and source",
        text:find("2589 Linen Cloth: 1s 20c TSM DBRecent", 1, true) ~= nil, text)
    check(p .. "item line shows every source's value",
        text:find("tsm=1s 20c (DBRecent) auctionator=1s 25c (1d) vendor=- sell=13c", 1, true) ~= nil, text)
    check(p .. "sources that disagree are flagged",
        text:find("2592 Wool Cloth:[^\n]*DISAGREE") ~= nil, text)
    check(p .. "agreeing sources are not flagged", text:find("2589 Linen Cloth:[^\n]*DISAGREE") == nil, text)
    check(p .. "stale price flagged", text:find("4306 Silk Cloth:[^\n]*STALE") ~= nil, text)
    check(p .. "uncached item named by id", text:find("7777 item:7777: ", 1, true) ~= nil, text)
    check(p .. "plain ASCII", not text:find("[\128-\255]"))
    check(p .. "a path without route data prints no route line", text:find("route:", 1, true) == nil, text)

    -- Which candidate route was kept, each candidate's amounts, the time it
    -- took, and how the sale values stand.
    local routed = pathWith(2589, 2592)
    routed.route = { kept = "stock", ms = 12.4, keepMargin = 6500, candidates = {
        { key = "market", net = 123456, spend = 130000, sale = 6544, gapLength = 0, eligible = true },
        { key = "sale", net = 150000, spend = 160000, sale = 10000, gapLength = 6, eligible = false },
        { key = "stock", net = -250, spend = 9750, sale = 10000, gapLength = 0, eligible = true },
    } }
    routed.sale = { mode = "vendor", values = { [1] = 5, [2] = 6, [3] = 7 }, rank = { [1] = 5 }, loading = 2,
                    loadingItems = { 901, 902 } }
    addon.SaleValue = { LoadingCount = function(_, sale) return #sale.loadingItems - 1 end }
    addon.Pathfinder.currentPath = routed
    lines = {}
    ok, err = pcall(pm.RunDiagnostic, pm, lines)
    text = table.concat(lines, "\n")
    check(p .. "route: no Lua error", ok, err)
    check(p .. "route: which candidate was kept and how long planning took",
        text:find("route: kept=stock candidates=3 planned in 12 ms", 1, true) ~= nil, text)
    check(p .. "route: the margin the plan in hand is given", text:find("keep margin=65s", 1, true) ~= nil, text)
    check(p .. "route: a candidate's amounts",
        text:find("candidate market: net=12g 34s 56c spend=13g sale=65s 44c", 1, true) ~= nil, text)
    check(p .. "route: a candidate that covers less says so",
        text:find("candidate sale: net=15g spend=16g sale=1g (not eligible: leaves 6 more skill points uncovered)", 1, true) ~= nil, text)
    check(p .. "route: a net gain is printed as a gain",
        text:find("candidate stock: net=gain 2s 50c spend=97s 50c sale=1g", 1, true) ~= nil, text)
    check(p .. "sale values: mode and counts",
        text:find("sale values: mode=vendor counted=3 ranked=1 loading=1", 1, true) ~= nil, text)
    check(p .. "route: plain ASCII", not text:find("[\128-\255]"))
    addon.SaleValue = nil

    addon.Pathfinder.currentPath = nil
    lines = {}
    ok, err = pcall(pm.RunDiagnostic, pm, lines)
    text = table.concat(lines, "\n")
    check(p .. "no path: says so", ok and text:find("no path yet", 1, true) ~= nil, text)

    addon = loadPricing({ tsm = false, auctionator = false })
    addon.Pathfinder = { currentPath = pathWith(2589, 2592, 2320, 4306, 2996, 7777) }
    lines = {}
    ok, err = pcall(addon.PriceManager.RunDiagnostic, addon.PriceManager, lines)
    text = table.concat(lines, "\n")
    check(p .. "no auction addons: no error", ok, err)
    check(p .. "no auction addons: providers false", text:find("tsm=false auctionator=false", 1, true) ~= nil, text)
    check(p .. "no auction addons: values n/a", text:find("tsm=n/a auctionator=n/a", 1, true) ~= nil, text)

    -- A price source that errors: that item's line fails, the rest still prints.
    addon = loadPricing()
    addon.Pathfinder = { currentPath = pathWith(2589, 2592) }
    _G.TSM_API.GetCustomPriceValue = function(_source, itemString)
        if itemString == "i:2592" then error("boom") end
        return 120
    end
    lines = {}
    ok, err = pcall(addon.PriceManager.RunDiagnostic, addon.PriceManager, lines)
    text = table.concat(lines, "\n")
    check(p .. "erroring source: no Lua error", ok, err)
    check(p .. "erroring source: section error and the other item",
        text:find("SECTION ERROR", 1, true) ~= nil and text:find("2589 Linen Cloth:", 1, true) ~= nil, text)
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
