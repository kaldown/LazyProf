-- Modules/UI/Widgets/PanelShell.lua
-- One shell for LazyProf's panels (the LazyProf window, recipe details, the
-- merchant panel): where they sit, whether the user closed them, how they
-- stack above their anchor, and what combat does.
--
-- Position: the default spot comes from the panel's anchor function. Once the
--   user drags a panel, its top-left corner is saved in
--   db.profile.panelPositions[key] (relative to UIParent's BOTTOMLEFT) and
--   wins from then on, until "/lp resetpanels" or the options button.
-- Owners: the profession window owns every panel; planning (the LazyProf
--   window undocked) also owns the panels attached with opts.planning (recipe
--   details).
-- Closed: the close button sets frame.userClosed. Show does nothing while it
--   is set. ResetClosed (the profession window opened again) clears it on
--   every panel, ResetClosedForPlanning (the user opens planning or picks a
--   profession in it) on the planning panels.
-- Raise: on Place the panel sits RAISE_LEVELS above the frame it anchors to,
--   taking that frame's strata when it is higher than the panel's own. It is
--   never put below its own strata or level. Without an anchor frame it goes
--   back to its own strata and level.
-- Own owner: a frame attached with opts.owner (the LazyProf window, the
--   merchant panel) says itself whether it should be showing: the function
--   is asked when combat ends and replaces the profession-window / Planning
--   rule below. Such a frame may also name its saved spot with a function
--   (opts.key), so it can keep one spot docked and another undocked.
-- Size: SaveSize / ApplySize keep a resizable frame's size in
--   db.profile.panelSizes[key]; "/lp resetpanels" forgets sizes too.
-- Combat (rule 7, ruling L4): panels hide when combat starts. A Show asked for
--   during combat is remembered instead of shown. When combat ends a panel
--   shows again only if it was shown or asked for, the user did not close it,
--   and an owner is there: the profession window is still open and a current
--   path exists (or the panel shows a notice instead of one, frame.showsNotice),
--   or (planning panels) planning is shown or was shown before combat. A Hide
--   during combat cancels any restore.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

local PanelShell = {}
LazyProf.PanelShell = PanelShell

local RAISE_LEVELS = 20

-- Draw order of the frame stratas, lowest first.
local STRATA_RANK = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
    FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

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

local function Sizes()
    local profile = LazyProf.db and LazyProf.db.profile
    if not profile then return nil end
    profile.panelSizes = profile.panelSizes or {}
    return profile.panelSizes
end

-- The name a frame's position and size are saved under (a frame may switch
-- between two, e.g. docked and undocked).
local function Key(shell)
    if type(shell.key) == "function" then
        return shell.key()
    end
    return shell.key
end

-- A current path: the live path has steps, or gaps the window shows.
local function HasCurrentPath()
    local path = LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath
    if not path then return false end
    return (path.steps and #path.steps > 0) or (path.gaps and #path.gaps > 0) or false
end

local function WindowOpen()
    return LazyProf.Client and LazyProf.Client:IsOpen() or false
end

-- Planning (the LazyProf window undocked) is shown, or will be once combat
-- ends: regen handlers run in no fixed order, so its own restore may not have
-- happened yet.
local function PlanningShown()
    local window = LazyProf.GuideWindow
    return (window and window.IsPlanningShown and window:IsPlanningShown()) or false
end

-- Strata and level for a panel anchored to anchorFrame (nil: its own).
local function RaiseTarget(shell, anchorFrame)
    local strata, level = shell.baseStrata, shell.baseLevel
    if not anchorFrame then return strata, level end
    local anchorStrata = anchorFrame:GetFrameStrata()
    local anchorRank, baseRank = STRATA_RANK[anchorStrata], STRATA_RANK[strata]
    if not anchorRank then return strata, level end
    local raised = anchorFrame:GetFrameLevel() + RAISE_LEVELS
    if not baseRank or anchorRank > baseRank then
        return anchorStrata, raised
    elseif anchorRank == baseRank then
        return strata, math.max(level or 0, raised)
    end
    return strata, level   -- own strata already draws above the anchor
end

-- Attach a panel frame. key names its saved position (a string, or a function
-- returning one); opts.anchor is a function returning (anchorFrame, point,
-- relPoint, x, y) for the default spot, or nil when there is nothing to
-- anchor to; opts.planning marks a panel planning also shows;
-- opts.owner is a function(frame) saying whether the frame should be showing
-- (asked when combat ends); opts.onReset(frame) runs after "/lp resetpanels".
-- Call after the frame's own strata and level are set (the floor for the
-- raise and the fallback when not anchored).
function PanelShell:Attach(frame, key, opts)
    opts = opts or {}
    frame._shell = {
        key = key,
        anchor = opts.anchor,
        planning = opts.planning and true or false,
        owner = opts.owner,
        onReset = opts.onReset,
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
    -- Hidden mid-drag (combat start, window closed): OnDragStop never fires,
    -- so end the drag here and keep the spot it was dropped at.
    frame:HookScript("OnHide", function(f)
        if f._shellDragging then
            f:StopMovingOrSizing()
            f._shellDragging = nil
            PanelShell:SavePosition(f)
        end
    end)

    Utils.AddCombatLockdown(frame, function(f)
        PanelShell:RestoreAfterCombat(f)
    end)

    shells[#shells + 1] = frame
    return frame
end

-- Panel chrome. opts.bg / opts.border are the classic backdrop colours.
-- Classic: the tooltip-style backdrop. Forever: Blizzard's own panel frame -
-- a NineSlice child with the "ButtonFrameTemplateNoPortrait" layout, the layout
-- every plain portrait-less framed panel uses (Blizzard UI source,
-- Gethe/wow-ui-source forever branch: Blizzard_SharedXML/Mainline/
-- NineSliceLayouts.lua:43, picked by DefaultPanelBaseTemplate at
-- Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:480; the Camelot
-- overrides in Blizzard_SharedXML/Camelot/NineSliceLayoutOverrides.lua adjust
-- its offsets on this client). NineSlicePanelTemplate: Ketho
-- BlizzardInterfaceResources, forever branch, Resources/Templates.lua:2311;
-- applied with NineSliceUtil.ApplyLayoutByName (Blizzard_SharedXML/NineSlice.lua:226).
-- Background: the rock tile at the anchors DefaultPanelTemplate uses
-- (SharedUIPanelTemplates.xml:531-537). The panel's own title bar strip is
-- hidden; the title font stays GameFontNormal. Call after the title bar
-- texture exists.
local FOREVER_LAYOUT = "ButtonFrameTemplateNoPortrait"
local CHROME_LEVEL = 5   -- NineSlice level above the panel; titles and controls sit above it
local FOREVER_BG = "Interface\\FrameGeneral\\UI-Background-Rock"

function PanelShell:ApplyChrome(frame, opts)
    opts = opts or {}
    if LazyProf.ClientFamily == "forever" then
        if frame._chromeApplied == true then return end
        frame._chromeApplied = true
        if frame.titleBg then frame.titleBg:Hide() end
        if not frame.Bg then
            local bg = frame:CreateTexture(nil, "BACKGROUND")
            bg:SetTexture(FOREVER_BG)
            bg:SetHorizTile(true)
            bg:SetVertTile(true)
            bg:SetPoint("TOPLEFT", 6, -21)
            bg:SetPoint("BOTTOMRIGHT", -2, 2)
            frame.Bg = bg
        end
        if NineSliceUtil and NineSliceUtil.ApplyLayoutByName then
            frame.NineSlice = CreateFrame("Frame", nil, frame, "NineSlicePanelTemplate")
            -- NineSlicePanelTemplate already sets all points and a fixed level 500
            -- (Mainline/SharedUIPanelTemplates.xml:381); anchor explicitly and take
            -- a level relative to the panel so the shell's raise still orders panels.
            frame.NineSlice:SetAllPoints(frame)
            frame.NineSlice:SetFrameLevel(frame:GetFrameLevel() + CHROME_LEVEL)
            NineSliceUtil.ApplyLayoutByName(frame.NineSlice, FOREVER_LAYOUT)
            -- The border is textures on a child frame, and a child frame draws above
            -- the parent's own regions, so the title moves to a host frame above it
            -- (Blizzard does the same: TitleContainer at frameLevel 510,
            -- SharedUIPanelTemplates.xml:486).
            if frame.title then
                local host = CreateFrame("Frame", nil, frame)
                host:SetAllPoints(frame)
                host:SetFrameLevel(frame:GetFrameLevel() + CHROME_LEVEL + 2)
                frame.title:SetParent(host)
                frame.TitleHost = host
            end
        end
        return
    end
    local bg, border = opts.bg or { 0.1, 0.1, 0.1, 0.95 }, opts.border or { 0.6, 0.6, 0.6, 1 }
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
end

-- Forever: lift a control (close button, resize grip, mode toggle) above the
-- border frame so the frame art does not cover it. No-op elsewhere.
function PanelShell:RaiseControl(frame, control)
    if LazyProf.ClientFamily ~= "forever" or not control or type(frame.NineSlice) ~= "table" then return end
    control:SetFrameLevel(frame.NineSlice:GetFrameLevel() + 2)
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
    local key = Key(shell)
    positions[key] = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top }
    LazyProf:Debug("ui", string.format("PanelShell: saved %s at %.0f, %.0f", tostring(key), left, top))
end

-- Remember a resizable frame's size (call when the user lets go of the grip).
function PanelShell:SaveSize(frame)
    local shell, sizes = frame._shell, Sizes()
    if not (shell and sizes) then return end
    local width, height = frame:GetWidth(), frame:GetHeight()
    if not (width and height) then return end
    sizes[Key(shell)] = { width = width, height = height }
end

-- Size a frame: the saved size, else the given default.
function PanelShell:ApplySize(frame, defaultWidth, defaultHeight)
    local shell, sizes = frame._shell, Sizes()
    local saved = shell and sizes and sizes[Key(shell)]
    if saved and type(saved.width) == "number" and type(saved.height) == "number" then
        frame:SetSize(saved.width, saved.height)
    else
        frame:SetSize(defaultWidth, defaultHeight)
    end
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
    local saved = positions and positions[Key(shell)]
    if saved and type(saved.x) == "number" and type(saved.y) == "number" then
        frame:ClearAllPoints()
        frame:SetPoint(saved.point or "TOPLEFT", UIParent, saved.relPoint or "BOTTOMLEFT", saved.x, saved.y)
    elseif anchorFrame then
        frame:ClearAllPoints()
        frame:SetPoint(point, anchorFrame, relPoint, x or 0, y or 0)
    end

    local strata, level = RaiseTarget(shell, anchorFrame)
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

-- The user opened Planning or picked a profession in it: its closed panels
-- may show again (not on programmatic reloads).
function PanelShell:ResetClosedForPlanning()
    for _, frame in ipairs(shells) do
        if frame._shell.planning then
            frame.userClosed = nil
        end
    end
end

-- Forget every saved position and size; shown panels go back to their
-- default spot (and, through their onReset, their default size).
function PanelShell:ResetPositions()
    for _, saved in ipairs({ Positions() or false, Sizes() or false }) do
        if saved then
            for k in pairs(saved) do
                saved[k] = nil
            end
        end
    end
    if not InCombat() then
        for _, frame in ipairs(shells) do
            if frame._shell.onReset then
                frame._shell.onReset(frame)
            end
        end
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

    local live = WindowOpen() and (HasCurrentPath() or frame.showsNotice == true)
    local planning = frame._shell and frame._shell.planning and PlanningShown() or false
    local restore = not frame.userClosed and (live or planning)
    local owner = frame._shell and frame._shell.owner
    if owner then
        -- The frame decides itself (the LazyProf window, the merchant panel)
        restore = not frame.userClosed and (owner(frame) and true or false)
    end
    if LazyProf:IsDebugEnabled("ui") then
        LazyProf:Debug("ui", string.format(
            "PanelShell: after combat %s -> %s (closed=%s, window=%s, path=%s, planning=%s)",
            frame._shell and tostring(Key(frame._shell)) or "?", restore and "show" or "stay hidden",
            tostring(frame.userClosed == true), tostring(WindowOpen()), tostring(HasCurrentPath()),
            tostring(planning)))
    end
    if not restore then return end

    self:Place(frame)
    frame:Show()
    -- Regen handlers run in no fixed order: re-place so a panel anchored below
    -- this one does not stay at its fallback spot.
    self:PlaceShown()
end
