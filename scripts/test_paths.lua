-- scripts/test_paths.lua
--
-- Characterization snapshots: pins the paths the Cheapest and Fastest
-- strategies compute from bundled CraftLib data, so later refactors can prove
-- they changed nothing.
--
-- Run from the addon root:  lua5.1 scripts/test_paths.lua
-- Rewrite snapshots:        UPDATE_SNAPSHOTS=1 lua5.1 scripts/test_paths.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")

local UPDATE = os.getenv("UPDATE_SNAPSHOTS") == "1"

local LAZYPROF_FILES = {
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Modules/Recipes/Availability.lua",
    "Modules/Recipes/SelfFound.lua",
    "Modules/Pathfinder/StrategyCore.lua",
    "Modules/Pathfinder/Strategies/Cheapest.lua",
    "Modules/Pathfinder/Strategies/Fastest.lua",
}

local CASES = {
    { name = "tbc_leatherworking_300_375", interface = 20505, prof = "leatherworking", from = 300, to = 375 },
    { name = "vanilla_enchanting_1_300", interface = 11508, prof = "enchanting", from = 1, to = 300 },
    { name = "tbc_engineering_1_375", interface = 20505, prof = "engineering", from = 1, to = 375 },
    { name = "wotlk_alchemy_1_450", interface = 30403, prof = "alchemy", from = 1, to = 450 },
    { name = "sod_tailoring_1_300", interface = 11508, sod = true, prof = "tailoring", from = 1, to = 300 },
}
local STRATEGIES = { "cheapest", "fastest" }

local failures, total = 0, 0
local function check(name, cond, detail)
    total = total + 1
    if cond then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail and ("\n" .. detail) or ""))
    end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function lastSkill(steps)
    local last = steps[#steps]
    return last and last.skillEnd or 0
end

local summary = {}

for _, case in ipairs(CASES) do
    local CraftLib = harness.loadCraftLib(case.interface, { sod = case.sod })
    local LazyProf = harness.loadLazyProf(LAZYPROF_FILES)
    local prof = CraftLib:GetProfession(case.prof)
    assert(prof, case.name .. ": CraftLib has no profession " .. case.prof)

    local recipes = LazyProf.Utils.DeepCopy(prof.recipes)
    for _, r in ipairs(recipes) do r.learned = false end
    local prices = harness.priceTable(recipes)

    for _, strategyName in ipairs(STRATEGIES) do
        local label = case.name .. "_" .. strategyName
        LazyProf.db.profile.strategy = strategyName
        local strategy = LazyProf.PathfinderStrategies[strategyName]
        assert(strategy, "missing strategy " .. strategyName)

        LazyProf.RecipeAvailability:BeginRecalc()
        LazyProf.SelfFound:BeginRecalc({})
        local steps = strategy:Calculate(case.from, case.to, LazyProf.Utils.DeepCopy(recipes), {}, prices, 0, {})
        LazyProf.SelfFound:EndRecalc()
        LazyProf.RecipeAvailability:EndRecalc()

        local text = harness.formatSteps(steps)
        local path = "scripts/snapshots/" .. label .. ".txt"
        summary[#summary + 1] = string.format("%s: %d steps, final skill %.2f", label, #steps, lastSkill(steps))

        if UPDATE then
            local f = assert(io.open(path, "w"))
            f:write(text)
            f:close()
            check(label .. " (snapshot written)", #steps > 0)
        else
            local expected = readFile(path)
            check(label, expected == text,
                expected and ("expected:\n" .. expected .. "got:\n" .. text) or ("missing snapshot " .. path))
        end
    end
end

for _, line in ipairs(summary) do print("INFO: " .. line) end
print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
