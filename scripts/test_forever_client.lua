-- scripts/test_forever_client.lua
--
-- Core/Client/Forever.lua: the WoW Forever implementation of LazyProf.Client
-- (C_TradeSkillUI profession info and recipes, ProfessionsFrame and its recipe
-- ScrollBox, GetProfessions skill ranks, C_Item item info, events and scroll
-- callbacks), the milestone-panel hint for a hidden unlearned next recipe, and
-- the addon-compartment entry that replaces the minimap button on Forever.
--
-- Run from the addon root:  lua5.1 scripts/test_forever_client.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")

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

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end

local function sortedKeys(set)
    local keys = {}
    for k in pairs(set) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for i, k in ipairs(keys) do out[i] = tostring(k) end
    return table.concat(out, ",")
end

local function setBuild(interface, projectId, camelot)
    _G.GetBuildInfo = function() return "1.60.1", "70938", "Nov 1 2026", interface end
    _G.WOW_PROJECT_ID = projectId
    _G.WOW_PROJECT_CAMELOT = camelot
end

-- ===========================================================================
-- Forever stubs: C_TradeSkillUI, ProfessionsFrame + recipe ScrollBox,
-- GetProfessions/GetProfessionInfo, C_Item, timers, scroll-box events.
-- ===========================================================================
_G.Enum = { TradeskillRelativeDifficulty = { Optimal = 0, Medium = 1, Easy = 2, Trivial = 3 } }
_G.BaseScrollBoxEvents = { OnScroll = "OnScroll" }
_G.ScrollBoxListMixin = { Event = { OnDataRangeChanged = "OnDataRangeChanged" } }

local childInfo, baseInfo
local function resetProfessionInfo()
    childInfo = { professionID = 2937, parentProfessionID = 171, skillLevel = 152, maxSkillLevel = 225 }
    baseInfo = { professionID = 171, skillLevel = 152, maxSkillLevel = 225 }
end
resetProfessionInfo()

local recipeInfos = {
    [2329] = { recipeID = 2329, learned = true, relativeDifficulty = 1 },
    [2330] = { recipeID = 2330, learned = false, relativeDifficulty = 0 },
    [3170] = { recipeID = 3170, learned = true, relativeDifficulty = 0 },
}
local showUnlearned = false
local dataSourceChanging = false
-- Whose list the window shows: nil = the player's own; else "linked",
-- "guildMember", "guild" or "npc".
local externalView = nil
_G.C_TradeSkillUI = {
    IsTradeSkillLinked = function()
        if externalView == "linked" then return true, "Otherplayer" end
        return false
    end,
    IsTradeSkillGuildMember = function() return externalView == "guildMember" end,
    IsTradeSkillGuild = function() return externalView == "guild" end,
    IsNPCCrafting = function() return externalView == "npc" end,
    GetChildProfessionInfo = function() return childInfo end,
    GetBaseProfessionInfo = function() return baseInfo end,
    GetAllRecipeIDs = function() return { 2329, 2330, 3170 } end,
    GetRecipeInfo = function(id) return recipeInfos[id] end,
    GetShowLearned = function() return true end,
    GetShowUnlearned = function() return showUnlearned end,
    IsDataSourceChanging = function() return dataSourceChanging end,
}

-- Recipe-list row frame as the tree view hands it out: GetElementData() is a
-- tree node whose .data holds recipeInfo (or categoryInfo for headers).
local function rowFrame(data)
    return { node = { data = data }, GetElementData = function(self) return self.node end }
end
local categoryRow = rowFrame({ categoryInfo = { name = "Potions" } })
local row2329 = rowFrame({ recipeInfo = { recipeID = 2329, relativeDifficulty = 1 } })
local row3170 = rowFrame({ recipeInfo = { recipeID = 3170, relativeDifficulty = 0 } })

local scrollBox = { frames = { categoryRow, row2329, row3170 }, callbacks = {}, registrations = 0 }
function scrollBox:EnumerateFrames() return ipairs(self.frames) end
function scrollBox:RegisterCallback(event, func, owner)
    self.registrations = self.registrations + 1
    self.callbacks[event] = { func = func, owner = owner }
end
function scrollBox:Trigger(event, ...)
    local cb = self.callbacks[event]
    if cb then cb.func(cb.owner, ...) end
end

local function shown(v) return { visible = v, IsShown = function(self) return self.visible end } end
-- The recipe page keeps its script hooks so a test can show/hide it the way
-- the client does (hooks run after the frame's own handler).
local function makePage()
    local page = shown(true)
    page.hooks = { OnShow = {}, OnHide = {} }
    function page:HookScript(script, fn) table.insert(self.hooks[script], fn) end
    function page:SetShownForTest(v)
        self.visible = v
        for _, fn in ipairs(self.hooks[v and "OnShow" or "OnHide"]) do fn(self) end
    end
    return page
end
local function makeProfessionsFrame()
    local f = shown(true)
    f.CraftingPage = makePage()
    f.CraftingPage.RecipeList = { ScrollBox = scrollBox }
    return f
end
_G.ProfessionsFrame = makeProfessionsFrame()

-- GetProfessions returns spell-book indices (nil for an empty slot).
_G.GetProfessions = function() return 1, nil, nil, 4, nil end
local professionsByIndex = {
    [1] = { "Alchemy", 136240, 152, 225, 2, 10, 171, 0 },
    [4] = { "Cooking", 133971, 40, 75, 1, 20, 185, 0 },
}
_G.GetProfessionInfo = function(index) return unpack(professionsByIndex[index]) end

local itemCalls = {}
_G.C_Item = {
    GetItemInfo = function(itemId)
        itemCalls[#itemCalls + 1] = itemId
        if itemId ~= 2589 then return nil end
        return "Linen Cloth", "|Hitem:2589|h[Linen Cloth]|h", 1, 5, 0, "Trade Goods", "Cloth",
            20, "", "icon-linen", 13
    end,
}
-- A global GetItemInfo must never be reached on Forever.
_G.GetItemInfo = function() error("global GetItemInfo called on Forever") end

local timers = {}
_G.C_Timer = { After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end }
local function runTimers()
    local list = timers
    timers = {}
    for _, t in ipairs(list) do t.fn() end
end

local function craftlibRecipe(id, name)
    return { id = id, name = name, itemId = id + 100000, reagents = {},
             skillRange = { orange = 1, yellow = 20, green = 40, gray = 60 },
             source = { type = "trainer", npcName = "Any Alchemy Trainer" } }
end

-- Load Family + Classic + Forever (+ the real Constants and Registry) into one
-- addon table, the way the TOC does.
local function loadAdapter(interface, projectId, camelot)
    setBuild(interface, projectId, camelot)
    local addon = {}
    addon.dependencyCheckFailed = true
    addon.db = { char = { learnedRecipes = {} } }
    addon.Utils = { DeepCopy = deepcopy }
    function addon:Debug() end
    addon.events = {}
    function addon:RegisterEvent(event, handler) self.events[event] = handler end
    assert(loadfile("Core/Constants.lua"))("LazyProf", addon)
    assert(loadfile("Core/Client/Family.lua"))("LazyProf", addon)
    assert(loadfile("Core/Client/Classic.lua"))("LazyProf", addon)
    assert(loadfile("Core/Client/Forever.lua"))("LazyProf", addon)
    assert(loadfile("Professions/Registry.lua"))("LazyProf", addon)
    addon.Professions.registry.alchemy = {
        id = 2259, name = "Alchemy", milestones = { 75, 150, 225, 300 },
        recipes = { craftlibRecipe(2329, "Elixir of Lion's Strength"),
                    craftlibRecipe(2330, "Minor Healing Potion"),
                    craftlibRecipe(3170, "Weak Troll's Blood Elixir") },
    }
    addon.Professions.registry.cooking = { id = 2550, name = "Cooking", milestones = {}, recipes = {} }
    return addon
end

local SURFACE = { "IsOpen", "AnchorFrame", "GetLine", "KnownRecipeIds", "PlayerSkill", "GetItemInfo",
                  "FindRecipeRow", "InvalidateRowCache", "UnlearnedHiddenByFilter", "Start", "RunDiagnostic" }

-- ===========================================================================
-- 1. Only the Forever adapter installs itself on a Forever client
-- ===========================================================================
section("selection", function()
    local p = "selection: "
    local forever = loadAdapter(16001)
    check(p .. "16001 installs LazyProf.Client", type(forever.Client) == "table")
    for _, m in ipairs(SURFACE) do
        check(p .. "Forever Client:" .. m .. " exists", forever.Client and type(forever.Client[m]) == "function")
    end
    local camelot = loadAdapter(11508, 18, 18)
    check(p .. "camelot project id installs the Forever adapter",
        camelot.Client and camelot.Client.UnlearnedHiddenByFilter and camelot.Client:UnlearnedHiddenByFilter() == true)
    local classic = loadAdapter(11508)
    check(p .. "classic client: Forever.lua does not replace the Classic adapter",
        classic.Client and classic.Client:UnlearnedHiddenByFilter() == false)
end)

-- ===========================================================================
-- 2. Window, profession line, known recipes, rows, ranks, items
-- ===========================================================================
section("forever", function()
    local p = "forever: "
    local addon = loadAdapter(16001)
    local Client = addon.Client

    -- Open state: the recipe list (CraftingPage) must be what the window shows.
    _G.ProfessionsFrame = nil
    check(p .. "IsOpen without ProfessionsFrame -> false", Client:IsOpen() == false)
    check(p .. "AnchorFrame without ProfessionsFrame -> nil", Client:AnchorFrame() == nil)
    _G.ProfessionsFrame = makeProfessionsFrame()
    _G.ProfessionsFrame.visible = false
    check(p .. "IsOpen hidden -> false", Client:IsOpen() == false)
    _G.ProfessionsFrame.visible = true
    _G.ProfessionsFrame.CraftingPage.visible = false
    check(p .. "IsOpen on the book page (no recipe list) -> false", Client:IsOpen() == false)
    _G.ProfessionsFrame.CraftingPage.visible = true
    check(p .. "IsOpen with the recipe list -> true", Client:IsOpen() == true)
    check(p .. "AnchorFrame -> ProfessionsFrame", Client:AnchorFrame() == _G.ProfessionsFrame)

    -- Profession line: child info, parent skill line.
    local key, rank, maxRank = Client:GetLine()
    check(p .. "GetLine -> alchemy, 152, 225", key == "alchemy" and rank == 152 and maxRank == 225,
        tostring(key) .. "," .. tostring(rank) .. "," .. tostring(maxRank))
    childInfo = { professionID = 0, skillLevel = 0, maxSkillLevel = 0 }
    baseInfo = { professionID = 185, skillLevel = 40, maxSkillLevel = 75 }
    key, rank, maxRank = Client:GetLine()
    check(p .. "GetLine child id 0 -> base info (cooking, 40, 75)",
        key == "cooking" and rank == 40 and maxRank == 75,
        tostring(key) .. "," .. tostring(rank) .. "," .. tostring(maxRank))
    childInfo = { professionID = 9999, parentProfessionID = 755, skillLevel = 12, maxSkillLevel = 75 }
    key, rank, maxRank = Client:GetLine()
    check(p .. "GetLine unmapped skill line -> nil key, rank kept", key == nil and rank == 12 and maxRank == 75)
    childInfo = { professionID = 2950, parentProfessionID = 197, skillLevel = 5, maxSkillLevel = 75 }
    check(p .. "GetLine mapped line without registered profession -> nil key", Client:GetLine() == nil)
    resetProfessionInfo()

    -- Someone else's list (linked, guild member, guild, NPC crafting): no
    -- profession key, so no path and nothing written to the learned cache.
    for _, view in ipairs({ "linked", "guildMember", "guild", "npc" }) do
        externalView = view
        key = Client:GetLine()
        check(p .. "GetLine while viewing " .. view .. " -> nil key", key == nil, key)
        addon.db.char.learnedRecipes = {}
        check(p .. view .. ": DetectActive -> nil", addon.Professions:DetectActive() == nil)
        addon.Professions:GetRecipesWithLearnedStatus(addon.Professions.active)
        check(p .. view .. ": learned cache untouched", next(addon.db.char.learnedRecipes) == nil)
    end
    externalView = nil
    check(p .. "own list again -> alchemy", Client:GetLine() == "alchemy")

    -- Known recipes: the full learned set from C_TradeSkillUI, not the rows.
    check(p .. "KnownRecipeIds -> 2329,3170", sortedKeys(Client:KnownRecipeIds("alchemy")) == "2329,3170",
        sortedKeys(Client:KnownRecipeIds("alchemy")))
    local savedFrames = scrollBox.frames
    scrollBox.frames = {}
    check(p .. "KnownRecipeIds independent of visible rows",
        sortedKeys(Client:KnownRecipeIds("alchemy")) == "2329,3170")
    scrollBox.frames = savedFrames

    local merged = {}
    for _, r in ipairs(addon.Professions:GetRecipesWithLearnedStatus("alchemy")) do merged[r.id] = r.learned end
    check(p .. "Registry learned via adapter",
        merged[2329] == true and merged[2330] == false and merged[3170] == true)
    check(p .. "DetectActive -> alchemy", addon.Professions:DetectActive() == "alchemy")

    -- Rows: matched by recipe id through the ScrollBox frames.
    local frame, difficulty = Client:FindRecipeRow({ id = 3170 })
    check(p .. "FindRecipeRow 3170 -> its row, optimal", frame == row3170 and difficulty == "optimal",
        tostring(difficulty))
    frame, difficulty = Client:FindRecipeRow({ id = 2329 })
    check(p .. "FindRecipeRow 2329 -> its row, medium", frame == row2329 and difficulty == "medium",
        tostring(difficulty))
    check(p .. "FindRecipeRow 2330 (unlearned, hidden) -> nil", Client:FindRecipeRow({ id = 2330 }) == nil)
    _G.ProfessionsFrame.CraftingPage.visible = false
    check(p .. "FindRecipeRow with the window closed -> nil", Client:FindRecipeRow({ id = 3170 }) == nil)
    _G.ProfessionsFrame.CraftingPage.visible = true
    Client:InvalidateRowCache()
    check(p .. "InvalidateRowCache keeps lookups working", Client:FindRecipeRow({ id = 3170 }) == row3170)

    showUnlearned = false
    check(p .. "UnlearnedHiddenByFilter with show-unlearned off -> true", Client:UnlearnedHiddenByFilter() == true)
    showUnlearned = true
    check(p .. "UnlearnedHiddenByFilter with show-unlearned on -> false", Client:UnlearnedHiddenByFilter() == false)
    showUnlearned = false

    -- Player ranks from the spell-book professions, matched by skill line.
    check(p .. "PlayerSkill alchemy -> 152", Client:PlayerSkill("alchemy") == 152, Client:PlayerSkill("alchemy"))
    check(p .. "PlayerSkill cooking -> 40", Client:PlayerSkill("cooking") == 40)
    check(p .. "PlayerSkill not trained -> 0", Client:PlayerSkill("tailoring") == 0)
    check(p .. "PlayerSkill unknown key -> 0", Client:PlayerSkill("nope") == 0)

    -- Items through C_Item.
    itemCalls = {}
    check(p .. "GetItemInfo returns every value", select("#", Client:GetItemInfo(2589)) == 11)
    check(p .. "GetItemInfo calls C_Item.GetItemInfo", itemCalls[1] == 2589, itemCalls[1])
    check(p .. "GetItemInfo 11th return is the sell price", select(11, Client:GetItemInfo(2589)) == 13)
    check(p .. "GetItemInfo uncached -> nil", Client:GetItemInfo(1) == nil)

    local lines = { "existing" }
    Client:RunDiagnostic(lines)
    check(p .. "RunDiagnostic appends lines", lines[1] == "existing" and type(lines[2]) == "string", #lines)
end)

-- ===========================================================================
-- 3. Start: events and the ScrollBox callbacks
-- ===========================================================================
section("start", function()
    local p = "start: "
    local addon = loadAdapter(16001)
    local counts = { open = 0, close = 0, update = 0, scroll = 0, display = 0 }
    function addon:UpdateDisplay() counts.display = counts.display + 1 end
    scrollBox.callbacks, scrollBox.registrations = {}, 0
    _G.ProfessionsFrame = nil
    addon.Client:Start({
        onOpen = function() counts.open = counts.open + 1 end,
        onClose = function() counts.close = counts.close + 1 end,
        onUpdate = function() counts.update = counts.update + 1 end,
        onScroll = function() counts.scroll = counts.scroll + 1 end,
    })
    check(p .. "registers exactly the four trade-skill events",
        sortedKeys(addon.events) == "TRADE_SKILL_CLOSE,TRADE_SKILL_DATA_SOURCE_CHANGED,TRADE_SKILL_LIST_UPDATE,TRADE_SKILL_SHOW",
        sortedKeys(addon.events))

    -- The professions UI loads on demand: no frame yet at the first show.
    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    check(p .. "TRADE_SKILL_SHOW -> onOpen", counts.open == 1)
    check(p .. "no ScrollBox yet -> nothing registered", scrollBox.registrations == 0)

    _G.ProfessionsFrame = makeProfessionsFrame()
    addon.events.TRADE_SKILL_LIST_UPDATE("TRADE_SKILL_LIST_UPDATE")
    check(p .. "TRADE_SKILL_LIST_UPDATE -> onUpdate", counts.update == 1)
    check(p .. "frame exists -> OnScroll registered", scrollBox.callbacks.OnScroll ~= nil)
    check(p .. "frame exists -> OnDataRangeChanged registered", scrollBox.callbacks.OnDataRangeChanged ~= nil)
    local registered = scrollBox.registrations
    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    addon.events.TRADE_SKILL_LIST_UPDATE("TRADE_SKILL_LIST_UPDATE")
    check(p .. "callbacks registered once", scrollBox.registrations == registered, scrollBox.registrations)

    timers = {}
    scrollBox:Trigger("OnScroll", 0.5, 0.2, 0.1)
    check(p .. "scroll waits 0.05s", #timers == 1 and timers[1].delay == 0.05)
    scrollBox:Trigger("OnDataRangeChanged", 1, 20)
    runTimers()
    check(p .. "two list changes in a row -> one onScroll", counts.scroll == 1, counts.scroll)

    dataSourceChanging = true
    addon.events.TRADE_SKILL_LIST_UPDATE("TRADE_SKILL_LIST_UPDATE")
    check(p .. "list update while the data source changes -> no onUpdate", counts.update == 2, counts.update)
    dataSourceChanging = false
    addon.events.TRADE_SKILL_DATA_SOURCE_CHANGED("TRADE_SKILL_DATA_SOURCE_CHANGED")
    check(p .. "TRADE_SKILL_DATA_SOURCE_CHANGED -> onUpdate", counts.update == 3, counts.update)

    -- "Show unlearned" toggled: the panels re-render the current path (the
    -- hint depends on it); no recalculation, and nothing on an unchanged value.
    showUnlearned = false
    addon.events.TRADE_SKILL_LIST_UPDATE("TRADE_SKILL_LIST_UPDATE")
    local display = counts.display
    showUnlearned = true
    addon.events.TRADE_SKILL_LIST_UPDATE("TRADE_SKILL_LIST_UPDATE")
    check(p .. "show-unlearned toggled -> UpdateDisplay once", counts.display == display + 1, counts.display - display)
    addon.events.TRADE_SKILL_LIST_UPDATE("TRADE_SKILL_LIST_UPDATE")
    check(p .. "unchanged filter -> no UpdateDisplay", counts.display == display + 1)
    showUnlearned = false
    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    display = counts.display
    addon.events.TRADE_SKILL_LIST_UPDATE("TRADE_SKILL_LIST_UPDATE")
    check(p .. "first list update of an open only records the filter", counts.display == display)
    showUnlearned = false

    -- Window closes: the page hides with it, then TRADE_SKILL_CLOSE; one close.
    local page = _G.ProfessionsFrame.CraftingPage
    local closes = counts.close
    page:SetShownForTest(false)
    addon.events.TRADE_SKILL_CLOSE("TRADE_SKILL_CLOSE")
    check(p .. "window close -> onClose once", counts.close == closes + 1, counts.close - closes)

    -- Reopen with the page showing before TRADE_SKILL_SHOW (same frame): one open.
    local opens = counts.open
    timers = {}
    page:SetShownForTest(true)
    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    runTimers()
    check(p .. "page shown then TRADE_SKILL_SHOW -> onOpen once", counts.open == opens + 1, counts.open - opens)

    -- Profession-book page: the trade skill stays open, the recipe page hides.
    closes = counts.close
    page:SetShownForTest(false)
    check(p .. "book page -> onClose", counts.close == closes + 1, counts.close - closes)
    check(p .. "book page -> IsOpen false", addon.Client:IsOpen() == false)
    addon.events.TRADE_SKILL_CLOSE("TRADE_SKILL_CLOSE")
    check(p .. "trade skill closing behind the book page -> no second onClose", counts.close == closes + 1)

    -- Back to the recipes (no TRADE_SKILL_SHOW): open after a frame.
    opens = counts.open
    timers = {}
    page:SetShownForTest(true)
    check(p .. "recipe page back -> open waits a frame", counts.open == opens and #timers == 1 and timers[1].delay == 0)
    runTimers()
    check(p .. "recipe page back -> onOpen", counts.open == opens + 1, counts.open - opens)

    -- TRADE_SKILL_SHOW first, then the page shows: one open.
    page:SetShownForTest(false)
    opens = counts.open
    timers = {}
    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    page:SetShownForTest(true)
    runTimers()
    check(p .. "TRADE_SKILL_SHOW then page shown -> onOpen once", counts.open == opens + 1, counts.open - opens)

    -- Switching profession while open still reports an open (recalculation).
    opens = counts.open
    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    check(p .. "TRADE_SKILL_SHOW while open -> onOpen", counts.open == opens + 1)
    closes = counts.close
    addon.events.TRADE_SKILL_CLOSE("TRADE_SKILL_CLOSE")
    check(p .. "TRADE_SKILL_CLOSE -> onClose", counts.close == closes + 1, counts.close - closes)
end)

-- ===========================================================================
-- 4. Milestone panel hint: next recipe unlearned and hidden by the window
-- ===========================================================================
section("hint", function()
    local p = "hint: "
    harness.stubWow({ interface = 16001 })
    _G.Enum = { TradeskillRelativeDifficulty = { Optimal = 0, Medium = 1, Easy = 2, Trivial = 3 } }
    _G.C_Timer = { After = function() end }
    local LazyProf = harness.loadLazyProf({
        "Core/Constants.lua",
        "Core/Utils.lua",
        "Core/Client/Family.lua",
        "Core/Client/Classic.lua",
        "Core/Client/Forever.lua",
        "Core/Config.lua",
        "Modules/Pathfinder/Pathfinder.lua",
        "Modules/UI/Widgets/RowPool.lua",
        "Modules/UI/MilestoneBreakdown.lua",
    })
    local Panel = LazyProf.MilestonePanelClass
    check(p .. "Forever adapter active", LazyProf.ClientFamily == "forever")

    local unlearned = { id = 2330, name = "Minor Healing Potion", learned = false,
                        source = { type = "trainer", npcName = "Any Alchemy Trainer" } }
    local learned = { id = 2329, name = "Elixir of Lion's Strength", learned = true,
                      source = { type = "trainer", npcName = "Any Alchemy Trainer" } }
    local function path(first)
        return { actualSkill = 10, gaps = {},
                 steps = { { skillStart = 1, skillEnd = 40, recipe = first },
                           { skillStart = 40, skillEnd = 80, recipe = learned } } }
    end

    showUnlearned = false
    local text = Panel.NextRecipeHint(path(unlearned))
    check(p .. "unlearned next recipe, unlearned hidden -> hint",
        text == "Next recipe is not learned yet - learn it from Any Alchemy Trainer", text)
    check(p .. "hint is plain ASCII", text and not text:find("[\128-\255]"))
    showUnlearned = true
    check(p .. "unlearned shown -> no hint", Panel.NextRecipeHint(path(unlearned)) == nil)
    showUnlearned = false
    check(p .. "learned next recipe -> no hint", Panel.NextRecipeHint(path(learned)) == nil)
    local later = path(learned)
    later.actualSkill = 50
    later.steps[2].recipe = unlearned
    check(p .. "follows the real skill to the next step",
        Panel.NextRecipeHint(later) == "Next recipe is not learned yet - learn it from Any Alchemy Trainer")
    check(p .. "no path -> no hint", Panel.NextRecipeHint(nil) == nil)
end)

-- ===========================================================================
-- 5. Addon compartment replaces the minimap button on Forever (ruling L8)
-- ===========================================================================
section("compartment", function()
    local p = "compartment: "
    local registered, created = 0, 0
    _G.LibStub = function(name)
        if name == "LibDataBroker-1.1" then
            return { NewDataObject = function(_self, _name, obj) created = created + 1; return obj end }
        end
        return {
            Register = function() registered = registered + 1 end,
            Show = function() error("LibDBIcon:Show on Forever") end,
            Hide = function() error("LibDBIcon:Hide on Forever") end,
        }
    end
    _G.InCombatLockdown = function() return false end
    _G.AddonCompartmentFrame = { name = "compartment" }
    _G.LazyProf_OnAddonCompartmentClick = nil

    local function loadButton(family)
        local addon = { ClientFamily = family, db = { profile = { minimap = { hide = false } } } }
        local toggled = {}
        addon.ProfessionBrowser = { Toggle = function(_self, anchor) toggled[#toggled + 1] = anchor end }
        assert(loadfile("Modules/UI/MinimapButton.lua"))("LazyProf", addon)
        _G.LazyProf = addon
        return addon, toggled
    end

    local addon, toggled = loadButton("forever")
    addon.MinimapButton:Initialize()
    check(p .. "Forever: no LibDBIcon button", registered == 0, registered)
    check(p .. "Forever: Show/Hide do not touch LibDBIcon",
        pcall(function() addon.MinimapButton:Show(); addon.MinimapButton:Hide() end))
    check(p .. "global click handler exists", type(_G.LazyProf_OnAddonCompartmentClick) == "function")
    _G.LazyProf_OnAddonCompartmentClick("LazyProf", "LeftButton")
    check(p .. "left click toggles the profession browser at the compartment",
        #toggled == 1 and toggled[1] == _G.AddonCompartmentFrame)

    addon.dependencyCheckFailed = true
    _G.LazyProf_OnAddonCompartmentClick("LazyProf", "LeftButton")
    check(p .. "click does nothing when the dependency check failed", #toggled == 1)

    local classic = loadButton("classic")
    classic.MinimapButton:Initialize()
    check(p .. "Classic: LibDBIcon button registered", registered == 1, registered)
end)

-- ===========================================================================
-- Diagnostic: /lp diag forever
-- ===========================================================================
section("diagnostic", function()
    local p = "diag: "
    resetProfessionInfo()
    externalView = nil
    _G.ProfessionsFrame = makeProfessionsFrame()
    local addon = loadAdapter(16001, 18, 18)
    _G.C_AddOns = { GetAddOnMetadata = function(name, field) return (name == "CraftLib" and field == "Version") and "0.11.0" or nil end }
    _G.CraftLib = {
        IsReady = function() return true end,
        GetActiveProfile = function() return "FOREVER" end,
        GetProfessions = function() return { alchemy = {} } end,
    }
    addon.Pathfinder = { currentPath = { steps = { 1, 2 }, complete = false, gaps = { { skillStart = 100 } } } }
    local lines = {}
    local ok, err = pcall(addon.Client.RunDiagnostic, addon.Client, lines)
    check(p .. "no Lua error", ok, err)
    local text = table.concat(lines, "\n")
    print(text)
    check(p .. "no SECTION ERROR", not text:find("SECTION ERROR", 1, true), text)
    check(p .. "craftlib version from metadata", text:find("version=0.11.0", 1, true) ~= nil, text)
    check(p .. "profile=FOREVER", text:find("profile=FOREVER", 1, true) ~= nil, text)
    check(p .. "recipes=3 learned=2", text:find("recipes=3 learned=2", 1, true) ~= nil, text)
    check(p .. "notInCraftLib=", text:find("notInCraftLib=", 1, true) ~= nil)
    check(p .. "path line", text:find("steps=2", 1, true) ~= nil and text:find("complete=false", 1, true) ~= nil)
    check(p .. "plain ASCII", not text:find("[\128-\255]"))

    -- One failing section does not stop the rest.
    local saved = C_TradeSkillUI.GetAllRecipeIDs
    C_TradeSkillUI.GetAllRecipeIDs = function() return nil end
    lines = {}
    ok, err = pcall(addon.Client.RunDiagnostic, addon.Client, lines)
    C_TradeSkillUI.GetAllRecipeIDs = saved
    text = table.concat(lines, "\n")
    check(p .. "nil GetAllRecipeIDs does not error", ok, err)
    check(p .. "nil ids reported, later sections still print",
        text:find("nil", 1, true) ~= nil and text:find("steps=2", 1, true) ~= nil, text)
    _G.CraftLib = nil
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
