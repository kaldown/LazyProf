-- Modules/Pathfinder/Pathfinder.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.Pathfinder = {}
local Pathfinder = LazyProf.Pathfinder

-- Current calculated path
Pathfinder.currentPath = nil

-- Pinned recipes: session-only overrides for pathfinder choices
-- Key: skill level (step's skillStart), Value: recipe ID
Pathfinder.pinnedRecipes = {}

-- Calculate optimal path for active profession
-- reason: optional string describing what triggered this calculation
function Pathfinder:Calculate(reason)
    -- Get active profession
    local profData = LazyProf.Professions:GetActive()
    if not profData then
        LazyProf:Debug("pathfinder", "No active profession detected")
        return nil
    end

    -- Get current skill level
    local skillName, currentSkill, maxSkill = GetTradeSkillLine()
    if not currentSkill then
        LazyProf:Debug("pathfinder", "Could not get current skill")
        return nil
    end

    -- Determine starting skill based on setting
    local startSkill = currentSkill
    if not LazyProf.db.profile.calculateFromCurrentSkill then
        -- Show full leveling path from skill 1
        startSkill = 1
    end

    -- Determine target skill (next milestone or max)
    local targetSkill = self:GetTargetSkill(startSkill, profData.milestones)

    LazyProf:Debug("pathfinder", string.format("Calculating path: %s %d -> %d (actual skill: %d)%s",
        skillName, startSkill, targetSkill, currentSkill,
        reason and (" [" .. reason .. "]") or ""))
    LazyProf:Debug("pathfinder", string.format("Settings: strategy=%s, fromCurrentSkill=%s, bank=%s, alts=%s",
        LazyProf.db.profile.strategy,
        tostring(LazyProf.db.profile.calculateFromCurrentSkill),
        tostring(LazyProf.db.profile.includeBankItems),
        tostring(LazyProf.db.profile.includeAltCharacters)))

    -- Log active pins if any
    local pinCount = 0
    for _ in pairs(self.pinnedRecipes) do pinCount = pinCount + 1 end
    if pinCount > 0 then
        local pinDetails = {}
        for skill, recipeId in pairs(self.pinnedRecipes) do
            table.insert(pinDetails, string.format("skill %d -> recipe %s", skill, tostring(recipeId)))
        end
        LazyProf:Debug("pathfinder", string.format("Active pins (%d): %s", pinCount, table.concat(pinDetails, ", ")))
    end

    -- Get recipes with learned status
    local recipes = LazyProf.Professions:GetRecipesWithLearnedStatus(LazyProf.Professions.active)

    -- Get inventory (bags + all enabled sources)
    local inventory, sourceBreakdown = LazyProf.Inventory:ScanAll()

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
        LazyProf:Debug("pathfinder", "Unknown strategy: " .. strategyName)
        return nil
    end

    -- Get racial profession bonus
    local racialBonus = Utils.GetRacialProfessionBonus(LazyProf.Professions.active)
    if racialBonus > 0 then
        LazyProf:Debug("pathfinder", string.format("Racial bonus detected: +%d for %s",
            racialBonus, LazyProf.Professions.active))
    end

    -- Calculate path with empty inventory so scoring uses market prices only
    -- (owned materials are handled separately by the shopping list)
    local steps = strategy:Calculate(startSkill, targetSkill, recipes, {}, prices, racialBonus, self.pinnedRecipes)

    -- Build result
    self.currentPath = {
        profession = profData.name,
        currentSkill = startSkill,
        targetSkill = targetSkill,
        racialBonus = racialBonus,
        steps = steps,
        totalCost = Utils.Sum(steps, "totalCost"),
        missingMaterials = self:CalculateMissingMaterials(steps, inventory, sourceBreakdown, prices),
        milestoneBreakdown = self:CalculateMilestoneBreakdown(steps, profData.milestones, startSkill, inventory, prices, racialBonus),
    }

    LazyProf:Debug("pathfinder", string.format("Path calculated: %d steps, %s total",
        #steps, Utils.FormatMoney(self.currentPath.totalCost)))

    return self.currentPath
end

-- Calculate path for a specific profession (for planning mode)
-- profKey: profession key like "alchemy", "engineering"
-- skillLevel: current skill (0 if not learned)
-- reason: optional string describing what triggered this calculation
function Pathfinder:CalculateForProfession(profKey, skillLevel, reason)
    local profData = LazyProf.Professions:Get(profKey)
    if not profData then
        LazyProf:Debug("pathfinder", "Profession not found: " .. tostring(profKey))
        return nil
    end

    -- In WoW, you start at skill 1 when learning a profession, not 0
    -- Use minimum of 1 for planning mode calculations
    skillLevel = math.max(1, skillLevel or 0)
    local targetSkill = self:GetTargetSkill(skillLevel, profData.milestones)

    LazyProf:Debug("pathfinder", string.format("Planning path: %s %d -> %d%s",
        profData.name, skillLevel, targetSkill,
        reason and (" [" .. reason .. "]") or ""))

    -- Get all recipes with cached learned status for planning mode
    local recipes = LazyProf.Utils.DeepCopy(profData.recipes)
    local cachedLearned = LazyProf.db.char.learnedRecipes and LazyProf.db.char.learnedRecipes[profKey] or {}
    for _, recipe in ipairs(recipes) do
        recipe.learned = cachedLearned[recipe.id] or false
    end

    -- Get inventory (bags + all enabled sources)
    local inventory, sourceBreakdown = LazyProf.Inventory:ScanAll()

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
        LazyProf:Debug("pathfinder", "Unknown strategy: " .. strategyName)
        return nil
    end

    -- Get racial profession bonus
    local racialBonus = Utils.GetRacialProfessionBonus(profKey)
    if racialBonus > 0 then
        LazyProf:Debug("pathfinder", string.format("Racial bonus detected: +%d for %s",
            racialBonus, profKey))
    end

    -- Calculate path with empty inventory so scoring uses market prices only
    -- (owned materials are handled separately by the shopping list)
    local steps = strategy:Calculate(skillLevel, targetSkill, recipes, {}, prices, racialBonus, self.pinnedRecipes)

    -- Build result (similar to Calculate() but stored separately)
    local path = {
        profession = profData.name,
        professionKey = profKey,
        currentSkill = skillLevel,
        targetSkill = targetSkill,
        racialBonus = racialBonus,
        steps = steps,
        totalCost = Utils.Sum(steps, "totalCost"),
        missingMaterials = self:CalculateMissingMaterials(steps, inventory, sourceBreakdown, prices),
        milestoneBreakdown = self:CalculateMilestoneBreakdown(steps, profData.milestones, skillLevel, inventory, prices, racialBonus),
    }

    LazyProf:Debug("pathfinder", string.format("Planning path calculated: %d steps, %s total",
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
-- Returns { fromBank, fromMail, fromAuctions, fromGuildBank, fromAlts, toCraft, fromAH, recipeCosts }
function Pathfinder:CalculateMissingMaterials(steps, inventory, sourceBreakdown, prices)
    local needed = {}

    -- Sum up all reagents needed (preserve name from CraftLib as fallback)
    for _, step in ipairs(steps) do
        for _, reagent in ipairs(step.recipe.reagents) do
            local itemId = reagent.itemId
            if not needed[itemId] then
                needed[itemId] = { count = 0, nameFromData = reagent.name, firstUsedAtSkill = step.skillStart }
            else
                needed[itemId].firstUsedAtSkill = math.min(needed[itemId].firstUsedAtSkill, step.skillStart)
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

                    if not resolvedNeeded[source.itemId] then
                        resolvedNeeded[source.itemId] = { count = 0, nameFromData = source.name, firstUsedAtSkill = data.firstUsedAtSkill }
                    else
                        resolvedNeeded[source.itemId].firstUsedAtSkill = math.min(resolvedNeeded[source.itemId].firstUsedAtSkill, data.firstUsedAtSkill)
                    end
                    resolvedNeeded[source.itemId].count = resolvedNeeded[source.itemId].count + source.totalNeeded

                    if source.fromInventory > 0 then
                        bankPurpose[source.itemId] = string.format("for %s", recipeName:lower())
                    end
                end

                -- Build source description for UI
                local totalSourceNeeded = sourceFromBank + sourceFromAH
                local sourceDesc = string.format("%dx %s", totalSourceNeeded, sourceMaterialName)
                local usingDesc = ""
                if sourceFromBank > 0 and sourceFromAH > 0 then
                    usingDesc = string.format("%dx from inventory + %dx from AH", sourceFromBank, sourceFromAH)
                elseif sourceFromBank > 0 then
                    usingDesc = string.format("%dx from inventory", sourceFromBank)
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
                    firstUsedAtSkill = data.firstUsedAtSkill,
                })
            else
                if not resolvedNeeded[itemId] then
                    resolvedNeeded[itemId] = { count = 0, nameFromData = data.nameFromData, firstUsedAtSkill = data.firstUsedAtSkill }
                else
                    resolvedNeeded[itemId].firstUsedAtSkill = math.min(resolvedNeeded[itemId].firstUsedAtSkill, data.firstUsedAtSkill)
                end
                resolvedNeeded[itemId].count = resolvedNeeded[itemId].count + need
            end
        elseif afterBags > 0 then
            if not resolvedNeeded[itemId] then
                resolvedNeeded[itemId] = { count = 0, nameFromData = data.nameFromData, firstUsedAtSkill = data.firstUsedAtSkill }
            else
                resolvedNeeded[itemId].firstUsedAtSkill = math.min(resolvedNeeded[itemId].firstUsedAtSkill, data.firstUsedAtSkill)
            end
            resolvedNeeded[itemId].count = resolvedNeeded[itemId].count + need
        end
    end

    -- Categorize resolved materials by source (waterfall: most accessible first)
    local fromBank = {}
    local fromMail = {}
    local fromAuctions = {}
    local fromGuildBank = {}
    local fromAlts = {}
    local fromAH = {}

    -- Helper: get per-source count from sourceBreakdown
    local function getSourceCount(itemId, sourceKey)
        local bd = sourceBreakdown and sourceBreakdown[itemId]
        if not bd then return 0 end
        return bd[sourceKey] or 0
    end

    -- Helper: get total alt count for an item across all sources
    local function getAltTotal(itemId)
        local bd = sourceBreakdown and sourceBreakdown[itemId]
        if not bd or not bd.alts then return 0 end
        local total = 0
        for _, charSources in pairs(bd.alts) do
            for _, count in pairs(charSources) do
                total = total + count
            end
        end
        return total
    end

    for itemId, data in pairs(resolvedNeeded) do
        local need = data.count
        local inBags = getSourceCount(itemId, "bags")
        local totalHave = inventory[itemId] or 0

        -- How many do we still need after bags?
        local remaining = math.max(0, need - inBags)

        if remaining > 0 then
            local name, link, icon = Utils.GetItemInfo(itemId)
            local price = prices[itemId] or 0
            name = name or data.nameFromData or "Unknown"
            icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"

            -- Waterfall: bank -> mail -> auctions -> guildBank -> alts -> AH

            -- 1. Bank
            local inBank = getSourceCount(itemId, "bank")
            local fromBankCount = math.min(remaining, inBank)
            remaining = remaining - fromBankCount

            -- 2. Mail
            local inMail = getSourceCount(itemId, "mail")
            local fromMailCount = math.min(remaining, inMail)
            remaining = remaining - fromMailCount

            -- 3. Auctions (active AH listings)
            local inAuctions = getSourceCount(itemId, "auctions")
            local fromAuctionsCount = math.min(remaining, inAuctions)
            remaining = remaining - fromAuctionsCount

            -- 4. Guild bank
            local inGuildBank = getSourceCount(itemId, "guildBank")
            local fromGuildBankCount = math.min(remaining, inGuildBank)
            remaining = remaining - fromGuildBankCount

            -- 5. Alts (with per-character breakdown)
            local fromAltCount = 0
            local altCharacters = {}
            local bd = sourceBreakdown and sourceBreakdown[itemId]
            if remaining > 0 and bd and bd.alts then
                local altRemaining = remaining
                for charName, charSources in pairs(bd.alts) do
                    local charTotal = 0
                    for _, count in pairs(charSources) do
                        charTotal = charTotal + count
                    end
                    local useFromChar = math.min(altRemaining, charTotal)
                    if useFromChar > 0 then
                        fromAltCount = fromAltCount + useFromChar
                        altRemaining = altRemaining - useFromChar
                        table.insert(altCharacters, { name = charName, count = useFromChar })
                    end
                    if altRemaining <= 0 then break end
                end
                remaining = remaining - fromAltCount
            end

            -- 6. AH (remainder)
            local fromAHCount = remaining

            -- Build result entries for each source
            if fromBankCount > 0 then
                local purpose = bankPurpose[itemId]
                table.insert(fromBank, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    have = inBank,
                    need = fromBankCount,
                    missing = fromBankCount,
                    estimatedCost = 0,
                    purpose = purpose,
                    firstUsedAtSkill = data.firstUsedAtSkill,
                })
            end

            if fromMailCount > 0 then
                table.insert(fromMail, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    have = inMail,
                    missing = fromMailCount,
                    firstUsedAtSkill = data.firstUsedAtSkill,
                })
            end

            if fromAuctionsCount > 0 then
                table.insert(fromAuctions, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    have = inAuctions,
                    missing = fromAuctionsCount,
                    firstUsedAtSkill = data.firstUsedAtSkill,
                })
            end

            if fromGuildBankCount > 0 then
                table.insert(fromGuildBank, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    have = inGuildBank,
                    missing = fromGuildBankCount,
                    firstUsedAtSkill = data.firstUsedAtSkill,
                })
            end

            if fromAltCount > 0 then
                table.insert(fromAlts, {
                    itemId = itemId,
                    name = name,
                    icon = icon,
                    link = link,
                    missing = fromAltCount,
                    have = getAltTotal(itemId),
                    characters = altCharacters,
                    firstUsedAtSkill = data.firstUsedAtSkill,
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
                    firstUsedAtSkill = data.firstUsedAtSkill,
                })
            end
        end
    end

    -- Sort by skill level when materials are first consumed, then by name
    local function sortBySkillThenName(a, b)
        if a.firstUsedAtSkill ~= b.firstUsedAtSkill then
            return a.firstUsedAtSkill < b.firstUsedAtSkill
        end
        return (a.name or "") < (b.name or "")
    end
    table.sort(fromBank, sortBySkillThenName)
    table.sort(fromMail, sortBySkillThenName)
    table.sort(fromAuctions, sortBySkillThenName)
    table.sort(fromGuildBank, sortBySkillThenName)
    table.sort(fromAlts, sortBySkillThenName)
    table.sort(fromAH, sortBySkillThenName)
    table.sort(toCraft, sortBySkillThenName)

    -- Calculate recipe acquisition costs (one-time costs for unlearned recipes)
    local seenRecipes = {}
    local recipeCosts = 0
    for _, step in ipairs(steps) do
        if not step.recipe.learned and step.recipe._sourceInfo and not seenRecipes[step.recipe.id] then
            seenRecipes[step.recipe.id] = true
            local srcType = step.recipe._sourceInfo.type
            if srcType == "trainer" or srcType == "vendor" then
                recipeCosts = recipeCosts + (step.recipe._sourceInfo.cost or 0)
            elseif srcType == "ah" then
                recipeCosts = recipeCosts + (step.recipe._sourceInfo.price or 0)
            end
        end
    end

    return {
        fromBank = fromBank,
        fromMail = fromMail,
        fromAuctions = fromAuctions,
        fromGuildBank = fromGuildBank,
        fromAlts = fromAlts,
        toCraft = toCraft,
        fromAH = fromAH,
        recipeCosts = recipeCosts,
    }
end

-- Break down path by individual steps (step-by-step format)
function Pathfinder:CalculateMilestoneBreakdown(steps, milestones, currentSkill, inventory, prices, racialBonus)
    racialBonus = racialBonus or 0
    local breakdown = {}

    -- Simulate inventory consumption: each step uses materials, reducing what's available for later steps
    local remainingInventory = {}
    for k, v in pairs(inventory) do remainingInventory[k] = v end

    for _, step in ipairs(steps) do
        -- Calculate materials for this step only
        local materials = {}
        for _, reagent in ipairs(step.recipe.reagents) do
            local need = reagent.count * step.quantity
            local have = remainingInventory[reagent.itemId] or 0
            local used = math.min(need, have)
            local missing = need - used
            local name, link, icon = Utils.GetItemInfo(reagent.itemId)
            local price = prices[reagent.itemId] or 0

            -- Consume from remaining inventory so later steps don't double-count
            remainingInventory[reagent.itemId] = have - used

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

        -- Calculate recipe color at step's starting skill (with racial bonus)
        local effectiveSkill = step.skillStart - racialBonus
        local color = Utils.GetSkillColor(effectiveSkill, step.recipe.skillRange)

        table.insert(breakdown, {
            from = step.skillStart,
            to = step.skillEnd,
            recipe = step.recipe,
            quantity = step.quantity,
            cost = step.totalCost,
            materials = materials,
            materialsSummary = table.concat(materialParts, ", "),
            color = color,  -- Pre-calculated color for UI display
            alternatives = step.alternatives,  -- All scored candidates at this skill level
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

-- Pin a recipe at a specific skill level (overrides optimizer's pick on next recalculate)
function Pathfinder:PinRecipe(skillLevel, recipeId)
    self.pinnedRecipes[skillLevel] = recipeId
    LazyProf:Debug("pathfinder", string.format("Pinned recipe %s at skill %d", tostring(recipeId), skillLevel))
end

-- Remove a pin at a specific skill level
function Pathfinder:UnpinRecipe(skillLevel)
    self.pinnedRecipes[skillLevel] = nil
    LazyProf:Debug("pathfinder", string.format("Unpinned recipe at skill %d", skillLevel))
end

-- Clear all pins
function Pathfinder:ClearPins()
    self.pinnedRecipes = {}
    LazyProf:Debug("pathfinder", "Cleared all pinned recipes")
end

-- Check if any pins exist that differ from the current path's winners
function Pathfinder:HasDirtyPins()
    if not self.currentPath then return false end
    for _, step in ipairs(self.currentPath.steps) do
        local pinned = self.pinnedRecipes[step.skillStart]
        if pinned and pinned ~= step.recipe.id then
            return true
        end
    end
    return false
end

-- Get count of pins that differ from current path winners
function Pathfinder:GetDirtyPinCount()
    if not self.currentPath then return 0 end
    local count = 0
    for _, step in ipairs(self.currentPath.steps) do
        local pinned = self.pinnedRecipes[step.skillStart]
        if pinned and pinned ~= step.recipe.id then
            count = count + 1
        end
    end
    return count
end
