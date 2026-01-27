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

    -- Get inventory (bags + optional bank + optional alts)
    local inventory, bankInventory, altInventory, altItemsByCharacter = LazyProf.Inventory:ScanAll()

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
        missingMaterials = self:CalculateMissingMaterials(steps, inventory, bankInventory, altInventory, altItemsByCharacter, prices),
        milestoneBreakdown = self:CalculateMilestoneBreakdown(steps, profData.milestones, currentSkill, inventory, prices),
    }

    LazyProf:Debug(string.format("Path calculated: %d steps, %s total",
        #steps, Utils.FormatMoney(self.currentPath.totalCost)))

    return self.currentPath
end

-- Calculate path for a specific profession (for planning mode)
-- profKey: profession key like "alchemy", "engineering"
-- skillLevel: current skill (0 if not learned)
function Pathfinder:CalculateForProfession(profKey, skillLevel)
    local profData = LazyProf.Professions:Get(profKey)
    if not profData then
        LazyProf:Debug("Profession not found: " .. tostring(profKey))
        return nil
    end

    -- In WoW, you start at skill 1 when learning a profession, not 0
    -- Use minimum of 1 for planning mode calculations
    skillLevel = math.max(1, skillLevel or 0)
    local targetSkill = self:GetTargetSkill(skillLevel, profData.milestones)

    LazyProf:Debug(string.format("Planning path: %s %d -> %d", profData.name, skillLevel, targetSkill))

    -- Get all recipes (no learned status needed for planning)
    local recipes = LazyProf.Utils.DeepCopy(profData.recipes)
    -- Mark all as unlearned for planning mode
    for _, recipe in ipairs(recipes) do
        recipe.learned = false
    end

    -- Get inventory (bags + optional bank + optional alts)
    local inventory, bankInventory, altInventory, altItemsByCharacter = LazyProf.Inventory:ScanAll()

    -- Get prices for all reagents
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
    local steps = strategy:Calculate(skillLevel, targetSkill, recipes, inventory, prices)

    -- Build result (similar to Calculate() but stored separately)
    local path = {
        profession = profData.name,
        professionKey = profKey,
        currentSkill = skillLevel,
        targetSkill = targetSkill,
        steps = steps,
        totalCost = Utils.Sum(steps, "totalCost"),
        missingMaterials = self:CalculateMissingMaterials(steps, inventory, bankInventory, altInventory, altItemsByCharacter, prices),
        milestoneBreakdown = self:CalculateMilestoneBreakdown(steps, profData.milestones, skillLevel, inventory, prices),
    }

    LazyProf:Debug(string.format("Planning path calculated: %d steps, %s total",
        #steps, Utils.FormatMoney(path.totalCost)))

    return path
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
-- Returns { fromBank = {...}, fromAlts = {...}, toCraft = {...}, fromAH = {...} }
function Pathfinder:CalculateMissingMaterials(steps, inventory, bankInventory, altInventory, altItemsByCharacter, prices)
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

    -- Categorize resolved materials by source: bank vs alts vs AH
    local fromBank = {}
    local fromAlts = {}
    local fromAH = {}

    for itemId, data in pairs(resolvedNeeded) do
        local need = data.count
        local inBags = LazyProf.Inventory:ScanBags()[itemId] or 0
        local inBank = bankInventory and bankInventory[itemId] or 0
        local inAlts = altInventory and altInventory[itemId] or 0
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
            local afterBank = math.max(0, afterBags - inBank)

            -- How many can come from alts?
            local fromAltCount = 0
            local altCharacters = {}
            if afterBank > 0 and altItemsByCharacter and altItemsByCharacter[itemId] then
                local remaining = afterBank
                for charName, charCount in pairs(altItemsByCharacter[itemId]) do
                    local useFromChar = math.min(remaining, charCount)
                    if useFromChar > 0 then
                        fromAltCount = fromAltCount + useFromChar
                        remaining = remaining - useFromChar
                        table.insert(altCharacters, { name = charName, count = useFromChar })
                    end
                    if remaining <= 0 then break end
                end
            end
            local afterAlts = math.max(0, afterBank - fromAltCount)

            -- How many must come from AH?
            local fromAHCount = afterAlts

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

            if fromAltCount > 0 then
                table.insert(fromAlts, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    missing = fromAltCount,
                    have = inAlts,
                    characters = altCharacters,  -- Which alts have this item
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

    -- Sort by cost descending (AH items) and by name (bank/craft/alt items)
    table.sort(fromAH, function(a, b) return a.estimatedCost > b.estimatedCost end)
    table.sort(fromBank, function(a, b) return (a.name or "") < (b.name or "") end)
    table.sort(fromAlts, function(a, b) return (a.name or "") < (b.name or "") end)
    table.sort(toCraft, function(a, b) return (a.name or "") < (b.name or "") end)

    return { fromBank = fromBank, fromAlts = fromAlts, toCraft = toCraft, fromAH = fromAH }
end

-- Break down path by individual steps (step-by-step format)
function Pathfinder:CalculateMilestoneBreakdown(steps, milestones, currentSkill, inventory, prices)
    local breakdown = {}

    for _, step in ipairs(steps) do
        -- Calculate materials for this step only
        local materials = {}
        for _, reagent in ipairs(step.recipe.reagents) do
            local need = reagent.count * step.quantity
            local have = inventory[reagent.itemId] or 0
            local missing = math.max(0, need - have)
            local name, link, icon = Utils.GetItemInfo(reagent.itemId)
            local price = prices[reagent.itemId] or 0

            -- Fallback to CraftLib's reagent name if GetItemInfo hasn't cached the item
            name = name or reagent.name or "Unknown"
            icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"

            table.insert(materials, {
                itemId = reagent.itemId,
                name = name,
                icon = icon,
                link = link,
                need = need,
                have = have,
                missing = missing,
                estimatedCost = price * missing,
            })
        end

        -- Build materials summary string
        local materialParts = {}
        for _, mat in ipairs(materials) do
            table.insert(materialParts, string.format("%dx %s", mat.need, mat.name))
        end

        table.insert(breakdown, {
            from = step.skillStart,
            to = step.skillEnd,
            recipe = step.recipe,
            quantity = step.quantity,
            cost = step.totalCost,
            materials = materials,
            materialsSummary = table.concat(materialParts, ", "),
            -- Check if this step crosses a trainer milestone
            trainerMilestoneAfter = self:GetMilestoneBetween(step.skillStart, step.skillEnd, milestones),
        })
    end

    return breakdown
end

-- Helper: Get the highest milestone that this skill level has reached or passed
function Pathfinder:GetMilestoneAt(skill, milestones)
    local highestMilestone = nil
    for _, m in ipairs(milestones) do
        if skill >= m then
            highestMilestone = m
        end
    end
    return highestMilestone
end

-- Helper: Check if a milestone exists between two skill levels (exclusive start, inclusive end)
function Pathfinder:GetMilestoneBetween(fromSkill, toSkill, milestones)
    for _, m in ipairs(milestones) do
        if m > fromSkill and m <= toSkill then
            return m
        end
    end
    return nil
end

-- Get the current recommended recipe (first step)
function Pathfinder:GetCurrentRecommendation()
    if not self.currentPath or #self.currentPath.steps == 0 then
        return nil
    end
    return self.currentPath.steps[1]
end
