-- scripts/test_stages.lua
--
-- Stages: the path's fragments (five-craft steps with fractional skill
-- boundaries) folded into the steps a player follows - craft runs of one
-- recipe, learn-the-recipe steps, train-the-next-rank steps and gaps - plus
-- the margin, the done/current marks and the totals.
--
-- Run from the addon root:  lua5.1 scripts/test_stages.lua
-- Rewrite the stage snapshot:  UPDATE_SNAPSHOTS=1 lua5.1 scripts/test_stages.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

local FILES = {
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
    "Modules/Guide/Text.lua",
    "Modules/Guide/Range.lua",
    "Modules/Guide/Stages.lua",
}

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf(FILES)
local Stages, Text, Range = LazyProf.Stages, LazyProf.GuideText, LazyProf.GuideRange

local function recipe(id, name, orange, yellow, green, gray, opts)
    opts = opts or {}
    return {
        id = id, name = name, learned = not opts.unlearned,
        skillRequired = opts.required or orange,
        skillRange = { orange = orange, yellow = yellow, green = green, gray = gray },
        reagents = opts.reagents or { { itemId = 100 + id, count = 1, name = "Mat" .. name } },
        _sourceInfo = opts.sourceInfo,
    }
end
local function step(r, from, to, quantity, cost, extra)
    local s = { recipe = r, skillStart = from, skillEnd = to, quantity = quantity, totalCost = cost,
                alternatives = {} }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end
local function kinds(stages)
    local out = {}
    for _, s in ipairs(stages) do
        if s.kind == "craft" then
            out[#out + 1] = string.format("craft:%s:%dx", s.recipe.name, s.quantity)
        elseif s.kind == "learn" then
            out[#out + 1] = "learn:" .. s.recipe.name
        elseif s.kind == "rank" then
            out[#out + 1] = "rank:" .. tostring(s.cap)
        else
            out[#out + 1] = string.format("gap:%d-%d", s.from, s.to)
        end
    end
    return table.concat(out, " ")
end

local PRICES = { [101] = 100, [102] = 200, [103] = 300, [104] = 50 }
local MILESTONES = { 75, 150, 225, 300 }

T.section("merging", function()
    local A = recipe(1, "A", 1, 40, 50, 60)
    local B = recipe(2, "B", 30, 60, 70, 80)
    local path = { targetSkill = 75, steps = {
        step(A, 1, 6, 5, 500), step(A, 6, 11.5, 6, 600), step(A, 11.5, 30.25, 19, 1900),
        step(B, 30.25, 35, 5, 1000), step(B, 35, 40.5, 6, 1200),
        step(A, 40.5, 42, 4, 400),
    }, gaps = {}, totalCost = 5600 }
    local stages, summary = Stages.Build(path, { prices = PRICES, milestones = MILESTONES })
    T.eq("consecutive steps of one recipe merge", kinds(stages), "craft:A:30x craft:B:11x craft:A:4x")
    local first = stages[1]
    T.eq("quantity is summed", first.quantity, 30)
    T.eq("cost is summed", first.cost, 3000)
    T.eq("exact start kept", first.from, 1)
    T.eq("exact end kept", first.to, 30.25)
    T.eq("display start floored", first.fromDisplay, 1)
    T.eq("display end floored", first.toDisplay, 30)
    T.eq("fragments kept", #first.fragments, 3)
    T.eq("stage index", stages[2].index, 2)
    T.eq("second stage starts where the first ends", stages[2].from, 30.25)
    T.eq("expected cost equals the path total", summary.cost, 5600)
    T.eq("crafts counted", summary.crafts, 45)
    T.eq("range text", Text.StageRange(stages[2]), "30-40")
    T.eq("stage title", Text.StageTitle(stages[2]), "11x B")
end)

T.section("bridge and gaps", function()
    local A = recipe(1, "A", 1, 20, 30, 40)
    local B = recipe(2, "B", 50, 60, 70, 80)
    local path = { targetSkill = 75, steps = {
        step(A, 1, 20, 19, 1900), step(A, 20, 30, 15, 1500),
        step(A, 30, 38, 30, 3000, { bridge = true }),
        step(B, 50, 60, 10, 2000),
    }, gaps = { { from = 38, to = 50, reason = "no recipe" }, { from = 60, to = 75, reason = "no recipe" } },
        totalCost = 8400, complete = false }
    local stages, summary = Stages.Build(path, { prices = PRICES, milestones = MILESTONES })
    T.eq("a bridge run is its own stage; gaps sit in skill order", kinds(stages),
        "craft:A:34x craft:A:30x gap:38-50 craft:B:10x gap:60-75")
    T.check("bridge flag carried", stages[2].bridge == true and not stages[1].bridge)
    T.eq("bridge title", Text.StageTitle(stages[2]), "30x A (green: no better recipe)")
    T.eq("gap text unchanged", Text.GapText(stages[3]), "No recipe for 38-50: train elsewhere or missing data")
    T.eq("gaps add no cost", summary.cost, 8400)

    local onlyGap = { targetSkill = 75, steps = {}, gaps = { { from = 1, to = 75, reason = "no recipe" } }, totalCost = 0 }
    local s2, sum2 = Stages.Build(onlyGap, { prices = PRICES, milestones = MILESTONES, actualSkill = 1 })
    T.eq("a path made only of a gap still builds", kinds(s2), "gap:1-75")
    T.eq("its current stage is the gap", sum2.currentIndex, 1)
    T.eq("and it costs nothing", sum2.cost, 0)

    local gapFirst = { targetSkill = 75, steps = { step(B, 50, 60, 10, 2000) },
        gaps = { { from = 1, to = 50, reason = "no recipe" } }, totalCost = 2000 }
    T.eq("a gap before the first step comes first", kinds((Stages.Build(gapFirst, { prices = PRICES, milestones = MILESTONES }))),
        "gap:1-50 craft:B:10x")

    local empty = { targetSkill = 75, steps = {}, gaps = {}, totalCost = 0 }
    local s3, sum3 = Stages.Build(empty, { prices = PRICES, milestones = MILESTONES, actualSkill = 75 })
    T.eq("an empty path gives no stages", #s3, 0)
    T.check("and no current stage", sum3.currentIndex == nil)
end)

T.section("learn steps and fees", function()
    local A = recipe(1, "A", 1, 40, 50, 60)
    local B = recipe(2, "B", 30, 60, 70, 80, { unlearned = true, sourceInfo = { type = "vendor", cost = 1500 } })
    local C = recipe(3, "C", 60, 80, 90, 100, { unlearned = true, sourceInfo = { type = "ah", price = 700, source = "TSM" } })
    local D = recipe(4, "D", 70, 90, 95, 100, { unlearned = true })   -- pinned, no source
    local path = { targetSkill = 100, steps = {
        step(A, 1, 30, 30, 3000),
        step(B, 30, 35, 5, 1000 + 1500), step(B, 35, 60, 25, 5000),
        step(A, 60, 61, 4, 400),
        step(B, 61, 62, 2, 400),
        step(C, 62, 70, 8, 2400 + 700),
        step(D, 70, 100, 30, 1500),
    }, gaps = {}, totalCost = 15900 }

    local plain, plainSum = Stages.Build(path, { prices = PRICES, milestones = MILESTONES })
    T.eq("without learn steps the list is crafts only", kinds(plain),
        "craft:A:30x craft:B:30x craft:A:4x craft:B:2x craft:C:8x craft:D:30x")
    T.eq("and the fee stays in the craft stage", plain[2].cost, 7500)
    T.eq("total still the path total", plainSum.cost, 15900)

    local stages, summary = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, includeLearn = true })
    T.eq("a learn step before the first stage of each unlearned recipe", kinds(stages),
        "craft:A:30x learn:B craft:B:30x craft:A:4x craft:B:2x learn:C craft:C:8x learn:D craft:D:30x")
    T.eq("craft cost is reagents only", stages[3].cost, 6000)
    T.eq("the learn step carries the fee", stages[2].fee, 1500)
    T.eq("auction recipes carry their price", stages[6].fee, 700)
    T.check("the learn step carries the resolved source", stages[2].sourceInfo.type == "vendor")
    T.eq("learn step sits at the craft stage's start", stages[2].at, 30)
    T.check("a recipe with no resolved source still gets a learn step", stages[8].kind == "learn" and stages[8].sourceInfo == nil)
    T.eq("with no fee", stages[8].fee, 0)
    T.eq("fees are part of the total", summary.cost, 15900)
    T.eq("fees reported", summary.fees, 2200)
    T.eq("pay includes fees (nothing owned)", summary.pay, 15900)
end)

T.section("rank steps", function()
    local A = recipe(1, "A", 1, 400, 410, 420)
    local function path300()
        return { targetSkill = 300, steps = {
            step(A, 140, 145, 5, 500), step(A, 145, 149.5, 5, 500), step(A, 149.5, 154, 5, 500),
            step(A, 154, 224.2, 80, 8000), step(A, 224.2, 226, 2, 200), step(A, 226, 300, 90, 9000),
        }, gaps = {}, totalCost = 18700 }
    end
    local stages = Stages.Build(path300(), { prices = PRICES, milestones = MILESTONES, liveCap = 150 })
    T.eq("a rank step before the first fragment that ends above each cap still to train", kinds(stages),
        "craft:A:10x rank:150 craft:A:85x rank:225 craft:A:92x")
    T.eq("the crossing fragment starts the next stage, a little below the cap", stages[3].from, 149.5)
    T.eq("rank step sits at the cap", stages[2].at, 150)

    T.eq("cap already 300: no rank steps", kinds((Stages.Build(path300(), { prices = PRICES, milestones = MILESTONES, liveCap = 300 }))),
        "craft:A:187x")
    T.eq("cap 225: only the 225 step", kinds((Stages.Build(path300(), { prices = PRICES, milestones = MILESTONES, liveCap = 225 }))),
        "craft:A:95x rank:225 craft:A:92x")
    T.eq("no live cap given: no rank steps", kinds((Stages.Build(path300(), { prices = PRICES, milestones = MILESTONES }))),
        "craft:A:187x")

    local to225 = path300()
    to225.targetSkill = 225
    to225.steps = { to225.steps[1], to225.steps[2], to225.steps[3], step(A, 154, 225, 81, 8100) }
    T.eq("target 225: no rank step at 225", kinds((Stages.Build(to225, { prices = PRICES, milestones = MILESTONES, liveCap = 150 }))),
        "craft:A:10x rank:150 craft:A:86x")

    local from1 = { targetSkill = 300, steps = { step(A, 1, 80, 80, 8000), step(A, 80, 300, 220, 22000) }, gaps = {}, totalCost = 30000 }
    T.eq("a profession not yet learned: the first cap is the live cap", kinds((Stages.Build(from1,
        { prices = PRICES, milestones = MILESTONES, liveCap = Stages.LiveCap(nil, MILESTONES) }))),
        "rank:75 craft:A:80x rank:150 rank:225 craft:A:220x")
    T.eq("LiveCap keeps a real cap", Stages.LiveCap(225, MILESTONES), 225)

    local startAtCap = { targetSkill = 225, steps = { step(A, 150, 225, 75, 7500) }, gaps = {}, totalCost = 7500 }
    T.eq("standing on the cap: the rank step comes first", kinds((Stages.Build(startAtCap,
        { prices = PRICES, milestones = MILESTONES, liveCap = 150 }))), "rank:150 craft:A:75x")

    local gapOverCap = { targetSkill = 225, steps = { step(A, 140, 148, 8, 800), step(A, 160, 225, 65, 6500) },
        gaps = { { from = 148, to = 160, reason = "no recipe" } }, totalCost = 7300 }
    T.eq("a gap that crosses the cap gets the rank step before it", kinds((Stages.Build(gapOverCap,
        { prices = PRICES, milestones = MILESTONES, liveCap = 150 }))), "craft:A:8x rank:150 gap:148-160 craft:A:65x")

    local B = recipe(2, "B", 150, 200, 210, 220, { unlearned = true, sourceInfo = { type = "trainer", cost = 100 } })
    local both = { targetSkill = 225, steps = { step(A, 140, 150, 10, 1000), step(B, 150, 225, 75, 15100) }, gaps = {}, totalCost = 16100 }
    T.eq("rank before learn before the craft stage", kinds((Stages.Build(both,
        { prices = PRICES, milestones = MILESTONES, liveCap = 150, includeLearn = true }))),
        "craft:A:10x rank:150 learn:B craft:B:75x")
end)

T.section("done and current", function()
    local A = recipe(1, "A", 1, 400, 410, 420)
    local B = recipe(2, "B", 30, 400, 410, 420, { unlearned = true, sourceInfo = { type = "vendor", cost = 10 } })
    local path = { targetSkill = 100, steps = {
        step(A, 1, 30, 30, 3000), step(B, 30, 60, 30, 6010), step(A, 60, 100, 40, 4000),
    }, gaps = {}, totalCost = 13010 }
    local opts = { prices = PRICES, milestones = MILESTONES, includeLearn = true, liveCap = 75 }
    local function marks(actual)
        opts.actualSkill = actual
        local stages, summary = Stages.Build(path, opts)
        local out = {}
        for _, s in ipairs(stages) do
            out[#out + 1] = (s.done and "D" or "-") .. (s.current and "*" or "")
        end
        return table.concat(out, " "), summary.currentIndex, stages
    end
    -- stages: craft A, learn B, craft B, rank 75, craft A
    local text, current = marks(1)
    T.eq("at the start nothing is done", text, "-* - - - -")
    T.eq("current is the first stage", current, 1)
    text, current = marks(30)
    T.eq("a craft stage is done once the skill reaches its end; the learn step is current", text, "D -* - - -")
    T.eq("current index follows", current, 2)
    text, current = marks(60)
    T.eq("a learn step is done when the stage after it is done", text, "D D D -* -")
    text, current = marks(100)
    T.eq("everything done at the target", text, "D D D D D")
    T.check("no current stage then", current == nil)
    text = marks(nil)
    T.eq("no real skill: nothing done, first stage current", text, "-* - - - -")
end)

T.section("margin", function()
    local A = recipe(1, "A", 1, 400, 410, 420, { reagents = {
        { itemId = 101, count = 3, name = "Wool" }, { itemId = 104, count = 1, name = "Thread" } } })
    local B = recipe(2, "B", 1, 400, 410, 420)
    local function path()
        return { targetSkill = 75, steps = {
            step(A, 1, 20, 20, 20 * 350), step(A, 20, 42, 21, 21 * 350),
            step(B, 42, 43, 1, 200), step(B, 43, 44, 1, 200), step(B, 44, 45, 1, 200),
        }, gaps = {}, totalCost = 41 * 350 + 600 }
    end
    local base, baseSum = Stages.Build(path(), { prices = PRICES, milestones = MILESTONES })
    local off, offSum = Stages.Build(path(), { prices = PRICES, milestones = MILESTONES, marginPercent = 0 })
    T.eq("margin 0 changes nothing", off[1].quantity, base[1].quantity)
    T.check("no margin: no margin totals", baseSum.marginCost == nil and offSum.marginCost == nil)

    local stages, summary = Stages.Build(path(), { prices = PRICES, milestones = MILESTONES, marginPercent = 15 })
    T.eq("41 crafts with 15 percent is 48", stages[1].quantity, 48)
    T.eq("the expected quantity is kept", stages[1].baseQuantity, 41)
    T.eq("rounded once per stage, not per fragment (3 single crafts)", stages[2].quantity, 4)
    T.eq("reagent needs scale", stages[1].materials[1].need, 144)
    T.eq("cost scales with the quantity", stages[1].cost, 48 * 350)
    T.eq("the recipe is not changed", stages[1].recipe.id, 1)
    T.eq("expected total is still the path total", summary.cost, 41 * 350 + 600)
    T.eq("the with-margin total sits beside it", summary.marginCost, 48 * 350 + 4 * 200)
    T.eq("shopping steps use the stage quantities", Stages.ShoppingSteps(stages)[1].quantity, 48)
    T.eq("shopping step recipe", Stages.ShoppingSteps(stages)[2].recipe.id, 2)
    T.eq("shopping step start", Stages.ShoppingSteps(stages)[2].skillStart, 42)
end)

T.section("materials and inventory", function()
    local A = recipe(1, "A", 1, 400, 410, 420, { reagents = {
        { itemId = 101, count = 2, name = "Wool" }, { itemId = 999, count = 1, name = "Mystery" } } })
    local B = recipe(2, "B", 1, 400, 410, 420, { reagents = { { itemId = 101, count = 1, name = "Wool" } } })
    local path = { targetSkill = 75, steps = { step(A, 1, 11, 10, 2000), step(B, 11, 21, 10, 1000) }, gaps = {}, totalCost = 3000 }
    local stages, summary = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, inventory = { [101] = 25 } })
    local wool = stages[1].materials[1]
    T.eq("need", wool.need, 20)
    T.eq("have", wool.have, 25)
    T.eq("nothing missing", wool.missing, 0)
    T.eq("later stages see what is left", stages[2].materials[1].have, 5)
    T.eq("and miss the rest", stages[2].materials[1].missing, 5)
    T.eq("out-of-pocket cost counts only what is missing", stages[2].outOfPocketCost, 500)
    T.eq("market cost is unchanged by stock", stages[2].cost, 1000)
    local mystery = stages[1].materials[2]
    T.check("a reagent with no price is flagged", mystery.price == nil)
    T.eq("and costs nothing instead of breaking the total", mystery.estimatedCost, 0)
    T.eq("stage cost stays a number", stages[1].cost, 2000)
    T.eq("pay total", summary.pay, 500)
    T.eq("names fall back to the recipe data", wool.name, "Wool")
end)

T.section("colours", function()
    local A = recipe(1, "A", 100, 120, 130, 140)
    local path = { targetSkill = 150, steps = { step(A, 110, 135, 40, 4000) }, gaps = {}, totalCost = 4000 }
    local stages = Stages.Build(path, { prices = PRICES, milestones = MILESTONES })
    T.eq("colour at the stage start", stages[1].color, "orange")
    T.eq("where it changes", Text.ColorChanges(stages[1]), "orange until 120, yellow until 130, then green")
    local shifted = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, racialBonus = 15 })
    T.eq("a racial bonus moves the thresholds", Text.ColorChanges(shifted[1]), "orange all the way")
    local short = { targetSkill = 150, steps = { step(A, 100, 110, 10, 1000) }, gaps = {}, totalCost = 1000 }
    T.eq("no change inside the stage", Text.ColorChanges((Stages.Build(short, { prices = PRICES, milestones = MILESTONES }))[1]),
        "orange all the way")
    -- Learned at 165, after its yellow threshold (160): never orange.
    local B = recipe(2, "B", 165, 160, 180, 200)
    local late = { targetSkill = 200, steps = { step(B, 165, 190, 40, 4000) }, gaps = {}, totalCost = 4000 }
    local lateStages = Stages.Build(late, { prices = PRICES, milestones = MILESTONES })
    T.eq("a recipe learned above yellow starts yellow", lateStages[1].color, "yellow")
    T.eq("and only turns green", Text.ColorChanges(lateStages[1]), "yellow until 180, then green")
end)

T.section("alternatives and pins", function()
    local A = recipe(1, "A", 1, 400, 410, 420)
    local B = recipe(2, "B", 1, 400, 410, 420, { unlearned = true, sourceInfo = { type = "vendor", cost = 1000 } })
    local C = recipe(3, "C", 1, 400, 410, 420)
    C._isUnavailable = true
    C._unavailableReason = "Needs Alchemy"
    local alts = {
        { recipe = A, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = B, score = 2, color = "orange", expectedSkillups = 0.5, craftCost = 200 },
        { recipe = C, score = math.huge, color = "orange", expectedSkillups = 1, craftCost = 300 },
    }
    local path = { targetSkill = 75, steps = { step(A, 1, 11, 10, 1000, { alternatives = alts }), step(A, 11, 21, 10, 1000) },
        gaps = {}, totalCost = 2000 }
    local pins = {}
    LazyProf.Pins.Add(pins, 1, 21, 1)
    local stages = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, pins = pins, inventory = { [102] = 5 } })
    local st = stages[1]
    T.eq("the stage's own recipe is not an alternative", #st.alternatives, 2)
    local b = st.alternatives[1]
    T.eq("alternatives come from the first fragment", b.recipe.id, 2)
    T.eq("crafts projected over the stage's range", b.projectedCrafts, 40)
    T.eq("crafts delta against the stage", b.craftsDelta, 20)
    T.eq("projected cost uses owned stock and adds the recipe fee", b.projectedCost, (40 - 5) * 200 + 1000)
    T.eq("cost delta against what the stage costs you", b.costDelta, (40 - 5) * 200 + 1000 - 2000)
    T.check("an unavailable alternative stays, flagged", st.alternatives[2].unavailable == true)
    T.eq("with its reason", st.alternatives[2].reason, "Needs Alchemy")
    T.check("pinned stage is marked", st.pinned == true)
    T.check("without pins it is not", not Stages.Build(path, { prices = PRICES, milestones = MILESTONES })[1].pinned)
end)

T.section("range filter", function()
    local brackets = LazyProf.Utils.BuildSkillBrackets(MILESTONES)
    T.eq("current range from the real skill", Range.Effective(nil, brackets, 143).name, "75-150")
    T.eq("a chosen range", Range.Effective(3, brackets, 143).name, "150-225")
    T.check("full path has no range", Range.Effective("all", brackets, 143) == nil)
    T.check("skill past every range: no range", Range.Effective(nil, brackets, 300) == nil)
    T.eq("label for the current range", Range.Label(nil, brackets, 143), "Current (75-150)")
    T.eq("label for a chosen range", Range.Label(2, brackets, 143), "75-150")
    T.eq("label for the full path", Range.Label("all", brackets, 143), "Full path")
    local options = Range.Options(nil, brackets)
    T.eq("options: current, each range, full path", #options, 6)
    T.check("the selected option is checked", options[1].checked and not options[2].checked)
    T.eq("option values", tostring(options[1].value) .. "," .. tostring(options[3].value) .. "," .. tostring(options[6].value),
        "current,2,all")
    T.check("picking current selects nil", Range.FromValue("current") == nil)
    T.eq("picking a range selects its index", Range.FromValue(2), 2)

    local A = recipe(1, "A", 1, 400, 410, 420)
    local B = recipe(2, "B", 150, 400, 410, 420, { unlearned = true, sourceInfo = { type = "vendor", cost = 5 } })
    local path = { targetSkill = 300, steps = {
        step(A, 140, 149.5, 10, 1000), step(A, 149.5, 160, 11, 1100),
        step(B, 160, 220, 60, 12005), step(B, 220, 230, 10, 2000),
    }, gaps = { { from = 230, to = 300, reason = "no recipe" } }, totalCost = 16105 }
    local stages = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, liveCap = 150, includeLearn = true })
    T.eq("all stages", kinds(stages), "craft:A:10x rank:150 craft:A:11x learn:B craft:B:60x rank:225 craft:B:10x gap:230-300")
    T.eq("a stage belongs to the range its start is in; a rank step to the range it caps",
        kinds(Range.FilterStages(stages, brackets[2])), "craft:A:10x rank:150 craft:A:11x")
    T.eq("a learn step follows its craft stage", kinds(Range.FilterStages(stages, brackets[3])),
        "learn:B craft:B:60x rank:225 craft:B:10x")
    T.eq("gaps by their start", kinds(Range.FilterStages(stages, brackets[4])), "gap:230-300")
    T.eq("no range: everything", #Range.FilterStages(stages, nil), #stages)
    local totals = Stages.Totals(Range.FilterStages(stages, brackets[3]))
    T.eq("range totals include the range's fees", totals.cost, 14005)
end)

-- The real planner's output for one shipped case, folded into stages.
T.section("stage snapshot", function()
    local CraftLib = harness.loadCraftLib(16001, { camelot = true })
    local LP = harness.loadLazyProf(FILES)
    LP.Client = { GetItemInfo = function() return nil end }   -- the Forever adapter is not loaded here
    local prof = CraftLib:GetProfession("tailoring")
    local recipes = LP.Utils.DeepCopy(prof.recipes)
    for _, r in ipairs(recipes) do r.learned = false end
    local prices = harness.priceTable(recipes)
    LP.db.profile.strategy = "cheapest"
    LP.RecipeAvailability:BeginRecalc()
    LP.SelfFound:BeginRecalc({})
    local steps, meta = LP.PathfinderStrategies.cheapest:Calculate(1, 300, recipes, {}, prices, 0, {})
    LP.SelfFound:EndRecalc()
    LP.RecipeAvailability:EndRecalc()
    local total = 0
    for _, s in ipairs(steps) do total = total + s.totalCost end
    local path = { targetSkill = 300, steps = steps, gaps = meta.gaps, totalCost = total }
    local stages, summary = LP.Stages.Build(path, { prices = prices, milestones = prof.milestones,
        liveCap = LP.Stages.LiveCap(nil, prof.milestones), includeLearn = true, actualSkill = 1 })
    T.eq("stage costs and fees add up to the path total", summary.cost, total)
    T.check("fewer stages than fragments", #stages < #steps, #stages .. " vs " .. #steps)

    local lines = {}
    for _, s in ipairs(stages) do
        if s.kind == "craft" then
            lines[#lines + 1] = string.format("%.2f-%.2f craft %s x%d %s %s%s", s.from, s.to, tostring(s.recipe.id),
                s.quantity, tostring(s.cost), s.color, s.bridge and " bridge" or "")
        elseif s.kind == "learn" then
            lines[#lines + 1] = string.format("%d learn %s %s %s", s.at, tostring(s.recipe.id),
                s.sourceInfo and s.sourceInfo.type or "none", tostring(s.fee))
        elseif s.kind == "rank" then
            lines[#lines + 1] = string.format("%d rank", s.cap)
        else
            lines[#lines + 1] = string.format("%.2f-%.2f gap %s", s.from, s.to, tostring(s.reason))
        end
    end
    local text = table.concat(lines, "\n") .. "\n"
    local file = "scripts/snapshots/stages_forever_tailoring_1_300_cheapest.txt"
    if os.getenv("UPDATE_SNAPSHOTS") == "1" then
        local f = assert(io.open(file, "w"))
        f:write(text)
        f:close()
        T.check("stage snapshot written", true)
    else
        local f = io.open(file, "r")
        local expected = f and f:read("*a")
        if f then f:close() end
        T.check("stage snapshot", expected == text, expected and ("expected:\n" .. expected .. "got:\n" .. text) or "missing snapshot")
    end
end)

T.finish()
