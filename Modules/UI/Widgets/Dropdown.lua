-- Modules/UI/Widgets/Dropdown.lua
-- One dropdown for every client. The kind is chosen once, at load, from
-- LazyProf.ClientFamily:
--   classic - UIDropDownMenuTemplate + UIDropDownMenu_* (what the panels used
--             before this widget existed, unchanged).
--   forever - a DropdownButton (WowStyle1DropdownTemplate) filled through
--             SetupMenu with one radio per option.
--
--   local dd = LazyProf.Widgets.CreateDropdown(parent, name, width)
--   dd:SetOptions(getOptions, onSelect)
--       getOptions() returns { { text = s, value = v, checked = bool }, ... };
--       { separator = true } is a blank, unselectable line. It is called each
--       time the menu is built (Classic: on Initialize and each open; Forever:
--       each open), so checked always reflects the current state.
--       onSelect(value, option) runs when the user picks an option. It should
--       call dd:SetText itself: the shown text is never derived from the radios.
--   dd:SetText(text)
--   dd:SetPoint(...), dd:ClearAllPoints(), dd:Show(), dd:Hide(), dd:IsShown()
--       A dropdown passed as the relative frame of SetPoint stands for its frame.
--   dd.frame - the frame to position, show and hide.
--
-- Layout: call sites keep one set of offsets for both clients. On Classic the
-- frame is the UIDropDownMenu frame, whose art sits inside a transparent
-- margin (frame width = width + 2 * 25). On Forever dd.frame is a plain frame
-- of that same size and the DropdownButton sits inside it where the Classic
-- art would be, so offsets written for the Classic frame line up on both.
local ADDON_NAME, LazyProf = ...

LazyProf.Widgets = LazyProf.Widgets or {}
local Widgets = LazyProf.Widgets

-- Classic template geometry the Forever frame copies (UIDropDownMenuTemplate:
-- 32 high; UIDropDownMenu_SetWidth adds 25 on each side of the given width).
local CLASSIC_HEIGHT = 32
local CLASSIC_SIDE_PADDING = 25
-- Where the Classic art starts inside that margin, on each side. Measured from
-- the template textures, not from a Forever client: check in game.
local CLASSIC_ART_INSET = 16

local Dropdown = {}
Dropdown.__index = Dropdown

local function Unwrap(region)
    if type(region) == "table" and region.isLazyProfDropdown then
        return region.frame
    end
    return region
end

function Dropdown:SetPoint(point, relativeTo, ...)
    self.frame:SetPoint(point, Unwrap(relativeTo), ...)
end

function Dropdown:ClearAllPoints()
    self.frame:ClearAllPoints()
end

function Dropdown:Show()
    self.frame:Show()
end

function Dropdown:Hide()
    self.frame:Hide()
end

function Dropdown:IsShown()
    return self.frame:IsShown()
end

-- Classic ---------------------------------------------------------------------

local ClassicDropdown = setmetatable({}, { __index = Dropdown })
ClassicDropdown.__index = ClassicDropdown

local function CreateClassic(parent, name, width)
    local frame = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(frame, width)
    return setmetatable({ frame = frame, isLazyProfDropdown = true }, ClassicDropdown)
end

function ClassicDropdown:SetOptions(getOptions, onSelect)
    UIDropDownMenu_Initialize(self.frame, function(_, level)
        for _, option in ipairs(getOptions()) do
            local info = UIDropDownMenu_CreateInfo()
            if option.separator then
                info.disabled = true
                info.notCheckable = true
            else
                info.text = option.text
                info.value = option.value
                info.checked = option.checked and true or false
                info.func = function()
                    onSelect(option.value, option)
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
end

function ClassicDropdown:SetText(text)
    UIDropDownMenu_SetText(self.frame, text)
end

-- Forever ---------------------------------------------------------------------

local ForeverDropdown = setmetatable({}, { __index = Dropdown })
ForeverDropdown.__index = ForeverDropdown

local function CreateForever(parent, name, width)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width + 2 * CLASSIC_SIDE_PADDING, CLASSIC_HEIGHT)
    local button = CreateFrame("DropdownButton", name, frame, "WowStyle1DropdownTemplate")
    button:SetPoint("LEFT", frame, "LEFT", CLASSIC_ART_INSET, 0)
    button:SetPoint("RIGHT", frame, "RIGHT", -CLASSIC_ART_INSET, 0)
    return setmetatable({ frame = frame, button = button, isLazyProfDropdown = true }, ForeverDropdown)
end

function ForeverDropdown:SetOptions(getOptions, onSelect)
    self.button:SetupMenu(function(_, root)
        for _, option in ipairs(getOptions()) do
            if option.separator then
                root:CreateDivider()
            else
                local checked = option.checked and true or false
                root:CreateRadio(option.text,
                    function() return checked end,
                    function() onSelect(option.value, option) end,
                    option.value)
            end
        end
    end)
end

function ForeverDropdown:SetText(text)
    -- The text is always ours (the caller's own wording), never a radio's label.
    self.button:OverrideText(text)
end

-- Chosen once -----------------------------------------------------------------

local create = (LazyProf.ClientFamily == "forever") and CreateForever or CreateClassic

function Widgets.CreateDropdown(parent, name, width)
    return create(parent, name, width)
end
