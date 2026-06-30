-- scripts/test_selffound.lua
--
-- Standalone Lua 5.1 unit test for Modules/Recipes/SelfFound.lua: self-found
-- reagent/recipe obtainability (owned / vendor / gathered raw / craftable by a
-- profession you have) and the MarkRecipe candidate decision.
--
-- Run from the addon root:  lua5.1 scripts/test_selffound.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Stubs (configurable per scenario)
-- ---------------------------------------------------------------------------
local addon = {}
addon.db = { char = { learnedRecipes = {} }, profile = {} }
addon.Professions = { active = nil }
addon.Inventory = { ScanAll = function() return {} end }
addon.RecipeAvailability = { MeetsTrainerRequirements = function() return true end }

local vendorPrices = {}   -- itemId -> per-unit copper
local products = {}       -- itemId -> { {professionKey=...}, ... }
local profNames = {
    alchemy = "Alchemy", mining = "Mining",
    leatherworking = "Leatherworking", enchanting = "Enchanting",
}
_G.CraftLib = {
    GetVendorBuyPrice = function(_self, itemId) return vendorPrices[itemId] end,
    GetRecipeByProduct = function(_self, itemId) return products[itemId] end,
    GetProfession = function(_self, key)
        local n = profNames[key]; return n and { name = n } or nil
    end,
}

local knownSpells = {}
_G.IsSpellKnown = function(id) return knownSpells[id] == true end

-- ---------------------------------------------------------------------------
-- Load the real module
-- ---------------------------------------------------------------------------
assert(loadfile("Modules/Recipes/SelfFound.lua"))("LazyProf", addon)
local SelfFound = addon.SelfFound
assert(SelfFound, "SelfFound.lua did not create LazyProf.SelfFound")

-- Readable item ids
local OWNED, VENDOR_VIAL, RAW_LEATHER = 1001, 1002, 1003
local ELIXIR, BRONZE_BAR, CURED_LEATHER = 2001, 2002, 2003

local function reset()
    vendorPrices = { [VENDOR_VIAL] = 5 }
    products = {
        [ELIXIR]        = { { professionKey = "alchemy" } },
        [BRONZE_BAR]    = { { professionKey = "mining" } },
        [CURED_LEATHER] = { { professionKey = "leatherworking" } },
    }
    knownSpells = {}
    addon.db.char.learnedRecipes = {}
    addon.db.profile = { suggestUnlearnedRecipes = true }
    addon.db.char.selfFoundMode = true
    addon.Professions.active = "leatherworking"
end

-- ===========================================================================
-- Scenario 1: reagent classification (LW active; no Mining, no Alchemy)
-- ===========================================================================
reset()
SelfFound:BeginRecalc({ [OWNED] = 3 })
check("owned reagent -> obtainable", SelfFound:IsReagentObtainable(OWNED) == true)
check("vendor reagent -> obtainable", SelfFound:IsReagentObtainable(VENDOR_VIAL) == true)
check("raw (no producer) -> obtainable", SelfFound:IsReagentObtainable(RAW_LEATHER) == true)
do
    local ok, reason = SelfFound:IsReagentObtainable(ELIXIR)
    check("alchemy product, no Alchemy -> blocked", ok == false)
    check("alchemy block names the profession", reason == "Needs Alchemy", reason)
end
check("bar, no Mining -> blocked", (SelfFound:IsReagentObtainable(BRONZE_BAR)) == false)
check("LW product while LW active -> obtainable", SelfFound:IsReagentObtainable(CURED_LEATHER) == true)
SelfFound:EndRecalc()

-- ===========================================================================
-- Scenario 2: Mining via the smelting IsSpellKnown fallback (spell 2575)
-- ===========================================================================
reset()
knownSpells[2575] = true
SelfFound:BeginRecalc({})
check("bar obtainable when smelting spell known", SelfFound:IsReagentObtainable(BRONZE_BAR) == true)
SelfFound:EndRecalc()

-- ===========================================================================
-- Scenario 3: Mining via the learnedRecipes cache
-- ===========================================================================
reset()
addon.db.char.learnedRecipes = { mining = { [2659] = true } }
SelfFound:BeginRecalc({})
check("bar obtainable when mining in learnedRecipes", SelfFound:IsReagentObtainable(BRONZE_BAR) == true)
SelfFound:EndRecalc()

-- ===========================================================================
-- Scenario 4: Alchemy known -> elixir obtainable
-- ===========================================================================
reset()
addon.db.char.learnedRecipes = { alchemy = { [123] = true } }
SelfFound:BeginRecalc({})
check("elixir obtainable when Alchemy known", SelfFound:IsReagentObtainable(ELIXIR) == true)
SelfFound:EndRecalc()

-- ===========================================================================
-- Scenario 5: whole-recipe obtainability + reason formatting + learned check
-- ===========================================================================
reset()
SelfFound:BeginRecalc({})
local function recipe(id, learned, srcType, reagentSpec)
    local reagents = {}
    for i, r in ipairs(reagentSpec) do
        reagents[i] = { itemId = r.id, count = 1, name = r.name }
    end
    return {
        id = id, name = "R" .. id, learned = learned,
        source = srcType and { type = srcType } or nil,
        reagents = reagents,
    }
end
do
    local ok, reason, si = SelfFound:IsRecipeObtainable(
        recipe(9001, false, "drop", { { id = RAW_LEATHER, name = "Light Leather" }, { id = VENDOR_VIAL, name = "Crystal Vial" } }))
    check("recipe with obtainable reagents -> obtainable", ok == true, reason)
    check("obtainable recipe returns sourceInfo from real source", si ~= nil and si.type == "drop")

    local ok2, reason2 = SelfFound:IsRecipeObtainable(
        recipe(9002, false, "trainer", { { id = RAW_LEATHER, name = "Light Leather" }, { id = ELIXIR, name = "Elixir of Minor Agility" } }))
    check("recipe needing an elixir -> blocked", ok2 == false)
    check("block reason names profession + reagent",
        reason2 == "Needs Alchemy: Elixir of Minor Agility", reason2)

    local ok3 = SelfFound:IsRecipeObtainable(
        recipe(9003, true, nil, { { id = ELIXIR, name = "Elixir of Minor Agility" } }))
    check("learned recipe with unobtainable reagent -> blocked", ok3 == false)

    local ok4 = SelfFound:IsRecipeObtainable(
        recipe(9004, false, nil, { { id = RAW_LEATHER, name = "Light Leather" } }))
    check("unlearned recipe with no source -> blocked", ok4 == false)
end
SelfFound:EndRecalc()

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
