-- scripts/test_widgets.lua
--
-- Widget layer: the row pool (Modules/UI/Widgets/RowPool.lua) and the
-- client-aware dropdown (Modules/UI/Widgets/Dropdown.lua), plus a call site:
-- the debug-window dropdowns build a UIDropDownMenu on Classic and a
-- DropdownButton menu on Forever. Driven with a fake CreateFrame that counts
-- every frame it makes. (The window's own lists and controls are covered by
-- scripts/test_controls.lua and scripts/test_window.lua.)
--
-- Run from the addon root:  lua5.1 scripts/test_widgets.lua
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

if not string.trim then
    function string.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
end

-- ===========================================================================
-- Fake UI
-- ===========================================================================
local function noop() end
-- Unknown CamelCase methods are no-ops; unknown lowercase fields stay nil so
-- `if frame.someChild then` checks behave as in game.
local function methodFallback(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end

local env

local function newRegion(kind, parent)
    local r = setmetatable({ kind = kind, parent = parent, points = {}, alpha = 1, shown = true },
        { __index = methodFallback })
    function r:SetText(t) self.text = t end
    function r:GetText() return self.text end
    function r:SetTextColor(cr, cg, cb) self.color = { cr, cg, cb } end
    function r:SetTexture(t) self.texture = t end
    function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function r:ClearAllPoints() self.points = {} end
    function r:SetAlpha(a) self.alpha = a end
    function r:GetAlpha() return self.alpha end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    return r
end

local function newFrame(ftype, name, parent, template)
    local f = setmetatable({
        ftype = ftype, name = name, parent = parent, template = template,
        shown = true, points = {}, scripts = {}, width = 0, height = 0,
        strata = "MEDIUM", level = 1, alpha = 1,
    }, { __index = methodFallback })
    function f:Show() self.shown = true end
    function f:Hide()
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:IsShown() return self.shown end
    function f:IsVisible() return self.shown end
    function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function f:ClearAllPoints() self.points = {} end
    function f:GetNumPoints() return #self.points end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:GetScript(n) return self.scripts[n] end
    function f:HookScript(n, fn)
        local prev = self.scripts[n]
        self.scripts[n] = function(...)
            if prev then prev(...) end
            fn(...)
        end
    end
    function f:SetSize(w, h) self.width, self.height = w, h end
    function f:SetWidth(w) self.width = w end
    function f:SetHeight(h) self.height = h end
    function f:GetWidth() return self.width end
    function f:GetHeight() return self.height end
    function f:GetName() return self.name end
    function f:GetParent() return self.parent end
    function f:SetFrameStrata(s) self.strata = s end
    function f:GetFrameStrata() return self.strata end
    function f:SetFrameLevel(l) self.level = l end
    function f:GetFrameLevel() return self.level end
    function f:SetAlpha(a) self.alpha = a end
    function f:GetAlpha() return self.alpha end
    function f:SetBackdropColor(cr, cg, cb, ca) self.backdropColor = { cr, cg, cb, ca } end
    function f:CreateFontString() return newRegion("FontString", self) end
    function f:CreateTexture() return newRegion("Texture", self) end
    function f:GetNormalTexture()
        self.normalTexture = self.normalTexture or newRegion("Texture", self)
        return self.normalTexture
    end
    function f:SetText(t) self.text = t end
    function f:GetText() return self.text end
    if ftype == "DropdownButton" then
        function f:SetupMenu(generator) self.generator = generator; self.setupCalls = (self.setupCalls or 0) + 1 end
        function f:OverrideText(t) self.overrideText = t end
    end
    return f
end

-- Menu root stub for a Forever generator: records radios and dividers.
local function openMenu(button)
    local root = { radios = {}, items = {}, dividers = 0 }
    function root:CreateRadio(text, isSelected, setSelected, data)
        local r = { text = text, isSelected = isSelected, setSelected = setSelected, data = data }
        self.radios[#self.radios + 1] = r
        self.items[#self.items + 1] = r
        return r
    end
    function root:CreateDivider()
        self.dividers = self.dividers + 1
        self.items[#self.items + 1] = { divider = true }
    end
    assert(button and button.generator, "dropdown has no menu generator")
    button.generator(button, root)
    return root
end

local function radioTexts(root)
    local t = {}
    for _, r in ipairs(root.radios) do t[#t + 1] = r.text end
    return table.concat(t, "|")
end
local function selectedTexts(root)
    local t = {}
    for _, r in ipairs(root.radios) do
        if r.isSelected(r.data) then t[#t + 1] = r.text end
    end
    return table.concat(t, "|")
end
local function radioNamed(root, text)
    for _, r in ipairs(root.radios) do
        if r.text == text then return r end
    end
end

local DROPDOWN_API = {
    "UIDropDownMenu_SetWidth", "UIDropDownMenu_Initialize", "UIDropDownMenu_SetText",
    "UIDropDownMenu_CreateInfo", "UIDropDownMenu_AddButton",
}

-- Classic UIDropDownMenu stubs: record width, init function, text, buttons.
local function installClassicMenu()
    env.dd = { widths = {}, init = {}, texts = {}, buttons = nil }
    _G.UIDropDownMenu_SetWidth = function(frame, w) env.dd.widths[frame] = w end
    _G.UIDropDownMenu_Initialize = function(frame, fn) env.dd.init[frame] = fn end
    _G.UIDropDownMenu_SetText = function(frame, t) env.dd.texts[frame] = t end
    _G.UIDropDownMenu_CreateInfo = function() return {} end
    _G.UIDropDownMenu_AddButton = function(info) table.insert(env.dd.buttons, info) end
end
local function classicButtons(frame)
    env.dd.buttons = {}
    assert(env.dd.init[frame], "dropdown was not initialized")
    env.dd.init[frame](frame, 1)
    return env.dd.buttons
end
local function buttonTexts(buttons)
    local t = {}
    for _, b in ipairs(buttons) do t[#t + 1] = tostring(b.text) end
    return table.concat(t, "|")
end

-- Forever: the legacy dropdown API must never be called.
local function installForeverMenu()
    for _, n in ipairs(DROPDOWN_API) do
        _G[n] = function() error(n .. " called on Forever") end
    end
    _G.EasyMenu = function() error("EasyMenu called on Forever") end
end

local BRACKETS = {
    { min = 1, max = 75, name = "1-75" },
    { min = 75, max = 150, name = "75-150" },
}

-- Fresh addon table for `family` ("classic" | "forever"); opts.init loads Core/Init.lua.
local function load(family, opts)
    opts = opts or {}
    env = { frames = {}, missing = {}, updates = 0 }
    _G.CreateFrame = function(ftype, name, parent, template)
        local f = newFrame(ftype, name, parent, template)
        env.frames[#env.frames + 1] = f
        if name then _G[name] = f end
        return f
    end
    _G.UIParent = newFrame("Frame", "UIParent")
    _G.GameTooltip = setmetatable({}, { __index = methodFallback })
    _G.InCombatLockdown = function() return false end
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.UISpecialFrames = {}
    _G.tinsert = table.insert
    _G.GameFontHighlightSmall = {}
    _G.C_Timer = { After = function() end }
    _G.IsShiftKeyDown = function() return false end
    _G.date = function() return "00:00:00" end
    _G.LibStub = function() return { NewAddon = function(_, addon) return addon end } end
    if family == "forever" then
        _G.WOW_PROJECT_ID, _G.WOW_PROJECT_CAMELOT = 99, 99
        _G.GetBuildInfo = function() return "1.60.1", "1", "Jan 1 2026", 16001 end
        installForeverMenu()
    else
        _G.WOW_PROJECT_ID, _G.WOW_PROJECT_CAMELOT = nil, nil
        _G.GetBuildInfo = function() return "1.15.8", "1", "Jan 1 2026", 11508 end
        installClassicMenu()
    end

    local addon = {}
    addon.Debug = noop
    addon.IsDebugEnabled = function() return false end
    addon.db = {
        profile = {
            strategy = "cheapest", panelPositions = {}, debug = false,
            debugCategories = {},
        },
        char = {},
    }
    addon.Client = {
        AnchorFrame = function() return nil end,
        PanelOffsetX = function() return 10 end,
        IsOpen = function() return true end,
    }
    addon.Pathfinder = {}

    local files = {
        "Core/Utils.lua",
        "Core/Client/Family.lua",
        "Modules/UI/Widgets/PanelShell.lua",
        "Modules/UI/Widgets/RowPool.lua",
        "Modules/UI/Widgets/Dropdown.lua",
        "Modules/UI/Widgets/Controls.lua",
    }
    if opts.init then files[#files + 1] = "Core/Init.lua" end
    for _, path in ipairs(files) do
        assert(loadfile(path))("LazyProf", addon)
    end
    addon.GetSkillBrackets = function() return BRACKETS end
    if opts.init then
        addon.UpdateDebugWindowContent = function() env.updates = env.updates + 1 end
    end
    env.addon = addon
    return addon
end

-- ===========================================================================
-- 1. RowPool unit
-- ===========================================================================
section("rowpool", function()
    local p = "rowpool: "
    local addon = load("classic")
    local RowPool = addon.Widgets and addon.Widgets.RowPool
    check(p .. "LazyProf.Widgets.RowPool exists", RowPool and RowPool.New)
    local made = 0
    local pool = RowPool.New(function()
        made = made + 1
        return CreateFrame("Frame", nil, UIParent)
    end)
    local first = {}
    for i = 1, 10 do first[i] = pool:Acquire() end
    check(p .. "first pass creates 10 rows", made == 10, made)
    first[1]:SetPoint("TOPLEFT", 0, 0)
    pool:ReleaseAll()
    local hidden, cleared = true, true
    for i = 1, 10 do
        if first[i].shown then hidden = false end
        if #first[i].points > 0 then cleared = false end
    end
    check(p .. "ReleaseAll hides every row", hidden)
    check(p .. "ReleaseAll clears every row's points", cleared)
    local same = true
    for i = 1, 10 do
        if pool:Acquire() ~= first[i] then same = false end
    end
    check(p .. "second pass creates nothing", made == 10, made)
    check(p .. "rows come back in the same order", same)
    pool:Acquire()
    check(p .. "an 11th row is created only when the pool is empty", made == 11, made)
end)

-- ===========================================================================
-- 4. Dropdown wrapper
-- ===========================================================================
local function optionsABC(state)
    return function()
        return {
            { text = "Alpha", value = "a", checked = state.sel == "a" },
            { separator = true },
            { text = "Beta", value = 2, checked = state.sel == 2 },
            { text = "Gamma", value = "g", checked = state.sel == "g" },
        }
    end
end

section("dropdown forever", function()
    local p = "dropdown forever: "
    local addon = load("forever")
    check(p .. "client family is forever", addon.ClientFamily == "forever", addon.ClientFamily)
    local holder = CreateFrame("Frame", "Holder", UIParent)
    local dd = addon.Widgets.CreateDropdown(holder, "TestDropdown", 160)
    local button = _G.TestDropdown
    check(p .. "creates a DropdownButton", button and button.ftype == "DropdownButton", button and button.ftype)
    check(p .. "uses WowStyle1DropdownTemplate", button and button.template == "WowStyle1DropdownTemplate")
    local state, picked = { sel = 2 }, {}
    dd:SetOptions(optionsABC(state), function(value, option) picked[#picked + 1] = { value, option } end)
    check(p .. "SetOptions calls SetupMenu", button.setupCalls == 1, button.setupCalls)
    local root = openMenu(button)
    check(p .. "one radio per option", radioTexts(root) == "Alpha|Beta|Gamma", radioTexts(root))
    check(p .. "separator becomes a divider", root.dividers == 1 and root.items[2].divider)
    check(p .. "only the checked option is selected", selectedTexts(root) == "Beta", selectedTexts(root))
    radioNamed(root, "Gamma").setSelected(radioNamed(root, "Gamma").data)
    check(p .. "picking a radio calls onSelect with its value", picked[1] and picked[1][1] == "g")
    check(p .. "onSelect gets the option", picked[1] and picked[1][2].text == "Gamma")
    state.sel = "g"
    root = openMenu(button)
    check(p .. "the menu is rebuilt from fresh options", selectedTexts(root) == "Gamma", selectedTexts(root))
    dd:SetText("Shown text")
    check(p .. "SetText overrides the button text", button.overrideText == "Shown text", button.overrideText)
    dd:SetPoint("TOPLEFT", -8, -26)
    check(p .. "SetPoint positions the dropdown's frame", #dd.frame.points == 1)
    dd:Hide()
    check(p .. "Hide hides it", not dd:IsShown())
    dd:Show()
    check(p .. "Show shows it", dd:IsShown())
    local other = addon.Widgets.CreateDropdown(holder, "TestDropdown2", 150)
    other:SetPoint("LEFT", dd, "RIGHT", -15, 0)
    check(p .. "anchoring to a dropdown uses its frame", other.frame.points[1][2] == dd.frame,
        tostring(other.frame.points[1][2]))
end)

section("dropdown classic", function()
    local p = "dropdown classic: "
    local addon = load("classic")
    check(p .. "client family is classic", addon.ClientFamily == "classic", addon.ClientFamily)
    local holder = CreateFrame("Frame", "Holder", UIParent)
    local dd = addon.Widgets.CreateDropdown(holder, "TestDropdown", 160)
    local frame = _G.TestDropdown
    check(p .. "creates a UIDropDownMenuTemplate frame",
        frame and frame.ftype == "Frame" and frame.template == "UIDropDownMenuTemplate")
    check(p .. "the frame is the dropdown's frame", dd.frame == frame)
    check(p .. "width set through UIDropDownMenu_SetWidth", env.dd.widths[frame] == 160, env.dd.widths[frame])
    local state, picked = { sel = "a" }, {}
    dd:SetOptions(optionsABC(state), function(value) picked[#picked + 1] = value end)
    local buttons = classicButtons(frame)
    check(p .. "one button per option, separator included", #buttons == 4, #buttons)
    check(p .. "button texts", buttonTexts(buttons) == "Alpha|nil|Beta|Gamma", buttonTexts(buttons))
    check(p .. "separator is disabled and not checkable",
        buttons[2].disabled == true and buttons[2].notCheckable == true)
    check(p .. "checked state", buttons[1].checked == true and buttons[3].checked == false)
    check(p .. "values kept", buttons[1].value == "a" and buttons[3].value == 2)
    buttons[3].func()
    check(p .. "func calls onSelect with the value", picked[1] == 2, picked[1])
    dd:SetText("Hello")
    check(p .. "SetText uses UIDropDownMenu_SetText", env.dd.texts[frame] == "Hello", env.dd.texts[frame])
end)

-- ===========================================================================
-- 5. Call site: debug window dropdowns
-- ===========================================================================
section("debug dropdowns forever", function()
    local p = "debug dropdowns forever: "
    local addon = load("forever", { init = true })
    addon:CreateDebugFrame()
    local frame = addon.debugFrame
    local filter = _G.LazyProfDebugFilterDropdown
    local bracket = _G.LazyProfDebugBracketDropdown
    check(p .. "filter is a DropdownButton", filter and filter.ftype == "DropdownButton")
    check(p .. "bracket is a DropdownButton", bracket and bracket.ftype == "DropdownButton")
    check(p .. "filter text", filter.overrideText == "All Categories", filter.overrideText)
    check(p .. "bracket dropdown starts hidden", not frame.bracketDropdown:IsShown())
    local root = openMenu(filter)
    check(p .. "filter options", radioTexts(root) ==
        "All Categories|Pathfinder Scoring|Pathfinder Core|UI Updates|Professions|Pricing|Arrow", radioTexts(root))
    check(p .. "filter divider after All Categories", root.items[2] and root.items[2].divider)
    check(p .. "All Categories selected", selectedTexts(root) == "All Categories", selectedTexts(root))
    addon.Pathfinder.currentPath = { currentSkill = 80 }
    radioNamed(root, "Pathfinder Scoring").setSelected(radioNamed(root, "Pathfinder Scoring").data)
    check(p .. "scoring filter set", addon.debugFilter == "scoring", addon.debugFilter)
    check(p .. "filter text follows", filter.overrideText == "Pathfinder Scoring", filter.overrideText)
    check(p .. "bracket dropdown shown for scoring", frame.bracketDropdown:IsShown())
    check(p .. "bracket auto-selected from skill", addon.debugScoringBracket == 2
        and bracket.overrideText == "75-150", bracket.overrideText)
    local broot = openMenu(bracket)
    check(p .. "bracket options", radioTexts(broot) == "All Skill Levels|1-75|75-150", radioTexts(broot))
    check(p .. "bracket selected", selectedTexts(broot) == "75-150", selectedTexts(broot))
    radioNamed(broot, "All Skill Levels").setSelected(radioNamed(broot, "All Skill Levels").data)
    check(p .. "all skill levels", addon.debugScoringBracket == nil and bracket.overrideText == "All Skill Levels")
    root = openMenu(filter)
    radioNamed(root, "All Categories").setSelected(radioNamed(root, "All Categories").data)
    check(p .. "all categories", addon.debugFilter == nil and not frame.bracketDropdown:IsShown())
    check(p .. "window refreshed on each pick", env.updates == 3, env.updates)
end)

section("debug dropdowns classic", function()
    local p = "debug dropdowns classic: "
    local addon = load("classic", { init = true })
    addon:CreateDebugFrame()
    local frame = addon.debugFrame
    local filter = _G.LazyProfDebugFilterDropdown
    local bracket = _G.LazyProfDebugBracketDropdown
    check(p .. "filter is a UIDropDownMenuTemplate frame", filter and filter.template == "UIDropDownMenuTemplate")
    check(p .. "filter at TOPLEFT 100, -3", filter.points[1][1] == "TOPLEFT" and filter.points[1][2] == 100
        and filter.points[1][3] == -3)
    check(p .. "bracket right of filter", bracket.points[1][1] == "LEFT" and bracket.points[1][2] == filter
        and bracket.points[1][3] == "RIGHT" and bracket.points[1][4] == -15)
    check(p .. "widths 150", env.dd.widths[filter] == 150 and env.dd.widths[bracket] == 150)
    check(p .. "texts", env.dd.texts[filter] == "All Categories" and env.dd.texts[bracket] == "All Skill Levels")
    check(p .. "bracket hidden", not bracket.shown)
    local buttons = classicButtons(filter)
    check(p .. "filter has 8 buttons", #buttons == 8, #buttons)
    check(p .. "separator", buttons[2].disabled == true and buttons[2].notCheckable == true)
    check(p .. "All Categories checked", buttons[1].checked == true and buttons[3].checked == false)
    buttons[3].func()  -- scoring
    check(p .. "scoring picked", addon.debugFilter == "scoring" and env.dd.texts[filter] == "Pathfinder Scoring")
    check(p .. "bracket shown", bracket.shown)
    local bb = classicButtons(bracket)
    check(p .. "bracket buttons", buttonTexts(bb) == "All Skill Levels|1-75|75-150", buttonTexts(bb))
    bb[2].func()
    check(p .. "bracket picked", addon.debugScoringBracket == 1 and env.dd.texts[bracket] == "1-75")
    buttons = classicButtons(filter)
    buttons[1].func()
    check(p .. "all categories hides bracket", addon.debugFilter == nil and not bracket.shown
        and env.dd.texts[bracket] == "All Skill Levels")
end)

-- ===========================================================================
-- 8. TOC wiring
-- ===========================================================================
section("toc", function()
    local fh = assert(io.open("LazyProf.toc", "r"))
    local toc = fh:read("*a")
    fh:close()
    local panelAt = toc:find("Modules\\UI\\GuideWindow.lua", 1, true)
    for _, name in ipairs({ "RowPool", "Dropdown", "Controls", "Tabs", "RowList" }) do
        local at = toc:find("Modules\\UI\\Widgets\\" .. name .. ".lua", 1, true)
        check("toc: " .. name .. " loads before the window", at and panelAt and at < panelAt)
    end
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
