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

local LEARN_COLOR = { 1, 0.75, 0.3 }

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

-- Tooltip of an alternative: what it is, why it may be blocked, what it costs.
local function AlternativeTooltip(alt)
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
    if alt.priced then
        lines[#lines + 1] = { text = string.format("About %d crafts for this step: %s", alt.projectedCrafts,
            Money(alt.projectedCost)), r = 1, g = 1, b = 1 }
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

local function AlternativeRow(stage, alt, ctx)
    local name = alt.recipe.name or "Unknown"
    if not alt.recipe.learned then
        name = name .. " |cFFFF8800[!]|r"
    end
    local right
    if alt.priced then
        right = Signed(alt.craftsDelta, "crafts") .. "  " .. SignedMoney(alt.costDelta)
    else
        right = Grey("no price")
    end
    local useTip = { { text = "Use this recipe for the step", r = 1, g = 1, b = 1 },
        { text = "The path is planned again at once. Reset puts the planner's choice back.", r = 0.7, g = 0.7, b = 0.7 } }
    if alt.unavailable then
        useTip[#useTip + 1] = { text = "You will need to obtain this recipe yourself.", r = 1, g = 0.53, b = 0 }
    end
    return {
        kind = "line", alt = alt, indent = 6, text = name, color = Views.DifficultyColor(alt.color),
        right = right, alpha = alt.unavailable and 0.5 or 1,
        bg = BG_SUB, hoverBg = BG_ROW_HOVER, tooltip = AlternativeTooltip(alt),
        onClick = function() ctx.onShowRecipe(alt.recipe, stage.fromDisplay) end,
        button = { text = "Use this", width = 62, tooltip = useTip, onClick = function() ctx.onUseAlternative(stage, alt) end },
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
            rows[#rows + 1] = { kind = "line", wrap = true, color = DIFFICULTY_COLOR.green,
                text = "No orange or yellow recipe is available here, so this green recipe keeps you leveling." }
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
        local LINE_COLOR = { plain = WHITE, good = GREEN, warn = { 1, 0.3, 0.3 }, cost = GOLD }
        for _, line in ipairs(Text.LearnLines(stage, view.profile, path and path.profession)) do
            rows[#rows + 1] = { kind = "line", wrap = true, text = line.text, color = LINE_COLOR[line.color] or WHITE }
        end
        -- The profession window's filter hides unlearned recipes, so the arrow
        -- has no row to point at for this one.
        if view.hiddenRecipeId and view.hiddenRecipeId == recipe.id then
            rows[#rows + 1] = { kind = "line", wrap = true, color = ORANGE,
                text = "The profession window hides unlearned recipes, so the arrow cannot point at this one until you learn it." }
        end
    elseif stage.kind == "rank" then
        rows[#rows + 1] = { kind = "line", height = 26, font = "GameFontNormalLarge", color = GOLD,
            text = "Train the next rank", right = "before " .. tostring(stage.cap), rightColor = GOLD }
        rows[#rows + 1] = { kind = "line", wrap = true, color = WHITE,
            text = Text.RankLine(stage, view.liveCap, path and path.profession, path and path.hasProfession) }
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
    local lines = {}
    if row.choice then
        lines[#lines + 1] = { text = row.crafted and "You chose to craft this yourself." or "You chose to buy this.", r = 1, g = 1, b = 1 }
    else
        lines[#lines + 1] = { text = row.crafted and "Chosen automatically: crafting is cheaper."
            or "Chosen automatically: buying is cheaper, or automatic crafting is off.", r = 1, g = 1, b = 1 }
    end
    if row.craftRecipeName then
        lines[#lines + 1] = { text = "Recipe: " .. row.craftRecipeName, r = 0.7, g = 0.7, b = 0.7 }
    end
    lines[#lines + 1] = { text = "Click to switch. Right-click for automatic.", r = 0.5, g = 0.5, b = 0.5 }
    lines[#lines + 1] = { text = "This changes the shopping list only, not the path.", r = 0.5, g = 0.5, b = 0.5 }
    return {
        text = row.crafted and "I craft it" or "I buy it",
        tooltip = lines,
        onClick = function(mouseButton)
            if mouseButton == "RightButton" then
                ctx.onCraftChoice(row, nil)
            else
                ctx.onCraftChoice(row, row.crafted and "buy" or "craft")
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

-- "Collect first", then one row per reagent: need / have / buy / cost, a
-- "vendor" mark, and a craft / buy button on reagents the character can make.
-- view.missing is Pathfinder:CalculateMissingMaterials of the chosen range;
-- view.hideOwned hides rows with nothing left to buy.
-- ctx: onCraftChoice(row, "craft" | "buy" | nil).
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
        return rows
    end

    local table_ = {}
    local toBuyRows = 0
    for _, row in ipairs(items) do
        if row.toBuy > 0 then toBuyRows = toBuyRows + 1 end
        if not (view.hideOwned and row.toBuy <= 0 and not row.crafted) then
            local buy = row.toBuy > 0 and tostring(row.toBuy) or "-"
            local cost
            if row.crafted or row.toBuy <= 0 then
                cost = row.crafted and "" or "-"
            elseif row.unpriced then
                cost = "?"
            else
                cost = Utils.FormatMoneyShort(row.cost)
            end
            local desc = {
                kind = "cols", item = row, icon = row.icon, text = row.name,
                cols = { tostring(row.need), tostring(row.have), buy, cost },
                colColors = {
                    [2] = row.have >= row.need and GREEN or WHITE,
                    [3] = row.toBuy > 0 and RED or DIM,
                    [4] = row.unpriced and ORANGE or WHITE,
                },
                mark = row.isVendor and "vendor" or nil,
                bg = BG_SUB, hoverBg = BG_ROW_HOVER,
                itemId = row.itemId, link = row.link, tooltip = ShoppingTooltip(row),
            }
            if row.craftable then
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
    end

    if toBuyRows == 0 then
        rows[#rows + 1] = { kind = "line", color = GREEN, text = "Nothing left to buy"
            .. (view.bracket and (" for " .. view.bracket.name) or "") .. "." }
    end
    if #table_ > 0 then
        rows[#rows + 1] = Views.ReagentHeader()
        for _, desc in ipairs(table_) do rows[#rows + 1] = desc end
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
