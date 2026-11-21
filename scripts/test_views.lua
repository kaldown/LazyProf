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

T.finish()
