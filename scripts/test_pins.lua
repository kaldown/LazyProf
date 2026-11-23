-- scripts/test_pins.lua
--
-- Range pins: a pinned recipe covers a skill range ("recipe X from 143 to
-- 165") instead of one exact fractional skill, so it keeps matching when the
-- steps before it change. Covers the pure pin list and the strategy loop's
-- lookup. With no pins the loop's output is unchanged (scripts/test_paths.lua).
--
-- Run from the addon root:  lua5.1 scripts/test_pins.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 11508 })
local guid = "Player-1-00000001"
_G.UnitGUID = function() return guid end
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
LazyProf.db.global = { characters = {} }
local Pins = LazyProf.Pins
local Utils = LazyProf.Utils

local function ids(pins)
    local out = {}
    for _, p in ipairs(pins) do
        out[#out + 1] = string.format("%s-%s:%s", tostring(p.from), tostring(p.to), tostring(p.recipeId))
    end
    return table.concat(out, " ")
end

T.section("pin list", function()
    local pins = {}
    T.check("empty list finds nothing", Pins.Find(pins, 10) == nil)
    T.check("nil list finds nothing", Pins.Find(nil, 10) == nil)

    Pins.Add(pins, 143, 165.5, 7)
    T.eq("found at its start", Pins.Find(pins, 143), 7)
    T.eq("found inside", Pins.Find(pins, 150.25), 7)
    T.check("not found at its end (half-open range)", Pins.Find(pins, 165.5) == nil)
    T.check("not found before it", Pins.Find(pins, 142.99) == nil)

    Pins.Add(pins, 165.5, 180, 8)
    T.eq("a pin starting where another ends keeps both", ids(pins), "143-165.5:7 165.5-180:8")
    T.eq("the boundary belongs to the later pin", Pins.Find(pins, 165.5), 8)

    Pins.Add(pins, 160, 170, 9)
    T.eq("a new pin replaces every pin it overlaps", ids(pins), "160-170:9")

    Pins.Add(pins, 100, 120, 1)
    Pins.Add(pins, 200, 220, 2)
    T.eq("pins stay sorted by start", ids(pins), "100-120:1 160-170:9 200-220:2")

    T.check("RemoveAt removes the covering pin", Pins.RemoveAt(pins, 165) == true)
    T.eq("the others stay", ids(pins), "100-120:1 200-220:2")
    T.check("RemoveAt with nothing there reports false", Pins.RemoveAt(pins, 165) == false)

    T.eq("Prune drops pins the skill has passed", Pins.Prune(pins, 120), 1)
    T.eq("a pin still ahead stays", ids(pins), "200-220:2")
    T.eq("a pin the skill is inside stays", Pins.Prune(pins, 210), 0)
    T.eq("Prune at its end drops it", Pins.Prune(pins, 220), 1)
    T.eq("now empty", #pins, 0)

    Pins.Add(pins, 10, 10, 3)
    T.eq("an empty range is not stored", #pins, 0)
    Pins.Add(pins, 10, 20, nil)
    T.eq("a pin without a recipe is not stored", #pins, 0)
end)

-- Two recipes over the same range: A is cheaper, C dearer. The optimizer
-- picks A; a pin makes it C for the pinned range only.
local function recipe(id, name, orange, yellow, green, gray, required)
    return {
        id = id, name = name, learned = true,
        skillRequired = required or orange,
        skillRange = { orange = orange, yellow = yellow, green = green, gray = gray },
        reagents = { { itemId = 100 + id, count = 1, name = "Mat" .. name } },
    }
end
local A = recipe(1, "A", 1, 40, 50, 60)
local C = recipe(3, "C", 1, 40, 50, 60)
local LATE = recipe(4, "Late", 30, 60, 70, 80)
local PRICES = { [101] = 100, [103] = 300, [104] = 5000 }

local function run(strategyName, pins)
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local steps = LazyProf.PathfinderStrategies[strategyName]:Calculate(
        1, 40, Utils.DeepCopy({ A, C, LATE }), {}, PRICES, 0, pins)
    LazyProf.SelfFound:EndRecalc()
    LazyProf.RecipeAvailability:EndRecalc()
    return steps
end

for _, strategyName in ipairs({ "cheapest", "fastest" }) do
    T.section(strategyName .. " loop", function()
        LazyProf.db.profile.strategy = strategyName
        local plain = run(strategyName, {})
        T.check(strategyName .. ": a path exists", #plain > 0)
        local plainNil = run(strategyName, nil)
        T.eq(strategyName .. ": no pin list equals an empty one", #plainNil, #plain)
        local picked = plain[1].recipe.id
        local other = picked == 1 and 3 or 1

        local pins = {}
        Pins.Add(pins, 10, 20, other)
        local steps = run(strategyName, pins)
        local okInside, okOutside = true, true
        local sawInside = false
        for _, s in ipairs(steps) do
            if s.skillStart >= 10 and s.skillStart < 20 then
                sawInside = true
                if s.recipe.id ~= other then okInside = false end
            elseif s.skillStart < 10 then
                if s.recipe.id ~= picked then okOutside = false end
            end
        end
        T.check(strategyName .. ": steps start inside the pinned range", sawInside)
        T.check(strategyName .. ": every step starting in the range uses the pinned recipe", okInside)
        T.check(strategyName .. ": steps before the range keep the optimizer's recipe", okOutside)

        -- A pin for a recipe that cannot be crafted in its range changes nothing.
        local dead = {}
        Pins.Add(dead, 5, 15, 4)   -- "Late" needs skill 30
        local same = run(strategyName, dead)
        local identical = #same == #plain
        for i = 1, math.min(#same, #plain) do
            if same[i].recipe.id ~= plain[i].recipe.id or same[i].quantity ~= plain[i].quantity then
                identical = false
            end
        end
        T.check(strategyName .. ": a pin for a recipe that is no candidate leaves the path alone", identical)
        T.eq(strategyName .. ": and the pin stays in the list", #dead, 1)
    end)
end

T.section("planner pin api", function()
    local PF = LazyProf.Pathfinder
    T.eq("no pins at first", #PF:GetPins("tailoring"), 0)
    PF:PinRange("tailoring", 143, 165, 77)
    T.eq("PinRange stores it for the profession", PF:PinnedAt("tailoring", 150), 77)
    T.check("other professions are not touched", PF:PinnedAt("alchemy", 150) == nil)
    T.check("stored in the character's saved data",
        LazyProf.db.global.characters[guid].professions.tailoring.pins[1].recipeId == 77)
    PF:UnpinAt("tailoring", 150)
    T.check("UnpinAt removes it", PF:PinnedAt("tailoring", 150) == nil)
    PF:PinRange("tailoring", 143, 165, 77)
    PF:ClearPins("tailoring")
    T.eq("ClearPins empties the profession's list", #PF:GetPins("tailoring"), 0)
end)

T.finish()
