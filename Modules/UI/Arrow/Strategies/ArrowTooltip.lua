-- Modules/UI/Arrow/Strategies/ArrowTooltip.lua
-- How the arrow beside the recommended recipe behaves: where it points, and
-- what its tooltip says. The tooltip's content is built as data by
-- Views.ArrowTooltip (Modules/Guide/Views.lua): the current step, the next
-- two, what the path costs (spent, back from selling, net) and where the
-- prices came from.
local ADDON_NAME, LazyProf = ...

LazyProf.ArrowStrategies = LazyProf.ArrowStrategies or {}

LazyProf.ArrowStrategies.arrowWithTooltip = {
    name = "Arrow with Tooltip",

    Update = function(self, manager, path)
        if not path or #path.steps == 0 then
            manager:Hide()
            return
        end

        local recommendation = LazyProf.Pathfinder:GetArrowStep(path)
        if not recommendation or not recommendation.recipe then
            manager:Hide()
            return
        end

        -- Hides itself when the recipe has no visible row (not learned or
        -- scrolled out of view).
        manager:PositionAtRecipe(recommendation.recipe)
    end,

    OnEnter = function(self, manager)
        if not manager.currentPath then return end
        local view = LazyProf.GuideWindow and LazyProf.GuideWindow:LiveView()
        if not view then return end

        GameTooltip:SetOwner(manager.frame, "ANCHOR_RIGHT")
        for _, line in ipairs(LazyProf.GuideViews.ArrowTooltip(view)) do
            if line.right then
                GameTooltip:AddDoubleLine(line.text, line.right, line.r, line.g, line.b, line.rr, line.rg, line.rb)
            else
                GameTooltip:AddLine(line.text, line.r, line.g, line.b, line.wrap)
            end
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
