-- Modules/UI/MinimapButton.lua
local ADDON_NAME, LazyProf = ...

LazyProf.MinimapButton = {}
local MinimapButton = LazyProf.MinimapButton

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

MinimapButton.dataObject = nil

-- WoW Forever has the addon compartment (TOC AddonCompartmentFunc) instead of
-- a LibDBIcon minimap button.
local function UsesCompartment()
    return LazyProf.ClientFamily == "forever"
end

-- Left click: profession browser (anchored to the clicked frame); right
-- click: settings. Shared by the minimap button and the addon compartment.
function MinimapButton:OnClick(anchor, button)
    if InCombatLockdown() then return end
    if button == "LeftButton" then
        if LazyProf.ProfessionBrowser then
            LazyProf.ProfessionBrowser:Toggle(anchor)
        end
    elseif button == "RightButton" then
        if LazyProf.configRegistered then
            LibStub("AceConfigDialog-3.0"):Open("LazyProf")
        end
    end
end

-- Named by the TOC's AddonCompartmentFunc; the compartment calls it as
-- func(addonName, buttonName) (Blizzard_Minimap/Mainline/AddonCompartment.lua:113-128).
-- The compartment button itself is AddonCompartmentFrame
-- (Blizzard_Minimap/Camelot/AddonCompartment.xml:3).
function LazyProf_OnAddonCompartmentClick(addonName, buttonName)
    if LazyProf.dependencyCheckFailed then return end
    MinimapButton:OnClick(AddonCompartmentFrame, buttonName)
end

function MinimapButton:Initialize()
    -- Create the data broker object
    self.dataObject = LDB:NewDataObject("LazyProf", {
        type = "launcher",
        icon = "Interface\\AddOns\\LazyProf\\icon",
        OnClick = function(frame, button)
            MinimapButton:OnClick(frame, button)
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("LazyProf", 1, 0.82, 0)
            tooltip:AddLine(" ")
            tooltip:AddLine("|cFFFFFFFFLeft-click:|r Browse professions", 0.7, 0.7, 0.7)
            tooltip:AddLine("|cFFFFFFFFRight-click:|r Open settings", 0.7, 0.7, 0.7)
        end,
    })

    -- Register with LibDBIcon (not on Forever: the compartment entry is the
    -- launcher there)
    if not UsesCompartment() then
        LDBIcon:Register("LazyProf", self.dataObject, LazyProf.db.profile.minimap)
    end
end

function MinimapButton:Show()
    if UsesCompartment() then return end
    LDBIcon:Show("LazyProf")
end

function MinimapButton:Hide()
    if UsesCompartment() then return end
    LDBIcon:Hide("LazyProf")
end

function MinimapButton:IsVisible()
    return not LazyProf.db.profile.minimap.hide
end
