-- Modules/Pathfinder/Pathfinder.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.Pathfinder = {}
local Pathfinder = LazyProf.Pathfinder

-- Current calculated path
Pathfinder.currentPath = nil

-- Prices of every reagent of the recipes, and of what those reagents are
-- made from (for the craft-or-buy comparison of the shopping list).
local function CollectPrices(recipes)
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

    return LazyProf.PriceManager:GetPrices(reagentIds)
end

-- Run the strategy and build the path object.
-- run: { profKey, profData, recipes, startSkill, actualSkill, reason, planning,
--        hasProfession, planFromOne }
-- The path runs from startSkill to the profession's target (GetTargetSkill).
-- When the start is already at or past the target there is nothing to plan:
-- no steps, no gaps, path.nothingLeft = true.
function Pathfinder:BuildPath(run)
    local profKey, profData = run.profKey, run.profData
    local startSkill, actualSkill = run.startSkill, run.actualSkill
    local milestones = profData.milestones
    local targetSkill = self:GetTargetSkill(profKey, milestones)

    LazyProf:Debug("pathfinder", string.format("Calculating path: %s %d -> %d (actual skill: %d)%s%s",
        profData.name, startSkill, targetSkill, actualSkill,
        run.planning and " (planning)" or "",
        run.reason and (" [" .. run.reason .. "]") or ""))
    LazyProf:Debug("pathfinder", string.format("Settings: strategy=%s, bank=%s, alts=%s, greenRecipes=%s",
        LazyProf.db.profile.strategy,
        tostring(LazyProf.db.profile.includeBankItems),
        tostring(LazyProf.db.profile.includeAltCharacters),
        tostring(LazyProf.db.profile.includeGreenRecipes)))

    -- Pins the real skill has passed are done with; the rest override the
    -- optimizer over their skill range.
    local pins = self:GetPins(profKey)
    if run.hasProfession ~= false then
        LazyProf.Pins.Prune(pins, actualSkill)
    end
    if #pins > 0 and LazyProf:IsDebugEnabled("pathfinder") then
        local pinDetails = {}
        for _, pin in ipairs(pins) do
            table.insert(pinDetails, string.format("%.2f-%.2f -> recipe %s", pin.from, pin.to, tostring(pin.recipeId)))
        end
        LazyProf:Debug("pathfinder", string.format("Active pins (%d): %s", #pins, table.concat(pinDetails, ", ")))
    end

    -- Get inventory (bags + all enabled sources)
    local inventory, sourceBreakdown = LazyProf.Inventory:ScanAll()

    -- Log owned materials summary (guarded: GetItemInfo + string building per
    -- owned item runs every recalc and is wasted when debug logging is off)
    if LazyProf:IsDebugEnabled("pathfinder") then
        local ownedCount = 0
        local ownedParts = {}
        for itemId, qty in pairs(inventory) do
            if qty > 0 then
                ownedCount = ownedCount + 1
                if ownedCount <= 15 then
                    local name = Utils.GetItemInfo(itemId)
                    table.insert(ownedParts, string.format("%dx %s", qty, name or itemId))
                end
            end
        end
        if ownedCount > 0 then
            local suffix = ownedCount > 15 and string.format(" ... and %d more", ownedCount - 15) or ""
            LazyProf:Debug("pathfinder", string.format("Owned materials (%d items): %s%s", ownedCount, table.concat(ownedParts, ", "), suffix))
        else
            LazyProf:Debug("pathfinder", "Owned materials: none")
        end
    end

    local prices = CollectPrices(run.recipes)

    -- Get strategy
    local strategyName = LazyProf.db.profile.strategy
    local strategy = LazyProf.PathfinderStrategies[strategyName]
    if not strategy then
        LazyProf:Debug("pathfinder", "Unknown strategy: " .. tostring(strategyName))
        return nil
    end

    -- Get racial profession bonus
    local racialBonus = Utils.GetRacialProfessionBonus(profKey)
    if racialBonus > 0 then
        LazyProf:Debug("pathfinder", string.format("Racial bonus detected: +%d for %s", racialBonus, tostring(profKey)))
    end

    -- Calculate path with empty inventory so scoring uses market prices only
    -- (owned materials are handled separately by the shopping list)
    -- Memoize recipe availability for the duration of this synchronous scoring
    -- pass (IsRecipeAvailable is called per unlearned candidate per step).
    LazyProf.RecipeAvailability:BeginRecalc()
    LazyProf.SelfFound:BeginRecalc(inventory)
    local steps, meta = strategy:Calculate(startSkill, targetSkill, run.recipes, {}, prices, racialBonus, pins)
    LazyProf.SelfFound:EndRecalc()
    LazyProf.RecipeAvailability:EndRecalc()

    -- Build result (totals cover the steps the path has; gaps add nothing)
    local path = {
        profession = profData.name,
        professionKey = profKey,
        planning = run.planning or nil,
        hasProfession = run.hasProfession,
        planFromOne = run.planFromOne or nil,
        currentSkill = startSkill,
        actualSkill = actualSkill,
        targetSkill = targetSkill,
        capSkill = milestones[#milestones],
        milestones = milestones,
        racialBonus = racialBonus,
        steps = steps,
        complete = meta.complete,
        gaps = meta.gaps,
        nothingLeft = (#steps == 0 and #meta.gaps == 0) or nil,
        totalCost = Utils.Sum(steps, "totalCost"),
        -- What the stage builder and the shopping list are computed from
        prices = prices,
        inventory = inventory,
        sourceBreakdown = sourceBreakdown,
    }

    if LazyProf:IsDebugEnabled("pathfinder") then
        LazyProf:Debug("pathfinder", string.format("Path calculated: %d steps, %d gaps, %s total",
            #steps, #meta.gaps, Utils.FormatMoney(path.totalCost)))
    end

    return path
end

-- Calculate the path for the open profession, from the character's real skill.
-- reason: optional string describing what triggered this calculation
function Pathfinder:Calculate(reason)
    -- Get active profession
    local profData = LazyProf.Professions:GetActive()
    if not profData then
        LazyProf:Debug("pathfinder", "No active profession detected")
        return nil
    end

    -- Get current skill level
    local _, currentSkill = LazyProf.Client:GetLine()
    if not currentSkill then
        LazyProf:Debug("pathfinder", "Could not get current skill")
        return nil
    end

    local profKey = LazyProf.Professions.active
    self.currentPath = self:BuildPath({
        profKey = profKey,
        profData = profData,
        -- Recipes with learned status from the open window
        recipes = LazyProf.Professions:GetRecipesWithLearnedStatus(profKey),
        startSkill = currentSkill,
        actualSkill = currentSkill,
        hasProfession = true,
        reason = reason,
    })
    return self.currentPath
end

-- Calculate the path for any profession, without its window (planning).
-- A profession the character has is planned from the real skill; one not
-- learned yet from 1. opts.planFromOne plans a learned profession from 1 as a
-- what-if (the path bar then shows what is already done).
-- opts: { planFromOne = bool, reason = string }
function Pathfinder:CalculateForProfession(profKey, opts)
    opts = opts or {}
    local profData = LazyProf.Professions:Get(profKey)
    if not profData then
        LazyProf:Debug("pathfinder", "Profession not found: " .. tostring(profKey))
        return nil
    end

    -- A learned profession starts at 1, not 0
    local realSkill = LazyProf.Client:PlayerSkill(profKey) or 0
    local hasProfession = realSkill > 0
    local actualSkill = math.max(1, realSkill)
    local planFromOne = hasProfession and opts.planFromOne and true or false
    local startSkill = (hasProfession and not planFromOne) and actualSkill or 1

    -- Learned status from the cache the profession window fills
    local recipes = LazyProf.Utils.DeepCopy(profData.recipes)
    local cachedLearned = LazyProf.db.char.learnedRecipes and LazyProf.db.char.learnedRecipes[profKey] or {}
    for _, recipe in ipairs(recipes) do
        recipe.learned = cachedLearned[recipe.id] or false
    end

    return self:BuildPath({
        profKey = profKey,
        profData = profData,
        recipes = recipes,
        startSkill = startSkill,
        actualSkill = actualSkill,
        hasProfession = hasProfession,
        planFromOne = planFromOne,
        planning = true,
        reason = opts.reason,
    })
end

-- The skill a profession's path runs to: the target the player set for it,
-- never above the last cap; the last cap when none is set.
function Pathfinder:GetTargetSkill(profKey, milestones)
    local cap = milestones[#milestones]
    local stored = profKey and LazyProf.CharStore:Profession(profKey).target
    if stored and stored < cap then
        return stored
    end
    return cap
end

-- Set a profession's target from what the player typed. The value is clamped
-- to [real skill + 1, last cap]; returns the value in force so the input box
-- can show the correction. A target equal to the cap is stored as "none", so
-- it follows the cap.
function Pathfinder:SetTargetSkill(profKey, value, actualSkill, milestones)
    local cap = milestones[#milestones]
    value = math.floor(tonumber(value) or cap)
    local low = math.min((actualSkill or 0) + 1, cap)
    value = math.max(low, math.min(cap, value))
    LazyProf.CharStore:Profession(profKey).target = (value < cap) and value or nil
    return value
end

-- Calculate the shopping list of a set of steps (path steps, or the craft
-- stages' { recipe, quantity, skillStart } entries).
-- Returns the per-source lists { fromBank, fromMail, fromAuctions,
-- fromGuildBank, fromAlts, toCraft, fromAH, recipeCosts } and, for the
-- Shopping tab, one row per item in `rows`:
--   itemId, name, icon, link, firstUsedAtSkill
--   need        how many the steps use (as a reagent, and to craft other rows)
--   have        how many the character owns across the enabled sources
--   inBags      of those, in the bags
--   sources     what to collect first: { bank, mail, auctions, guildBank, alts } counts
--   toBuy       what is left to buy
--   unitPrice   nil when the item has no price (unpriced = true); cost = unitPrice x toBuy
--   priceSource the price's source ("Vendor", "TSM", ...); isVendor = sold by a vendor
--   craftable   a recipe the character can craft makes it
--   choice      the player's choice for the item ("craft" / "buy"), nil = automatic
--   crafted     the item is crafted, not bought: craftRecipeName, professionKey,
--               craftQuantity, craftCost and children = { { itemId, name, need }, ... }
-- and buyTotal, the sum of the rows' costs.
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

    -- Automatic craft-or-buy follows the setting, under the Cheapest strategy
    -- only; an explicit per-item choice applies under both strategies.
    local resolutionMode = Constants.MATERIAL_RESOLUTION.NONE
    if LazyProf.db.profile.strategy == Constants.STRATEGY.CHEAPEST then
        resolutionMode = LazyProf.db.profile.materialResolution
    end
    local choices = LazyProf.CharStore and LazyProf.CharStore:Get().craftChoices or {}

    -- Track intermediate crafts and resolved materials
    local toCraft = {}
    local resolvedNeeded = {} -- Final materials after resolution
    local bankPurpose = {}    -- Track why bank items are needed (for annotations)
    local rowsById = {}       -- one shopping row per item

    local function addResolved(itemId, count, nameFromData, firstUsedAtSkill)
        local entry = resolvedNeeded[itemId]
        if not entry then
            entry = { count = 0, nameFromData = nameFromData, firstUsedAtSkill = firstUsedAtSkill }
            resolvedNeeded[itemId] = entry
        else
            entry.firstUsedAtSkill = math.min(entry.firstUsedAtSkill, firstUsedAtSkill)
        end
        entry.count = entry.count + count
    end

    local bagCounts = LazyProf.Inventory:ScanBags()

    -- Process each needed material through MaterialResolver
    for itemId, data in pairs(needed) do
        local need = data.count
        local inBags = bagCounts[itemId] or 0
        local afterBags = math.max(0, need - inBags)
        local choice = choices[itemId]
        local resolution = nil
        if LazyProf.MaterialResolver then
            -- Asked for at least one so "can the character craft it" is known
            -- even when the bags already hold enough.
            resolution = LazyProf.MaterialResolver:ResolveMaterial(
                itemId, math.max(afterBags, 1), inventory, prices, {}, resolutionMode, choice
            )
        end
        local craftable = resolution and resolution.craftable or false

        if afterBags > 0 and resolution and resolution.shouldCraft and resolution.craftRecipe then
            -- Add to toCraft list
            local name, link, icon = Utils.GetItemInfo(itemId)
            name = name or data.nameFromData or "Unknown"
            icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"
            local recipeName = resolution.craftRecipe.name or "Unknown Recipe"

            -- Calculate source material breakdown
            local sourceFromBank = 0
            local sourceFromAH = 0
            local sourceMaterialName = ""
            local children = {}

            for _, source in ipairs(resolution.sourceItems) do
                sourceFromBank = sourceFromBank + source.fromInventory
                sourceFromAH = sourceFromAH + source.toBuy
                sourceMaterialName = source.name or "Unknown"

                addResolved(source.itemId, source.totalNeeded, source.name, data.firstUsedAtSkill)
                children[#children + 1] = { itemId = source.itemId, name = source.name or "Unknown", need = source.totalNeeded }

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

            rowsById[itemId] = {
                itemId = itemId, name = name, icon = icon, link = link,
                firstUsedAtSkill = data.firstUsedAtSkill,
                need = need, have = inventory[itemId] or 0, inBags = inBags, sources = {},
                toBuy = 0, cost = 0, unitPrice = prices[itemId],
                craftable = true, choice = choice, crafted = true,
                craftRecipeName = recipeName, professionKey = resolution.professionKey,
                craftQuantity = afterBags, craftCost = resolution.craftCost, children = children,
            }
        else
            -- Bought (or already owned): its full need goes on, so an item
            -- that is also the source of a crafted one is counted once, whole.
            addResolved(itemId, need, data.nameFromData, data.firstUsedAtSkill)
            rowsById[itemId] = { itemId = itemId, craftable = craftable, choice = choice, crafted = false }
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

    local pm = LazyProf.PriceManager

    for itemId, data in pairs(resolvedNeeded) do
        local need = data.count
        local inBags = getSourceCount(itemId, "bags")
        local totalHave = inventory[itemId] or 0

        -- How many do we still need after bags?
        local remaining = math.max(0, need - inBags)

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

        -- The item's shopping row
        local row = rowsById[itemId] or { itemId = itemId, craftable = false, crafted = false }
        rowsById[itemId] = row
        if not row.crafted then
            local info = pm and pm.PeekPriceInfo and pm:PeekPriceInfo(itemId) or nil
            row.name, row.icon, row.link = name, icon, link
            row.firstUsedAtSkill = data.firstUsedAtSkill
            row.need = need
            row.have = totalHave
            row.inBags = inBags
            row.sources = {
                bank = fromBankCount, mail = fromMailCount, auctions = fromAuctionsCount,
                guildBank = fromGuildBankCount, alts = fromAltCount,
            }
            row.toBuy = fromAHCount
            row.unitPrice = prices[itemId]
            row.unpriced = (prices[itemId] == nil) or nil
            row.cost = price * fromAHCount
            row.priceSource = info and info.source or nil
            row.isVendor = (info ~= nil and info.source == "Vendor")
        end

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

    local rows = {}
    local buyTotal = 0
    for _, row in pairs(rowsById) do
        rows[#rows + 1] = row
        buyTotal = buyTotal + (row.cost or 0)
    end
    table.sort(rows, sortBySkillThenName)

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
        rows = rows,
        buyTotal = buyTotal,
    }
end

-- The step the arrow points at: the first step the player's real skill has not
-- finished. Inside a gap, or past the last step, there is no step to point at
-- (returns nil). A path without a real skill (actualSkill nil) points at its
-- first step.
function Pathfinder:GetArrowStep(path)
    if not path or not path.steps or #path.steps == 0 then
        return nil
    end
    local actual = path.actualSkill
    if not actual then
        return path.steps[1]
    end
    for _, gap in ipairs(path.gaps or {}) do
        if actual >= gap.from and actual < gap.to then
            return nil
        end
    end
    for _, step in ipairs(path.steps) do
        if step.skillEnd and step.skillEnd > actual then
            return step
        end
    end
    return nil  -- past the last step: nothing left to point at
end

-- Pins (see Modules/Pathfinder/Pins.lua): saved per character and profession.

-- The profession's pin list (the saved table itself).
function Pathfinder:GetPins(profKey)
    if not profKey then return {} end
    return LazyProf.CharStore:Profession(profKey).pins
end

-- Recipe id pinned at a skill, nil when none.
function Pathfinder:PinnedAt(profKey, skill)
    return LazyProf.Pins.Find(self:GetPins(profKey), skill)
end

-- Pin a recipe over a skill range; it replaces any pin it overlaps. The
-- caller recalculates.
function Pathfinder:PinRange(profKey, from, to, recipeId)
    LazyProf.Pins.Add(self:GetPins(profKey), from, to, recipeId)
    LazyProf:Debug("pathfinder", string.format("Pinned recipe %s for %s %.2f-%.2f",
        tostring(recipeId), tostring(profKey), from, to))
end

-- Remove the pin covering a skill.
function Pathfinder:UnpinAt(profKey, skill)
    if LazyProf.Pins.RemoveAt(self:GetPins(profKey), skill) then
        LazyProf:Debug("pathfinder", string.format("Unpinned %s at %.2f", tostring(profKey), skill))
    end
end

-- Remove every pin of a profession.
function Pathfinder:ClearPins(profKey)
    local pins = self:GetPins(profKey)
    for i = #pins, 1, -1 do
        pins[i] = nil
    end
end
