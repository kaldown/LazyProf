-- scripts/test_sources.lua
--
-- Currency-only and unknown-source recipes: never free, never silently
-- available. Run from the addon root:  lua5.1 scripts/test_sources.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")

local FILES = {
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Client/Family.lua",
    "Core/Client/Classic.lua",
    "Core/Config.lua",
    "Modules/Recipes/Availability.lua",
    "Modules/Recipes/SelfFound.lua",
    "Modules/Pathfinder/StrategyCore.lua",
    "Modules/Pathfinder/Strategies/Cheapest.lua",
    "Modules/Pathfinder/Strategies/Fastest.lua",
}

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf(FILES)
local Utils = LazyProf.Utils
local Avail = LazyProf.RecipeAvailability

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

local CUR = { name = "Merchant's Favor", amount = 45 }
local function recipe(id, source, learned)
    return {
        id = id, name = "R" .. id, learned = learned or false, source = source,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 20, green = 30, gray = 40 },
        reagents = { { itemId = 100 + id, count = 1, name = "Mat" } },
    }
end

local ahPrices = {}
Avail.GetAHPrice = function(_, itemId) return ahPrices[itemId], ahPrices[itemId] and "TSM" or nil end

check("default includeCurrencyRecipes is false", LazyProf.db.profile.includeCurrencyRecipes == false,
    tostring(LazyProf.db.profile.includeCurrencyRecipes))

section("availability: currency", function()
    for _, stype in ipairs({ "vendor", "reputation" }) do
        local r = recipe(1, { type = stype, currency = CUR, itemId = 900 })
        LazyProf.db.profile.includeCurrencyRecipes = false
        local ok = Avail:IsRecipeAvailableUncached(r)
        check(stype .. " currency, option off: unavailable", ok == false, tostring(ok))
        LazyProf.db.profile.includeCurrencyRecipes = true
        local ok2, info = Avail:IsRecipeAvailableUncached(r)
        check(stype .. " currency, option on: available", ok2 == true)
        check(stype .. " currency, option on: cost 0", info and info.cost == 0, info and info.cost)
        check(stype .. " currency, option on: currency carried",
            info and info.currency == CUR and info.itemId == 900 and info.type == "vendor")
        LazyProf.db.profile.includeCurrencyRecipes = false
        local ok3, info3 = Avail:IsRecipeAvailableUncached(recipe(1, { type = stype, currency = CUR }, true))
        check(stype .. " currency learned: available", ok3 == true and info3.type == "learned")
    end
    -- A normal gold vendor recipe is untouched.
    local ok, info = Avail:IsRecipeAvailableUncached(recipe(2, { type = "vendor", cost = 500 }))
    check("gold vendor unchanged", ok and info.cost == 500 and info.currency == nil)
end)

section("availability: unknown", function()
    local r = recipe(3, { type = "unknown", itemId = 901 })
    ahPrices = {}
    local ok = Avail:IsRecipeAvailableUncached(r)
    check("unknown, no AH price: unavailable", ok == false)
    ahPrices = { [901] = 777 }
    local ok2, info = Avail:IsRecipeAvailableUncached(r)
    check("unknown, AH price: available as ah", ok2 and info.type == "ah" and info.price == 777)
    ahPrices = {}
    local ok3 = Avail:IsRecipeAvailableUncached(recipe(3, { type = "unknown", itemId = 901 }, true))
    check("unknown learned: available", ok3 == true)
end)

section("self-found does not free currency recipes", function()
    local r = recipe(4, { type = "vendor", currency = CUR })
    LazyProf.db.profile.includeCurrencyRecipes = false
    local ok = LazyProf.SelfFound:IsRecipeObtainableUncached(r)
    check("self-found currency option off: not obtainable", ok == false)
    LazyProf.db.profile.includeCurrencyRecipes = true
    local ok2, _, info = LazyProf.SelfFound:IsRecipeObtainableUncached(r)
    check("self-found currency option on: obtainable, currency carried",
        ok2 == true and info and info.currency == CUR and (info.cost or 0) == 0)
    LazyProf.db.profile.includeCurrencyRecipes = false
end)

section("strategy run", function()
    local PRICES = { [101] = 100, [105] = 100 }
    local learned = recipe(5, { type = "trainer" }, true)
    learned.skillRange = { orange = 1, yellow = 5, green = 8, gray = 10 }
    learned.reagents = { { itemId = 105, count = 1, name = "M" } }
    local cur = recipe(1, { type = "vendor", currency = CUR, itemId = 900 })
    cur.skillRange = { orange = 1, yellow = 30, green = 50, gray = 70 }
    for _, name in ipairs({ "cheapest", "fastest" }) do
        for _, opt in ipairs({ false, true }) do
            LazyProf.db.profile.includeCurrencyRecipes = opt
            LazyProf.db.profile.suggestUnlearnedRecipes = true
            Avail:BeginRecalc(); LazyProf.SelfFound:BeginRecalc({})
            local steps = LazyProf.PathfinderStrategies[name]:Calculate(
                1, 40, Utils.DeepCopy({ learned, cur }), {}, PRICES, 0, {})
            LazyProf.SelfFound:EndRecalc(); Avail:EndRecalc()
            local used, info = false, nil
            for _, s in ipairs(steps) do
                if s.recipe.id == 1 then used = true; info = s.recipe._sourceInfo end
            end
            if opt then
                check(name .. " option on: currency recipe used, cost 0, currency carried",
                    used and info and info.cost == 0 and info.currency ~= nil, tostring(used))
            else
                check(name .. " option off: currency recipe never appears", used == false)
            end
        end
    end
    LazyProf.db.profile.includeCurrencyRecipes = false
end)

section("descriptions", function()
    check("unknown description", Utils.GetSourceDescription({ type = "unknown" }) == "Unknown source",
        Utils.GetSourceDescription({ type = "unknown" }))
    check("vendor currency description",
        Utils.GetSourceDescription({ type = "vendor", currency = CUR }) == "Vendor: 45 Merchant's Favor",
        Utils.GetSourceDescription({ type = "vendor", currency = CUR }))
    check("currency text helper", Utils.FormatCurrency and Utils.FormatCurrency(CUR) == "45 Merchant's Favor")
    local d = Utils.GetSourceDetails({ type = "vendor", currency = CUR, vendors = {} })
    check("details carry currency", d and d.currency == CUR)
    local d2 = Utils.GetSourceDetails({ type = "unknown" })
    check("details unknown type", d2 and d2.type == "unknown")
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
