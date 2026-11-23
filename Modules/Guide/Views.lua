-- Modules/Guide/Views.lua
-- What the LazyProf window shows, as plain data. Each function turns the
-- window's state (the path, its stages, the chosen range, what is expanded)
-- into text and row descriptors for Widgets/RowList.lua. Nothing here touches
-- a frame, so the content of every tab is tested headlessly; the frame code
-- only places widgets and passes clicks back through `ctx` callbacks.
--
-- `view` is built by the window (GuideWindow:ComputeView):
--   path, stages, summary        the path, all its stages, Stages.Totals of them
--   account                      Pathfinder:Account of the whole path's stages (the
--                                shopping list, what is spent, what the crafts sell
--                                for, the net) plus stockSaves, what the owned
--                                stock takes off the amount spent
--   sale, saleLoading            the path's sale values (mode, sources) and how
--                                many crafted items still wait for their data now
--   advanced                     "More options" is on
--   rangeStages, rangeTotals     the stages of the chosen range and their totals
--   bracket, rangeLabel          the chosen range (nil = full path) and its label
--   skill, cap                   the real skill and the live cap (nil when unknown)
--   priceSummary, priceLines     PriceManager:PathSummary / SummaryLines of the path
--   marginPercent                nil when the margin is off
--   expanded                     { [stage.key] = true } rows opened on the Steps tab; in
--                                the path list also false = closed by the player
--   showAllAlts                  path list: { [stage.key] = true } runs that list
--                                every alternative (the Guide card: one boolean)
--   profile, liveCap             the client profile ("VANILLA", ...) and the cap the
--                                character works under
--   hiddenRecipeId               the next recipe when the profession window hides it
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils
local Text = LazyProf.GuideText
local SALE_MODE = LazyProf.Constants.SALE_MODE

local Views = {}
LazyProf.GuideViews = Views

local DIFFICULTY_COLOR = {
    orange = { 1, 0.5, 0.25 },
    yellow = { 1, 1, 0 },
    green = { 0.25, 0.75, 0.25 },
    gray = { 0.5, 0.5, 0.5 },
}
Views.DIFFICULTY_COLOR = DIFFICULTY_COLOR

local WHITE = { 1, 1, 1 }
local GOLD = { 1, 0.82, 0 }
local GREY = { 0.7, 0.7, 0.7 }
local DIM = { 0.5, 0.5, 0.5 }
local GREEN = { 0.4, 1, 0.4 }
local ORANGE = { 1, 0.5, 0 }
local GAP_RED = { 1, 0.5, 0.4 }

local BG_ROW = { 0.15, 0.15, 0.15, 0.3 }
local BG_ROW_HOVER = { 0.25, 0.25, 0.25, 0.6 }
local BG_CURRENT = { 0.35, 0.28, 0.05, 0.55 }
local BG_CURRENT_HOVER = { 0.45, 0.36, 0.1, 0.7 }
local BG_GAP = { 0.35, 0.1, 0.1, 0.35 }
local BG_GAP_HOVER = { 0.45, 0.15, 0.15, 0.6 }
local BG_SUB = { 0.12, 0.12, 0.12, 0.5 }

-- An amount to the copper (whole copper only: a price per item of a bundle
-- can be a fraction). Every amount that is added to another, or is the sum
-- of amounts shown, is written with this.
local function Money(copper)
    return Text.Money(copper)
end

local function Green(text)
    return "|cFF66FF66" .. text .. "|r"
end

local function Grey(text)
    return "|cFF888888" .. text .. "|r"
end

function Views.DifficultyColor(color)
    return DIFFICULTY_COLOR[color] or DIFFICULTY_COLOR.gray
end

-- Header ---------------------------------------------------------------------

-- Title, status line and price line of the shared header.
--   title        "LazyProf - Tailoring"
--   status       "Skill 143 / 150 (+15 racial)" | "Not learned yet - planned from skill 1"
--   priceText    "Prices: TSM 12, vendor 3" ("" when the path has no reagents)
--   priceColor   orange when a price is missing, still loading or too old
--   priceTooltip the full price-source lines
function Views.Header(view)
    local path = view.path
    local header = { title = "LazyProf" }
    if not path then
        header.status, header.priceText, header.priceColor, header.priceTooltip = "", "", GREY, {}
        return header
    end
    header.title = "LazyProf - " .. tostring(path.profession)

    if path.hasProfession == false then
        header.status = "Not learned yet - planned from skill 1"
    else
        local status = "Skill " .. tostring(view.skill or path.actualSkill or "?")
        if view.cap then
            status = status .. " / " .. tostring(view.cap)
        end
        if (path.racialBonus or 0) > 0 then
            status = status .. string.format(" (+%d racial)", path.racialBonus)
        end
        if path.planFromOne then
            status = status .. " - planned from skill 1"
        end
        header.status = status
    end

    local lines = view.priceLines or {}
    header.priceTooltip = lines
    header.priceText = lines[1] and lines[1].text or ""
    local s = view.priceSummary
    local problem = s and ((s.stale or 0) > 0 or (s.unpriced or 0) > 0 or (s.loading or 0) > 0)
    header.priceColor = problem and ORANGE or GREY
    return header
end

-- Receipt ----------------------------------------------------------------------

-- The two largest units only ("12g 34s"): for comparisons - an alternative's
-- difference, a cost per craft - never for an amount that is added up.
local function Short(copper)
    return Utils.FormatMoneyShort(copper)
end

local function Round(copper)
    return math.floor((copper or 0) + 0.5)
end

-- What the path costs, as the lines of a receipt. Built from the account of
-- the whole path (view.account: the shopping list of the stages' quantities,
-- less what the crafts sell for), so "You spend" is the Shopping tab added up.
-- Returns { { key, label, amount, note, amountColor, color }, ... }:
--   key          "spend" | "back" | "net" | "stock" | "making" | "margin" | "problem"
--   label        "You spend", ...; nil on a line that is only a note
--   amount       money text for the right-aligned column; nil: a note-only line
--   note         the text after the amount (may be nil), or the whole of a
--                note-only line
--   amountColor  { r, g, b } of the amount (green: money that comes back)
--   color        { r, g, b } of the note
-- Lines, in order:
--   spend    reagents still to buy plus recipes to buy or learn
--   back     what the crafts sell for (not when sale values are not counted,
--            or nothing sells and nothing is still loading)
--   net      spend less back, a gain when the crafts sell for more (only with back)
--   stock    what the owned stock saves, when there is no net line to say it on
--   making   the list makes reagents instead of buying them, so the path's
--            cost column (each run's direct reagents at buy prices) adds up
--            to more or less than the reagents amount: by how much (not said
--            while something that has to be bought has no price)
--   margin   the amounts include spare crafts
--   problem  a price is missing, still loading or too old: the price
--            summary's first problem line, else how many rows of the list
--            have something to buy and no price
-- Every amount is written to the copper, so the lines add up as shown.
function Views.Receipt(view)
    local lines = {}
    local path, account = view.path, view.account
    if not path or not account or path.nothingLeft then return lines end
    local function add(line)
        line.color = line.color or GREY
        lines[#lines + 1] = line
    end

    local spent = Round(account.spend)
    local spend = { key = "spend", label = "You spend", amount = Money(spent), amountColor = WHITE }
    if path.complete == false then
        spend.label = spend.label .. " (excluding gaps)"
    end
    if (account.recipes or 0) > 0 then
        spend.note = "reagents " .. Money(account.reagents) .. " + recipes " .. Money(account.recipes)
    end
    add(spend)

    local saves = Round(account.stockSaves)
    local saved = saves > 0 and Money(saves) or nil
    local mode = view.sale and view.sale.mode or SALE_MODE.NONE
    local loading = (view.saleLoading or 0) > 0
    local back = Round(account.sale)
    if mode ~= SALE_MODE.NONE and (back > 0 or loading) then
        add({ key = "back", label = "Back from selling", amount = back > 0 and ("-" .. Money(back)) or Money(0),
              amountColor = GREEN, note = Text.SoldNote(mode) .. (loading and ", still loading" or "") })
        local net = spent - back
        add({ key = "net", label = net < 0 and "Net gain" or "Net cost", amount = Money(math.abs(net)),
              amountColor = net < 0 and GREEN or WHITE, note = saved and ("your own stock saves " .. saved) or nil })
    elseif saved then
        add({ key = "stock", note = "Your own stock saves " .. saved })
    end

    -- Rows with something to buy and no price: the amounts leave them out.
    local crafted, unpriced = {}, 0
    for _, row in ipairs(account.missing and account.missing.rows or {}) do
        if row.crafted then crafted[#crafted + 1] = row end
        if (row.toBuy or 0) > 0 and row.unpriced then unpriced = unpriced + 1 end
    end
    -- What making reagents saves is only known when everything bought for
    -- them has a price.
    local columnPay = view.summary and view.summary.columnPay
    if #crafted > 0 and columnPay and unpriced == 0 then
        local saving = Round(columnPay - account.reagents)
        if saving ~= 0 then
            local what = string.format("%d reagents", #crafted)
            if #crafted == 1 then
                what = string.format("%d %s", crafted[1].craftQuantity or 0, crafted[1].name or "Unknown")
            end
            if saving > 0 then
                add({ key = "making", note = "Making " .. what .. " yourself saves " .. Money(saving) })
            else
                add({ key = "making", note = "Making " .. what .. " yourself costs " .. Money(-saving) .. " more than buying" })
            end
        end
    end

    if view.marginPercent then
        add({ key = "margin", note = string.format("Includes %d%% spare crafts", view.marginPercent) })
    end

    -- The price summary looks at the path's own reagents; what the list buys
    -- to make reagents can lack a price as well.
    local problem
    for _, line in ipairs(view.priceLines or {}) do
        if line.problem then
            problem = line.text
            break
        end
    end
    if not problem and unpriced > 0 then
        problem = unpriced == 1 and "1 reagent on the list has no price - the amounts leave it out."
            or (tostring(unpriced) .. " reagents on the list have no price - the amounts leave them out.")
    end
    if problem then
        add({ key = "problem", note = problem, color = ORANGE })
    end
    return lines
end

-- Target ------------------------------------------------------------------------

-- The target slider's model, or nil without a path (or a cap):
--   min, max     the real skill (1 for a profession the character does not
--                have) and the last cap; never inverted
--   value        the path's target, clamped into that range
--   enabled      there is something to choose: the target can be no lower
--                than the real skill + 1, so one point of room is none
--   leftLabel, rightLabel   the two ends as text
function Views.Target(view)
    local path = view.path
    if not path then return nil end
    local milestones = path.milestones or {}
    local max = path.capSkill or milestones[#milestones]
    if not max then return nil end
    local min = 1
    if path.hasProfession ~= false then
        min = view.skill or path.actualSkill or 1
    end
    min = math.max(1, math.min(min, max))
    local value = math.max(min, math.min(max, path.targetSkill or max))
    return {
        min = min, max = max, value = value,
        enabled = (max - min) > 1,
        leftLabel = tostring(min), rightLabel = tostring(max),
    }
end

-- Footer ---------------------------------------------------------------------

local function PayText(totals, marginSide)
    local cost = marginSide and totals.marginCost or totals.cost
    local pay = marginSide and totals.marginPay or totals.pay
    local text = Money(pay)
    if pay < cost then text = Green(text) end
    return text
end

-- "This range: X   Whole path: Y (you pay Z)", plus a second line with the
-- with-margin figures when the margin is on. Returns line1, line2 (or nil).
function Views.Footer(view)
    local path = view.path
    if not path or not view.summary then return "", nil end
    local all, range = view.summary, view.rangeTotals
    local whole = Text.TotalLabel(path, "Whole path") .. Money(all.cost)
        .. " (you pay " .. PayText(all) .. ")"
    local line1 = whole
    if view.bracket and range then
        line1 = "This range: " .. PayText(range) .. "     " .. whole
    end

    local line2
    if all.marginCost then
        line2 = string.format("With %d%% margin: ", view.marginPercent or 0)
        if view.bracket and range and range.marginCost then
            line2 = line2 .. "range " .. PayText(range, true) .. ", "
        end
        line2 = line2 .. "whole path " .. Money(all.marginCost) .. " (you pay " .. PayText(all, true) .. ")"
    end
    return line1, line2
end

-- Messages instead of a list ---------------------------------------------------

-- Rows to show instead of the tab's content, or nil: nothing is left to plan,
-- or the chosen range holds no step.
function Views.Notice(view)
    local path = view.path
    if not path then return nil end
    local function message(text, more)
        local rows = { { kind = "line", height = 26, text = text, color = { 0.8, 0.8, 0.8 }, wrap = true } }
        if more then
            rows[#rows + 1] = { kind = "line", height = 22, text = more, color = DIM, wrap = true }
        end
        return rows
    end
    if path.nothingLeft then
        local skill = view.skill or path.actualSkill or 0
        if path.capSkill and skill >= path.capSkill then
            return message(string.format("Nothing left: %s is at its cap of %d.", tostring(path.profession), path.capSkill))
        end
        return message(string.format("Target reached: skill %d, target %d.", skill, path.targetSkill or 0),
            "Raise the target to keep planning.")
    end
    if view.rangeStages and #view.rangeStages == 0 then
        return message("No steps in " .. (view.bracket and view.bracket.name or "this range"))
    end
    return nil
end

-- Reagent table ----------------------------------------------------------------

local COLUMN_TITLES = { "Need", "Have", "Buy", "Cost" }

function Views.ReagentHeader(indent)
    return { kind = "cols", header = true, indent = indent, text = "Reagent", cols = COLUMN_TITLES }
end

-- One reagent of a craft stage: need / have / buy / cost. A reagent with no
-- price shows "?" instead of a made-up cost.
function Views.ReagentRow(mat, indent)
    local buy = mat.missing > 0 and tostring(mat.missing) or "-"
    local cost
    if mat.missing <= 0 then
        cost = "-"
    elseif not mat.price then
        cost = "?"
    else
        cost = Money(mat.estimatedCost)
    end
    local tooltip = {}
    local pm = LazyProf.PriceManager
    if pm and pm.PeekPriceInfo then
        tooltip[#tooltip + 1] = { text = pm.PriceLine(pm:PeekPriceInfo(mat.itemId)), r = 0.7, g = 0.7, b = 0.7 }
    elseif not mat.price then
        tooltip[#tooltip + 1] = { text = "No price known for this item", r = 0.7, g = 0.7, b = 0.7 }
    end
    tooltip[#tooltip + 1] = { text = "Shift-click to link", r = 0.5, g = 0.5, b = 0.5 }
    return {
        kind = "cols", indent = indent, icon = mat.icon, text = mat.name,
        cols = { tostring(mat.need), tostring(mat.have), buy, cost },
        colColors = {
            [2] = mat.have >= mat.need and GREEN or WHITE,
            [3] = mat.missing > 0 and WHITE or DIM,
            [4] = (mat.missing > 0 and not mat.price) and ORANGE or WHITE,
        },
        bg = BG_SUB, hoverBg = BG_ROW_HOVER,
        itemId = mat.itemId, link = mat.link, tooltip = tooltip,
    }
end

-- Steps tab --------------------------------------------------------------------

local BRIDGE_TEXT = "No orange or yellow recipe is available here, so this green recipe keeps you leveling."

-- Tooltip of a craft stage. opts (optional): spareWord, how the margin is
-- called ("margin" by default); unpriced = true when a reagent that has to be
-- bought has no price, so no cost is stated.
local function CraftTooltip(stage, opts)
    opts = opts or {}
    local lines = {
        { text = Text.StageTitle(stage), r = 1, g = 1, b = 1 },
        { text = string.format("Skill %d to %d", stage.fromDisplay, stage.toDisplay), r = 0.7, g = 0.7, b = 0.7 },
        { text = Text.ColorChanges(stage), r = 0.7, g = 0.7, b = 0.7 },
    }
    if stage.bridge then
        lines[#lines + 1] = { text = BRIDGE_TEXT, r = 0.25, g = 0.75, b = 0.25 }
    end
    local pay, cost = stage.outOfPocketCost, stage.cost
    if opts.unpriced then
        lines[#lines + 1] = { text = "A reagent has no price, so the cost is not known.", r = 1, g = 0.5, b = 0 }
    else
        if stage.quantity > 0 then
            local perCraft = math.floor(pay / stage.quantity + 0.5)
            lines[#lines + 1] = { text = "Per craft: " .. Money(perCraft), r = 1, g = 1, b = 1 }
        end
        if pay < cost then
            lines[#lines + 1] = { text = string.format("You pay: %s (market price %s)", Money(pay), Money(cost)), r = 0.4, g = 1, b = 0.4 }
        else
            lines[#lines + 1] = { text = "Cost: " .. Money(cost), r = 1, g = 1, b = 1 }
        end
        local gained = stage.to - stage.from
        if gained > 0 then
            lines[#lines + 1] = { text = "Cost per skill-up: " .. Money(math.floor(pay / gained + 0.5)), r = 1, g = 0.82, b = 0 }
        end
    end
    if stage.margin and stage.quantity ~= stage.baseQuantity then
        lines[#lines + 1] = { text = string.format("%d crafts expected, %d with %s", stage.baseQuantity, stage.quantity,
            opts.spareWord or "margin"), r = 0.7, g = 0.7, b = 0.7 }
    end
    return lines
end

Views.GAP_TOOLTIP = {
    "No available recipe gives skill-ups in this range.",
    "Level these points another way, or the recipe data is missing.",
    "The path continues after the gap; totals exclude it.",
}

local function GapTooltip(stage)
    local lines = { { text = Text.GapText(stage), r = 1, g = 0.5, b = 0.4 } }
    for _, text in ipairs(Views.GAP_TOOLTIP) do
        lines[#lines + 1] = { text = text, r = 0.7, g = 0.7, b = 0.7 }
    end
    return lines
end

local LEARN_COLOR = { 1, 0.75, 0.3 }
-- Colours of a learn step's lines (Text.LearnLines)
local LEARN_LINE_COLOR = { plain = WHITE, good = GREEN, warn = { 1, 0.3, 0.3 }, cost = GOLD }
local HIDDEN_TEXT = "The profession window hides unlearned recipes, so the arrow cannot point at this one until you learn it."

-- One line for a learn or rank step (lists and "next" rows).
function Views.StepRow(stage, view, ctx)
    local row = {
        kind = "line", stage = stage, lead = Text.StageRange(stage), leadWidth = 74,
        bg = BG_ROW, hoverBg = BG_ROW_HOVER, alpha = stage.done and 0.5 or 1,
        onClick = ctx.onOpenStage and function() ctx.onOpenStage(stage) end or nil,
    }
    if stage.kind == "learn" then
        local short = Text.LearnShort(stage, view.profile)
        row.text = Grey("learn") .. "  " .. (stage.recipe.name or "Unknown") .. (short and (" - " .. short) or "")
        row.color = LEARN_COLOR
        row.right = stage.fee > 0 and Money(stage.fee) or ""
        row.tooltip = { { text = "Learn " .. (stage.recipe.name or "the recipe"), r = 1, g = 1, b = 1 } }
        for _, line in ipairs(Text.LearnLines(stage, view.profile, view.path and view.path.profession)) do
            row.tooltip[#row.tooltip + 1] = { text = line.text, r = 0.7, g = 0.7, b = 0.7 }
        end
    else
        row.text = Grey("train") .. "  " .. Text.RankShort(stage)
        row.color = GOLD
        row.tooltip = { { text = Text.RankLine(stage, view.liveCap, view.path and view.path.profession,
            view.path and view.path.hasProfession), r = 1, g = 1, b = 1 } }
    end
    return row
end

-- "> 143-165" for the current stage, "143-165" otherwise.
local function Lead(stage)
    return (stage.current and "> " or "") .. Text.StageRange(stage)
end

-- One row per stage of the chosen range; a craft row opens its reagents in
-- place. ctx: onToggleExpand(stage), onOpenStage(stage) (optional: adds a
-- button that opens the stage on the Guide tab).
function Views.Steps(view, ctx)
    local notice = Views.Notice(view)
    if notice then return notice end
    local rows = {}
    for _, stage in ipairs(view.rangeStages or {}) do
        local alpha = stage.done and 0.5 or 1
        local bg = stage.current and BG_CURRENT or BG_ROW
        local hover = stage.current and BG_CURRENT_HOVER or BG_ROW_HOVER
        if stage.kind == "craft" then
            local pay = stage.outOfPocketCost
            local tooltip = CraftTooltip(stage)
            tooltip[#tooltip + 1] = { text = "Click to show or hide the reagents", r = 0.5, g = 0.5, b = 0.5 }
            rows[#rows + 1] = {
                kind = "line", stage = stage, lead = Lead(stage), leadWidth = 74,
                text = Grey("craft") .. "  " .. Text.StageTitle(stage),
                color = Views.DifficultyColor(stage.color),
                right = stage.done and "done" or Money(pay),
                rightColor = stage.done and DIM or (pay < stage.cost and GREEN or WHITE),
                bg = bg, hoverBg = hover, alpha = alpha, tooltip = tooltip,
                onClick = function() ctx.onToggleExpand(stage) end,
                button = ctx.onOpenStage and { text = "Guide", width = 46, onClick = function() ctx.onOpenStage(stage) end,
                    tooltip = { { text = "Open this step on the Guide tab", r = 1, g = 1, b = 1 } } } or nil,
            }
            if view.expanded and view.expanded[stage.key] then
                rows[#rows + 1] = Views.ReagentHeader(14)
                for _, mat in ipairs(stage.materials) do
                    rows[#rows + 1] = Views.ReagentRow(mat, 14)
                end
            end
        elseif stage.kind == "gap" then
            rows[#rows + 1] = {
                kind = "line", stage = stage, lead = Lead(stage), leadWidth = 74,
                text = Grey("gap") .. "  " .. Text.GapText(stage), color = GAP_RED,
                bg = stage.current and BG_CURRENT or BG_GAP, hoverBg = BG_GAP_HOVER, alpha = alpha,
                tooltip = GapTooltip(stage),
                onClick = ctx.onOpenStage and function() ctx.onOpenStage(stage) end or nil,
            }
        elseif stage.kind == "learn" or stage.kind == "rank" then
            local row = Views.StepRow(stage, view, ctx)
            row.lead = Lead(stage)
            row.bg, row.hoverBg = bg, hover
            rows[#rows + 1] = row
        end
    end
    return rows
end

-- Recipe search ----------------------------------------------------------------

-- Recipes whose name contains the query (plain text, any case), by required skill.
function Views.SearchRecipes(recipes, query)
    local matches = {}
    local needle = (query or ""):lower()
    if needle == "" then return matches end
    for _, recipe in ipairs(recipes or {}) do
        if recipe.name and recipe.name:lower():find(needle, 1, true) then
            matches[#matches + 1] = recipe
        end
    end
    table.sort(matches, function(a, b)
        local ra, rb = a.skillRequired or 0, b.skillRequired or 0
        if ra ~= rb then return ra < rb end
        return (a.name or "") < (b.name or "")
    end)
    return matches
end

-- Search results replace the list. ctx: onShowRecipe(recipe).
function Views.SearchResults(matches, ctx)
    if #matches == 0 then
        return { { kind = "line", height = 26, text = "No recipes found", color = DIM } }
    end
    local rows = {}
    for _, recipe in ipairs(matches) do
        rows[#rows + 1] = {
            kind = "line", recipe = recipe, text = recipe.name,
            right = "Requires " .. tostring(recipe.skillRequired or "?"), rightColor = GREY,
            hoverBg = BG_ROW_HOVER,
            tooltip = { { text = recipe.name, r = 1, g = 1, b = 1 }, { text = "Click for recipe details", r = 0.5, g = 0.5, b = 0.5 } },
            onClick = function() ctx.onShowRecipe(recipe) end,
        }
    end
    rows[#rows + 1] = { kind = "line", text = #matches .. " result" .. (#matches ~= 1 and "s" or ""), color = DIM }
    return rows
end

-- Path bar ---------------------------------------------------------------------

local BAR_DONE = { 0.35, 0.35, 0.35 }
local BAR_GAP = { 0.8, 0.15, 0.15 }

local function StageTooltip(stage)
    if stage.kind == "gap" then
        return GapTooltip(stage)
    end
    return CraftTooltip(stage)
end

-- The whole journey as one strip. Returns
--   from, to     skills at the bar's ends
--   segments     { { left, width (fractions of the bar), color, alpha, kind =
--                "done" | "craft" | "gap", stage, selected, tooltip }, ... }
--   ticks        { { pos, skill }, ... } one per rank still to train
--   marker       position of the real skill (nil when it is off the bar)
--   markerSkill  the real skill
-- For a profession the character has, the bar starts at 1 and the part already
-- gained is one dim block; otherwise it starts where the path does.
function Views.PathBar(view)
    local path = view.path
    local bar = { segments = {}, ticks = {} }
    if not path then return bar end
    local from = path.currentSkill or 1
    if path.hasProfession ~= false and from > 1 then
        from = 1
    end
    local to = math.max(path.targetSkill or from, path.actualSkill or from, from)
    bar.from, bar.to = from, to
    local span = to - from
    if span <= 0 then return bar end

    local function add(segFrom, segTo, fields)
        if segTo <= segFrom then return end
        fields.left = (segFrom - from) / span
        fields.width = (segTo - segFrom) / span
        bar.segments[#bar.segments + 1] = fields
    end

    local start = path.currentSkill or from
    if start > from then
        add(from, start, { kind = "done", color = BAR_DONE, alpha = 0.6,
            tooltip = { { text = string.format("Skill %d to %d: already done", from, start), r = 0.7, g = 0.7, b = 0.7 } } })
    end
    for _, stage in ipairs(view.stages or {}) do
        if stage.kind == "craft" or stage.kind == "gap" then
            add(stage.from, stage.to, {
                kind = stage.kind, stage = stage,
                color = stage.kind == "gap" and BAR_GAP or Views.DifficultyColor(stage.color),
                alpha = stage.done and 0.4 or 1,
                selected = (view.selectedStage == stage) or nil,
                tooltip = StageTooltip(stage),
            })
        elseif stage.kind == "rank" then
            bar.ticks[#bar.ticks + 1] = { pos = (stage.cap - from) / span, skill = stage.cap }
        end
    end

    local actual = view.skill or path.actualSkill
    if actual and actual >= from and actual <= to then
        bar.marker = (actual - from) / span
        bar.markerSkill = actual
    end
    return bar
end

-- Guide tab --------------------------------------------------------------------

local ALTERNATIVES_SHOWN = 3
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The stage the Guide tab shows: the one the player opened (by key, else the
-- craft or gap stage covering the skill it started at, so a stage whose recipe
-- was just replaced stays selected), else the current one, else the last.
function Views.SelectedStage(stages, summary, selection)
    if not stages or #stages == 0 then return nil end
    if selection then
        for _, stage in ipairs(stages) do
            if stage.key == selection.key then return stage end
        end
        for _, stage in ipairs(stages) do
            if (stage.kind == "craft" or stage.kind == "gap")
                    and selection.from >= stage.from and selection.from < stage.to then
                return stage
            end
        end
    end
    return stages[summary and summary.currentIndex or #stages] or stages[#stages]
end

local function Signed(n, unit)
    if n == 0 then return Grey("same " .. unit) end
    local text = string.format("%+d %s", n, unit)
    return n < 0 and Green(text) or ("|cFFFF6666" .. text .. "|r")
end

local function SignedMoney(copper)
    if copper == 0 then return Grey("same cost") end
    local text = (copper < 0 and "-" or "+") .. Utils.FormatMoneyShort(math.abs(copper))
    return copper < 0 and Green(text) or ("|cFFFF6666" .. text .. "|r")
end

-- An alternative that cannot bring the skill to the end of the stage
-- (alt.covers == false): how far it gets, in place of differences that would
-- compare a part of the run with the whole.
local function ReachText(stage, alt)
    if alt.coversTo <= stage.fromDisplay then
        return "no skill-ups here"
    end
    return "only up to " .. tostring(alt.coversTo)
end

-- Tooltip of an alternative of `stage`: what it is, why it may be blocked,
-- what it costs over the run and what its crafts sell for.
local function AlternativeTooltip(alt, stage)
    local recipe = alt.recipe
    local c = Views.DifficultyColor(alt.color)
    local lines = { { text = recipe.name or "Unknown", r = c[1], g = c[2], b = c[3] } }
    if not recipe.learned then
        lines[#lines + 1] = { text = "[!] Unlearned: " .. Utils.GetSourceDescription(recipe.source), r = 1, g = 0.53, b = 0 }
        if alt.unavailable and not alt.reason then
            lines[#lines + 1] = { text = "Not currently obtainable", r = 1, g = 0.3, b = 0.3 }
        end
    end
    -- An explicit block reason (Self-Found, ...) also applies to learned recipes.
    if alt.reason then
        lines[#lines + 1] = { text = alt.reason, r = 1, g = 0.3, b = 0.3 }
    end
    lines[#lines + 1] = { text = string.format("Difficulty: %s (%d%% skillup chance)", tostring(alt.color),
        (alt.expectedSkillups or 0) * 100), r = 0.7, g = 0.7, b = 0.7 }
    if alt.covers == false then
        local text = "Gives no skill-ups in this range, so it cannot cover this run."
        if alt.coversTo > stage.fromDisplay then
            text = string.format("Gives skill-ups only up to %d, so it cannot cover this run.", alt.coversTo)
        end
        lines[#lines + 1] = { text = text, r = 1, g = 0.5, b = 0 }
    elseif alt.priced then
        -- The same figures the row's difference is made of: what it costs
        -- over the run, what its crafts sell for, and the net of the two.
        local cost, sale = Round(alt.projectedCost), Round(alt.projectedSale)
        local text = string.format("About %d crafts for this run: %s", alt.projectedCrafts, Money(cost))
        if sale > 0 then
            text = text .. ", sells for " .. Money(sale)
        end
        lines[#lines + 1] = { text = text, r = 1, g = 1, b = 1 }
        if sale > 0 then
            local net = cost - sale
            lines[#lines + 1] = { text = (net < 0 and "Net gain: " or "Net cost: ") .. Money(math.abs(net)), r = 1, g = 1, b = 1 }
        end
        if alt.fee > 0 then
            lines[#lines + 1] = { text = "Includes " .. Money(alt.fee) .. " to learn the recipe", r = 0.7, g = 0.7, b = 0.7 }
        end
    else
        lines[#lines + 1] = { text = "Missing price data", r = 1, g = 0.4, b = 0.4 }
    end
    lines[#lines + 1] = { text = "Materials:", r = 1, g = 0.82, b = 0 }
    for _, reagent in ipairs(recipe.reagents or {}) do
        lines[#lines + 1] = { text = string.format("  %dx %s", reagent.count, reagent.name or "Unknown"), r = 0.8, g = 0.8, b = 0.8 }
    end
    lines[#lines + 1] = { text = "Click for recipe details", r = 0.5, g = 0.5, b = 0.5 }
    return lines
end

-- Tooltip of an alternative's Use button.
local function UseTooltip(alt)
    local lines = { { text = "Use this recipe instead", r = 1, g = 1, b = 1 },
        { text = "The path is planned again at once. Reset puts the planner's choice back.", r = 0.7, g = 0.7, b = 0.7 } }
    if alt.unavailable then
        lines[#lines + 1] = { text = "You will need to obtain this recipe yourself.", r = 1, g = 0.53, b = 0 }
    end
    return lines
end

local function AlternativeRow(stage, alt, ctx)
    local name = alt.recipe.name or "Unknown"
    if not alt.recipe.learned then
        name = name .. " |cFFFF8800[!]|r"
    end
    local right
    if alt.covers == false then
        right = Grey(ReachText(stage, alt))
    elseif alt.priced then
        right = Signed(alt.craftsDelta, "crafts") .. "  " .. SignedMoney(alt.costDelta)
    else
        right = Grey("no price")
    end
    return {
        kind = "line", alt = alt, indent = 6, text = name, color = Views.DifficultyColor(alt.color),
        right = right, alpha = alt.unavailable and 0.5 or 1,
        bg = BG_SUB, hoverBg = BG_ROW_HOVER, tooltip = AlternativeTooltip(alt, stage),
        onClick = function() ctx.onShowRecipe(alt.recipe, stage.fromDisplay) end,
        button = { text = "Use this", width = 62, tooltip = UseTooltip(alt), onClick = function() ctx.onUseAlternative(stage, alt) end },
    }
end

-- One-line row for a stage (the "next" rows under the card, and the list).
local function CompactRow(stage, ctx, view)
    if stage.kind == "learn" or stage.kind == "rank" then
        return Views.StepRow(stage, view, ctx)
    end
    local lead = nil
    local row = {
        kind = "line", stage = stage, lead = lead or Text.StageRange(stage), leadWidth = 74,
        bg = BG_ROW, hoverBg = BG_ROW_HOVER, alpha = stage.done and 0.5 or 1,
        onClick = function() ctx.onOpenStage(stage) end,
    }
    if stage.kind == "craft" then
        row.text = Grey("craft") .. "  " .. Text.StageTitle(stage)
        row.color = Views.DifficultyColor(stage.color)
        row.right = Money(stage.outOfPocketCost)
        row.rightColor = stage.outOfPocketCost < stage.cost and GREEN or WHITE
    else
        row.text = Grey("gap") .. "  " .. Text.GapText(stage)
        row.color = GAP_RED
    end
    return row
end

-- Rows naming the trainers the player has visited for a path's profession
-- (recipeId: only those that listed that recipe), under `label`. Empty when
-- none is remembered: nothing is ever named that the game did not show.
function Views.TrainerRows(path, recipeId, label)
    local memory = LazyProf.TrainerMemory
    if not (memory and path and path.professionKey) then return {} end
    local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
    local trainers = memory:Trainers(path.professionKey, recipeId, faction)
    if #trainers == 0 then return {} end
    local rows = { { kind = "line", height = 16, color = GREY, text = label } }
    for i, trainer in ipairs(trainers) do
        if i > 6 then
            rows[#rows + 1] = { kind = "line", height = 16, indent = 8, color = DIM,
                text = string.format("... and %d more", #trainers - 6) }
            break
        end
        rows[#rows + 1] = {
            kind = "line", height = 16, indent = 8, color = WHITE, text = Text.TrainerLine(trainer),
            tooltip = {
                { text = trainer.name or "Unknown", r = 1, g = 1, b = 1 },
                { text = "You visited this trainer. The position is where you stood.", r = 0.7, g = 0.7, b = 0.7 },
            },
        }
    end
    return rows
end

-- The card of the selected stage, the alternatives and the next two stages.
-- view.selectedStage is the stage; view.showAllAlts expands the alternatives.
-- ctx: onShowRecipe(recipe, skill), onUseAlternative(stage, alt),
-- onResetPin(stage), onShowAllAlts(bool), onOpenStage(stage).
function Views.GuideCard(view, ctx)
    local path = view.path
    if path and path.nothingLeft then
        return Views.Notice(view)
    end
    local stage = view.selectedStage
    if not stage then
        return { { kind = "line", height = 26, text = "No steps to show.", color = DIM } }
    end
    local stages = view.stages
    local rows = {}
    local state = stage.done and " (done)" or (stage.current and " (current step)" or "")
    rows[#rows + 1] = { kind = "line", font = "GameFontNormalSmall", color = GOLD,
        text = string.format("Step %d of %d - %s%s", stage.index, #stages,
            stage.kind == "rank" and "train" or stage.kind, state) }

    if stage.kind == "craft" then
        local recipe = stage.recipe
        local icon
        if recipe.itemId then
            local _, _, itemIcon = Utils.GetItemInfo(recipe.itemId)
            icon = itemIcon
        end
        rows[#rows + 1] = {
            kind = "line", height = 26, font = "GameFontNormalLarge", icon = icon or QUESTION_MARK,
            text = Text.StageTitle(stage), color = Views.DifficultyColor(stage.color),
            right = string.format("%d to %d", stage.fromDisplay, stage.toDisplay), rightColor = GOLD,
            hoverBg = BG_ROW_HOVER, tooltip = CraftTooltip(stage),
            onClick = function() ctx.onShowRecipe(recipe, stage.fromDisplay) end,
        }
        rows[#rows + 1] = { kind = "line", height = 16, text = Text.ColorChanges(stage), color = GREY }
        if stage.bridge then
            rows[#rows + 1] = { kind = "line", wrap = true, color = DIFFICULTY_COLOR.green, text = BRIDGE_TEXT }
        end
        if stage.pinned then
            rows[#rows + 1] = {
                kind = "line", text = "Pinned: you chose this recipe for the step.", color = { 0.4, 0.7, 1 },
                button = { text = "Reset", width = 54, onClick = function() ctx.onResetPin(stage) end,
                    tooltip = { { text = "Let the planner choose again", r = 1, g = 1, b = 1 } } },
            }
        end

        rows[#rows + 1] = Views.ReagentHeader(4)
        for _, mat in ipairs(stage.materials) do
            rows[#rows + 1] = Views.ReagentRow(mat, 4)
        end
        local pay = stage.outOfPocketCost
        local costLine = { kind = "line", text = "", right = "Step cost  " .. Money(pay),
            rightColor = pay < stage.cost and GREEN or WHITE }
        if pay < stage.cost then
            costLine.text = Grey("market price " .. Money(stage.cost))
        end
        rows[#rows + 1] = costLine
        if stage.margin and stage.quantity ~= stage.baseQuantity then
            rows[#rows + 1] = { kind = "line", height = 16, color = GREY,
                text = string.format("%d crafts expected, %d with margin", stage.baseQuantity, stage.quantity) }
        end

        local alts = stage.alternatives or {}
        if #alts > 0 then
            rows[#rows + 1] = { kind = "sep" }
            rows[#rows + 1] = { kind = "line", font = "GameFontNormalSmall", color = GOLD, text = "Alternatives" }
            local shown = view.showAllAlts and #alts or math.min(ALTERNATIVES_SHOWN, #alts)
            for i = 1, shown do
                rows[#rows + 1] = AlternativeRow(stage, alts[i], ctx)
            end
            if #alts > ALTERNATIVES_SHOWN then
                local expand = not view.showAllAlts
                rows[#rows + 1] = {
                    kind = "line", indent = 6, color = { 0.5, 0.6, 0.8 }, hoverBg = BG_ROW_HOVER,
                    text = expand and ("Show all " .. #alts) or "Show fewer",
                    onClick = function() ctx.onShowAllAlts(expand) end,
                }
            end
        end
    elseif stage.kind == "gap" then
        rows[#rows + 1] = { kind = "line", height = 26, font = "GameFontNormal", color = GAP_RED, wrap = true,
            text = Text.GapText(stage) }
        for _, text in ipairs(Views.GAP_TOOLTIP) do
            rows[#rows + 1] = { kind = "line", wrap = true, color = GREY, text = text }
        end
    elseif stage.kind == "learn" then
        local recipe = stage.recipe
        local icon
        if recipe.itemId then
            local _, _, itemIcon = Utils.GetItemInfo(recipe.itemId)
            icon = itemIcon
        end
        rows[#rows + 1] = {
            kind = "line", height = 26, font = "GameFontNormalLarge", icon = icon or QUESTION_MARK,
            text = "Learn " .. (recipe.name or "the recipe"), color = LEARN_COLOR,
            right = "at " .. tostring(stage.at), rightColor = GOLD, hoverBg = BG_ROW_HOVER,
            tooltip = { { text = "Click for recipe details", r = 0.5, g = 0.5, b = 0.5 } },
            onClick = function() ctx.onShowRecipe(recipe, stage.at) end,
        }
        for _, line in ipairs(Text.LearnLines(stage, view.profile, path and path.profession)) do
            rows[#rows + 1] = { kind = "line", wrap = true, text = line.text, color = LEARN_LINE_COLOR[line.color] or WHITE }
        end
        -- Trainers the player has visited that listed this recipe (never on
        -- the VANILLA profile, where "trainer-taught" is not trusted).
        if stage.sourceInfo and stage.sourceInfo.type == "trainer" and view.profile ~= "VANILLA" then
            for _, row in ipairs(Views.TrainerRows(path, recipe.id, "Trainers you visited that teach it:")) do
                rows[#rows + 1] = row
            end
        end
        -- The profession window's filter hides unlearned recipes, so the arrow
        -- has no row to point at for this one.
        if view.hiddenRecipeId and view.hiddenRecipeId == recipe.id then
            rows[#rows + 1] = { kind = "line", wrap = true, color = ORANGE, text = HIDDEN_TEXT }
        end
    elseif stage.kind == "rank" then
        rows[#rows + 1] = { kind = "line", height = 26, font = "GameFontNormalLarge", color = GOLD,
            text = "Train the next rank", right = "before " .. tostring(stage.cap), rightColor = GOLD }
        rows[#rows + 1] = { kind = "line", wrap = true, color = WHITE,
            text = Text.RankLine(stage, view.liveCap, path and path.profession, path and path.hasProfession) }
        local label = string.format("%s trainers you have visited (not every trainer teaches every rank):",
            tostring(path and path.profession))
        for _, row in ipairs(Views.TrainerRows(path, nil, label)) do
            rows[#rows + 1] = row
        end
    end

    -- The next two stages
    local nextRows = {}
    for i = stage.index + 1, math.min(stage.index + 2, #stages) do
        nextRows[#nextRows + 1] = CompactRow(stages[i], ctx, view)
    end
    if #nextRows > 0 then
        rows[#rows + 1] = { kind = "sep" }
        rows[#rows + 1] = { kind = "line", font = "GameFontNormalSmall", color = GOLD, text = "Next" }
        for _, row in ipairs(nextRows) do rows[#rows + 1] = row end
    end
    return rows
end

-- Which of Prev / Current step / Next can be used for the selected stage.
function Views.GuideNav(view)
    local stage, stages = view.selectedStage, view.stages or {}
    local current = view.summary and view.summary.currentIndex
    return {
        prev = stage ~= nil and stage.index > 1,
        next = stage ~= nil and stage.index < #stages,
        current = stage ~= nil and current ~= nil and stage.index ~= current,
        recipe = stage ~= nil and stage.recipe ~= nil,
    }
end

-- Path tab ---------------------------------------------------------------------

-- An alternative is close when it costs the player at most this share of the
-- run's own cost more (a cheaper one always is): it is then offered right
-- under the run's row.
Views.CLOSE_ALTERNATIVE = 0.10

local OPEN_INDENT = 14
local PATH_COLUMNS = { "skill", "crafts", "cost" }

-- Where the player is in the list: the current stage, or the run (or gap)
-- right after the learn and rank steps that come before it.
local function CurrentRow(view)
    local stages = view.stages or {}
    local index = view.summary and view.summary.currentIndex
    while index and stages[index] and (stages[index].kind == "learn" or stages[index].kind == "rank") do
        index = index + 1
    end
    return index and stages[index] or nil
end

-- A reagent of the run still has to be bought and has no price.
local function UnpricedToBuy(stage)
    for _, mat in ipairs(stage.materials or {}) do
        if mat.missing > 0 and not mat.price then return true end
    end
    return false
end

-- "+14s", a green "-40s", or `same` when there is no difference.
local function CostDifference(copper, same)
    local amount = Round(math.abs(copper))
    if amount == 0 then return same end
    if copper < 0 then return Green("-" .. Short(amount)) end
    return "+" .. Short(amount)
end

-- "+4 crafts", a green "-1 craft", or a grey "same crafts".
local function CraftsDifference(n)
    if n == 0 then return Grey("same crafts") end
    local text = string.format("%+d %s", n, math.abs(n) == 1 and "craft" or "crafts")
    return n < 0 and Green(text) or text
end

-- An alternative's name. One whose recipe is still to learn says so, with the
-- fee when one is known (not on the VANILLA profile, where the recipe data
-- types every recipe as trainer-taught and the fee comes from that typing).
local function AlternativeName(alt, profile)
    local name = alt.recipe.name or "Unknown"
    if alt.recipe.learned then return name end
    if alt.fee > 0 and profile ~= "VANILLA" then
        return name .. " (learn " .. Money(alt.fee) .. ")"
    end
    return name .. " (to learn)"
end

-- The alternative to offer under a run's row: the best usable one, when it is
-- close (Views.CLOSE_ALTERNATIVE of what the run costs the player after its
-- crafts are sold, so for a run that pays for itself only one that is no
-- dearer) or cheaper. Only the first of the stage's sorted alternatives is
-- considered: when that one cannot be obtained, cannot cover the run or has
-- no price, none is offered. None either on a run the player pinned or has
-- finished, or whose own cost is not known.
local function CloseAlternative(stage)
    if stage.pinned or stage.done or UnpricedToBuy(stage) then return nil end
    local alt = stage.alternatives and stage.alternatives[1]
    if not alt or alt.unavailable or alt.covers == false or not alt.priced then return nil end
    local net = stage.outOfPocketCost + (stage.feeIncluded and 0 or (stage.fee or 0)) - (stage.sale or 0)
    if alt.costDelta <= Views.CLOSE_ALTERNATIVE * math.max(0, net) then
        return alt
    end
    return nil
end

-- One of the "Other recipes" of an opened run: the difference in cost for the
-- player (after what the crafts sell for) and in crafts, and a Use button.
local function PathAlternativeRow(stage, alt, view, ctx)
    local right
    if alt.covers == false then
        right = Grey(ReachText(stage, alt))
    elseif alt.priced then
        right = CostDifference(alt.costDelta, Grey("same cost")) .. "  " .. CraftsDifference(alt.craftsDelta)
    else
        right = Grey("no price")
    end
    return {
        kind = "line", alt = alt, indent = 6, text = AlternativeName(alt, view.profile),
        color = Views.DifficultyColor(alt.color), right = right, alpha = alt.unavailable and 0.5 or 1,
        bg = BG_SUB, hoverBg = BG_ROW_HOVER, tooltip = AlternativeTooltip(alt, stage),
        onClick = function() ctx.onShowRecipe(alt.recipe, stage.fromDisplay) end,
        button = { text = "Use", width = 40, tooltip = UseTooltip(alt), onClick = function() ctx.onUseAlternative(stage, alt) end },
    }
end

-- What an opened run shows under its row, indented: with More options the
-- colour changes, the cost per craft and the market price; "Your choice" and
-- Reset on a pinned run; why a green recipe is there; the reagent table; what
-- a craft sells for; how to learn the recipe while that is still to do
-- (`learn` is the run's learn step, nil once learned); both craft counts when
-- spare crafts changed the count; the other recipes for the run's range; and
-- a last line with the Recipe details button.
local function AddOpenedRun(rows, stage, learn, view, ctx)
    local path, recipe = view.path, stage.recipe
    local function add(row)
        row.indent = (row.indent or 0) + OPEN_INDENT
        rows[#rows + 1] = row
    end

    if view.advanced then
        local parts = { Text.ColorChanges(stage) }
        if not UnpricedToBuy(stage) then
            if stage.quantity > 0 then
                parts[#parts + 1] = Short(stage.outOfPocketCost / stage.quantity) .. " per craft"
            end
            if stage.outOfPocketCost < stage.cost then
                parts[#parts + 1] = "market price " .. Money(stage.cost)
            end
        end
        add({ kind = "line", height = 16, wrap = true, color = GREY, text = table.concat(parts, "; ") })
    end
    if stage.pinned then
        add({
            kind = "line", text = "Your choice", color = { 0.4, 0.7, 1 },
            button = { text = "Reset", width = 54, onClick = function() ctx.onResetPin(stage) end,
                tooltip = { { text = "Let the planner choose again", r = 1, g = 1, b = 1 } } },
        })
    end
    if stage.bridge then
        add({ kind = "line", wrap = true, color = DIFFICULTY_COLOR.green, text = BRIDGE_TEXT })
    end

    add(Views.ReagentHeader())
    for _, mat in ipairs(stage.materials or {}) do
        add(Views.ReagentRow(mat))
    end
    if (stage.saleEach or 0) > 0 then
        local sources = view.sale and view.sale.sources
        add({ kind = "line", height = 16, color = GREY, text = Text.SellsFor(stage.saleEach, sources and sources[recipe.id]) })
    end

    if learn then
        for _, line in ipairs(Text.LearnLines(learn, view.profile, path.profession)) do
            add({ kind = "line", wrap = true, text = line.text, color = LEARN_LINE_COLOR[line.color] or WHITE })
        end
        -- Trainers the player has visited that listed this recipe (never on
        -- the VANILLA profile, where "trainer-taught" is not trusted).
        if learn.sourceInfo and learn.sourceInfo.type == "trainer" and view.profile ~= "VANILLA" then
            for _, row in ipairs(Views.TrainerRows(path, recipe.id, "Trainers you visited that teach it:")) do
                add(row)
            end
        end
        if view.hiddenRecipeId and view.hiddenRecipeId == recipe.id then
            add({ kind = "line", wrap = true, color = ORANGE, text = HIDDEN_TEXT })
        end
    end

    if stage.margin and stage.quantity ~= stage.baseQuantity then
        add({ kind = "line", height = 16, color = GREY,
              text = string.format("%d crafts expected, %d with spare crafts", stage.baseQuantity, stage.quantity) })
    end

    local last = {
        kind = "line", text = "",
        button = { text = "Recipe details", width = 96, onClick = function() ctx.onShowRecipe(recipe, stage.fromDisplay) end },
    }
    local alts = stage.alternatives or {}
    if #alts > 0 then
        add({ kind = "line", font = "GameFontNormalSmall", color = GOLD,
              text = string.format("Other recipes for %d-%d", stage.fromDisplay, stage.toDisplay) })
        local all = (type(view.showAllAlts) == "table" and view.showAllAlts[stage.key]) and true or false
        for i = 1, all and #alts or math.min(ALTERNATIVES_SHOWN, #alts) do
            add(PathAlternativeRow(stage, alts[i], view, ctx))
        end
        if #alts > ALTERNATIVES_SHOWN then
            last.text = all and "Show fewer" or ("Show all " .. #alts)
            last.color = { 0.5, 0.6, 0.8 }
            last.hoverBg = BG_ROW_HOVER
            last.onClick = function() ctx.onShowAllAlts(stage, not all) end
        end
    end
    add(last)
end

-- The row of a craft run, its sub-lines and, when it is open, its content.
local function AddRun(rows, stage, learn, isCurrent, view, ctx)
    local recipe = stage.recipe
    local unpriced = UnpricedToBuy(stage)
    -- A finished run (the what-if from skill 1 has them) keeps its cost: the
    -- account still counts it. It is dimmed instead.
    local cost, costColor = Money(stage.outOfPocketCost), nil
    if unpriced then
        cost, costColor = "?", ORANGE
    elseif stage.outOfPocketCost < stage.cost then
        costColor = GREEN
    end
    local tooltip = CraftTooltip(stage, { spareWord = "spare crafts", unpriced = unpriced })
    tooltip[#tooltip + 1] = { text = "Click to open or close", r = 0.5, g = 0.5, b = 0.5 }
    local function toggle() ctx.onToggleExpand(stage) end
    rows[#rows + 1] = {
        kind = "cols", layout = "path", stage = stage,
        text = (isCurrent and "> " or "") .. (recipe.name or "Unknown"),
        color = Views.DifficultyColor(stage.color),
        cols = { Text.StageRange(stage), tostring(stage.quantity), cost },
        colColors = costColor and { [3] = costColor } or nil,
        bg = isCurrent and BG_CURRENT or BG_ROW, hoverBg = isCurrent and BG_CURRENT_HOVER or BG_ROW_HOVER,
        alpha = stage.done and 0.5 or 1, tooltip = tooltip, onClick = toggle,
    }

    if learn then
        local learnTip = { { text = "Learn " .. (recipe.name or "the recipe"), r = 1, g = 1, b = 1 } }
        for _, line in ipairs(Text.LearnLines(learn, view.profile, view.path.profession)) do
            learnTip[#learnTip + 1] = { text = line.text, r = 0.7, g = 0.7, b = 0.7 }
        end
        rows[#rows + 1] = { kind = "line", sub = true, stage = learn, text = Text.LearnFirst(learn, view.profile),
                            color = LEARN_COLOR, alpha = learn.done and 0.5 or 1, tooltip = learnTip, onClick = toggle }
    end

    -- Open when the player opened it; the run the player is on is open until
    -- it is closed.
    local open = view.expanded and view.expanded[stage.key]
    if open == nil then open = isCurrent end
    if open then
        AddOpenedRun(rows, stage, (learn and not learn.done) and learn or nil, view, ctx)
        return
    end
    local alt = CloseAlternative(stage)
    if alt then
        rows[#rows + 1] = {
            kind = "line", sub = true, stage = stage, alt = alt, color = GREY,
            text = "or: " .. AlternativeName(alt, view.profile) .. ", " .. CostDifference(alt.costDelta, "same cost"),
            tooltip = AlternativeTooltip(alt, stage),
            onClick = function() ctx.onShowRecipe(alt.recipe, stage.fromDisplay) end,
            button = { text = "Use", width = 40, tooltip = UseTooltip(alt), onClick = function() ctx.onUseAlternative(stage, alt) end },
        }
    end
end

-- "Train the next rank before 150": a thin row. Its tooltip is the rank
-- sentence and the trainers of the profession the player has visited.
local function RankRow(stage, view)
    local path = view.path
    local tooltip = { { text = Text.RankLine(stage, view.liveCap, path.profession, path.hasProfession), r = 1, g = 1, b = 1 } }
    local label = string.format("%s trainers you have visited (not every trainer teaches every rank):", tostring(path.profession))
    for i, row in ipairs(Views.TrainerRows(path, nil, label)) do
        tooltip[#tooltip + 1] = { text = (i > 1 and "  " or "") .. row.text, r = 0.7, g = 0.7, b = 0.7 }
    end
    return { kind = "line", stage = stage, height = 18, text = Text.RankShort(stage), color = GOLD,
             alpha = stage.done and 0.5 or 1, tooltip = tooltip }
end

local function GapRow(stage, isCurrent)
    return {
        kind = "line", stage = stage, text = (isCurrent and "> " or "") .. Text.GapText(stage), color = GAP_RED,
        bg = isCurrent and BG_CURRENT or BG_GAP, hoverBg = isCurrent and BG_CURRENT_HOVER or BG_GAP_HOVER,
        alpha = stage.done and 0.5 or 1, tooltip = GapTooltip(stage),
    }
end

-- The path as one list: a row per recipe run in skill order, with what has to
-- be done first and the closest alternative folded in under it, and thin rows
-- for rank steps and gaps. A click opens a run in place (AddOpenedRun).
-- Row descriptors the list widget has to know beyond today's:
--   layout = "path"   on "cols" rows: three columns - skill range, crafts,
--                     cost - in place of need / have / buy / cost, no mark
--                     column; the header row carries the titles
--   sub = true        on "line" rows: a sub-line of the row above it (smaller,
--                     indented, grey unless `color` is given): "Learn first:
--                     trainer, 4s" and "or: <recipe>, +14s" with a Use button
-- Rows also carry `stage` (and `alt` on alternatives) for the caller.
-- The row the player is on is marked with "> " and highlighted.
-- view.expanded[stage.key]: true = open, false = closed, nil = open only for
-- the run the player is on. view.showAllAlts[stage.key]: every alternative of
-- that run is listed.
-- ctx: onToggleExpand(stage), onShowRecipe(recipe, skill),
-- onUseAlternative(stage, alt), onResetPin(stage), onShowAllAlts(stage, on).
function Views.Path(view, ctx)
    local path = view.path
    if not path then return {} end
    if path.nothingLeft then
        return Views.Notice(view)
    end
    local stages = view.stages or {}
    if #stages == 0 then
        return { { kind = "line", height = 26, text = "No steps to show.", color = DIM } }
    end

    local rows = { { kind = "cols", layout = "path", header = true, text = "Recipes", cols = PATH_COLUMNS } }
    local current = CurrentRow(view)
    local learn = nil   -- the learn step waiting for its run's row
    for _, stage in ipairs(stages) do
        if stage.kind == "learn" then
            learn = stage
        elseif stage.kind == "craft" then
            local itsLearn = (learn and learn.recipe.id == stage.recipe.id) and learn or nil
            learn = nil
            AddRun(rows, stage, itsLearn, stage == current, view, ctx)
        elseif stage.kind == "rank" then
            rows[#rows + 1] = RankRow(stage, view)
        elseif stage.kind == "gap" then
            rows[#rows + 1] = GapRow(stage, stage == current)
        end
    end
    return rows
end

-- Shopping tab -------------------------------------------------------------------

-- Owned stock that is not in the bags: where to fetch it first. Same sections
-- and colours the shopping list has always had.
local COLLECT = {
    { list = "fromBank", label = "From bank", color = { 0.4, 1, 0.4 },
      tip = function(mat) return string.format("In bank: %d | Grab: %d", mat.have, mat.missing) end },
    { list = "fromMail", label = "Check mail", color = { 0.4, 0.8, 1 },
      tip = function(mat) return string.format("In mail: %d | Grab: %d", mat.have, mat.missing) end },
    { list = "fromAuctions", label = "Cancel from AH", color = { 1, 0.6, 0.2 },
      tip = function(mat) return string.format("Listed on AH: %d | Cancel: %d", mat.have, mat.missing) end,
      warning = "Requires cancelling your auction" },
    { list = "fromGuildBank", label = "From guild bank", color = { 0.2, 0.8, 0.8 },
      tip = function(mat) return string.format("In guild bank: %d | Withdraw: %d", mat.have, mat.missing) end,
      warning = "Shared resource - others may need these" },
    { list = "fromAlts", label = "From alts", color = { 0.8, 0.6, 1 } },
}

local function CollectRow(section, mat)
    local text = string.format("%dx %s", mat.missing, mat.name or "Unknown")
    local tooltip = {}
    if section.list == "fromAlts" then
        local names = {}
        tooltip[#tooltip + 1] = { text = "On your alts:", r = 0.8, g = 0.6, b = 1 }
        for _, char in ipairs(mat.characters or {}) do
            -- Character name without the realm part
            names[#names + 1] = (char.name:match("^([^-]+)") or char.name) .. ":" .. tostring(char.count)
            tooltip[#tooltip + 1] = { text = string.format("  %s: %d", char.name, char.count), r = 1, g = 1, b = 1 }
        end
        text = text .. " " .. Grey("(" .. table.concat(names, ", ") .. ")")
        tooltip[#tooltip + 1] = { text = "Transfer to this character before crafting", r = 0.6, g = 0.6, b = 0.6 }
    else
        if mat.purpose then
            text = text .. " " .. Grey("(" .. mat.purpose .. ")")
        end
        local c = section.color
        tooltip[#tooltip + 1] = { text = section.tip(mat), r = c[1], g = c[2], b = c[3] }
        if section.warning then
            tooltip[#tooltip + 1] = { text = section.warning, r = 0.6, g = 0.6, b = 0.6 }
        end
    end
    tooltip[#tooltip + 1] = { text = "Shift-click to link", r = 0.5, g = 0.5, b = 0.5 }
    return {
        kind = "line", icon = mat.icon, lead = section.label, leadWidth = 96, leadColor = section.color,
        text = text, bg = BG_SUB, hoverBg = BG_ROW_HOVER,
        itemId = mat.itemId, link = mat.link, tooltip = tooltip,
    }
end

-- The craft / buy button of a craftable reagent. Its text is the state in
-- force; a click switches it, a right-click goes back to automatic.
local function ChoiceButton(row, ctx)
    -- The choice in force: the player's when one was made (also while the
    -- stock covers the need and nothing is crafted), else what the list does.
    local craft
    if row.choice then
        craft = (row.choice == "craft")
    else
        craft = row.crafted and true or false
    end
    local lines = {}
    if row.choice then
        lines[#lines + 1] = { text = craft and "You chose to craft this yourself." or "You chose to buy this.", r = 1, g = 1, b = 1 }
        if craft and not row.crafted then
            lines[#lines + 1] = { text = "Your stock covers it, so nothing has to be crafted now.", r = 0.7, g = 0.7, b = 0.7 }
        end
    else
        lines[#lines + 1] = { text = craft and "Chosen automatically: crafting is cheaper."
            or "Chosen automatically: buying is cheaper, or automatic crafting is off.", r = 1, g = 1, b = 1 }
    end
    if row.craftRecipeName then
        lines[#lines + 1] = { text = "Recipe: " .. row.craftRecipeName, r = 0.7, g = 0.7, b = 0.7 }
    end
    lines[#lines + 1] = { text = "Click to switch. Right-click for automatic.", r = 0.5, g = 0.5, b = 0.5 }
    lines[#lines + 1] = { text = "This changes the shopping list only, not the path.", r = 0.5, g = 0.5, b = 0.5 }
    return {
        text = craft and "I craft it" or "I buy it",
        tooltip = lines,
        onClick = function(mouseButton)
            if mouseButton == "RightButton" then
                ctx.onCraftChoice(row, nil)
            else
                ctx.onCraftChoice(row, craft and "buy" or "craft")
            end
        end,
    }
end

local function ShoppingTooltip(row)
    local lines = {}
    local parts = {}
    if (row.inBags or 0) > 0 then parts[#parts + 1] = "bags " .. row.inBags end
    for _, source in ipairs({ { "bank", "bank" }, { "mail", "mail" }, { "auctions", "your auctions" },
                              { "guildBank", "guild bank" }, { "alts", "alts" } }) do
        local n = row.sources and row.sources[source[1]] or 0
        if n > 0 then parts[#parts + 1] = source[2] .. " " .. n end
    end
    lines[#lines + 1] = { text = string.format("Need: %d | Have: %d | Buy: %d", row.need or 0, row.have or 0, row.toBuy or 0), r = 1, g = 1, b = 1 }
    if #parts > 0 then
        lines[#lines + 1] = { text = "Using: " .. table.concat(parts, ", "), r = 0.7, g = 0.7, b = 0.7 }
    end
    if row.crafted then
        lines[#lines + 1] = { text = string.format("Craft %d with %s", row.craftQuantity or 0, tostring(row.craftRecipeName)), r = 0.4, g = 0.8, b = 1 }
    else
        local pm = LazyProf.PriceManager
        if pm and pm.PeekPriceInfo then
            lines[#lines + 1] = { text = pm.PriceLine(pm:PeekPriceInfo(row.itemId)), r = 0.7, g = 0.7, b = 0.7 }
        end
    end
    lines[#lines + 1] = { text = "Shift-click to link", r = 0.5, g = 0.5, b = 0.5 }
    return lines
end

-- Rows to buy: priced ones first, the dearest first; then by name.
local function DearestFirst(a, b)
    local unpricedA, unpricedB = a.unpriced and true or false, b.unpriced and true or false
    if unpricedA ~= unpricedB then return unpricedB end
    local costA, costB = a.cost or 0, b.cost or 0
    if costA ~= costB then return costA > costB end
    if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
    return (a.itemId or 0) < (b.itemId or 0)
end

local function ByName(a, b)
    if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
    return (a.itemId or 0) < (b.itemId or 0)
end

-- A line of the shopping table that sums a column: the label, and the amount
-- under the Cost column.
local function TotalRow(label, copper)
    return { kind = "cols", total = true, text = label, color = GOLD, cols = { "", "", "", Money(copper or 0) } }
end

-- The shopping list. view.missing is Pathfinder:CalculateMissingMaterials of
-- the steps shown. In order:
--   "Collect first": owned stock that is not in the bags
--   the table (need / have / buy / cost, a "vendor" mark): reagents with
--     something left to buy, the dearest first and those without a price
--     last; then the reagents the character makes, each with what it is made
--     from beneath it; then the reagents already owned, dimmed, by name
--   "Reagents to buy": the sum of the Cost column (missing.buyTotal)
--   "Recipes to learn": a row per recipe that costs something, with where it
--     comes from (never on the VANILLA profile) and its price, and their sum
-- The two sums are the two parts of the receipt's "You spend".
-- With More options (view.advanced) a reagent the character can make has its
-- craft / buy button, and view.hideOwned hides the owned rows; without it
-- neither acts, because the checkbox that would undo the filter is hidden.
-- Row fields beyond the list widget's: `item` (the shopping row), `recipe`
-- (on recipe rows), `total = true` (on the two sum rows).
-- ctx: onCraftChoice(row, "craft" | "buy" | nil); onShowRecipe(recipe) (optional).
function Views.Shopping(view, ctx)
    local path = view.path
    if path and path.nothingLeft then
        return Views.Notice(view)
    end
    local missing = view.missing or {}
    local rows = {}

    local collect = {}
    for _, section in ipairs(COLLECT) do
        for _, mat in ipairs(missing[section.list] or {}) do
            collect[#collect + 1] = CollectRow(section, mat)
        end
    end
    if #collect > 0 then
        rows[#rows + 1] = { kind = "line", font = "GameFontNormalSmall", color = GOLD, text = "Collect first" }
        for _, row in ipairs(collect) do rows[#rows + 1] = row end
        rows[#rows + 1] = { kind = "sep" }
    end

    local items = missing.rows or {}
    if #items == 0 then
        rows[#rows + 1] = { kind = "line", height = 26, color = DIM,
            text = "No reagents needed in " .. (view.bracket and view.bracket.name or "this path") .. "." }
    else
        local toBuy, crafted, owned = {}, {}, {}
        local toBuyRows = 0
        for _, row in ipairs(items) do
            if row.toBuy > 0 then toBuyRows = toBuyRows + 1 end
            if row.crafted then
                crafted[#crafted + 1] = row
            elseif row.toBuy > 0 then
                toBuy[#toBuy + 1] = row
            else
                owned[#owned + 1] = row
            end
        end
        table.sort(toBuy, DearestFirst)
        table.sort(crafted, DearestFirst)
        table.sort(owned, ByName)
        if view.advanced and view.hideOwned then
            owned = {}
        end

        local table_ = {}
        local function addItem(row, alpha)
            local buy = row.toBuy > 0 and tostring(row.toBuy) or "-"
            local cost
            if row.toBuy <= 0 then
                cost = row.crafted and "" or "-"
            elseif row.unpriced then
                cost = "?"
            else
                cost = Money(row.cost)
            end
            local desc = {
                kind = "cols", item = row, icon = row.icon, text = row.name,
                cols = { tostring(row.need), tostring(row.have), buy, cost },
                colColors = {
                    [2] = row.have >= row.need and GREEN or WHITE,
                    [3] = row.toBuy > 0 and WHITE or DIM,
                    [4] = row.unpriced and ORANGE or WHITE,
                },
                mark = row.isVendor and "vendor" or nil,
                bg = BG_SUB, hoverBg = BG_ROW_HOVER, alpha = alpha,
                itemId = row.itemId, link = row.link, tooltip = ShoppingTooltip(row),
            }
            if row.craftable and view.advanced then
                desc.button = ChoiceButton(row, ctx)
            end
            table_[#table_ + 1] = desc
            for _, child in ipairs(row.crafted and row.children or {}) do
                table_[#table_ + 1] = {
                    kind = "cols", indent = 14, text = child.name, color = GREY,
                    cols = { tostring(child.need), "", "", "" }, colColors = { [1] = GREY },
                    mark = "in list", itemId = child.itemId,
                    tooltip = { { text = string.format("Needed to craft %s. It is counted in this reagent's own row.", tostring(row.name)),
                        r = 0.7, g = 0.7, b = 0.7 } },
                }
            end
        end
        for _, row in ipairs(toBuy) do addItem(row) end
        for _, row in ipairs(crafted) do addItem(row) end
        for _, row in ipairs(owned) do addItem(row, 0.55) end

        if toBuyRows == 0 then
            rows[#rows + 1] = { kind = "line", color = GREEN, text = "Nothing left to buy"
                .. (view.bracket and (" for " .. view.bracket.name) or "") .. "." }
        end
        if #table_ > 0 then
            rows[#rows + 1] = Views.ReagentHeader()
            for _, desc in ipairs(table_) do rows[#rows + 1] = desc end
            rows[#rows + 1] = TotalRow("Reagents to buy", missing.buyTotal)
        end
    end

    local recipeRows = missing.recipeRows or {}
    if #recipeRows > 0 then
        rows[#rows + 1] = { kind = "sep" }
        rows[#rows + 1] = { kind = "line", font = "GameFontNormalSmall", color = GOLD, text = "Recipes to learn" }
        for _, entry in ipairs(recipeRows) do
            local learn = { recipe = entry.recipe, sourceInfo = entry.sourceInfo }
            local where = Text.LearnShort(learn, view.profile)
            local tooltip = { { text = "Learn " .. tostring(entry.name), r = 1, g = 1, b = 1 } }
            for _, line in ipairs(Text.LearnLines(learn, view.profile, path and path.profession)) do
                tooltip[#tooltip + 1] = { text = line.text, r = 0.7, g = 0.7, b = 0.7 }
            end
            rows[#rows + 1] = {
                kind = "cols", recipe = entry.recipe, text = tostring(entry.name) .. (where and (" - " .. where) or ""),
                cols = { "", "", "", Money(entry.cost) },
                bg = BG_SUB, hoverBg = BG_ROW_HOVER, tooltip = tooltip,
                onClick = ctx.onShowRecipe and function() ctx.onShowRecipe(entry.recipe) end or nil,
            }
        end
        rows[#rows + 1] = TotalRow("Recipes", missing.recipeCosts)
    end
    return rows
end

-- "To buy: X + Y recipes" under the shopping table.
function Views.ShoppingTotal(view)
    local missing = view.missing
    if not missing then return "" end
    local text = "To buy: " .. Money(missing.buyTotal or 0)
    if (missing.recipeCosts or 0) > 0 then
        text = text .. "  " .. Grey("+ " .. Money(missing.recipeCosts) .. " recipes")
    end
    return text
end

-- Arrow tooltip ------------------------------------------------------------------

-- What the arrow's tooltip says: the current step, the next two, the
-- receipt's amounts (what is spent, what comes back from selling, the net)
-- and where the prices came from. (The whole path is on the Path tab.)
-- Returns { { text, right, r, g, b, rr, rg, rb, wrap }, ... }; a line with
-- `right` is a two-column line.
function Views.ArrowTooltip(view)
    local lines = {}
    local function add(text, r, g, b, wrap)
        lines[#lines + 1] = { text = text, r = r or 1, g = g or 1, b = b or 1, wrap = wrap }
    end
    local function addDouble(text, right, r, g, b, rr, rg, rb)
        lines[#lines + 1] = { text = text, right = right, r = r or 1, g = g or 1, b = b or 1,
                              rr = rr or 1, rg = rg or 0.82, rb = rb or 0 }
    end
    add("LazyProf - Optimal Path", 1, 0.82, 0)
    local path = view and view.path
    if not path then return lines end
    add(" ")

    local stages = view.stages or {}
    local summary = view.summary or {}
    local current = summary.currentIndex and stages[summary.currentIndex]
    local profile, profession = view.profile, path.profession

    -- One stage as "<what>" and its cost (nil when it has none).
    local function describe(stage)
        if stage.kind == "craft" then
            return Text.StageTitle(stage), Money(stage.outOfPocketCost)
        elseif stage.kind == "learn" then
            return "Learn " .. (stage.recipe.name or "the recipe"), stage.fee > 0 and Money(stage.fee) or nil
        elseif stage.kind == "rank" then
            return Text.RankShort(stage), nil
        end
        return Text.GapText(stage), nil
    end

    if not current then
        for _, row in ipairs(Views.Notice(view) or {}) do
            add(row.text, 0.8, 0.8, 0.8, true)
        end
    else
        local what, cost = describe(current)
        if cost then addDouble("Now: " .. what, cost) else add("Now: " .. what) end
        if current.kind == "craft" then
            add(string.format("   Skill %d to %d", current.fromDisplay, current.toDisplay), 0.5, 0.5, 0.5)
        elseif current.kind == "learn" then
            for _, line in ipairs(Text.LearnLines(current, profile, profession)) do
                add("   " .. line.text, 0.7, 0.7, 0.7, true)
            end
        elseif current.kind == "rank" then
            add("   " .. Text.RankLine(current, view.liveCap, profession, path.hasProfession), 0.7, 0.7, 0.7, true)
        end
        for i = current.index + 1, math.min(current.index + 2, #stages) do
            local nextWhat, nextCost = describe(stages[i])
            local text = "Then: " .. nextWhat
            if nextCost then
                addDouble(text, nextCost, 0.7, 0.7, 0.7, 0.7, 0.6, 0.2)
            else
                add(text, 0.7, 0.7, 0.7)
            end
        end
        local more = #stages - math.min(current.index + 2, #stages)
        if more > 0 then
            add(string.format("... and %d more step%s (see the Path tab)", more, more == 1 and "" or "s"), 0.5, 0.5, 0.5)
        end
    end

    -- The receipt's amounts, label left and amount right (with gaps they
    -- cover only the path's steps, and the label says so), and its note that
    -- the amounts include spare crafts.
    local blank = false
    for _, line in ipairs(Views.Receipt(view)) do
        local amounts = (line.key == "spend" or line.key == "back" or line.key == "net")
        if amounts or line.key == "margin" then
            if not blank then
                add(" ")
                blank = true
            end
            if amounts then
                local c = line.amountColor or WHITE
                addDouble(line.label .. ": ", line.amount, 1, 1, 1, c[1], c[2], c[3])
            else
                add(line.note, 0.7, 0.7, 0.7)
            end
        end
    end

    -- Where the reagent prices came from, and what to do when some are
    -- missing, too old or only an estimate.
    if view.priceLines and #view.priceLines > 0 then
        add(" ")
        for _, line in ipairs(view.priceLines) do
            add(line.text, line.r, line.g, line.b, true)
        end
    end
    return lines
end

-- Merchant panel -----------------------------------------------------------------

-- Rows of the panel beside the merchant window: what this merchant sells of
-- the shopping list, with a Buy button each; what it sells but is not bought
-- automatically, with the reason; and the last purchase's report.
-- plan: PurchaseQueue.Plan; state: { busy = bool, report = text or nil };
-- ctx: onBuy(entry).
function Views.Merchant(plan, state, ctx)
    local rows = {}
    state = state or {}
    for _, entry in ipairs(plan and plan.entries or {}) do
        rows[#rows + 1] = {
            kind = "line", entry = entry, text = entry.name, itemId = entry.itemId,
            right = string.format("%d   %s", entry.quantity, Utils.FormatMoneyShort(entry.cost)),
            bg = BG_SUB, hoverBg = BG_ROW_HOVER,
            tooltip = { { text = string.format("%d to buy at %s each", entry.quantity, Money(entry.unitPrice)), r = 0.7, g = 0.7, b = 0.7 } },
            button = { text = "Buy", width = 44, enabled = not state.busy, onClick = function() ctx.onBuy(entry) end },
        }
    end
    for _, skipped in ipairs(plan and plan.skipped or {}) do
        rows[#rows + 1] = {
            kind = "line", text = skipped.name, right = skipped.reason, color = DIM, rightColor = DIM,
            itemId = skipped.itemId,
            tooltip = { { text = "Not bought automatically: " .. skipped.reason .. ".", r = 0.7, g = 0.7, b = 0.7 } },
        }
    end
    if state.report then
        rows[#rows + 1] = { kind = "line", wrap = true, color = GREY, text = state.report }
    end
    return rows
end

-- Text of the "Buy all" button.
function Views.MerchantBuyAll(plan, state)
    if state and state.busy then return "Buying..." end
    return "Buy all - " .. Money(plan and plan.total or 0)
end
