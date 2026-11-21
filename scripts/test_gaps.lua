-- scripts/test_gaps.lua
--
-- Skill gaps: when no recipe can be chosen at the simulated skill, the shared
-- strategy loop must bridge with a green recipe (while its skill-up chance is
-- at least Constants.BRIDGE_MIN_CHANCE) or record a gap and continue from the
-- next learnable recipe. A path never ends silently.
--
-- Run from the addon root:  lua5.1 scripts/test_gaps.lua

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
    "Modules/Pathfinder/Pathfinder.lua",
    "Modules/UI/Widgets/RowPool.lua",
    "Modules/UI/Widgets/Dropdown.lua",
    "Modules/UI/MilestoneBreakdown.lua",
}

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf(FILES)
local Utils = LazyProf.Utils
local Panel = LazyProf.MilestonePanelClass

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

local function recipe(id, name, orange, yellow, green, gray, opts)
    opts = opts or {}
    return {
        id = id, name = name, learned = not opts.unlearned,
        skillRequired = opts.required or orange,
        skillRange = { orange = orange, yellow = yellow, green = green, gray = gray },
        reagents = { { itemId = 100 + id, count = 1, name = "Mat" .. name } },
    }
end

-- The measured probe: A (1/20/30/40) and B (50/60/70/80).
local A = recipe(1, "A", 1, 20, 30, 40)
local B = recipe(2, "B", 50, 60, 70, 80)
local PRICES = { [101] = 100, [102] = 200, [103] = 300 }
local STRATEGIES = { "cheapest", "fastest" }

local function run(strategyName, from, to, recipes)
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local steps, meta = LazyProf.PathfinderStrategies[strategyName]:Calculate(
        from, to, Utils.DeepCopy(recipes), {}, PRICES, 0, {})
    LazyProf.SelfFound:EndRecalc()
    LazyProf.RecipeAvailability:EndRecalc()
    return steps, meta
end

local function chance(skill, r) return Utils.GetSkillUpChance(skill, r.skillRange) end
local function lastEnd(steps) return steps[#steps] and steps[#steps].skillEnd or 0 end
local function uses(steps, id)
    for _, s in ipairs(steps) do if s.recipe.id == id then return true end end
    return false
end
local function countBridges(steps)
    local n = 0
    for _, s in ipairs(steps) do if s.bridge then n = n + 1 end end
    return n
end

-- Every crafted unit of a bridge step must have had chance >= the floor.
local function bridgesRespectFloor(steps)
    local floorChance = LazyProf.Constants.BRIDGE_MIN_CHANCE
    for _, s in ipairs(steps) do
        if s.bridge then
            local sim = s.skillStart
            for _ = 1, s.quantity do
                local c = chance(sim, s.recipe)
                if c < floorChance then
                    return false, string.format("%s crafted at %.2f with chance %.3f", s.recipe.name, sim, c)
                end
                sim = sim + c
            end
        end
    end
    return true
end

-- Steps are contiguous; any jump is covered by exactly one recorded gap.
local function noSilentJumps(steps, meta, from)
    local at = from
    local gi = 1
    for _, s in ipairs(steps) do
        if math.abs(s.skillStart - at) > 1e-9 then
            local g = meta.gaps[gi]
            if not (g and math.abs(g.from - at) < 1e-9 and math.abs(g.to - s.skillStart) < 1e-9) then
                return false, string.format("jump %.2f to %.2f without a gap", at, s.skillStart)
            end
            gi = gi + 1
        end
        at = s.skillEnd
    end
    return true
end

local function hasHighBytes(s)
    return s:find("[\128-\255]") ~= nil
end

-- ===========================================================================
-- 1. The probe: green excluded, A then B learnable at 50, target 90
-- ===========================================================================
for _, strategyName in ipairs(STRATEGIES) do
    section("probe " .. strategyName, function()
        local p = "probe " .. strategyName .. ": "
        local steps, meta = run(strategyName, 1, 90, { A, B })
        check(p .. "Calculate returns meta", type(meta) == "table", type(meta))
        check(p .. "steps reach >= 50", lastEnd(steps) >= 50, lastEnd(steps))
        check(p .. "B is used", uses(steps, 2))
        check(p .. "complete == false", meta.complete == false, tostring(meta.complete))
        local g1 = meta.gaps[1]
        check(p .. "first gap ends at 50", g1 and g1.to == 50, g1 and g1.to)
        check(p .. "first gap reason", g1 and g1.reason == "no recipe", g1 and g1.reason)
        check(p .. "first gap starts where A fell under 10%",
            g1 and g1.from >= 38 and chance(g1.from, A) < LazyProf.Constants.BRIDGE_MIN_CHANCE,
            g1 and g1.from)
        local gl = meta.gaps[#meta.gaps]
        check(p .. "last gap ends at the target", gl and gl.to == 90, gl and gl.to)
        check(p .. "two gaps", #meta.gaps == 2, #meta.gaps)
        check(p .. "bridge steps exist", countBridges(steps) > 0, countBridges(steps))
        local ok, why = bridgesRespectFloor(steps)
        check(p .. "bridges respect the 10% floor", ok, why)
        ok, why = noSilentJumps(steps, meta, 1)
        check(p .. "every jump is a recorded gap", ok, why)
    end)
end

-- ===========================================================================
-- 2. Only A, target 90: the path ends with a gap up to the target
-- ===========================================================================
for _, strategyName in ipairs(STRATEGIES) do
    section("only A " .. strategyName, function()
        local p = "only A " .. strategyName .. ": "
        local steps, meta = run(strategyName, 1, 90, { A })
        check(p .. "one gap", #meta.gaps == 1, #meta.gaps)
        local g = meta.gaps[1]
        check(p .. "gap ends at 90", g and g.to == 90, g and g.to)
        check(p .. "gap starts at the last step end", g and math.abs(g.from - lastEnd(steps)) < 1e-9,
            g and (g.from .. " vs " .. lastEnd(steps)))
        check(p .. "gap starts past the 10% floor", g and g.from >= 38, g and g.from)
        check(p .. "complete == false", meta.complete == false)
    end)
end

-- ===========================================================================
-- 3. Bridge: A turns green at 30, B learnable at 32, target 50
-- ===========================================================================
local B32 = recipe(2, "B", 32, 45, 55, 65)
for _, strategyName in ipairs(STRATEGIES) do
    section("bridge " .. strategyName, function()
        local p = "bridge " .. strategyName .. ": "
        local steps, meta = run(strategyName, 1, 50, { A, B32 })
        local bridge
        for _, s in ipairs(steps) do if s.bridge then bridge = s; break end end
        check(p .. "a step is marked bridge = true", bridge ~= nil and bridge.bridge == true)
        check(p .. "the bridge crafts A", bridge and bridge.recipe.id == 1, bridge and bridge.recipe.id)
        check(p .. "the bridge recipe is green", bridge
            and Utils.GetSkillColor(bridge.skillStart, A.skillRange) == "green",
            bridge and bridge.skillStart)
        check(p .. "the bridge stops at B's unlock", bridge and bridge.skillEnd < 33, bridge and bridge.skillEnd)
        check(p .. "complete == true", meta.complete == true, tostring(meta.complete))
        check(p .. "no gaps", #meta.gaps == 0, #meta.gaps)
        check(p .. "reaches 50", lastEnd(steps) == 50, lastEnd(steps))
        for _, s in ipairs(steps) do
            if not s.bridge and s.bridge ~= nil then
                check(p .. "non-bridge steps carry no bridge flag", false, tostring(s.bridge))
            end
        end
    end)
end

-- ===========================================================================
-- 4. Candidates exist but none is available (unlearned, not suggested):
--    still bridged / reported, as in TBC Leatherworking at 370
-- ===========================================================================
local C = recipe(3, "C", 25, 45, 55, 65, { unlearned = true })
for _, strategyName in ipairs(STRATEGIES) do
    section("unavailable " .. strategyName, function()
        local p = "unavailable " .. strategyName .. ": "
        LazyProf.db.profile.suggestUnlearnedRecipes = false
        local steps, meta = run(strategyName, 1, 45, { A, C })
        LazyProf.db.profile.suggestUnlearnedRecipes = true
        check(p .. "never picks the unavailable recipe", not uses(steps, 3))
        check(p .. "bridges with A", countBridges(steps) > 0, countBridges(steps))
        local listsC = false
        for _, s in ipairs(steps) do
            if s.bridge then
                for _, alt in ipairs(s.alternatives or {}) do
                    if alt.recipe.id == 3 then listsC = true end
                end
            end
        end
        check(p .. "bridge alternatives still list C", listsC)
        local g = meta.gaps[1]
        check(p .. "gap up to the target", #meta.gaps == 1 and g.to == 45, g and g.to)
        check(p .. "gap starts past the 10% floor", g and g.from >= 38, g and g.from)
    end)
end

-- ===========================================================================
-- 5. Green recipes included by the setting: no bridge marking, gaps still recorded
-- ===========================================================================
section("green included", function()
    LazyProf.db.profile.includeGreenRecipes = true
    for _, strategyName in ipairs(STRATEGIES) do
        local p = "green included " .. strategyName .. ": "
        local steps, meta = run(strategyName, 1, 90, { A, B })
        check(p .. "no bridge steps", countBridges(steps) == 0, countBridges(steps))
        check(p .. "B is used", uses(steps, 2))
        check(p .. "first gap ends at 50", meta.gaps[1] and meta.gaps[1].to == 50)
        check(p .. "complete == false", meta.complete == false)
        local ok, why = noSilentJumps(steps, meta, 1)
        check(p .. "every jump is a recorded gap", ok, why)
    end
    LazyProf.db.profile.includeGreenRecipes = false
end)

-- ===========================================================================
-- 6. Starting inside a gap; 7. a complete path is unchanged
-- ===========================================================================
for _, strategyName in ipairs(STRATEGIES) do
    section("start in gap " .. strategyName, function()
        local p = "start in gap " .. strategyName .. ": "
        local steps, meta = run(strategyName, 41, 90, { A, B })
        local g = meta.gaps[1]
        check(p .. "gap 41-50 first", g and g.from == 41 and g.to == 50,
            g and (g.from .. "-" .. g.to))
        check(p .. "first step starts at 50", steps[1] and steps[1].skillStart == 50,
            steps[1] and steps[1].skillStart)
    end)
    section("complete " .. strategyName, function()
        local p = "complete " .. strategyName .. ": "
        local steps, meta = run(strategyName, 1, 25, { A })
        check(p .. "complete == true", meta.complete == true)
        check(p .. "no gaps", #meta.gaps == 0)
        check(p .. "no bridges", countBridges(steps) == 0)
        check(p .. "reaches 25", lastEnd(steps) == 25, lastEnd(steps))
    end)
end

-- ===========================================================================
-- 8. Pathfinder stores complete + gaps; totals cover the steps it has
-- ===========================================================================
section("pathfinder", function()
    local p = "pathfinder: "
    LazyProf.Professions = {
        Get = function(_self, key)
            if key ~= "testprof" then return nil end
            return { name = "Test", milestones = { 90 }, recipes = Utils.DeepCopy({ A, B }) }
        end,
    }
    LazyProf.db.char.learnedRecipes = { testprof = { [1] = true, [2] = true } }
    LazyProf.PriceManager = { GetPrices = function() return PRICES end, cache = {} }
    LazyProf.Inventory.ScanBags = function() return {} end
    LazyProf.db.profile.strategy = "cheapest"
    local path = LazyProf.Pathfinder:CalculateForProfession("testprof", 1)
    check(p .. "path built", type(path) == "table")
    check(p .. "path.complete == false", path.complete == false, tostring(path.complete))
    check(p .. "path.gaps stored", type(path.gaps) == "table" and #path.gaps == 2,
        path.gaps and #path.gaps)
    check(p .. "totalCost sums existing steps", path.totalCost == Utils.Sum(path.steps, "totalCost"))
    local bridged = false
    for _, mb in ipairs(path.milestoneBreakdown) do
        if mb.bridge then bridged = true end
    end
    check(p .. "milestone breakdown carries the bridge flag", bridged)
end)

-- ===========================================================================
-- 9. Milestone panel text and ordering (pure helpers, no frames)
-- ===========================================================================
section("panel", function()
    local p = "panel: "
    local gapText = Panel.GapText({ from = 38.01, to = 50 })
    check(p .. "gap row text", gapText == "No recipe for 38-50: train elsewhere or missing data", gapText)
    check(p .. "gap row text is ASCII", not hasHighBytes(gapText))
    local bridgeText = Panel.StepRecipeText({ quantity = 3, recipe = { name = "A" }, bridge = true })
    check(p .. "bridge suffix", bridgeText == "3x A (green: no better recipe)", bridgeText)
    local plainText = Panel.StepRecipeText({ quantity = 3, recipe = { name = "A" } })
    check(p .. "no suffix on normal steps", plainText == "3x A", plainText)
    check(p .. "total label excluding gaps", Panel.TotalLabel({ complete = false }, "Total") == "Total (excluding gaps): ",
        Panel.TotalLabel({ complete = false }, "Total"))
    check(p .. "total label complete", Panel.TotalLabel({ complete = true }, "Total") == "Total: ")
    check(p .. "total label old path", Panel.TotalLabel({}, "Total") == "Total: ")

    local steps = { { from = 1, to = 30 }, { from = 30, to = 38 }, { from = 50, to = 70 } }
    local gaps = { { from = 38, to = 50 }, { from = 78, to = 90 } }
    local merged = Panel.MergeStepsAndGaps(steps, gaps)
    local order = {}
    for _, e in ipairs(merged) do order[#order + 1] = e.gap and "gap" or "step" end
    check(p .. "gaps interleave by skill", table.concat(order, ",") == "step,step,gap,step,gap",
        table.concat(order, ","))

    local inBracket = Panel.FilterGapsForBracket(gaps, { min = 75, max = 150 })
    check(p .. "bracket keeps overlapping gaps", #inBracket == 1 and inBracket[1].from == 78, #inBracket)
    local none = Panel.FilterGapsForBracket(gaps, { min = 1, max = 38 })
    check(p .. "bracket drops non-overlapping gaps", #none == 0, #none)
    check(p .. "no bracket keeps all gaps", #Panel.FilterGapsForBracket(gaps, nil) == 2)
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
