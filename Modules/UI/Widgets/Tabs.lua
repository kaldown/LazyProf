-- Modules/UI/Widgets/Tabs.lua
-- Bottom tabs for a window, one implementation per client family, chosen once
-- at load (like the dropdown widget).
--
--   local tabs = LazyProf.Widgets.CreateTabs(frame, { "Guide", "Steps" }, onSelect)
--   tabs:Select(index)       show a tab as selected (does not call onSelect)
--   tabs:GetSelected()
--   tabs.buttons[index]
--   onSelect(index) runs when the player clicks a tab.
--
-- The window must have a global name: the stock tab helpers find tab i as
-- <FrameName>Tab<i>. The helpers keep the tab count and the selected tab in
-- frame.numTabs / frame.selectedTab.
--
-- forever - PanelTabButtonTemplate driven by PanelTemplates_SetNumTabs /
--   PanelTemplates_SetTab (Blizzard UI source 1.60.1, Interface/AddOns/
--   Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:932 and
--   SharedUIPanelTemplates.lua:441, 542). SetNumTabs anchors tabs 2..n to the
--   tab before them itself (:557-563), so only tab 1 is anchored here, where
--   Blizzard puts it under a framed window
--   (Blizzard_InspectUI/Camelot/Blizzard_InspectUI.xml:17). The character-
--   frame tab template of the Classic clients is not loaded on this client.
-- classic - CharacterFrameTabButtonTemplate, the Classic clients' own tab.
--   Whether their SetNumTabs anchors the tabs is not confirmed, so every tab
--   is anchored here and only the select / resize helpers are used, each
--   guarded.
local ADDON_NAME, LazyProf = ...

LazyProf.Widgets = LazyProf.Widgets or {}
local Widgets = LazyProf.Widgets

local Tabs = {}
Tabs.__index = Tabs

function Tabs:GetSelected()
    return self.selected
end

local function OnTabClick(tabs, index)
    if tabs.selected == index then return end
    tabs:Select(index)
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    end
    tabs.onSelect(index)
end

local function MakeButtons(tabs, frame, labels, template)
    local name = frame:GetName()
    assert(name, "a window with tabs needs a global name")
    for i, label in ipairs(labels) do
        local button = CreateFrame("Button", name .. "Tab" .. i, frame, template)
        button:SetID(i)
        button:SetText(label)
        button:SetScript("OnClick", function() OnTabClick(tabs, i) end)
        tabs.buttons[i] = button
    end
end

-- Forever -----------------------------------------------------------------

local ForeverTabs = setmetatable({}, { __index = Tabs })
ForeverTabs.__index = ForeverTabs

local function CreateForever(frame, labels, onSelect)
    local tabs = setmetatable({ frame = frame, buttons = {}, onSelect = onSelect }, ForeverTabs)
    MakeButtons(tabs, frame, labels, "PanelTabButtonTemplate")
    tabs.buttons[1]:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2)
    PanelTemplates_SetNumTabs(frame, #labels)
    return tabs
end

function ForeverTabs:Select(index)
    self.selected = index
    PanelTemplates_SetTab(self.frame, index)
end

-- Classic -----------------------------------------------------------------

local ClassicTabs = setmetatable({}, { __index = Tabs })
ClassicTabs.__index = ClassicTabs

local function CreateClassic(frame, labels, onSelect)
    local tabs = setmetatable({ frame = frame, buttons = {}, onSelect = onSelect }, ClassicTabs)
    MakeButtons(tabs, frame, labels, "CharacterFrameTabButtonTemplate")
    frame.numTabs = #labels
    for i, button in ipairs(tabs.buttons) do
        if i == 1 then
            button:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2)
        else
            button:SetPoint("LEFT", tabs.buttons[i - 1], "RIGHT", -16, 0)
        end
        if PanelTemplates_TabResize then
            PanelTemplates_TabResize(button, 0)
        end
    end
    return tabs
end

function ClassicTabs:Select(index)
    self.selected = index
    if PanelTemplates_SetTab then
        PanelTemplates_SetTab(self.frame, index)
    end
end

-- Chosen once ---------------------------------------------------------------

local create = (LazyProf.ClientFamily == "forever") and CreateForever or CreateClassic

function Widgets.CreateTabs(frame, labels, onSelect)
    local tabs = create(frame, labels, onSelect)
    tabs:Select(1)
    return tabs
end
