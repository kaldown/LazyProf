-- Modules/UI/MissingMaterials.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

LazyProf.MissingMaterialsPanel = {}
local MissingPanel = LazyProf.MissingMaterialsPanel

MissingPanel.frame = nil
MissingPanel.rows = {}

local ROW_HEIGHT = 22
local MIN_WIDTH = 280
local MIN_HEIGHT = 80
local DEFAULT_WIDTH = 300

-- Initialize the panel
function MissingPanel:Initialize()
    self.frame = CreateFrame("Frame", "LazyProfMissingPanel", UIParent, "BackdropTemplate")
    self.frame:SetSize(DEFAULT_WIDTH, 150)
    self.frame:SetPoint("TOPLEFT", LazyProfMilestonePanel or UIParent, "BOTTOMLEFT", 0, -10)
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
        self.frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, 500, 600)
    else
        self.frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
        self.frame:SetMaxResize(500, 600)
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
    self.frame.title:SetText("Shopping List")
    self.frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    self.frame.closeBtn = CreateFrame("Button", nil, self.frame, "UIPanelCloseButton")
    self.frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    self.frame.closeBtn:SetSize(20, 20)

    -- Scroll frame for content
    self.frame.scrollFrame = CreateFrame("ScrollFrame", "LazyProfMissingScrollFrame", self.frame, "UIPanelScrollFrameTemplate")
    self.frame.scrollFrame:SetPoint("TOPLEFT", 8, -32)
    self.frame.scrollFrame:SetPoint("BOTTOMRIGHT", -28, 32)

    -- Content frame inside scroll
    self.frame.content = CreateFrame("Frame", nil, self.frame.scrollFrame)
    self.frame.content:SetSize(DEFAULT_WIDTH - 40, 300)
    self.frame.scrollFrame:SetScrollChild(self.frame.content)

    -- Total bar at bottom
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
function MissingPanel:RefreshLayout()
    if LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath then
        self:Update(LazyProf.Pathfinder.currentPath.missingMaterials)
    end
end

-- Update panel with missing materials
-- missingMaterials is now { fromBank = {...}, toCraft = {...}, fromAH = {...} }
function MissingPanel:Update(missingMaterials)
    if not LazyProf.db.profile.showMissingMaterials then
        self:Hide()
        return
    end

    -- Clear existing rows
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    self.rows = {}

    -- Handle structure { fromBank, fromAlts, toCraft, fromAH }
    local fromBank = missingMaterials and missingMaterials.fromBank or {}
    local fromAlts = missingMaterials and missingMaterials.fromAlts or {}
    local toCraft = missingMaterials and missingMaterials.toCraft or {}
    local fromAH = missingMaterials and missingMaterials.fromAH or {}

    if #fromBank == 0 and #fromAlts == 0 and #toCraft == 0 and #fromAH == 0 then
        self.frame.title:SetText("All Materials Ready!")
        self.frame.title:SetTextColor(0.4, 1, 0.4)
        self.frame.total:SetText("")
        self.frame:SetHeight(70)
        self:Show()
        return
    end

    self.frame.title:SetText("Shopping List")
    self.frame.title:SetTextColor(1, 0.82, 0)

    local contentWidth = self.frame:GetWidth() - 40
    local yOffset = 0
    local totalCost = 0

    -- 1. Show bank section first (if any)
    if #fromBank > 0 then
        local headerRow = self:CreateSectionHeader("From Bank", yOffset, contentWidth)
        table.insert(self.rows, headerRow)
        yOffset = yOffset + ROW_HEIGHT

        for _, mat in ipairs(fromBank) do
            local row = self:CreateMaterialRow(mat, yOffset, contentWidth, "bank")
            table.insert(self.rows, row)
            yOffset = yOffset + ROW_HEIGHT
        end
    end

    -- 2. Show alts section (if any)
    if #fromAlts > 0 then
        local headerRow = self:CreateSectionHeader("From Alts", yOffset, contentWidth)
        table.insert(self.rows, headerRow)
        yOffset = yOffset + ROW_HEIGHT

        for _, mat in ipairs(fromAlts) do
            local row = self:CreateAltMaterialRow(mat, yOffset, contentWidth)
            table.insert(self.rows, row)
            yOffset = yOffset + ROW_HEIGHT
        end
    end

    -- 3. Show "To Craft" section (if any)
    if #toCraft > 0 then
        local headerRow = self:CreateSectionHeader("To Craft", yOffset, contentWidth)
        table.insert(self.rows, headerRow)
        yOffset = yOffset + ROW_HEIGHT

        for _, craft in ipairs(toCraft) do
            -- Main craft row
            local row = self:CreateCraftRow(craft, yOffset, contentWidth)
            table.insert(self.rows, row)
            yOffset = yOffset + ROW_HEIGHT

            -- Sub-row showing material breakdown
            local subRow = self:CreateCraftSubRow(craft, yOffset, contentWidth)
            table.insert(self.rows, subRow)
            yOffset = yOffset + ROW_HEIGHT

            totalCost = totalCost + (craft.craftCost or 0)
        end
    end

    -- 4. Show AH section (if any)
    if #fromAH > 0 then
        local headerRow = self:CreateSectionHeader("From AH", yOffset, contentWidth)
        table.insert(self.rows, headerRow)
        yOffset = yOffset + ROW_HEIGHT

        for _, mat in ipairs(fromAH) do
            local row = self:CreateMaterialRow(mat, yOffset, contentWidth, "ah")
            table.insert(self.rows, row)
            yOffset = yOffset + ROW_HEIGHT
            totalCost = totalCost + mat.estimatedCost
        end
    end

    self.frame.total:SetText("Total: " .. Utils.FormatMoney(totalCost))

    -- Update content height for scrolling
    self.frame.content:SetHeight(math.max(yOffset + 10, self.frame:GetHeight() - 70))

    -- Position below milestone panel
    if LazyProfMilestonePanel and LazyProfMilestonePanel:IsVisible() then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPLEFT", LazyProfMilestonePanel, "BOTTOMLEFT", 0, -10)
    elseif TradeSkillFrame and TradeSkillFrame:IsVisible() then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPLEFT", TradeSkillFrame, "TOPRIGHT", 10, -220)
    end

    self:Show()
end

-- Create a section header row
function MissingPanel:CreateSectionHeader(text, yOffset, contentWidth)
    local row = CreateFrame("Frame", nil, self.frame.content)
    row:SetSize(contentWidth, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetText("|cFFFFD100" .. text .. "|r")

    row:Show()
    return row
end

-- Create a material row
-- rowType: "bank" for bank items (green), "ah" for AH items (red with price)
function MissingPanel:CreateMaterialRow(mat, yOffset, contentWidth, rowType)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    -- Row background for hover
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)

    local isBank = (rowType == "bank")

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture(mat.icon)

    -- Count and name (green for bank, red for AH) with optional purpose annotation
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", 26, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.text:SetJustifyH("LEFT")
    local countColor = isBank and "|cFF66FF66" or "|cFFFF6666"
    local displayText = string.format("%s%dx|r %s", countColor, mat.missing, mat.name or "Unknown")

    -- Add purpose annotation for bank items (e.g., "for smelting")
    if isBank and mat.purpose then
        displayText = displayText .. string.format(" |cFF888888(%s)|r", mat.purpose)
    end
    row.text:SetText(displayText)

    -- Cost (only for AH items)
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.cost:SetPoint("RIGHT", -8, 0)
    if isBank then
        row.cost:SetText("")
    elseif mat.estimatedCost > 0 then
        row.cost:SetText(Utils.FormatMoney(mat.estimatedCost))
    else
        row.cost:SetText("|cFF666666No price|r")
    end

    -- Shift-click to link (works with chat, AH, Auctionator, etc.)
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
            GameTooltip:AddLine(" ")
            if isBank then
                GameTooltip:AddLine(string.format("In bank: %d | Grab: %d", mat.have, mat.missing), 0.4, 1, 0.4)
                if mat.purpose then
                    GameTooltip:AddLine("Purpose: " .. mat.purpose, 0.6, 0.6, 0.6)
                end
            else
                GameTooltip:AddLine(string.format("Have: %d | Need: %d | Buy: %d", mat.have, mat.need, mat.missing), 1, 1, 1)
            end
            GameTooltip:AddLine("Shift-click to link", 0.5, 0.5, 0.5)
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

-- Create a material row for alt items (shows character name)
function MissingPanel:CreateAltMaterialRow(mat, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture(mat.icon)

    -- Build character list string
    local charList = {}
    for _, charInfo in ipairs(mat.characters or {}) do
        -- Extract just character name (remove realm)
        local charName = charInfo.name:match("^([^-]+)") or charInfo.name
        table.insert(charList, string.format("%s:%d", charName, charInfo.count))
    end
    local charString = table.concat(charList, ", ")

    -- Count and name (purple for alts)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", 26, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.text:SetJustifyH("LEFT")
    local displayText = string.format("|cFFCC99FF%dx|r %s |cFF888888(%s)|r",
        mat.missing, mat.name or "Unknown", charString)
    row.text:SetText(displayText)

    -- Shift-click to link
    row:SetScript("OnClick", function()
        if IsShiftKeyDown() and mat.link then
            HandleModifiedItemClick(mat.link)
        end
    end)

    -- Tooltip
    row:SetScript("OnEnter", function()
        row:SetBackdropColor(0.25, 0.25, 0.25, 0.8)
        if mat.itemId then
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(mat.itemId)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("On your alts:", 0.8, 0.6, 1)
            for _, charInfo in ipairs(mat.characters or {}) do
                GameTooltip:AddLine(string.format("  %s: %d", charInfo.name, charInfo.count), 1, 1, 1)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Transfer to crafter before crafting", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Shift-click to link", 0.5, 0.5, 0.5)
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

-- Create a craft row for "To Craft" section
-- Format: 46x Fel Iron Bar (Smelt Fel Iron: 92x Fel Iron Ore)
function MissingPanel:CreateCraftRow(craft, yOffset, contentWidth)
    local row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetSize(contentWidth, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    -- Row background for hover
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture(craft.icon)

    -- Text: "46x Fel Iron Bar (Smelt Fel Iron: 92x Fel Iron Ore)"
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", 26, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.text:SetJustifyH("LEFT")

    local displayText = string.format("|cFF66CCFF%dx|r %s", craft.quantity, craft.name or "Unknown")
    if craft.recipeName and craft.sourceDesc then
        displayText = displayText .. string.format(" |cFFAAAAAA(%s: %s)|r", craft.recipeName, craft.sourceDesc)
    end
    row.text:SetText(displayText)

    -- Cost
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.cost:SetPoint("RIGHT", -8, 0)
    if craft.craftCost and craft.craftCost > 0 then
        row.cost:SetText(Utils.FormatMoney(craft.craftCost))
    else
        row.cost:SetText("|cFF66FF66Free|r")
    end

    -- Shift-click to link
    row:SetScript("OnClick", function()
        if IsShiftKeyDown() and craft.link then
            HandleModifiedItemClick(craft.link)
        end
    end)

    -- Tooltip and hover
    row:SetScript("OnEnter", function()
        row:SetBackdropColor(0.25, 0.25, 0.25, 0.8)
        if craft.itemId then
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(craft.itemId)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Craft this intermediate material", 0.4, 0.8, 1)
            if craft.recipeName then
                GameTooltip:AddLine("Recipe: " .. craft.recipeName, 1, 1, 1)
            end
            if craft.professionKey then
                GameTooltip:AddLine("Profession: " .. craft.professionKey, 0.8, 0.8, 0.8)
            end
            GameTooltip:AddLine("Shift-click to link", 0.5, 0.5, 0.5)
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

-- Create a sub-row showing material breakdown: "└─ Using: 50x from bank + 42x from AH"
function MissingPanel:CreateCraftSubRow(craft, yOffset, contentWidth)
    local row = CreateFrame("Frame", nil, self.frame.content)
    row:SetSize(contentWidth, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 26, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetTextColor(0.6, 0.6, 0.6)

    local usingText = craft.usingDesc or ""
    row.text:SetText(string.format("    \226\148\148\226\148\128 Using: %s", usingText))

    row:Show()
    return row
end

-- Show panel
function MissingPanel:Show()
    self.frame:Show()
end

-- Hide panel
function MissingPanel:Hide()
    self.frame:Hide()
end
