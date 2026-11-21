-- scripts/test_panelshell.lua
--
-- Panel shell (Modules/UI/Widgets/PanelShell.lua): the state machine the side
-- panels (milestone breakdown, shopping list, recipe details) share -
-- saved position vs default anchor, the user-closed flag, the raise above the
-- anchor frame, and the combat hide/restore policy. Driven with fake frames.
-- Also checks the wiring: Core/Init.lua (ResetClosed on open, /lp
-- resetpanels, no display with the window closed, stale path dropped),
-- Core/Config.lua (default + reset button), the TOC line and each panel's
-- Attach + close button.
--
-- Run from the addon root:  lua5.1 scripts/test_panelshell.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

local failures, total = 0, 0
local function check(name, cond, detail)
    total = total + 1
    if cond then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
    end
end
local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then check(name .. " executed without error", false, err) end
end

-- ===========================================================================
-- Fake frames
-- ===========================================================================
local function newFrame(name, strata, level)
    local f = {
        name = name, shown = false, points = {}, scripts = {}, events = {},
        strata = strata or "MEDIUM", level = level or 1, left = 0, top = 0,
        movable = false, showCalls = 0,
    }
    function f:Show() self.shown = true; self.showCalls = self.showCalls + 1 end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:IsVisible() return self.shown end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(point, rel, relPoint, x, y)
        self.points[#self.points + 1] = { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
    end
    function f:GetNumPoints() return #self.points end
    function f:GetLeft() return self.left end
    function f:GetTop() return self.top end
    function f:SetFrameStrata(s) self.strata = s end
    function f:GetFrameStrata() return self.strata end
    function f:SetFrameLevel(l) self.level = l end
    function f:GetFrameLevel() return self.level end
    function f:SetMovable(v) self.movable = v end
    function f:IsMovable() return self.movable end
    function f:EnableMouse() end
    function f:SetClampedToScreen() end
    function f:RegisterForDrag(button) self.dragButton = button end
    function f:StartMoving() self.moving = true end
    function f:StopMovingOrSizing() self.moving = false end
    function f:SetUserPlaced(v) self.userPlaced = v end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:GetScript(n) return self.scripts[n] end
    function f:HookScript(n, fn)
        local prev = self.scripts[n]
        self.scripts[n] = function(...)
            if prev then prev(...) end
            fn(...)
        end
    end
    function f:Fire(event, ...)
        if self.events[event] and self.scripts.OnEvent then
            self.scripts.OnEvent(self, event, ...)
        end
    end
    return f
end

-- ===========================================================================
-- Environment: a fresh addon table with Utils + PanelShell per scenario.
-- ===========================================================================
local env
local function fresh()
    env = { combat = false, open = true }
    env.window = newFrame("Window", "MEDIUM", 5)
    _G.UIParent = newFrame("UIParent")
    _G.InCombatLockdown = function() return env.combat end
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    local addon = {}
    addon.Debug = function() end
    addon.IsDebugEnabled = function() return false end
    addon.db = { profile = { panelPositions = {} } }
    addon.Client = {
        IsOpen = function() return env.open end,
        AnchorFrame = function() return env.window end,
    }
    addon.Pathfinder = { currentPath = { steps = { {} }, gaps = {} } }
    assert(loadfile("Core/Utils.lua"))("LazyProf", addon)
    assert(loadfile("Modules/UI/Widgets/PanelShell.lua"))("LazyProf", addon)
    env.addon = addon
    env.shell = addon.PanelShell
    env.frames = {}
    return addon
end

-- Attach a panel anchored TOPLEFT to the window's TOPRIGHT +10,0.
local function attach(key, anchorFn)
    local f = newFrame(key, "MEDIUM", 10)
    env.shell:Attach(f, key, {
        anchor = anchorFn or function() return env.window, "TOPLEFT", "TOPRIGHT", 10, 0 end,
    })
    env.frames[#env.frames + 1] = f
    return f
end

-- Combat edges, delivered to each frame in the given order (default: attach order).
-- InCombatLockdown() is false while PLAYER_REGEN_DISABLED/ENABLED dispatch, as in game.
local function enterCombat(order)
    for _, f in ipairs(order or env.frames) do f:Fire("PLAYER_REGEN_DISABLED") end
    env.combat = true
end
local function leaveCombat(order)
    env.combat = false
    for _, f in ipairs(order or env.frames) do f:Fire("PLAYER_REGEN_ENABLED") end
end

local function lastPoint(f) return f.points[#f.points] end

-- ===========================================================================
-- 1. Position: saved position vs default anchor, drag saves, reset
-- ===========================================================================
section("position", function()
    local p = "position: "
    fresh()
    local f = attach("milestone")
    check(p .. "Attach makes the frame movable by left-drag", f.movable and f.dragButton == "LeftButton")
    check(p .. "Attach registers the combat events",
        f.events.PLAYER_REGEN_DISABLED and f.events.PLAYER_REGEN_ENABLED)

    env.shell:Place(f)
    local pt = lastPoint(f)
    check(p .. "no saved position: anchored to the window TOPRIGHT +10,0",
        #f.points == 1 and pt.point == "TOPLEFT" and pt.rel == env.window
            and pt.relPoint == "TOPRIGHT" and pt.x == 10 and pt.y == 0)

    env.addon.db.profile.panelPositions.milestone = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 300, y = 700 }
    env.shell:Place(f)
    pt = lastPoint(f)
    check(p .. "saved position wins over the anchor",
        #f.points == 1 and pt.rel == UIParent and pt.point == "TOPLEFT"
            and pt.relPoint == "BOTTOMLEFT" and pt.x == 300 and pt.y == 700)

    -- Drag: start + stop saves TOPLEFT relative to UIParent's BOTTOMLEFT.
    env.addon.db.profile.panelPositions.milestone = nil
    f.scripts.OnDragStart(f)
    check(p .. "drag start moves the frame", f.moving == true)
    f.left, f.top = 123, 456
    f.scripts.OnDragStop(f)
    local saved = env.addon.db.profile.panelPositions.milestone
    check(p .. "drag stop stops moving", f.moving == false)
    check(p .. "drag stop saves the position",
        saved and saved.point == "TOPLEFT" and saved.relPoint == "BOTTOMLEFT"
            and saved.x == 123 and saved.y == 456)
    check(p .. "drag stop leaves the layout cache out of it", f.userPlaced == false)

    -- An update during a drag must not snap the panel back.
    env.addon.db.profile.panelPositions.milestone = nil
    f.scripts.OnDragStart(f)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 5, 5)
    env.shell:Show(f)
    check(p .. "Place during a drag leaves the frame alone", #f.points == 1 and f.points[1].point == "CENTER")
    f.left, f.top = 123, 456
    f.scripts.OnDragStop(f)

    -- Show places too: saved position survives a Show (the update path).
    env.shell:Show(f)
    pt = lastPoint(f)
    check(p .. "Show keeps the saved position", f.shown and pt.rel == UIParent and pt.x == 123 and pt.y == 456)

    -- Reset: positions cleared, shown panels go back to the anchor.
    env.shell:ResetPositions()
    pt = lastPoint(f)
    check(p .. "ResetPositions clears saved positions", next(env.addon.db.profile.panelPositions) == nil)
    check(p .. "ResetPositions re-anchors a shown panel", pt.rel == env.window and pt.x == 10)

    -- No anchor and no saved position: leave the frame where it is.
    fresh()
    local loose = attach("loose", function() return nil end)
    loose:SetPoint("CENTER", UIParent, "CENTER", 1, 2)
    env.shell:Place(loose)
    check(p .. "no anchor and no saved position: points untouched",
        #loose.points == 1 and loose.points[1].point == "CENTER")

    -- Missing db (defensive): Place falls back to the anchor without error.
    fresh()
    local f2 = attach("milestone")
    env.addon.db.profile.panelPositions = nil
    env.shell:Place(f2)
    check(p .. "nil panelPositions: anchored, no error", lastPoint(f2).rel == env.window)
end)

-- ===========================================================================
-- 2. Raise above the anchor frame
-- ===========================================================================
section("raise", function()
    local p = "raise: "
    fresh()
    env.window.strata, env.window.level = "HIGH", 7
    local f = attach("milestone")
    env.shell:Place(f)
    check(p .. "takes the anchor's strata", f.strata == "HIGH", f.strata)
    check(p .. "sits 20 levels above the anchor", f.level == 27, f.level)

    -- Saved position still raises above the anchor (it may overlap the window).
    env.addon.db.profile.panelPositions.milestone = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 1, y = 2 }
    f.strata, f.level = "LOW", 1
    env.shell:Place(f)
    check(p .. "saved position: still raised", f.strata == "HIGH" and f.level == 27)

    -- No anchor frame: back to the strata/level the panel had when attached.
    fresh()
    local hasAnchor = true
    local g = newFrame("details", "HIGH", 20)
    env.shell:Attach(g, "details", {
        anchor = function() if hasAnchor then return env.window, "TOPLEFT", "TOPRIGHT", 10, 0 end end,
    })
    env.shell:Place(g)
    check(p .. "anchored: MEDIUM 25", g.strata == "MEDIUM" and g.level == 25, g.strata .. " " .. g.level)
    hasAnchor = false
    env.shell:Place(g)
    check(p .. "no anchor: base strata and level restored", g.strata == "HIGH" and g.level == 20,
        g.strata .. " " .. g.level)
end)

-- ===========================================================================
-- 3. Closed state
-- ===========================================================================
section("closed", function()
    local p = "closed: "
    fresh()
    local f = attach("milestone")
    env.shell:Show(f)
    check(p .. "Show shows", f.shown)
    env.shell:Close(f)
    check(p .. "Close hides and marks userClosed", not f.shown and f.userClosed == true)
    env.shell:Show(f)
    env.shell:Show(f)
    check(p .. "userClosed holds across two Show calls", not f.shown)
    env.shell:ResetClosed()
    check(p .. "ResetClosed clears userClosed", not f.userClosed)
    env.shell:Show(f)
    check(p .. "Show after ResetClosed shows", f.shown)

    env.shell:Hide(f)
    check(p .. "a plain Hide does not mark userClosed", not f.shown and not f.userClosed)
    env.shell:Show(f)
    check(p .. "Show after a plain Hide shows", f.shown)

    -- ResetClosed covers every attached shell.
    local g = attach("shoppingList")
    env.shell:Close(f)
    env.shell:Close(g)
    env.shell:ResetClosed()
    check(p .. "ResetClosed clears every shell", not f.userClosed and not g.userClosed)
end)

-- ===========================================================================
-- 4. Combat (ruling L4)
-- ===========================================================================
section("combat", function()
    local p = "combat: "

    -- Show during combat, regen with the window closed -> stays hidden.
    fresh()
    local f = attach("milestone")
    enterCombat()
    env.shell:Show(f)
    check(p .. "Show during combat does not show", not f.shown and f.showCalls == 0)
    env.open = false
    leaveCombat()
    check(p .. "Show in combat, window closed at regen -> stays hidden", not f.shown)

    -- Show during combat, regen with window open and a path -> shown, placed.
    fresh()
    f = attach("milestone")
    enterCombat()
    env.shell:Show(f)
    leaveCombat()
    check(p .. "Show in combat, window open + path at regen -> shown", f.shown)
    check(p .. "restored panel is placed", lastPoint(f) and lastPoint(f).rel == env.window)
    leaveCombat()
    check(p .. "pending show is consumed (second regen does not re-show)", f.showCalls == 1, f.showCalls)

    -- Show during combat but no current path at regen -> stays hidden.
    fresh()
    f = attach("milestone")
    enterCombat()
    env.shell:Show(f)
    env.addon.Pathfinder.currentPath = nil
    leaveCombat()
    check(p .. "Show in combat, no path at regen -> stays hidden", not f.shown)

    -- A path with no steps but gap rows still counts (the panel shows gap rows).
    fresh()
    f = attach("milestone")
    env.addon.Pathfinder.currentPath = { steps = {}, gaps = { { from = 1, to = 5 } } }
    enterCombat()
    env.shell:Show(f)
    leaveCombat()
    check(p .. "gap-only path counts as a current path", f.shown)
    fresh()
    f = attach("milestone")
    env.addon.Pathfinder.currentPath = { steps = {}, gaps = {} }
    enterCombat()
    env.shell:Show(f)
    leaveCombat()
    check(p .. "empty path does not count", not f.shown)

    -- Shown before combat: hidden at combat start, restored after.
    fresh()
    f = attach("milestone")
    env.shell:Show(f)
    enterCombat()
    check(p .. "shown panel hides when combat starts", not f.shown)
    leaveCombat()
    check(p .. "shown before combat, window open + path -> restored", f.shown)

    -- Close the window in combat (onClose hides the panels) -> not restored.
    fresh()
    f = attach("milestone")
    env.shell:Show(f)
    enterCombat()
    env.open = false
    env.shell:Hide(f)
    leaveCombat()
    check(p .. "window closed in combat -> not restored", not f.shown)

    -- A Hide in combat cancels the restore even if the window is open again.
    fresh()
    f = attach("milestone")
    env.shell:Show(f)
    enterCombat()
    env.shell:Hide(f)
    leaveCombat()
    check(p .. "Hide in combat cancels the restore", not f.shown)

    -- Shown before combat but the window closed (no Hide call) -> not restored.
    fresh()
    f = attach("milestone")
    env.shell:Show(f)
    enterCombat()
    env.open = false
    leaveCombat()
    check(p .. "shown before combat, window closed at regen -> not restored", not f.shown)

    -- Shown before combat, path gone at regen -> not restored.
    fresh()
    f = attach("milestone")
    env.shell:Show(f)
    enterCombat()
    env.addon.Pathfinder.currentPath = nil
    leaveCombat()
    check(p .. "shown before combat, no path at regen -> not restored", not f.shown)

    -- User-closed panel: Show in combat is ignored, nothing restored.
    fresh()
    f = attach("milestone")
    env.shell:Close(f)
    enterCombat()
    env.shell:Show(f)
    leaveCombat()
    check(p .. "user-closed panel is not shown after combat", not f.shown)

    -- Show then Hide in combat: last intent wins (stays hidden); Hide then Show: shown.
    fresh()
    f = attach("milestone")
    enterCombat()
    env.shell:Show(f)
    env.shell:Hide(f)
    leaveCombat()
    check(p .. "Show then Hide in combat -> hidden", not f.shown)
    fresh()
    f = attach("milestone")
    env.shell:Show(f)
    enterCombat()
    env.shell:Hide(f)
    env.shell:Show(f)
    leaveCombat()
    check(p .. "Hide then Show in combat -> shown", f.shown)

    -- Restore order: a panel anchored below another ends up below it even
    -- when its regen handler runs first.
    fresh()
    local top = attach("milestone")
    local below = attach("shoppingList", function()
        if top:IsShown() then return top, "TOPLEFT", "BOTTOMLEFT", 0, -10 end
        return env.window, "TOPLEFT", "TOPRIGHT", 10, -220
    end)
    enterCombat()
    env.shell:Show(top)
    env.shell:Show(below)
    leaveCombat({ below, top })
    local pt = lastPoint(below)
    check(p .. "dependent panel re-anchored below its restored anchor",
        top.shown and below.shown and pt.rel == top and pt.y == -10, pt and tostring(pt.y))

    -- Frames outside the shell keep the plain restore (Planning window, browser, arrow).
    fresh()
    local plain = newFrame("plain")
    env.addon.Utils.AddCombatLockdown(plain)
    plain:Show()
    plain:Fire("PLAYER_REGEN_DISABLED")
    check(p .. "plain frame hides at combat start", not plain.shown)
    env.open = false
    env.addon.Pathfinder.currentPath = nil
    plain:Fire("PLAYER_REGEN_ENABLED")
    check(p .. "plain frame restores unconditionally (unchanged)", plain.shown)
end)

-- ===========================================================================
-- 5. Init.lua wiring
-- ===========================================================================
section("init", function()
    local p = "init: "
    _G.LibStub = function(_name)
        return { NewAddon = function(_self, addon) return addon end }
    end
    _G.GetTime = function() return 0 end
    _G.strlower = string.lower
    local addon = {}
    assert(loadfile("Core/Init.lua"))("LazyProf", addon)
    local open = true
    addon.Client = {
        IsOpen = function() return open end,
        GetLine = function() return "tailoring", 100, 150 end,
    }
    local calls = {}
    addon.PanelShell = {
        ResetClosed = function() calls[#calls + 1] = "ResetClosed" end,
        ResetPositions = function() calls[#calls + 1] = "ResetPositions" end,
    }
    addon.ScheduleRecalculation = function() calls[#calls + 1] = "recalc" end
    addon.Print = function() end

    addon:OnTradeSkillShow()
    check(p .. "profession open clears the closed state before recalculating",
        calls[1] == "ResetClosed" and calls[2] == "recalc", table.concat(calls, ","))

    calls = {}
    addon:SlashCommand("resetpanels")
    check(p .. "/lp resetpanels resets panel positions", calls[1] == "ResetPositions", table.concat(calls, ","))

    local printed
    addon.Print = function(_self, msg) printed = msg end
    addon.configRegistered = false
    addon:SlashCommand("help")
    check(p .. "help line lists /lp resetpanels", printed and printed:find("/lp resetpanels", 1, true), printed)

    -- UpdateDisplay never shows panels with the profession window closed.
    local updates = 0
    addon.Pathfinder = { currentPath = { steps = { {} } } }
    addon.ArrowManager = { Update = function() updates = updates + 1 end }
    addon.MilestonePanel = { Update = function() updates = updates + 1 end }
    open = false
    addon:UpdateDisplay()
    check(p .. "UpdateDisplay with the window closed does nothing", updates == 0, updates)
    open = true
    addon:UpdateDisplay()
    check(p .. "UpdateDisplay with the window open updates", updates == 2, updates)

    -- No path for the open profession: the stale path is dropped.
    local hidden = 0
    addon.ArrowManager = { Hide = function() hidden = hidden + 1 end, InvalidateCache = function() end }
    addon.MilestonePanel = { Hide = function() hidden = hidden + 1 end }
    addon.MissingMaterialsPanel = { Hide = function() hidden = hidden + 1 end }
    addon.Pathfinder.Calculate = function() return nil end
    addon:Recalculate("test")
    check(p .. "no path: stale current path cleared", addon.Pathfinder.currentPath == nil)
    check(p .. "no path: panels hidden", hidden == 3, hidden)

    -- Shopping-list refresh queued before the window closed does not show the list.
    local refreshed = 0
    addon.Pathfinder.currentPath = { steps = { {} }, milestoneBreakdown = {} }
    addon.MilestonePanel = nil
    addon.MissingMaterialsPanel = { Update = function() refreshed = refreshed + 1 end }
    addon.Inventory = { ScanAll = function() return {}, {} end }
    addon.PriceManager = { cache = {} }
    addon.Pathfinder.CalculateMissingMaterials = function() return {} end
    open = false
    addon:RefreshShoppingList()
    check(p .. "shopping-list refresh with the window closed does nothing", refreshed == 0, refreshed)
    open = true
    addon:RefreshShoppingList()
    check(p .. "shopping-list refresh with the window open updates", refreshed == 1, refreshed)
end)

-- ===========================================================================
-- 6. Config: default and reset button
-- ===========================================================================
section("config", function()
    local p = "config: "
    local addon = {}
    assert(loadfile("Core/Constants.lua"))("LazyProf", addon)
    assert(loadfile("Core/Config.lua"))("LazyProf", addon)
    local d = addon.defaults.profile.panelPositions
    check(p .. "default panelPositions is an empty table", type(d) == "table" and next(d) == nil)

    local found
    local function walk(t)
        for _, opt in pairs(t) do
            if type(opt) == "table" then
                if opt.type == "execute" and opt.name == "Reset panel positions" then found = opt end
                if opt.args then walk(opt.args) end
            end
        end
    end
    walk(addon.options.args)
    check(p .. "execute button 'Reset panel positions' exists", found ~= nil)
    local reset = 0
    addon.PanelShell = { ResetPositions = function() reset = reset + 1 end }
    if found then found.func() end
    check(p .. "the button resets panel positions", reset == 1, reset)
end)

-- ===========================================================================
-- 7. TOC + panel wiring (source-level)
-- ===========================================================================
local function read(path)
    local fh = assert(io.open(path, "r"))
    local s = fh:read("*a")
    fh:close()
    return s
end

section("wiring", function()
    local p = "wiring: "
    local toc = read("LazyProf.toc")
    local shellAt = toc:find("Modules\\UI\\Widgets\\PanelShell.lua", 1, true)
    local firstPanel = toc:find("Modules\\UI\\MilestoneBreakdown.lua", 1, true)
    check(p .. "TOC loads the shell before the panels", shellAt and firstPanel and shellAt < firstPanel)

    local mb = read("Modules/UI/MilestoneBreakdown.lua")
    local mm = read("Modules/UI/MissingMaterials.lua")
    local rd = read("Modules/UI/RecipeDetails.lua")
    check(p .. "milestone panel attaches as 'milestone'", mb:find('PanelShell:Attach(self.frame, "milestone"', 1, true))
    check(p .. "shopping list attaches as 'shoppingList'", mm:find('PanelShell:Attach(self.frame, "shoppingList"', 1, true))
    check(p .. "recipe details attaches as 'recipeDetails'", rd:find('PanelShell:Attach(self.frame, "recipeDetails"', 1, true))
    check(p .. "no manuallyMoved left", not mb:find("manuallyMoved", 1, true))
    check(p .. "milestone close button closes through the shell", mb:find("PanelShell:Close(self.frame)", 1, true))
    check(p .. "shopping list close button closes through the shell", mm:find("PanelShell:Close(self.frame)", 1, true))
    for name, src in pairs({ milestone = mb, shopping = mm, details = rd }) do
        check(p .. name .. ": no own drag scripts (the shell owns dragging)",
            not src:find('SetScript("OnDragStart"', 1, true))
        check(p .. name .. ": no direct AddCombatLockdown (through the shell)",
            not src:find("Utils.AddCombatLockdown(", 1, true))
    end
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
