-- scripts/test_arrow.lua
--
-- The recipe arrow (Modules/UI/Arrow/ArrowManager.lua) and its tooltip
-- (Modules/UI/Arrow/Strategies/ArrowTooltip.lua), driven with fake frames:
-- combat handling (rule 7: hidden during combat; after combat it comes back
-- only while the profession window is open and a path exists, a Show asked
-- for during combat is honoured then, and a Hide always cancels a restore)
-- and the tooltip drawing the lines the views give it (their content is
-- checked in scripts/test_views.lua).
--
-- Run from the addon root:  lua5.1 scripts/test_arrow.lua
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

-- WoW adds string:trim() (Utils.FormatMoney uses it); stock Lua 5.1 does not.
if not string.trim then
    function string.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
end

-- ===========================================================================
-- Fake frames: unknown CamelCase methods are no-ops.
-- ===========================================================================
local function noop() end
local function methodFallback(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end

local function newRegion()
    return setmetatable({}, { __index = methodFallback })
end

local function newFrame(name)
    local f = setmetatable({ name = name, shown = false, points = {}, scripts = {}, events = {}, level = 1 },
        { __index = methodFallback })
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:IsVisible() return self.shown end
    function f:SetPoint(point, rel, relPoint, x, y)
        self.points[#self.points + 1] = { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
    end
    function f:ClearAllPoints() self.points = {} end
    function f:SetParent(p) self.parent = p end
    function f:SetFrameLevel(l) self.level = l end
    function f:GetFrameLevel() return self.level end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:HookScript(n, fn)
        local prev = self.scripts[n]
        self.scripts[n] = function(...)
            if prev then prev(...) end
            fn(...)
        end
    end
    function f:CreateTexture() return newRegion() end
    function f:CreateFontString() return newRegion() end
    function f:Fire(event)
        if self.events[event] and self.scripts.OnEvent then self.scripts.OnEvent(self, event) end
    end
    return f
end

-- ===========================================================================
-- Environment: a fresh addon table with Utils + the arrow per scenario.
-- ===========================================================================
local env
local function fresh()
    env = { combat = false, open = true, rowVisible = true }
    env.window = newFrame("ProfessionWindow")
    env.row = newFrame("RecipeRow")
    _G.UIParent = newFrame("UIParent")
    _G.CreateFrame = function(_type, name) return newFrame(name) end
    _G.InCombatLockdown = function() return env.combat end
    env.tooltip = { left = {}, right = {}, rightColor = {} }
    _G.GameTooltip = setmetatable({}, { __index = methodFallback })
    function GameTooltip:AddDoubleLine(l, r, _lr, _lg, _lb, rr, rg, rb)
        env.tooltip.left[#env.tooltip.left + 1] = l
        env.tooltip.right[#env.tooltip.right + 1] = r
        env.tooltip.rightColor[#env.tooltip.rightColor + 1] = { rr, rg, rb }
    end

    local addon = {}
    addon.Debug = noop
    addon.IsDebugEnabled = function() return false end
    addon.db = { profile = { displayMode = "arrowWithTooltip" } }
    addon.Client = {
        IsOpen = function() return env.open end,
        AnchorFrame = function() return env.window end,
        FindRecipeRow = function(_self, recipe)
            if env.open and env.rowVisible and recipe then return env.row, "optimal" end
            return nil
        end,
    }
    env.recipe = { id = 7, name = "Linen Bandage", learned = true }
    env.path = {
        steps = { { recipe = env.recipe, quantity = 5, totalCost = 500, skillStart = 1, skillEnd = 30 } },
        totalCost = 500, outOfPocketTotal = 500,
    }
    addon.Pathfinder = {
        currentPath = env.path,
        GetArrowStep = function(_self, path) return path and path.steps and path.steps[1] end,
    }
    assert(loadfile("Core/Utils.lua"))("LazyProf", addon)
    assert(loadfile("Modules/UI/Arrow/Strategies/ArrowTooltip.lua"))("LazyProf", addon)
    assert(loadfile("Modules/UI/Arrow/ArrowManager.lua"))("LazyProf", addon)
    -- The tooltip's lines come from the window's view of the live path.
    addon.GuideWindow = { LiveView = function() return env.view end }
    addon.GuideViews = { ArrowTooltip = function(view) env.asked = view; return env.lines or {} end }
    addon.ArrowManager:Initialize()
    env.addon = addon
    env.arrow = addon.ArrowManager
    return env.arrow
end

-- Combat edges, delivered to the arrow and the highlight in the given order.
-- InCombatLockdown() is false while PLAYER_REGEN_DISABLED/ENABLED dispatch, as in game.
local function frames(highlightFirst)
    local a = env.arrow
    if highlightFirst then return { a.highlight, a.frame } end
    return { a.frame, a.highlight }
end
local function enterCombat(highlightFirst)
    for _, f in ipairs(frames(highlightFirst)) do f:Fire("PLAYER_REGEN_DISABLED") end
    env.combat = true
end
local function leaveCombat(highlightFirst)
    env.combat = false
    for _, f in ipairs(frames(highlightFirst)) do f:Fire("PLAYER_REGEN_ENABLED") end
end

local function shownState()
    return env.arrow.frame.shown, env.arrow.highlight.shown
end

-- ===========================================================================
-- 1. Combat: hide on start, restore only into an open window with a path
-- ===========================================================================
for _, highlightFirst in ipairs({ false, true }) do
    local order = highlightFirst and " (highlight first)" or " (arrow first)"
    section("combat" .. order, function()
        local p = "combat" .. order .. ": "
        local arrow = fresh()
        arrow:Update(env.path)
        local a, h = shownState()
        check(p .. "Update shows the arrow and the highlight at the row", a and h)
        check(p .. "arrow anchored to the recipe row", arrow.frame.points[1] and arrow.frame.points[1].rel == env.row)

        enterCombat(highlightFirst)
        a, h = shownState()
        check(p .. "combat start hides both", not a and not h)
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "combat end, window open, path -> both shown again", a and h)

        -- Window closed during combat (close report -> Hide): no restore.
        enterCombat(highlightFirst)
        env.open = false
        arrow:Hide()
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "closed in combat -> not restored after combat", not a and not h)

        -- Window gone without a Hide (e.g. the book page): no restore either.
        fresh()
        env.arrow:Update(env.path)
        enterCombat(highlightFirst)
        env.open = false
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "window not open at combat end -> not restored", not a and not h)

        -- No path at combat end: not restored.
        fresh()
        env.arrow:Update(env.path)
        enterCombat(highlightFirst)
        env.addon.Pathfinder.currentPath = nil
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "no path at combat end -> not restored", not a and not h)

        -- Row scrolled out of view by combat end: stays hidden.
        fresh()
        env.arrow:Update(env.path)
        enterCombat(highlightFirst)
        env.rowVisible = false
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "row not in view at combat end -> stays hidden", not a and not h)
    end)

    section("combat open" .. order, function()
        local p = "combat open" .. order .. ": "
        -- Window opened during combat: the Show is kept, honoured after combat.
        local arrow = fresh()
        enterCombat(highlightFirst)
        arrow:Update(env.path)
        local a, h = shownState()
        check(p .. "Show during combat keeps both hidden (rule 7)", not a and not h)
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "Show asked for in combat -> shown after combat", a and h)
        check(p .. "shown at the recipe row", arrow.frame.points[1] and arrow.frame.points[1].rel == env.row)

        -- Asked for in combat, then the window closed: nothing after combat.
        arrow = fresh()
        enterCombat(highlightFirst)
        arrow:Update(env.path)
        env.open = false
        arrow:Hide()
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "Show then Hide in combat -> not shown after combat", not a and not h)

        -- A later combat does not replay an old request.
        arrow = fresh()
        enterCombat(highlightFirst)
        arrow:Update(env.path)
        leaveCombat(highlightFirst)
        arrow:Hide()
        enterCombat(highlightFirst)
        leaveCombat(highlightFirst)
        a, h = shownState()
        check(p .. "hidden before the next combat -> stays hidden after it", not a and not h)
    end)
end

-- Hide outside combat also cancels a pending restore.
section("hide", function()
    local p = "hide: "
    local arrow = fresh()
    arrow:Update(env.path)
    arrow:Hide()
    local a, h = shownState()
    check(p .. "Hide hides both", not a and not h)
    enterCombat()
    leaveCombat()
    a, h = shownState()
    check(p .. "hidden before combat -> not shown after", not a and not h)
end)

-- ===========================================================================
-- 2. Tooltip: draws the lines built for the live path
-- ===========================================================================
section("tooltip", function()
    local p = "tooltip: "
    fresh()
    local plain, shown = {}, 0
    function GameTooltip:AddLine(text, r, g, b, wrap) plain[#plain + 1] = { text = text, r = r, wrap = wrap } end
    function GameTooltip:Show() shown = shown + 1 end
    env.view = { path = env.path }
    env.lines = {
        { text = "LazyProf - Optimal Path", r = 1, g = 0.82, b = 0 },
        { text = "Now: 5x Linen Bandage", right = "5s", r = 1, g = 1, b = 1, rr = 1, rg = 0.82, rb = 0 },
        { text = "   Skill 1 to 30", r = 0.5, g = 0.5, b = 0.5 },
        -- The receipt's amounts: label left, amount right in its own colour.
        { text = "You spend: ", right = "5s", r = 1, g = 1, b = 1, rr = 1, rg = 1, rb = 1 },
        { text = "Back from selling: ", right = "-1s 20c", r = 1, g = 1, b = 1, rr = 0.4, rg = 1, rb = 0.4 },
        { text = "Net cost: ", right = "3s 80c", r = 1, g = 1, b = 1, rr = 1, rg = 1, rb = 1 },
        { text = "Prices: TSM 2", r = 0.6, g = 0.6, b = 0.6, wrap = true },
    }
    env.arrow:Update(env.path)
    env.arrow.frame.scripts.OnEnter(env.arrow.frame)
    check(p .. "asks for the live path's view", env.asked == env.view)
    check(p .. "plain lines drawn in order", #plain == 3 and plain[1].text == "LazyProf - Optimal Path"
        and plain[2].text == "   Skill 1 to 30", #plain)
    check(p .. "two-column lines drawn as such", env.tooltip.left[1] == "Now: 5x Linen Bandage" and env.tooltip.right[1] == "5s"
        and env.tooltip.left[2] == "You spend: ", table.concat(env.tooltip.left, "|"))
    check(p .. "the receipt's three amounts, in order", env.tooltip.left[3] == "Back from selling: "
        and env.tooltip.right[3] == "-1s 20c" and env.tooltip.left[4] == "Net cost: " and env.tooltip.right[4] == "3s 80c",
        table.concat(env.tooltip.right, "|"))
    local back, spend = env.tooltip.rightColor[3], env.tooltip.rightColor[2]
    check(p .. "money that comes back keeps its green", back[1] == 0.4 and back[2] == 1 and back[3] == 0.4)
    check(p .. "what is spent keeps its white", spend[1] == 1 and spend[2] == 1 and spend[3] == 1)
    check(p .. "wrapping passed on", plain[3].wrap == true)
    check(p .. "the tooltip is shown once", shown == 1, shown)

    -- No live view (no path): nothing is drawn.
    plain, shown = {}, 0
    env.view = nil
    env.arrow.frame.scripts.OnEnter(env.arrow.frame)
    check(p .. "no view: no tooltip", #plain == 0 and shown == 0)

    -- The simple arrow has no tooltip at all.
    env.view = { path = env.path }
    env.addon.ArrowStrategies.simpleArrow.OnEnter({}, env.arrow)
    check(p .. "simple arrow: no tooltip", shown == 0)
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
