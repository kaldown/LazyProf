-- Modules/UI/Arrow/Strategies/ArrowTooltip.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

LazyProf.ArrowStrategies = LazyProf.ArrowStrategies or {}

LazyProf.ArrowStrategies.arrowWithTooltip = {
    name = "Arrow with Tooltip",

    Update = function(self, manager, path)
        if not path or #path.steps == 0 then
            manager:Hide()
            return
        end

        local recommendation = path.steps[1]
        if not recommendation then
            manager:Hide()
            return
        end

        -- Find recipe in TradeSkill frame
        local recipeIndex = manager:FindRecipeIndex(recommendation.recipe)
        if recipeIndex then
            manager:PositionAtRecipe(recipeIndex)
        else
            -- Recipe not visible (not learned or scrolled away)
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
