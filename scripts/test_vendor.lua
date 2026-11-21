-- scripts/test_vendor.lua
--
-- Vendor prices: what LazyProf remembers from merchant windows, and the order
-- in which the vendor price provider asks its sources.
--
-- Run from the addon root:  lua5.1 scripts/test_vendor.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })
_G.time = function() return 1000 end
local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Modules/Shopping/VendorMemory.lua",
    "Modules/Pricing/Providers/Vendor.lua",
    "Modules/Pricing/PriceManager.lua",
    "Modules/Recipes/SelfFound.lua",
})
local Memory, Vendor, PM = LazyProf.VendorMemory, LazyProf.PriceProviders.vendor, LazyProf.PriceManager
LazyProf.db.global = { characters = {} }
LazyProf.db.profile.priceSourcePriority = {}
LazyProf.Client = { GetItemInfo = function() return nil end }
PM:Initialize()

local THREAD, DYE, SALT, INK, SWORD, VIAL = 1, 2, 3, 4, 5, 6
LazyProf.Professions = { GetAllReagentIds = function() return { THREAD, DYE, SALT, INK, VIAL } end }

local function item(itemId, price, extra)
    local i = { index = itemId, itemId = itemId, price = price, bundle = 1, stock = -1, maxStack = 20, extendedCost = false }
    for k, v in pairs(extra or {}) do i[k] = v end
    return i
end

T.section("memory", function()
    T.check("defaults declare the store", type(LazyProf.defaults.global.vendorPrices) == "table")
    T.check("nothing known at first", Memory:Get(THREAD) == nil and Memory:Count() == 0)
    local changed = Memory:Record({
        item(THREAD, 100),
        item(DYE, 350),
        item(SALT, 500, { stock = 3 }),              -- limited stock
        item(INK, 0, { extendedCost = true }),       -- not sold for gold
        item(SWORD, 5000),                           -- not a reagent
        item(VIAL, 100, { bundle = 5 }),             -- sold five at a time
    })
    T.eq("unlimited gold-priced reagents are remembered", Memory:Get(THREAD), 100)
    T.eq("another one", Memory:Get(DYE), 350)
    T.eq("a bundle is remembered per item", Memory:Get(VIAL), 20)
    T.check("limited stock is not remembered", Memory:Get(SALT) == nil)
    T.check("an item not sold for gold is not remembered", Memory:Get(INK) == nil)
    T.check("an item that is no reagent is not remembered", Memory:Get(SWORD) == nil)
    table.sort(changed)
    T.eq("the changed ids are reported", table.concat(changed, ","), "1,2,6")
    T.check("stored account-wide by item id", LazyProf.db.global.vendorPrices[THREAD] == 100)
    T.eq("count", Memory:Count(), 3)

    T.eq("seeing the same price again changes nothing", #Memory:Record({ item(THREAD, 100) }), 0)
    changed = Memory:Record({ item(THREAD, 120) })
    T.check("a new price replaces the old one", Memory:Get(THREAD) == 120 and changed[1] == THREAD)
    T.eq("a sold-out item (stock 0) is not remembered", #Memory:Record({ item(SALT, 500, { stock = 0 }) }), 0)
    T.eq("an unknown stock value is not remembered", #Memory:Record({ item(SALT, 500, { stock = false }) }), 0)
    T.eq("an empty list is fine", #Memory:Record({}), 0)
    T.eq("no list is fine", #Memory:Record(nil), 0)

    local saved = LazyProf.db.global
    LazyProf.db.global = nil
    T.check("no database yet: nothing breaks", #Memory:Record({ item(THREAD, 100) }) == 0 and Memory:Get(THREAD) == nil)
    LazyProf.db.global = saved
end)

T.section("provider order", function()
    T.check("the vendor provider is always available", Vendor:IsAvailable() == true)
    local price, detail = Vendor:GetPrice(THREAD)
    T.check("no price addon: the remembered price", price == 120 and detail == "seen", tostring(price) .. " " .. tostring(detail))
    T.check("nothing known: nil", Vendor:GetPrice(SALT) == nil)

    _G.CraftLib = { GetVendorBuyPrice = function(_, itemId) return itemId == SALT and 480 or (itemId == THREAD and 90 or nil) end }
    price, detail = Vendor:GetPrice(SALT)
    T.check("the shipped list answers when nothing was seen", price == 480 and detail == "list")
    price, detail = Vendor:GetPrice(THREAD)
    T.check("a remembered price comes before the shipped list", price == 120 and detail == "seen")

    _G.Auctionator = { API = { v1 = { GetVendorPriceByItemID = function(_, itemId) return itemId == THREAD and 110 or nil end } } }
    price, detail = Vendor:GetPrice(THREAD)
    T.check("Auctionator's merchant data comes before the memory", price == 110 and detail == "Auctionator")
    _G.TSM_API = { GetCustomPriceValue = function(source, key) return (source == "vendorbuy" and key == "i:1") and 105 or nil end }
    price, detail = Vendor:GetPrice(THREAD)
    T.check("TSM's merchant data comes first", price == 105 and detail == "TSM")
    _G.TSM_API, _G.Auctionator = nil, nil

    -- Through the price manager every one of them is a vendor price.
    local info = PM:GetPriceInfo(THREAD)
    T.check("remembered price is reported as a vendor price", info.source == "Vendor" and info.price == 120 and info.detail == "seen")
    info = PM:GetPriceInfo(SALT)
    T.check("listed price is reported as a vendor price", info.source == "Vendor" and info.detail == "list")
    T.eq("source text: seen", PM.DescribeSource({ source = "Vendor", detail = "seen" }), "vendor price (seen at a vendor)")
    T.eq("source text: list", PM.DescribeSource({ source = "Vendor", detail = "list" }), "vendor price (known vendor item)")
    T.eq("source text: addon", PM.DescribeSource({ source = "Vendor", detail = "TSM" }), "vendor price (recorded by TSM)")
    _G.CraftLib = nil
end)

T.section("self-found", function()
    local SF = LazyProf.SelfFound
    _G.CraftLib = { GetVendorBuyPrice = function() return nil end,
        GetRecipeByProduct = function(_, itemId)
            if itemId == THREAD or itemId == INK then return { { professionKey = "tailoring" } } end
        end }
    SF:BeginRecalc({})
    T.check("a reagent seen at a vendor counts as obtainable without the auction house", SF:IsReagentObtainable(THREAD) == true)
    T.check("one never seen, made only by a profession the character lacks, does not", SF:IsReagentObtainable(INK) == false)
    SF:EndRecalc()
    _G.CraftLib = nil
end)

T.finish()
