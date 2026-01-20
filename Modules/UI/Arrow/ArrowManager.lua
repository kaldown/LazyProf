-- Modules/UI/Arrow/ArrowManager.lua
local ADDON_NAME, LazyProf = ...

LazyProf.ArrowManager = {}
local ArrowManager = LazyProf.ArrowManager

ArrowManager.strategies = {}
ArrowManager.activeStrategy = nil
ArrowManager.frame = nil

-- Initialize arrow manager
function ArrowManager:Initialize()
    -- Create main arrow frame
    self.frame = CreateFrame("Frame", "LazyProfArrow", UIParent)
    self.frame:SetSize(24, 24)
    self.frame:Hide()

    -- Arrow texture (pointing right)
    self.frame.texture = self.frame:CreateTexture(nil, "OVERLAY")
    self.frame.texture:SetAllPoints()
    self.frame.texture:SetTexture("Interface\\MINIMAP\\ROTATING-MINIMAPGUIDEARROW")

    -- Enable mouse for tooltip
    self.frame:EnableMouse(true)
    self.frame:SetScript("OnEnter", function() self:OnEnter() end)
    self.frame:SetScript("OnLeave", function() self:OnLeave() end)

    -- Load strategies
    self:LoadStrategies()
end

-- Load display strategies
function ArrowManager:LoadStrategies()
    self.strategies = LazyProf.ArrowStrategies or {}
end

-- Set active strategy based on config
function ArrowManager:SetStrategy(strategyName)
    local strategy = self.strategies[strategyName]
    if strategy then
        self.activeStrategy = strategy
        LazyProf:Debug("Arrow strategy set: " .. strategyName)
    else
        LazyProf:Debug("Unknown arrow strategy: " .. strategyName)
    end
end

-- Update arrow position and visibility
function ArrowManager:Update(path)
    if not self.activeStrategy then
        self:SetStrategy(LazyProf.db.profile.displayMode)
    end

    if not self.activeStrategy then
        self:Hide()
        return
    end

    self.currentPath = path
    self.activeStrategy:Update(self, path)
end

-- Show arrow
function ArrowManager:Show()
    self.frame:Show()
end

-- Hide arrow
function ArrowManager:Hide()
    self.frame:Hide()
end

-- Position arrow next to a recipe row
function ArrowManager:PositionAtRecipe(recipeIndex)
    if not TradeSkillFrame then return false end

    -- Find the skill button for this recipe
    local buttonName = "TradeSkillSkill" .. recipeIndex
    local button = _G[buttonName]

    if not button or not button:IsVisible() then
        -- Recipe might be scrolled out of view
        self:Hide()
        return false
    end

    self.frame:ClearAllPoints()
    self.frame:SetPoint("RIGHT", button, "LEFT", -5, 0)
    self.frame:SetParent(TradeSkillFrame)
    self.frame:SetFrameStrata("HIGH")
    self:Show()

    return true
end

-- Find recipe index in TradeSkill frame
function ArrowManager:FindRecipeIndex(recipe)
    local numSkills = GetNumTradeSkills()

    for i = 1, numSkills do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType ~= "header" and skillName == recipe.name then
            return i
        end
    end

    return nil
end

-- Tooltip handlers
function ArrowManager:OnEnter()
    if self.activeStrategy and self.activeStrategy.OnEnter then
        self.activeStrategy:OnEnter(self)
    end
end

function ArrowManager:OnLeave()
    if self.activeStrategy and self.activeStrategy.OnLeave then
        self.activeStrategy:OnLeave(self)
    end
end
