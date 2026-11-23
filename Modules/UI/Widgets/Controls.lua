-- Modules/UI/Widgets/Controls.lua
-- Small stock controls for the LazyProf window, built from templates every
-- supported client has (WoW Forever: Blizzard UI source, 1.60.1,
-- Interface/AddOns/Blizzard_SharedXML: UIPanelButtonTemplate
-- Mainline/SharedUIPanelTemplates.xml:315, UICheckButtonTemplate
-- Shared/Button/CheckButtonTemplates.xml:50, InputBoxTemplate
-- Shared/InputBox/InputBoxTemplates.xml:70; SetResizeBounds, SetButtonState,
-- LockHighlight, SetHitRectInsets, SetChecked, SetNumeric and SetMaxLetters
-- are in the client's widget API dump). No family split is needed here.
--
--   Widgets.SetResizeBounds(frame, minW, minH, maxW, maxH)
--   Widgets.CreateResizeGrip(frame, onDone)
--   Widgets.CreateButtonGroup(parent, options, onSelect)   options: { text, value, width, tooltip }
--   Widgets.CreateNumericInput(parent, name, width, maxLetters, onCommit)
--   Widgets.CreateCheckbox(parent, name, label, onChange)
--   Widgets.CreateSearchBox(parent, name, placeholder, onChange)
local ADDON_NAME, LazyProf = ...

LazyProf.Widgets = LazyProf.Widgets or {}
local Widgets = LazyProf.Widgets

local function Sound(key)
    if PlaySound and SOUNDKIT and SOUNDKIT[key] then
        PlaySound(SOUNDKIT[key])
    end
end

local function ShowTextTooltip(owner, title, text)
    if not title then return end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(title)
    if text then
        GameTooltip:AddLine(text, 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

-- Resize limits: newer clients have one call, older ones a pair.
function Widgets.SetResizeBounds(frame, minW, minH, maxW, maxH)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(minW, minH, maxW, maxH)
    else
        frame:SetMinResize(minW, minH)
        frame:SetMaxResize(maxW, maxH)
    end
end

-- The bottom-right resize grip. onDone() runs when the user lets go.
function Widgets.CreateResizeGrip(frame, onDone)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(32, 32)
    grip:SetPoint("BOTTOMRIGHT", 0, 0)
    -- A nearly invisible texture so the whole corner takes the click
    grip:SetNormalTexture("Interface\\Buttons\\WHITE8x8")
    grip:GetNormalTexture():SetVertexColor(0, 0, 0, 0.01)
    grip.icon = grip:CreateTexture(nil, "OVERLAY")
    grip.icon:SetPoint("BOTTOMRIGHT", 0, 0)
    grip.icon:SetSize(16, 16)
    grip.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        if onDone then onDone() end
    end)
    return grip
end

-- Two or three stock buttons in a row, one of them shown selected: held in
-- its pushed state with its highlight on and white text, while the others
-- are dimmed. Clicking another selects it and calls onSelect(value).
local ButtonGroup = {}
ButtonGroup.__index = ButtonGroup

-- The stock panel button has no pushed texture of its own: its three art
-- pieces (Left / Middle / Right) are swapped to the "down" art while the
-- mouse is held and back to "up" on release and on show (WoW Forever:
-- Blizzard_SharedXML/SecureUIPanelTemplates.lua:44-67). The selected button
-- is therefore given the "down" art here, again after each of those.
local BUTTON_UP = "Interface\\Buttons\\UI-Panel-Button-Up"
local BUTTON_DOWN = "Interface\\Buttons\\UI-Panel-Button-Down"
-- The pressed art alone does not tell the two apart at a glance, so the
-- selected button also gets the white font and the others are dimmed
-- (generic calls: SetNormalFontObject, WoW Forever Blizzard_APIDocumentationGenerated/
-- SimpleButtonAPIDocumentation.lua:423; SetAlpha, SimpleRegionAPIDocumentation.lua:123;
-- font objects GameFontHighlight / GameFontNormal,
-- Blizzard_Fonts_Shared/Shared/FontStyles.xml:62, 50).
local SELECTED_FONT = "GameFontHighlight"
local UNSELECTED_FONT = "GameFontNormal"
local UNSELECTED_ALPHA = 0.55

local function ApplyButtonArt(button, selected)
    if selected then
        button:SetButtonState("PUSHED", true)
        button:LockHighlight()
    else
        button:SetButtonState("NORMAL")
        button:UnlockHighlight()
    end
    local font = selected and SELECTED_FONT or UNSELECTED_FONT
    button:SetNormalFontObject(_G[font] or font)
    button:SetAlpha(selected and 1 or UNSELECTED_ALPHA)
    local art = selected and BUTTON_DOWN or BUTTON_UP
    for _, key in ipairs({ "Left", "Middle", "Right" }) do
        local piece = rawget(button, key)
        if type(piece) == "table" and piece.SetTexture then
            piece:SetTexture(art)
        end
    end
end

function ButtonGroup:SetSelected(value)
    self.selected = value
    for _, button in ipairs(self.list) do
        ApplyButtonArt(button, button.value == value)
    end
end

function ButtonGroup:GetSelected()
    return self.selected
end

function ButtonGroup:SetPoint(...)
    self.frame:SetPoint(...)
end

function Widgets.CreateButtonGroup(parent, options, onSelect)
    local group = setmetatable({ buttons = {}, list = {} }, ButtonGroup)
    group.frame = CreateFrame("Frame", nil, parent)
    local x = 0
    for _, option in ipairs(options) do
        local button = CreateFrame("Button", nil, group.frame, "UIPanelButtonTemplate")
        local width = option.width or 70
        button:SetSize(width, 22)
        button:SetPoint("LEFT", group.frame, "LEFT", x, 0)
        button:SetText(option.text)
        button.value = option.value
        button:SetScript("OnClick", function()
            if group.selected == option.value then
                group:SetSelected(option.value)   -- the click released it; hold it again
                return
            end
            group:SetSelected(option.value)
            Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
            onSelect(option.value)
        end)
        button:SetScript("OnEnter", function(self) ShowTextTooltip(self, option.tooltip and option.text, option.tooltip) end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- The template puts the "up" art back on release and on show.
        local function reapply(self) ApplyButtonArt(self, group.selected == option.value) end
        button:HookScript("OnMouseUp", reapply)
        button:HookScript("OnShow", reapply)
        group.buttons[option.value] = button
        group.list[#group.list + 1] = button
        x = x + width
    end
    group.frame:SetSize(x, 22)
    return group
end

-- A small number box. onCommit(number) runs on Enter or when the box loses
-- focus with a changed number; what it returns (a corrected value) is shown.
-- Escape puts the last value back.
local NumericInput = {}
NumericInput.__index = NumericInput

function NumericInput:SetValue(value)
    self.value = value
    self.frame:SetText(value ~= nil and tostring(value) or "")
end

function NumericInput:GetValue()
    return self.value
end

function NumericInput:SetPoint(...)
    self.frame:SetPoint(...)
end

function Widgets.CreateNumericInput(parent, name, width, maxLetters, onCommit)
    local input = setmetatable({}, NumericInput)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    input.frame = box
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(maxLetters or 4)

    local function commit()
        local typed = tonumber(box:GetText())
        if not typed then
            input:SetValue(input.value)
            return
        end
        if typed == input.value then return end
        local corrected = onCommit(typed)
        input:SetValue(corrected or typed)
    end
    box:SetScript("OnEnterPressed", function(self)
        commit()
        self:ClearFocus()
    end)
    box:SetScript("OnEscapePressed", function(self)
        input:SetValue(input.value)
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", function()
        commit()
    end)
    return input
end

-- A check button with its own label (the template's label key differs
-- between clients). onChange(checked) runs on a click.
local Checkbox = {}
Checkbox.__index = Checkbox

function Checkbox:SetChecked(checked)
    self.frame:SetChecked(checked and true or false)
end

function Checkbox:GetChecked()
    return self.frame:GetChecked() and true or false
end

function Checkbox:SetLabel(text)
    self.label:SetText(text)
    -- The label is part of the click area
    self.frame:SetHitRectInsets(0, -(self.label:GetStringWidth() + 4), 0, 0)
end

function Checkbox:SetPoint(...)
    self.frame:SetPoint(...)
end

function Checkbox:SetShown(shown)
    if shown then self.frame:Show() else self.frame:Hide() end
end

function Widgets.CreateCheckbox(parent, name, label, onChange, tooltip)
    local box = setmetatable({}, Checkbox)
    local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    box.frame = check
    check:SetSize(24, 24)
    box.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    box.label:SetPoint("LEFT", check, "RIGHT", 0, 1)
    box:SetLabel(label)
    check:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        Sound(checked and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        onChange(checked)
    end)
    check:SetScript("OnEnter", function(self) ShowTextTooltip(self, tooltip and label, tooltip) end)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return box
end

-- A text box with a grey hint while empty and a clear button. onChange(text)
-- runs as the player types (not for text set by code).
local SearchBox = {}
SearchBox.__index = SearchBox

function SearchBox:SetText(text)
    self.frame:SetText(text or "")
end

function SearchBox:GetText()
    return self.frame:GetText() or ""
end

function SearchBox:ClearFocus()
    self.frame:ClearFocus()
end

function Widgets.CreateSearchBox(parent, name, placeholder, onChange)
    local search = setmetatable({}, SearchBox)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    search.frame = box
    box:SetHeight(20)
    box:SetAutoFocus(false)
    box:SetFontObject(_G.GameFontHighlightSmall or "GameFontHighlightSmall")
    box:SetMaxLetters(50)

    search.hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    search.hint:SetPoint("LEFT", box, "LEFT", 4, 0)
    search.hint:SetText(placeholder or "")

    local clear = CreateFrame("Button", nil, box)
    search.clear = clear
    clear:SetSize(18, 18)
    clear:SetPoint("RIGHT", box, "RIGHT", -2, 0)
    clear.text = clear:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clear.text:SetPoint("CENTER")
    clear.text:SetText("x")
    clear:Hide()
    clear:SetScript("OnClick", function()
        box:SetText("")
        box:ClearFocus()
        onChange("")
    end)

    box:SetScript("OnTextChanged", function(self, userInput)
        local text = self:GetText() or ""
        search.hint:SetShown(text == "")
        clear:SetShown(text ~= "")
        if userInput then
            onChange(text)
        end
    end)
    box:SetScript("OnEscapePressed", function(self)
        if (self:GetText() or "") ~= "" then
            self:SetText("")
            onChange("")
        end
        self:ClearFocus()
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return search
end
