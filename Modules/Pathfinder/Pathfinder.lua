-- Modules/Pathfinder/Pathfinder.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.Pathfinder = {}
local Pathfinder = LazyProf.Pathfinder

-- Current calculated path
Pathfinder.currentPath = nil

-- Calculate optimal path for active profession
function Pathfinder:Calculate()
    -- Get active profession
    local profData = LazyProf.Professions:GetActive()
    if not profData then
        LazyProf:Debug("No active profession detected")
        return nil
    end

    -- Get current skill level
    local skillName, currentSkill, maxSkill = GetTradeSkillLine()
    if not currentSkill then
        LazyProf:Debug("Could not get current skill")
        return nil
    end

    -- Determine target skill (next milestone or max)
    local targetSkill = self:GetTargetSkill(currentSkill, profData.milestones)

    LazyProf:Debug(string.format("Calculating path: %s %d -> %d", skillName, currentSkill, targetSkill))

    -- Get recipes with learned status
    local recipes = LazyProf.Professions:GetRecipesWithLearnedStatus(LazyProf.Professions.active)

    -- Get inventory
    local inventory = LazyProf.Inventory:ScanBags()

    -- Get prices for all reagents
    local reagentIds = {}
    for _, recipe in ipairs(recipes) do
        for _, reagent in ipairs(recipe.reagents) do
            table.insert(reagentIds, reagent.itemId)
        end
    end
    local prices = LazyProf.PriceManager:GetPrices(reagentIds)

    -- Get strategy
    local strategyName = LazyProf.db.profile.strategy
    local strategy = LazyProf.PathfinderStrategies[strategyName]
    if not strategy then
        LazyProf:Debug("Unknown strategy: " .. strategyName)
        return nil
    end

    -- Calculate path
    local steps = strategy:Calculate(currentSkill, targetSkill, recipes, inventory, prices)

    -- Build result
    self.currentPath = {
        profession = profData.name,
        currentSkill = currentSkill,
        targetSkill = targetSkill,
        steps = steps,
        totalCost = Utils.Sum(steps, "totalCost"),
        missingMaterials = self:CalculateMissingMaterials(steps, inventory, prices),
        milestoneBreakdown = self:CalculateMilestoneBreakdown(steps, profData.milestones, inventory, prices),
    }

    LazyProf:Debug(string.format("Path calculated: %d steps, %s total",
        #steps, Utils.FormatMoney(self.currentPath.totalCost)))

    return self.currentPath
end

-- Get target skill (max or current cap)
function Pathfinder:GetTargetSkill(currentSkill, milestones)
    -- Find the max skill cap based on current skill
    -- (player needs to train at milestones to increase cap)
    local maxPossible = milestones[#milestones]

    -- For simplicity, target the final milestone
    -- Future: could detect actual skill cap from UI
    return maxPossible
end

-- Calculate total missing materials for entire path
function Pathfinder:CalculateMissingMaterials(steps, inventory, prices)
    local needed = {}

    -- Sum up all reagents needed
    for _, step in ipairs(steps) do
        for _, reagent in ipairs(step.recipe.reagents) do
            local itemId = reagent.itemId
            needed[itemId] = (needed[itemId] or 0) + (reagent.count * step.quantity)
        end
    end

    -- Calculate missing vs inventory
    local missing = {}
    for itemId, need in pairs(needed) do
        local have = inventory[itemId] or 0
        local short = math.max(0, need - have)

        if short > 0 then
            local name, link, icon = Utils.GetItemInfo(itemId)
            local price = prices[itemId] or 0

            table.insert(missing, {
                itemId = itemId,
                name = name or "Unknown",
                icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark",
                link = link,
                have = have,
                need = need,
                missing = short,
                estimatedCost = price * short,
            })
        end
    end

    -- Sort by cost descending
    table.sort(missing, function(a, b) return a.estimatedCost > b.estimatedCost end)

    return missing
end

-- Break down path by milestones
function Pathfinder:CalculateMilestoneBreakdown(steps, milestones, inventory, prices)
    local breakdown = {}

    -- Build milestone ranges
    local ranges = {}
    local prev = 1
    for _, m in ipairs(milestones) do
        table.insert(ranges, { from = prev, to = m })
        prev = m
    end

    -- Group steps into ranges
    for _, range in ipairs(ranges) do
        local rangeSteps = {}
        local rangeCost = 0
        local rangeNeeded = {}

        for _, step in ipairs(steps) do
            -- Check if step falls within this range
            if step.skillStart < range.to and step.skillEnd > range.from then
                table.insert(rangeSteps, step)
                rangeCost = rangeCost + step.totalCost

                -- Track materials for this range
                for _, reagent in ipairs(step.recipe.reagents) do
                    local itemId = reagent.itemId
                    rangeNeeded[itemId] = (rangeNeeded[itemId] or 0) + (reagent.count * step.quantity)
                end
            end
        end

        if #rangeSteps > 0 then
            -- Build recipe summary
            local summaryParts = {}
            for _, step in ipairs(rangeSteps) do
                table.insert(summaryParts, string.format("%dx %s", step.quantity, step.recipe.name))
            end

            -- Build materials list
            local materials = {}
            for itemId, need in pairs(rangeNeeded) do
                local have = inventory[itemId] or 0
                local short = math.max(0, need - have)
                local name, link, icon = Utils.GetItemInfo(itemId)
                local price = prices[itemId] or 0

                table.insert(materials, {
                    itemId = itemId,
                    name = name or "Unknown",
                    icon = icon,
                    link = link,
                    have = have,
                    need = need,
                    missing = short,
                    estimatedCost = price * short,
                })
            end

            table.insert(breakdown, {
                from = range.from,
                to = range.to,
                steps = rangeSteps,
                summary = table.concat(summaryParts, ", "),
                cost = rangeCost,
                materials = materials,
            })
        end
    end

    return breakdown
end

-- Get the current recommended recipe (first step)
function Pathfinder:GetCurrentRecommendation()
    if not self.currentPath or #self.currentPath.steps == 0 then
        return nil
    end
    return self.currentPath.steps[1]
end
