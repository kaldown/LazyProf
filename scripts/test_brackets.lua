-- scripts/test_brackets.lua
--
-- With calculateFromCurrentSkill off the path starts at skill 1, but the
-- selected bracket, the shopping-list filter and the arrow follow the
-- player's real skill (path.actualSkill).
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
    "Modules/Recipes/Availability.lua",
    "Modules/Recipes/SelfFound.lua",
    "Modules/Pathfinder/StrategyCore.lua",
    "Modules/Pathfinder/Strategies/Cheapest.lua",
    "Modules/Pathfinder/Strategies/Fastest.lua",
    "Modules/Pathfinder/Pathfinder.lua",
    "Modules/UI/Widgets/RowPool.lua",
    "Modules/UI/Widgets/Dropdown.lua",
    "Modules/UI/MilestoneBreakdown.lua",
    "Modules/UI/Arrow/Strategies/ArrowTooltip.lua",
}

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf(FILES)
local Panel = LazyProf.MilestonePanelClass

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
        milestoneBreakdown = {
            { from = 1 }, { from = 75 }, { from = 150 }, { from = 225 },
        },
    }
end

-- Bracket + shopping-list filter
local panel = setmetatable({ currentPath = path(250) }, { __index = Panel })
local b = panel:GetEffectiveBracket()
check("bracket follows real skill 250", b and b.min == 225 and b.max == 300, b and (b.min .. "-" .. b.max))
local filtered = panel:FilterBreakdownByBracket(panel.currentPath.milestoneBreakdown)
check("shopping list filtered to the real bracket", #filtered == 1 and filtered[1].from == 225, #filtered)
panel.currentPath = path(nil)
b = panel:GetEffectiveBracket()
check("no actualSkill falls back to currentSkill", b and b.min == 1, b and b.min)
panel.currentPath = path(250)
panel.selectedBracketIndex = "all"
check("Full Path still unfiltered", panel:GetEffectiveBracket() == nil)

-- Arrow step
local P = LazyProf.Pathfinder
local s = P:GetArrowStep(path(250))
check("arrow step covers 250", s and s.skillStart == 225 and s.skillEnd == 260, s and s.skillStart)
s = P:GetArrowStep(path(260))
check("arrow at a step end moves to the next step", s and s.skillStart == 260, s and s.skillStart)
s = P:GetArrowStep(path(1))
check("arrow at skill 1 is the first step", s and s.skillStart == 1)
s = P:GetArrowStep(path(400))
check("past the last step falls back to steps[1]", s and s.skillStart == 1)
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

print(string.format("%d/%d passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
