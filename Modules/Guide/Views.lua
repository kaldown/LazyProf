-- Modules/Guide/Views.lua
-- What the LazyProf window shows, as plain data. Each function turns the
-- window's state (the path, its stages, the chosen range, what is expanded)
-- into text and row descriptors for Widgets/RowList.lua. Nothing here touches
-- a frame, so the content of every tab is tested headlessly; the frame code
-- only places widgets and passes clicks back through `ctx` callbacks.
--
-- `view` is built by the window (GuideWindow:ComputeView):
--   path, stages, summary        the path, all its stages, Stages.Totals of them
--   rangeStages, rangeTotals     the stages of the chosen range and their totals
--   bracket, rangeLabel          the chosen range (nil = full path) and its label
--   skill, cap                   the real skill and the live cap (nil when unknown)
--   priceSummary, priceLines     PriceManager:PathSummary / SummaryLines of the path
--   marginPercent                nil when the margin is off
--   expanded                     { [stage.key] = true } rows opened on the Steps tab
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils
local Text = LazyProf.GuideText

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
local RED = { 1, 0.4, 0.4 }
local ORANGE = { 1, 0.5, 0 }
local GAP_RED = { 1, 0.5, 0.4 }

local BG_ROW = { 0.15, 0.15, 0.15, 0.3 }
local BG_ROW_HOVER = { 0.25, 0.25, 0.25, 0.6 }
local BG_CURRENT = { 0.35, 0.28, 0.05, 0.55 }
local BG_CURRENT_HOVER = { 0.45, 0.36, 0.1, 0.7 }
local BG_GAP = { 0.35, 0.1, 0.1, 0.35 }
local BG_GAP_HOVER = { 0.45, 0.15, 0.15, 0.6 }
local BG_SUB = { 0.12, 0.12, 0.12, 0.5 }

local function Money(copper)
    return Utils.FormatMoney(copper)
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
        line1 = "This range: " .. PayText(range) .. "   " .. Grey("|") .. "   " .. whole
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
        cost = Utils.FormatMoneyShort(mat.estimatedCost)
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
            [3] = mat.missing > 0 and RED or DIM,
            [4] = (mat.missing > 0 and not mat.price) and ORANGE or WHITE,
        },
        bg = BG_SUB, hoverBg = BG_ROW_HOVER,
        itemId = mat.itemId, link = mat.link, tooltip = tooltip,
    }
end

-- Steps tab --------------------------------------------------------------------

local function CraftTooltip(stage)
    local lines = {
        { text = Text.StageTitle(stage), r = 1, g = 1, b = 1 },
        { text = string.format("Skill %d to %d", stage.fromDisplay, stage.toDisplay), r = 0.7, g = 0.7, b = 0.7 },
        { text = Text.ColorChanges(stage), r = 0.7, g = 0.7, b = 0.7 },
    }
    if stage.bridge then
        lines[#lines + 1] = { text = "No orange or yellow recipe is available here, so this green recipe keeps you leveling.",
            r = 0.25, g = 0.75, b = 0.25 }
    end
    local pay, cost = stage.outOfPocketCost, stage.cost
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
    if stage.margin and stage.quantity ~= stage.baseQuantity then
        lines[#lines + 1] = { text = string.format("%d crafts expected, %d with margin", stage.baseQuantity, stage.quantity),
            r = 0.7, g = 0.7, b = 0.7 }
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

-- "> 143-165" for the current stage, "143-165" otherwise.
local function Lead(stage)
    return (stage.current and "> " or "") .. Text.StageRange(stage)
end

-- One row per stage of the chosen range; a craft row opens its reagents in
-- place. ctx: onToggleExpand(stage).
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
            }
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
