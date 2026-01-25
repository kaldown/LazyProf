-- Modules/UI/MinimapButton.lua
local ADDON_NAME, LazyProf = ...

LazyProf.MinimapButton = {}
local MinimapButton = LazyProf.MinimapButton

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

MinimapButton.dataObject = nil

function MinimapButton:Initialize()
    -- Create the data broker object
    self.dataObject = LDB:NewDataObject("LazyProf", {
        type = "launcher",
        icon = "Interface\\AddOns\\LazyProf\\icon",
        OnClick = function(_, button)
            if button == "LeftButton" then
                if LazyProf.ProfessionBrowser then
                    LazyProf.ProfessionBrowser:Toggle(LazyProfMinimapButton)
                end
            elseif button == "RightButton" then
                if LazyProf.configRegistered then
                    LibStub("AceConfigDialog-3.0"):Open("LazyProf")
                end
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("LazyProf", 1, 0.82, 0)
            tooltip:AddLine(" ")
            tooltip:AddLine("|cFFFFFFFFLeft-click:|r Browse professions", 0.7, 0.7, 0.7)
            tooltip:AddLine("|cFFFFFFFFRight-click:|r Open settings", 0.7, 0.7, 0.7)
        end,
    })

    -- Register with LibDBIcon
    LDBIcon:Register("LazyProf", self.dataObject, LazyProf.db.profile.minimap)
end

function MinimapButton:Show()
    LDBIcon:Show("LazyProf")
end

function MinimapButton:Hide()
    LDBIcon:Hide("LazyProf")
end

function MinimapButton:IsVisible()
    return not LazyProf.db.profile.minimap.hide
end
