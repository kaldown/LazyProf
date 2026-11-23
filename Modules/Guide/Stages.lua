-- Modules/Guide/Stages.lua
-- Folds a calculated path into the steps a player follows.
--
-- The planner's steps are fragments: about five crafts each, cut at every
-- recipe unlock and colour change, with fractional skill boundaries. A stage
-- is what a person does:
--   craft  consecutive fragments of one recipe, merged
--   learn  "learn this recipe", before the first craft stage of each recipe
--          the character does not know (opts.includeLearn)
--   rank   "train the next rank", before the first fragment that ends above a
--          cap the character has not trained past yet (opts.liveCap)
--   gap    a skill range no recipe covers
--
-- Fragments are never re-cut: the planner's output (and its snapshots) stay
-- as they are, so the craft stage after a rank step may start a few points
-- below the cap.
--
-- Pure: no frames and no client calls except item names through Utils.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

local Stages = {}
LazyProf.Stages = Stages

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- One-time cost of getting an unlearned recipe (0 when learned, free or unknown).
function Stages.RecipeFee(recipe)
    local info = recipe and not recipe.learned and recipe._sourceInfo
    if not info then return 0 end
    if info.type == "trainer" or info.type == "vendor" then
        return info.cost or 0
    elseif info.type == "ah" then
        return info.price or 0
    end
    return 0
end

-- The cap a character works under: the real one, or the first cap for a
-- profession not learned yet.
function Stages.LiveCap(maxRank, milestones)
    if maxRank and maxRank > 0 then return maxRank end
    return milestones and milestones[1] or nil
end

-- Margin: extra crafts for bad luck, rounded up once per stage.
local function WithMargin(quantity, percent)
    if not percent or percent <= 0 then return quantity end
    return math.ceil(quantity * (1 + percent / 100) - 1e-9)
end

-- Reagent rows for `quantity` crafts against `remaining` (owned counts left
-- after earlier stages), consuming what is used. Returns the rows, the market
-- cost of all reagents and the cost of what is missing.
local function Materials(recipe, quantity, remaining, prices)
    local rows, cost, pay = {}, 0, 0
    for _, reagent in ipairs(recipe.reagents or {}) do
        local need = reagent.count * quantity
        local have = remaining[reagent.itemId] or 0
        local used = math.min(need, have)
        local missing = need - used
        remaining[reagent.itemId] = have - used
        local price = prices[reagent.itemId]
        local name, link, icon = Utils.GetItemInfo(reagent.itemId)
        rows[#rows + 1] = {
            itemId = reagent.itemId,
            name = name or reagent.name or "Unknown",
            icon = icon or QUESTION_MARK,
            link = link,
            need = need,
            have = have,
            missing = missing,
            price = price,
            estimatedCost = (price or 0) * missing,
        }
        cost = cost + (price or 0) * need
        pay = pay + (price or 0) * missing
    end
    return rows, cost, pay
end

-- Colour at the stage's start and the skills inside it where it changes.
local function Colors(recipe, from, to, racialBonus)
    local range = recipe.skillRange
    local color = Utils.GetSkillColor(from - racialBonus, range)
    local changes = {}
    for _, t in ipairs({
        { skill = range.yellow + racialBonus, color = "yellow" },
        { skill = range.green + racialBonus, color = "green" },
        { skill = range.gray + racialBonus, color = "gray" },
    }) do
        if t.skill > from and t.skill < to then
            changes[#changes + 1] = t
        end
    end
    return color, changes
end

-- The other recipes that could cover the stage, from the first fragment's
-- scored list, with what choosing each would mean for the stage: crafts and
-- cost over the stage's range, against what the stage costs the player. Both
-- sides are net of what the crafts sell for (saleValues by recipe id) and both
-- carry the margin when it is on, so like is compared with like.
local function Alternatives(stage, inventoryBefore, prices, stagePay, saleValues, margin)
    local out = {}
    local span = stage.to - stage.from
    for _, alt in ipairs(stage.fragments[1].alternatives or {}) do
        if alt.recipe.id ~= stage.recipe.id then
            local crafts = 1
            if alt.expectedSkillups and alt.expectedSkillups > 0 and span > 0 then
                crafts = math.ceil(span / alt.expectedSkillups - 1e-9)
            end
            crafts = WithMargin(crafts, margin)
            local reagentCost, priced = 0, true
            for _, reagent in ipairs(alt.recipe.reagents or {}) do
                local price = prices[reagent.itemId]
                if not price or price <= 0 then priced = false end
                local missing = math.max(0, reagent.count * crafts - (inventoryBefore[reagent.itemId] or 0))
                reagentCost = reagentCost + (price or 0) * missing
            end
            local fee = Stages.RecipeFee(alt.recipe)
            local projected = reagentCost + fee
            local saleEach = saleValues[alt.recipe.id] or 0
            local projectedSale = crafts * saleEach
            local projectedNet = projected - projectedSale
            out[#out + 1] = {
                recipe = alt.recipe,
                score = alt.score,
                color = alt.color,
                expectedSkillups = alt.expectedSkillups,
                craftCost = alt.craftCost,
                fee = fee,
                priced = priced,
                projectedCrafts = crafts,
                projectedCost = projected,
                saleEach = saleEach,
                projectedSale = projectedSale,
                projectedNet = projectedNet,
                craftsDelta = crafts - stage.quantity,
                costDelta = projectedNet - (stagePay - stage.sale),
                unavailable = alt.recipe._isUnavailable and true or false,
                reason = alt.recipe._unavailableReason,
            }
        end
    end
    -- Usable ones first, cheapest for the player first.
    table.sort(out, function(a, b)
        if a.unavailable ~= b.unavailable then return not a.unavailable end
        if a.priced ~= b.priced then return a.priced end
        if a.projectedNet ~= b.projectedNet then return a.projectedNet < b.projectedNet end
        return (a.recipe.name or "") < (b.recipe.name or "")
    end)
    return out
end

-- Steps and gaps in skill order: each gap goes before the first step that
-- starts above it.
local function Entries(path)
    local entries = {}
    local gaps = path.gaps or {}
    local gi = 1
    for _, step in ipairs(path.steps or {}) do
        while gaps[gi] and gaps[gi].from < step.skillStart do
            entries[#entries + 1] = { gap = gaps[gi], to = gaps[gi].to }
            gi = gi + 1
        end
        entries[#entries + 1] = { step = step, to = step.skillEnd }
    end
    for i = gi, #gaps do
        entries[#entries + 1] = { gap = gaps[i], to = gaps[i].to }
    end
    return entries
end

-- Totals of a stage list (all stages, or the stages of one range):
--   cost / pay              market cost and what the player still pays (owned
--                           stock taken off), recipe fees included, expected
--                           quantities
--   sale / net              what the crafts sell for, and pay less that
--   marginCost / marginPay / marginSale / marginNet
--                           the same with the margin (nil when the margin is off)
--   columnPay / shownSale   as the window shows them (the stages' own
--                           quantities, margin included when on): the craft
--                           stages' reagent costs without recipe fees, and
--                           what their crafts sell for
--   fees, crafts
function Stages.Totals(stages)
    local t = { cost = 0, pay = 0, fees = 0, crafts = 0, sale = 0, columnPay = 0, shownSale = 0 }
    local margin = false
    local marginCost, marginPay = 0, 0
    for _, stage in ipairs(stages) do
        if stage.kind == "craft" then
            local feeInside = stage.feeIncluded and stage.fee or 0
            t.cost = t.cost + stage.baseCost + feeInside
            t.pay = t.pay + stage.basePay + feeInside
            t.fees = t.fees + feeInside
            t.crafts = t.crafts + stage.quantity
            t.sale = t.sale + (stage.baseSale or 0)
            t.columnPay = t.columnPay + stage.outOfPocketCost - feeInside
            t.shownSale = t.shownSale + (stage.sale or 0)
            marginCost = marginCost + stage.cost
            marginPay = marginPay + stage.outOfPocketCost
            if stage.quantity ~= stage.baseQuantity or stage.margin then margin = true end
        elseif stage.kind == "learn" then
            t.cost = t.cost + stage.fee
            t.pay = t.pay + stage.fee
            t.fees = t.fees + stage.fee
            marginCost = marginCost + stage.fee
            marginPay = marginPay + stage.fee
        end
    end
    t.net = t.pay - t.sale
    if margin then
        t.marginCost, t.marginPay = marginCost, marginPay
        t.marginSale = t.shownSale
        t.marginNet = marginPay - t.shownSale
    end
    return t
end

-- What the shopping list is computed from: one entry per craft stage, with
-- the stage's quantity (margin included).
function Stages.ShoppingSteps(stages)
    local steps = {}
    for _, stage in ipairs(stages) do
        if stage.kind == "craft" then
            steps[#steps + 1] = { recipe = stage.recipe, quantity = stage.quantity, skillStart = stage.from }
        end
    end
    return steps
end

-- Build the stage list of a path.
-- opts:
--   actualSkill    the character's real skill (default path.actualSkill); nil = nothing is done
--   liveCap        the cap the character works under; nil = no rank steps
--   includeLearn   add learn steps and move recipe fees into them
--   marginPercent  nil / 0 = off
--   inventory      owned counts { [itemId] = n } (default none)
--   prices         { [itemId] = copper } (default path.prices)
--   racialBonus    default path.racialBonus
--   milestones     the profession's caps (default path.milestones)
--   pins           pin list, to mark pinned stages
--   sale           { [recipeId] = copper } what one craft sells for (default
--                  path.sale.values; none: nothing is counted as sold)
-- Returns stages, summary (Stages.Totals of all stages plus currentIndex).
function Stages.Build(path, opts)
    opts = opts or {}
    local prices = opts.prices or path.prices or {}
    local racialBonus = opts.racialBonus or path.racialBonus or 0
    local milestones = opts.milestones or path.milestones or {}
    local actual = opts.actualSkill
    if actual == nil then actual = path.actualSkill end
    local target = path.targetSkill or 0
    local margin = opts.marginPercent
    if margin and margin <= 0 then margin = nil end
    local saleValues = opts.sale or (path.sale and path.sale.values) or {}

    -- Caps still to train, in order.
    local caps = {}
    if opts.liveCap then
        for _, cap in ipairs(milestones) do
            if cap >= opts.liveCap and cap < target then
                caps[#caps + 1] = cap
            end
        end
    end
    local capIndex = 1

    local stages = {}
    local current = nil          -- the craft stage being merged into
    local learnAdded = {}        -- [recipeId] = true once its learn step exists
    local firstUse = {}          -- [recipeId] = true once a craft stage used it

    local function close()
        current = nil
    end

    for _, entry in ipairs(Entries(path)) do
        -- A rank step goes before the first entry that ends above a cap.
        while caps[capIndex] and entry.to > caps[capIndex] do
            close()
            local cap = caps[capIndex]
            stages[#stages + 1] = { kind = "rank", cap = cap, at = cap, from = cap, to = cap,
                                    fromDisplay = cap, toDisplay = cap }
            capIndex = capIndex + 1
        end

        if entry.gap then
            close()
            local gap = entry.gap
            stages[#stages + 1] = { kind = "gap", from = gap.from, to = gap.to, reason = gap.reason,
                                    fromDisplay = math.floor(gap.from), toDisplay = math.floor(gap.to) }
        else
            local step = entry.step
            local recipe = step.recipe
            local sameRun = current and current.recipe.id == recipe.id
                and (current.bridge or false) == (step.bridge or false)
            if sameRun then
                current.fragments[#current.fragments + 1] = step
                current.baseQuantity = current.baseQuantity + step.quantity
                current.to = step.skillEnd
                current.toDisplay = math.floor(step.skillEnd)
            else
                close()
                local fee = 0
                if not firstUse[recipe.id] then
                    firstUse[recipe.id] = true
                    fee = Stages.RecipeFee(recipe)
                end
                if opts.includeLearn and not recipe.learned and not learnAdded[recipe.id] then
                    learnAdded[recipe.id] = true
                    local info = recipe._sourceInfo
                    stages[#stages + 1] = {
                        kind = "learn", recipe = recipe, sourceInfo = info, fee = fee,
                        currency = info and info.currency or nil,
                        at = math.floor(step.skillStart), from = step.skillStart, to = step.skillStart,
                        fromDisplay = math.floor(step.skillStart), toDisplay = math.floor(step.skillStart),
                    }
                end
                current = {
                    kind = "craft", recipe = recipe, bridge = step.bridge and true or nil,
                    fragments = { step }, baseQuantity = step.quantity,
                    from = step.skillStart, to = step.skillEnd,
                    fromDisplay = math.floor(step.skillStart), toDisplay = math.floor(step.skillEnd),
                    fee = fee, feeIncluded = (fee > 0 and not opts.includeLearn) or nil,
                }
                stages[#stages + 1] = current
            end
        end
    end

    -- Quantities, reagents and costs. Two passes over the owned stock: one
    -- with the expected quantities (the totals the path reports) and, when
    -- the margin is on, one with the margin (what the window shows).
    local remainingBase, remainingShown = {}, {}
    for itemId, count in pairs(opts.inventory or {}) do
        remainingBase[itemId] = count
        remainingShown[itemId] = count
    end
    for index, stage in ipairs(stages) do
        stage.index = index
        -- A key that survives a recalculation (expanded rows, the selected card)
        stage.key = stage.kind .. ":" .. tostring(stage.recipe and stage.recipe.id or stage.cap or "") .. ":"
            .. tostring(stage.fromDisplay)
        if stage.kind == "craft" then
            local feeInside = stage.feeIncluded and stage.fee or 0
            local before = {}
            for itemId, count in pairs(remainingShown) do before[itemId] = count end

            local _, baseCost, basePay = Materials(stage.recipe, stage.baseQuantity, remainingBase, prices)
            stage.baseCost, stage.basePay = baseCost, basePay
            stage.quantity = WithMargin(stage.baseQuantity, margin)
            stage.margin = margin and true or nil
            local rows, cost, pay = Materials(stage.recipe, stage.quantity, remainingShown, prices)
            stage.materials = rows
            stage.cost = cost + feeInside
            stage.outOfPocketCost = pay + feeInside
            stage.saleEach = saleValues[stage.recipe.id] or 0
            stage.baseSale = stage.baseQuantity * stage.saleEach
            stage.sale = stage.quantity * stage.saleEach
            stage.color, stage.colorChanges = Colors(stage.recipe, stage.from, stage.to, racialBonus)
            stage.pinned = (LazyProf.Pins.Find(opts.pins, stage.from) == stage.recipe.id) or nil
            stage.alternatives = Alternatives(stage, before, prices,
                stage.outOfPocketCost + (stage.feeIncluded and 0 or stage.fee), saleValues, margin)
        end
    end

    -- Done marks, last to first (a learn or rank step is done when the stage
    -- after it is), then the current stage: the first one not done.
    for i = #stages, 1, -1 do
        local stage = stages[i]
        if stage.kind == "craft" or stage.kind == "gap" then
            stage.done = (actual ~= nil and actual >= stage.to) or false
        else
            stage.done = (stages[i + 1] ~= nil and stages[i + 1].done) or false
        end
    end
    local summary = Stages.Totals(stages)
    for i, stage in ipairs(stages) do
        if not stage.done then
            stage.current = true
            summary.currentIndex = i
            break
        end
    end
    return stages, summary
end
