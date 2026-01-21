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

    -- Get inventory (bags + optional bank)
    local inventory, bankInventory = LazyProf.Inventory:ScanAll()

    -- Get prices for all reagents (and potential source materials for resolution)
    local reagentIds = {}
    local seenIds = {}
    for _, recipe in ipairs(recipes) do
        for _, reagent in ipairs(recipe.reagents) do
            if not seenIds[reagent.itemId] then
                seenIds[reagent.itemId] = true
                table.insert(reagentIds, reagent.itemId)
            end
        end
    end

    -- Also get prices for potential source materials (for material resolution)
    local CraftLib = _G.CraftLib
    if CraftLib and CraftLib.GetRecipeByProduct then
        for itemId in pairs(seenIds) do
            local craftRecipes = CraftLib:GetRecipeByProduct(itemId)
            if craftRecipes then
                for _, recipeInfo in ipairs(craftRecipes) do
                    if recipeInfo.recipe and recipeInfo.recipe.reagents then
                        for _, reagent in ipairs(recipeInfo.recipe.reagents) do
                            if not seenIds[reagent.itemId] then
                                seenIds[reagent.itemId] = true
                                table.insert(reagentIds, reagent.itemId)
                            end
                        end
                    end
                end
            end
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
        missingMaterials = self:CalculateMissingMaterials(steps, inventory, bankInventory, prices),
        milestoneBreakdown = self:CalculateMilestoneBreakdown(steps, profData.milestones, currentSkill, inventory, prices),
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
-- Returns { fromBank = {...}, toCraft = {...}, fromAH = {...} }
function Pathfinder:CalculateMissingMaterials(steps, inventory, bankInventory, prices)
    local needed = {}

    -- Sum up all reagents needed (preserve name from CraftLib as fallback)
    for _, step in ipairs(steps) do
        for _, reagent in ipairs(step.recipe.reagents) do
            local itemId = reagent.itemId
            if not needed[itemId] then
                needed[itemId] = { count = 0, nameFromData = reagent.name }
            end
            needed[itemId].count = needed[itemId].count + (reagent.count * step.quantity)
        end
    end

    -- Get resolution mode (only applies to Cheapest strategy)
    local resolutionMode = Constants.MATERIAL_RESOLUTION.NONE
    if LazyProf.db.profile.strategy == Constants.STRATEGY.CHEAPEST then
        resolutionMode = LazyProf.db.profile.materialResolution
    end

    -- Track intermediate crafts and resolved materials
    local toCraft = {}
    local resolvedNeeded = {} -- Final materials after resolution
    local bankPurpose = {}    -- Track why bank items are needed (for annotations)

    -- Process each needed material through MaterialResolver
    for itemId, data in pairs(needed) do
        local need = data.count
        local inBags = LazyProf.Inventory:ScanBags()[itemId] or 0
        local afterBags = math.max(0, need - inBags)

        if afterBags > 0 and LazyProf.MaterialResolver then
            -- Check if this material should be crafted
            local resolution = LazyProf.MaterialResolver:ResolveMaterial(
                itemId, afterBags, inventory, prices, {}, resolutionMode
            )

            if resolution.shouldCraft and resolution.craftRecipe then
                -- Add to toCraft list
                local name, link, icon = Utils.GetItemInfo(itemId)
                -- Fallback to CraftLib's reagent name if GetItemInfo hasn't cached the item
                name = name or data.nameFromData or "Unknown"
                icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"
                local recipeName = resolution.craftRecipe.name or "Unknown Recipe"

                -- Calculate source material breakdown
                local sourceFromBank = 0
                local sourceFromAH = 0
                local sourceMaterialName = ""

                for _, source in ipairs(resolution.sourceItems) do
                    sourceFromBank = sourceFromBank + source.fromInventory
                    sourceFromAH = sourceFromAH + source.toBuy
                    sourceMaterialName = source.name or "Unknown"

                    -- Add source materials to resolvedNeeded (preserve name fallback)
                    if not resolvedNeeded[source.itemId] then
                        resolvedNeeded[source.itemId] = { count = 0, nameFromData = source.name }
                    end
                    resolvedNeeded[source.itemId].count = resolvedNeeded[source.itemId].count + source.totalNeeded

                    -- Track bank purpose for source materials
                    if source.fromInventory > 0 then
                        bankPurpose[source.itemId] = string.format("for %s", recipeName:lower())
                    end
                end

                -- Build source description for UI
                local totalSourceNeeded = sourceFromBank + sourceFromAH
                local sourceDesc = string.format("%dx %s", totalSourceNeeded, sourceMaterialName)
                local usingDesc = ""
                if sourceFromBank > 0 and sourceFromAH > 0 then
                    usingDesc = string.format("%dx from bank + %dx from AH", sourceFromBank, sourceFromAH)
                elseif sourceFromBank > 0 then
                    usingDesc = string.format("%dx from bank", sourceFromBank)
                else
                    usingDesc = string.format("%dx from AH", sourceFromAH)
                end

                table.insert(toCraft, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    quantity = afterBags,
                    recipeName = recipeName,
                    professionKey = resolution.professionKey,
                    sourceDesc = sourceDesc,
                    usingDesc = usingDesc,
                    craftCost = resolution.craftCost,
                    sourceItems = resolution.sourceItems,
                })
            else
                -- Not crafting - add directly to resolvedNeeded (preserve name fallback)
                if not resolvedNeeded[itemId] then
                    resolvedNeeded[itemId] = { count = 0, nameFromData = data.nameFromData }
                end
                resolvedNeeded[itemId].count = resolvedNeeded[itemId].count + afterBags
            end
        elseif afterBags > 0 then
            -- No MaterialResolver or no resolution needed (preserve name fallback)
            if not resolvedNeeded[itemId] then
                resolvedNeeded[itemId] = { count = 0, nameFromData = data.nameFromData }
            end
            resolvedNeeded[itemId].count = resolvedNeeded[itemId].count + afterBags
        end
    end

    -- Categorize resolved materials by source: bank vs AH
    local fromBank = {}
    local fromAH = {}

    for itemId, data in pairs(resolvedNeeded) do
        local need = data.count
        local inBags = LazyProf.Inventory:ScanBags()[itemId] or 0
        local inBank = bankInventory and bankInventory[itemId] or 0
        local totalHave = inventory[itemId] or 0

        -- How many do we still need after bags?
        local afterBags = math.max(0, need - inBags)

        if afterBags > 0 then
            local name, link, icon = Utils.GetItemInfo(itemId)
            local price = prices[itemId] or 0

            -- Fallback to CraftLib's reagent name if GetItemInfo hasn't cached the item
            name = name or data.nameFromData or "Unknown"
            icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"

            -- How many can come from bank?
            local fromBankCount = math.min(afterBags, inBank)
            -- How many must come from AH?
            local fromAHCount = math.max(0, afterBags - inBank)

            if fromBankCount > 0 then
                local purpose = bankPurpose[itemId] -- e.g., "for smelting"
                table.insert(fromBank, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    have = inBank,
                    need = fromBankCount,
                    missing = fromBankCount,
                    estimatedCost = 0, -- Bank items are free
                    purpose = purpose, -- Annotation for UI
                })
            end

            if fromAHCount > 0 then
                table.insert(fromAH, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    have = totalHave,
                    need = need,
                    missing = fromAHCount,
                    estimatedCost = price * fromAHCount,
                })
            end
        end
    end

    -- Sort by cost descending (AH items) and by name (bank/craft items)
    table.sort(fromAH, function(a, b) return a.estimatedCost > b.estimatedCost end)
    table.sort(fromBank, function(a, b) return (a.name or "") < (b.name or "") end)
    table.sort(toCraft, function(a, b) return (a.name or "") < (b.name or "") end)

    return { fromBank = fromBank, toCraft = toCraft, fromAH = fromAH }
end

-- Break down path by milestones
function Pathfinder:CalculateMilestoneBreakdown(steps, milestones, currentSkill, inventory, prices)
    local breakdown = {}
    local calculateFromCurrent = LazyProf.db.profile.calculateFromCurrentSkill

    -- Build milestone ranges
    local ranges = {}
    local prev = 1
    for _, m in ipairs(milestones) do
        table.insert(ranges, { from = prev, to = m })
        prev = m
    end

    -- Group steps into ranges
    for _, range in ipairs(ranges) do
        -- When calculateFromCurrentSkill is enabled, adjust the first applicable range
        local displayFrom = range.from
        if calculateFromCurrent and currentSkill > range.from and currentSkill < range.to then
            displayFrom = currentSkill
        end
        local rangeSteps = {}
        local rangeCost = 0
        local rangeNeeded = {}

        for _, step in ipairs(steps) do
            -- Check if step falls within this range
            if step.skillStart < range.to and step.skillEnd > range.from then
                table.insert(rangeSteps, step)
                rangeCost = rangeCost + step.totalCost

                -- Track materials for this range (preserve name from CraftLib as fallback)
                for _, reagent in ipairs(step.recipe.reagents) do
                    local itemId = reagent.itemId
                    if not rangeNeeded[itemId] then
                        rangeNeeded[itemId] = { count = 0, nameFromData = reagent.name }
                    end
                    rangeNeeded[itemId].count = rangeNeeded[itemId].count + (reagent.count * step.quantity)
                end
            end
        end

        if #rangeSteps > 0 then
            -- Skip ranges already completed when calculateFromCurrent is enabled
            if calculateFromCurrent and currentSkill >= range.to then
                -- Skip this completed range
            else
                -- Build recipe summary
                local summaryParts = {}
                for _, step in ipairs(rangeSteps) do
                    table.insert(summaryParts, string.format("%dx %s", step.quantity, step.recipe.name))
                end

                -- Build materials list
                local materials = {}
                for itemId, data in pairs(rangeNeeded) do
                    local need = data.count
                    local have = inventory[itemId] or 0
                    local short = math.max(0, need - have)
                    local name, link, icon = Utils.GetItemInfo(itemId)
                    local price = prices[itemId] or 0

                    -- Fallback to CraftLib's reagent name if GetItemInfo hasn't cached the item
                    name = name or data.nameFromData or "Unknown"
                    icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"

                    table.insert(materials, {
                        itemId = itemId,
                        name = name,
                        icon = icon,
                        link = link,
                        have = have,
                        need = need,
                        missing = short,
                        estimatedCost = price * short,
                    })
                end

                table.insert(breakdown, {
                    from = displayFrom,
                    to = range.to,
                    steps = rangeSteps,
                    summary = table.concat(summaryParts, ", "),
                    cost = rangeCost,
                    materials = materials,
                })
            end
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
