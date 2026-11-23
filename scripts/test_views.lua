-- scripts/test_views.lua
--
-- What the LazyProf window shows, checked as data: the header lines, the
-- receipt, the footer totals, the Steps tab's rows, the "nothing left" states
-- and the recipe search; the path list, the shopping list, the target model
-- and the arrow tooltip. No frames are involved.
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
    "Modules/Pathfinder/MaterialResolver.lua",
    "Modules/Pathfinder/Pathfinder.lua",
    "Modules/Guide/Text.lua",
    "Modules/Guide/Range.lua",
    "Modules/Guide/Stages.lua",
    "Modules/Guide/Views.lua",
})
local Stages, Views, Range = LazyProf.Stages, LazyProf.GuideViews, LazyProf.GuideRange
local Pathfinder = LazyProf.Pathfinder
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

-- Craft or buy in the shopping list: Bolt (150) is made from 3 Cloth (151)
-- and Bar (152) from 2 Ore (153), by recipes the character knows.
local BOLT, CLOTH, BAR, ORE = 150, 151, 152, 153
local PRODUCERS = {
    [BOLT] = { { professionKey = "tailoring", recipe = { id = 500, name = "Bolt of Cloth", source = { type = "trainer" },
        reagents = { { itemId = CLOTH, count = 3, name = "Cloth" } } } } },
    [BAR] = { { professionKey = "mining", recipe = { id = 501, name = "Smelt Bar", source = { type = "trainer" },
        reagents = { { itemId = ORE, count = 2, name = "Ore" } } } } },
}
_G.CraftLib = { GetRecipeByProduct = function(_, itemId) return PRODUCERS[itemId] end }
LazyProf.Client.PlayerSkill = function() return 0 end
LazyProf.db.char.learnedRecipes = { tailoring = { [500] = true }, mining = { [501] = true } }

-- The view as the window builds it for the receipt and the reworked tabs:
-- stages with learn steps, and the account of the whole path (the shopping
-- list of its stages, less what the crafts sell for).
local function shopView(path, opts)
    opts = opts or {}
    local inventory = opts.inventory or {}
    -- In the bags unless opts.breakdown says where the stock is.
    local breakdown = opts.breakdown
    if not breakdown then
        breakdown = {}
        for itemId, count in pairs(inventory) do breakdown[itemId] = { bags = count } end
    end
    local stages, summary = Stages.Build(path, { inventory = inventory, marginPercent = opts.margin,
        includeLearn = true, liveCap = opts.liveCap, pins = opts.pins })
    local steps = Stages.ShoppingSteps(stages)
    local account = Pathfinder:Account(steps, inventory, breakdown, path.prices, path.sale and path.sale.values)
    account.stockSaves = Pathfinder:StockSaving(steps, path.prices, account.spend)
    return {
        path = path, stages = stages, summary = summary, account = account, missing = account.missing,
        sale = path.sale, saleLoading = opts.saleLoading or 0,
        skill = path.actualSkill, cap = opts.cap, liveCap = opts.liveCap, profile = opts.profile or "FOREVER",
        priceSummary = opts.priceSummary, priceLines = opts.priceLines,
        marginPercent = opts.margin, expanded = opts.expanded or {}, showAllAlts = opts.showAllAlts or {},
        advanced = opts.advanced or false, hideOwned = opts.hideOwned or false,
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

T.section("receipt", function()
    -- Lines by key, and the keys in order.
    local function receipt(view)
        local byKey, keys = {}, {}
        for _, line in ipairs(Views.Receipt(view)) do
            byKey[line.key] = line
            keys[#keys + 1] = line.key
        end
        return byKey, table.concat(keys, ",")
    end
    local function sold(mode, values)
        local sources = {}
        for id in pairs(values) do sources[id] = mode end
        return { mode = mode, values = values, sources = sources, rank = {}, loading = 0, loadingItems = {} }
    end

    -- Nothing sells, nothing owned, every recipe known: one line.
    -- Gloves 19 x 1s + Shirt 20 x 2s; the Mystery reagent has no price.
    local r, keys = receipt(shopView(makePath()))
    T.eq("no sale value, no stock: one line", keys, "spend")
    T.eq("spend: label, with the gaps flagged", r.spend.label, "You spend (excluding gaps)")
    T.eq("spend: a reagent without a price adds nothing", r.spend.amount, "59s")
    T.check("spend: no note when no recipe costs anything", r.spend.note == nil, r.spend.note)
    r = receipt(shopView(makePath({ complete = true })))
    T.eq("spend: label of a path without gaps", r.spend.label, "You spend")

    -- A recipe to learn: the note splits the amount.
    local boots = recipe(4, "Boots", 143, 200, 210, 220, { unlearned = true, sourceInfo = { type = "vendor", cost = 2000 } })
    local learnPath = makePath({ complete = true, gaps = {}, prices = { [104] = 100 },
        steps = { step(boots, 143, 150, 7, 2700), step(boots, 150, 160, 10, 1000) } })
    r, keys = receipt(shopView(learnPath))
    T.eq("recipes: amount is reagents plus recipes", r.spend.amount, "37s")
    T.eq("recipes: the note says both parts", r.spend.note, "reagents 17s + recipes 20s")
    T.eq("recipes: still one line", keys, "spend")

    -- Sold to a vendor: three lines.
    local view = shopView(makePath({ complete = true, sale = sold("vendor", { [1] = 30 }) }))
    r, keys = receipt(view)
    T.eq("vendor: three lines", keys, "spend,back,net")
    T.eq("vendor: back label", r.back.label, "Back from selling")
    T.eq("vendor: 19 gloves at 30c come back, shown as a minus", r.back.amount, "-5s 70c")
    T.check("vendor: the amount is green", r.back.amountColor[1] < 1 and r.back.amountColor[2] == 1)
    T.eq("vendor: note", r.back.note, "crafts sold to a vendor")
    T.eq("vendor: net label", r.net.label, "Net cost")
    T.eq("vendor: net is spend less back", r.net.amount, "53s 30c")
    T.check("vendor: no stock note without stock", r.net.note == nil, r.net.note)
    T.eq("the lines add up", view.account.spend - view.account.sale, view.account.net)

    r = receipt(shopView(makePath({ complete = true, sale = sold("auction", { [1] = 30 }) })))
    T.eq("auction: note", r.back.note, "crafts sold at auction, after the 5% cut")

    -- Sale values still loading: the amount known so far, and a note.
    r, keys = receipt(shopView(makePath({ complete = true, sale = sold("vendor", { [1] = 30 }) }), { saleLoading = 2 }))
    T.eq("loading: note", r.back.note, "crafts sold to a vendor, still loading")
    T.eq("loading: the amount known so far", r.back.amount, "-5s 70c")
    r, keys = receipt(shopView(makePath({ complete = true, sale = sold("vendor", {}) }), { saleLoading = 1 }))
    T.eq("loading, nothing known yet: the lines are there", keys, "spend,back,net")
    T.eq("loading, nothing known yet: zero without a minus", r.back.amount, "0c")
    T.eq("loading, nothing known yet: net is the spend", r.net.amount, "59s")
    -- The count frozen on the path is not what is read.
    local frozen = sold("vendor", {})
    frozen.loading = 3
    r, keys = receipt(shopView(makePath({ complete = true, sale = frozen })))
    T.eq("the path's own loading count is ignored", keys, "spend")

    r, keys = receipt(shopView(makePath({ complete = true, sale = sold("vendor", {}) })))
    T.eq("nothing sells and nothing is loading: one line", keys, "spend")
    r, keys = receipt(shopView(makePath({ complete = true, sale = sold("none", {}) }), { saleLoading = 2 }))
    T.eq("sale values not counted: one line", keys, "spend")

    -- The crafts sell for more than is spent: a gain, never a negative cost.
    r = receipt(shopView(makePath({ complete = true, sale = sold("auction", { [1] = 400 }) })))
    T.eq("gain: label", r.net.label, "Net gain")
    T.eq("gain: a positive amount", r.net.amount, "17s")
    T.check("gain: green", r.net.amountColor[1] < 1 and r.net.amountColor[2] == 1)
    r = receipt(shopView(makePath({ complete = true, sale = sold("vendor", { [1] = 30 }) })))
    T.check("a cost is not green", r.net.amountColor[1] == 1)

    -- Owned stock: the note sits on the net line, or on a line of its own.
    r, keys = receipt(shopView(makePath({ complete = true, sale = sold("vendor", { [1] = 30 }) }), { inventory = { [101] = 19 } }))
    T.eq("stock: spend is what is left to buy", r.spend.amount, "40s")
    T.eq("stock: note on the net line", r.net.note, "your own stock saves 19s")
    T.eq("stock: no extra line then", keys, "spend,back,net")
    r, keys = receipt(shopView(makePath({ complete = true }), { inventory = { [101] = 19 } }))
    T.eq("stock, no net line: a line of its own", keys, "spend,stock")
    T.eq("stock line text", r.stock.note, "Your own stock saves 19s")
    T.check("stock line has no amount", r.stock.amount == nil and r.stock.label == nil)
    T.eq("stock line is grey", r.stock.color[1], 0.7)

    -- Margin
    r, keys = receipt(shopView(makePath({ complete = true }), { margin = 15 }))
    T.eq("margin: a line says so", keys, "spend,margin")
    T.eq("margin: text", r.margin.note, "Includes 15% spare crafts")
    T.eq("margin: the amount covers the larger counts (22 and 23 crafts)", r.spend.amount, "68s")
    T.check("margin: note-only", r.margin.amount == nil)

    -- Prices missing, loading or too old: the first problem line, in orange.
    local priceLines = {
        { text = "Prices: TSM 2, none 1", r = 0.6, g = 0.6, b = 0.6 },
        { text = "1 reagent has no price at all - scan the auction house (needs TSM or Auctionator).", r = 1, g = 0.5, b = 0, problem = true },
        { text = "Auctionator prices up to 6 days old - rescan the auction house.", r = 1, g = 0.5, b = 0, problem = true },
        { text = "/lp diag prices lists every price and its source.", r = 0.5, g = 0.5, b = 0.5 },
    }
    view = shopView(makePath({ complete = true }))
    view.priceLines = priceLines
    r, keys = receipt(view)
    T.eq("problem: one more line", keys, "spend,problem")
    T.eq("problem: the first problem line of the price summary", r.problem.note, priceLines[2].text)
    T.check("problem: orange", r.problem.color[1] == 1 and r.problem.color[2] == 0.5 and r.problem.color[3] == 0)
    T.check("problem: note-only", r.problem.amount == nil)
    view.priceLines = { priceLines[1] }
    r, keys = receipt(view)
    T.eq("no problem line when the prices are fine", keys, "spend")

    -- Everything at once, in order.
    view = shopView(makePath({ sale = sold("vendor", { [1] = 30 }) }), { inventory = { [101] = 5 }, margin = 15 })
    view.priceLines = priceLines
    r, keys = receipt(view)
    T.eq("order of the lines", keys, "spend,back,net,margin,problem")

    -- The list makes a reagent instead of buying it: the Path tab's cost
    -- column prices the run's direct reagents, so the receipt names the
    -- difference. 10 Shirts need 20 Bolt (5s each) or 60 Cloth (1s each).
    local shirt = recipe(20, "Shirt", 100, 150, 160, 170, { reagents = { { itemId = BOLT, count = 2, name = "Bolt" } } })
    local sword = recipe(21, "Sword", 110, 150, 160, 170, { reagents = { { itemId = BAR, count = 1, name = "Bar" } } })
    local function craftPath(prices, steps)
        return makePath({ complete = true, gaps = {}, currentSkill = 100, actualSkill = 100, prices = prices,
            steps = steps or { step(shirt, 100, 110, 10, 0) } })
    end
    view = shopView(craftPath({ [BOLT] = 500, [CLOTH] = 100 }))
    r, keys = receipt(view)
    T.eq("making: spend is the cloth", r.spend.amount, "60s")
    T.eq("making: the line names the reagent and the saving", r.making.note, "Making 20 Bolt yourself saves 40s")
    T.eq("making: after the amounts", keys, "spend,making")
    T.check("making: grey, note-only", r.making.amount == nil and r.making.color[1] == 0.7)
    T.eq("cost column total + recipes - the saving = You spend",
        view.summary.columnPay + view.account.recipes - 4000, view.account.spend)

    -- The bank holds some of the reagent the list makes: that stock is used
    -- before any is made, and the sums still add up. 8 Bolt owned, 12 made
    -- from 36 Cloth; the run's cost column prices the 12 at 5s each.
    view = shopView(craftPath({ [BOLT] = 500, [CLOTH] = 100 }), { inventory = { [BOLT] = 8 }, breakdown = { [BOLT] = { bank = 8 } } })
    r, keys = receipt(view)
    T.eq("made reagent partly in the bank: only the rest is made", r.making.note, "Making 12 Bolt yourself saves 24s")
    T.eq("made reagent partly in the bank: spend", r.spend.amount, "36s")
    T.eq("made reagent partly in the bank: what the stock saves", r.stock.note, "Your own stock saves 24s")
    T.eq("made reagent partly in the bank: order", keys, "spend,stock,making")
    T.eq("made reagent partly in the bank: cost column + recipes - the saving = You spend",
        view.summary.columnPay + view.account.recipes - 2400, view.account.spend)
    T.eq("the bank stock is under Collect first", view.account.missing.fromBank[1] and view.account.missing.fromBank[1].missing, 8)

    -- "I craft it" although buying is cheaper: said as it is.
    LazyProf.CharStore:Get().craftChoices[BOLT] = "craft"
    view = shopView(craftPath({ [BOLT] = 500, [CLOTH] = 200 }))
    r = receipt(view)
    T.eq("making, dearer: the line says so", r.making.note, "Making 20 Bolt yourself costs 20s more than buying")
    T.eq("making, dearer: the sums still hold", view.summary.columnPay + view.account.recipes + 2000, view.account.spend)
    view = shopView(craftPath({ [BOLT] = 300, [CLOTH] = 100 }))
    r, keys = receipt(view)
    T.eq("making, same cost: no line", keys, "spend")
    LazyProf.CharStore:Get().craftChoices[BOLT] = nil

    -- Several crafted reagents: counted, not named.
    view = shopView(craftPath({ [BOLT] = 500, [CLOTH] = 100, [BAR] = 300, [ORE] = 100 },
        { step(shirt, 100, 110, 10, 0), step(sword, 110, 120, 10, 0) }))
    r = receipt(view)
    T.eq("making, several: a count", r.making.note, "Making 2 reagents yourself saves 50s")

    -- No lines without a path, without an account, or with nothing left.
    T.eq("no path: empty", #Views.Receipt({}), 0)
    T.eq("no account: empty", #Views.Receipt({ path = makePath() }), 0)
    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    T.eq("nothing left: empty", #Views.Receipt(shopView(done)), 0)

    for _, line in ipairs(Views.Receipt(view)) do
        for _, text in ipairs({ line.label or "", line.amount or "", line.note or "" }) do
            if text:find("[\128-\255]") then T.check("receipt text is plain ASCII", false, text) end
        end
    end
end)

-- A bare pipe wrapped in a colour ("|cFF888888||r") is read by the client as
-- a colour, an escaped pipe and a stray "r". Nothing in the views may build one.
T.section("no pipe inside a colour code", function()
    local f = assert(io.open("Modules/Guide/Views.lua", "r"))
    local source = f:read("*a")
    f:close()
    T.check("no literal colour code closes right after a pipe", source:find("||r", 1, true) == nil)
    local found
    for _, helper in ipairs({ "Grey", "Green" }) do
        found = found or source:match(helper .. '%(%s*"[^"\n]*|[^"\n]*"')
    end
    T.check("no colour helper is handed a text with a pipe", found == nil, found)
    -- And what the views build: a pipe is only ever the start of a colour
    -- code or its end.
    local function scan(text)
        local rest = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        return rest:find("|", 1, true) == nil
    end
    local view = makeView(makePath())
    for _, text in ipairs({ Views.Footer(view) }) do
        T.check("footer: pipes only in colour codes", scan(text), text)
    end
end)

T.section("footer", function()
    local line1, line2 = Views.Footer(makeView(makePath()))
    -- Range 75-150 holds the Gloves stage (19 crafts, 1900).
    T.eq("range and whole path, gaps flagged",
        line1, "This range: 19s     Whole path (excluding gaps): 59s (you pay 59s)")
    T.check("no margin line when the margin is off", line2 == nil)

    line1 = Views.Footer(makeView(makePath({ complete = true }), { range = "all" }))
    T.eq("full path: no range part", line1, "Whole path: 59s (you pay 59s)")

    line1 = Views.Footer(makeView(makePath({ complete = true }), { range = "all", inventory = { [101] = 19 } }))
    T.eq("owned stock: you pay less, in green", line1, "Whole path: 59s (you pay |cFF66FF6640s|r)")

    line1, line2 = Views.Footer(makeView(makePath({ complete = true }), { margin = 15 }))
    -- 19 -> 22 crafts, 20 -> 23, 30 -> 35 (no price): 2200 + 4600
    T.eq("margin line: range and whole path", line2, "With 15% margin: range 22s, whole path 68s (you pay 68s)")
    T.eq("the first line keeps the expected figures", line1, "This range: 19s     Whole path: 59s (you pay 59s)")
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
    -- Every alternative turns yellow at 150 like the Gloves, and takes 21
    -- crafts for 143-160 counted craft by craft.
    T.eq("first alternative: crafts and cost difference",
        t[9], "Belt | |cFFFF6666+2 crafts|r  |cFFFF6666+12s 50c|r [Use this]")
    T.eq("second alternative, with its recipe to learn", t[10], "Boots |cFFFF8800[!]|r | |cFFFF6666+2 crafts|r  |cFFFF6666+19s 90c|r [Use this]")
    T.eq("third alternative", t[11], "Bag | |cFFFF6666+2 crafts|r  |cFFFF6666+65s|r [Use this]")
    T.eq("the rest is behind Show all", t[12], "Show all 4")
    T.eq("next stages after a separator", t[13] .. " " .. t[14], "--- Next")
    T.eq("next stage row", t[15], "160-180 | |cFF888888craft|r  20x Shirt (green: no better recipe) | 40s")
    T.eq("second next row is the gap", t[16], "180-200 | |cFF888888gap|r  No recipe for 180-200: train elsewhere or missing data")
    T.eq("two next rows only", #t, 16)

    rows[2].onClick()
    T.eq("title click opens the recipe details", calls[#calls], "recipe:Gloves:143")
    rows[10].button.onClick()
    T.eq("Use this pins over the stage's exact range", calls[#calls], "use:Boots:143-160")
    rows[10].onClick()
    T.eq("alternative click opens its recipe", calls[#calls], "recipe:Boots:143")
    rows[12].onClick()
    T.eq("Show all asks to expand", calls[#calls], "all:true")
    rows[15].onClick()
    T.eq("a next row opens that stage", calls[#calls], "open:2")
    local tip = rows[10].tooltip
    T.eq("alternative tooltip: unlearned source", tip[2].text, "[!] Unlearned: Vendor")
    T.check("alternative tooltip: learning fee", tip[5].text:find("to learn the recipe", 1, true) ~= nil, tip[5].text)

    view.showAllAlts = true
    rows = Views.GuideCard(view, ctx)
    t = texts(rows)
    T.eq("expanded: the unavailable one is last", t[12], "Hat | |cFFFF6666+2 crafts|r  |cFF66FF66-8s 50c|r [Use this]")
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

    -- The sub-line under a recipe still to learn: where it comes from and
    -- the fee, in a few words.
    local function first(info, fee, profile)
        local stage = learn(info)
        stage.fee = fee or 0
        return Text.LearnFirst(stage, profile or "FOREVER")
    end
    T.eq("learn first: trainer with its fee", first({ type = "trainer", cost = 400 }, 400), "Learn first: trainer, 4s")
    T.eq("learn first: trainer, fee unknown", first({ type = "trainer" }), "Learn first: trainer")
    T.eq("learn first: vendor", first({ type = "vendor", cost = 2000 }, 2000), "Learn first: vendor, 20s")
    T.eq("learn first: vendor, no price known", first({ type = "vendor" }), "Learn first: vendor")
    T.eq("learn first: currency vendor", first({ type = "vendor", currency = { name = "Favor", amount = 3 } }),
        "Learn first: vendor, 3 Favor")
    T.eq("learn first: auction house with its price", first({ type = "ah", price = 4000 }, 4000), "Learn first: auction house, 40s")
    T.eq("learn first: in the bags", first({ type = "inventory", location = { type = "bags" } }), "Learn first: in your bags")
    T.eq("learn first: no source", first(nil), "Learn first: not currently obtainable")
    T.eq("learn first: VANILLA names no source and no fee", first({ type = "trainer", cost = 400 }, 400, "VANILLA"),
        "Learn the recipe first")
    T.eq("learn first: a source kind it has no words for", first({ type = "quest" }, 0), "Learn the recipe first")

    -- What one craft sells for, by where the value comes from.
    T.eq("sells for: vendor", Text.SellsFor(4500, "vendor"), "Sells for 45s each (vendor)")
    T.eq("sells for: auction", Text.SellsFor(12345, "auction"), "Sells for 1g 23s each (auction, after the 5% cut)")
    T.eq("sells for: source unknown", Text.SellsFor(45, nil), "Sells for 45c each")
    T.eq("sold note: vendor", Text.SoldNote("vendor"), "crafts sold to a vendor")
    T.eq("sold note: auction", Text.SoldNote("auction"), "crafts sold at auction, after the 5% cut")

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

-- The Path tab: one row per recipe run, learn steps and the closest
-- alternative folded in as sub-lines, a run opened in place.
T.section("path list", function()
    -- Leatherworking at 117 with the cap at 150: Dark Boots (to learn at a
    -- trainer) 117-125, Shoulders 125-140 (with other recipes that could do
    -- that range), Armor Kit 140-150, the next rank, Barbaric Gloves (pattern
    -- on the auction house) 150-170, then nothing for 170-190.
    local function listPath(opts)
        opts = opts or {}
        local boots = recipe(31, "Dark Boots", 117, 150, 160, 170, { unlearned = true,
            sourceInfo = { type = "trainer", cost = 400, npcName = "Any Leatherworking Trainer" } })
        local shoulders = recipe(32, "Shoulders", 125, 150, 160, 170)
        local kit = recipe(33, "Armor Kit", 140, 165, 175, 185)
        local gloves = recipe(34, "Barbaric Gloves", 150, 170, 180, 190, { unlearned = true,
            sourceInfo = { type = "ah", price = 8500, source = "TSM" } })
        local pants = recipe(35, "Dark Pants", 120, 150, 160, 170)
        local vest = recipe(36, "Vest", 120, 130, 140, 150)     -- yellow from 130: 19 crafts for 125-140
        local fine = recipe(37, "Fine Pants", 120, 150, 160, 170, { unlearned = true, sourceInfo = { type = "vendor", cost = 3000 } })
        fine.source = { type = "vendor" }
        local belt = recipe(38, "Belt", 120, 150, 160, 170)
        local hat = recipe(39, "Hat", 120, 150, 160, 170)
        hat._isUnavailable, hat._unavailableReason = true, "Needs Alchemy"
        local alts = {
            { recipe = shoulders, score = 1, color = "orange", expectedSkillups = 1 },
            { recipe = pants, score = 2, color = "orange", expectedSkillups = 1 },
            { recipe = vest, score = 3, color = "orange", expectedSkillups = 1 },
            { recipe = fine, score = 4, color = "orange", expectedSkillups = 1 },
            { recipe = belt, score = 5, color = "orange", expectedSkillups = 1 },
            { recipe = hat, score = math.huge, color = "orange", expectedSkillups = 1 },
        }
        if opts.scarf then
            -- Cheap, but grey at 134: it cannot do the whole of 125-140.
            alts[#alts + 1] = { recipe = recipe(43, "Scarf", 120, 126, 130, 134), score = 6, color = "orange", expectedSkillups = 1 }
        end
        if opts.onlyScarf then
            alts = { alts[1], alts[#alts] }
        end
        return {
            profession = "Leatherworking", professionKey = "leatherworking", hasProfession = true,
            currentSkill = 117, actualSkill = opts.skill or 117, targetSkill = 190, capSkill = 300, racialBonus = 0,
            milestones = MILESTONES, complete = false, sale = opts.sale,
            prices = { [131] = 100, [132] = 100, [133] = 80, [134] = 105, [135] = opts.pantsPrice or 110,
                       [136] = 150, [137] = 120, [138] = 200, [139] = 50, [143] = 10 },
            steps = {
                step(boots, 117, 121, 5, 0), step(boots, 121, 125, 5, 0),
                step(shoulders, 125, 140, 15, 0, { alternatives = alts }),
                step(kit, 140, 150, 12, 0),
                step(gloves, 150, 170, 24, 0),
            },
            gaps = { { from = 170, to = 190, reason = "no recipe" } },
        }
    end
    local BOOTS_KEY, SHOULDERS_KEY, KIT_KEY = "craft:31:117", "craft:32:125", "craft:33:140"
    local calls = {}
    local ctx = {
        onToggleExpand = function(stage) calls[#calls + 1] = "toggle:" .. stage.key end,
        onShowRecipe = function(r, skill) calls[#calls + 1] = "recipe:" .. r.name .. ":" .. tostring(skill) end,
        onUseAlternative = function(stage, alt) calls[#calls + 1] = "use:" .. alt.recipe.name .. ":" .. stage.from .. "-" .. stage.to end,
        onResetPin = function(stage) calls[#calls + 1] = "reset:" .. stage.key end,
        onShowAllAlts = function(stage, on) calls[#calls + 1] = "all:" .. stage.key .. ":" .. tostring(on) end,
    }
    -- One line per row: sub-lines indented, columns, right text, button.
    local function texts(rows)
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = (r.sub and "  " or "") .. (r.text or "")
                .. (r.cols and (" | " .. table.concat(r.cols, ",")) or "")
                .. ((r.right and r.right ~= "") and (" | " .. r.right) or "")
                .. (r.button and (" [" .. r.button.text .. "]") or "")
        end
        return out
    end
    local function find(rows, needle)
        for i, r in ipairs(rows) do
            if r.text and r.text:find(needle, 1, true) then return r, i end
        end
    end
    local function closed(extra)
        local expanded = { [BOOTS_KEY] = false }
        for k, v in pairs(extra or {}) do expanded[k] = v end
        return expanded
    end
    local function list(pathOpts, viewOpts)
        viewOpts = viewOpts or {}
        viewOpts.liveCap = viewOpts.liveCap or 150
        viewOpts.expanded = viewOpts.expanded or closed()
        local view = shopView(listPath(pathOpts), viewOpts)
        return Views.Path(view, ctx), view
    end

    T.eq("the closest alternative counts as close within a tenth of the run's cost", Views.CLOSE_ALTERNATIVE, 0.10)

    -- Every row closed.
    local rows, view = list()
    local t = texts(rows)
    T.eq("header row", t[1], "Recipes | skill,crafts,cost")
    T.check("header: path columns", rows[1].kind == "cols" and rows[1].layout == "path" and rows[1].header == true)
    T.eq("the current run is marked", t[2], "> Dark Boots | 117-125,10,10s")
    T.eq("its recipe is still to learn: a sub-line, not a row", t[3], "  Learn first: trainer, 4s")
    T.eq("a run with a close alternative", t[4], "Shoulders | 125-140,15,15s")
    T.eq("the alternative as a sub-line with a Use button", t[5], "  or: Dark Pants, +1s 50c [Use]")
    T.eq("a plain run", t[6], "Armor Kit | 140-150,12,9s 60c")
    T.eq("the rank step is a thin row of its own", t[7], "Train the next rank before 150")
    T.eq("the run after it", t[8], "Barbaric Gloves | 150-170,24,25s 20c")
    T.eq("with its pattern on the auction house", t[9], "  Learn first: auction house, 85s")
    T.eq("the gap", t[10], "No recipe for 170-190: train elsewhere or missing data")
    T.eq("nothing else", #t, 10)

    local boots, shoulders, rank, gap = rows[2], rows[4], rows[7], rows[10]
    T.check("craft row: path columns", boots.kind == "cols" and boots.layout == "path" and #boots.cols == 3)
    T.eq("craft row: its stage", boots.stage, view.stages[2])
    T.eq("craft row: difficulty colour at the start (orange)", boots.color[2], 0.5)
    T.check("the current run is highlighted", boots.bg[1] > 0.3 and shoulders.bg[1] < 0.3)
    T.eq("other runs carry no mark", shoulders.text, "Shoulders")
    T.check("sub-lines are marked for the list", rows[3].kind == "line" and rows[3].sub == true and rows[5].sub == true)
    T.check("the learn sub-line has the learn step's tooltip",
        rows[3].tooltip[1].text == "Learn Dark Boots" and rows[3].tooltip[2].text == "Learn from: any Leatherworking trainer")
    T.eq("rank row: gold", rank.color[2], 0.82)
    T.eq("rank row: tooltip is the rank sentence", rank.tooltip[1].text,
        "Your cap is 150. Train the next rank at a Leatherworking trainer before you reach 150.")
    T.check("gap row: red", gap.color[1] == 1 and gap.color[2] < 0.6)
    T.eq("gap row: today's tooltip", gap.tooltip[2].text, "No available recipe gives skill-ups in this range.")
    T.eq("craft tooltip: title", boots.tooltip[1].text, "10x Dark Boots")
    T.eq("craft tooltip: how to open", boots.tooltip[#boots.tooltip].text, "Click to open or close")

    boots.onClick()
    T.eq("a click on a run asks to open or close it", calls[#calls], "toggle:" .. BOOTS_KEY)
    rows[3].onClick()
    T.eq("so does a click on its learn sub-line", calls[#calls], "toggle:" .. BOOTS_KEY)
    rows[5].button.onClick()
    T.eq("Use pins the alternative over the run's exact range", calls[#calls], "use:Dark Pants:125-140")
    rows[5].onClick()
    T.eq("a click on the alternative opens its recipe", calls[#calls], "recipe:Dark Pants:125")

    -- Learn sub-line on the VANILLA profile: no source, no fee.
    rows = list(nil, { profile = "VANILLA" })
    T.eq("VANILLA: the learn sub-line names no source", texts(rows)[3], "  Learn the recipe first")

    -- Owned stock lowers a run's cost: green.
    rows = list(nil, { inventory = { [132] = 5 } })
    T.eq("stock: the run costs what is left to buy", rows[4].cols[3], "10s")
    T.check("stock: in green", rows[4].colColors[3][1] < 1 and rows[4].colColors[3][2] == 1)
    T.check("no stock: not green", shoulders.colColors == nil or shoulders.colColors[3] == nil or shoulders.colColors[3][1] == 1)

    -- A reagent to buy without a price: no made-up cost.
    local unpricedPath = listPath()
    unpricedPath.prices[133] = nil
    rows = Views.Path(shopView(unpricedPath, { liveCap = 150, expanded = closed() }), ctx)
    T.eq("a run with an unpriced reagent shows a question mark", rows[6].cols[3], "?")
    T.check("in orange", rows[6].colColors[3][1] == 1 and rows[6].colColors[3][2] == 0.5)

    -- Finished runs: dimmed, "done", their learn step gone, no alternative.
    rows = list({ skill = 141, pantsPrice = 60 })
    t = texts(rows)
    T.eq("done: says so in the cost column", t[2], "Dark Boots | 117-125,10,done")
    T.eq("done: dimmed", rows[2].alpha, 0.5)
    T.eq("done: no learn sub-line, no alternative; the next run follows", t[3], "Shoulders | 125-140,15,done")
    T.eq("the run the skill is in is the current one", t[4], "> Armor Kit | 140-150,12,9s 60c")
    -- The skill is inside the gap: the gap is where the player is.
    rows = list({ skill = 175 })
    T.eq("in a gap: the gap row is marked", texts(rows)[#rows], "> No recipe for 170-190: train elsewhere or missing data")
    -- A rank step, then a gap: the gap is still where the player is.
    local capGap = makePath({ complete = false, currentSkill = 143, actualSkill = 150, prices = PRICES,
        steps = { step(A, 143, 150, 7, 0), step(B, 170, 180, 10, 0) },
        gaps = { { from = 150, to = 170, reason = "no recipe" } } })
    t = texts(Views.Path(shopView(capGap, { liveCap = 150 }), ctx))
    T.eq("rank step before a gap: the rank row", t[3], "Train the next rank before 150")
    T.eq("rank step before a gap: the gap is marked", t[4], "> No recipe for 150-170: train elsewhere or missing data")
    -- The rank step is next: the run after it is still the one to craft.
    rows = list({ skill = 150 })
    t = texts(rows)
    T.eq("rank step next: it is not marked", t[5], "Train the next rank before 150")
    T.eq("rank step next: the run after it is the current one", t[6], "> Barbaric Gloves | 150-170,24,25s 20c")

    -- The closest alternative: shown within a tenth of what the run costs
    -- the player, and always when it is cheaper.
    T.check("exactly a tenth dearer: shown", find(list({ pantsPrice = 110 }), "or: Dark Pants") ~= nil)
    T.check("a copper more than that: not shown", find(list({ pantsPrice = 111 }), "or:") == nil)
    rows = list({ pantsPrice = 60 })
    T.eq("cheaper: always shown, in green", texts(rows)[5], "  or: Dark Pants, |cFF66FF66-6s|r [Use]")
    rows = list({ pantsPrice = 100 })
    T.eq("the same cost", texts(rows)[5], "  or: Dark Pants, same cost [Use]")
    -- A run that pays for itself: only a cheaper alternative.
    local sale = { mode = "vendor", values = { [32] = 100 }, sources = { [32] = "vendor" } }
    T.check("run with no net cost: a dearer alternative is not shown", find(list({ sale = sale }), "or:") == nil)
    sale = { mode = "vendor", values = { [32] = 100, [35] = 120 }, sources = { [32] = "vendor", [35] = "vendor" } }
    rows = list({ sale = sale })
    T.eq("run with no net cost: a cheaper one is", texts(rows)[5], "  or: Dark Pants, |cFF66FF66-1s 50c|r [Use]")
    local gain = { mode = "vendor", values = { [32] = 150 }, sources = { [32] = "vendor" } }
    T.check("run that gains money: a dearer alternative is not shown either", find(list({ sale = gain, pantsPrice = 60 }), "or:") == nil)
    -- An alternative whose recipe has to be learned says so.
    local learnAlt = listPath()
    for _, itemId in ipairs({ 135, 136, 138 }) do learnAlt.prices[itemId] = 500 end
    learnAlt.prices[137] = 1                                -- Fine Pants: 15c of reagents and 30s to learn
    learnAlt.steps[3].recipe.reagents[1].count = 3          -- Shoulders: 45s
    rows = Views.Path(shopView(learnAlt, { liveCap = 150, expanded = closed() }), ctx)
    T.eq("an alternative to learn names the fee", texts(rows)[5], "  or: Fine Pants (learn 30s), |cFF66FF66-14s 85c|r [Use]")
    -- A pinned run: the player already chose.
    local pins = {}
    LazyProf.Pins.Add(pins, 125, 140, 32)
    T.check("pinned run: no inline alternative", find(list({ pantsPrice = 60 }, { pins = pins }), "or:") == nil)

    -- The alternative's tooltip says what the row says: cost over the run,
    -- what its crafts sell for, and the net.
    rows = list({ sale = sale })
    local tip = {}
    for _, line in ipairs(rows[5].tooltip) do tip[#tip + 1] = line.text end
    tip = table.concat(tip, " / ")
    T.check("alternative tooltip: cost and sale over the run",
        tip:find("About 15 crafts for this run: 16s 50c, sells for 18s", 1, true) ~= nil, tip)
    T.check("alternative tooltip: the net", tip:find("Net gain: 1s 50c", 1, true) ~= nil, tip)
    rows = list()
    tip = {}
    for _, line in ipairs(rows[5].tooltip) do tip[#tip + 1] = line.text end
    tip = table.concat(tip, " / ")
    T.check("alternative tooltip, nothing sells: the cost alone",
        tip:find("About 15 crafts for this run: 16s 50c / ", 1, true) ~= nil and tip:find("Net", 1, true) == nil, tip)

    -- Opened in place. The current run is open until the player closes it.
    rows, view = list(nil, { expanded = {} })
    t = texts(rows)
    T.eq("open by default: the current run's reagent table", t[4], "Reagent | Need,Have,Buy,Cost")
    T.eq("its reagent", t[5], "MatDark Boots | 10,0,10,10s")
    T.check("the Buy number is white, not red", rows[5].colColors[3][1] == 1 and rows[5].colColors[3][2] == 1)
    T.eq("still to learn: where", t[6], "Learn from: any Leatherworking trainer")
    T.eq("and the fee", t[7], "Cost: 4s")
    T.eq("and the skill", t[8], "Requires skill 117")
    T.eq("the last line of an opened run", t[9], " [Recipe details]")
    T.eq("then the next run", t[10], "Shoulders | 125-140,15,15s")
    T.check("opened rows are indented", (rows[4].indent or 0) > 0 and (rows[6].indent or 0) > 0)
    rows[9].button.onClick()
    T.eq("Recipe details opens the run's recipe", calls[#calls], "recipe:Dark Boots:117")
    T.eq("closed by the player: nothing under it but the learn line",
        texts(list(nil, { expanded = { [BOOTS_KEY] = false } }))[4], "Shoulders | 125-140,15,15s")

    -- Another run opened: its alternatives.
    rows, view = list(nil, { expanded = closed({ [SHOULDERS_KEY] = true }) })
    t = texts(rows)
    T.eq("opened run: no inline alternative (they are listed below)", t[5], "Reagent | Need,Have,Buy,Cost")
    T.eq("opened run: alternatives header names the range", t[7], "Other recipes for 125-140")
    T.eq("first alternative: cost and crafts difference", t[8], "Dark Pants | +1s 50c  |cFF888888same crafts|r [Use]")
    T.eq("second: more crafts, as its chance falls inside the run", t[9], "Vest | +13s 50c  +4 crafts [Use]")
    T.eq("third", t[10], "Belt | +15s  |cFF888888same crafts|r [Use]")
    T.eq("the rest behind Show all, with the details button", t[11], "Show all 5 [Recipe details]")
    T.eq("then the next run", t[12], "Armor Kit | 140-150,12,9s 60c")
    rows[8].button.onClick()
    T.eq("Use on a listed alternative", calls[#calls], "use:Dark Pants:125-140")
    rows[8].onClick()
    T.eq("a click on a listed alternative opens its recipe", calls[#calls], "recipe:Dark Pants:125")
    rows[11].onClick()
    T.eq("Show all asks for that run", calls[#calls], "all:" .. SHOULDERS_KEY .. ":true")
    rows[11].button.onClick()
    T.eq("Recipe details of that run", calls[#calls], "recipe:Shoulders:125")

    rows = list(nil, { expanded = closed({ [SHOULDERS_KEY] = true }), showAllAlts = { [SHOULDERS_KEY] = true } })
    t = texts(rows)
    T.eq("show all: an alternative to learn", t[11], "Fine Pants (learn 30s) | +33s  |cFF888888same crafts|r [Use]")
    T.eq("show all: the unobtainable one last", t[12], "Hat | |cFF66FF66-7s 50c|r  |cFF888888same crafts|r [Use]")
    T.eq("and dimmed", rows[12].alpha, 0.5)
    T.eq("with its reason in the tooltip", rows[12].tooltip[2].text, "Needs Alchemy")
    T.eq("Show fewer closes it", t[13], "Show fewer [Recipe details]")
    rows[13].onClick()
    T.eq("Show fewer asks for that run", calls[#calls], "all:" .. SHOULDERS_KEY .. ":false")
    -- Shown for one run only.
    rows = list(nil, { expanded = closed({ [SHOULDERS_KEY] = true }), showAllAlts = { [KIT_KEY] = true } })
    T.check("show all is per run", find(rows, "Show all 5") ~= nil)
    -- Fewer crafts, one craft: the run's own recipe turns yellow at 137 and
    -- needs 16 crafts, the alternative stays orange.
    local fewer = listPath()
    fewer.steps[3].recipe.skillRange = { orange = 125, yellow = 137, green = 144, gray = 150 }
    fewer.steps[3].quantity = 16
    rows = Views.Path(shopView(fewer, { liveCap = 150, expanded = closed({ [SHOULDERS_KEY] = true }) }), ctx)
    T.eq("one craft fewer", texts(rows)[8], "Dark Pants | +50c  |cFF66FF66-1 craft|r [Use]")

    -- An alternative that goes grey inside the run cannot cover it: it is
    -- listed after the ones that can, says how far it gets, and is never
    -- offered under the row - however cheap it is.
    rows = list({ scarf = true }, { expanded = closed({ [SHOULDERS_KEY] = true }), showAllAlts = { [SHOULDERS_KEY] = true } })
    t = texts(rows)
    T.eq("goes grey inside the run: after the ones that cover it", t[12], "Scarf | |cFF888888only up to 134|r [Use]")
    T.eq("goes grey inside the run: before the unobtainable one", t[13], "Hat | |cFF66FF66-7s 50c|r  |cFF888888same crafts|r [Use]")
    tip = {}
    for _, line in ipairs(rows[12].tooltip) do tip[#tip + 1] = line.text end
    tip = table.concat(tip, " / ")
    T.check("goes grey inside the run: the tooltip says so",
        tip:find("Gives skill-ups only up to 134, so it cannot cover this run.", 1, true) ~= nil, tip)
    T.check("goes grey inside the run: no cost over a run it cannot do", tip:find("crafts for this run", 1, true) == nil, tip)
    rows[12].button.onClick()
    T.eq("goes grey inside the run: it can still be chosen", calls[#calls], "use:Scarf:125-140")
    rows = list({ onlyScarf = true })
    T.check("goes grey inside the run: never the inline alternative", find(rows, "or:") == nil)

    -- A pinned run says so and offers Reset.
    rows = list(nil, { expanded = closed({ [SHOULDERS_KEY] = true }), pins = pins })
    t = texts(rows)
    T.eq("pinned: your choice, with Reset", t[5], "Your choice [Reset]")
    rows[5].button.onClick()
    T.eq("Reset asks to unpin the run", calls[#calls], "reset:" .. SHOULDERS_KEY)

    -- More options: the colour line, the cost per craft and the market price.
    rows = list(nil, { expanded = {}, advanced = true })
    T.eq("more options: colour changes and cost per craft", texts(rows)[4], "orange all the way; 1s per craft")
    rows = list(nil, { expanded = {}, advanced = true, inventory = { [131] = 4 } })
    T.eq("more options, with stock: the market price too", texts(rows)[4],
        "orange all the way; 60c per craft; market price 10s")
    rows = list(nil, { expanded = {}, inventory = { [131] = 4 } })
    T.eq("without more options: straight to the reagents", texts(rows)[4], "Reagent | Need,Have,Buy,Cost")
    T.eq("stock in the reagent table", texts(rows)[5], "MatDark Boots | 10,4,6,6s")

    -- What a craft sells for.
    sale = { mode = "vendor", values = { [31] = 45 }, sources = { [31] = "vendor" } }
    rows = list({ sale = sale }, { expanded = {} })
    T.eq("sells for, vendor", texts(rows)[6], "Sells for 45c each (vendor)")
    sale = { mode = "auction", values = { [31] = 45 }, sources = { [31] = "auction" } }
    rows = list({ sale = sale }, { expanded = {} })
    T.eq("sells for, auction", texts(rows)[6], "Sells for 45c each (auction, after the 5% cut)")
    sale = { mode = "auction", values = { [31] = 45 }, sources = { [31] = "vendor" } }
    rows = list({ sale = sale }, { expanded = {} })
    T.eq("sells for, auction mode but only a vendor value", texts(rows)[6], "Sells for 45c each (vendor)")

    -- Spare crafts.
    rows = list(nil, { expanded = {}, margin = 15 })
    t = texts(rows)
    T.eq("margin: the row shows the larger count", t[2], "> Dark Boots | 117-125,12,12s")
    T.check("margin: both counts when opened", find(rows, "10 crafts expected, 12 with spare crafts") ~= nil)

    -- The profession window hides the unlearned recipe: said where it is learned.
    rows, view = list(nil, { expanded = {} })
    view.hiddenRecipeId = 31
    rows = Views.Path(view, ctx)
    T.check("hidden by the profession window's filter: the hint", find(rows, "The profession window hides unlearned recipes") ~= nil)
    view.hiddenRecipeId = 34
    T.check("not on another recipe's run", find(Views.Path(view, ctx), "The profession window hides unlearned recipes") == nil)

    -- Trainers the player visited: under the learn lines and in the rank tooltip.
    LazyProf.TrainerMemory = { Trainers = function(_, profKey, recipeId)
        if profKey ~= "leatherworking" then return {} end
        return { { name = recipeId and "Bob" or "Ann", zone = "Stormwind", x = 0.53, y = 0.81 } }
    end }
    rows = list(nil, { expanded = {} })
    local _, at = find(rows, "Trainers you visited that teach it:")
    T.check("visited trainers are named", at ~= nil and rows[at + 1].text == "Bob - Stormwind (53, 81)")
    local rankRow = find(rows, "Train the next rank")
    T.eq("rank tooltip: visited trainers", rankRow.tooltip[#rankRow.tooltip].text, "  Ann - Stormwind (53, 81)")
    rows = list(nil, { expanded = {}, profile = "VANILLA" })
    T.check("VANILLA: no trainer is named for a recipe", find(rows, "Trainers you visited that teach it:") == nil)
    T.eq("VANILLA: the opened run says only to learn it", texts(rows)[6], "Learn the recipe. The recipe details show what is known about it.")
    LazyProf.TrainerMemory = nil

    -- A green recipe bridging a gap says why it is there.
    local bridge = makePath({ complete = true })
    rows = Views.Path(shopView(bridge, { expanded = { ["craft:1:143"] = false, ["craft:2:160"] = true } }), ctx)
    T.check("bridge: the sentence", find(rows, "No orange or yellow recipe is available here") ~= nil)
    T.eq("colour changes of a run that crosses a threshold", LazyProf.GuideText.ColorChanges(Stages.Build(bridge)[1]),
        "orange until 150, then yellow")

    -- Nothing left, no path, no stages.
    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    T.eq("nothing left: the notice replaces the list", Views.Path(shopView(done), ctx)[1].text,
        "Nothing left: Tailoring is at its cap of 300.")
    T.eq("no path: no rows", #Views.Path({}, ctx), 0)

    for _, r in ipairs(Views.Path(shopView(listPath(), { liveCap = 150, expanded = { [SHOULDERS_KEY] = true }, advanced = true }), ctx)) do
        for _, text in ipairs({ r.text or "", r.right or "" }) do
            if text:find("[\128-\255]") then T.check("path text is plain ASCII", false, text) end
            if text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):find("|", 1, true) then
                T.check("path text: pipes only in colour codes", false, text)
            end
        end
    end
end)

T.section("shopping rows", function()
    local chosen = {}
    local ctx = { onCraftChoice = function(row, choice) chosen[#chosen + 1] = { row.itemId, choice == nil and "auto" or choice } end }
    -- (The craft / buy button belongs to the advanced controls.)
    local function shop(rows)
        return Views.Shopping({ path = makePath(), missing = { rows = rows }, advanced = true }, ctx)
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

-- The Shopping tab: what is left to buy first, dearest first; then what the
-- character makes; then what is already owned; the two sums of the receipt.
T.section("shopping list", function()
    local THREAD, LEATHER, DYE, DUST, SILK = 161, 162, 163, 164, 165
    local shirt = recipe(40, "Shirt", 100, 150, 160, 170, { reagents = {
        { itemId = BOLT, count = 2, name = "Bolt" }, { itemId = THREAD, count = 1, name = "Thread" } } })
    local hat = recipe(41, "Hat", 110, 150, 160, 170, { unlearned = true, sourceInfo = { type = "ah", price = 8500, source = "TSM" },
        reagents = { { itemId = LEATHER, count = 2, name = "Leather" }, { itemId = DUST, count = 1, name = "Dust" } } })
    local belt = recipe(42, "Belt", 120, 150, 160, 170, { unlearned = true, sourceInfo = { type = "trainer", cost = 400 },
        reagents = { { itemId = DYE, count = 1, name = "Dye" }, { itemId = SILK, count = 3, name = "Silk" } } })
    -- Dust has no price. Ten of each recipe: 20 Bolt (made from 60 Cloth),
    -- 10 Thread, 20 Leather, 10 Dust, 10 Dye, 30 Silk.
    local prices = { [BOLT] = 500, [CLOTH] = 100, [THREAD] = 10, [LEATHER] = 300, [DYE] = 50, [SILK] = 200 }
    local function shopPath()
        return makePath({ complete = true, gaps = {}, currentSkill = 100, actualSkill = 100, prices = prices,
            steps = { step(shirt, 100, 110, 10, 0), step(hat, 110, 120, 10, 0), step(belt, 120, 130, 10, 0) } })
    end
    local stock = { [DYE] = 25, [SILK] = 12 }
    local chosen, shown = {}, {}
    local ctx = {
        onCraftChoice = function(row, choice) chosen[#chosen + 1] = { row.itemId, choice == nil and "auto" or choice } end,
        onShowRecipe = function(r) shown[#shown + 1] = r.name end,
    }
    local function texts(rows)
        local out = {}
        for _, r in ipairs(rows) do
            if r.kind == "sep" then
                out[#out + 1] = "---"
            else
                out[#out + 1] = (r.text or "") .. (r.cols and (" | " .. table.concat(r.cols, ",")) or "")
                    .. (r.button and (" [" .. r.button.text .. "]") or "")
            end
        end
        return out
    end
    local function shopping(opts)
        opts = opts or {}
        opts.inventory = opts.inventory or stock
        local view = shopView(shopPath(), opts)
        return Views.Shopping(view, ctx), view
    end

    local rows, view = shopping()
    local t = texts(rows)
    T.eq("table header", t[1], "Reagent | Need,Have,Buy,Cost")
    T.eq("to buy, dearest first (same cost: by name)", t[2], "Cloth | 60,0,60,60s")
    T.eq("second", t[3], "Leather | 20,0,20,60s")
    T.eq("third, partly owned", t[4], "Silk | 30,12,18,36s")
    T.eq("the cheapest priced one", t[5], "Thread | 10,0,10,1s")
    T.eq("a reagent without a price is last of those to buy", t[6], "Dust | 10,0,10,?")
    T.eq("then what the character makes", t[7], "Bolt | 20,0,-,")
    T.eq("with what it is made from beneath", t[8], "Cloth | 60,,,")
    T.eq("then what is already owned", t[9], "Dye | 10,25,-,-")
    T.eq("the reagents total under the table", t[10], "Reagents to buy | ,,,1g 57s")
    T.eq("a rule, then the recipes", t[11] .. " " .. t[12], "--- Recipes to learn")
    T.eq("a recipe to learn: where from and its price", t[13], "Belt - trainer | ,,,4s")
    T.eq("by name", t[14], "Hat - auction house | ,,,85s")
    T.eq("the recipes total", t[15], "Recipes | ,,,89s")
    T.eq("nothing else", #t, 15)

    -- The two totals are the receipt's two parts.
    T.eq("reagents total is the account's reagents", rows[10].cols[4], LazyProf.Utils.FormatMoneyShort(view.account.reagents))
    T.eq("recipes total is the account's recipes", rows[15].cols[4], LazyProf.Utils.FormatMoneyShort(view.account.recipes))
    T.eq("and the receipt says the same", Views.Receipt(view)[1].note, "reagents 1g 57s + recipes 89s")
    local costs = 0
    for _, r in ipairs(rows) do
        if r.item then costs = costs + (r.item.cost or 0) end
    end
    T.eq("the Cost column adds up to the reagents total", costs, view.account.reagents)

    -- Colours: nothing red; Have is green when it covers Need; owned rows dimmed.
    local silk, dye, dust, bolt = rows[4], rows[9], rows[6], rows[7]
    T.check("the Buy number is white", silk.colColors[3][1] == 1 and silk.colColors[3][2] == 1 and silk.colColors[3][3] == 1)
    T.check("Have is white while it does not cover Need", silk.colColors[2][1] == 1)
    T.check("Have is green when it does", dye.colColors[2][1] < 1 and dye.colColors[2][2] == 1)
    T.eq("a fully owned row is dimmed", dye.alpha, 0.55)
    T.check("rows to buy are not", silk.alpha == nil or silk.alpha == 1)
    T.check("a missing price is orange", dust.colColors[4][1] == 1 and dust.colColors[4][2] == 0.5)
    T.eq("the child row is indented", rows[8].indent, 14)

    -- The craft / buy button and "Hide what I have" belong to More options.
    T.check("more options off: no craft / buy button", bolt.button == nil)
    rows = shopping({ hideOwned = true })
    T.check("more options off: hide-owned does not act (its checkbox is hidden)", texts(rows)[9] == "Dye | 10,25,-,-")
    rows = shopping({ advanced = true })
    t = texts(rows)
    T.eq("more options on: the button, on a reagent the character can make", t[7], "Bolt | 20,0,-, [I craft it]")
    T.check("and on no other row", rows[2].button == nil and rows[9].button == nil)
    rows[7].button.onClick("LeftButton")
    T.check("its click switches the choice", chosen[#chosen][1] == BOLT and chosen[#chosen][2] == "buy")
    rows = shopping({ advanced = true, hideOwned = true })
    t = texts(rows)
    T.eq("more options on, hide-owned: owned rows go", t[9], "Reagents to buy | ,,,1g 57s")
    T.eq("crafted rows stay", t[7], "Bolt | 20,0,-, [I craft it]")

    -- A recipe row opens the recipe; its tooltip says how to learn it.
    rows = shopping()
    rows[14].onClick()
    T.eq("a click on a recipe row opens the recipe", shown[#shown], "Hat")
    T.eq("recipe row tooltip", rows[14].tooltip[2].text, "Listed on the auction house.")

    -- VANILLA: the recipe data's sources are not trusted, so none is named;
    -- the amounts stay, because the receipt has to add up from these rows.
    rows = shopping({ profile = "VANILLA" })
    t = texts(rows)
    T.eq("VANILLA: recipe and price only", t[13], "Belt | ,,,4s")
    T.eq("VANILLA: second", t[14], "Hat | ,,,85s")
    T.eq("VANILLA: the total is unchanged", t[15], "Recipes | ,,,89s")
    T.eq("VANILLA: the tooltip names no source", rows[14].tooltip[2].text,
        "Learn the recipe. The recipe details show what is known about it.")

    -- No recipe costs anything: no recipe section.
    local known = shopPath()
    known.steps = { step(shirt, 100, 110, 10, 0) }
    rows = Views.Shopping(shopView(known), ctx)
    t = texts(rows)
    T.eq("no recipes to learn: the list ends with the reagents total", t[#t], "Reagents to buy | ,,,61s")

    -- Everything owned.
    rows = shopping({ inventory = { [BOLT] = 20, [THREAD] = 10, [LEATHER] = 20, [DUST] = 10, [DYE] = 10, [SILK] = 30 } })
    t = texts(rows)
    T.eq("nothing to buy says so", t[1], "Nothing left to buy.")
    T.eq("the owned rows follow, by name", t[3] .. " / " .. t[4], "Bolt | 20,20,-,- / Dust | 10,10,-,-")
    T.eq("a zero total", t[9], "Reagents to buy | ,,,0c")
    T.eq("the recipes still cost", t[#t], "Recipes | ,,,89s")

    -- Owned stock that is not in the bags: collect it first, as before.
    local view2 = shopView(shopPath())
    view2.account = Pathfinder:Account(Stages.ShoppingSteps(view2.stages), { [SILK] = 30 }, { [SILK] = { bank = 30 } }, prices)
    view2.missing = view2.account.missing
    t = texts(Views.Shopping(view2, ctx))
    T.eq("collect first block", t[1], "Collect first")
    T.eq("from the bank", t[2], "30x Silk")
    T.eq("a rule before the table", t[3] .. " " .. t[4], "--- Reagent | Need,Have,Buy,Cost")

    -- No reagents at all, nothing left.
    T.eq("no reagents needed", texts(Views.Shopping({ path = makePath(), missing = { rows = {} } }, ctx))[1],
        "No reagents needed in this path.")
    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    T.eq("nothing left: the notice", Views.Shopping(shopView(done), ctx)[1].text, "Nothing left: Tailoring is at its cap of 300.")
end)

-- The target slider's model: from the real skill to the last cap.
T.section("target", function()
    local function target(extra)
        return Views.Target({ path = makePath(extra), skill = (extra or {}).actualSkill or 143 })
    end
    local m = target({ currentSkill = 117, actualSkill = 117, targetSkill = 225 })
    T.eq("left end: the real skill", m.min, 117)
    T.eq("right end: the last cap", m.max, 300)
    T.eq("value: the target", m.value, 225)
    T.eq("it can be moved", m.enabled, true)
    T.eq("left label", m.leftLabel, "117")
    T.eq("right label", m.rightLabel, "300")

    m = target({ currentSkill = 117, actualSkill = 117, targetSkill = 300 })
    T.eq("target at the cap: the handle is at the right end", m.value, 300)
    T.eq("and can be moved down", m.enabled, true)

    -- No room to move: the target cannot go below the real skill + 1.
    m = target({ currentSkill = 299, actualSkill = 299, targetSkill = 300 })
    T.check("skill one below the cap: the only target is the cap", m.enabled == false and m.value == 300)
    T.check("its range is not inverted", m.min == 299 and m.max == 300 and m.min <= m.max)
    m = target({ currentSkill = 298, actualSkill = 298, targetSkill = 300 })
    T.eq("two below the cap: there is a choice", m.enabled, true)
    m = target({ currentSkill = 300, actualSkill = 300, targetSkill = 300, steps = {}, gaps = {}, nothingLeft = true })
    T.check("skill at the cap: nothing to move", m.enabled == false and m.min == 300 and m.max == 300 and m.value == 300)
    m = target({ currentSkill = 315, actualSkill = 315, targetSkill = 300, steps = {}, gaps = {}, nothingLeft = true })
    T.check("skill past the cap: still no inverted range", m.enabled == false and m.min <= m.max and m.value == 300)

    -- Target reached (the stored target is at or below the skill): the
    -- handle sits at the left end and the target can be raised.
    m = target({ currentSkill = 200, actualSkill = 200, targetSkill = 180, steps = {}, gaps = {}, nothingLeft = true })
    T.check("target reached: clamped to the real skill, still movable", m.value == 200 and m.min == 200 and m.enabled == true)

    -- A profession the character does not have starts at 1.
    m = target({ hasProfession = false, currentSkill = 1, actualSkill = 1, targetSkill = 150 })
    T.check("not learned: the left end is 1", m.min == 1 and m.leftLabel == "1" and m.value == 150 and m.enabled == true)
    -- "Plan from skill 1" changes where the plan starts, not the left end.
    m = target({ planFromOne = true, currentSkill = 1, actualSkill = 143, targetSkill = 225 })
    T.eq("what-if from 1: the left end stays the real skill", m.min, 143)
    -- The view's skill wins over the path's when both are there.
    m = Views.Target({ path = makePath({ actualSkill = 143, targetSkill = 225 }), skill = 150 })
    T.eq("the view's skill is the real skill", m.min, 150)
    m = Views.Target({ path = makePath({ actualSkill = 143, targetSkill = 225 }) })
    T.eq("else the path's", m.min, 143)

    T.check("no path: no model", Views.Target({}) == nil)
    T.check("no cap known: no model", Views.Target({ path = makePath({ capSkill = false, milestones = {} }) }) == nil)
    m = Views.Target({ path = makePath({ capSkill = false, actualSkill = 117, targetSkill = 225 }) })
    T.eq("the cap from the profession's milestones when the path names none", m.max, 300)
end)

T.section("arrow tooltip", function()
    local function lines(view)
        local out = {}
        for _, l in ipairs(Views.ArrowTooltip(view)) do
            out[#out + 1] = l.right and ((l.text:gsub("%s+$", "")) .. " | " .. l.right) or l.text
        end
        return out
    end
    local function sold(mode, values)
        return { mode = mode, values = values, sources = {}, rank = {}, loading = 0, loadingItems = {} }
    end
    local view = shopView(makePath(), { priceLines = { { text = "Prices: TSM 2", r = 0.6, g = 0.6, b = 0.6 } } })
    local t = lines(view)
    T.eq("title", t[1], "LazyProf - Optimal Path")
    T.eq("the current step and its cost", t[3], "Now: 19x Gloves | 19s")
    T.eq("its skill range", t[4], "   Skill 143 to 160")
    T.eq("the next step", t[5], "Then: 20x Shirt (green: no better recipe) | 40s")
    T.eq("the one after", t[6], "Then: No recipe for 180-200: train elsewhere or missing data")
    T.eq("the rest is on the Path tab", t[7], "... and 2 more steps (see the Path tab)")
    T.eq("what is spent, flagged when the path has gaps", t[9], "You spend (excluding gaps): | 59s")
    T.eq("labels keep their colon and space for the two-column line", Views.ArrowTooltip(view)[9].text, "You spend (excluding gaps): ")
    T.eq("price lines last", t[11], "Prices: TSM 2")
    T.eq("no more lines than that: nothing sells, so no other amount", #t, 11)

    -- What the crafts sell for: the receipt's three lines.
    view = shopView(makePath({ complete = true, sale = sold("vendor", { [1] = 30 }) }))
    t = lines(view)
    T.eq("sale value: spend", t[9], "You spend: | 59s")
    T.eq("sale value: back", t[10], "Back from selling: | -5s 70c")
    T.eq("sale value: net", t[11], "Net cost: | 53s 30c")
    T.eq("sale value: nothing after the net", #t, 11)
    local all = Views.ArrowTooltip(view)
    T.check("money that comes back is green", all[10].rr < 1 and all[10].rg == 1)
    T.check("what is spent is not", all[9].rr == 1 and all[9].rg == 1 and all[9].rb == 1)
    view = shopView(makePath({ complete = true, sale = sold("auction", { [1] = 400 }) }))
    t = lines(view)
    T.eq("a gain is worded as a gain", t[11], "Net gain: | 17s")
    T.eq("the receipt and the tooltip agree", t[11], Views.Receipt(view)[3].label .. ": | " .. Views.Receipt(view)[3].amount)

    -- Owned stock: the amount is what is left to pay.
    view = shopView(makePath({ complete = true }), { inventory = { [101] = 19 } })
    t = lines(view)
    T.eq("stock: the current step costs nothing", t[3], "Now: 19x Gloves | 0c")
    T.eq("stock: what is spent", t[9], "You spend: | 40s")
    T.eq("stock: one amount", #t, 9)

    -- Spare crafts: the amount covers them, and says so.
    view = shopView(makePath({ complete = true }), { margin = 15 })
    t = lines(view)
    T.eq("margin: the larger count", t[3], "Now: 22x Gloves | 22s")
    T.eq("margin: the amount covers the spare crafts", t[9], "You spend: | 68s")
    T.eq("margin: and says so", t[10], "Includes 15% spare crafts")

    -- Learn and rank steps as the current step
    local boots = recipe(8, "Boots", 143, 200, 210, 220, { unlearned = true, sourceInfo = { type = "vendor", cost = 1500 } })
    local path = makePath({ complete = true, gaps = {}, totalCost = 3200, prices = { [108] = 100 },
        steps = { step(boots, 143, 150, 7, 7 * 100 + 1500), step(boots, 150, 160, 10, 1000) } })
    view = shopView(path, { liveCap = 150 })
    t = lines(view)
    T.eq("learn step first, with its fee", t[3], "Now: Learn Boots | 15s")
    T.eq("where it comes from", t[4], "   Sold by a vendor.")
    T.eq("then the craft", t[7], "Then: 7x Boots | 7s")
    T.eq("then the rank step", t[8], "Then: Train the next rank before 150")
    T.eq("one more step, on the Path tab", t[9], "... and 1 more step (see the Path tab)")
    T.eq("what is spent includes the fee", t[11], "You spend: | 32s")

    -- Nothing left, and no path
    local done = makePath({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 })
    t = lines(shopView(done))
    T.eq("nothing left says so", t[3], "Nothing left: Tailoring is at its cap of 300.")
    T.eq("nothing left: no amounts", #t, 3)
    T.eq("no path: just the title", #lines({}), 1)
    -- A view without an account (none was worked out) shows no amounts.
    t = lines(makeView(makePath(), { range = "all" }))
    T.eq("no account: the steps only", #t, 7)
    for _, l in ipairs(Views.ArrowTooltip(view)) do
        if l.text:find("[\128-\255]") then T.check("tooltip text is plain ASCII", false, l.text) end
    end
end)

T.finish()
