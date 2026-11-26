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
    "Modules/Pricing/SaleValue.lua",
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
    T.eq("bank stock counts by default", LazyProf.defaults.profile.includeBankItems, true)
    T.eq("alt stock counts by default", LazyProf.defaults.profile.includeAltCharacters, true)
    T.eq("the guild bank does not (it is shared)", LazyProf.defaults.profile.includeGuildBank, false)
    T.eq("crafts are counted as sold to a vendor by default", LazyProf.defaults.profile.saleValueMode, "vendor")
    T.eq("the advanced controls are hidden by default", LazyProf.defaults.profile.showAdvanced, false)
    T.eq("margin is off by default", LazyProf.defaults.profile.useMargin, false)
    T.eq("margin percent default", LazyProf.defaults.profile.marginPercent, 15)
    local opt = LazyProf.options.args.general.args.marginPercent
    T.eq("the option is named as the window names it", opt.name, "Spare crafts (percent)")
    T.check("margin percent option exists", opt ~= nil)
    T.eq("option minimum", opt and opt.min, 5)
    T.eq("option maximum", opt and opt.max, 30)
    T.eq("option step", opt and opt.step, 5)
    T.check("the old option is gone", LazyProf.options.args.display.args.calculateFromCurrentSkill == nil)
end)

-- The options name parts of the window. None may name one that is gone: the
-- "With margin" box (now "Spare crafts"), the Guide and Steps tabs, the path
-- bar, the range dropdown.
T.section("options text", function()
    local texts = {}
    local function collect(value)
        if type(value) == "string" then
            texts[#texts + 1] = value
        elseif type(value) == "table" then
            for _, v in pairs(value) do collect(v) end
        end
    end
    local function walk(option)
        collect(option.name)
        collect(option.desc)
        collect(option.values)
        for _, child in pairs(option.args or {}) do
            if type(child) == "table" then walk(child) end
        end
    end
    walk(LazyProf.options)
    T.check("the options were read", #texts > 40, #texts)
    local gone = {
        { "the With margin box", function(t) return t:lower():find("with margin", 1, true) end },
        { "the Guide tab", function(t) return t:find("%f[%a]Guide%f[%A]") end },
        { "the Steps tab", function(t) return t:find("%f[%a]Steps%f[%A]") end },
        { "the path bar", function(t) return t:lower():find("path bar", 1, true) end },
        { "the range dropdown", function(t) return t:find("%f[%a]Range%f[%A]") or t:lower():find("range filter", 1, true)
            or t:lower():find("range dropdown", 1, true) or t:lower():find("current range", 1, true) end },
    }
    for _, entry in ipairs(gone) do
        local found
        for _, text in ipairs(texts) do
            if entry[2](text) then found = text end
        end
        T.check("no options text names " .. entry[1], found == nil, found)
    end
    local margin = LazyProf.options.args.general.args.marginPercent.desc
    T.check("the margin option names the box as the window does", margin:find('"Spare crafts"', 1, true) ~= nil
        and margin:find("More options", 1, true) ~= nil, margin)
    local open = LazyProf.options.args.display.args.openWithProfession.desc
    T.check("the window option names today's tabs", open:find("Crafts and Shopping", 1, true) ~= nil, open)
end)

T.section("settings migration", function()
    local migrate = LazyProf.MigrateSettings
    -- The raw saved table holds only what differed from the old defaults (both toggles on).
    local sv = { profiles = {
        Default = { showMilestonePanel = false, showMissingMaterials = false, calculateFromCurrentSkill = true,
                    panelPositions = { milestone = { x = 1, y = 2 }, shoppingList = { x = 3, y = 4 }, recipeDetails = { x = 5, y = 6 } } },
        OnlyMilestoneOff = { showMilestonePanel = false },
        OnlyShoppingOff = { showMissingMaterials = false },
        Untouched = { strategy = "fastest" },
        AlreadyNew = { showMilestonePanel = false, showMissingMaterials = false, openWithProfession = true },
    } }
    migrate(sv)
    local d = sv.profiles.Default
    T.check("both panels were off: the window does not open with the profession window", d.openWithProfession == false)
    T.check("old toggles removed", d.showMilestonePanel == nil and d.showMissingMaterials == nil)
    T.check("retired setting removed", d.calculateFromCurrentSkill == nil)
    T.check("the two old panel spots removed", d.panelPositions.milestone == nil and d.panelPositions.shoppingList == nil)
    T.check("other saved spots kept", d.panelPositions.recipeDetails ~= nil)
    T.check("one panel was on: the default (open) stays", sv.profiles.OnlyMilestoneOff.openWithProfession == nil
        and sv.profiles.OnlyShoppingOff.openWithProfession == nil)
    T.check("and its old toggle is removed", sv.profiles.OnlyMilestoneOff.showMilestonePanel == nil)
    T.check("an untouched profile is left alone", sv.profiles.Untouched.openWithProfession == nil
        and sv.profiles.Untouched.strategy == "fastest")
    T.check("a value already set is not overwritten", sv.profiles.AlreadyNew.openWithProfession == true)
    migrate(sv)
    T.check("running it again changes nothing", d.openWithProfession == false)
    T.check("no saved data: no error", pcall(migrate, nil) and pcall(migrate, {}))

    -- The bags and banks an unreleased build remembered itself are dropped,
    -- whatever else is saved; the rest of the account-wide data stays.
    local withStock = { global = { stock = { schema = 1, characters = { ["Player-1-A"] = { name = "A" } }, account = {} },
                                   vendorPrices = { [2589] = 10 }, characters = { ["Player-1-A"] = { lastTab = "path" } } } }
    migrate(withStock)
    T.check("saved stock memory: dropped", withStock.global.stock == nil)
    T.check("saved stock memory: the rest of the account-wide data stays",
        withStock.global.vendorPrices[2589] == 10 and withStock.global.characters["Player-1-A"].lastTab == "path")
    local both = { global = { stock = { schema = 1 } }, profiles = { Default = { showMilestonePanel = false, showMissingMaterials = false } } }
    migrate(both)
    T.check("with profiles saved too: dropped, and the profiles still migrated", both.global.stock == nil
        and both.profiles.Default.openWithProfession == false)
    migrate(withStock)
    T.check("running it again: nothing to drop, no error", withStock.global.stock == nil)
    T.check("a damaged global table: no error", pcall(migrate, { global = "broken" }) and pcall(migrate, { global = { stock = 5 } }))
    T.check("no default writes it back", LazyProf.defaults.global.stock == nil)

    T.eq("default: the window opens with the profession window", LazyProf.defaults.profile.openWithProfession, true)
    T.check("old toggle defaults are gone", LazyProf.defaults.profile.showMilestonePanel == nil
        and LazyProf.defaults.profile.showMissingMaterials == nil)
    local display = LazyProf.options.args.display.args
    T.check("option: open with the profession window", display.openWithProfession ~= nil)
    T.check("old options are gone", display.showMilestonePanel == nil and display.showMissingMaterials == nil)
end)

T.finish()
