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
function MissingPanel:RefreshLayout()
    if LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath then
        self:Update(LazyProf.Pathfinder.currentPath.missingMaterials)
    end
end

-- Update panel with missing materials
-- missingMaterials is now { fromBank = {...}, fromAH = {...} }
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

    -- Handle new structure { fromBank, fromAH }
    local fromBank = missingMaterials and missingMaterials.fromBank or {}
    local fromAH = missingMaterials and missingMaterials.fromAH or {}

    if #fromBank == 0 and #fromAH == 0 then
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

    -- Show bank section first (if any)
    if #fromBank > 0 then
        local headerRow = self:CreateSectionHeader("From Bank", yOffset, contentWidth)
        table.insert(self.rows, headerRow)
        yOffset = yOffset + ROW_HEIGHT

        for _, mat in ipairs(fromBank) do
            local row = self:CreateMaterialRow(mat, yOffset, contentWidth, true)
            table.insert(self.rows, row)
            yOffset = yOffset + ROW_HEIGHT
        end
    end

    -- Show AH section (if any)
    if #fromAH > 0 then
        local headerRow = self:CreateSectionHeader("From AH", yOffset, contentWidth)
        table.insert(self.rows, headerRow)
        yOffset = yOffset + ROW_HEIGHT

        for _, mat in ipairs(fromAH) do
            local row = self:CreateMaterialRow(mat, yOffset, contentWidth, false)
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
-- isBank: true for bank items (green), false for AH items (red with price)
function MissingPanel:CreateMaterialRow(mat, yOffset, contentWidth, isBank)
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
    row.icon:SetTexture(mat.icon)

    -- Count and name (green for bank, red for AH)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", 26, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.text:SetJustifyH("LEFT")
    local countColor = isBank and "|cFF66FF66" or "|cFFFF6666"
    row.text:SetText(string.format("%s%dx|r %s", countColor, mat.missing, mat.name or "Unknown"))

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

-- Show panel
function MissingPanel:Show()
    self.frame:Show()
end

-- Hide panel
function MissingPanel:Hide()
    self.frame:Hide()
end
