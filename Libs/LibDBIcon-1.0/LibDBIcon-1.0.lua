--[[
LibDBIcon-1.0 - Minimap button library for WoW addons
Creates draggable minimap buttons using LibDataBroker data objects
]]

assert(LibStub, "LibDBIcon-1.0 requires LibStub")
assert(LibStub:GetLibrary("LibDataBroker-1.1", true), "LibDBIcon-1.0 requires LibDataBroker-1.1")

local MAJOR, MINOR = "LibDBIcon-1.0", 56
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.objects = lib.objects or {}
lib.callbackRegistered = lib.callbackRegistered or nil
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.notCreated = lib.notCreated or {}
lib.tooltip = lib.tooltip or nil

local ldb = LibStub("LibDataBroker-1.1")
local callbacks = lib.callbacks

-- Constants
local ICON_SIZE = 31
local BUTTON_SIZE = 31
local MINIMAP_RADIUS = 80
local DEFAULT_ICON = [[Interface\Icons\INV_Misc_QuestionMark]]

-- Math helpers
local sin, cos, floor, atan2, sqrt = math.sin, math.cos, math.floor, math.atan2, math.sqrt
local pi, pi2 = math.pi, math.pi * 2

-- Utility functions
local function GetAngle(x, y)
    return atan2(y, x)
end

local function GetPosition(angle, radius)
    return cos(angle) * radius, sin(angle) * radius
end

-- Get minimap shape for non-circular minimaps
local function GetMinimapShape()
    return "ROUND"
end

-- Calculate position on minimap based on angle
local function UpdatePosition(button, position, radius)
    local angle = position and (position / 360) * pi2 or 0
    local x, y = GetPosition(angle, radius or MINIMAP_RADIUS)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Button creation
local function CreateButton(name, object, db)
    local button = CreateFrame("Button", "LibDBIcon10_" .. name, Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(136477) -- Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture(136430) -- Interface\\Minimap\\MiniMap-TrackingBorder
    overlay:SetPoint("TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture(136467) -- Interface\\Minimap\\UI-Minimap-Background
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(object.icon or DEFAULT_ICON)
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    button.isMouseDown = false
    button.dataObject = object
    button.db = db

    -- Dragging
    button:SetMovable(true)
    local isDragging = false

    button:SetScript("OnDragStart", function(self)
        if self.db and not self.db.lock then
            self:SetScript("OnUpdate", function(self)
                local mx, my = Minimap:GetCenter()
                local px, py = GetCursorPosition()
                local scale = Minimap:GetEffectiveScale()
                px, py = px / scale, py / scale
                local angle = GetAngle(px - mx, py - my)
                local degrees = (angle / pi2) * 360
                if degrees < 0 then degrees = degrees + 360 end
                self.db.minimapPos = degrees
                UpdatePosition(self, degrees, self.db.radius or MINIMAP_RADIUS)
            end)
            isDragging = true
            self:StartMoving()
        end
    end)

    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:StopMovingOrSizing()
        isDragging = false
        if lib.tooltip and lib.tooltip:IsShown() then
            lib.tooltip:Hide()
        end
    end)

    -- Click handlers
    button:SetScript("OnClick", function(self, btn)
        if isDragging then return end
        local obj = self.dataObject
        if btn == "LeftButton" and obj.OnClick then
            obj.OnClick(self, btn)
        elseif btn == "RightButton" and obj.OnClick then
            obj.OnClick(self, btn)
        end
    end)

    button:SetScript("OnMouseDown", function(self)
        self.isMouseDown = true
        self.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    end)

    button:SetScript("OnMouseUp", function(self)
        self.isMouseDown = false
        self.icon:SetTexCoord(0, 1, 0, 1)
    end)

    -- Tooltip
    button:SetScript("OnEnter", function(self)
        if isDragging then return end
        local obj = self.dataObject
        if obj.OnTooltipShow then
            lib.tooltip = lib.tooltip or GameTooltip
            lib.tooltip:SetOwner(self, "ANCHOR_NONE")
            lib.tooltip:SetPoint("TOPRIGHT", self, "BOTTOMLEFT")
            obj.OnTooltipShow(lib.tooltip)
            lib.tooltip:Show()
        elseif obj.OnEnter then
            obj.OnEnter(self)
        end
    end)

    button:SetScript("OnLeave", function(self)
        local obj = self.dataObject
        if obj.OnTooltipShow then
            if lib.tooltip then
                lib.tooltip:Hide()
            end
        elseif obj.OnLeave then
            obj.OnLeave(self)
        end
    end)

    lib.objects[name] = button

    -- Apply saved position
    if db then
        if db.hide then
            button:Hide()
        else
            button:Show()
        end
        UpdatePosition(button, db.minimapPos, db.radius)
    else
        UpdatePosition(button, 225, MINIMAP_RADIUS)
    end

    -- Callback for attribute changes
    ldb.callbacks:RegisterCallback("LibDataBroker_AttributeChanged_" .. name, function(event, dataName, key, value)
        if key == "icon" then
            button.icon:SetTexture(value)
        elseif key == "iconCoords" then
            button.icon:SetTexCoord(unpack(value))
        end
    end)

    callbacks:Fire("LibDBIcon_IconCreated", button, name)

    return button
end

-- Public API

function lib:Register(name, object, db)
    if lib.objects[name] or lib.notCreated[name] then
        return
    end

    if not object then
        object = ldb:GetDataObjectByName(name)
    end

    if object then
        CreateButton(name, object, db)
    else
        lib.notCreated[name] = db
    end
end

function lib:Lock(name)
    local button = lib.objects[name]
    if button and button.db then
        button.db.lock = true
    end
end

function lib:Unlock(name)
    local button = lib.objects[name]
    if button and button.db then
        button.db.lock = nil
    end
end

function lib:Hide(name)
    local button = lib.objects[name]
    if button then
        button:Hide()
        if button.db then
            button.db.hide = true
        end
    end
end

function lib:Show(name)
    local button = lib.objects[name]
    if button then
        button:Show()
        if button.db then
            button.db.hide = nil
        end
    end
end

function lib:IsRegistered(name)
    return lib.objects[name] ~= nil or lib.notCreated[name] ~= nil
end

function lib:Refresh(name, db)
    local button = lib.objects[name]
    if button then
        if db then
            button.db = db
        end
        UpdatePosition(button, button.db and button.db.minimapPos, button.db and button.db.radius)
        if button.db and button.db.hide then
            button:Hide()
        else
            button:Show()
        end
    end
end

function lib:GetMinimapButton(name)
    return lib.objects[name]
end

function lib:GetMinimapButtonIterator()
    return pairs(lib.objects)
end

function lib:SetButtonRadius(name, radius)
    local button = lib.objects[name]
    if button and button.db then
        button.db.radius = radius
        UpdatePosition(button, button.db.minimapPos, radius)
    end
end

function lib:SetButtonToPosition(name, position)
    local button = lib.objects[name]
    if button and button.db then
        button.db.minimapPos = position
        UpdatePosition(button, position, button.db.radius)
    end
end

-- Register callback for new LDB objects
if not lib.callbackRegistered then
    ldb.callbacks:RegisterCallback("LibDataBroker_DataObjectCreated", function(event, name, object)
        if lib.notCreated[name] then
            CreateButton(name, object, lib.notCreated[name])
            lib.notCreated[name] = nil
        end
    end)
    lib.callbackRegistered = true
end
