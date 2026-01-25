-- Modules/UI/MilestoneBreakdown.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

LazyProf.MilestonePanel = {}
local MilestonePanel = LazyProf.MilestonePanel

MilestonePanel.frame = nil
MilestonePanel.rows = {}
MilestonePanel.expandedRows = {}

local STEP_ROW_HEIGHT = 20
local INGREDIENT_ROW_HEIGHT = 18
local MILESTONE_SEPARATOR_HEIGHT = 16
local MIN_WIDTH = 350
local MIN_HEIGHT = 100
local DEFAULT_WIDTH = 400

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

    -- Resize handle (solid hit area with grabber icon overlay)
    self.frame.resizeBtn = CreateFrame("Button", nil, self.frame)
    self.frame.resizeBtn:SetSize(32, 32)
    self.frame.resizeBtn:SetPoint("BOTTOMRIGHT", 0, 0)
    self.frame.resizeBtn:SetFrameStrata("DIALOG") -- Above all nested content
    -- Solid texture for full-area click detection (nearly invisible)
    self.frame.resizeBtn:SetNormalTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.resizeBtn:GetNormalTexture():SetVertexColor(0, 0, 0, 0.01)
    -- Grabber icon on top
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
    -- Use the appropriate path based on current mode
    local path
    if self.parentMode == "planning" and LazyProf.PlanningWindow then
        path = LazyProf.PlanningWindow.currentPath
    elseif LazyProf.Pathfinder then
        path = LazyProf.Pathfinder.currentPath
    end

    if path then
        self:Update(path.milestoneBreakdown, path.totalCost)
    end
end

-- Set the parent frame for standalone vs attached mode
-- mode: "tradeskill" (attached to TradeSkillFrame) or "planning" (embedded in PlanningWindow)
function MilestonePanel:SetParentMode(mode, parentFrame)
    self.parentMode = mode
    self.customParent = parentFrame

    if mode == "planning" and parentFrame then
        self.frame:SetParent(parentFrame)
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 0, 0)
        self.frame:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", 0, 0)
        -- Hide UI elements handled by parent in planning mode
        self.frame.closeBtn:Hide()
        self.frame.resizeBtn:Hide()
        self.frame.titleBg:Hide()
        self.frame.title:Hide()
        -- Disable dragging (parent handles it)
        self.frame:SetMovable(false)
        -- Remove backdrop (parent has its own styling)
        self.frame:SetBackdrop(nil)
        -- Adjust scroll frame to use full space (no title bar)
        self.frame.scrollFrame:SetPoint("TOPLEFT", 4, -4)
        self.frame.scrollFrame:SetPoint("BOTTOMRIGHT", -24, 28)
    else
        self.frame:SetParent(UIParent)
        -- Clear stale anchors from planning mode and reset to default position
        self.frame:ClearAllPoints()
        self.frame:SetSize(DEFAULT_WIDTH, 200)
        self.frame:SetPoint("TOPLEFT", TradeSkillFrame or UIParent, "TOPRIGHT", 10, 0)
        self.frame.closeBtn:Show()
        self.frame.resizeBtn:Show()
        self.frame.titleBg:Show()
        self.frame.title:Show()
        self.frame:SetMovable(true)
        -- Restore backdrop
        self.frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        self.frame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        self.frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        -- Restore scroll frame position (leave room for title bar)
        self.frame.scrollFrame:SetPoint("TOPLEFT", 8, -32)
        self.frame.scrollFrame:SetPoint("BOTTOMRIGHT", -28, 32)
    end
end

-- Update the panel with milestone breakdown data (step-by-step format)
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
    self.frame.total:SetText("Total: " .. Utils.FormatMoney(totalCost))

    -- Update content height for scrolling
    self.frame.content:SetHeight(math.max(yOffset + 10, self.frame:GetHeight() - 70))

    -- Position based on mode
    if self.parentMode == "planning" then
        -- Already positioned by SetParentMode, don't reposition
    elseif TradeSkillFrame and TradeSkillFrame:IsVisible() and not self.manuallyMoved then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPLEFT", TradeSkillFrame, "TOPRIGHT", 10, 0)
    end

    self:Show()
end

-- Create a step row (single recipe step)
function MilestonePanel:CreateStepRow(step, index, yOffset, contentWidth)
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
    local recipeColor = self:GetRecipeColor(step.recipe)

    row.recipe = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.recipe:SetPoint("LEFT", 65, 0)
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

    -- Click to expand/collapse
    row:SetScript("OnClick", function()
        self.expandedRows[index] = not self.expandedRows[index]
        local path
        if self.parentMode == "planning" and LazyProf.PlanningWindow then
            path = LazyProf.PlanningWindow.currentPath
        elseif LazyProf.Pathfinder then
            path = LazyProf.Pathfinder.currentPath
        end
        if path then
            self:Update(path.milestoneBreakdown, path.totalCost)
        end
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

-- Get recipe color based on difficulty
function MilestonePanel:GetRecipeColor(recipe)
    if not recipe or not recipe.skillRange then
        return { r = 1, g = 1, b = 1 }
    end

    -- Use current skill from appropriate path based on mode
    local path
    if self.parentMode == "planning" and LazyProf.PlanningWindow then
        path = LazyProf.PlanningWindow.currentPath
    elseif LazyProf.Pathfinder then
        path = LazyProf.Pathfinder.currentPath
    end
    local currentSkill = path and path.currentSkill or 1
    local color = Utils.GetSkillColor(currentSkill, recipe.skillRange)

    if color == "orange" then
        return { r = 1, g = 0.5, b = 0.25 }
    elseif color == "yellow" then
        return { r = 1, g = 1, b = 0 }
    elseif color == "green" then
        return { r = 0.25, g = 0.75, b = 0.25 }
    else
        return { r = 0.5, g = 0.5, b = 0.5 }
    end
end

-- Create an unlearned recipe indicator row (for expanded step view)
function MilestonePanel:CreateUnlearnedIndicator(step, yOffset, contentWidth)
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
function MilestonePanel:CreateMilestoneSeparator(milestone, yOffset, contentWidth)
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
