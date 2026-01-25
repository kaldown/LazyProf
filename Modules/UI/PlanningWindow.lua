-- Modules/UI/PlanningWindow.lua
-- Standalone planning window - completely separate from MilestoneBreakdown
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils
local Constants = LazyProf.Constants

LazyProf.PlanningWindow = {}
local PlanningWindow = LazyProf.PlanningWindow

PlanningWindow.frame = nil
PlanningWindow.currentProfession = nil
PlanningWindow.currentPath = nil
PlanningWindow.rows = {}
PlanningWindow.expandedRows = {}

local STEP_ROW_HEIGHT = 20
local INGREDIENT_ROW_HEIGHT = 18
local MILESTONE_SEPARATOR_HEIGHT = 16
local DEFAULT_WIDTH = 420
local DEFAULT_HEIGHT = 500

function PlanningWindow:Initialize()
    self.frame = CreateFrame("Frame", "LazyProfPlanningWindow", UIParent, "BackdropTemplate")
    self.frame:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
    self.frame:SetPoint("CENTER")
    self.frame:SetFrameStrata("HIGH")
    self.frame:SetFrameLevel(100)

    -- Solid dark background
    self.frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    self.frame:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
    self.frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    self.frame:EnableMouse(true)
    self.frame:SetMovable(true)
    self.frame:SetResizable(true)
    self.frame:SetClampedToScreen(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    self.frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)

    if self.frame.SetResizeBounds then
        self.frame:SetResizeBounds(380, 300, 600, 800)
    else
        self.frame:SetMinResize(380, 300)
        self.frame:SetMaxResize(600, 800)
    end

    self.frame:Hide()

    -- Title bar
    self.frame.titleBg = self.frame:CreateTexture(nil, "ARTWORK")
    self.frame.titleBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.titleBg:SetVertexColor(0.2, 0.2, 0.2, 1)
    self.frame.titleBg:SetPoint("TOPLEFT", 4, -4)
    self.frame.titleBg:SetPoint("TOPRIGHT", -4, -4)
    self.frame.titleBg:SetHeight(28)

    -- Title text
    self.frame.title = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.frame.title:SetPoint("LEFT", self.frame.titleBg, "LEFT", 10, 0)
    self.frame.title:SetText("Planning Mode")
    self.frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    self.frame.closeBtn = CreateFrame("Button", nil, self.frame, "UIPanelCloseButton")
    self.frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    self.frame.closeBtn:SetSize(24, 24)
    self.frame.closeBtn:SetScript("OnClick", function() self:Hide() end)

    -- Mode dropdown (Fast/Optimal)
    self:CreateModeDropdown()

    -- Status banner
    self.frame.statusBg = self.frame:CreateTexture(nil, "ARTWORK")
    self.frame.statusBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.statusBg:SetVertexColor(0.15, 0.15, 0.15, 1)
    self.frame.statusBg:SetPoint("TOPLEFT", 4, -36)
    self.frame.statusBg:SetPoint("TOPRIGHT", -4, -36)
    self.frame.statusBg:SetHeight(22)

    self.frame.status = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.frame.status:SetPoint("LEFT", self.frame.statusBg, "LEFT", 8, 0)
    self.frame.status:SetTextColor(0.7, 0.7, 0.7)

    -- Scroll frame for content
    self.frame.scrollFrame = CreateFrame("ScrollFrame", "LazyProfPlanningScrollFrame", self.frame, "UIPanelScrollFrameTemplate")
    self.frame.scrollFrame:SetPoint("TOPLEFT", 8, -62)
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
    self.frame.resizeBtn:SetScript("OnMouseUp", function()
        self.frame:StopMovingOrSizing()
        self:RefreshContent()
    end)

    -- Handle resize events
    self.frame:SetScript("OnSizeChanged", function(f, width, height)
        if self.frame.content then
            self.frame.content:SetWidth(width - 40)
        end
    end)

    -- Make closable with Escape
    tinsert(UISpecialFrames, "LazyProfPlanningWindow")
end

function PlanningWindow:CreateModeDropdown()
    self.frame.modeBtn = CreateFrame("Button", nil, self.frame, "BackdropTemplate")
    self.frame.modeBtn:SetSize(80, 20)
    self.frame.modeBtn:SetPoint("RIGHT", self.frame.closeBtn, "LEFT", -4, 0)
    self.frame.modeBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    self.frame.modeBtn:SetBackdropColor(0.2, 0.2, 0.2, 1)
    self.frame.modeBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    self.frame.modeBtn.text = self.frame.modeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.frame.modeBtn.text:SetPoint("CENTER")
    self.frame.modeBtn.text:SetText("Cheapest")

    self.frame.modeBtn:SetScript("OnClick", function()
        local current = LazyProf.db.profile.strategy
        local newStrategy = (current == Constants.STRATEGY.CHEAPEST) and Constants.STRATEGY.FASTEST or Constants.STRATEGY.CHEAPEST
        LazyProf.db.profile.strategy = newStrategy
        self.frame.modeBtn.text:SetText(newStrategy == Constants.STRATEGY.CHEAPEST and "Cheapest" or "Fastest")
        if self.currentProfession then
            self:LoadProfession(self.currentProfession)
        end
    end)

    self.frame.modeBtn:SetScript("OnEnter", function(btn)
        btn:SetBackdropColor(0.3, 0.3, 0.3, 1)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Strategy")
        GameTooltip:AddLine("Click to toggle between Cheapest and Fastest", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    self.frame.modeBtn:SetScript("OnLeave", function(btn)
        btn:SetBackdropColor(0.2, 0.2, 0.2, 1)
        GameTooltip:Hide()
    end)
end

function PlanningWindow:Open(profKey)
    if not self.frame then
        self:Initialize()
    end

    self:LoadProfession(profKey)
    self.frame:Show()
end

function PlanningWindow:LoadProfession(profKey)
    self.currentProfession = profKey

    local profInfo = Constants.PROFESSIONS[profKey]
    if not profInfo then
        LazyProf:Print("Unknown profession: " .. tostring(profKey))
        return
    end

    -- Update title
    self.frame.title:SetText("Planning: " .. profInfo.name)

    -- Update mode button text
    local strategy = LazyProf.db.profile.strategy
    self.frame.modeBtn.text:SetText(strategy == Constants.STRATEGY.CHEAPEST and "Cheapest" or "Fastest")

    -- Check if player has this profession
    local skillLevel = self:GetPlayerSkillLevel(profKey)
    if skillLevel > 0 then
        self.frame.status:SetText(string.format("Current skill: %d/375", skillLevel))
        self.frame.status:SetTextColor(0.4, 1, 0.4)
    else
        self.frame.status:SetText("You have not learned this profession")
        self.frame.status:SetTextColor(0.7, 0.7, 0.7)
    end

    -- Calculate path
    self.currentPath = LazyProf.Pathfinder:CalculateForProfession(profKey, skillLevel)

    -- Render content directly (no MilestonePanel dependency)
    if self.currentPath then
        self:RenderBreakdown(self.currentPath.milestoneBreakdown, self.currentPath.totalCost)
    end
end

function PlanningWindow:GetPlayerSkillLevel(profKey)
    local profInfo = Constants.PROFESSIONS[profKey]
    if not profInfo then return 0 end

    local targetName = profInfo.name:lower()

    -- Classic/TBC uses GetSkillLineInfo instead of GetProfessions
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank = GetSkillLineInfo(i)
        if not isHeader and skillName and skillName:lower() == targetName then
            return skillRank or 0
        end
    end

    return 0
end

function PlanningWindow:RefreshContent()
    if self.currentPath then
        self:RenderBreakdown(self.currentPath.milestoneBreakdown, self.currentPath.totalCost)
    end
end

function PlanningWindow:RenderBreakdown(breakdown, totalCost)
    -- Clear existing rows
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    self.rows = {}

    if not breakdown or #breakdown == 0 then
        self.frame.total:SetText("No path found")
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

        -- If expanded, show ingredients
        if self.expandedRows[i] then
            if step.recipe and not step.recipe.learned then
                local unlearnedRow = self:CreateUnlearnedIndicator(step, yOffset, contentWidth)
                table.insert(self.rows, unlearnedRow)
                yOffset = yOffset + INGREDIENT_ROW_HEIGHT
            end

            for _, mat in ipairs(step.materials) do
                local ingredientRow = self:CreateIngredientRow(mat, yOffset, contentWidth)
                table.insert(self.rows, ingredientRow)
                yOffset = yOffset + INGREDIENT_ROW_HEIGHT
            end
        end

        -- Milestone separator
        if step.trainerMilestoneAfter and step.trainerMilestoneAfter ~= lastMilestone then
            local separator = self:CreateMilestoneSeparator(step.trainerMilestoneAfter, yOffset, contentWidth)
            table.insert(self.rows, separator)
            yOffset = yOffset + MILESTONE_SEPARATOR_HEIGHT
            lastMilestone = step.trainerMilestoneAfter
        end
    end

    -- Update total
    self.frame.total:SetText("Total: " .. Utils.FormatMoney(totalCost))

    -- Update content height
    self.frame.content:SetHeight(math.max(yOffset + 10, self.frame:GetHeight() - 100))
end

function PlanningWindow:CreateStepRow(step, index, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth, STEP_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.3)

    -- Expand indicator
    row.expandBtn = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.expandBtn:SetPoint("LEFT", 2, 0)
    row.expandBtn:SetText(self.expandedRows[index] and "[-]" or "[+]")
    row.expandBtn:SetTextColor(0.6, 0.6, 0.6)

    -- Skill range
    row.range = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.range:SetPoint("LEFT", 18, 0)
    row.range:SetText(string.format("%d-%d", step.from, step.to))
    row.range:SetTextColor(1, 0.82, 0)

    -- Recipe name
    local recipeName = step.recipe and step.recipe.name or "Unknown"
    local recipeColor = self:GetRecipeColor(step.recipe)

    row.recipe = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.recipe:SetPoint("LEFT", 65, 0)
    row.recipe:SetText(string.format("%dx %s", step.quantity, recipeName))
    row.recipe:SetTextColor(recipeColor.r, recipeColor.g, recipeColor.b)

    -- Materials summary
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
        self:RefreshContent()
    end)

    -- Hover
    row:SetScript("OnEnter", function()
        row:SetBackdropColor(0.25, 0.25, 0.25, 0.6)
        row.expandBtn:SetTextColor(1, 1, 0)
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

function PlanningWindow:GetRecipeColor(recipe)
    if not recipe or not recipe.skillRange then
        return { r = 1, g = 1, b = 1 }
    end

    local currentSkill = self.currentPath and self.currentPath.currentSkill or 1
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

function PlanningWindow:CreateUnlearnedIndicator(step, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth - 20, INGREDIENT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 20, -yOffset)

    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetBackdropColor(0.2, 0.15, 0, 0.3)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.text:SetJustifyH("LEFT")

    local sourceDesc = Utils.GetSourceDescription(step.recipe.source)
    row.text:SetText(string.format("|cFFFF8800[!] Unlearned:|r %s", sourceDesc))

    row.recipe = step.recipe

    row:SetScript("OnClick", function(self)
        if LazyProf.RecipeDetails then
            LazyProf.RecipeDetails:Toggle(self.recipe)
        end
    end)

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

function PlanningWindow:CreateMilestoneSeparator(milestone, yOffset, contentWidth)
    local row = CreateFrame("Frame", nil, self.frame.content)
    row:SetSize(contentWidth, MILESTONE_SEPARATOR_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    row.lineLeft = row:CreateTexture(nil, "ARTWORK")
    row.lineLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.lineLeft:SetVertexColor(0.4, 0.4, 0.4, 0.8)
    row.lineLeft:SetHeight(1)
    row.lineLeft:SetPoint("LEFT", 4, 0)
    row.lineLeft:SetPoint("RIGHT", row, "CENTER", -40, 0)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("CENTER", 0, 0)
    row.text:SetText(string.format("Train (%d)", milestone))
    row.text:SetTextColor(0.6, 0.6, 0.6)

    row.lineRight = row:CreateTexture(nil, "ARTWORK")
    row.lineRight:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.lineRight:SetVertexColor(0.4, 0.4, 0.4, 0.8)
    row.lineRight:SetHeight(1)
    row.lineRight:SetPoint("LEFT", row, "CENTER", 40, 0)
    row.lineRight:SetPoint("RIGHT", -4, 0)

    row:Show()
    return row
end

function PlanningWindow:CreateIngredientRow(mat, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth - 20, INGREDIENT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 20, -yOffset)

    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture(mat.icon)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", 24, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.text:SetJustifyH("LEFT")
    local countText = mat.missing > 0 and
        string.format("|cFFFF6666%dx|r", mat.missing) or
        "|cFF66FF66Ready|r"
    row.text:SetText(countText .. " " .. (mat.name or "Unknown"))

    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.cost:SetPoint("RIGHT", -8, 0)
    if mat.estimatedCost > 0 then
        row.cost:SetText(Utils.FormatMoney(mat.estimatedCost))
    else
        row.cost:SetText("|cFF666666N/A|r")
    end

    row:SetScript("OnClick", function()
        if IsShiftKeyDown() and mat.link then
            HandleModifiedItemClick(mat.link)
        end
    end)

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

function PlanningWindow:Hide()
    if self.frame then
        self.frame:Hide()
    end
    -- No MilestonePanel dependency - nothing else to reset
end

function PlanningWindow:IsVisible()
    return self.frame and self.frame:IsVisible()
end
