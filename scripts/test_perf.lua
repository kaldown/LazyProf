-- scripts/test_perf.lua
--
-- Standalone Lua 5.1 unit tests for the calc-performance fixes:
--   1. LazyProf:IsDebugEnabled(category)          (Core/Init.lua)
--   2. LazyProf:ScheduleItemInfoRecalc()          (Core/Init.lua) - trailing debounce
--   3. LazyProf:OnItemInfoReceived wiring          (Core/Init.lua)
--   4. RecipeAvailability per-recalc memo          (Modules/Recipes/Availability.lua)
--
-- Run from the addon root:  lua5.1 scripts/test_perf.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

-- ---------------------------------------------------------------------------
-- Controllable fake clock + C_Timer
-- ---------------------------------------------------------------------------
local fakeNow = 0
local pending = {}   -- { {due=, fn=}, ... }
_G.GetTime = function() return fakeNow end
_G.C_Timer = { After = function(delay, fn)
    if delay < 0 then delay = 0 end
    table.insert(pending, { due = fakeNow + delay, fn = fn })
end }
local function advance(dt)
    fakeNow = fakeNow + dt
    local progressed = true
    while progressed do
        progressed = false
        for i, t in ipairs(pending) do
            if t.due <= fakeNow + 1e-9 then
                table.remove(pending, i)
                t.fn()
                progressed = true
                break
            end
        end
    end
end

-- Other load-time stubs
_G.LibStub = function(_name)
    return { NewAddon = function(_self, addon, ...) return addon end }
end
_G.date = function(_fmt) return "12:00:00" end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

-- ---------------------------------------------------------------------------
-- Load addon files into one shared addon table
-- ---------------------------------------------------------------------------
local addon = {}

-- Utils/Constants stubs the Cheapest strategy captures at load time.
local fmCalls = 0   -- shared with section E to count FormatMoney string-building
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end
addon.Constants = {}
addon.Utils = {
    DeepCopy = deepcopy,
    GetSkillColor = function(_skill, _range) return "orange" end,
    GetSkillUpChance = function(_eff, _range) return 0.5 end,
    FormatMoney = function(c) fmCalls = fmCalls + 1; return tostring(c) end,
    GetItemInfo = function(itemId) return "Item" .. tostring(itemId) end,
}

assert(loadfile("Core/Init.lua"))("LazyProf", addon)
assert(loadfile("Modules/Recipes/Availability.lua"))("LazyProf", addon)
assert(loadfile("Modules/Pathfinder/Strategies/Cheapest.lua"))("LazyProf", addon)
local LP = _G.LazyProf
assert(LP == addon, "Init.lua did not expose the shared addon table as _G.LazyProf")

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
local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then check(name .. " executed without error", false, err) end
end
local function flush()
    advance(10)        -- drain any pending timers to a settled state
    pending = {}
    fakeNow = fakeNow + 10
end

-- ===========================================================================
-- A: IsDebugEnabled
-- ===========================================================================
section("A", function()
    check("A IsDebugEnabled exists", type(LP.IsDebugEnabled) == "function")
    LP.db = { profile = { debug = false, debugCategories = { scoring = true, pathfinder = false } } }
    check("A off when master debug off", LP:IsDebugEnabled("scoring") == false)
    LP.db.profile.debug = true
    check("A on when master + category on", LP:IsDebugEnabled("scoring") == true)
    check("A off when category disabled", LP:IsDebugEnabled("pathfinder") == false)
    check("A nil category follows master", LP:IsDebugEnabled() == true)
    LP.db = nil
    check("A safe when db missing", LP:IsDebugEnabled("scoring") == false)
end)

-- ===========================================================================
-- B: ScheduleItemInfoRecalc trailing-debounce coalescing
-- ===========================================================================
section("B", function()
    check("B ScheduleItemInfoRecalc exists", type(LP.ScheduleItemInfoRecalc) == "function")

    local recalcCount = 0
    LP.Recalculate = function(_self, _reason) recalcCount = recalcCount + 1 end

    -- B1: single arrival -> exactly one recalc after the quiet window
    flush(); recalcCount = 0
    LP:ScheduleItemInfoRecalc()
    advance(0.6)
    check("B1 single arrival -> 1 recalc", recalcCount == 1, recalcCount)

    -- B2: a burst of 20 arrivals over ~2s collapses into ONE recalc
    flush(); recalcCount = 0
    for _ = 1, 20 do LP:ScheduleItemInfoRecalc(); advance(0.1) end
    advance(0.6)  -- let the quiet window elapse after the last arrival
    check("B2 burst of 20 -> 1 recalc (was ~20)", recalcCount == 1, recalcCount)

    -- B3: a never-quiet stream still recalcs by the max-wait cap (no starvation)
    flush(); recalcCount = 0
    for _ = 1, 45 do LP:ScheduleItemInfoRecalc(); advance(0.1) end  -- 4.5s continuous
    check("B3 continuous stream still recalcs (max-wait)", recalcCount >= 1, recalcCount)
end)

-- ===========================================================================
-- C: OnItemInfoReceived drives the coalescing path (not the per-event recalc)
-- ===========================================================================
section("C", function()
    LP.PriceManager = { flooredItems = { [123] = true, [456] = true }, cache = { [123] = {} } }
    local schedCount = 0
    local saved = LP.ScheduleItemInfoRecalc
    LP.ScheduleItemInfoRecalc = function(_self) schedCount = schedCount + 1 end

    LP:OnItemInfoReceived("e", 999, true)   -- not a floored item
    check("C unfloored item -> no schedule", schedCount == 0, schedCount)

    LP:OnItemInfoReceived("e", 123, true)   -- floored -> coalesced schedule + cleared
    check("C floored item -> one coalesced schedule", schedCount == 1, schedCount)
    check("C floored item cleared from flooredItems", LP.PriceManager.flooredItems[123] == nil)

    LP:OnItemInfoReceived("e", 456, false)  -- success == false -> ignored
    check("C failed item-info -> no schedule", schedCount == 1, schedCount)

    LP.ScheduleItemInfoRecalc = saved
end)

-- ===========================================================================
-- D: RecipeAvailability per-recalc memo
-- ===========================================================================
section("D", function()
    local Av = LP.RecipeAvailability
    check("D BeginRecalc exists", type(Av.BeginRecalc) == "function")
    check("D EndRecalc exists", type(Av.EndRecalc) == "function")
    check("D IsRecipeAvailableUncached exists", type(Av.IsRecipeAvailableUncached) == "function")

    local underlying = 0
    Av.IsRecipeAvailableUncached = function(_self, _recipe)
        underlying = underlying + 1
        return true, { type = "test" }
    end

    local r1 = { id = 111 }
    Av:BeginRecalc()
    local a1 = Av:IsRecipeAvailable(r1)
    local a2 = Av:IsRecipeAvailable(r1)  -- same id -> served from memo
    check("D memo: underlying called once per id", underlying == 1, underlying)
    check("D memo returns correct value", a1 == true and a2 == true)

    Av:EndRecalc()
    Av:IsRecipeAvailable(r1)             -- memo disabled outside a recalc
    check("D uncached outside recalc", underlying == 2, underlying)

    underlying = 0
    Av:BeginRecalc()
    Av:IsRecipeAvailable(r1)
    Av:IsRecipeAvailable({ id = 222 })
    Av:IsRecipeAvailable(r1)
    check("D per-recalc: 2 unique ids -> 2 underlying calls", underlying == 2, underlying)
    Av:EndRecalc()
end)

-- ===========================================================================
-- E: hot debug blocks build NO strings when debug is off (Fix 3b)
-- ===========================================================================
section("E", function()
    local cheapest = LP.PathfinderStrategies and LP.PathfinderStrategies.cheapest
    check("E cheapest strategy loaded", type(cheapest) == "table")

    local recipes = {}
    for i = 1, 3 do
        recipes[i] = {
            id = i, name = "R" .. i, learned = true,
            skillRequired = 1,
            skillRange = { orange = 1, yellow = 20, green = 40, gray = 60 },
            reagents = { { itemId = 1, count = 1, name = "Mat" } },
        }
    end
    local prices = { [1] = 100 }

    LP.db = { profile = { debug = false, strategy = "cheapest",
        includeGreenRecipes = true, suggestUnlearnedRecipes = false,
        debugCategories = { scoring = false, pathfinder = false } } }

    fmCalls = 0
    local pathOff = cheapest:Calculate(1, 5, recipes, {}, prices, 0, {})
    check("E debug OFF: a path is still produced", type(pathOff) == "table" and #pathOff > 0,
        pathOff and #pathOff)
    check("E debug OFF: zero FormatMoney from top-10 logging", fmCalls == 0, fmCalls)

    LP.db.profile.debug = true
    LP.db.profile.debugCategories.scoring = true
    fmCalls = 0
    cheapest:Calculate(1, 5, recipes, {}, prices, 0, {})
    check("E debug ON: top-10 logging builds FormatMoney strings", fmCalls > 0, fmCalls)
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
