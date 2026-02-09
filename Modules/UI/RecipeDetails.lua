-- Modules/UI/RecipeDetails.lua
-- Side panel showing detailed recipe information including source/vendor details
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

LazyProf.RecipeDetails = {}
local RecipeDetails = LazyProf.RecipeDetails

RecipeDetails.frame = nil
RecipeDetails.currentRecipe = nil
RecipeDetails.showAllFactions = false

local PANEL_WIDTH = 280
local PANEL_HEIGHT = 410
local ROW_HEIGHT = 18
local SECTION_SPACING = 12
local THRESHOLD_ROW_HEIGHT = 13

-- Initialize the recipe details panel
function RecipeDetails:Initialize()
    self.frame = CreateFrame("Frame", "LazyProfRecipeDetails", UIParent, "BackdropTemplate")
    self.frame:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    self.frame:SetPoint("TOPLEFT", UIParent, "CENTER", 100, 100)
    self.frame:SetFrameStrata("HIGH")
    self.frame:SetFrameLevel(20)

    -- Register for item info received event to update icon when data is loaded
    self.frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    self.frame:SetScript("OnEvent", function(_, event, itemId)
        if event == "GET_ITEM_INFO_RECEIVED" and self.currentRecipe and self.currentRecipe.itemId == itemId then
            local _, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemId)
            if itemIcon then
                self.frame.content.icon:SetTexture(itemIcon)
            end
        end
    end)

    -- Solid dark background
    self.frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    self.frame:SetBackdropColor(0.08, 0.08, 0.08, 0.98)
    self.frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    self.frame:EnableMouse(true)
    self.frame:SetMovable(true)
    self.frame:SetClampedToScreen(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    self.frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)

    self.frame:Hide()

    -- Title bar background
    self.frame.titleBg = self.frame:CreateTexture(nil, "ARTWORK")
    self.frame.titleBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.titleBg:SetVertexColor(0.15, 0.15, 0.15, 1)
    self.frame.titleBg:SetPoint("TOPLEFT", 4, -4)
    self.frame.titleBg:SetPoint("TOPRIGHT", -4, -4)
    self.frame.titleBg:SetHeight(24)

    -- Title
    self.frame.title = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.frame.title:SetPoint("TOP", 0, -10)
    self.frame.title:SetText("Recipe Details")
    self.frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    self.frame.closeBtn = CreateFrame("Button", nil, self.frame, "UIPanelCloseButton")
    self.frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    self.frame.closeBtn:SetSize(20, 20)
    self.frame.closeBtn:SetScript("OnClick", function() self:Hide() end)

    -- Content area
    self.frame.content = CreateFrame("Frame", nil, self.frame)
    self.frame.content:SetPoint("TOPLEFT", 12, -34)
    self.frame.content:SetPoint("BOTTOMRIGHT", -12, 12)

    -- Create UI elements
    self:CreateRecipeHeader()
    self:CreateReagentsSection()
    self:CreateSourceSection()
    self:CreateWowheadSection()
end

-- Create recipe header (icon, name, skill info)
function RecipeDetails:CreateRecipeHeader()
    local content = self.frame.content

    -- Recipe icon
    content.icon = content:CreateTexture(nil, "ARTWORK")
    content.icon:SetSize(32, 32)
    content.icon:SetPoint("TOPLEFT", 0, 0)

    -- Recipe name
    content.name = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    content.name:SetPoint("TOPLEFT", 40, -2)
    content.name:SetPoint("RIGHT", -8, 0)
    content.name:SetJustifyH("LEFT")
    content.name:SetTextColor(1, 1, 1)

    -- Skill requirement
    content.skill = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    content.skill:SetPoint("TOPLEFT", 40, -18)
    content.skill:SetJustifyH("LEFT")
    content.skill:SetTextColor(0.8, 0.8, 0.8)

    -- Difficulty bar background
    content.diffBg = content:CreateTexture(nil, "BACKGROUND")
    content.diffBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    content.diffBg:SetVertexColor(0.2, 0.2, 0.2, 1)
    content.diffBg:SetSize(100, 8)
    content.diffBg:SetPoint("TOPLEFT", 0, -40)

    -- Difficulty bar fill
    content.diffBar = content:CreateTexture(nil, "ARTWORK")
    content.diffBar:SetTexture("Interface\\Buttons\\WHITE8x8")
    content.diffBar:SetSize(100, 8)
    content.diffBar:SetPoint("TOPLEFT", content.diffBg, "TOPLEFT", 0, 0)

    -- Difficulty label
    content.diffLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    content.diffLabel:SetPoint("LEFT", content.diffBg, "RIGHT", 8, 0)
    content.diffLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Difficulty threshold rows (orange, yellow, green, gray)
    content.thresholdRows = {}
    for i = 1, 4 do
        local row = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row:SetPoint("TOPLEFT", 4, -50 - (i - 1) * THRESHOLD_ROW_HEIGHT)
        row:SetJustifyH("LEFT")
        content.thresholdRows[i] = row
    end
end

-- Create reagents section
function RecipeDetails:CreateReagentsSection()
    local content = self.frame.content

    -- Reagents header (shifted down to accommodate threshold rows)
    content.reagentsHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    content.reagentsHeader:SetPoint("TOPLEFT", 0, -110)
    content.reagentsHeader:SetText("Reagents:")
    content.reagentsHeader:SetTextColor(1, 0.82, 0)

    -- Reagent rows container
    content.reagentRows = {}
    for i = 1, 8 do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(PANEL_WIDTH - 24, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, -110 - SECTION_SPACING - (i - 1) * ROW_HEIGHT)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 0, 0)
        row.text:SetJustifyH("LEFT")

        row:Hide()
        content.reagentRows[i] = row
    end
end

-- Create source section
function RecipeDetails:CreateSourceSection()
    local content = self.frame.content

    -- Source header (shifted down to accommodate threshold rows)
    content.sourceHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    content.sourceHeader:SetPoint("TOPLEFT", 0, -232)
    content.sourceHeader:SetText("Learn from:")
    content.sourceHeader:SetTextColor(1, 0.82, 0)

    -- Show all factions checkbox
    content.factionToggle = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    content.factionToggle:SetSize(20, 20)
    content.factionToggle:SetPoint("TOPRIGHT", -4, -230)
    content.factionToggle:SetChecked(self.showAllFactions)
    content.factionToggle:SetScript("OnClick", function(btn)
        self.showAllFactions = btn:GetChecked()
        if self.currentRecipe then
            self:UpdateSourceSection(self.currentRecipe)
        end
    end)

    content.factionToggleLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    content.factionToggleLabel:SetPoint("RIGHT", content.factionToggle, "LEFT", -2, 0)
    content.factionToggleLabel:SetText("All factions")
    content.factionToggleLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Vendor/source rows container
    content.sourceRows = {}
    for i = 1, 6 do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(PANEL_WIDTH - 24, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, -232 - SECTION_SPACING - (i - 1) * ROW_HEIGHT)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 0, 0)
        row.text:SetPoint("RIGHT", -8, 0)
        row.text:SetJustifyH("LEFT")

        row:Hide()
        content.sourceRows[i] = row
    end
end

-- Create Wowhead link section
function RecipeDetails:CreateWowheadSection()
    local content = self.frame.content

    -- Wowhead header
    content.wowheadHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    content.wowheadHeader:SetPoint("BOTTOMLEFT", 0, 36)
    content.wowheadHeader:SetText("Wowhead Link:")
    content.wowheadHeader:SetTextColor(0.7, 0.7, 0.7)

    -- URL editbox (for copying)
    content.urlBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    content.urlBox:SetSize(PANEL_WIDTH - 80, 20)
    content.urlBox:SetPoint("BOTTOMLEFT", 0, 12)
    content.urlBox:SetAutoFocus(false)
    content.urlBox:SetFontObject("GameFontHighlightSmall")
    content.urlBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    content.urlBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    -- Copy button
    content.copyBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    content.copyBtn:SetSize(50, 22)
    content.copyBtn:SetPoint("LEFT", content.urlBox, "RIGHT", 4, 0)
    content.copyBtn:SetText("Copy")
    content.copyBtn:SetScript("OnClick", function()
        content.urlBox:SetFocus()
        content.urlBox:HighlightText()
    end)
end

-- Show recipe details
-- atSkillLevel: optional skill level for difficulty display (e.g., step's starting skill from milestone)
function RecipeDetails:Show(recipe, atSkillLevel)
    if not recipe then return end
    if not self.frame then self:Initialize() end

    self.currentRecipe = recipe
    local content = self.frame.content

    -- Update header icon from crafted item
    local icon = nil
    if recipe.itemId then
        local _, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(recipe.itemId)
        icon = itemIcon
    end
    content.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    content.name:SetText(recipe.name or "Unknown Recipe")
    content.skill:SetText("Requires: " .. (recipe.skillRequired or "?"))

    -- Update difficulty bar
    self:UpdateDifficultyBar(recipe, atSkillLevel)

    -- Update reagents
    self:UpdateReagentsSection(recipe)

    -- Update source
    self:UpdateSourceSection(recipe)

    -- Update Wowhead link
    if recipe.id then
        content.urlBox:SetText(Utils.GetWowheadUrl(recipe.id))
    else
        content.urlBox:SetText("")
    end

    -- Position near MilestonePanel if visible
    if LazyProf.MilestonePanel and LazyProf.MilestonePanel.frame and LazyProf.MilestonePanel.frame:IsVisible() then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPLEFT", LazyProf.MilestonePanel.frame, "TOPRIGHT", 10, 0)
    end

    self.frame:Show()
end

-- Color name to display properties (bar color, width, capitalized label)
local DIFFICULTY_DISPLAY = {
    orange = { color = {1, 0.5, 0, 1}, width = 100, label = "Orange" },
    yellow = { color = {1, 1, 0, 1}, width = 75, label = "Yellow" },
    green  = { color = {0, 1, 0, 1}, width = 50, label = "Green" },
    gray   = { color = {0.5, 0.5, 0.5, 1}, width = 25, label = "Gray" },
}

-- Ordered threshold keys matching thresholdRows[1..4]
local THRESHOLD_ORDER = {
    { key = "orange", label = "Orange" },
    { key = "yellow", label = "Yellow" },
    { key = "green",  label = "Green" },
    { key = "gray",   label = "Gray" },
}

-- Update difficulty bar and threshold rows based on skill level
-- atSkillLevel: optional explicit skill level (already includes racial bonus);
--               when nil, uses current profession skill from TradeSkill API
function RecipeDetails:UpdateDifficultyBar(recipe, atSkillLevel)
    local content = self.frame.content
    local range = recipe.skillRange
    local skillRequired = recipe.skillRequired

    -- Hide thresholds if no range data
    if not range then
        content.diffBar:SetVertexColor(0.5, 0.5, 0.5, 1)
        content.diffBar:SetWidth(50)
        content.diffLabel:SetText("Unknown")
        for _, row in ipairs(content.thresholdRows) do
            row:SetText("")
        end
        return
    end

    -- Determine skill to evaluate against
    local currentSkill = atSkillLevel
    if not currentSkill then
        local _, apiSkill = GetTradeSkillLine()
        currentSkill = apiSkill
    end
    if not currentSkill then
        content.diffBar:SetVertexColor(0.5, 0.5, 0.5, 1)
        content.diffBar:SetWidth(50)
        content.diffLabel:SetText("Unknown")
        for _, row in ipairs(content.thresholdRows) do
            row:SetText("")
        end
        return
    end

    -- Check if player can't learn this recipe yet
    if skillRequired and currentSkill < skillRequired then
        content.diffBg:Hide()
        content.diffBar:Hide()
        content.diffLabel:SetText("")
        for _, row in ipairs(content.thresholdRows) do
            row:SetText("")
        end
        return
    end

    -- Show bars and restore label position (in case they were hidden)
    content.diffBg:Show()
    content.diffBar:Show()
    content.diffLabel:ClearAllPoints()
    content.diffLabel:SetPoint("LEFT", content.diffBg, "RIGHT", 8, 0)

    -- Subtract racial bonus for color calculation (same as pathfinder)
    local racialBonus = Utils.GetRacialProfessionBonus(LazyProf.Professions and LazyProf.Professions.active)
    local effectiveSkill = currentSkill - racialBonus
    local colorName = Utils.GetSkillColor(effectiveSkill, range)
    local display = DIFFICULTY_DISPLAY[colorName] or DIFFICULTY_DISPLAY.gray

    content.diffBar:SetVertexColor(unpack(display.color))
    content.diffBar:SetWidth(display.width)
    content.diffLabel:SetText(display.label)

    -- Populate threshold rows with colored difficulty levels
    for i, t in ipairs(THRESHOLD_ORDER) do
        local threshold = range[t.key]
        local rowDisplay = DIFFICULTY_DISPLAY[t.key]
        local isActive = (t.key == colorName)

        -- Format: "Orange: 240" or "Orange: 240 [255]" with racial
        local text = string.format("%s: %d", t.label, threshold)
        if racialBonus > 0 then
            text = text .. string.format(" [%d]", threshold + racialBonus)
        end
        if isActive then
            text = "> " .. text
        else
            text = "  " .. text
        end

        content.thresholdRows[i]:SetText(text)
        local r, g, b = rowDisplay.color[1], rowDisplay.color[2], rowDisplay.color[3]
        if isActive then
            content.thresholdRows[i]:SetTextColor(r, g, b)
        else
            content.thresholdRows[i]:SetTextColor(r * 0.5, g * 0.5, b * 0.5)
        end
    end
end

-- Update reagents section
function RecipeDetails:UpdateReagentsSection(recipe)
    local content = self.frame.content

    -- Hide all rows first
    for _, row in ipairs(content.reagentRows) do
        row:Hide()
    end

    if not recipe.reagents then return end

    for i, reagent in ipairs(recipe.reagents) do
        if i > #content.reagentRows then break end
        local row = content.reagentRows[i]
        row.text:SetText(string.format("%dx %s", reagent.count or 1, reagent.name or "Unknown"))
        row:Show()
    end
end

-- Update source section
function RecipeDetails:UpdateSourceSection(recipe)
    local content = self.frame.content

    -- Hide all rows first
    for _, row in ipairs(content.sourceRows) do
        row:Hide()
    end

    if not recipe.source then
        content.sourceRows[1].text:SetText("|cFF888888Unknown source|r")
        content.sourceRows[1]:Show()
        content.factionToggle:Hide()
        content.factionToggleLabel:Hide()
        return
    end

    local source = recipe.source
    local rowIndex = 1

    if source.type == "vendor" and source.vendors then
        -- Show faction toggle for vendors
        content.factionToggle:Show()
        content.factionToggleLabel:Show()

        local vendors = Utils.GetVendorsForFaction(source, Utils.GetPlayerFaction(), self.showAllFactions)

        if #vendors == 0 then
            content.sourceRows[1].text:SetText("|cFFFF6666No vendors for your faction|r")
            content.sourceRows[1]:Show()
        else
            for _, vendor in ipairs(vendors) do
                if rowIndex > #content.sourceRows then break end
                local row = content.sourceRows[rowIndex]

                local factionColor = ""
                if vendor.faction == "Alliance" then
                    factionColor = "|cFF0080FF"
                elseif vendor.faction == "Horde" then
                    factionColor = "|cFFFF0000"
                else
                    factionColor = "|cFFFFFF00" -- Neutral
                end

                row.text:SetText(string.format("%s%s|r (%s)", factionColor, vendor.npcName, vendor.location or "Unknown"))
                row:Show()
                rowIndex = rowIndex + 1
            end
        end

    elseif source.type == "trainer" then
        content.factionToggle:Hide()
        content.factionToggleLabel:Hide()

        local text = source.npcName or "Any Trainer"
        if source.note then
            text = text .. "\n|cFF888888" .. source.note .. "|r"
        end
        content.sourceRows[1].text:SetText(text)
        content.sourceRows[1]:Show()

    elseif source.type == "quest" then
        content.factionToggle:Hide()
        content.factionToggleLabel:Hide()

        local text = "Quest: " .. (source.questName or "Unknown")
        if source.location then
            text = text .. "\n|cFF888888" .. source.location .. "|r"
        end
        if source.faction then
            text = text .. " |cFFFFAA00(" .. source.faction .. " only)|r"
        end
        content.sourceRows[1].text:SetText(text)
        content.sourceRows[1]:Show()

    else
        content.factionToggle:Hide()
        content.factionToggleLabel:Hide()
        content.sourceRows[1].text:SetText(Utils.GetSourceDescription(source))
        content.sourceRows[1]:Show()
    end
end

-- Hide the panel
function RecipeDetails:Hide()
    if self.frame then
        self.frame:Hide()
    end
    self.currentRecipe = nil
end

-- Toggle visibility
function RecipeDetails:Toggle(recipe, atSkillLevel)
    if self.frame and self.frame:IsVisible() and self.currentRecipe == recipe then
        self:Hide()
    else
        self:Show(recipe, atSkillLevel)
    end
end
