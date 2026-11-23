-- Modules/UI/Widgets/Slider.lua
-- A horizontal slider over whole numbers that tells moving the handle from
-- letting it go, one implementation per client family, chosen once at load
-- (like the tabs and the dropdown).
--
--   local slider = LazyProf.Widgets.CreateSlider(parent, name, {
--       onChanging = function(value) end,   -- every new value while the player moves the handle
--       onReleased = function(value) end,   -- once, when the handle is let go at a new value
--   })
--   slider.frame                       the frame to anchor and size
--   slider:SetPoint(...)
--   slider:SetRange(min, max, value)   silent; does nothing while the handle is held
--   slider:SetValue(value)             silent; does nothing while the handle is held
--   slider:GetValue()
--   slider:SetEnabled(on)
--   slider:IsHeld()                    the player has the handle
--
-- Values set from code call neither callback. A range with no room
-- (max <= min) disables the slider; the frame is then given a one-point range
-- ending at the larger number, never an empty or an inverted one.
--
-- "Held" is a mouse button pressed on the slider and not yet let go, or the
-- client saying the handle is being dragged. A hold ends on mouse-up. It also
-- ends, like a release, once no mouse button is down any more: the button may
-- be let go where the slider runs no script for it. That is noticed the next
-- time the slider is asked or told something (IsHeld, SetRange, SetValue), so
-- an owner that redraws asks first (IsHeld) and draws what the commit brings.
-- A hold is dropped, with nothing committed, when the slider goes out of
-- sight. A value that arrives from the player with nothing held is committed
-- at once.
--
-- forever - the bare MinimalSliderTemplate: a Slider frame, 200 x 19, its
--   handle under the key Thumb, whole steps obeyed while dragging (Blizzard
--   UI source 1.60.1, Interface/AddOns/Blizzard_SharedXML/Shared/Slider/
--   MinimalSlider.xml:3-32, MinimalSlider.lua:6-8). Not the stepper template
--   that wraps it (:34): its OnInteractStart / OnInteractEnd follow hover and
--   press together (MinimalSlider.lua:45-48, 144-158), so they do not say
--   when the handle is let go, and its stepper buttons would commit on every
--   click. Blizzard sets OnMouseDown / OnMouseUp on this very slider and
--   asks IsEnabled inside them (MinimalSlider.lua:62-75), sets
--   OnValueChanged on it (:141) and asks IsDraggingThumb of it to leave a
--   dragged slider alone (Blizzard_EditMode/Shared/EditModeDialogs.lua:583).
--   Slider calls: Blizzard_APIDocumentationGenerated/
--   SimpleSliderAPIDocumentation.lua (SetMinMaxValues :154, SetValueStep
--   :217, SetValue :206, SetEnabled :144, IsEnabled :131, IsDraggingThumb
--   :118); IsVisible: SimpleScriptRegionAPIDocumentation.lua:582; SetAlpha:
--   SimpleRegionAPIDocumentation.lua:123. The scripts are in the client's
--   list of frame scripts (Blizzard_SharedXML/UI.xsd:403, 406, 407, 420).
--   IsMouseButtonDown() without a button asks for any button
--   (Blizzard_APIDocumentationGenerated/InputDocumentation.lua:185-198);
--   Blizzard polls it to end a drag whose release it did not hear
--   (Blizzard_Console/Blizzard_Console.lua:308,
--   Blizzard_SharedXML/Mainline/ModelControlButtonMixin.lua:167, and with a
--   button named in its older scroll buttons).
--   Whether the value-changed script tells a player's change from one made
--   by code is not relied on: this widget marks its own changes itself.
-- classic - a plain Slider frame with a track of its own (light grey, a thin
--   dark edge) and the stock horizontal thumb; base widget calls only. Not
--   seen on a client.
local ADDON_NAME, LazyProf = ...

LazyProf.Widgets = LazyProf.Widgets or {}
local Widgets = LazyProf.Widgets

local DISABLED_ALPHA = 0.5

local Slider = {}
Slider.__index = Slider

local function Round(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

-- The client's own answer to "is the handle being dragged". (Looked up
-- first: a Classic client's slider may not have the call.)
local function Dragging(frame)
    return frame.IsDraggingThumb ~= nil and frame:IsDraggingThumb() and true or false
end

-- No mouse button is down. (Looked up first: a client without the call
-- cannot say, and a hold then lasts until its mouse-up.)
local function NoButtonDown()
    return type(IsMouseButtonDown) == "function" and not IsMouseButtonDown()
end

function Slider:SetPoint(...)
    self.frame:SetPoint(...)
end

function Slider:GetValue()
    return self.value
end

-- Tell the owner the value the handle was let go at, once per value.
local function Commit(slider)
    if slider.value == slider.committed then return end
    slider.committed = slider.value
    if slider.onReleased then slider.onReleased(slider.value) end
end

-- The hold is over: commit where the handle is. While the owner is told, the
-- slider does not count as held, whatever the client still says about the
-- handle: the owner redraws from inside the release.
local function Release(slider)
    slider.held = false
    slider.releasing = true
    Commit(slider)
    slider.releasing = false
end

-- The player has the handle. A hold only counts while the slider can be
-- seen: hidden mid-drag (combat, the window closing), no mouse-up may follow.
-- And it is over once no mouse button is down and the client no longer calls
-- the handle dragged, although no mouse-up was heard: it then ends here, like
-- a release.
function Slider:IsHeld()
    local frame = self.frame
    if self.held and not frame:IsVisible() then
        self.held = false
    end
    if self.releasing then return false end
    local dragging = Dragging(frame)
    if self.held and not dragging and NoButtonDown() then
        Release(self)
    end
    return self.held or dragging
end

local function ApplyEnabled(slider)
    local on = slider.wanted and slider.room
    slider.frame:SetEnabled(on)
    slider.frame:SetAlpha(on and 1 or DISABLED_ALPHA)
end

function Slider:SetEnabled(on)
    self.wanted = on and true or false
    ApplyEnabled(self)
end

-- Put the handle at a value without telling anyone.
local function SetSilently(slider, value)
    slider.value, slider.committed = value, value
    slider.silent = true
    slider.frame:SetValue(value)
    slider.silent = false
end

function Slider:SetRange(min, max, value)
    if self:IsHeld() then return end
    min, max = Round(min), Round(max)
    self.room = max > min
    if not self.room then
        -- Nothing to choose: a one-point range with the handle at its end.
        max = math.max(min, max)
        min = max - 1
        value = max
    end
    self.min, self.max = min, max
    self.silent = true
    self.frame:SetMinMaxValues(min, max)
    self.silent = false
    SetSilently(self, math.max(min, math.min(max, Round(value or min))))
    ApplyEnabled(self)
end

function Slider:SetValue(value)
    if self:IsHeld() then return end
    SetSilently(self, math.max(self.min, math.min(self.max, Round(value))))
end

-- The scripts both families share. Anything the frame reports while this
-- widget is not setting a value itself comes from the player.
local function Wire(slider)
    local frame = slider.frame
    frame:SetScript("OnValueChanged", function(_, raw)
        if slider.silent then return end
        local value = Round(raw)
        -- Nothing new: the same whole number again, or a value this widget
        -- set a moment ago.
        if value == slider.value then return end
        slider.value = value
        if slider.onChanging then slider.onChanging(value) end
        if not slider:IsHeld() then
            Commit(slider)
        end
    end)
    -- Any mouse button: whichever one the client moves the handle for, its
    -- press holds and its release commits.
    frame:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then
            slider.held = true
        end
    end)
    frame:SetScript("OnMouseUp", function()
        Release(slider)
    end)
    -- Out of sight mid-drag: the hold is over and the value it reached is
    -- dropped (the next SetRange puts the handle back).
    frame:SetScript("OnHide", function()
        slider.held = false
        slider.value = slider.committed
    end)
end

local function New(frame, opts)
    opts = opts or {}
    local slider = setmetatable({
        frame = frame, onChanging = opts.onChanging, onReleased = opts.onReleased,
        held = false, releasing = false, silent = false, wanted = true, room = false,
        min = 0, max = 1, value = 0, committed = 0,
    }, Slider)
    frame:SetValueStep(1)
    Wire(slider)
    return slider
end

-- Forever -----------------------------------------------------------------

local function CreateForever(parent, name, opts)
    -- The template sizes the frame, draws the track and the handle and turns
    -- on whole steps while dragging.
    return New(CreateFrame("Slider", name, parent, "MinimalSliderTemplate"), opts)
end

-- Classic -----------------------------------------------------------------

local TRACK = "Interface\\Buttons\\WHITE8x8"
local TRACK_HEIGHT = 6
local THUMB = "Interface\\Buttons\\UI-SliderBar-Button-Horizontal"

local function CreateClassic(parent, name, opts)
    local frame = CreateFrame("Slider", name, parent)
    frame:SetOrientation("HORIZONTAL")
    frame:SetSize(200, 17)
    frame:EnableMouse(true)
    frame:SetThumbTexture(THUMB)
    local thumb = frame:GetThumbTexture()
    if thumb then
        thumb:SetSize(32, 32)
    end
    if frame.SetObeyStepOnDrag then
        frame:SetObeyStepOnDrag(true)
    end
    local slider = New(frame, opts)
    -- A light grey track with a thin dark edge under it: a dark track is lost
    -- on the window's dark backdrop.
    slider.trackEdge = frame:CreateTexture(nil, "BACKGROUND")
    slider.trackEdge:SetTexture(TRACK)
    slider.trackEdge:SetVertexColor(0.05, 0.05, 0.05, 0.9)
    slider.trackEdge:SetHeight(TRACK_HEIGHT + 2)
    slider.trackEdge:SetPoint("LEFT", -1, 0)
    slider.trackEdge:SetPoint("RIGHT", 1, 0)
    slider.track = frame:CreateTexture(nil, "BORDER")
    slider.track:SetTexture(TRACK)
    slider.track:SetVertexColor(0.35, 0.35, 0.35, 0.9)
    slider.track:SetHeight(TRACK_HEIGHT)
    slider.track:SetPoint("LEFT", 0, 0)
    slider.track:SetPoint("RIGHT", 0, 0)
    return slider
end

-- Chosen once ---------------------------------------------------------------

local create = (LazyProf.ClientFamily == "forever") and CreateForever or CreateClassic

function Widgets.CreateSlider(parent, name, opts)
    return create(parent, name, opts)
end
