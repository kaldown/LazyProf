-- Modules/UI/MilestoneBreakdown.lua
-- Reusable milestone breakdown panel - can be standalone or embedded
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

-- Class definition
local MilestonePanelClass = {}
MilestonePanelClass.__index = MilestonePanelClass

-- Export class for creating instances
LazyProf.MilestonePanelClass = MilestonePanelClass

local STEP_ROW_HEIGHT = 20
local INGREDIENT_ROW_HEIGHT = 18
local MILESTONE_SEPARATOR_HEIGHT = 16
local MIN_WIDTH = 350
local MIN_HEIGHT = 100
local DEFAULT_WIDTH = 400

-- Constructor
-- config.name: unique name for frame (e.g., "Main", "Planning")
-- config.embedded: if true, no chrome (title bar, close btn, resize handle)
-- config.parent: parent frame (required if embedded)
function MilestonePanelClass:New(config)
    local instance = setmetatable({}, MilestonePanelClass)
    instance.config = config or {}
    instance.rows = {}
    instance.expandedRows = {}
    instance.currentPath = nil
    instance.frame = nil
    return instance
end

-- Initialize the milestone panel UI
function MilestonePanelClass:Initialize()
    local config = self.config
    local frameName = "LazyProfMilestonePanel" .. (config.name or "")
    local parent = config.embedded and config.parent or UIParent

    -- Create main frame
    self.frame = CreateFrame("Frame", frameName, parent, "BackdropTemplate")

    if config.embedded then
        -- Embedded mode: fill parent, no chrome
        -- Don't set strata - inherit from parent so we're not drawn behind it
        self.frame:SetAllPoints(parent)
    else
        -- Standalone mode: own size, position, chrome
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
        self.frame:SetScript("OnDragStart", function(f)
            if f:IsMovable() then
                f:StartMoving()
            end
        end)
        self.frame:SetScript("OnDragStop", function(f)
            if f:IsMovable() then
                f:StopMovingOrSizing()
            end
        end)

        -- Set resize bounds
        if self.frame.SetResizeBounds then
            self.frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, 600, 800)
        else
            self.frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
            self.frame:SetMaxResize(600, 800)
        end

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

        -- Resize handle
        self.frame.resizeBtn = CreateFrame("Button", nil, self.frame)
        self.frame.resizeBtn:SetSize(32, 32)
        self.frame.resizeBtn:SetPoint("BOTTOMRIGHT", 0, 0)
        self.frame.resizeBtn:SetFrameStrata("DIALOG")
        self.frame.resizeBtn:SetNormalTexture("Interface\\Buttons\\WHITE8x8")
        self.frame.resizeBtn:GetNormalTexture():SetVertexColor(0, 0, 0, 0.01)
        self.frame.resizeBtn.icon = self.frame.resizeBtn:CreateTexture(nil, "OVERLAY")
        self.frame.resizeBtn.icon:SetPoint("BOTTOMRIGHT", 0, 0)
        self.frame.resizeBtn.icon:SetSize(16, 16)
        self.frame.resizeBtn.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

        self.frame.resizeBtn:SetScript("OnMouseDown", function(btn, button)
            if button == "LeftButton" then
                self.frame:StartSizing("BOTTOMRIGHT")
            end
        end)
        self.frame.resizeBtn:SetScript("OnMouseUp", function(btn, button)
            self.frame:StopMovingOrSizing()
            self:Refresh()
        end)

        -- Handle resize events
        self.frame:SetScript("OnSizeChanged", function(f, width, height)
            if self.frame.content then
                self.frame.content:SetWidth(width - 40)
            end
        end)
    end

    self.frame:Hide()

    -- Create scroll frame for content
    local scrollName = frameName .. "ScrollFrame"
    self.frame.scrollFrame = CreateFrame("ScrollFrame", scrollName, self.frame, "UIPanelScrollFrameTemplate")

    if config.embedded then
        self.frame.scrollFrame:SetPoint("TOPLEFT", 4, -4)
        self.frame.scrollFrame:SetPoint("BOTTOMRIGHT", -24, 28)
    else
        self.frame.scrollFrame:SetPoint("TOPLEFT", 8, -32)
        self.frame.scrollFrame:SetPoint("BOTTOMRIGHT", -28, 32)
    end

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
end

-- Refresh the display using stored path
function MilestonePanelClass:Refresh()
    if self.currentPath then
        self:Update(self.currentPath)
    end
end

-- Update the panel with path data
-- path: full path object with milestoneBreakdown, totalCost, currentSkill
function MilestonePanelClass:Update(path)
    LazyProf:Debug("ui", "=== MilestonePanel:Update (" .. (self.config.name or "unnamed") .. ") ===")
    LazyProf:Debug("ui", "  config.embedded: " .. tostring(self.config.embedded))
    LazyProf:Debug("ui", "  path: " .. (path and "exists" or "NIL"))

    -- Store the path for refresh and click handlers
    self.currentPath = path

    -- For standalone mode, check if panel should be shown
    if not self.config.embedded and not LazyProf.db.profile.showMilestonePanel then
        LazyProf:Debug("ui", "  HIDING - standalone mode and showMilestonePanel=false")
        self:Hide()
        return
    end

    -- Clear existing rows
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    self.rows = {}

    local breakdown = path and path.milestoneBreakdown
    LazyProf:Debug("ui", "  breakdown: " .. (breakdown and ("#" .. #breakdown .. " steps") or "NIL"))

    if not breakdown or #breakdown == 0 then
        LazyProf:Debug("ui", "  HIDING - no breakdown data")
        self:Hide()
        return
    end

    LazyProf:Debug("ui", "  frame: " .. (self.frame and tostring(self.frame:GetName()) or "NIL"))
    LazyProf:Debug("ui", "  frame.content: " .. (self.frame and self.frame.content and "exists" or "NIL"))
    LazyProf:Debug("ui", "  frame size: " .. (self.frame and (self.frame:GetWidth() .. "x" .. self.frame:GetHeight()) or "N/A"))

    -- Update title with mode indicator (standalone only)
    if not self.config.embedded and self.frame.title then
        if LazyProf.db.profile.calculateFromCurrentSkill then
            self.frame.title:SetText(string.format("Milestone Breakdown |cFF66FF66(from %d)|r", path.currentSkill))
        else
            self.frame.title:SetText("Milestone Breakdown |cFF888888(full path)|r")
        end
    end

    local contentWidth = self.frame:GetWidth() - 40
    local yOffset = 0
    local lastMilestone = nil

    for i, step in ipairs(breakdown) do
        -- Create step row
        local row = self:CreateStepRow(step, i, yOffset, contentWidth)
        table.insert(self.rows, row)
        yOffset = yOffset + STEP_ROW_HEIGHT

        -- If expanded, show ingredients for this step
        if self.expandedRows[i] then
            -- Show unlearned indicator if recipe not learned
            if step.recipe and not step.recipe.learned then
                local unlearnedRow = self:CreateUnlearnedIndicator(step, yOffset, contentWidth)
                table.insert(self.rows, unlearnedRow)
                yOffset = yOffset + INGREDIENT_ROW_HEIGHT
            end

            -- Show ingredients
            for _, mat in ipairs(step.materials) do
                local ingredientRow = self:CreateIngredientRow(mat, yOffset, contentWidth)
                table.insert(self.rows, ingredientRow)
                yOffset = yOffset + INGREDIENT_ROW_HEIGHT
            end
        end

        -- Add milestone separator after this step if it crosses a trainer milestone
        if step.trainerMilestoneAfter and step.trainerMilestoneAfter ~= lastMilestone then
            local separator = self:CreateMilestoneSeparator(step.trainerMilestoneAfter, yOffset, contentWidth)
            table.insert(self.rows, separator)
            yOffset = yOffset + MILESTONE_SEPARATOR_HEIGHT
            lastMilestone = step.trainerMilestoneAfter
        end
    end

    -- Update total
    self.frame.total:SetText("Total: " .. Utils.FormatMoney(path.totalCost))

    -- Update content height for scrolling
    self.frame.content:SetHeight(math.max(yOffset + 10, self.frame:GetHeight() - 70))

    -- Position standalone panel next to TradeSkillFrame
    if not self.config.embedded then
        if TradeSkillFrame and TradeSkillFrame:IsVisible() and not self.manuallyMoved then
            self.frame:ClearAllPoints()
            self.frame:SetPoint("TOPLEFT", TradeSkillFrame, "TOPRIGHT", 10, 0)
        end
    end

    LazyProf:Debug("ui", string.format("  Created %d rows, content size: %.0fx%.0f",
        #self.rows,
        self.frame.content:GetWidth(),
        self.frame.content:GetHeight()))
    self:Show()

    -- Verify first row is actually visible (helps diagnose strata/positioning issues)
    if #self.rows > 0 then
        local firstRow = self.rows[1]
        LazyProf:Debug("ui", string.format("  First row: visible=%s, left=%.0f, top=%.0f",
            tostring(firstRow:IsVisible()),
            firstRow:GetLeft() or -1,
            firstRow:GetTop() or -1))
    end
end

-- Create a step row (single recipe step)
function MilestonePanelClass:CreateStepRow(step, index, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth, STEP_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    -- Row background for hover
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.3)

    -- Expand/collapse indicator
    row.expandBtn = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.expandBtn:SetPoint("LEFT", 2, 0)
    row.expandBtn:SetText(self.expandedRows[index] and "[-]" or "[+]")
    row.expandBtn:SetTextColor(0.6, 0.6, 0.6)

    -- Skill range (e.g., "184-197")
    row.range = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.range:SetPoint("LEFT", 18, 0)
    row.range:SetText(string.format("%d-%d", step.from, step.to))
    row.range:SetTextColor(1, 0.82, 0) -- Gold color

    -- Quantity and recipe name (e.g., "30x Bronze Tube")
    local recipeName = step.recipe and step.recipe.name or "Unknown"
    local recipeColor = self:ColorToRGB(step.color)

    row.recipe = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.recipe:SetPoint("LEFT", 65, 0)
    row.recipe:SetPoint("RIGHT", row, "LEFT", 175, 0)
    row.recipe:SetJustifyH("LEFT")
    row.recipe:SetWordWrap(false)
    row.recipe:SetText(string.format("%dx %s", step.quantity, recipeName))
    row.recipe:SetTextColor(recipeColor.r, recipeColor.g, recipeColor.b)

    -- Materials summary (truncated)
    row.materials = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.materials:SetPoint("LEFT", 180, 0)
    row.materials:SetPoint("RIGHT", row, "RIGHT", -55, 0)
    row.materials:SetJustifyH("LEFT")
    row.materials:SetWordWrap(false)
    local matSummary = step.materialsSummary or ""
    if #matSummary > 40 then
        matSummary = matSummary:sub(1, 37) .. "..."
    end
    row.materials:SetText("- " .. matSummary)
    row.materials:SetTextColor(0.7, 0.7, 0.7)

    -- Cost
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.cost:SetPoint("RIGHT", -4, 0)
    row.cost:SetText(Utils.FormatMoney(step.cost))
    row.cost:SetTextColor(1, 1, 1)

    -- Click to expand/collapse (uses stored self.currentPath)
    row:SetScript("OnClick", function()
        self.expandedRows[index] = not self.expandedRows[index]
        self:Refresh()
    end)

    -- Highlight on hover
    row:SetScript("OnEnter", function()
        row:SetBackdropColor(0.25, 0.25, 0.25, 0.6)
        row.expandBtn:SetTextColor(1, 1, 0)
        -- Tooltip with full materials
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(string.format("%dx %s", step.quantity, recipeName), 1, 1, 1)
        GameTooltip:AddLine(string.format("Skill: %d -> %d", step.from, step.to), 0.7, 0.7, 0.7)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Materials:", 1, 0.82, 0)
        for _, mat in ipairs(step.materials) do
            local color = mat.missing > 0 and "|cFFFF6666" or "|cFF66FF66"
            GameTooltip:AddLine(string.format("  %s%dx|r %s", color, mat.need, mat.name), 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to expand/collapse", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        row:SetBackdropColor(0.15, 0.15, 0.15, 0.3)
        row.expandBtn:SetTextColor(0.6, 0.6, 0.6)
        GameTooltip:Hide()
    end)

    row:Show()
    return row
end

-- Convert color name to RGB values for display
function MilestonePanelClass:ColorToRGB(color)
    if color == "orange" then
        return { r = 1, g = 0.5, b = 0.25 }
    elseif color == "yellow" then
        return { r = 1, g = 1, b = 0 }
    elseif color == "green" then
        return { r = 0.25, g = 0.75, b = 0.25 }
    else
        return { r = 0.5, g = 0.5, b = 0.5 }  -- gray or unknown
    end
end

-- Create an unlearned recipe indicator row (for expanded step view)
function MilestonePanelClass:CreateUnlearnedIndicator(step, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth - 20, INGREDIENT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 20, -yOffset)

    -- Row background for hover
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.2, 0.15, 0, 0.3)

    -- Warning indicator
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.text:SetJustifyH("LEFT")

    local sourceDesc = Utils.GetSourceDescription(step.recipe.source)
    row.text:SetText(string.format("|cFFFF8800[!] Unlearned:|r %s", sourceDesc))

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
        self:SetBackdropColor(0.3, 0.25, 0.1, 0.5)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Click for details", 1, 1, 1)
        GameTooltip:AddLine("View vendors, Wowhead link", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.2, 0.15, 0, 0.3)
        GameTooltip:Hide()
    end)

    row:Show()
    return row
end

-- Create a trainer milestone separator
function MilestonePanelClass:CreateMilestoneSeparator(milestone, yOffset, contentWidth)
    local row = CreateFrame("Frame", nil, self.frame.content)
    row:SetSize(contentWidth, MILESTONE_SEPARATOR_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    -- Separator line left
    row.lineLeft = row:CreateTexture(nil, "ARTWORK")
    row.lineLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.lineLeft:SetVertexColor(0.4, 0.4, 0.4, 0.8)
    row.lineLeft:SetHeight(1)
    row.lineLeft:SetPoint("LEFT", 4, 0)
    row.lineLeft:SetPoint("RIGHT", row, "CENTER", -40, 0)

    -- Milestone text
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("CENTER", 0, 0)
    row.text:SetText(string.format("Train (%d)", milestone))
    row.text:SetTextColor(0.6, 0.6, 0.6)

    -- Separator line right
    row.lineRight = row:CreateTexture(nil, "ARTWORK")
    row.lineRight:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.lineRight:SetVertexColor(0.4, 0.4, 0.4, 0.8)
    row.lineRight:SetHeight(1)
    row.lineRight:SetPoint("LEFT", row, "CENTER", 40, 0)
    row.lineRight:SetPoint("RIGHT", -4, 0)

    row:Show()
    return row
end

-- Create an ingredient row
function MilestonePanelClass:CreateIngredientRow(mat, yOffset, contentWidth)
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
function MilestonePanelClass:Show()
    self.frame:Show()
end

-- Hide the panel
function MilestonePanelClass:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

-- Check if visible
function MilestonePanelClass:IsVisible()
    return self.frame and self.frame:IsVisible()
end

-- Create the main standalone instance (backwards compatible)
-- Empty name keeps frame as "LazyProfMilestonePanel" for other modules that reference it
LazyProf.MilestonePanel = MilestonePanelClass:New({ name = "", embedded = false })
