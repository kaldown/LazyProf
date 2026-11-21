-- scripts/test_target.lua
--
-- Target skill and where a path starts: the path runs to a target the player
-- sets per profession (the last cap when none is set), and a profession the
-- character has is always planned from the real skill.
--
-- Run from the addon root:  lua5.1 scripts/test_target.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Client/Family.lua",
    "Core/Client/Classic.lua",
    "Core/Config.lua",
    "Core/CharStore.lua",
    "Modules/Recipes/Availability.lua",
    "Modules/Recipes/SelfFound.lua",
    "Modules/Pathfinder/Pins.lua",
    "Modules/Pathfinder/StrategyCore.lua",
    "Modules/Pathfinder/Strategies/Cheapest.lua",
    "Modules/Pathfinder/Strategies/Fastest.lua",
    "Modules/Pathfinder/MaterialResolver.lua",
    "Modules/Pathfinder/Pathfinder.lua",
})
local PF = LazyProf.Pathfinder
local MILESTONES = { 75, 150, 225, 300 }

local function rec(id, o, y, g, gr)
    return { id = id, name = "R" .. id, learned = true, skillRequired = o,
        skillRange = { orange = o, yellow = y, green = g, gray = gr },
        reagents = { { itemId = 100 + id, count = 1, name = "M" } } }
end
local PROF = { name = "Test", milestones = MILESTONES, recipes = { rec(1, 1, 400, 410, 420) } }

local realSkill, windowSkill = 0, nil
LazyProf.Professions = {
    active = "testprof",
    Get = function(_, key) return key == "testprof" and PROF or nil end,
    GetActive = function() return PROF end,
    GetRecipesWithLearnedStatus = function() return LazyProf.Utils.DeepCopy(PROF.recipes) end,
}
LazyProf.Client.PlayerSkill = function() return realSkill end
LazyProf.Client.GetLine = function() return "testprof", windowSkill, 300 end
LazyProf.PriceManager = { GetPrices = function() return { [101] = 100 } end, cache = {} }
LazyProf.Inventory.ScanBags = function() return {} end
LazyProf.db.char.learnedRecipes = { testprof = { [1] = true } }
LazyProf.db.profile.strategy = "cheapest"

T.section("target", function()
    T.eq("no stored target: the last cap", PF:GetTargetSkill("testprof", MILESTONES), 300)
    T.eq("setting 225 stores and returns it", PF:SetTargetSkill("testprof", 225, 143, MILESTONES), 225)
    T.eq("the stored target is used", PF:GetTargetSkill("testprof", MILESTONES), 225)
    T.eq("other professions keep the cap", PF:GetTargetSkill("other", MILESTONES), 300)
    T.eq("above the cap: clamped to the cap", PF:SetTargetSkill("testprof", 400, 143, MILESTONES), 300)
    T.check("a target equal to the cap is stored as none", LazyProf.CharStore:Profession("testprof").target == nil)
    T.eq("at or below the skill: clamped to skill + 1", PF:SetTargetSkill("testprof", 100, 143, MILESTONES), 144)
    T.eq("a fraction is floored", PF:SetTargetSkill("testprof", 200.7, 143, MILESTONES), 200)
    T.eq("not a number: the cap", PF:SetTargetSkill("testprof", "abc", 143, MILESTONES), 300)
    T.eq("skill at the cap: the cap", PF:SetTargetSkill("testprof", 250, 300, MILESTONES), 300)
    LazyProf.CharStore:Profession("testprof").target = 400
    T.eq("a stored target above the cap reads as the cap", PF:GetTargetSkill("testprof", MILESTONES), 300)
    LazyProf.CharStore:Profession("testprof").target = nil
end)

T.section("live path", function()
    windowSkill = 143
    local path = PF:Calculate("test")
    T.check("a path is calculated", path ~= nil)
    T.eq("it starts at the real skill", path.currentSkill, 143)
    T.eq("the real skill is recorded", path.actualSkill, 143)
    T.eq("it runs to the cap", path.targetSkill, 300)
    T.eq("the cap is recorded", path.capSkill, 300)
    T.eq("the profession key is recorded", path.professionKey, "testprof")
    T.check("it is not a planning path", not path.planning)
    T.check("the first step starts at the real skill", path.steps[1] and path.steps[1].skillStart == 143)
    T.check("prices and stock travel with the path", type(path.prices) == "table" and type(path.inventory) == "table")
    T.check("so do the caps", path.milestones == MILESTONES)

    PF:SetTargetSkill("testprof", 200, 143, MILESTONES)
    path = PF:Calculate("test")
    T.eq("a stored target ends the path there", path.targetSkill, 200)
    T.eq("the last step ends at the target", path.steps[#path.steps].skillEnd, 200)
    T.check("something is left", not path.nothingLeft)

    windowSkill = 200
    path = PF:Calculate("test")
    T.eq("skill at the target: no steps", #path.steps, 0)
    T.eq("and no gaps", #path.gaps, 0)
    T.check("flagged as nothing left", path.nothingLeft == true)
    T.eq("with a zero total", path.totalCost, 0)

    windowSkill = 260
    path = PF:Calculate("test")
    T.check("skill past the target: still nothing left, no error", path.nothingLeft == true and #path.steps == 0)

    LazyProf.CharStore:Profession("testprof").target = nil
    windowSkill = 300
    path = PF:Calculate("test")
    T.check("skill at the last cap: nothing left", path.nothingLeft == true)
end)

T.section("planning path", function()
    realSkill = 250
    local path = PF:CalculateForProfession("testprof")
    T.eq("a profession the character has starts at the real skill", path.currentSkill, 250)
    T.eq("real skill recorded", path.actualSkill, 250)
    T.check("has the profession", path.hasProfession == true)
    T.check("marked as planning", path.planning == true)
    T.eq("profession key", path.professionKey, "testprof")

    path = PF:CalculateForProfession("testprof", { planFromOne = true })
    T.eq("plan from 1: starts at 1", path.currentSkill, 1)
    T.eq("plan from 1: the real skill is still recorded", path.actualSkill, 250)
    T.check("plan from 1 is recorded", path.planFromOne == true)

    realSkill = 0
    path = PF:CalculateForProfession("testprof")
    T.eq("a profession not learned starts at 1", path.currentSkill, 1)
    T.eq("with real skill 1", path.actualSkill, 1)
    T.check("does not have the profession", path.hasProfession == false)

    T.check("unknown profession: no path", PF:CalculateForProfession("nope") == nil)

    PF:SetTargetSkill("testprof", 100, 1, MILESTONES)
    path = PF:CalculateForProfession("testprof")
    T.eq("planning honours the target too", path.targetSkill, 100)
    LazyProf.CharStore:Profession("testprof").target = nil
end)

T.section("settings", function()
    T.check("calculate-from-current-skill is retired", LazyProf.defaults.profile.calculateFromCurrentSkill == nil)
    T.eq("margin is off by default", LazyProf.defaults.profile.useMargin, false)
    T.eq("margin percent default", LazyProf.defaults.profile.marginPercent, 15)
    local opt = LazyProf.options.args.general.args.marginPercent
    T.check("margin percent option exists", opt ~= nil)
    T.eq("option minimum", opt and opt.min, 5)
    T.eq("option maximum", opt and opt.max, 30)
    T.eq("option step", opt and opt.step, 5)
    T.check("the old option is gone", LazyProf.options.args.display.args.calculateFromCurrentSkill == nil)
end)

T.finish()
