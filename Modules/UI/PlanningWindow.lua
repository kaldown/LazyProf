-- Modules/UI/PlanningWindow.lua
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils
local Constants = LazyProf.Constants

LazyProf.PlanningWindow = {}
local PlanningWindow = LazyProf.PlanningWindow

PlanningWindow.frame = nil
PlanningWindow.currentProfession = nil
PlanningWindow.currentPath = nil

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

    -- Content area (will embed milestone panel)
    self.frame.contentArea = CreateFrame("Frame", nil, self.frame)
    self.frame.contentArea:SetPoint("TOPLEFT", 4, -62)
    self.frame.contentArea:SetPoint("BOTTOMRIGHT", -4, 4)

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
    self.frame.resizeBtn:SetScript("OnMouseUp", function()
        self.frame:StopMovingOrSizing()
        -- Refresh MilestonePanel layout after resize
        if self.currentPath and LazyProf.MilestonePanel then
            LazyProf.MilestonePanel:RefreshLayout()
        end
    end)

    -- Handle continuous resize for smooth content updates
    self.frame:SetScript("OnSizeChanged", function(f, width, height)
        if self.currentPath and LazyProf.MilestonePanel and LazyProf.MilestonePanel.frame then
            -- Update content width in MilestonePanel
            local contentArea = self.frame.contentArea
            if contentArea and LazyProf.MilestonePanel.frame.content then
                LazyProf.MilestonePanel.frame.content:SetWidth(contentArea:GetWidth() - 30)
            end
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
        -- Toggle between cheapest and fastest
        local current = LazyProf.db.profile.strategy
        local newStrategy = (current == Constants.STRATEGY.CHEAPEST) and Constants.STRATEGY.FASTEST or Constants.STRATEGY.CHEAPEST
        LazyProf.db.profile.strategy = newStrategy
        self.frame.modeBtn.text:SetText(newStrategy == Constants.STRATEGY.CHEAPEST and "Cheapest" or "Fastest")
        -- Recalculate
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

    -- Update milestone panel in planning mode
    if self.currentPath and LazyProf.MilestonePanel then
        LazyProf.MilestonePanel:SetParentMode("planning", self.frame.contentArea)
        LazyProf.MilestonePanel:Update(self.currentPath.milestoneBreakdown, self.currentPath.totalCost)
        LazyProf:Debug(string.format("Loaded %s: %d steps, %s",
            profInfo.name, #self.currentPath.steps,
            Utils.FormatMoney(self.currentPath.totalCost)))
    end
end

function PlanningWindow:GetPlayerSkillLevel(profKey)
    -- For now, return 0 (treat as unlearned)
    -- TODO: Implement proper skill detection via GetProfessions() API
    return 0
end

function PlanningWindow:Hide()
    if self.frame then
        self.frame:Hide()
    end
    -- Reset milestone panel to normal mode
    if LazyProf.MilestonePanel then
        LazyProf.MilestonePanel:SetParentMode("tradeskill", nil)
        LazyProf.MilestonePanel:Hide()
    end
end

function PlanningWindow:IsVisible()
    return self.frame and self.frame:IsVisible()
end
