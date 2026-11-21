-- Modules/UI/Widgets/PanelShell.lua
-- One shell for the side panels next to the profession window (milestone
-- breakdown, shopping list, recipe details): where they sit, whether the user
-- closed them, how they stack above their anchor, and what combat does.
--
-- Position: the default spot comes from the panel's anchor function. Once the
--   user drags a panel, its top-left corner is saved in
--   db.profile.panelPositions[key] (relative to UIParent's BOTTOMLEFT) and
--   wins from then on, until "/lp resetpanels" or the options button.
-- Closed: the close button sets frame.userClosed. Show does nothing while it
--   is set; ResetClosed (the profession window opened again) clears it.
-- Raise: on Place the panel takes the strata of the frame it anchors to and
--   sits RAISE_LEVELS above it, so that frame never draws over the panel.
--   Without an anchor frame the panel goes back to its own strata and level.
-- Combat (rule 7, ruling L4): panels hide when combat starts. A Show asked for
--   during combat is remembered instead of shown. When combat ends a panel
--   shows again only if it was shown or asked for, the profession window is
--   still open, a current path exists and the user did not close it. A Hide
--   during combat cancels any restore.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

local PanelShell = {}
LazyProf.PanelShell = PanelShell

local RAISE_LEVELS = 20

-- Attached frames in attach order (a panel anchored to another one must be
-- attached after it, so re-placing in this order settles dependents).
local shells = {}

local function InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

local function Positions()
    local profile = LazyProf.db and LazyProf.db.profile
    return profile and profile.panelPositions
end

-- A current path: the live path has steps, or gap rows the milestone panel shows.
local function HasCurrentPath()
    local path = LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath
    if not path then return false end
    return (path.steps and #path.steps > 0) or (path.gaps and #path.gaps > 0) or false
end

local function WindowOpen()
    return LazyProf.Client and LazyProf.Client:IsOpen() or false
end

-- Attach a panel frame. key names its saved position; opts.anchor is a
-- function returning (anchorFrame, point, relPoint, x, y) for the default
-- spot, or nil when there is nothing to anchor to. Call after the frame's
-- own strata and level are set (they are the fallback when not anchored).
function PanelShell:Attach(frame, key, opts)
    opts = opts or {}
    frame._shell = {
        key = key,
        anchor = opts.anchor,
        baseStrata = frame:GetFrameStrata(),
        baseLevel = frame:GetFrameLevel(),
    }

    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f)
        if f:IsMovable() then
            f._shellDragging = true
            f:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        f._shellDragging = nil
        PanelShell:SavePosition(f)
    end)

    Utils.AddCombatLockdown(frame, function(f)
        PanelShell:RestoreAfterCombat(f)
    end)

    shells[#shells + 1] = frame
    return frame
end

-- Save where the user dropped the panel.
function PanelShell:SavePosition(frame)
    local shell = frame._shell
    if not shell then return end
    -- Our saved position is the only source of truth, not the client's layout cache.
    if frame.SetUserPlaced then
        frame:SetUserPlaced(false)
    end
    local left, top = frame:GetLeft(), frame:GetTop()
    local positions = Positions()
    if not (left and top and positions) then return end
    positions[shell.key] = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top }
    LazyProf:Debug("ui", string.format("PanelShell: saved %s at %.0f, %.0f", shell.key, left, top))
end

-- Position the panel (saved spot, else the anchor) and raise it above its anchor.
function PanelShell:Place(frame)
    local shell = frame._shell
    -- An update (bag change, skill-up) during a drag must not snap it back.
    if not shell or frame._shellDragging then return end

    local anchorFrame, point, relPoint, x, y
    if shell.anchor then
        anchorFrame, point, relPoint, x, y = shell.anchor()
    end

    local positions = Positions()
    local saved = positions and positions[shell.key]
    if saved and type(saved.x) == "number" and type(saved.y) == "number" then
        frame:ClearAllPoints()
        frame:SetPoint(saved.point or "TOPLEFT", UIParent, saved.relPoint or "BOTTOMLEFT", saved.x, saved.y)
    elseif anchorFrame then
        frame:ClearAllPoints()
        frame:SetPoint(point, anchorFrame, relPoint, x or 0, y or 0)
    end

    local strata, level = shell.baseStrata, shell.baseLevel
    if anchorFrame then
        strata = anchorFrame:GetFrameStrata()
        level = anchorFrame:GetFrameLevel() + RAISE_LEVELS
    end
    -- Only touch strata when it changes (a strata change re-strata's children).
    if strata and frame:GetFrameStrata() ~= strata then
        frame:SetFrameStrata(strata)
    end
    if level and frame:GetFrameLevel() ~= level then
        frame:SetFrameLevel(level)
    end
end

-- Show the panel unless the user closed it; during combat remember the request.
function PanelShell:Show(frame)
    if frame.userClosed then return end
    if InCombat() then
        frame._pendingShow = true
        return
    end
    self:Place(frame)
    frame:Show()
end

-- Hide the panel and cancel any after-combat restore. During combat the panel
-- is already hidden (combat start hid it, Show only records the request).
function PanelShell:Hide(frame)
    frame._pendingShow = nil
    frame._wasShownBeforeCombat = nil
    if InCombat() then return end
    frame:Hide()
end

-- The close button: hide and keep it closed until the profession window reopens.
function PanelShell:Close(frame)
    frame.userClosed = true
    self:Hide(frame)
end

-- The profession window was opened: closed panels may show again.
function PanelShell:ResetClosed()
    for _, frame in ipairs(shells) do
        frame.userClosed = nil
    end
end

-- Forget every saved position; shown panels go back to their default spot.
function PanelShell:ResetPositions()
    local positions = Positions()
    if positions then
        for k in pairs(positions) do
            positions[k] = nil
        end
    end
    if not InCombat() then
        self:PlaceShown()
    end
end

-- Re-place every shown panel, in attach order.
function PanelShell:PlaceShown()
    for _, frame in ipairs(shells) do
        if frame:IsShown() then
            self:Place(frame)
        end
    end
end

-- PLAYER_REGEN_ENABLED for an attached frame (see the header for the rule).
function PanelShell:RestoreAfterCombat(frame)
    local wanted = frame._pendingShow or frame._wasShownBeforeCombat
    frame._pendingShow = nil
    frame._wasShownBeforeCombat = nil
    if not wanted then return end

    local restore = not frame.userClosed and WindowOpen() and HasCurrentPath()
    if LazyProf:IsDebugEnabled("ui") then
        LazyProf:Debug("ui", string.format("PanelShell: after combat %s -> %s (closed=%s, window=%s, path=%s)",
            frame._shell and frame._shell.key or "?", restore and "show" or "stay hidden",
            tostring(frame.userClosed == true), tostring(WindowOpen()), tostring(HasCurrentPath())))
    end
    if not restore then return end

    self:Place(frame)
    frame:Show()
    -- Regen handlers run in no fixed order: re-place so a panel anchored below
    -- this one does not stay at its fallback spot.
    self:PlaceShown()
end
