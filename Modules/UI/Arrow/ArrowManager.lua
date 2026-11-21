-- Modules/UI/Arrow/ArrowManager.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

LazyProf.ArrowManager = {}
local ArrowManager = LazyProf.ArrowManager

ArrowManager.strategies = {}
ArrowManager.activeStrategy = nil
ArrowManager.frame = nil
ArrowManager.cachedRecipe = nil  -- Recipe the arrow last pointed at (scroll refresh)

-- Initialize arrow manager
function ArrowManager:Initialize()
    -- Create highlight frame (shows behind the recipe row)
    self.highlight = CreateFrame("Frame", "LazyProfHighlight", UIParent)
    self.highlight:SetHeight(16)
    self.highlight:Hide()

    -- Highlight background texture (color set dynamically based on skill difficulty)
    self.highlight.bg = self.highlight:CreateTexture(nil, "BACKGROUND")
    self.highlight.bg:SetAllPoints()
    self.highlight.bg:SetColorTexture(1.0, 1.0, 0.0, 0.2)  -- Default yellow, updated per recipe

    -- Create main arrow frame
    self.frame = CreateFrame("Frame", "LazyProfArrow", UIParent)
    self.frame:SetSize(16, 16)
    self.frame:Hide()

    -- Arrow text indicator ">" - more visible than small texture
    self.frame.text = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.frame.text:SetPoint("CENTER", 0, 0)
    self.frame.text:SetText(">")
    self.frame.text:SetTextColor(1.0, 1.0, 0.0)  -- Default yellow, updated per recipe

    -- Also keep a texture arrow for visual appeal
    self.frame.texture = self.frame:CreateTexture(nil, "OVERLAY")
    self.frame.texture:SetSize(12, 12)
    self.frame.texture:SetPoint("RIGHT", self.frame.text, "LEFT", -2, 0)
    self.frame.texture:SetTexture("Interface\\BUTTONS\\UI-SpellbookIcon-NextPage-Up")
    self.frame.texture:SetVertexColor(1.0, 1.0, 0.0)  -- Default yellow, updated per recipe

    -- Enable mouse for tooltip
    self.frame:EnableMouse(true)
    self.frame:SetScript("OnEnter", function() self:OnEnter() end)
    self.frame:SetScript("OnLeave", function() self:OnLeave() end)

    -- Combat lockdown: auto-hide during combat, restore after
    Utils.AddCombatLockdown(self.frame)
    Utils.AddCombatLockdown(self.highlight)

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
        LazyProf:Debug("arrow", "Arrow strategy set: " .. strategyName)
    else
        LazyProf:Debug("arrow", "Unknown arrow strategy: " .. strategyName)
    end
end

-- Update arrow position and visibility
function ArrowManager:Update(path)
    if not self.activeStrategy then
        self:SetStrategy(LazyProf.db.profile.displayMode)
    end

    if not self.activeStrategy or not path or not path.steps or #path.steps == 0 then
        self:Hide()
        return
    end

    self.currentPath = path
    self.activeStrategy:Update(self, path)
end

-- Lightweight refresh for scroll events - uses the cached recipe
function ArrowManager:RefreshPosition()
    if not self.cachedRecipe then
        self:Hide()
        return
    end
    self:PositionAtRecipe(self.cachedRecipe)
end

-- Invalidate cache when path changes (called when a new path is calculated)
function ArrowManager:InvalidateCache()
    self.cachedRecipe = nil
end

-- Show arrow and highlight
function ArrowManager:Show()
    if InCombatLockdown() then return end
    self.frame:Show()
    if self.highlight then
        self.highlight:Show()
    end
end

-- Hide arrow and highlight
function ArrowManager:Hide()
    if InCombatLockdown() then return end
    self.frame:Hide()
    if self.highlight then
        self.highlight:Hide()
    end
end

-- Skill difficulty colors (matching WoW's TradeSkill colors)
local SKILL_COLORS = {
    optimal = { r = 1.0, g = 0.5, b = 0.25 },  -- Orange
    medium  = { r = 1.0, g = 1.0, b = 0.0 },   -- Yellow
    easy    = { r = 0.25, g = 0.75, b = 0.25 }, -- Green
    trivial = { r = 0.5, g = 0.5, b = 0.5 },   -- Gray
    header  = { r = 1.0, g = 0.82, b = 0.0 },  -- Gold (headers)
}

-- Position arrow next to a recipe row (the recipe, not an index)
function ArrowManager:PositionAtRecipe(recipe)
    self.cachedRecipe = recipe
    local button, skillType = LazyProf.Client:FindRecipeRow(recipe)
    if not button then
        self:Hide()
        return false
    end

    local anchor = LazyProf.Client:AnchorFrame()

    -- Get skill difficulty color from the recipe
    local skillName = recipe.name
    local color = SKILL_COLORS[skillType] or SKILL_COLORS.medium  -- Default to yellow

    -- Log when arrow becomes visible
    if not self.frame:IsShown() then
        LazyProf:Debug("arrow", string.format("Showing arrow at '%s'", skillName or "?"))
    end

    -- Set arrow color to match skill difficulty
    if self.frame.text then
        self.frame.text:SetTextColor(color.r, color.g, color.b)
    end
    if self.frame.texture then
        self.frame.texture:SetVertexColor(color.r, color.g, color.b)
    end

    -- Position arrow at the left side of the button (before recipe name)
    self.frame:ClearAllPoints()
    self.frame:SetPoint("LEFT", button, "LEFT", 2, 0)
    self.frame:SetParent(anchor)
    self.frame:SetFrameStrata("HIGH")
    self.frame:SetFrameLevel(button:GetFrameLevel() + 10)

    -- Position highlight to cover the entire recipe row with matching color
    if self.highlight then
        self.highlight.bg:SetColorTexture(color.r, color.g, color.b, 0.2)  -- Subtle tint
        self.highlight:ClearAllPoints()
        self.highlight:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
        self.highlight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
        self.highlight:SetParent(anchor)
        self.highlight:SetFrameStrata("MEDIUM")
        self.highlight:SetFrameLevel(button:GetFrameLevel() + 1)
    end

    self:Show()
    return true
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
