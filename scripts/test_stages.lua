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
    "Modules/Guide/Stages.lua",
}

harness.stubWow({ interface = 11508 })
local LazyProf = harness.loadLazyProf(FILES)
local Stages, Text = LazyProf.Stages, LazyProf.GuideText

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

-- A run that uses what an earlier run of the path made takes those crafts
-- first; the crafts used that way are not sold (ruling P118). Bolts (item
-- 500) from 3 Cloth each, 12 of them; then 5 Shirts of 2 Bolts and a Thread.
T.section("a run uses what an earlier run made", function()
    local BOLT, CLOTH, THREAD = 500, 501, 502
    local prices = { [BOLT] = 400, [CLOTH] = 100, [THREAD] = 10 }
    local bolts = recipe(1, "Bolt", 1, 400, 410, 420, { reagents = { { itemId = CLOTH, count = 3, name = "Cloth" } } })
    bolts.itemId = BOLT
    local shirt = recipe(2, "Shirt", 1, 400, 410, 420, { reagents = {
        { itemId = BOLT, count = 2, name = "Bolt" }, { itemId = THREAD, count = 1, name = "Thread" } } })
    local function path(first, second)
        return { targetSkill = 75, steps = { first, second }, gaps = {}, totalCost = 0 }
    end
    local sale = { [1] = 40, [2] = 30 }

    local stages, totals = Stages.Build(path(step(bolts, 1, 13, 12, 0), step(shirt, 13, 18, 5, 0)),
        { prices = prices, sale = sale, inventory = { [THREAD] = 2 } })
    local b, s = stages[1], stages[2]
    T.eq("the shirts' bolts: 10 needed", s.materials[1].need, 10)
    T.eq("all of them made by the bolt run", s.materials[1].made, 10)
    T.eq("so none is missing", s.materials[1].missing, 0)
    T.eq("the thread: 2 owned, 3 missing", s.materials[2].missing, 3)
    T.eq("the shirts pay for the thread only", s.outOfPocketCost, 3 * 10)
    T.eq("the market cost still prices every bolt", s.cost, 10 * 400 + 5 * 10)
    T.eq("10 bolts are used later", b.usedLater, 10)
    T.eq("only the 2 left over are sold", b.sale, 2 * 40)
    T.eq("the shirts sell as before", s.sale, 5 * 30)
    T.eq("the totals sell 2 bolts and 5 shirts", totals.shownSale, 2 * 40 + 5 * 30)
    T.eq("the expected quantities too", totals.sale, 2 * 40 + 5 * 30)

    -- Made after the shirts: no help to them, every bolt is sold.
    stages = Stages.Build(path(step(shirt, 1, 6, 5, 0), step(bolts, 6, 18, 12, 0)), { prices = prices, sale = sale })
    T.eq("bolts made later: the shirts buy theirs", stages[1].materials[1].missing, 10)
    T.eq("and every bolt is sold", stages[2].sale, 12 * 40)

    -- Too few made: the rest is missing, and nothing of the bolt run is sold.
    stages = Stages.Build(path(step(bolts, 1, 5, 4, 0), step(shirt, 5, 10, 5, 0)), { prices = prices, sale = sale })
    T.eq("4 bolts made, 6 missing", stages[2].materials[1].missing, 6)
    T.eq("no bolt left to sell", stages[1].sale, 0)

    -- With the margin the shown pass makes and uses the spare crafts.
    stages = Stages.Build(path(step(bolts, 1, 13, 12, 0), step(shirt, 13, 18, 5, 0)),
        { prices = prices, sale = sale, marginPercent = 50 })
    T.eq("margin: 18 bolts made, 16 used by 8 shirts", stages[1].usedLater, 16)
    T.eq("margin: 2 spare bolts sold", stages[1].sale, 2 * 40)
    T.eq("margin: the expected pass sells 2 bolts too", stages[1].baseSale, 2 * 40)
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
    -- B turns yellow at 11 and green at 21: the run's twenty points take it 24 crafts.
    local B = recipe(2, "B", 1, 11, 21, 31, { unlearned = true, sourceInfo = { type = "vendor", cost = 1000 } })
    local C = recipe(3, "C", 1, 400, 410, 420)
    C._isUnavailable = true
    C._unavailableReason = "Needs Alchemy"
    local alts = {
        { recipe = A, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = B, score = 2, color = "orange", expectedSkillups = 1, craftCost = 200 },
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
    T.eq("crafts projected over the stage's range", b.projectedCrafts, 24)
    T.eq("crafts delta against the stage", b.craftsDelta, 4)
    T.eq("projected cost uses owned stock and adds the recipe fee", b.projectedCost, (24 - 5) * 200 + 1000)
    T.eq("cost delta against what the stage costs you", b.costDelta, (24 - 5) * 200 + 1000 - 2000)
    T.check("an unavailable alternative stays, flagged", st.alternatives[2].unavailable == true)
    T.eq("with its reason", st.alternatives[2].reason, "Needs Alchemy")
    T.check("pinned stage is marked", st.pinned == true)
    T.check("without pins it is not", not Stages.Build(path, { prices = PRICES, milestones = MILESTONES })[1].pinned)
end)

-- An alternative's crafts are counted the way the planner counts a run:
-- craft by craft, each craft moving the skill by its chance at that skill.
T.section("an alternative's crafts over the run", function()
    -- The rule, written out.
    local function crafts(r, from, to, bonus)
        local n, skill = 0, from
        while skill < to - 1e-6 do
            local chance = LazyProf.Utils.GetSkillUpChance(skill - (bonus or 0), r.skillRange)
            if chance <= 0 or n >= 1000 then return n, false end
            n = n + 1
            skill = skill + chance
        end
        return n, true
    end
    local function alt(r, color) return { recipe = r, score = 1, color = color or "orange", expectedSkillups = 1, craftCost = 0 } end
    local function byId(stage, id)
        for i, a in ipairs(stage.alternatives) do
            if a.recipe.id == id then return a, i end
        end
    end

    -- A run of ten crafts from 5 to 15, and what else could do those points.
    local A = recipe(1, "A", 1, 400, 410, 420)
    -- Orange until 10, grey at 20: five crafts to 10, then a craft moves the
    -- skill by 1, 0.9, 0.81, ... - seven more to pass 15.
    local Fades = recipe(2, "Fades", 1, 10, 15, 20, { reagents = { { itemId = 101, count = 1, name = "MatA" } } })
    -- Grey at 12: it never gets to 15. Half the price a craft.
    local Greys = recipe(3, "Greys", 1, 8, 10, 12, { reagents = { { itemId = 104, count = 1, name = "Cheap" } } })
    -- Grey before the run starts.
    local Dead = recipe(4, "Dead", 1, 2, 3, 4, { reagents = { { itemId = 104, count = 1, name = "Cheap" } } })
    local path = { targetSkill = 75, gaps = {}, totalCost = 1000,
        steps = { step(A, 5, 15, 10, 1000, { alternatives = { alt(A), alt(Greys), alt(Dead, "gray"), alt(Fades) } }) } }
    local st = Stages.Build(path, { prices = PRICES, milestones = MILESTONES })[1]
    local fades, at = byId(st, 2)
    T.eq("crafts: five while orange, then seven as the chance falls", fades.projectedCrafts, 12)
    T.eq("the rule written out agrees", fades.projectedCrafts, (crafts(Fades, 5, 15)))
    T.eq("two crafts more than the run", fades.craftsDelta, 2)
    T.eq("the cost of those crafts", fades.projectedCost, 1200)
    T.eq("dearer by the two crafts", fades.costDelta, 200)
    T.check("it covers the run", fades.covers == true and fades.coversTo == nil)
    T.eq("the one that covers the run comes first, although another is cheaper a craft", at, 1)

    local greys = byId(st, 3)
    T.check("one that goes grey inside the run is marked", greys.covers == false)
    T.eq("with the skill it gets to", greys.coversTo, 12)
    T.check("and has no differences: they would compare unlike things",
        greys.craftsDelta == nil and greys.costDelta == nil and greys.projectedCrafts == nil and greys.projectedCost == nil)
    T.check("its reagents are still known to be priced", greys.priced == true)
    local dead = byId(st, 4)
    T.check("one that is grey from the start covers nothing", dead.covers == false and dead.coversTo == 5)
    T.eq("further reach first among those that do not cover the run", st.alternatives[2].recipe.id, 3)

    -- A racial bonus moves the thresholds: grey at 27 now.
    st = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, racialBonus = 15 })[1]
    greys = byId(st, 3)
    T.check("racial bonus: the same recipe covers the run", greys.covers == true)
    T.eq("racial bonus: in ten crafts", greys.projectedCrafts, 10)
    T.eq("racial bonus: at half the cost", greys.costDelta, -500)

    -- The margin is applied to the counted crafts.
    st = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, marginPercent = 15 })[1]
    T.eq("margin: on the counted crafts", byId(st, 2).projectedCrafts, 14)
    T.eq("margin: against the run's own", byId(st, 2).craftsDelta, 14 - 12)

    -- A twin of the run's recipe (same thresholds, same reagent), with the
    -- run planned by the planner itself across a colour change: the same
    -- crafts and the same cost, not fewer because it starts orange.
    local R = recipe(5, "R", 1, 10, 15, 20, { reagents = { { itemId = 101, count = 1, name = "MatA" } } })
    local Twin = recipe(6, "Twin", 1, 10, 15, 20, { reagents = { { itemId = 101, count = 1, name = "MatA" } } })
    LazyProf.db.profile.strategy = "cheapest"
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc({})
    local steps, meta = LazyProf.PathfinderStrategies.cheapest:Calculate(5, 15, { R, Twin }, {}, PRICES, 0, {})
    LazyProf.SelfFound:EndRecalc()
    LazyProf.RecipeAvailability:EndRecalc()
    local planned = Stages.Build({ targetSkill = 15, steps = steps, gaps = meta.gaps }, { prices = PRICES, milestones = MILESTONES })
    local crossed, twins = false, 0
    for _, stage in ipairs(planned) do
        if stage.kind == "craft" then
            if #stage.colorChanges > 0 then crossed = true end
            local other = byId(stage, stage.recipe.id == 5 and 6 or 5)
            if other then
                twins = twins + 1
                T.eq("twin over " .. stage.fromDisplay .. "-" .. stage.toDisplay .. ": the same crafts", other.craftsDelta, 0)
                T.eq("twin over " .. stage.fromDisplay .. "-" .. stage.toDisplay .. ": the same cost", other.costDelta, 0)
            end
        end
    end
    T.check("the planned run passes a colour change", crossed)
    T.check("and its twin was compared", twins > 0, twins)
    T.eq("the planner's own count is the rule's", planned[1].baseQuantity, (crafts(R, planned[1].from, planned[1].to)))
end)

T.section("alternatives with the margin on", function()
    -- A twin of the stage's recipe: same reagent price, same chance. With the
    -- margin on, both sides carry it, so the twin costs the same.
    local A = recipe(1, "A", 1, 400, 410, 420)
    local Twin = recipe(2, "Twin", 1, 400, 410, 420, { reagents = { { itemId = 101, count = 1, name = "MatA" } } })
    local alts = {
        { recipe = A, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = Twin, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
    }
    local path = { targetSkill = 75, steps = { step(A, 1, 21, 20, 2000, { alternatives = alts }) }, gaps = {}, totalCost = 2000 }
    local stages = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, marginPercent = 15,
        sale = { [1] = 10, [2] = 10 } })
    local st, twin = stages[1], stages[1].alternatives[1]
    T.eq("fixture: the stage has 23 crafts with the margin", st.quantity, 23)
    T.eq("the alternative is projected with the same margin", twin.projectedCrafts, 23)
    T.eq("same crafts", twin.craftsDelta, 0)
    T.eq("same cost", twin.costDelta, 0)
    T.eq("its sale counts the margin's crafts too", twin.projectedSale, 230)

    stages = Stages.Build(path, { prices = PRICES, milestones = MILESTONES })
    T.eq("margin off: projected as before", stages[1].alternatives[1].projectedCrafts, 20)
    T.eq("margin off: same cost", stages[1].alternatives[1].costDelta, 0)
end)

T.section("what crafts sell for", function()
    local prices = { [101] = 100, [102] = 120, [103] = 300 }
    local A = recipe(1, "A", 1, 400, 410, 420)   -- 100 a craft
    local B = recipe(2, "B", 1, 400, 410, 420)   -- 120 a craft: 200 more over ten crafts
    local C = recipe(3, "C", 1, 400, 410, 420)   -- 300 a craft
    local alts = {
        { recipe = A, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = C, score = 3, color = "orange", expectedSkillups = 1, craftCost = 300 },
        { recipe = B, score = 2, color = "orange", expectedSkillups = 1, craftCost = 120 },
    }
    local function path(extra)
        local p = { targetSkill = 75, steps = { step(A, 1, 11, 10, 1000, { alternatives = alts }) }, gaps = {}, totalCost = 1000 }
        for k, v in pairs(extra or {}) do p[k] = v end
        return p
    end
    local sale = { [1] = 45, [2] = 75, [3] = 10 }   -- B sells for 30 more than A

    local stages, summary = Stages.Build(path(), { prices = prices, milestones = MILESTONES, sale = sale })
    local st = stages[1]
    T.eq("what one craft sells for", st.saleEach, 45)
    T.eq("ten crafts", st.sale, 450)
    T.eq("the expected amount", st.baseSale, 450)
    T.eq("totals: what comes back", summary.sale, 450)
    T.eq("totals: net is pay less sale", summary.net, summary.pay - 450)
    T.eq("totals: the cost column", summary.columnPay, 1000)
    T.eq("totals: the sale shown", summary.shownSale, 450)
    T.check("no margin: no margin sale", summary.marginSale == nil and summary.marginNet == nil)

    local b = st.alternatives[1]
    T.eq("the alternative that nets less comes first", b.recipe.id, 2)
    T.eq("its sale value", b.saleEach, 75)
    T.eq("its sale over the run", b.projectedSale, 750)
    T.eq("its net over the run", b.projectedNet, 1200 - 750)
    T.eq("200 more in reagents, 300 more back: 100 cheaper for the player", b.costDelta, -100)
    T.eq("the dear one stays last", st.alternatives[2].recipe.id, 3)
    T.eq("its difference counts its small sale", st.alternatives[2].costDelta, (3000 - 100) - (1000 - 450))

    -- Dearer to make but nets less: it comes before a cheaper one that sells for nothing.
    local D = recipe(4, "D", 1, 400, 410, 420, { reagents = { { itemId = 103, count = 1, name = "Silk" } } })   -- 300 a craft
    local E = recipe(5, "E", 1, 400, 410, 420, { reagents = { { itemId = 102, count = 1, name = "Wool" } } })   -- 120 a craft
    local netAlts = {
        { recipe = A, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = E, score = 2, color = "orange", expectedSkillups = 1, craftCost = 120 },
        { recipe = D, score = 3, color = "orange", expectedSkillups = 1, craftCost = 300 },
    }
    local netPath = { targetSkill = 75, steps = { step(A, 1, 11, 10, 1000, { alternatives = netAlts }) }, gaps = {}, totalCost = 1000 }
    local netStages = Stages.Build(netPath, { prices = prices, milestones = MILESTONES, sale = { [1] = 45, [4] = 290 } })
    T.eq("ordered by net: the dear one that sells well first", netStages[1].alternatives[1].recipe.id, 4)
    T.eq("its net over the run", netStages[1].alternatives[1].projectedNet, 3000 - 2900)
    T.eq("then the cheap one that sells for nothing", netStages[1].alternatives[2].recipe.id, 5)

    -- The margin: more crafts, more sold.
    stages, summary = Stages.Build(path(), { prices = prices, milestones = MILESTONES, sale = sale, marginPercent = 15 })
    T.eq("with 15 percent: twelve crafts sold", stages[1].sale, 540)
    T.eq("the expected amount stays", stages[1].baseSale, 450)
    T.eq("totals: expected sale", summary.sale, 450)
    T.eq("totals: sale with the margin", summary.marginSale, 540)
    T.eq("totals: net with the margin", summary.marginNet, summary.marginPay - 540)
    T.eq("totals: the sale shown is the margin's", summary.shownSale, 540)
    T.eq("totals: the cost column is the margin's", summary.columnPay, 1200)

    -- The path's own sale values are the default.
    stages = Stages.Build(path({ sale = { values = sale } }), { prices = prices, milestones = MILESTONES })
    T.eq("sale values come with the path", stages[1].sale, 450)

    -- None given: nothing is sold and alternatives compare costs as before.
    stages, summary = Stages.Build(path(), { prices = prices, milestones = MILESTONES })
    T.eq("no sale values: nothing sold", stages[1].sale, 0)
    T.eq("no sale values: totals", summary.sale, 0)
    T.eq("no sale values: net is what is paid", summary.net, summary.pay)
    T.eq("no sale values: the cheaper-to-make alternative first", stages[1].alternatives[1].recipe.id, 2)
    T.eq("no sale values: its difference is the cost difference", stages[1].alternatives[1].costDelta, 200)

    -- A fee kept inside the craft stage is not part of the cost column.
    local D = recipe(4, "D", 1, 400, 410, 420, { unlearned = true, sourceInfo = { type = "vendor", cost = 700 },
        reagents = { { itemId = 101, count = 1, name = "Wool" } } })
    local feePath = { targetSkill = 75, steps = { step(D, 1, 11, 10, 1700) }, gaps = {}, totalCost = 1700 }
    local _, feeSum = Stages.Build(feePath, { prices = prices, milestones = MILESTONES })
    T.eq("fee inside the stage: pay includes it", feeSum.pay, 1700)
    T.eq("fee inside the stage: the cost column does not", feeSum.columnPay, 1000)
end)

-- Costs are whole copper where they are produced, and sums add up the
-- rounded values: what is shown can then be added up to the copper.
T.section("whole copper", function()
    local A = recipe(1, "A", 1, 400, 410, 420, { reagents = {
        { itemId = 201, count = 3, name = "Grain" }, { itemId = 202, count = 1, name = "Oil" } } })
    local B = recipe(2, "B", 1, 400, 410, 420, { unlearned = true, sourceInfo = { type = "ah", price = 12.5 },
        reagents = { { itemId = 201, count = 1, name = "Grain" } } })
    local prices = { [201] = 0.4, [202] = 33.3 }
    local alts = { { recipe = A, score = 1, color = "orange", expectedSkillups = 1 }, { recipe = B, score = 2, color = "orange", expectedSkillups = 1 } }
    local path = { targetSkill = 75, gaps = {}, totalCost = 0,
        steps = { step(A, 1, 4, 3, 0, { alternatives = alts }), step(B, 4, 11, 7, 0) } }
    local stages, summary = Stages.Build(path, { prices = prices, milestones = MILESTONES, includeLearn = true })
    local a, learn, b = stages[1], stages[2], stages[3]
    -- 9 Grain at 0.4 is 3.6, 3 Oil at 33.3 is 99.9.
    T.eq("a reagent's cost is whole copper", a.materials[1].estimatedCost, 4)
    T.eq("the other", a.materials[2].estimatedCost, 100)
    T.eq("the run's cost is the sum of its reagents' costs", a.outOfPocketCost, 104)
    T.eq("so is its market cost", a.cost, 104)
    T.eq("a recipe's price is whole copper", learn.fee, 13)
    T.eq("7 Grain at 0.4 is 2.8", b.outOfPocketCost, 3)
    T.eq("the cost column is the sum of the runs", summary.columnPay, 107)
    T.eq("the totals add up the same whole amounts", summary.pay, 107 + 13)
    local alt = a.alternatives[1]
    T.eq("an alternative's cost is whole copper too (3 Grain: 1.2, and the recipe)", alt.projectedCost, 1 + 13)

    -- With stock: 4 Grain owned, 5 to buy at 0.4.
    stages = Stages.Build(path, { prices = prices, milestones = MILESTONES, includeLearn = true, inventory = { [201] = 4 } })
    T.eq("stock: what is left to buy, rounded", stages[1].materials[1].estimatedCost, 2)
    T.eq("stock: the run", stages[1].outOfPocketCost, 102)
    T.eq("stock: its market cost is unchanged", stages[1].cost, 104)
end)

T.section("stage order and part totals", function()
    local A = recipe(1, "A", 1, 400, 410, 420)
    local B = recipe(2, "B", 150, 400, 410, 420, { unlearned = true, sourceInfo = { type = "vendor", cost = 5 } })
    local path = { targetSkill = 300, steps = {
        step(A, 140, 149.5, 10, 1000), step(A, 149.5, 160, 11, 1100),
        step(B, 160, 220, 60, 12005), step(B, 220, 230, 10, 2000),
    }, gaps = { { from = 230, to = 300, reason = "no recipe" } }, totalCost = 16105 }
    local stages = Stages.Build(path, { prices = PRICES, milestones = MILESTONES, liveCap = 150, includeLearn = true })
    T.eq("all stages", kinds(stages), "craft:A:10x rank:150 craft:A:11x learn:B craft:B:60x rank:225 craft:B:10x gap:230-300")
    -- Totals of a part of the path count the learn steps in it.
    local totals = Stages.Totals({ stages[4], stages[5], stages[6], stages[7] })
    T.eq("totals of a part include its fees", totals.cost, 14005)
end)

-- The Crafts tab names the earlier run a reagent comes from and shows the
-- crafted item's icon: the stages carry both.
T.section("who made a reagent, and the run's icon", function()
    local maker = recipe(70, "Maker", 100, 120, 130, 140, { reagents = { { itemId = 171, count = 1, name = "Raw" } } })
    maker.itemId = 170
    local user = recipe(71, "User", 110, 130, 140, 150, { reagents = { { itemId = 170, count = 1, name = "Made" } } })
    local path = { targetSkill = 125, steps = { step(maker, 100, 110, 10, 0), step(user, 110, 125, 15, 0) },
                   gaps = {}, totalCost = 0 }
    local stages = Stages.Build(path, { prices = { [170] = 10, [171] = 5 }, milestones = MILESTONES, inventory = {} })
    local first, second
    for _, s in ipairs(stages) do
        if s.kind == "craft" and s.recipe == maker then first = s end
        if s.kind == "craft" and s.recipe == user then second = s end
    end
    local made = second.materials[1]
    T.check("made by run 1", made.madeBy ~= nil and made.madeBy[1] == first and #made.madeBy == 1)
    T.eq("ten of fifteen from the path", made.made, 10)
    T.eq("five missing", made.missing, 5)
    T.check("nothing made for run 1's reagent", first.materials[1].madeBy == nil)
    T.eq("icon of an item not loaded yet", first.icon, "Interface\\Icons\\INV_Misc_QuestionMark")
    T.check("and the run says its icon is still missing", first.iconMissing == true)
    T.check("no item, no icon", second.icon == nil)
    T.check("and nothing missing", second.iconMissing == nil)
    -- Once the item's data is there, its own icon and nothing missing.
    local savedClient = LazyProf.Client
    LazyProf.Client = setmetatable({ GetItemInfo = function(_, itemId)
        if itemId == 170 then return "Made", "link", nil, nil, nil, nil, nil, nil, nil, "Interface\\Icons\\Made" end
        return nil
    end }, { __index = savedClient })
    stages = Stages.Build(path, { prices = { [170] = 10, [171] = 5 }, milestones = MILESTONES, inventory = {} })
    LazyProf.Client = savedClient
    for _, s in ipairs(stages) do
        if s.kind == "craft" and s.recipe == maker then first = s end
    end
    T.eq("loaded: the item's icon", first.icon, "Interface\\Icons\\Made")
    T.check("loaded: nothing missing", first.iconMissing == nil)
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
