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
local ALTERNATIVE_ROW_HEIGHT = 18
local ALT_GROUP_HEADER_HEIGHT = 18
local ALT_GROUP_SIZE = 5
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
    instance.expandedAlternatives = {}  -- [stepKey] = true/false (main alternatives spoiler)
    instance.expandedAltGroups = {}     -- [stepKey][groupIndex] = true/false
    instance.currentPath = nil
    instance.frame = nil
    instance.selectedBracketIndex = nil  -- nil="current bracket", number=specific, "all"=full path
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
        self.frame.title:SetPoint("TOPLEFT", 12, -10)
        self.frame.title:SetJustifyH("LEFT")
        self.frame.title:SetText("Milestone Breakdown")
        self.frame.title:SetTextColor(1, 0.82, 0)

        -- Close button
        self.frame.closeBtn = CreateFrame("Button", nil, self.frame, "UIPanelCloseButton")
        self.frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
        self.frame.closeBtn:SetSize(20, 20)

        -- Bracket filter dropdown
        self:CreateBracketDropdown(frameName, config)

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

    local scrollTopOffset = self.frame.bracketDropdown and -56 or -32
    if config.embedded then
        self.frame.scrollFrame:SetPoint("TOPLEFT", 4, -28)
        self.frame.scrollFrame:SetPoint("BOTTOMRIGHT", -24, 28)
    else
        self.frame.scrollFrame:SetPoint("TOPLEFT", 8, scrollTopOffset)
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

-- Get the effective bracket for display filtering
-- Returns {min, max, name} or nil (nil = show all steps)
function MilestonePanelClass:GetEffectiveBracket()
    if self.selectedBracketIndex == "all" then
        return nil  -- no filtering
    end

    local brackets = LazyProf.skillBrackets
    if type(self.selectedBracketIndex) == "number" then
        return brackets[self.selectedBracketIndex]
    end

    -- nil = auto-detect from current path skill
    if self.currentPath and self.currentPath.currentSkill then
        for _, bracket in ipairs(brackets) do
            if self.currentPath.currentSkill >= bracket.min and self.currentPath.currentSkill < bracket.max then
                return bracket
            end
        end
    end
    return nil  -- fallback: show all
end

-- Get display label for the bracket dropdown
function MilestonePanelClass:GetBracketLabel()
    if self.selectedBracketIndex == "all" then
        return "Full Path"
    end

    local bracket = self:GetEffectiveBracket()
    if not bracket then
        return "Full Path"
    end

    if self.selectedBracketIndex == nil then
        return "Current (" .. bracket.name .. ")"
    end
    return bracket.name
end

-- Filter breakdown steps to only those within the effective bracket
function MilestonePanelClass:FilterBreakdownByBracket(breakdown)
    local bracket = self:GetEffectiveBracket()
    if not bracket then
        return breakdown  -- no filtering
    end

    local filtered = {}
    for _, step in ipairs(breakdown) do
        if step.from >= bracket.min and step.from < bracket.max then
            table.insert(filtered, step)
        end
    end
    return filtered
end

-- Create the bracket filter dropdown
function MilestonePanelClass:CreateBracketDropdown(frameName, config)
    local dropdownName = frameName .. "BracketDropdown"
    self.frame.bracketDropdown = CreateFrame("Frame", dropdownName, self.frame, "UIDropDownMenuTemplate")
    self.frame.bracketDropdown:SetPoint("TOPLEFT", -8, -26)
    UIDropDownMenu_SetWidth(self.frame.bracketDropdown, 160)

    local panel = self
    local function BracketDropdown_Initialize(dropdown, level)
        local info = UIDropDownMenu_CreateInfo()

        -- "Current Bracket" option (auto-detect)
        info.text = "Current Bracket"
        info.value = "current"
        info.checked = (panel.selectedBracketIndex == nil)
        info.func = function()
            panel.selectedBracketIndex = nil
            UIDropDownMenu_SetText(dropdown, panel:GetBracketLabel())
            panel:Refresh()
        end
        UIDropDownMenu_AddButton(info, level)

        -- Individual brackets
        for i, bracket in ipairs(LazyProf.skillBrackets) do
            info = UIDropDownMenu_CreateInfo()
            info.text = bracket.name
            info.value = i
            info.checked = (panel.selectedBracketIndex == i)
            info.func = function()
                panel.selectedBracketIndex = i
                UIDropDownMenu_SetText(dropdown, panel:GetBracketLabel())
                panel:Refresh()
            end
            UIDropDownMenu_AddButton(info, level)
        end

        -- "Full Path" option
        info = UIDropDownMenu_CreateInfo()
        info.text = "Full Path"
        info.value = "all"
        info.checked = (panel.selectedBracketIndex == "all")
        info.func = function()
            panel.selectedBracketIndex = "all"
            UIDropDownMenu_SetText(dropdown, "Full Path")
            panel:Refresh()
        end
        UIDropDownMenu_AddButton(info, level)
    end

    UIDropDownMenu_Initialize(self.frame.bracketDropdown, BracketDropdown_Initialize)
    UIDropDownMenu_SetText(self.frame.bracketDropdown, self:GetBracketLabel())
end

-- Update shopping list with bracket-filtered data
function MilestonePanelClass:UpdateShoppingList(path, filteredBreakdown, bracket)
    local panel = LazyProf.MissingMaterialsPanel
    if not panel then return end

    -- Extract the step objects that match the filtered breakdown
    local filteredSteps = {}
    if path.steps then
        local filteredFromSet = {}
        for _, bd in ipairs(filteredBreakdown) do
            filteredFromSet[bd.from] = true
        end
        for _, step in ipairs(path.steps) do
            if filteredFromSet[step.skillStart] then
                table.insert(filteredSteps, step)
            end
        end
    end

    -- Recalculate missing materials from filtered steps
    local inventory, sourceBreakdown = LazyProf.Inventory:ScanAll()
    local prices = {}
    for itemId, cached in pairs(LazyProf.PriceManager.cache) do
        prices[itemId] = cached.price
    end

    local missingMaterials = LazyProf.Pathfinder:CalculateMissingMaterials(
        filteredSteps, inventory, sourceBreakdown, prices
    )

    local bracketLabel = bracket and bracket.name or nil
    panel:Update(missingMaterials, bracketLabel)
end

-- Update the panel with path data
-- path: full path object with milestoneBreakdown, totalCost, currentSkill
function MilestonePanelClass:Update(path)
    LazyProf:Debug("ui", "=== MilestonePanel:Update (" .. (self.config.name or "unnamed") .. ") ===")
    LazyProf:Debug("ui", "  config.embedded: " .. tostring(self.config.embedded))
    LazyProf:Debug("ui", "  path: " .. (path and "exists" or "NIL"))

    -- Auto-advance: reset bracket and expanded state when a new path arrives
    if path ~= self.currentPath then
        self.selectedBracketIndex = nil
        self.expandedRows = {}
        self.expandedAlternatives = {}
        self.expandedAltGroups = {}
    end

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

    local fullBreakdown = path and path.milestoneBreakdown
    LazyProf:Debug("ui", "  breakdown: " .. (fullBreakdown and ("#" .. #fullBreakdown .. " steps") or "NIL"))

    if not fullBreakdown or #fullBreakdown == 0 then
        LazyProf:Debug("ui", "  HIDING - no breakdown data")
        self:Hide()
        return
    end

    -- Apply bracket filter
    local bracket = self:GetEffectiveBracket()
    local breakdown = self:FilterBreakdownByBracket(fullBreakdown)
    LazyProf:Debug("ui", "  bracket filter: " .. self:GetBracketLabel() .. " (" .. #breakdown .. " of " .. #fullBreakdown .. " steps)")

    -- Update bracket dropdown text
    if self.frame.bracketDropdown then
        UIDropDownMenu_SetText(self.frame.bracketDropdown, self:GetBracketLabel())
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

    -- Handle empty bracket
    if #breakdown == 0 then
        local emptyRow = CreateFrame("Frame", nil, self.frame.content)
        emptyRow:SetSize(contentWidth, STEP_ROW_HEIGHT)
        emptyRow:SetPoint("TOPLEFT", 0, 0)
        emptyRow.text = emptyRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyRow.text:SetPoint("CENTER", 0, 0)
        emptyRow.text:SetText("No steps in " .. (bracket and bracket.name or "this bracket"))
        emptyRow.text:SetTextColor(0.5, 0.5, 0.5)
        emptyRow:Show()
        table.insert(self.rows, emptyRow)
        yOffset = STEP_ROW_HEIGHT

        self.frame.total:SetText("")
        self.frame.content:SetHeight(math.max(yOffset + 10, self.frame:GetHeight() - 70))

        if not self.config.embedded then
            if TradeSkillFrame and TradeSkillFrame:IsVisible() and not self.manuallyMoved then
                self.frame:ClearAllPoints()
                self.frame:SetPoint("TOPLEFT", TradeSkillFrame, "TOPRIGHT", 10, 0)
            end
        end

        self:Show()
        -- Update shopping list with empty bracket
        self:UpdateShoppingList(path, breakdown, bracket)
        return
    end

    for _, step in ipairs(breakdown) do
        local stepKey = step.from
        -- Create step row
        local row = self:CreateStepRow(step, stepKey, yOffset, contentWidth)
        table.insert(self.rows, row)
        yOffset = yOffset + STEP_ROW_HEIGHT

        -- If expanded, show unlearned indicator, ingredients, then alternatives
        if self.expandedRows[stepKey] then
            -- Show unlearned indicator if recipe not learned
            if step.recipe and not step.recipe.learned then
                local unlearnedRow = self:CreateUnlearnedIndicator(step, yOffset, contentWidth)
                table.insert(self.rows, unlearnedRow)
                yOffset = yOffset + INGREDIENT_ROW_HEIGHT
            end

            -- Show ingredients first (context for why the winner was chosen)
            for _, mat in ipairs(step.materials) do
                local ingredientRow = self:CreateIngredientRow(mat, yOffset, contentWidth)
                table.insert(self.rows, ingredientRow)
                yOffset = yOffset + INGREDIENT_ROW_HEIGHT
            end

            -- Show alternatives section (collapsible spoiler with groups inside)
            if step.alternatives and #step.alternatives > 1 then
                -- Build filtered list (exclude current recipe)
                local filteredAlts = {}
                for _, alt in ipairs(step.alternatives) do
                    if alt.recipe.id ~= step.recipe.id then
                        table.insert(filteredAlts, { alt = alt })
                    end
                end
                -- Sort by out-of-pocket cost (cheapest-for-you first)
                table.sort(filteredAlts, function(a, b)
                    return (a.alt.outOfPocketCost or a.alt.craftCost) < (b.alt.outOfPocketCost or b.alt.craftCost)
                end)
                -- Assign display rank after sort
                for i, entry in ipairs(filteredAlts) do
                    entry.rank = i
                end

                local totalAlts = #filteredAlts
                if totalAlts > 0 then
                    -- Main "Alternatives" spoiler header with separator lines
                    local isAltExpanded = self.expandedAlternatives[stepKey]
                    local altHeader = self:CreateAlternativesSpoiler(totalAlts, isAltExpanded, stepKey, yOffset, contentWidth)
                    table.insert(self.rows, altHeader)
                    yOffset = yOffset + MILESTONE_SEPARATOR_HEIGHT

                    -- Only show groups if the main spoiler is expanded
                    if isAltExpanded then
                        local bestScore = step.alternatives[1] and step.alternatives[1].score or 0

                        -- Initialize group state for this step
                        if not self.expandedAltGroups[stepKey] then
                            self.expandedAltGroups[stepKey] = {}
                        end

                        -- Split into groups of ALT_GROUP_SIZE
                        local groupIndex = 0
                        for startIdx = 1, totalAlts, ALT_GROUP_SIZE do
                            groupIndex = groupIndex + 1
                            local endIdx = math.min(startIdx + ALT_GROUP_SIZE - 1, totalAlts)
                            local firstRank = filteredAlts[startIdx].rank
                            local lastRank = filteredAlts[endIdx].rank

                            -- Group header
                            local isGroupExpanded = self.expandedAltGroups[stepKey][groupIndex]
                            local headerRow = self:CreateAltGroupHeader(
                                firstRank, lastRank, isGroupExpanded, stepKey, groupIndex, yOffset, contentWidth
                            )
                            table.insert(self.rows, headerRow)
                            yOffset = yOffset + ALT_GROUP_HEADER_HEIGHT

                            -- Show individual rows if group is expanded
                            if isGroupExpanded then
                                for idx = startIdx, endIdx do
                                    local entry = filteredAlts[idx]
                                    local altRow = self:CreateAlternativeRow(
                                        entry.alt, entry.rank, bestScore, step.from, yOffset, contentWidth
                                    )
                                    table.insert(self.rows, altRow)
                                    yOffset = yOffset + ALTERNATIVE_ROW_HEIGHT
                                end
                            end
                        end
                    end
                end
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

    -- Show recalculate button if there are dirty pins (use FULL breakdown for pin check)
    if self.frame.recalcBtn then
        self.frame.recalcBtn:Hide()
    end
    local dirtyCount = 0
    for _, step in ipairs(fullBreakdown) do
        local pinned = LazyProf.Pathfinder.pinnedRecipes[step.from]
        if pinned and pinned ~= step.recipe.id then
            dirtyCount = dirtyCount + 1
        end
    end
    if dirtyCount > 0 then
        self:CreateRecalculateButton(dirtyCount)
    end

    -- Update total - show out-of-pocket cost (green when inventory saves money)
    if bracket then
        local bracketOopCost = 0
        local bracketMarketCost = 0
        for _, step in ipairs(breakdown) do
            bracketOopCost = bracketOopCost + (step.outOfPocketCost or step.cost or 0)
            bracketMarketCost = bracketMarketCost + (step.cost or 0)
        end
        local fullOopCost = path.outOfPocketTotal or path.totalCost
        local bracketColor = bracketOopCost < bracketMarketCost and "|cFF66FF66" or ""
        local bracketColorEnd = bracketOopCost < bracketMarketCost and "|r" or ""
        self.frame.total:SetText(string.format("Bracket: %s%s%s  |cFF888888|  Full: %s|r",
            bracketColor, Utils.FormatMoney(bracketOopCost), bracketColorEnd, Utils.FormatMoney(fullOopCost)))
    else
        local oopTotal = path.outOfPocketTotal or path.totalCost
        if oopTotal < path.totalCost then
            self.frame.total:SetText(string.format("Total: |cFF66FF66%s|r",
                Utils.FormatMoney(oopTotal)))
        else
            self.frame.total:SetText("Total: " .. Utils.FormatMoney(path.totalCost))
        end
    end

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

    -- Update shopping list with bracket-filtered data
    self:UpdateShoppingList(path, breakdown, bracket)
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

    -- Skill range (e.g., "184-197") with pin indicator
    local hasDirtyPin = LazyProf.Pathfinder.pinnedRecipes[step.from] and
        LazyProf.Pathfinder.pinnedRecipes[step.from] ~= step.recipe.id
    row.range = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.range:SetPoint("LEFT", 18, 0)
    local rangeText = string.format("%d-%d", step.from, step.to)
    if hasDirtyPin then
        rangeText = rangeText .. " [*]"
        row.range:SetTextColor(0.4, 0.7, 1) -- Blue tint for pending pin
    else
        row.range:SetTextColor(1, 0.82, 0) -- Gold color
    end
    row.range:SetText(rangeText)

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

    -- Cost (out-of-pocket; green when inventory reduces cost)
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.cost:SetPoint("RIGHT", -4, 0)
    local oopCost = step.outOfPocketCost or step.cost
    local marketCost = step.cost or 0
    row.cost:SetText(Utils.FormatMoney(oopCost))
    if oopCost < marketCost then
        row.cost:SetTextColor(0.4, 1, 0.4)
    else
        row.cost:SetTextColor(1, 1, 1)
    end

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
        if oopCost < marketCost then
            GameTooltip:AddLine(string.format("You pay: %s", Utils.FormatMoney(oopCost)), 0.4, 1, 0.4)
            GameTooltip:AddLine(string.format("Market price: %s", Utils.FormatMoney(marketCost)), 0.5, 0.5, 0.5)
            GameTooltip:AddLine(string.format("Saving: %s", Utils.FormatMoney(marketCost - oopCost)), 0.4, 1, 0.4)
        else
            GameTooltip:AddLine(string.format("Cost: %s", Utils.FormatMoney(marketCost)), 1, 1, 1)
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

    -- Store recipe reference and skill level for click handler
    row.recipe = step.recipe
    row.skillLevel = step.from

    -- Click to show recipe details panel
    row:SetScript("OnClick", function(self)
        if LazyProf.RecipeDetails then
            LazyProf.RecipeDetails:Toggle(self.recipe, self.skillLevel)
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

-- Create the main "Alternatives" spoiler separator (with lines on both sides)
function MilestonePanelClass:CreateAlternativesSpoiler(totalAlts, isExpanded, stepIndex, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content)
    row:SetSize(contentWidth - 16, MILESTONE_SEPARATOR_HEIGHT)
    row:SetPoint("TOPLEFT", 16, -yOffset)

    -- Separator line left
    row.lineLeft = row:CreateTexture(nil, "ARTWORK")
    row.lineLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.lineLeft:SetVertexColor(0.3, 0.4, 0.5, 0.8)
    row.lineLeft:SetHeight(1)
    row.lineLeft:SetPoint("LEFT", 0, 0)
    row.lineLeft:SetPoint("RIGHT", row, "CENTER", -60, 0)

    -- Label text
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("CENTER", 0, 0)
    local indicator = isExpanded and "[-]" or "[+]"
    row.text:SetText(string.format("%s Alternatives (%d)", indicator, totalAlts))
    row.text:SetTextColor(0.5, 0.6, 0.8)

    -- Separator line right
    row.lineRight = row:CreateTexture(nil, "ARTWORK")
    row.lineRight:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.lineRight:SetVertexColor(0.3, 0.4, 0.5, 0.8)
    row.lineRight:SetHeight(1)
    row.lineRight:SetPoint("LEFT", row, "CENTER", 60, 0)
    row.lineRight:SetPoint("RIGHT", 0, 0)

    -- Click to expand/collapse
    row:SetScript("OnClick", function()
        self.expandedAlternatives[stepIndex] = not self.expandedAlternatives[stepIndex]
        self:Refresh()
    end)

    -- Hover
    row:SetScript("OnEnter", function()
        row.text:SetTextColor(0.7, 0.8, 1)
        row.lineLeft:SetVertexColor(0.4, 0.5, 0.7, 1)
        row.lineRight:SetVertexColor(0.4, 0.5, 0.7, 1)
    end)
    row:SetScript("OnLeave", function()
        row.text:SetTextColor(0.5, 0.6, 0.8)
        row.lineLeft:SetVertexColor(0.3, 0.4, 0.5, 0.8)
        row.lineRight:SetVertexColor(0.3, 0.4, 0.5, 0.8)
    end)

    row:Show()
    return row
end

-- Create a collapsible group header for alternatives (e.g., "Alternatives #2-#6")
function MilestonePanelClass:CreateAltGroupHeader(firstRank, lastRank, isExpanded, stepIndex, groupIndex, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth - 12, ALT_GROUP_HEADER_HEIGHT)
    row:SetPoint("TOPLEFT", 12, -yOffset)

    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.12, 0.14, 0.2, 0.5)

    -- Expand/collapse indicator + label
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", 4, 0)
    local indicator = isExpanded and "[-]" or "[+]"
    local label
    if firstRank == lastRank then
        label = string.format("%s Alternative #%d", indicator, firstRank)
    else
        label = string.format("%s Alternatives #%d - #%d", indicator, firstRank, lastRank)
    end
    row.text:SetText(label)
    row.text:SetTextColor(0.5, 0.6, 0.8)

    -- Click to expand/collapse this group
    row:SetScript("OnClick", function()
        if not self.expandedAltGroups[stepIndex] then
            self.expandedAltGroups[stepIndex] = {}
        end
        self.expandedAltGroups[stepIndex][groupIndex] = not self.expandedAltGroups[stepIndex][groupIndex]
        self:Refresh()
    end)

    -- Hover
    row:SetScript("OnEnter", function()
        row:SetBackdropColor(0.18, 0.2, 0.28, 0.6)
        row.text:SetTextColor(0.7, 0.8, 1)
    end)
    row:SetScript("OnLeave", function()
        row:SetBackdropColor(0.12, 0.14, 0.2, 0.5)
        row.text:SetTextColor(0.5, 0.6, 0.8)
    end)

    row:Show()
    return row
end

-- Create an alternative recipe row (shown when step is expanded)
-- alt: { recipe, score, color, expectedSkillups, craftCost }
-- rank: position in sorted alternatives (1 = best)
-- bestScore: score of the #1 alternative for delta calculation
-- skillLevel: the step's starting skill level (for pinning)
function MilestonePanelClass:CreateAlternativeRow(alt, rank, bestScore, skillLevel, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth - 16, ALTERNATIVE_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 16, -yOffset)

    -- Row background - blue tint to distinguish from ingredients
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })

    -- Highlight if this recipe is currently pinned at this skill level
    local pinnedId = LazyProf.Pathfinder.pinnedRecipes[skillLevel]
    local isThisPinned = (pinnedId == alt.recipe.id)
    if isThisPinned then
        row:SetBackdropColor(0.15, 0.2, 0.3, 0.6)
    else
        row:SetBackdropColor(0.1, 0.12, 0.18, 0.4)
    end

    -- Pin indicator button (clickable separately from row)
    row.pinBtn = CreateFrame("Button", nil, row)
    row.pinBtn:SetSize(18, ALTERNATIVE_ROW_HEIGHT)
    row.pinBtn:SetPoint("LEFT", 0, 0)
    row.pin = row.pinBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.pin:SetPoint("CENTER", row.pinBtn, "CENTER", 0, 0)
    if isThisPinned then
        row.pin:SetText("[*]")
        row.pin:SetTextColor(0.4, 0.7, 1)
    else
        row.pin:SetText("[>]")
        row.pin:SetTextColor(0.4, 0.4, 0.5)
    end

    -- Pin button click: toggle pin
    row.pinBtn:SetScript("OnClick", function()
        if isThisPinned then
            LazyProf.Pathfinder:UnpinRecipe(skillLevel)
        else
            LazyProf.Pathfinder:PinRecipe(skillLevel, alt.recipe.id)
        end
        self:Refresh()
    end)
    row.pinBtn:SetScript("OnEnter", function()
        row.pin:SetTextColor(0.6, 0.8, 1)
        -- Propagate hover to parent row for background highlight
        row:GetScript("OnEnter")(row)
    end)
    row.pinBtn:SetScript("OnLeave", function()
        row.pin:SetTextColor(isThisPinned and 0.4 or 0.4, isThisPinned and 0.7 or 0.4, isThisPinned and 1 or 0.5)
        row:GetScript("OnLeave")(row)
    end)

    -- Rank
    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.rank:SetPoint("LEFT", 20, 0)
    row.rank:SetText(string.format("#%d", rank))
    row.rank:SetTextColor(0.5, 0.5, 0.5)

    -- Recipe name (colored by difficulty), with [!] prefix if unlearned
    local recipeColor = self:ColorToRGB(alt.color)
    local isUnlearned = not alt.recipe.learned
    row.recipe = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.recipe:SetPoint("LEFT", 40, 0)
    row.recipe:SetPoint("RIGHT", row, "RIGHT", -120, 0)
    row.recipe:SetJustifyH("LEFT")
    row.recipe:SetWordWrap(false)
    local displayName = alt.recipe.name or "Unknown"
    if isUnlearned then
        displayName = "|cFFFF8800[!]|r " .. displayName
    end
    row.recipe:SetText(displayName)
    row.recipe:SetTextColor(recipeColor.r, recipeColor.g, recipeColor.b)

    -- Skillup rate
    row.skillup = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.skillup:SetPoint("RIGHT", row, "RIGHT", -70, 0)
    row.skillup:SetText(string.format("%.0f%%", alt.expectedSkillups * 100))
    row.skillup:SetTextColor(0.7, 0.7, 0.7)

    -- Cost per craft (out-of-pocket; green when inventory reduces cost)
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.cost:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    if alt.score < math.huge then
        local altOopCost = alt.outOfPocketCost or alt.craftCost
        row.cost:SetText(Utils.FormatMoney(altOopCost))
        if altOopCost < alt.craftCost then
            row.cost:SetTextColor(0.4, 1, 0.4)
        else
            row.cost:SetTextColor(1, 1, 1)
        end
    else
        row.cost:SetText("|cFF666666N/A|r")
        row.cost:SetTextColor(1, 1, 1)
    end

    -- Dim unavailable recipes visually
    if alt.recipe._isUnavailable then
        row.rank:SetAlpha(0.5)
        row.recipe:SetAlpha(0.5)
        row.skillup:SetAlpha(0.5)
        row.cost:SetAlpha(0.5)
    end

    -- Click row to show recipe details (pass step skill level for accurate difficulty)
    row:SetScript("OnClick", function()
        if LazyProf.RecipeDetails then
            LazyProf.RecipeDetails:Toggle(alt.recipe, skillLevel)
        end
    end)

    -- Hover effects
    row:SetScript("OnEnter", function()
        if isThisPinned then
            row:SetBackdropColor(0.2, 0.25, 0.35, 0.7)
        else
            row:SetBackdropColor(0.15, 0.18, 0.25, 0.6)
        end
        row.pin:SetTextColor(0.6, 0.8, 1)

        -- Tooltip with details
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(alt.recipe.name or "Unknown", recipeColor.r, recipeColor.g, recipeColor.b)
        if isUnlearned then
            local sourceDesc = Utils.GetSourceDescription(alt.recipe.source)
            GameTooltip:AddLine("[!] Unlearned: " .. sourceDesc, 1, 0.53, 0)
            if alt.recipe._isUnavailable then
                GameTooltip:AddLine("    Not currently obtainable", 1, 0.3, 0.3)
            end
        end
        GameTooltip:AddLine(string.format("Difficulty: %s (%d%% skillup chance)", alt.color, alt.expectedSkillups * 100), 0.7, 0.7, 0.7)
        if alt.score < math.huge then
            local tooltipOopCost = alt.outOfPocketCost or alt.craftCost
            if tooltipOopCost < alt.craftCost then
                GameTooltip:AddLine(string.format("Cost per craft: %s (market: %s)",
                    Utils.FormatMoney(tooltipOopCost), Utils.FormatMoney(alt.craftCost)), 0.4, 1, 0.4)
            else
                GameTooltip:AddLine(string.format("Cost per craft: %s", Utils.FormatMoney(alt.craftCost)), 1, 1, 1)
            end
            -- Score details only in debug mode
            if LazyProf.db.profile.debug then
                GameTooltip:AddLine(string.format("Score: %.2f", alt.score), 0.5, 0.5, 0.5)
                if bestScore and bestScore < math.huge and alt.score ~= bestScore then
                    local delta = alt.score - bestScore
                    local deltaColor = delta > 0 and "|cFFFF6666" or "|cFF66FF66"
                    GameTooltip:AddLine(string.format("vs best: %s%+.2f|r", deltaColor, delta), 1, 1, 1)
                end
            end
        else
            GameTooltip:AddLine("Missing price data", 1, 0.4, 0.4)
        end
        GameTooltip:AddLine(" ")
        -- Reagents
        GameTooltip:AddLine("Materials:", 1, 0.82, 0)
        for _, reagent in ipairs(alt.recipe.reagents) do
            GameTooltip:AddLine(string.format("  %dx %s", reagent.count, reagent.name or "Unknown"), 0.8, 0.8, 0.8)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click for recipe details", 0.5, 0.5, 0.5)
        if isThisPinned then
            GameTooltip:AddLine("Click [*] to unpin", 0.5, 0.5, 0.5)
        elseif alt.recipe._isUnavailable then
            GameTooltip:AddLine("Click [>] to pin (you will need to obtain this recipe)", 0.5, 0.5, 0.5)
        else
            GameTooltip:AddLine("Click [>] to pin (then Recalculate)", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        if isThisPinned then
            row:SetBackdropColor(0.15, 0.2, 0.3, 0.6)
        else
            row:SetBackdropColor(0.1, 0.12, 0.18, 0.4)
        end
        row.pin:SetTextColor(isThisPinned and 0.4 or 0.4, isThisPinned and 0.7 or 0.4, isThisPinned and 1 or 0.5)
        GameTooltip:Hide()
    end)

    row:Show()
    return row
end

-- Create the recalculate button (shown when dirty pins exist)
function MilestonePanelClass:CreateRecalculateButton(dirtyCount)
    if not self.frame.recalcBtn then
        self.frame.recalcBtn = CreateFrame("Button", nil, self.frame, "BackdropTemplate")
        self.frame.recalcBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        self.frame.recalcBtn:SetBackdropColor(0.1, 0.4, 0.15, 0.95)
        self.frame.recalcBtn:SetBackdropBorderColor(0.3, 0.8, 0.4, 1)

        -- Ensure button is above scroll content
        self.frame.recalcBtn:SetFrameLevel(self.frame:GetFrameLevel() + 10)

        self.frame.recalcBtn.text = self.frame.recalcBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        self.frame.recalcBtn.text:SetPoint("CENTER", 0, 0)
        self.frame.recalcBtn.text:SetTextColor(1, 1, 1)

        self.frame.recalcBtn:SetScript("OnClick", function()
            -- Use THIS panel's stored path (not the global Pathfinder.currentPath)
            local currentPath = self.currentPath
            if currentPath then
                local pinCount = LazyProf.Pathfinder:GetDirtyPinCount()
                local reason = string.format("recalculate button (%d dirty pin%s)", pinCount, pinCount ~= 1 and "s" or "")
                if currentPath.professionKey then
                    -- Planning mode - recalculate and update this panel
                    local path = LazyProf.Pathfinder:CalculateForProfession(
                        currentPath.professionKey,
                        currentPath.currentSkill,
                        reason
                    )
                    if path then
                        self:Update(path)
                    end
                else
                    -- Active profession mode - recalculate and update all UI
                    LazyProf.Pathfinder:Calculate(reason)
                    LazyProf:UpdateDisplay()
                end
            end
        end)

        self.frame.recalcBtn:SetScript("OnEnter", function(btn)
            btn:SetBackdropColor(0.15, 0.5, 0.2, 1)
        end)
        self.frame.recalcBtn:SetScript("OnLeave", function(btn)
            btn:SetBackdropColor(0.1, 0.4, 0.15, 0.95)
        end)
    end

    -- Stretch across the full width, above the total bar
    self.frame.recalcBtn:ClearAllPoints()
    self.frame.recalcBtn:SetPoint("BOTTOMLEFT", self.frame.totalBg, "TOPLEFT", 0, 2)
    self.frame.recalcBtn:SetPoint("BOTTOMRIGHT", self.frame.totalBg, "TOPRIGHT", 0, 2)
    self.frame.recalcBtn:SetHeight(26)
    self.frame.recalcBtn.text:SetText(string.format("Recalculate with %d pin%s", dirtyCount, dirtyCount > 1 and "s" or ""))
    self.frame.recalcBtn:Show()
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
