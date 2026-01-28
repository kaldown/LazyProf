-- Modules/UI/Arrow/Strategies/ArrowTooltip.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

-- Format source info for tooltip display
local function AddSourceTooltipLines(tooltip, recipe)
    if recipe.learned then
        return  -- No additional info needed for learned recipes
    end

    local sourceInfo = recipe._sourceInfo
    if not sourceInfo then
        tooltip:AddLine("Source unknown", 1, 0.5, 0)
        return
    end

    tooltip:AddLine(" ")

    if sourceInfo.type == "inventory" then
        local loc = sourceInfo.location
        if loc.type == "bags" then
            tooltip:AddLine("Recipe is in your bags", 0, 1, 0)
        elseif loc.type == "bank" then
            tooltip:AddLine("Recipe is in your bank", 0, 1, 0.5)
        elseif loc.type == "alt" then
            tooltip:AddLine("Recipe is on alt: " .. loc.character, 0.5, 1, 1)
        end
    elseif sourceInfo.type == "trainer" then
        local trainerText = sourceInfo.npcName or "Any Trainer"
        tooltip:AddLine("Learn from: " .. trainerText, 1, 1, 1)
        if sourceInfo.cost and sourceInfo.cost > 0 then
            tooltip:AddLine("Cost: " .. Utils.FormatMoney(sourceInfo.cost), 1, 0.82, 0)
        end
    elseif sourceInfo.type == "vendor" then
        if sourceInfo.vendors and #sourceInfo.vendors > 0 then
            local v = sourceInfo.vendors[1]
            tooltip:AddLine("Buy from: " .. (v.npcName or "Vendor"), 1, 1, 1)
            if v.location then
                tooltip:AddLine("Location: " .. v.location, 0.7, 0.7, 0.7)
            end
        else
            tooltip:AddLine("Available from vendor", 1, 1, 1)
        end
        if sourceInfo.cost and sourceInfo.cost > 0 then
            tooltip:AddLine("Cost: " .. Utils.FormatMoney(sourceInfo.cost), 1, 0.82, 0)
        end
    elseif sourceInfo.type == "ah" then
        tooltip:AddLine("Available on Auction House", 0.5, 1, 0.5)
        tooltip:AddLine("Price: " .. Utils.FormatMoney(sourceInfo.price) .. " (" .. sourceInfo.source .. ")", 1, 0.82, 0)
    end

    -- Add Wowhead link for recipe item
    if sourceInfo.itemId then
        tooltip:AddLine(" ")
        tooltip:AddLine("Wowhead: wowhead.com/item=" .. sourceInfo.itemId, 0.4, 0.6, 1)
    end
end

LazyProf.ArrowStrategies = LazyProf.ArrowStrategies or {}

LazyProf.ArrowStrategies.arrowWithTooltip = {
    name = "Arrow with Tooltip",

    Update = function(self, manager, path)
        if not path or #path.steps == 0 then
            manager:Hide()
            return
        end

        local recommendation = path.steps[1]
        if not recommendation or not recommendation.recipe then
            manager:Hide()
            return
        end

        -- Find recipe in TradeSkill frame
        local recipeIndex = manager:FindRecipeIndex(recommendation.recipe)
        if recipeIndex then
            manager:PositionAtRecipe(recipeIndex)
        else
            -- Recipe not in TradeSkill list (not learned)
            manager:Hide()
        end
    end,

    OnEnter = function(self, manager)
        local path = manager.currentPath
        if not path then return end

        GameTooltip:SetOwner(manager.frame, "ANCHOR_RIGHT")
        GameTooltip:AddLine("LazyProf - Optimal Path", 1, 0.82, 0)
        GameTooltip:AddLine(" ")

        -- Show each step
        for i, step in ipairs(path.steps) do
            local learnedColor = step.recipe.learned and "|cFFFFFFFF" or "|cFF888888"
            local learnTag = step.recipe.learned and "" or " [Learn]"

            GameTooltip:AddDoubleLine(
                string.format("%d. %s%s x%d%s|r",
                    i, learnedColor, step.recipe.name, step.quantity, learnTag),
                Utils.FormatMoney(step.totalCost),
                1, 1, 1,
                1, 0.82, 0
            )

            GameTooltip:AddLine(
                string.format("   Skill %d -> %d",
                    math.floor(step.skillStart), math.floor(step.skillEnd)),
                0.5, 0.5, 0.5
            )

            -- Add source details for unlearned recipes (first step only to avoid clutter)
            if i == 1 and not step.recipe.learned then
                AddSourceTooltipLines(GameTooltip, step.recipe)
            end
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(
            "Total Cost:",
            Utils.FormatMoney(path.totalCost),
            1, 1, 1,
            1, 0.82, 0
        )

        if LazyProf.PriceManager:ArePricesStale() then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Prices may be stale. Open AH to scan.", 1, 0.5, 0)
        end

        GameTooltip:Show()
    end,

    OnLeave = function(self, manager)
        GameTooltip:Hide()
    end,
}

-- Simple arrow (no tooltip) strategy
LazyProf.ArrowStrategies.simpleArrow = {
    name = "Simple Arrow",

    Update = function(self, manager, path)
        -- Same positioning logic as arrowWithTooltip
        LazyProf.ArrowStrategies.arrowWithTooltip.Update(self, manager, path)
    end,

    OnEnter = function(self, manager)
        -- No tooltip for simple arrow
    end,

    OnLeave = function(self, manager)
        -- Nothing to hide
    end,
}
