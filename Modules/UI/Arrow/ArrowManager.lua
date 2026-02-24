-- Modules/UI/Arrow/ArrowManager.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

LazyProf.ArrowManager = {}
local ArrowManager = LazyProf.ArrowManager

ArrowManager.strategies = {}
ArrowManager.activeStrategy = nil
ArrowManager.frame = nil
ArrowManager.cachedRecipeIndex = nil  -- Cached index for scroll performance
ArrowManager.cachedRecipeName = nil   -- Recipe name that was looked up

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

-- Lightweight refresh for scroll events - uses cached recipe index
function ArrowManager:RefreshPosition()
    if not self.cachedRecipeIndex then
        self:Hide()
        return
    end
    self:PositionAtRecipe(self.cachedRecipeIndex)
end

-- Invalidate cache when path changes (called when a new path is calculated)
function ArrowManager:InvalidateCache()
    self.cachedRecipeIndex = nil
    self.cachedRecipeName = nil
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

-- Get number of visible skill buttons (varies by game version/UI addons)
local function GetTradeSkillsDisplayed()
    -- Try to count actual visible buttons
    local count = 0
    for i = 1, 30 do  -- Check up to 30 buttons
        local button = _G["TradeSkillSkill" .. i]
        if button and button:IsShown() then
            count = i
        else
            break
        end
    end
    return count > 0 and count or 8  -- Fallback to 8 if detection fails
end

-- Skill difficulty colors (matching WoW's TradeSkill colors)
local SKILL_COLORS = {
    optimal = { r = 1.0, g = 0.5, b = 0.25 },  -- Orange
    medium  = { r = 1.0, g = 1.0, b = 0.0 },   -- Yellow
    easy    = { r = 0.25, g = 0.75, b = 0.25 }, -- Green
    trivial = { r = 0.5, g = 0.5, b = 0.5 },   -- Gray
    header  = { r = 1.0, g = 0.82, b = 0.0 },  -- Gold (headers)
}

-- Position arrow next to a recipe row
function ArrowManager:PositionAtRecipe(recipeIndex)
    if not TradeSkillFrame or not TradeSkillFrame:IsVisible() then
        return false
    end

    -- Get scroll offset to determine which button displays this recipe
    local scrollOffset = 0
    if TradeSkillListScrollFrame and FauxScrollFrame_GetOffset then
        scrollOffset = FauxScrollFrame_GetOffset(TradeSkillListScrollFrame)
    end

    -- Calculate visible button index (1-8 for Classic UI)
    local buttonIndex = recipeIndex - scrollOffset

    -- Check if recipe is currently visible in the scroll frame
    local maxVisible = GetTradeSkillsDisplayed()
    if buttonIndex < 1 or buttonIndex > maxVisible then
        self:Hide()
        return false
    end

    -- Find the skill button for this visible position
    local buttonName = "TradeSkillSkill" .. buttonIndex
    local button = _G[buttonName]

    if not button or not button:IsVisible() then
        self:Hide()
        return false
    end

    -- Get skill difficulty color from the recipe
    local skillName, skillType = GetTradeSkillInfo(recipeIndex)
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
    self.frame:SetParent(TradeSkillFrame)
    self.frame:SetFrameStrata("HIGH")
    self.frame:SetFrameLevel(button:GetFrameLevel() + 10)

    -- Position highlight to cover the entire recipe row with matching color
    if self.highlight then
        self.highlight.bg:SetColorTexture(color.r, color.g, color.b, 0.2)  -- Subtle tint
        self.highlight:ClearAllPoints()
        self.highlight:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
        self.highlight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
        self.highlight:SetParent(TradeSkillFrame)
        self.highlight:SetFrameStrata("MEDIUM")
        self.highlight:SetFrameLevel(button:GetFrameLevel() + 1)
    end

    self:Show()
    return true
end

-- Find recipe index in TradeSkill frame (with caching for scroll performance)
function ArrowManager:FindRecipeIndex(recipe)
    if not recipe then
        self.cachedRecipeIndex = nil
        self.cachedRecipeName = nil
        return nil
    end

    local targetName = recipe.name

    -- Use cache if same recipe
    if self.cachedRecipeName == targetName and self.cachedRecipeIndex then
        return self.cachedRecipeIndex
    end

    local numSkills = GetNumTradeSkills()

    for i = 1, numSkills do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType ~= "header" and skillName == targetName then
            -- Cache the result
            self.cachedRecipeIndex = i
            self.cachedRecipeName = targetName
            return i
        end
    end

    self.cachedRecipeIndex = nil
    self.cachedRecipeName = targetName  -- Still cache the name to avoid repeated searches
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
