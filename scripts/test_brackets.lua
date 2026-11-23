-- scripts/test_brackets.lua
--
-- A what-if path may start at skill 1 (planning "from 1"), but the
-- chosen range, what it filters and the arrow follow the player's real skill
-- (path.actualSkill).
--
-- Run from the addon root:  lua5.1 scripts/test_brackets.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")

local FILES = {
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Client/Family.lua",
    "Core/Client/Classic.lua",
    "Core/Config.lua",
    "Core/CharStore.lua",
    "Modules/Pricing/SaleValue.lua",
    "Modules/Recipes/Availability.lua",
    "Modules/Recipes/SelfFound.lua",
    "Modules/Pathfinder/Pins.lua",
    "Modules/Pathfinder/StrategyCore.lua",
    "Modules/Pathfinder/Strategies/Cheapest.lua",
    "Modules/Pathfinder/Strategies/Fastest.lua",
    "Modules/Pathfinder/Pathfinder.lua",
    "Modules/Guide/Text.lua",
    "Modules/Guide/Range.lua",
    "Modules/UI/Arrow/Strategies/ArrowTooltip.lua",
}

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf(FILES)
local Range = LazyProf.GuideRange

local MILESTONES = { 75, 150, 225, 300 }
LazyProf.GetSkillBrackets = function() return LazyProf.Utils.BuildSkillBrackets(MILESTONES) end

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

local function step(a, b) return { skillStart = a, skillEnd = b, recipe = { id = a, name = "R" .. a } } end
local function path(actual, gaps)
    return {
        currentSkill = 1, actualSkill = actual, gaps = gaps or {},
        steps = { step(1, 75), step(75, 150), step(150, 225), step(225, 260), step(260, 300) },
    }
end
-- Stages as the window filters them: one per step here.
local function stagesOf(p)
    local stages = {}
    for _, s in ipairs(p.steps) do
        stages[#stages + 1] = { kind = "craft", from = s.skillStart, to = s.skillEnd }
    end
    return stages
end

-- Range + what it filters
local BRACKETS = LazyProf:GetSkillBrackets()
local p250 = path(250)
local b = Range.Effective(nil, BRACKETS, p250.actualSkill)
check("the current range follows real skill 250", b and b.min == 225 and b.max == 300, b and (b.min .. "-" .. b.max))
local filtered = Range.FilterStages(stagesOf(p250), b)
check("stages filtered to the real range", #filtered == 2 and filtered[1].from == 225, #filtered)
check("no real skill: no range (everything shown)", Range.Effective(nil, BRACKETS, nil) == nil)
check("Full path is unfiltered", Range.Effective("all", BRACKETS, 250) == nil
    and #Range.FilterStages(stagesOf(p250), nil) == 5)

-- Arrow step
local P = LazyProf.Pathfinder
local s = P:GetArrowStep(path(250))
check("arrow step covers 250", s and s.skillStart == 225 and s.skillEnd == 260, s and s.skillStart)
s = P:GetArrowStep(path(260))
check("arrow at a step end moves to the next step", s and s.skillStart == 260, s and s.skillStart)
s = P:GetArrowStep(path(1))
check("arrow at skill 1 is the first step", s and s.skillStart == 1)
s = P:GetArrowStep(path(400))
check("past the last step: no arrow step", s == nil)
s = P:GetArrowStep(path(nil))
check("no actualSkill gives steps[1]", s and s.skillStart == 1)

-- Gap: real skill inside a gap hides the arrow
local gp = path(100, { { from = 90, to = 120, reason = "no recipe" } })
check("real skill inside a gap: no arrow step", P:GetArrowStep(gp) == nil)
gp.actualSkill = 120
check("gap end is exclusive", P:GetArrowStep(gp) ~= nil)
local hidden, shown = 0, nil
local manager = {
    Hide = function() hidden = hidden + 1 end,
    PositionAtRecipe = function(_, r) shown = r end,
}
gp.actualSkill = 100
LazyProf.ArrowStrategies.arrowWithTooltip.Update({}, manager, gp)
check("arrow hides inside a gap", hidden == 1 and shown == nil)
LazyProf.ArrowStrategies.arrowWithTooltip.Update({}, manager, path(250))
check("arrow points at the step covering 250", shown and shown.id == 225, shown and shown.id)

-- Planning: CalculateForProfession carries the real skill separately from the start
do
    local function rec(id, o, y, g, gr)
        return { id = id, name = "R" .. id, learned = true, skillRequired = o,
            skillRange = { orange = o, yellow = y, green = g, gray = gr },
            reagents = { { itemId = 100 + id, count = 1, name = "M" } } }
    end
    LazyProf.Professions = { Get = function(_, key)
        if key ~= "testprof" then return nil end
        return { name = "Test", milestones = { 75, 150, 225, 300 }, recipes = { rec(1, 1, 100, 200, 300) } }
    end }
    LazyProf.db.char.learnedRecipes = { testprof = { [1] = true } }
    LazyProf.PriceManager = { GetPrices = function() return { [101] = 100 } end, cache = {} }
    LazyProf.Inventory.ScanBags = function() return {} end
    LazyProf.db.profile.strategy = "cheapest"
    -- A learned profession is planned from the real skill; "plan from 1"
    -- keeps the real skill beside a path that starts at 1.
    LazyProf.Client.PlayerSkill = function() return 250 end
    local pp = LazyProf.Pathfinder:CalculateForProfession("testprof", { planFromOne = true })
    check("planning: actualSkill is the real skill", pp and pp.actualSkill == 250, pp and pp.actualSkill)
    check("planning from 1: path starts at 1", pp and pp.currentSkill == 1, pp and pp.currentSkill)
    local pp2 = LazyProf.Pathfinder:CalculateForProfession("testprof")
    check("planning: a learned profession starts at the real skill", pp2 and pp2.currentSkill == 250 and pp2.actualSkill == 250)
    local eb = Range.Effective(nil, BRACKETS, pp.actualSkill)
    check("planning from 1: the current range still follows the real skill", eb and eb.min == 225, eb and eb.min)
end

print(string.format("%d/%d passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
