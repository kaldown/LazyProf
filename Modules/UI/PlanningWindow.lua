-- Modules/UI/PlanningWindow.lua
-- Standalone planning window for viewing any profession's leveling path
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils
local Constants = LazyProf.Constants

LazyProf.PlanningWindow = {}
local PlanningWindow = LazyProf.PlanningWindow

PlanningWindow.frame = nil
PlanningWindow.currentProfession = nil
PlanningWindow.currentPath = nil
PlanningWindow.milestonePanel = nil  -- Embedded MilestonePanel instance

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

    -- Container frame for embedded MilestonePanel
    self.frame.contentContainer = CreateFrame("Frame", nil, self.frame)
    self.frame.contentContainer:SetPoint("TOPLEFT", 4, -62)
    self.frame.contentContainer:SetPoint("BOTTOMRIGHT", -4, 4)

    -- Create embedded MilestonePanel instance (with bracket dropdown and mode toggle)
    self.milestonePanel = LazyProf.MilestonePanelClass:New({
        name = "Planning",
        embedded = true,
        showBracketDropdown = true,
        showModeToggle = true,
        parent = self.frame.contentContainer
    })
    self.milestonePanel:Initialize()

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
        -- Refresh the embedded panel after resize
        if self.milestonePanel then
            self.milestonePanel:Refresh()
        end
    end)

    -- Make closable with Escape
    tinsert(UISpecialFrames, "LazyProfPlanningWindow")
end

function PlanningWindow:Open(profKey)
    if not self.frame then
        self:Initialize()
    end

    -- Show the main frame FIRST so child frames can become visible
    self.frame:Show()
    -- Then load the profession (which updates the embedded MilestonePanel)
    self:LoadProfession(profKey)
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

    -- Check if player has this profession
    local actualSkillLevel = self:GetPlayerSkillLevel(profKey)

    -- Determine starting skill based on calculateFromCurrentSkill setting
    local startSkill
    if LazyProf.db.profile.calculateFromCurrentSkill then
        startSkill = actualSkillLevel
    else
        startSkill = 0  -- CalculateForProfession will use max(1, skillLevel)
    end

    -- Check for racial bonus
    local racialBonus = Utils.GetRacialProfessionBonus(profKey)
    local racialText = ""
    if racialBonus > 0 then
        local race = Utils.GetPlayerRace()
        racialText = string.format(" |cFFFFD700(+%d %s)|r", racialBonus, race)
    end

    -- Update status bar with mode indicator and racial bonus
    if actualSkillLevel > 0 then
        if LazyProf.db.profile.calculateFromCurrentSkill then
            self.frame.status:SetText(string.format("Path from current skill: %d%s", actualSkillLevel, racialText))
        else
            self.frame.status:SetText(string.format("Current skill: %d%s |cFF888888(showing full path)|r", actualSkillLevel, racialText))
        end
        self.frame.status:SetTextColor(0.4, 1, 0.4)
    else
        if racialBonus > 0 then
            self.frame.status:SetText(string.format("You have not learned this profession%s |cFF888888(showing full path)|r", racialText))
        else
            self.frame.status:SetText("You have not learned this profession |cFF888888(showing full path)|r")
        end
        self.frame.status:SetTextColor(0.7, 0.7, 0.7)
    end

    -- Calculate path
    LazyProf:Debug("ui", "=== PlanningWindow:LoadProfession ===")
    LazyProf:Debug("ui", "  profKey: " .. tostring(profKey))
    LazyProf:Debug("ui", "  startSkill: " .. tostring(startSkill))

    self.currentPath = LazyProf.Pathfinder:CalculateForProfession(profKey, startSkill)

    LazyProf:Debug("ui", "  currentPath: " .. (self.currentPath and "exists" or "NIL"))
    if self.currentPath then
        LazyProf:Debug("ui", "  currentPath.milestoneBreakdown: " .. (self.currentPath.milestoneBreakdown and ("#" .. #self.currentPath.milestoneBreakdown .. " steps") or "NIL"))
    end
    LazyProf:Debug("ui", "  milestonePanel: " .. (self.milestonePanel and "exists" or "NIL"))
    if self.milestonePanel then
        LazyProf:Debug("ui", "  milestonePanel.frame: " .. (self.milestonePanel.frame and "exists" or "NIL"))
    end

    -- Update the embedded MilestonePanel
    if self.currentPath and self.milestonePanel then
        LazyProf:Debug("ui", "  Calling milestonePanel:Update()")
        self.milestonePanel:Update(self.currentPath)
        LazyProf:Debug("ui", "  After Update - frame visible: " .. tostring(self.milestonePanel.frame and self.milestonePanel.frame:IsVisible()))
    else
        LazyProf:Debug("ui", "  SKIPPED Update - missing path or panel")
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

function PlanningWindow:Hide()
    if self.frame then
        self.frame:Hide()
    end
    if self.milestonePanel then
        self.milestonePanel:Hide()
    end
end

function PlanningWindow:IsVisible()
    return self.frame and self.frame:IsVisible()
end
