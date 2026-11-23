-- scripts/test_views.lua
--
-- What the LazyProf window shows, checked as data: the header lines, the
-- footer totals, the Steps tab's rows, the "nothing left" states and the
-- recipe search. No frames are involved.
--
-- Run from the addon root:  lua5.1 scripts/test_views.lua

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
    "Modules/Pathfinder/Pins.lua",
    "Modules/Guide/Text.lua",
    "Modules/Guide/Range.lua",
    "Modules/Guide/Stages.lua",
    "Modules/Guide/Views.lua",
})
local Stages, Views, Range = LazyProf.Stages, LazyProf.GuideViews, LazyProf.GuideRange
local MILESTONES = { 75, 150, 225, 300 }
local BRACKETS = LazyProf.Utils.BuildSkillBrackets(MILESTONES)
local PRICES = { [101] = 100, [102] = 200, [103] = 300 }

local function recipe(id, name, orange, yellow, green, gray, opts)
    opts = opts or {}
    return {
        id = id, name = name, learned = not opts.unlearned, skillRequired = opts.required or orange,
        skillRange = { orange = orange, yellow = yellow, green = green, gray = gray },
        reagents = opts.reagents or { { itemId = 100 + id, count = 1, name = "Mat" .. name } },
        _sourceInfo = opts.sourceInfo,
    }
end
local function step(r, from, to, quantity, cost, extra)
    local s = { recipe = r, skillStart = from, skillEnd = to, quantity = quantity, totalCost = cost, alternatives = {} }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

local A = recipe(1, "Gloves", 100, 150, 160, 170)
local B = recipe(2, "Shirt", 150, 200, 210, 220)
local C = recipe(3, "Mystery", 200, 250, 260, 270, { reagents = { { itemId = 999, count = 2, name = "Odd Dust" } } })

local function makePath(extra)
    local path = {
        profession = "Tailoring", professionKey = "tailoring", hasProfession = true,
        currentSkill = 143, actualSkill = 143, targetSkill = 300, capSkill = 300, racialBonus = 0,
        milestones = MILESTONES, prices = PRICES, complete = false,
        steps = {
            step(A, 143, 150, 7, 700), step(A, 150, 160, 12, 1200),
            step(B, 160, 180, 20, 4000, { bridge = true }),
            step(C, 200, 230, 30, 0),
        },
        gaps = { { from = 180, to = 200, reason = "no recipe" }, { from = 230, to = 300, reason = "no recipe" } },
        totalCost = 5900,
    }
    for k, v in pairs(extra or {}) do path[k] = v end
    return path
end

-- The view the window computes.
local function makeView(path, opts)
    opts = opts or {}
    local stages, summary = Stages.Build(path, { inventory = opts.inventory, marginPercent = opts.margin })
    local bracket = Range.Effective(opts.range, BRACKETS, path.actualSkill)
    local rangeStages = Range.FilterStages(stages, bracket)
    return {
        path = path, stages = stages, summary = summary,
        rangeStages = rangeStages, rangeTotals = Stages.Totals(rangeStages),
        bracket = bracket, rangeLabel = Range.Label(opts.range, BRACKETS, path.actualSkill),
        skill = path.actualSkill, cap = opts.cap,
        priceSummary = opts.priceSummary, priceLines = opts.priceLines,
        marginPercent = opts.margin, expanded = opts.expanded or {},
    }
end

T.section("header", function()
    local h = Views.Header(makeView(makePath(), { cap = 150 }))
    T.eq("title names the profession", h.title, "LazyProf - Tailoring")
    T.eq("status: skill and cap", h.status, "Skill 143 / 150")
    T.eq("status: no cap known", Views.Header(makeView(makePath())).status, "Skill 143")
    T.eq("status: racial bonus", Views.Header(makeView(makePath({ racialBonus = 15 }), { cap = 150 })).status,
        "Skill 143 / 150 (+15 racial)")
    T.eq("status: not learned", Views.Header(makeView(makePath({ hasProfession = false, actualSkill = 1 }))).status,
        "Not learned yet - planned from skill 1")
    T.eq("status: what-if from 1", Views.Header(makeView(makePath({ planFromOne = true }), { cap = 150 })).status,
        "Skill 143 / 150 - planned from skill 1")

    local lines = { { text = "Prices: TSM 2, vendor 1", r = 0.6, g = 0.6, b = 0.6 }, { text = "more" } }
    h = Views.Header(makeView(makePath(), { priceLines = lines, priceSummary = { total = 3, stale = 0, unpriced = 0, loading = 0 } }))
    T.eq("price line is the summary's first line", h.priceText, "Prices: TSM 2, vendor 1")
    T.eq("price line is grey when all is well", h.priceColor[1], 0.7)
    T.eq("the tooltip carries every summary line", #h.priceTooltip, 2)
    h = Views.Header(makeView(makePath(), { priceLines = lines, priceSummary = { total = 3, stale = 2, unpriced = 0, loading = 0 } }))
    T.check("price line turns orange when prices are stale", h.priceColor[1] == 1 and h.priceColor[2] == 0.5)
    h = Views.Header(makeView(makePath(), { priceLines = lines, priceSummary = { total = 3, stale = 0, unpriced = 1, loading = 0 } }))
    T.check("and when a reagent has no price", h.priceColor[2] == 0.5)
    T.eq("no price lines: empty text", Views.Header(makeView(makePath())).priceText, "")
    T.eq("no path: bare title", Views.Header({}).title, "LazyProf")
end)

T.section("footer", function()
    local line1, line2 = Views.Footer(makeView(makePath()))
    -- Range 75-150 holds the Gloves stage (19 crafts, 1900).
    T.eq("range and whole path, gaps flagged",
        line1, "This range: 19s   |cFF888888||r   Whole path (excluding gaps): 59s (you pay 59s)")
    T.check("no margin line when the margin is off", line2 == nil)

    line1 = Views.Footer(makeView(makePath({ complete = true }), { range = "all" }))
    T.eq("full path: no range part", line1, "Whole path: 59s (you pay 59s)")

    line1 = Views.Footer(makeView(makePath({ complete = true }), { range = "all", inventory = { [101] = 19 } }))
    T.eq("owned stock: you pay less, in green", line1, "Whole path: 59s (you pay |cFF66FF6640s|r)")

    line1, line2 = Views.Footer(makeView(makePath({ complete = true }), { margin = 15 }))
    -- 19 -> 22 crafts, 20 -> 23, 30 -> 35 (no price): 2200 + 4600
    T.eq("margin line: range and whole path", line2, "With 15% margin: range 22s, whole path 68s (you pay 68s)")
    T.eq("the first line keeps the expected figures", line1, "This range: 19s   |cFF888888||r   Whole path: 59s (you pay 59s)")
    T.eq("no path: empty", (Views.Footer({})), "")
end)

T.section("steps", function()
    local toggled = {}
    local ctx = { onToggleExpand = function(stage) toggled[#toggled + 1] = stage.key end }
    local view = makeView(makePath(), { range = "all" })
    local rows = Views.Steps(view, ctx)
    T.eq("one row per stage", #rows, 5)
    local gloves, shirt, gap, mystery = rows[1], rows[2], rows[3], rows[4]
    T.eq("craft row: range with the current mark", gloves.lead, "> 143-160")
    T.eq("craft row: kind and title", gloves.text, "|cFF888888craft|r  19x Gloves")
    T.eq("craft row: cost", gloves.right, "19s")
    T.eq("craft row: difficulty colour (orange)", gloves.color[2], 0.5)
    T.check("the current row is highlighted", gloves.bg[1] > 0.3)
    T.eq("other rows carry no mark", shirt.lead, "160-180")
    T.eq("bridge suffix", shirt.text, "|cFF888888craft|r  20x Shirt (green: no better recipe)")
    T.eq("gap row text", gap.text, "|cFF888888gap|r  No recipe for 180-200: train elsewhere or missing data")
    T.eq("gap row range", gap.lead, "180-200")
    T.eq("gap tooltip explains", gap.tooltip[2].text, "No available recipe gives skill-ups in this range.")
    T.eq("a stage with unpriced reagents costs nothing known", mystery.right, "0c")
    T.check("craft tooltip names the colours", gloves.tooltip[3].text:find("orange until 150", 1, true) ~= nil, gloves.tooltip[3].text)

    gloves.onClick()
    T.eq("a click asks to expand that stage", toggled[1], view.stages[1].key)

    view.expanded[view.stages[1].key] = true
    view.expanded[view.stages[4].key] = true
    rows = Views.Steps(view, ctx)
    T.eq("expanded rows add a header and one row per reagent", #rows, 5 + 2 + 2)
    T.check("header row", rows[2].kind == "cols" and rows[2].header == true)
    local mat = rows[3]
    T.eq("reagent name", mat.text, "MatGloves")
    T.eq("need / have / buy / cost", table.concat(mat.cols, ","), "19,0,19,19s")
    T.eq("item tooltip", mat.itemId, 101)
    T.check("indented under its stage", (mat.indent or 0) > 0)
    local odd = rows[#rows - 1]
    T.eq("a reagent with no price shows a question mark", table.concat(odd.cols, ","), "60,0,60,?")

    -- Owned stock and done stages
    local path = makePath({ actualSkill = 165 })
    view = makeView(path, { range = "all", inventory = { [101] = 30 }, expanded = {} })
    rows = Views.Steps(view, ctx)
    T.eq("a finished stage says done", rows[1].right, "done")
    T.eq("and is dimmed", rows[1].alpha, 0.5)
    T.eq("the next one is current", rows[2].lead, "> 160-180")
    view.expanded[view.stages[1].key] = true
    rows = Views.Steps(view, ctx)
    T.eq("nothing to buy shows a dash", table.concat(rows[3].cols, ","), "19,30,-,-")

    -- Range filter
    view = makeView(makePath(), {})
    rows = Views.Steps(view, ctx)
    T.eq("current range 75-150: the stage that starts in it", #rows, 1)
    view = makeView(makePath(), { range = 1 })
    rows = Views.Steps(view, ctx)
    T.eq("an empty range says so", rows[1].text, "No steps in 1-75")

    -- Margin
    view = makeView(makePath(), { range = "all", margin = 15 })
    rows = Views.Steps(view, ctx)
    T.eq("margin: the row shows the larger count", rows[1].text, "|cFF888888craft|r  22x Gloves")
    local last = rows[1].tooltip[#rows[1].tooltip - 1]
    T.eq("margin: the tooltip gives both counts", last.text, "19 crafts expected, 22 with margin")
end)

T.section("nothing left", function()
    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    local rows = Views.Steps(makeView(done, { range = "all" }), {})
    T.eq("at the cap", rows[1].text, "Nothing left: Tailoring is at its cap of 300.")
    local reached = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 200, currentSkill = 200,
        targetSkill = 200 })
    rows = Views.Steps(makeView(reached, { range = "all" }), {})
    T.eq("target reached", rows[1].text, "Target reached: skill 200, target 200.")
    T.eq("with a hint", rows[2].text, "Raise the target to keep planning.")
    local line1 = Views.Footer(makeView(reached, { range = "all" }))
    T.eq("footer still builds", line1, "Whole path (excluding gaps): 0c (you pay 0c)")
end)

T.section("search", function()
    local list = { recipe(1, "Woolen Cape", 75, 0, 0, 0), recipe(2, "Heavy Woolen Gloves", 85, 0, 0, 0),
        recipe(3, "Linen Bag", 45, 0, 0, 0), recipe(4, "Woolen Bag", 80, 0, 0, 0) }
    local matches = Views.SearchRecipes(list, "WOOL")
    T.eq("matches any case, by required skill", matches[1].name .. "," .. matches[2].name .. "," .. matches[3].name,
        "Woolen Cape,Woolen Bag,Heavy Woolen Gloves")
    T.eq("an empty query matches nothing", #Views.SearchRecipes(list, ""), 0)
    T.eq("special characters are plain text", #Views.SearchRecipes(list, "%a+"), 0)
    local shown
    local rows = Views.SearchResults(matches, { onShowRecipe = function(r) shown = r end })
    T.eq("one row per match plus a count", #rows, 4)
    T.eq("row text", rows[1].text, "Woolen Cape")
    T.eq("required skill on the right", rows[1].right, "Requires 75")
    T.eq("count line", rows[4].text, "3 results")
    rows[2].onClick()
    T.eq("a click opens that recipe", shown and shown.name, "Woolen Bag")
    T.eq("no matches", Views.SearchResults({}, {})[1].text, "No recipes found")
end)

T.section("path bar", function()
    local view = makeView(makePath(), { range = "all" })
    local bar = Views.PathBar(view)
    T.eq("a profession the character has: the bar starts at 1", bar.from, 1)
    T.eq("and ends at the target", bar.to, 300)
    T.eq("one dim block for the skill already gained, then every craft and gap stage", #bar.segments, 6)
    T.eq("first segment is the done block", bar.segments[1].kind, "done")
    local total, prevEnd, contiguous = 0, 0, true
    for _, seg in ipairs(bar.segments) do
        total = total + seg.width
        if math.abs(seg.left - prevEnd) > 1e-9 then contiguous = false end
        prevEnd = seg.left + seg.width
    end
    T.check("segments cover the bar exactly", math.abs(total - 1) < 1e-9, total)
    T.check("and follow each other", contiguous)
    local gloves, shirt, gap = bar.segments[2], bar.segments[3], bar.segments[4]
    T.check("a craft stage has its start colour (orange)", gloves.color[1] == 1 and gloves.color[2] == 0.5)
    T.eq("its width is its share of the bar", gloves.width, (160 - 143) / 299)
    T.eq("it knows its stage", gloves.stage, view.stages[1])
    T.check("a gap is red", gap.kind == "gap" and gap.color[1] > 0.7 and gap.color[2] < 0.2)
    T.eq("hover text names the stage", gloves.tooltip[1].text, "19x Gloves")
    T.eq("hover text of a gap", gap.tooltip[1].text, "No recipe for 180-200: train elsewhere or missing data")
    T.eq("marker at the real skill", bar.marker, (143 - 1) / 299)
    T.eq("marker skill", bar.markerSkill, 143)
    T.eq("no ticks without rank steps", #bar.ticks, 0)
    T.eq("stages ahead are fully drawn", shirt.alpha, 1)

    -- Done stages are dimmed; the selected one is marked.
    local path = makePath({ actualSkill = 165 })
    view = makeView(path, { range = "all" })
    view.selectedStage = view.stages[2]
    bar = Views.PathBar(view)
    T.check("a finished stage is dimmed", bar.segments[2].alpha < 1)
    T.check("the selected stage is marked", bar.segments[3].selected == true and not bar.segments[2].selected)

    -- Rank steps become ticks.
    local stages = Stages.Build(makePath(), { liveCap = 150 })
    view = makeView(makePath(), { range = "all" })
    view.stages = stages
    bar = Views.PathBar(view)
    T.eq("one tick per rank still to train", #bar.ticks, 2)
    T.eq("tick at the cap", bar.ticks[1].skill, 150)
    T.eq("tick position", bar.ticks[1].pos, (150 - 1) / 299)

    -- A profession not learned yet, and a what-if from 1.
    local fresh = makePath({ hasProfession = false, currentSkill = 1, actualSkill = 1,
        steps = { step(A, 1, 300, 300, 30000) }, gaps = {}, totalCost = 30000 })
    bar = Views.PathBar(makeView(fresh, { range = "all" }))
    T.eq("not learned: starts where the path does", bar.from, 1)
    T.eq("no done block", bar.segments[1].kind, "craft")
    local whatIf = makePath({ planFromOne = true, currentSkill = 1, actualSkill = 143,
        steps = { step(A, 1, 143, 143, 14300), step(B, 143, 300, 157, 31400) }, gaps = {}, totalCost = 45700 })
    bar = Views.PathBar(makeView(whatIf, { range = "all" }))
    T.eq("what-if from 1: no extra done block", bar.segments[1].kind, "craft")
    T.check("its finished stage is dimmed instead", bar.segments[1].alpha < 1)
    T.eq("marker still at the real skill", bar.markerSkill, 143)

    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    bar = Views.PathBar(makeView(done, { range = "all" }))
    T.eq("nothing left: the whole bar is done", #bar.segments, 1)
    T.eq("no path: empty bar", #Views.PathBar({}).segments, 0)
end)

T.section("guide card", function()
    local D = recipe(4, "Boots", 100, 150, 160, 170, { unlearned = true, sourceInfo = { type = "vendor", cost = 2000 } })
    D.source = { type = "vendor" }
    local E = recipe(5, "Hat", 100, 150, 160, 170)
    E._isUnavailable = true
    E._unavailableReason = "Needs Alchemy"
    local F, G = recipe(6, "Belt", 100, 150, 160, 170), recipe(7, "Bag", 100, 150, 160, 170)
    local prices = { [101] = 100, [102] = 200, [104] = 90, [105] = 50, [106] = 150, [107] = 400 }
    local alts = {
        { recipe = A, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = D, score = 2, color = "orange", expectedSkillups = 1, craftCost = 90 },
        { recipe = E, score = math.huge, color = "yellow", expectedSkillups = 0.5, craftCost = 50 },
        { recipe = F, score = 3, color = "orange", expectedSkillups = 0.5, craftCost = 150 },
        { recipe = G, score = 4, color = "orange", expectedSkillups = 1, craftCost = 400 },
    }
    local function cardPath(extra)
        local path = makePath(extra)
        path.prices = prices
        path.steps[1].alternatives = alts
        return path
    end
    local calls = {}
    local ctx = {
        onShowRecipe = function(r, skill) calls[#calls + 1] = "recipe:" .. r.name .. ":" .. tostring(skill) end,
        onUseAlternative = function(stage, alt) calls[#calls + 1] = "use:" .. alt.recipe.name .. ":" .. stage.from .. "-" .. stage.to end,
        onResetPin = function(stage) calls[#calls + 1] = "reset:" .. stage.from end,
        onShowAllAlts = function(on) calls[#calls + 1] = "all:" .. tostring(on) end,
        onOpenStage = function(stage) calls[#calls + 1] = "open:" .. stage.index end,
    }
    local function texts(rows)
        local out = {}
        for _, r in ipairs(rows) do
            if r.kind == "sep" then
                out[#out + 1] = "---"
            else
                out[#out + 1] = (r.lead and (r.lead .. " | ") or "") .. (r.text or "")
                    .. (r.cols and (" | " .. table.concat(r.cols, ",")) or "")
                    .. ((r.right and r.right ~= "") and (" | " .. r.right) or "")
                    .. (r.button and (" [" .. r.button.text .. "]") or "")
            end
        end
        return out
    end

    local view = makeView(cardPath(), { range = "all" })
    view.selectedStage = Views.SelectedStage(view.stages, view.summary, nil)
    T.eq("the current stage is selected by default", view.selectedStage, view.stages[1])
    local rows = Views.GuideCard(view, ctx)
    local t = texts(rows)
    T.eq("card header", t[1], "Step 1 of 5 - craft (current step)")
    T.eq("title and range", t[2], "19x Gloves | 143 to 160")
    T.eq("colour changes", t[3], "orange until 150, then yellow")
    T.eq("reagent table header", t[4], "Reagent | Need,Have,Buy,Cost")
    T.eq("reagent row", t[5], "MatGloves | 19,0,19,19s")
    T.eq("step cost", t[6], " | Step cost  19s")
    T.eq("alternatives header after a separator", t[7] .. " " .. t[8], "--- Alternatives")
    -- Sorted: usable and cheapest for the player first; unavailable last.
    T.eq("first alternative: fewer or more crafts and the cost difference",
        t[9], "Boots |cFFFF8800[!]|r | |cFF66FF66-2 crafts|r  |cFFFF6666+16s 30c|r [Use this]")
    T.eq("second alternative", t[10], "Belt | |cFFFF6666+15 crafts|r  |cFFFF6666+32s|r [Use this]")
    T.eq("third alternative", t[11], "Bag | |cFF66FF66-2 crafts|r  |cFFFF6666+49s|r [Use this]")
    T.eq("the rest is behind Show all", t[12], "Show all 4")
    T.eq("next stages after a separator", t[13] .. " " .. t[14], "--- Next")
    T.eq("next stage row", t[15], "160-180 | |cFF888888craft|r  20x Shirt (green: no better recipe) | 40s")
    T.eq("second next row is the gap", t[16], "180-200 | |cFF888888gap|r  No recipe for 180-200: train elsewhere or missing data")
    T.eq("two next rows only", #t, 16)

    rows[2].onClick()
    T.eq("title click opens the recipe details", calls[#calls], "recipe:Gloves:143")
    rows[9].button.onClick()
    T.eq("Use this pins over the stage's exact range", calls[#calls], "use:Boots:143-160")
    rows[9].onClick()
    T.eq("alternative click opens its recipe", calls[#calls], "recipe:Boots:143")
    rows[12].onClick()
    T.eq("Show all asks to expand", calls[#calls], "all:true")
    rows[15].onClick()
    T.eq("a next row opens that stage", calls[#calls], "open:2")
    local tip = rows[9].tooltip
    T.eq("alternative tooltip: unlearned source", tip[2].text, "[!] Unlearned: Vendor")
    T.check("alternative tooltip: learning fee", tip[5].text:find("to learn the recipe", 1, true) ~= nil, tip[5].text)

    view.showAllAlts = true
    rows = Views.GuideCard(view, ctx)
    t = texts(rows)
    T.eq("expanded: the unavailable one is last", t[12], "Hat | |cFFFF6666+15 crafts|r  |cFF66FF66-2s|r [Use this]")
    T.eq("and dimmed", rows[12].alpha, 0.5)
    T.eq("with today's reason in its tooltip", rows[12].tooltip[2].text, "Needs Alchemy")
    T.eq("Show fewer closes it", t[13], "Show fewer")
    T.check("the Use button warns about an unobtainable recipe", rows[12].button.tooltip[3].text:find("obtain", 1, true) ~= nil)

    -- Pinned stage
    local pins = {}
    LazyProf.Pins.Add(pins, 143, 160, 1)
    view = makeView(cardPath(), { range = "all" })
    view.stages = Stages.Build(cardPath(), { prices = prices, pins = pins })
    view.selectedStage = view.stages[1]
    rows = Views.GuideCard(view, ctx)
    t = texts(rows)
    T.eq("a pinned stage says so and offers Reset", t[4], "Pinned: you chose this recipe for the step. [Reset]")
    rows[4].button.onClick()
    T.eq("Reset asks to unpin the stage", calls[#calls], "reset:143")

    -- Owned stock and margin on the card
    view = makeView(cardPath(), { range = "all", inventory = { [101] = 10 }, margin = 15 })
    view.selectedStage = view.stages[1]
    t = texts(Views.GuideCard(view, ctx))
    T.eq("stock: have and buy columns", t[5], "MatGloves | 22,10,12,12s")
    T.eq("stock: step cost with the market price beside it", t[6], "|cFF888888market price 22s|r | Step cost  12s")
    T.eq("margin: both counts", t[7], "19 crafts expected, 22 with margin")

    -- Bridge and gap cards
    view = makeView(cardPath(), { range = "all" })
    view.selectedStage = view.stages[2]
    t = texts(Views.GuideCard(view, ctx))
    T.eq("bridge card header", t[1], "Step 2 of 5 - craft")
    T.check("bridge explanation", t[4]:find("green recipe keeps you leveling", 1, true) ~= nil, t[4])
    view.selectedStage = view.stages[3]
    t = texts(Views.GuideCard(view, ctx))
    T.eq("gap card header", t[1], "Step 3 of 5 - gap")
    T.eq("gap card text", t[2], "No recipe for 180-200: train elsewhere or missing data")
    T.eq("gap card explanation", t[3], "No available recipe gives skill-ups in this range.")
    view.selectedStage = view.stages[5]
    t = texts(Views.GuideCard(view, ctx))
    T.eq("the last stage has no next rows", t[#t], "The path continues after the gap; totals exclude it.")

    -- Selection
    view = makeView(cardPath(), { range = "all" })
    T.eq("selection by key", Views.SelectedStage(view.stages, view.summary, { key = view.stages[4].key, from = 200 }), view.stages[4])
    T.eq("a key that is gone falls back to the stage covering that skill",
        Views.SelectedStage(view.stages, view.summary, { key = "craft:999:143", from = 143 }), view.stages[1])
    T.eq("nothing matching: the current stage", Views.SelectedStage(view.stages, view.summary, { key = "x", from = 999 }), view.stages[1])
    T.check("no stages: nothing selected", Views.SelectedStage({}, {}, nil) == nil)

    -- Navigation
    view.selectedStage = view.stages[1]
    local nav = Views.GuideNav(view)
    T.check("first stage: no Prev, Next allowed, not away from current", nav.prev == false and nav.next == true and nav.current == false)
    view.selectedStage = view.stages[5]
    nav = Views.GuideNav(view)
    T.check("last stage: Prev allowed, no Next, Current step offered", nav.prev == true and nav.next == false and nav.current == true)
    T.check("a gap has no recipe to show", nav.recipe == false)

    -- Nothing left
    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    view = makeView(done, { range = "all" })
    T.eq("nothing left on the card too", Views.GuideCard(view, ctx)[1].text, "Nothing left: Tailoring is at its cap of 300.")
end)

T.section("learn and rank text", function()
    local Text = LazyProf.GuideText
    local R = recipe(8, "Boots", 150, 200, 210, 220, { unlearned = true })
    local function learn(info) return { kind = "learn", recipe = R, sourceInfo = info, fee = 0, at = 150 } end
    local function texts(lines)
        local out = {}
        for _, l in ipairs(lines) do out[#out + 1] = l.text end
        return table.concat(out, " / ")
    end

    T.eq("trainer", texts(Text.LearnLines(learn({ type = "trainer", cost = 500, npcName = "Any Tailoring Trainer" }), "FOREVER", "Tailoring")),
        "Learn from: any Tailoring trainer / Cost: 5s / Requires skill 150")
    T.eq("trainer without a known fee: no fee line", texts(Text.LearnLines(learn({ type = "trainer" }), "FOREVER", "Tailoring")),
        "Learn from: any Tailoring trainer / Requires skill 150")
    T.eq("a named trainer note is kept", texts(Text.LearnLines(learn({ type = "trainer", npcName = "Special trainer" }), "FOREVER", "Alchemy")),
        "Learn from: Special trainer / Requires skill 150")
    T.eq("vendor", texts(Text.LearnLines(learn({ type = "vendor", cost = 1500 }), "TBC", "Tailoring")),
        "Sold by a vendor. / Cost: 15s / Requires skill 150")
    T.eq("vendor with a currency price", texts(Text.LearnLines(learn({ type = "vendor", cost = 0,
        currency = { name = "Merchant's Favor", amount = 45 } }), "FOREVER", "Tailoring")),
        "Sold by a vendor. / Price: 45 Merchant's Favor / Requires skill 150")
    T.eq("in the bags", texts(Text.LearnLines(learn({ type = "inventory", location = { type = "bags", count = 1 } }), "SOD", "Tailoring")),
        "The recipe is in your bags. Use it to learn the recipe. / Requires skill 150")
    T.eq("on an alt", texts(Text.LearnLines(learn({ type = "inventory", location = { type = "alt", character = "Bankalt" } }), "SOD", "Tailoring")),
        "The recipe is on your alt Bankalt. Use it to learn the recipe. / Requires skill 150")
    T.eq("auction house, with its price", texts(Text.LearnLines(learn({ type = "ah", price = 7000, source = "TSM" }), "WOTLK", "Tailoring")),
        "Listed on the auction house. / Price: 70s (TSM) / Requires skill 150")
    T.eq("no resolved source", texts(Text.LearnLines(learn(nil), "FOREVER", "Tailoring")),
        "Not currently obtainable from a trainer, a vendor or the auction house. / You chose this recipe yourself; you will need to obtain it. / Requires skill 150")
    -- The Vanilla data types every recipe as trainer-taught: say nothing about the source.
    T.eq("VANILLA profile never names a source", texts(Text.LearnLines(learn({ type = "trainer", cost = 500 }), "VANILLA", "Tailoring")),
        "Learn the recipe. The recipe details show what is known about it. / Requires skill 150")
    T.check("VANILLA profile: no short source", Text.LearnShort(learn({ type = "trainer" }), "VANILLA") == nil)
    T.eq("short: trainer", Text.LearnShort(learn({ type = "trainer" }), "FOREVER"), "trainer")
    T.eq("short: bank", Text.LearnShort(learn({ type = "inventory", location = { type = "bank" } }), "FOREVER"), "in your bank")
    T.eq("short: auction house", Text.LearnShort(learn({ type = "ah", price = 1 }), "FOREVER"), "auction house")
    T.eq("short: currency vendor", Text.LearnShort(learn({ type = "vendor", currency = { name = "Favor", amount = 3 } }), "FOREVER"), "vendor, 3 Favor")
    T.eq("short: none", Text.LearnShort(learn(nil), "FOREVER"), "not currently obtainable")

    local rank = { kind = "rank", cap = 150, at = 150 }
    T.eq("rank: the character's own cap", Text.RankLine(rank, 150, "Tailoring", true),
        "Your cap is 150. Train the next rank at a Tailoring trainer before you reach 150.")
    T.eq("rank: a later cap", Text.RankLine({ kind = "rank", cap = 225 }, 150, "Tailoring", true),
        "Skill cap 225: train the next rank at a Tailoring trainer before you reach 225.")
    T.eq("rank: a profession not learned yet", Text.RankLine({ kind = "rank", cap = 75 }, 75, "Tailoring", false),
        "Skill cap 75: train the next rank at a Tailoring trainer before you reach 75.")
    T.eq("rank: range text", Text.StageRange(rank), "150")

    -- Rows on the VANILLA profile: the learn row names no source.
    local row = Views.StepRow(learn({ type = "trainer", cost = 500 }), { profile = "VANILLA", path = { profession = "Tailoring" } }, {})
    T.eq("VANILLA learn row", row.text, "|cFF888888learn|r  Boots")
    row = Views.StepRow(learn({ type = "trainer", cost = 500 }), { profile = "FOREVER", path = { profession = "Tailoring" } }, {})
    T.eq("learn row elsewhere", row.text, "|cFF888888learn|r  Boots - trainer")
end)

T.section("shopping rows", function()
    local chosen = {}
    local ctx = { onCraftChoice = function(row, choice) chosen[#chosen + 1] = { row.itemId, choice == nil and "auto" or choice } end }
    local function shop(rows)
        return Views.Shopping({ path = makePath(), missing = { rows = rows } }, ctx)
    end
    local function find(rows, name)
        for _, r in ipairs(rows) do
            if r.text == name then return r end
        end
    end
    local function item(id, name, extra)
        local row = { itemId = id, name = name, need = 10, have = 0, toBuy = 0, cost = 0, sources = {}, craftable = true, crafted = false }
        for k, v in pairs(extra or {}) do row[k] = v end
        return row
    end

    -- A crafted reagent can have a part to buy (what other crafted reagents
    -- are made from): the row says how many and what they cost.
    local rows = shop({
        item(1, "Bar", { crafted = true, need = 9, toBuy = 6, cost = 1800, unitPrice = 300, craftQuantity = 3, craftRecipeName = "Smelt Bar", children = {} }),
        item(2, "Bolt", { crafted = true, craftQuantity = 10, craftRecipeName = "Bolt of Cloth", children = {} }),
    })
    T.eq("crafted with a part to buy: the buy count", find(rows, "Bar").cols[3], "6")
    T.eq("crafted with a part to buy: its cost is shown", find(rows, "Bar").cols[4], "18s")
    T.eq("crafted, nothing to buy: no cost", find(rows, "Bolt").cols[4], "")
    T.eq("crafted, nothing to buy: no count", find(rows, "Bolt").cols[3], "-")

    -- The craft / buy button says the choice in force, also when the stock
    -- covers the need and nothing is crafted right now.
    rows = shop({
        item(3, "Chosen craft, covered", { choice = "craft", have = 20 }),
        item(4, "Chosen buy", { choice = "buy", toBuy = 10, cost = 100 }),
        item(5, "Automatic craft", { crafted = true, craftQuantity = 10, children = {} }),
        item(6, "Automatic buy", { toBuy = 10, cost = 100 }),
    })
    local covered = find(rows, "Chosen craft, covered").button
    T.eq("chosen craft, stock covers it: still says craft", covered.text, "I craft it")
    T.check("its tooltip says it was chosen", covered.tooltip[1].text:find("You chose to craft", 1, true) ~= nil, covered.tooltip[1].text)
    T.check("and that nothing needs making now", covered.tooltip[2].text:find("covers", 1, true) ~= nil, covered.tooltip[2].text)
    covered.onClick("LeftButton")
    T.check("a click switches it to buy", chosen[#chosen][1] == 3 and chosen[#chosen][2] == "buy")
    local buy = find(rows, "Chosen buy").button
    T.eq("chosen buy", buy.text, "I buy it")
    T.check("its tooltip", buy.tooltip[1].text:find("You chose to buy", 1, true) ~= nil)
    buy.onClick("LeftButton")
    T.check("a click switches it to craft", chosen[#chosen][2] == "craft")
    buy.onClick("RightButton")
    T.check("a right-click goes back to automatic", chosen[#chosen][2] == "auto")
    T.eq("automatic craft", find(rows, "Automatic craft").button.text, "I craft it")
    T.check("automatic craft: tooltip", find(rows, "Automatic craft").button.tooltip[1].text:find("automatically", 1, true) ~= nil)
    T.eq("automatic buy", find(rows, "Automatic buy").button.text, "I buy it")
end)

T.section("arrow tooltip", function()
    local function lines(view)
        local out = {}
        for _, l in ipairs(Views.ArrowTooltip(view)) do
            out[#out + 1] = l.right and ((l.text:gsub("%s+$", "")) .. " | " .. l.right) or l.text
        end
        return out
    end
    local view = makeView(makePath(), { range = "all",
        priceLines = { { text = "Prices: TSM 2", r = 0.6, g = 0.6, b = 0.6 } } })
    local t = lines(view)
    T.eq("title", t[1], "LazyProf - Optimal Path")
    T.eq("the current step and its cost", t[3], "Now: 19x Gloves | 19s")
    T.eq("its skill range", t[4], "   Skill 143 to 160")
    T.eq("the next step", t[5], "Then: 20x Shirt (green: no better recipe) | 40s")
    T.eq("the one after", t[6], "Then: No recipe for 180-200: train elsewhere or missing data")
    T.eq("the rest is on the Steps tab", t[7], "... and 2 more steps (see the Steps tab)")
    T.eq("total, flagged when the path has gaps", t[9], "Total Cost (excluding gaps): | 59s")
    T.eq("labels keep their colon and space for the two-column line", Views.ArrowTooltip(view)[9].text, "Total Cost (excluding gaps): ")
    T.eq("price lines last", t[11], "Prices: TSM 2")
    T.eq("no more lines than that", #t, 11)

    -- Owned stock: you pay and the market price, as before.
    view = makeView(makePath({ complete = true }), { range = "all", inventory = { [101] = 19 } })
    t = lines(view)
    T.eq("stock: the current step costs nothing", t[3], "Now: 19x Gloves | 0c")
    T.eq("stock: you pay", t[9], "You Pay: | 40s")
    T.eq("stock: market price", t[10], "Market Price: | 59s")

    -- Margin
    view = makeView(makePath({ complete = true }), { range = "all", margin = 15 })
    t = lines(view)
    T.eq("margin: the larger count", t[3], "Now: 22x Gloves | 22s")
    T.eq("margin: its own total line", t[10], "With 15% margin: | 68s")

    -- Learn and rank steps as the current step
    local boots = recipe(8, "Boots", 143, 200, 210, 220, { unlearned = true, sourceInfo = { type = "vendor", cost = 1500 } })
    local path = makePath({ complete = true, gaps = {}, totalCost = 3200, prices = { [108] = 100 },
        steps = { step(boots, 143, 150, 7, 7 * 100 + 1500), step(boots, 150, 160, 10, 1000) } })
    view = makeView(path, { range = "all" })
    view.stages, view.summary = Stages.Build(path, { includeLearn = true, liveCap = 150 })
    view.profile, view.liveCap = "FOREVER", 150
    t = lines(view)
    T.eq("learn step first, with its fee", t[3], "Now: Learn Boots | 15s")
    T.eq("where it comes from", t[4], "   Sold by a vendor.")
    T.eq("then the craft", t[7], "Then: 7x Boots | 7s")
    T.eq("then the rank step", t[8], "Then: Train the next rank before 150")
    T.eq("total includes the fee", t[11], "Total Cost: | 32s")

    -- Nothing left, and no path
    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    t = lines(makeView(done, { range = "all" }))
    T.eq("nothing left says so", t[3], "Nothing left: Tailoring is at its cap of 300.")
    T.eq("no path: just the title", #lines({}), 1)
    for _, l in ipairs(Views.ArrowTooltip(view)) do
        if l.text:find("[\128-\255]") then T.check("tooltip text is plain ASCII", false, l.text) end
    end
end)

T.finish()
