-- Modules/UI/ProfessionBrowser.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

LazyProf.ProfessionBrowser = {}
local Browser = LazyProf.ProfessionBrowser

Browser.frame = nil
Browser.rows = {}

local ROW_HEIGHT = 24
local ICON_SIZE = 20
local DROPDOWN_WIDTH = 180

-- Sorted profession keys for consistent order
local PROFESSION_ORDER = {
    "alchemy", "blacksmithing", "cooking", "enchanting", "engineering",
    "firstAid", "jewelcrafting", "leatherworking", "mining", "tailoring"
}

function Browser:Initialize()
    self.frame = CreateFrame("Frame", "LazyProfBrowser", UIParent, "BackdropTemplate")
    self.frame:SetSize(DROPDOWN_WIDTH, #PROFESSION_ORDER * ROW_HEIGHT + 16)
    self.frame:SetFrameStrata("DIALOG")
    self.frame:SetFrameLevel(200)

    self.frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    self.frame:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
    self.frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    self.frame:EnableMouse(true)
    self.frame:Hide()

    -- Create profession rows
    for i, profKey in ipairs(PROFESSION_ORDER) do
        local row = self:CreateProfessionRow(profKey, i)
        table.insert(self.rows, row)
    end

    -- Close when clicking outside
    self.frame:SetScript("OnShow", function()
        self.frame:SetScript("OnUpdate", function()
            if not self.frame:IsMouseOver() and not (LazyProfMinimapButton and LazyProfMinimapButton:IsMouseOver()) then
                if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                    self:Hide()
                end
            end
        end)
    end)

    self.frame:SetScript("OnHide", function()
        self.frame:SetScript("OnUpdate", nil)
    end)
end

function Browser:CreateProfessionRow(profKey, index)
    local profInfo = Constants.PROFESSIONS[profKey]
    if not profInfo then return end

    local row = CreateFrame("Button", nil, self.frame, "BackdropTemplate")
    row:SetSize(DROPDOWN_WIDTH - 8, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 4, -4 - (index - 1) * ROW_HEIGHT)

    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetBackdropColor(0, 0, 0, 0)

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture(profInfo.icon)

    -- Name
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetText(profInfo.name)
    row.text:SetTextColor(1, 1, 1)

    -- Check if profession is available in CraftLib
    local profData = LazyProf.Professions:Get(profKey)
    if not profData then
        row.text:SetTextColor(0.5, 0.5, 0.5)
        row:SetScript("OnEnter", function()
            row:SetBackdropColor(0.2, 0.2, 0.2, 0.5)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(profInfo.name, 1, 1, 1)
            GameTooltip:AddLine("Data not available", 1, 0.3, 0.3)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            row:SetBackdropColor(0, 0, 0, 0)
            GameTooltip:Hide()
        end)
    else
        row:SetScript("OnClick", function()
            self:Hide()
            if LazyProf.PlanningWindow then
                LazyProf.PlanningWindow:Open(profKey)
            end
        end)
        row:SetScript("OnEnter", function()
            row:SetBackdropColor(0.3, 0.3, 0.3, 0.8)
            row.text:SetTextColor(1, 0.82, 0)
        end)
        row:SetScript("OnLeave", function()
            row:SetBackdropColor(0, 0, 0, 0)
            row.text:SetTextColor(1, 1, 1)
        end)
    end

    row:Show()
    return row
end

function Browser:Toggle(anchorFrame)
    if not self.frame then
        self:Initialize()
    end

    if self.frame:IsVisible() then
        self:Hide()
    else
        self:Show(anchorFrame)
    end
end

function Browser:Show(anchorFrame)
    if not self.frame then
        self:Initialize()
    end

    if anchorFrame then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPRIGHT", anchorFrame, "BOTTOMLEFT", 0, 0)
    end

    self.frame:Show()
end

function Browser:Hide()
    if self.frame then
        self.frame:Hide()
    end
end
