-- scripts/test_specialization.lua
--
-- Recipes that need a profession specialization (ruling P121): the planner
-- leaves out every unlearned recipe whose specialization the character does
-- not know (all of them when it knows none, and those whose requirement is
-- unknown), wherever recipes are chosen: candidates of both strategies, pins,
-- remembered routes, the availability answer, craft-or-buy. A learned recipe
-- stays usable. /lp diag spec reports it.
--
-- Run from the addon root:  lua5.1 scripts/test_specialization.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()
local check, eq = T.check, T.eq

local FILES = {
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Client/Family.lua",
    "Core/Client/Classic.lua",
    "Core/Config.lua",
    "Modules/Recipes/Availability.lua",
    "Modules/Recipes/SelfFound.lua",
    "Modules/Pathfinder/Pins.lua",
    "Modules/Pathfinder/StrategyCore.lua",
    "Modules/Pathfinder/Strategies/Cheapest.lua",
    "Modules/Pathfinder/Strategies/Fastest.lua",
    "Modules/Pathfinder/MaterialResolver.lua",
    "Professions/Registry.lua",
}

local DRAGON, ELEMENTAL, TRIBAL = 10656, 10658, 10660
local SPEC = {
    [DRAGON] = { spellId = DRAGON, name = "Dragonscale Leatherworking" },
    [ELEMENTAL] = { spellId = ELEMENTAL, name = "Elemental Leatherworking" },
    [TRIBAL] = { spellId = TRIBAL, name = "Tribal Leatherworking" },
}

-- Forever data (the camelot project id makes CraftLib load the FOREVER bucket);
-- the Forever adapter is not loaded here, so each test installs a stub.
local CraftLib = harness.loadCraftLib(16001, { camelot = true })
local LazyProf = harness.loadLazyProf(FILES)
local known = {}
local function stubClient()
    LazyProf.Client = {
        KnowsSpell = function(_, id) return known[id] == true end,
        PlayerSkill = function() return 300 end,
        ItemTooltipText = function() return nil, "not read on this client" end,
    }
end
stubClient()

local A = LazyProf.RecipeAvailability
local bags = {}
LazyProf.Inventory = { ScanAll = function()
    local combined, breakdown = {}, {}
    for itemId, n in pairs(bags) do
        combined[itemId] = n
        breakdown[itemId] = { bags = n }
    end
    return combined, breakdown
end }

-- One recipe orange at 1-50; its pattern (7000 + id) sold by a vendor unless
-- the source says otherwise.
local function recipe(id, spec, opts)
    opts = opts or {}
    return {
        id = id, name = "Recipe " .. id, itemId = 5000 + id, skillRequired = 1,
        skillRange = { orange = 1, yellow = 50, green = 75, gray = 100 },
        reagents = { { itemId = 9000 + id, name = "Reagent " .. id, count = 1 } },
        source = opts.source or { type = "vendor", itemId = 7000 + id, cost = 100 },
        specialization = spec,
        learned = opts.learned or false,
    }
end

local function fixture()
    return {
        recipe(101, SPEC[DRAGON]),
        recipe(102, SPEC[TRIBAL]),
        recipe(103, { unknown = true }),
        recipe(104, nil),
        recipe(105, SPEC[TRIBAL], { learned = true }),
        recipe(106, SPEC[ELEMENTAL], { source = { type = "drop", itemId = 7106 } }),
    }
end

local function prices(recipes)
    local p = {}
    for _, r in ipairs(recipes) do
        for _, g in ipairs(r.reagents) do p[g.itemId] = 50 end
    end
    return p
end

local function ids(list, field)
    local out = {}
    for _, x in ipairs(list) do
        local r = field and x[field] or x
        out[#out + 1] = r.id
    end
    table.sort(out)
    return table.concat(out, ",")
end

local function reset()
    known = {}
    bags = {}
    stubClient()
    LazyProf.db.char.selfFoundMode = nil
    LazyProf.db.char.learnedRecipes = {}
    LazyProf.db.profile.suggestUnlearnedRecipes = true
end

local function candidates(strategyName, recipes, skill)
    A:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local c = LazyProf.PathfinderStrategies[strategyName]:GetCandidates(recipes, skill or 10, 0)
    LazyProf.SelfFound:EndRecalc()
    A:EndRecalc()
    return c
end

local function calculate(strategyName, recipes, from, to, pins, ctx)
    LazyProf.db.profile.strategy = strategyName
    A:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local steps, meta = LazyProf.PathfinderStrategies[strategyName]:Calculate(
        from, to, recipes, {}, prices(recipes), 0, pins, ctx)
    LazyProf.SelfFound:EndRecalc()
    A:EndRecalc()
    return steps, meta
end

-- ===========================================================================
-- The rule
-- ===========================================================================
T.section("rule", function()
    reset()
    known[DRAGON] = true
    local r = fixture()
    check("known spec -> no block", A:SpecializationBlocks(r[1]) == nil)
    check("other spec -> blocked by it", A:SpecializationBlocks(r[2]) == r[2].specialization)
    check("unknown -> blocked", A:SpecializationBlocks(r[3]) and A:SpecializationBlocks(r[3]).unknown == true)
    check("no field -> no block", A:SpecializationBlocks(r[4]) == nil)
    check("learned foreign-spec recipe -> no block", A:SpecializationBlocks(r[5]) == nil)
    -- Without an adapter (headless runs of Forever data) nothing is known.
    LazyProf.Client = nil
    check("no adapter -> blocked", A:SpecializationBlocks(r[1]) ~= nil)
    stubClient()

    local ok, info = A:IsRecipeAvailableUncached(r[2])
    check("IsRecipeAvailable -> false, type specialization",
        ok == false and info and info.type == "specialization" and info.specialization.spellId == TRIBAL)
    bags[7102] = 1
    ok, info = A:IsRecipeAvailableUncached(r[2])
    check("foreign pattern in the bags -> still not available", ok == false and info.type == "specialization")
    -- Control: the bags check itself works here.
    bags[7104] = 1
    ok, info = A:IsRecipeAvailableUncached(r[4])
    check("control: own pattern in the bags -> available from the bags", ok == true and info.type == "inventory")

    -- Asked once per spell in one calculation; a spell learned meanwhile counts
    -- from the next one.
    local asked = 0
    LazyProf.Client.KnowsSpell = function(_, id) asked = asked + 1; return known[id] == true end
    A:BeginRecalc()
    A:SpecializationBlocks(r[2]); A:SpecializationBlocks(r[2]); A:SpecializationBlocks(r[1])
    eq("one question per spell per calculation", asked, 2)
    known[TRIBAL] = true
    check("learned mid-calculation: still blocked in it", A:SpecializationBlocks(r[2]) ~= nil)
    A:EndRecalc()
    check("next calculation: known", A:SpecializationBlocks(r[2]) == nil)
end)

-- ===========================================================================
-- Candidates of both strategies
-- ===========================================================================
for _, strategyName in ipairs({ "cheapest", "fastest" }) do
    T.section(strategyName .. " candidates", function()
        local p = strategyName .. ": "
        reset()
        known[DRAGON] = true
        eq(p .. "Dragonscale known: own spec, no-spec and learned recipes only",
            ids(candidates(strategyName, fixture())), "101,104,105")
        known = {}
        eq(p .. "none known: no specialization recipe unless learned",
            ids(candidates(strategyName, fixture())), "104,105")
        known[TRIBAL], known[ELEMENTAL] = true, true
        local c = candidates(strategyName, fixture())
        check(p .. "Tribal + Elemental known: 102 and 106 are candidates",
            ids(c):find("102", 1, true) ~= nil and ids(c):find("106", 1, true) ~= nil, ids(c))

        reset()
        bags[7102] = 1
        eq(p .. "foreign pattern in the bags -> not a candidate", ids(candidates(strategyName, fixture())), "104,105")

        reset()
        LazyProf.db.char.selfFoundMode = true
        local found = ids(candidates(strategyName, fixture()))
        check(p .. "Self-Found on -> still out", not found:find("102", 1, true) and not found:find("101", 1, true), found)
    end)
end

-- ===========================================================================
-- Pins, remembered routes, alternatives
-- ===========================================================================
for _, strategyName in ipairs({ "cheapest", "fastest" }) do
    T.section(strategyName .. " paths", function()
        local p = strategyName .. ": "
        reset()
        known[DRAGON] = true
        local function uses(steps, id)
            for _, s in ipairs(steps) do
                if s.recipe.id == id then return "step" end
                for _, alt in ipairs(s.alternatives or {}) do
                    if alt.recipe.id == id then return "alternative" end
                end
            end
            return nil
        end
        local steps = calculate(strategyName, fixture(), 1, 40, {})
        check(p .. "a path exists", #steps > 0)
        check(p .. "blocked recipe in no step and no alternative", uses(steps, 102) == nil and uses(steps, 103) == nil,
            tostring(uses(steps, 102)) .. "/" .. tostring(uses(steps, 103)))
        check(p .. "the own specialization's recipe can be listed", uses(steps, 101) ~= nil)

        -- A pin saved before this change, and a remembered route, naming a blocked recipe.
        local pins = { { from = 1, to = 40, recipeId = 102 } }
        local ok, pinned = pcall(calculate, strategyName, fixture(), 1, 40, pins)
        check(p .. "pin of a blocked recipe: no error", ok, pinned)
        check(p .. "pin of a blocked recipe falls back", ok and #pinned > 0 and uses(pinned, 102) == nil)
        local replay = { { from = 1, to = 40, recipeId = 103 }, at = 1 }
        local ok2, replayed = pcall(calculate, strategyName, fixture(), 1, 40, {}, { replay = replay })
        check(p .. "replay and pin of a blocked recipe fall back",
            ok2 and #replayed > 0 and uses(replayed, 103) == nil, replayed)
    end)
end

-- ===========================================================================
-- Craft or buy
-- ===========================================================================
T.section("material resolver", function()
    reset()
    local R = LazyProf.MaterialResolver
    local tribalTrainer = recipe(201, SPEC[TRIBAL], { source = { type = "trainer" } })
    local plainTrainer = recipe(202, nil, { source = { type = "trainer" } })
    tribalTrainer.learned, plainTrainer.learned = nil, nil   -- CraftLib's own recipe tables
    check("resolver: trainer fallback refuses a blocked recipe",
        R:CanCraft({ professionKey = "leatherworking", recipe = tribalTrainer }) == false)
    check("resolver: trainer fallback still takes a recipe without one",
        R:CanCraft({ professionKey = "leatherworking", recipe = plainTrainer }) == true)
    LazyProf.db.char.learnedRecipes = { leatherworking = { [201] = true } }
    check("resolver crafts a learned spec recipe",
        R:CanCraft({ professionKey = "leatherworking", recipe = tribalTrainer }) == true)
end)

-- ===========================================================================
-- Real data: WoW Forever Leatherworking 250-300 (the owner's case)
-- ===========================================================================
T.section("forever leatherworking", function()
    reset()
    LazyProf.Professions.registry = {}
    LazyProf.Professions:Initialize()
    local lw = LazyProf.Professions:Get("leatherworking")
    check("registry keeps CraftLib's specializations",
        lw and lw.specializations and #lw.specializations == 3 and lw.specializations[1].spellId == DRAGON)

    -- Every pattern has an auction price here, so a drop pattern such as
    -- Chimeric Boots (19063, Tribal) would be offered without the rule.
    local savedAH = A.GetAHPrice
    A.GetAHPrice = function() return 5000, "TSM" end
    local function plan(spell)
        known = { [spell] = true }
        local recipes = LazyProf.Utils.DeepCopy(CraftLib:GetProfession("leatherworking").recipes)
        for _, r in ipairs(recipes) do r.learned = false end
        local seen = {}
        local steps = calculate("cheapest", recipes, 250, 300, {})
        for _, s in ipairs(steps) do
            seen[s.recipe.id] = s.recipe
            for _, alt in ipairs(s.alternatives or {}) do seen[alt.recipe.id] = alt.recipe end
        end
        return steps, seen
    end
    local steps, seen = plan(DRAGON)
    check("Dragonscale: a path to 300", #steps > 0)
    local foreign, dragon = {}, 0
    for id, r in pairs(seen) do
        local sp = r.specialization
        if sp and sp.spellId == DRAGON then dragon = dragon + 1 end
        if sp and sp.spellId ~= DRAGON then foreign[#foreign + 1] = id end
    end
    check("Dragonscale: no Tribal, Elemental or unknown recipe anywhere", #foreign == 0, table.concat(foreign, ","))
    check("Dragonscale: Chimeric Boots gone", seen[19063] == nil)
    check("Dragonscale: Dragonscale recipes may appear", dragon > 0, dragon)
    local _, tribalSeen = plan(TRIBAL)
    check("control: with Tribal known, Chimeric Boots is offered", tribalSeen[19063] ~= nil)
    A.GetAHPrice = savedAH
end)

-- ===========================================================================
-- /lp diag spec
-- ===========================================================================
T.section("diag spec", function()
    reset()
    known[DRAGON] = true
    local lw = {
        recipe(101, SPEC[DRAGON]), recipe(102, SPEC[TRIBAL]), recipe(107, SPEC[TRIBAL]),
        recipe(103, { unknown = true }, { source = { type = "unknown", itemId = 15781 } }),
        recipe(108, { unknown = true }, { source = { type = "unknown", itemId = 20382 } }),
        recipe(104, nil),
    }
    lw[4].name, lw[5].name = "Onyxia Scale Breastplate", "Dreamscale Breastplate"
    LazyProf.Professions.registry = {
        leatherworking = { id = 2108, name = "Leatherworking", recipes = lw,
                           specializations = { SPEC[DRAGON], SPEC[ELEMENTAL], SPEC[TRIBAL] } },
        alchemy = { id = 2259, name = "Alchemy", recipes = { recipe(301, nil) } },
    }
    LazyProf.db.char.learnedRecipes = { leatherworking = { [107] = true } }
    LazyProf.Client.ItemTooltipText = function(_, itemId)
        if itemId == 15781 then
            return { "Pattern: Onyxia Scale Breastplate", "Requires Leatherworking (300)", "Requires Dragonscale Leatherworking" }
        end
        return nil, "not loaded"
    end
    local lines = {}
    A:RunSpecDiagnostic(lines)
    local text = table.concat(lines, "\n")
    print(text)
    local function has(s) return text:find(s, 1, true) ~= nil end
    check("diag: profession summary", has("leatherworking: 3 specializations, 3 recipes need one, 2 unknown"), text)
    check("diag: a known one", has("  Dragonscale Leatherworking (10656): known=yes recipes=1 left out=0"), text)
    check("diag: one with no recipe", has("  Elemental Leatherworking (10658): known=no recipes=0 left out=0"), text)
    check("diag: a learned one counts apart", has("  Tribal Leatherworking (10660): known=no recipes=2 left out=1 (1 learned)"), text)
    check("diag: an unknown with its tooltip lines",
        has("  unknown: Onyxia Scale Breastplate (103) item 15781 left out | Pattern: Onyxia Scale Breastplate | "
            .. "Requires Leatherworking (300) | Requires Dragonscale Leatherworking"), text)
    check("diag: tooltip not loaded",
        has("  unknown: Dreamscale Breastplate (108) item 20382 left out | not loaded - run /lp diag spec again"), text)
    check("diag: a profession without specializations is not listed", not has("alchemy"), text)
    check("diag: plain ASCII", not text:find("[\128-\255]"))

    lines = {}
    LazyProf.Professions.registry = { alchemy = { id = 2259, name = "Alchemy", recipes = { recipe(301, nil) } } }
    A:RunSpecDiagnostic(lines)
    eq("diag: no data", table.concat(lines, "\n"), "no specialization data in this CraftLib")
end)

T.finish()
