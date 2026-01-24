-- Modules/UI/MilestoneBreakdown.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

LazyProf.MilestonePanel = {}
local MilestonePanel = LazyProf.MilestonePanel

MilestonePanel.frame = nil
MilestonePanel.rows = {}
MilestonePanel.expandedRows = {}

local ROW_HEIGHT = 22
local INGREDIENT_ROW_HEIGHT = 20
local UNLEARNED_ROW_HEIGHT = 18
local MIN_WIDTH = 300
local MIN_HEIGHT = 100
local DEFAULT_WIDTH = 320

-- Initialize the milestone panel
function MilestonePanel:Initialize()
    -- Create main frame
    self.frame = CreateFrame("Frame", "LazyProfMilestonePanel", UIParent, "BackdropTemplate")
    self.frame:SetSize(DEFAULT_WIDTH, 200)
    self.frame:SetPoint("TOPLEFT", TradeSkillFrame or UIParent, "TOPRIGHT", 10, 0)
    self.frame:SetFrameStrata("MEDIUM")
    self.frame:SetFrameLevel(10)

    -- Solid dark background
    self.frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    self.frame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    self.frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    self.frame:EnableMouse(true)
    self.frame:SetMovable(true)
    self.frame:SetResizable(true)
    self.frame:SetClampedToScreen(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    self.frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)

    -- Set resize bounds
    if self.frame.SetResizeBounds then
        self.frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, 600, 800)
    else
        self.frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
        self.frame:SetMaxResize(600, 800)
    end

    self.frame:Hide()

    -- Title bar background
    self.frame.titleBg = self.frame:CreateTexture(nil, "ARTWORK")
    self.frame.titleBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.titleBg:SetVertexColor(0.2, 0.2, 0.2, 1)
    self.frame.titleBg:SetPoint("TOPLEFT", 4, -4)
    self.frame.titleBg:SetPoint("TOPRIGHT", -4, -4)
    self.frame.titleBg:SetHeight(24)

    -- Title
    self.frame.title = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.frame.title:SetPoint("TOP", 0, -10)
    self.frame.title:SetText("Milestone Breakdown")
    self.frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    self.frame.closeBtn = CreateFrame("Button", nil, self.frame, "UIPanelCloseButton")
    self.frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    self.frame.closeBtn:SetSize(20, 20)

    -- Create scroll frame for content
    self.frame.scrollFrame = CreateFrame("ScrollFrame", "LazyProfMilestoneScrollFrame", self.frame, "UIPanelScrollFrameTemplate")
    self.frame.scrollFrame:SetPoint("TOPLEFT", 8, -32)
    self.frame.scrollFrame:SetPoint("BOTTOMRIGHT", -28, 32)

    -- Content frame inside scroll
    self.frame.content = CreateFrame("Frame", nil, self.frame.scrollFrame)
    self.frame.content:SetSize(DEFAULT_WIDTH - 40, 400)
    self.frame.scrollFrame:SetScrollChild(self.frame.content)

    -- Total cost bar at bottom
    self.frame.totalBg = self.frame:CreateTexture(nil, "ARTWORK")
    self.frame.totalBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.totalBg:SetVertexColor(0.15, 0.15, 0.15, 1)
    self.frame.totalBg:SetPoint("BOTTOMLEFT", 4, 4)
    self.frame.totalBg:SetPoint("BOTTOMRIGHT", -4, 4)
    self.frame.totalBg:SetHeight(24)

    self.frame.total = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.frame.total:SetPoint("BOTTOM", 0, 12)
    self.frame.total:SetTextColor(1, 1, 1)

    -- Resize handle
    self.frame.resizeBtn = CreateFrame("Button", nil, self.frame)
    self.frame.resizeBtn:SetSize(16, 16)
    self.frame.resizeBtn:SetPoint("BOTTOMRIGHT", -2, 2)
    self.frame.resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    self.frame.resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    self.frame.resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

    self.frame.resizeBtn:SetScript("OnMouseDown", function(btn, button)
        if button == "LeftButton" then
            self.frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    self.frame.resizeBtn:SetScript("OnMouseUp", function(btn, button)
        self.frame:StopMovingOrSizing()
        self:RefreshLayout()
    end)

    -- Handle resize events
    self.frame:SetScript("OnSizeChanged", function(f, width, height)
        if self.frame.content then
            self.frame.content:SetWidth(width - 40)
        end
    end)
end

-- Refresh layout after resize
function MilestonePanel:RefreshLayout()
    if LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath then
        self:Update(LazyProf.Pathfinder.currentPath.milestoneBreakdown,
                    LazyProf.Pathfinder.currentPath.totalCost)
    end
end

-- Update the panel with milestone breakdown data
function MilestonePanel:Update(breakdown, totalCost)
    if not LazyProf.db.profile.showMilestonePanel then
        self:Hide()
        return
    end

    -- Clear existing rows
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    self.rows = {}

    if not breakdown or #breakdown == 0 then
        self:Hide()
        return
    end

    local contentWidth = self.frame:GetWidth() - 40
    local yOffset = 0

    for i, bracket in ipairs(breakdown) do
        local row = self:CreateMilestoneRow(bracket, i, yOffset, contentWidth)
        table.insert(self.rows, row)
        yOffset = yOffset + ROW_HEIGHT

        -- If expanded, show unlearned indicators and ingredients
        if self.expandedRows[i] then
            -- Show unlearned recipe indicators first
            for _, step in ipairs(bracket.steps) do
                if not step.recipe.learned then
                    local unlearnedRow = self:CreateUnlearnedRecipeRow(step, yOffset, contentWidth)
                    table.insert(self.rows, unlearnedRow)
                    yOffset = yOffset + UNLEARNED_ROW_HEIGHT
                end
            end

            -- Then show ingredients
            for _, mat in ipairs(bracket.materials) do
                local ingredientRow = self:CreateIngredientRow(mat, yOffset, contentWidth)
                table.insert(self.rows, ingredientRow)
                yOffset = yOffset + INGREDIENT_ROW_HEIGHT
            end
        end
    end

    -- Update total
    self.frame.total:SetText("Total: " .. Utils.FormatMoney(totalCost))

    -- Update content height for scrolling
    self.frame.content:SetHeight(math.max(yOffset + 10, self.frame:GetHeight() - 70))

    -- Position next to TradeSkill frame (only if not manually moved)
    if TradeSkillFrame and TradeSkillFrame:IsVisible() and not self.manuallyMoved then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPLEFT", TradeSkillFrame, "TOPRIGHT", 10, 0)
    end

    self:Show()
end

-- Create a milestone row
function MilestonePanel:CreateMilestoneRow(bracket, index, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    -- Row background for hover
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.2, 0.2, 0.2, 0)

    -- Expand/collapse button
    row.expandBtn = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.expandBtn:SetPoint("LEFT", 4, 0)
    row.expandBtn:SetText(self.expandedRows[index] and "[-]" or "[+]")
    row.expandBtn:SetTextColor(0.7, 0.7, 0.7)

    -- Range label
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("LEFT", 28, 0)
    row.label:SetText(string.format("%d-%d:", bracket.from, bracket.to))
    row.label:SetTextColor(1, 0.82, 0)

    -- Summary
    row.summary = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.summary:SetPoint("LEFT", 85, 0)
    row.summary:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.summary:SetJustifyH("LEFT")
    row.summary:SetWordWrap(false)
    row.summary:SetText(bracket.summary)

    -- Cost
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.cost:SetPoint("RIGHT", -8, 0)
    row.cost:SetText(Utils.FormatMoney(bracket.cost))
    row.cost:SetTextColor(1, 1, 1)

    -- Click to expand/collapse
    row:SetScript("OnClick", function()
        self.expandedRows[index] = not self.expandedRows[index]
        self:Update(LazyProf.Pathfinder.currentPath.milestoneBreakdown,
                    LazyProf.Pathfinder.currentPath.totalCost)
    end)

    -- Highlight on hover
    row:SetScript("OnEnter", function()
        row:SetBackdropColor(0.3, 0.3, 0.3, 0.5)
        row.expandBtn:SetTextColor(1, 1, 0)
    end)
    row:SetScript("OnLeave", function()
        row:SetBackdropColor(0.2, 0.2, 0.2, 0)
        row.expandBtn:SetTextColor(0.7, 0.7, 0.7)
    end)

    row:Show()
    return row
end

-- Create an unlearned recipe indicator row
function MilestonePanel:CreateUnlearnedRecipeRow(step, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth - 20, UNLEARNED_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 20, -yOffset)

    -- Row background for hover
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0, 0, 0, 0)

    -- Warning indicator
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.text:SetJustifyH("LEFT")

    local sourceDesc = Utils.GetSourceDescription(step.recipe.source)
    local recipeName = step.recipe.name or "Unknown"
    row.text:SetText(string.format("|cFFFF8800[!]|r %s: |cFFFF8800%s|r", recipeName, sourceDesc))

    -- Store recipe reference for click handler
    row.recipe = step.recipe

    -- Click to show recipe details panel
    row:SetScript("OnClick", function(self)
        if LazyProf.RecipeDetails then
            LazyProf.RecipeDetails:Toggle(self.recipe)
        end
    end)

    -- Hover effects
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.3, 0.3, 0.1, 0.5)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Click for details", 1, 1, 1)
        GameTooltip:AddLine("View vendors, Wowhead link", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        GameTooltip:Hide()
    end)

    row:Show()
    return row
end

-- Create an ingredient row
function MilestonePanel:CreateIngredientRow(mat, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth - 20, INGREDIENT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 20, -yOffset)

    -- Row background for hover
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture(mat.icon)

    -- Name and count (show how many still needed)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", 24, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.text:SetJustifyH("LEFT")
    local countText = mat.missing > 0 and
        string.format("|cFFFF6666%dx|r", mat.missing) or
        "|cFF66FF66Ready|r"
    row.text:SetText(countText .. " " .. (mat.name or "Unknown"))

    -- Cost
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.cost:SetPoint("RIGHT", -8, 0)
    if mat.estimatedCost > 0 then
        row.cost:SetText(Utils.FormatMoney(mat.estimatedCost))
    else
        row.cost:SetText("|cFF666666N/A|r")
    end

    -- Shift-click to link
    row:SetScript("OnClick", function()
        if IsShiftKeyDown() and mat.link then
            HandleModifiedItemClick(mat.link)
        end
    end)

    -- Tooltip and hover
    row:SetScript("OnEnter", function()
        row:SetBackdropColor(0.25, 0.25, 0.25, 0.8)
        if mat.itemId then
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(mat.itemId)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)
        GameTooltip:Hide()
    end)

    row:Show()
    return row
end

-- Show the panel
function MilestonePanel:Show()
    self.frame:Show()
end

-- Hide the panel
function MilestonePanel:Hide()
    self.frame:Hide()
end
