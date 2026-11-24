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
_G.Enum = { TradeskillRelativeDifficulty = { Optimal = 0, Medium = 1, Easy = 2, Trivial = 3 },
            CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 },
            -- Containers: carried bags 0-5, the character bank's tabs 6-14, the account bank's 15-23.
            BagIndex = { Accountbanktab = -3, Characterbanktab = -2, Keyring = -1, Backpack = 0,
                         Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
                         CharacterBankTab_1 = 6, CharacterBankTab_9 = 14,
                         AccountBankTab_1 = 15, AccountBankTab_9 = 23 },
            BankType = { Character = 0, Guild = 1, Account = 2 },
            GameRule = { HardcoreRuleset = 10, CraftFromBankRestricted = 211, PvPRuleset = 213, RPRuleset = 214 } }
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

local SURFACE = { "IsOpen", "AnchorFrame", "PanelOffsetX", "GetLine", "NoDataProfessionName",
                  "KnownRecipeIds", "PlayerSkill", "ProfessionRank", "GetItemInfo", "FindRecipeRow", "InvalidateRowCache",
                  "UnlearnedHiddenByFilter", "Start", "RunDiagnostic",
                  "StartMerchant", "IsMerchantOpen", "MerchantAnchorFrame", "MerchantItems", "BuyFromMerchant",
                  "FreeBagSlots", "Money", "RunMerchantDiagnostic",
                  "StartTrainer", "TrainerInfo", "TrainerServices", "RunTrainerDiagnostic",
                  "BagContents", "IsBankOpen", "BankContents", "BankUsable", "BankKindOfBag", "CharacterIdentity", "Now",
                  "IsSelfFoundCharacter", "ShowError", "ClientItemCounts",
                  "StartStock", "RunStockDiagnostic" }

-- Names of the functions an adapter installs.
local function methodNames(client)
    local names = {}
    for k, v in pairs(client or {}) do
        if type(v) == "function" then names[#names + 1] = k end
    end
    table.sort(names)
    return table.concat(names, ",")
end

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
    -- Callers never branch on the family: both adapters expose the same methods.
    check(p .. "Classic and Forever adapters expose the same methods",
        methodNames(classic.Client) == methodNames(forever.Client),
        methodNames(classic.Client) .. " vs " .. methodNames(forever.Client))
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
    -- The side tabs hang 55 px outside the window's right edge: panels go 10 px past them.
    check(p .. "PanelOffsetX -> 65 (10 px right of the 55 px side tabs)", Client:PanelOffsetX() == 65,
        Client:PanelOffsetX())

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

    -- A profession without data: the name the window shows (parent line's name
    -- first, as Blizzard's displayName); nil for one with data or someone else's list.
    childInfo = { professionID = 2950, professionName = "Classic Tailoring", parentProfessionID = 197,
                  parentProfessionName = "Tailoring", skillLevel = 5, maxSkillLevel = 75 }
    check(p .. "NoDataProfessionName without data -> the parent line's name",
        Client:NoDataProfessionName() == "Tailoring", Client:NoDataProfessionName())
    childInfo = { professionID = 9999, professionName = "Runecrafting", skillLevel = 1, maxSkillLevel = 75 }
    check(p .. "NoDataProfessionName unmapped line, no parent -> its own name",
        Client:NoDataProfessionName() == "Runecrafting", Client:NoDataProfessionName())
    externalView = "linked"
    check(p .. "NoDataProfessionName on someone else's list -> nil", Client:NoDataProfessionName() == nil)
    externalView = nil
    childInfo = { professionID = 0, skillLevel = 0, maxSkillLevel = 0 }
    baseInfo = { professionID = 0, professionName = "", skillLevel = 0, maxSkillLevel = 0 }
    check(p .. "NoDataProfessionName without a profession -> nil", Client:NoDataProfessionName() == nil)
    resetProfessionInfo()
    childInfo.professionName, childInfo.parentProfessionName = "Classic Alchemy", "Alchemy"
    check(p .. "NoDataProfessionName for a profession with data -> nil", Client:NoDataProfessionName() == nil)
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

    -- Rank and cap with the profession window closed (3rd and 4th returns).
    local rank, cap = Client:ProfessionRank("alchemy")
    check(p .. "ProfessionRank alchemy -> 152 of 225", rank == 152 and cap == 225, tostring(rank) .. "/" .. tostring(cap))
    rank, cap = Client:ProfessionRank("cooking")
    check(p .. "ProfessionRank cooking -> 40 of 75", rank == 40 and cap == 75)
    rank, cap = Client:ProfessionRank("tailoring")
    check(p .. "ProfessionRank not trained -> 0, no cap", rank == 0 and cap == nil)

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
-- 4. Merchant: items, buying, bag slots, money, open / update / close
-- ===========================================================================
section("merchant", function()
    local p = "merchant: "
    local addon = loadAdapter(16001)
    local Client = addon.Client

    -- The merchant as the client reports it.
    local list = {
        { id = 2320, info = { name = "Coarse Thread", price = 10, stackCount = 1, numAvailable = -1, isPurchasable = true,
                              hasExtendedCost = false }, maxStack = 20 },
        { id = 3371, info = { name = "Empty Vial", price = 100, stackCount = 5, numAvailable = -1, isPurchasable = true,
                              hasExtendedCost = false }, maxStack = 20 },
        { id = 4340, info = { name = "Gray Dye", price = 350, stackCount = 1, numAvailable = 3, isPurchasable = true,
                              hasExtendedCost = false }, maxStack = 10 },
        { id = 9999, info = { name = "Token Thing", price = 0, stackCount = 1, numAvailable = -1, isPurchasable = false,
                              hasExtendedCost = true, currencyID = 77 }, maxStack = 1 },
        { id = 5555, info = nil, maxStack = 1 },   -- the client had nothing for this index
    }
    _G.GetMerchantNumItems = function() return #list end
    _G.C_MerchantFrame = { GetItemInfo = function(index)
        local entry = list[index]
        if entry and entry.info then return entry.info end
    end }
    _G.GetMerchantItemID = function(index) return list[index] and list[index].id end
    _G.GetMerchantItemMaxStack = function(index) return list[index] and list[index].maxStack end
    -- The Classic positional call does not exist on this client.
    _G.GetMerchantItemInfo = function() error("GetMerchantItemInfo called on Forever") end
    local bought = {}
    _G.BuyMerchantItem = function(index, quantity) bought[#bought + 1] = index .. "x" .. tostring(quantity) end
    _G.GetMoney = function() return 123456 end
    _G.C_Container = { GetContainerNumFreeSlots = function(bag)
        if bag == 0 then return 4, 0 end
        if bag == 1 then return 6, 0 end
        if bag == 2 then return 10, 8 end     -- a bag for certain items only
        if bag == 3 then return 2 end         -- no family reported
        return 0, 0
    end }
    _G.MerchantFrame = { IsShown = function() return true end }

    local items = Client:MerchantItems()
    check(p .. "one entry per index the client has data for", #items == 4, #items)
    local thread, vial, dye, token = items[1], items[2], items[3], items[4]
    check(p .. "index, item id and name", thread.index == 1 and thread.itemId == 2320 and thread.name == "Coarse Thread")
    check(p .. "price, bundle and max stack", vial.price == 100 and vial.bundle == 5 and vial.maxStack == 20)
    check(p .. "unlimited stock is passed as reported", thread.stock == -1 and dye.stock == 3)
    check(p .. "a gold-priced item has no extended cost", thread.extendedCost == false and thread.purchasable == true)
    check(p .. "a currency-priced item is flagged", token.extendedCost == true and token.purchasable == false)

    Client:BuyFromMerchant(2, 10)
    check(p .. "buy passes index and item count", bought[1] == "2x10", bought[1])
    check(p .. "money", Client:Money() == 123456)
    check(p .. "free slots count general-purpose bags only", Client:FreeBagSlots() == 12, Client:FreeBagSlots())
    check(p .. "anchor frame is the merchant window", Client:MerchantAnchorFrame() == _G.MerchantFrame)

    -- Events
    local seen = {}
    Client:StartMerchant({
        onShow = function() seen[#seen + 1] = "show" end,
        onUpdate = function() seen[#seen + 1] = "update" end,
        onClose = function() seen[#seen + 1] = "close" end,
    })
    check(p .. "not open before the event", Client:IsMerchantOpen() == false)
    addon.events.MERCHANT_UPDATE()
    check(p .. "an update with no merchant open is ignored", #seen == 0)
    addon.events.MERCHANT_SHOW()
    check(p .. "open after MERCHANT_SHOW", Client:IsMerchantOpen() == true and seen[1] == "show")
    addon.events.MERCHANT_UPDATE()
    addon.events.MERCHANT_FILTER_ITEM_UPDATE()
    check(p .. "list and filter updates are passed on", seen[2] == "update" and seen[3] == "update")
    addon.events.MERCHANT_CLOSED()
    addon.events.MERCHANT_CLOSED()
    check(p .. "a close is reported once", #seen == 4 and seen[4] == "close" and Client:IsMerchantOpen() == false)

    -- Diagnostic
    local lines = {}
    local ok, err = pcall(Client.RunMerchantDiagnostic, Client, lines)
    check(p .. "diag: no Lua error", ok, err)
    local text = table.concat(lines, "\n")
    check(p .. "diag: state line", text:find("numItems=5", 1, true) and text:find("money=123456", 1, true)
        and text:find("freeSlots=12", 1, true), text)
    check(p .. "diag: raw stock value shown", text:find("numAvailable=-1", 1, true) ~= nil, text)
    check(p .. "diag: an index without data is reported", text:find("raw[5] no info", 1, true) ~= nil, text)
    check(p .. "diag: adapter view", text:find("adapter items=4", 1, true) ~= nil, text)
    _G.C_MerchantFrame.GetItemInfo = function() error("boom") end
    lines = {}
    ok = pcall(Client.RunMerchantDiagnostic, Client, lines)
    check(p .. "diag: a failing section is reported, the rest still prints",
        ok and table.concat(lines, "\n"):find("SECTION ERROR", 1, true) ~= nil)
end)

-- ===========================================================================
-- 4c. Trainer: who is open, what it lists; names the client keeps secret
-- ===========================================================================
section("trainer", function()
    local p = "trainer: "
    local addon = loadAdapter(16001)
    local Client = addon.Client
    local tradeskill = true
    local secretName = false
    local SECRET = {}
    _G.IsTradeskillTrainer = function() return tradeskill end
    _G.issecretvalue = function(value) return value == SECRET end
    _G.UnitName = function(unit) return unit == "npc" and (secretName and SECRET or "Georgio Bolero") or "Player" end
    _G.UnitGUID = function(unit) return unit == "npc" and "Creature-0-4444-0-12-1346-0000ABCDEF" or "Player-1-X" end
    _G.UnitFactionGroup = function() return "Alliance", "Alliance" end
    _G.GetRealZoneText = function() return "Stormwind City" end
    _G.GetSubZoneText = function() return "Mage Quarter" end
    _G.strsplit = function(sep, text)
        local parts = {}
        for part in (text .. sep):gmatch("(.-)%" .. sep) do parts[#parts + 1] = part end
        return unpack(parts)
    end
    local position = { GetXY = function() return 0.5312, 0.8124 end }
    _G.C_Map = {
        GetBestMapForUnit = function() return 84 end,
        GetPlayerMapPosition = function(mapId) return mapId == 84 and position or nil end,
    }
    -- name, type, texture, reqLevel, subText, category
    local services = {
        { "Tailoring (Journeyman)", "available", 1, 10, "", "", cost = 500 },
        { "Linen Cloak", "available", 2, 0, "", "", cost = 50 },
        { "Woolen Cape", "unavailable", 3, 0, "", "", cost = 300 },
        { "Silk Robe", "used", 4, 0, "", "", cost = 0 },
        { nil, "available", 5, 0, "", "", cost = 1 },   -- name not loaded yet
    }
    _G.GetNumTrainerServices = function() return #services end
    _G.GetTrainerServiceInfo = function(index) return unpack(services[index], 1, 6) end
    _G.GetTrainerServiceCost = function(index) return services[index].cost, true end
    _G.GetTrainerServiceSkillReq = function() return "Tailoring", 50, true end
    _G.GetTrainerServiceSkillLine = function() return "Tailoring" end
    _G.GetTrainerTradeskillRankValues = function() return 60, 75, 0 end

    local seen = {}
    Client:StartTrainer({
        onShow = function() seen[#seen + 1] = "show" end,
        onUpdate = function() seen[#seen + 1] = "update" end,
        onClose = function() seen[#seen + 1] = "close" end,
    })
    check(p .. "no trainer open: no info, no services", Client:TrainerInfo() == nil and #Client:TrainerServices() == 0)
    addon.events.TRAINER_UPDATE()
    check(p .. "an update with no trainer open is ignored", #seen == 0)
    addon.events.TRAINER_SHOW()
    check(p .. "open reported", seen[1] == "show")

    local info = Client:TrainerInfo()
    check(p .. "name of the trainer", info and info.name == "Georgio Bolero", info and info.name)
    check(p .. "npc id from its GUID", info.npcId == 1346, info.npcId)
    check(p .. "zone and sub-zone", info.zone == "Stormwind City" and info.subZone == "Mage Quarter")
    check(p .. "map id and the player's position", info.mapId == 84 and info.x == 0.5312 and info.y == 0.8124)
    check(p .. "the player's faction", info.faction == "Alliance")

    local list = Client:TrainerServices()
    check(p .. "one entry per named service", #list == 4, #list)
    check(p .. "name, state and cost", list[2].name == "Linen Cloak" and list[2].state == "available" and list[2].cost == 50)
    check(p .. "state passed as the client reports it", list[3].state == "unavailable" and list[4].state == "used")
    check(p .. "index kept", list[3].index == 3)

    -- A name the client keeps secret is not read out.
    secretName = true
    info = Client:TrainerInfo()
    check(p .. "a secret name is not returned", info ~= nil and info.name == nil)
    secretName = false

    -- No position on this map.
    _G.C_Map.GetPlayerMapPosition = function() return nil end
    info = Client:TrainerInfo()
    check(p .. "no position: info without coordinates", info.x == nil and info.mapId == 84)
    _G.C_Map.GetBestMapForUnit = function() return nil end
    check(p .. "no map: no error", pcall(Client.TrainerInfo, Client) and Client:TrainerInfo().mapId == nil)
    _G.C_Map.GetBestMapForUnit = function() return 84 end
    _G.C_Map.GetPlayerMapPosition = function() return position end

    -- A class trainer is not a profession trainer.
    tradeskill = false
    check(p .. "not a profession trainer: no info", Client:TrainerInfo() == nil)
    tradeskill = true

    addon.events.TRAINER_UPDATE()
    addon.events.TRAINER_CLOSED()
    addon.events.TRAINER_CLOSED()
    check(p .. "update, then one close", table.concat(seen, ",") == "show,update,close", table.concat(seen, ","))
    check(p .. "closed: no info", Client:TrainerInfo() == nil)

    -- Diagnostic
    addon.events.TRAINER_SHOW()
    local lines = {}
    local ok, err = pcall(Client.RunTrainerDiagnostic, Client, lines)
    check(p .. "diag: no Lua error", ok, err)
    local text = table.concat(lines, "\n")
    check(p .. "diag: state", text:find("IsTradeskillTrainer=true services=5", 1, true) ~= nil, text)
    check(p .. "diag: raw service line", text:find("raw[2] name=Linen Cloak type=available", 1, true) ~= nil, text)
    check(p .. "diag: adapter info", text:find("adapter info: name=Georgio Bolero npcId=1346", 1, true) ~= nil, text)
    secretName = true
    lines = {}
    Client:RunTrainerDiagnostic(lines)
    text = table.concat(lines, "\n")
    check(p .. "diag: a secret name is reported as secret, not printed",
        text:find("nameSecret=true name=(secret)", 1, true) ~= nil, text)
    secretName = false
    _G.GetTrainerServiceInfo = function() error("boom") end
    lines = {}
    ok = pcall(Client.RunTrainerDiagnostic, Client, lines)
    check(p .. "diag: a failing section is reported", ok and table.concat(lines, "\n"):find("SECTION ERROR", 1, true) ~= nil)
    _G.issecretvalue = nil
end)

-- ===========================================================================
-- 4d. Stock: bags, the bank, who the character is, the clock
-- ===========================================================================
section("stock", function()
    local p = "stock: "

    -- Containers as the client reports them: [bag] = { slots, [slot] = info }.
    local containers = {}
    local slotCalls = {}      -- container ids asked for their slot count, in order
    local function slot(itemId, stack, isBound)
        return { itemID = itemId, stackCount = stack, isBound = isBound and true or false }
    end
    _G.C_Container = {
        GetContainerNumSlots = function(bag)
            slotCalls[#slotCalls + 1] = bag
            return containers[bag] and containers[bag].slots or 0
        end,
        GetContainerItemInfo = function(bag, index)
            return containers[bag] and containers[bag][index] or nil
        end,
        GetContainerNumFreeSlots = function() return 0, 0 end,
    }
    -- The Classic container calls do not exist on this client.
    _G.GetContainerNumSlots = function() error("global GetContainerNumSlots called on Forever") end
    _G.GetContainerItemInfo = function() error("global GetContainerItemInfo called on Forever") end

    -- The bank as C_Bank reports it.
    local bank = {
        [0] = { canView = true, locked = nil, tabs = { { ID = 6 }, { ID = 8 } } },
        [2] = { canView = true, locked = nil, tabs = { { ID = 15 } } },
    }
    local fetched = {}
    _G.C_Bank = {
        CanViewBank = function(bankType) return bank[bankType] and bank[bankType].canView or false end,
        FetchBankLockedReason = function(bankType) return bank[bankType] and bank[bankType].locked or nil end,
        FetchPurchasedBankTabData = function(bankType)
            fetched[#fetched + 1] = bankType
            return bank[bankType] and bank[bankType].tabs or {}
        end,
        ShouldUsePlayerBagsInBank = function() return true end,
    }

    local function resetContainers()
        containers = {
            [0] = { slots = 16, slot(2589, 20), slot(2589, 5), nil, slot(6948, 1, true) },
            [1] = { slots = 8, slot(2592, 10, true), slot(2592, 4) },
            [4] = { slots = 6, slot(4306, 7) },
            [5] = { slots = 32, slot(765, 11), slot(2447, 3) },              -- the reagent bag
            [6] = { slots = 28, slot(2589, 100), slot(2770, 9, true) },      -- character bank: the bank itself
            [7] = { slots = 16, slot(99999, 1) },                            -- not a purchased tab: never read
            [8] = { slots = 12, slot(2770, 1), slot(4306, 2) },              -- character bank: a bank bag
            [15] = { slots = 98, slot(2589, 60), slot(774, 2, true) },       -- account bank
            [-1] = { slots = 4, slot(5396, 1) },                             -- keyring: not stock
        }
    end
    resetContainers()

    local addon = loadAdapter(16001)
    local Client = addon.Client

    -- Bags -----------------------------------------------------------------
    slotCalls = {}
    local items, bound, backpackSlots = Client:BagContents()
    check(p .. "bags: stacks of one item are added up", items[2589] == 25, items[2589])
    check(p .. "bags: the reagent bag (5) is read", items[765] == 11 and items[2447] == 3)
    check(p .. "bags: every carried bag", items[2592] == 14 and items[4306] == 7 and items[6948] == 1)
    check(p .. "bags: nothing from the bank or the keyring", items[2770] == nil and items[99999] == nil and items[5396] == nil)
    check(p .. "bags: exactly containers 0 to 5 are asked", table.concat(slotCalls, ",") == "0,1,2,3,4,5",
        table.concat(slotCalls, ","))
    check(p .. "bags: soulbound counts are split off", bound[2592] == 10 and bound[6948] == 1 and bound[2589] == nil)
    check(p .. "bags: the backpack's slot count is the third return", backpackSlots == 16, backpackSlots)
    containers[0] = nil
    items, bound, backpackSlots = Client:BagContents()
    check(p .. "bags: a backpack that reports no slots is reported as such", backpackSlots == 0 and type(items) == "table")
    resetContainers()

    -- Bank kinds of a container id -------------------------------------------
    check(p .. "kind: 5 (reagent bag) is no bank", Client:BankKindOfBag(5) == nil)
    check(p .. "kind: 6 is the character bank", Client:BankKindOfBag(6) == "character")
    check(p .. "kind: 14 is the character bank", Client:BankKindOfBag(14) == "character")
    check(p .. "kind: 15 is the account bank", Client:BankKindOfBag(15) == "account")
    check(p .. "kind: 23 is the account bank", Client:BankKindOfBag(23) == "account")
    check(p .. "kind: 24 is no bank", Client:BankKindOfBag(24) == nil)
    check(p .. "kind: the backpack, the keyring and nothing are no bank",
        Client:BankKindOfBag(0) == nil and Client:BankKindOfBag(-1) == nil and Client:BankKindOfBag(nil) == nil)

    -- Events -----------------------------------------------------------------
    local seen = {}
    local openDuringClosing, openDuringClose, readDuringClosing = nil, nil, nil
    local before = {}
    for event in pairs(addon.events) do before[event] = true end
    Client:StartStock({
        onBankOpened = function() seen[#seen + 1] = "opened" end,
        onBankChanged = function(kind) seen[#seen + 1] = "changed:" .. tostring(kind) end,
        onBankClosing = function()
            seen[#seen + 1] = "closing"
            openDuringClosing = Client:IsBankOpen()
            readDuringClosing = Client:BankContents("character")
        end,
        onBankClosed = function()
            seen[#seen + 1] = "closed"
            openDuringClose = Client:IsBankOpen()
        end,
        onLogout = function() seen[#seen + 1] = "logout" end,
    })
    local added = {}
    for event in pairs(addon.events) do
        if not before[event] then added[event] = true end
    end
    -- BAG_UPDATE belongs to Core/Init.lua (one handler per event on the addon object).
    check(p .. "registers the two bank window events, the tab event and logout - not BAG_UPDATE",
        sortedKeys(added) == "BANKFRAME_CLOSED,BANKFRAME_OPENED,BANK_TABS_CHANGED,PLAYER_LOGOUT", sortedKeys(added))

    -- Closed: nothing is read, whatever the containers hold.
    check(p .. "bank closed at first", Client:IsBankOpen() == false)
    fetched = {}
    check(p .. "closed: no character bank", Client:BankContents("character") == nil)
    check(p .. "closed: no account bank", Client:BankContents("account") == nil)
    check(p .. "closed: the bank is not even asked", #fetched == 0, #fetched)
    check(p .. "closed: no bank is usable", Client:BankUsable("character") == false and Client:BankUsable("account") == false)
    addon.events.BANK_TABS_CHANGED("BANK_TABS_CHANGED", 0)
    check(p .. "closed: a tab change is not passed on", #seen == 0, table.concat(seen, ","))

    addon.events.BANKFRAME_OPENED("BANKFRAME_OPENED")
    check(p .. "BANKFRAME_OPENED -> onBankOpened, bank open", seen[1] == "opened" and Client:IsBankOpen() == true)

    -- Open: read tab by tab, by the tab's container id.
    fetched = {}
    items, bound = Client:BankContents("character")
    check(p .. "open: the character bank is asked by its bank type", fetched[1] == 0, fetched[1])
    check(p .. "open: both purchased tabs are read by their id", items and items[2589] == 100 and items[2770] == 10
        and items[4306] == 2)
    check(p .. "open: a container that is not a purchased tab is not read", items[99999] == nil)
    check(p .. "open: nothing from the bags or the account bank", items[765] == nil and items[774] == nil)
    check(p .. "open: soulbound counts are split off", bound and bound[2770] == 9 and bound[2589] == nil)
    check(p .. "open: the slots of its tabs together are the third return", select(3, Client:BankContents("character")) == 40,
        select(3, Client:BankContents("character")))
    fetched = {}
    items, bound = Client:BankContents("account")
    check(p .. "open: the account bank's slots", select(3, Client:BankContents("account")) == 98)
    check(p .. "open: the account bank is asked by its bank type", fetched[1] == 2, fetched[1])
    check(p .. "open: the account bank's tab", items and items[2589] == 60 and items[774] == 2 and bound[774] == 2)
    check(p .. "open: an unknown kind is nothing", Client:BankContents("guild") == nil and Client:BankContents(nil) == nil)
    -- Usable: the gates of a read, without reading a slot.
    slotCalls = {}
    check(p .. "open: both banks are usable", Client:BankUsable("character") == true and Client:BankUsable("account") == true)
    check(p .. "usable: no container is asked for its slots", #slotCalls == 0, table.concat(slotCalls, ","))
    check(p .. "usable: an unknown kind is not", Client:BankUsable("guild") == false and Client:BankUsable(nil) == false)

    -- A bank bag slot without a bag reports no slots: the rest still counts.
    bank[0].tabs = { { ID = 6 }, { ID = 9 }, { ID = 8 } }
    items = Client:BankContents("character")
    check(p .. "open: a tab without slots among others is fine", items and items[2589] == 100 and items[4306] == 2)
    bank[0].tabs = { { ID = 6 }, { ID = 8 } }

    -- Not readable now: nil, never an empty bank.
    bank[0].canView = false
    check(p .. "open but not viewable -> nil", Client:BankContents("character") == nil)
    check(p .. "open but not viewable: not usable", Client:BankUsable("character") == false)
    bank[0].canView = true
    bank[0].locked = 2
    check(p .. "open but locked -> nil", Client:BankContents("character") == nil)
    check(p .. "open but locked: not usable", Client:BankUsable("character") == false)
    bank[0].locked = 0   -- any reason counts as locked, as in the bank window itself
    check(p .. "open, locked with reason 0 -> nil", Client:BankContents("character") == nil)
    check(p .. "open, locked with reason 0: not usable", Client:BankUsable("character") == false)
    bank[0].locked = nil
    bank[0].tabs = {}
    check(p .. "open with no tabs -> nil", Client:BankContents("character") == nil)
    check(p .. "open with no tabs: not usable", Client:BankUsable("character") == false)
    bank[0].tabs = { { ID = 6 }, { ID = 8 } }
    local savedSix, savedEight = containers[6], containers[8]
    containers[6], containers[8] = nil, nil
    check(p .. "open, tabs that report no slots at all -> nil", Client:BankContents("character") == nil)
    check(p .. "but usable: the bank can be viewed, is not locked and has its tabs", Client:BankUsable("character") == true)
    containers[6], containers[8] = savedSix, savedEight
    bank[2].canView = false
    check(p .. "an account bank that cannot be viewed -> nil, the character bank still reads",
        Client:BankContents("account") == nil and Client:BankContents("character") ~= nil)
    check(p .. "and only the character bank is usable", Client:BankUsable("account") == false and Client:BankUsable("character") == true)
    bank[2].canView = true
    containers[6] = { slots = 28 }
    containers[8] = { slots = 12 }
    items = Client:BankContents("character")
    check(p .. "an empty bank that has slots is an empty table, not nil", type(items) == "table" and next(items) == nil)
    resetContainers()

    -- Tab events while open.
    addon.events.BANK_TABS_CHANGED("BANK_TABS_CHANGED", 0)
    addon.events.BANK_TABS_CHANGED("BANK_TABS_CHANGED", 2)
    addon.events.BANK_TABS_CHANGED("BANK_TABS_CHANGED", 1)   -- the guild bank is not ours
    check(p .. "BANK_TABS_CHANGED -> onBankChanged with the kind",
        seen[2] == "changed:character" and seen[3] == "changed:account" and #seen == 3, table.concat(seen, ","))

    addon.events.BANKFRAME_CLOSED("BANKFRAME_CLOSED")
    addon.events.BANKFRAME_CLOSED("BANKFRAME_CLOSED")
    check(p .. "BANKFRAME_CLOSED twice -> one closing notice, then one close",
        #seen == 5 and seen[4] == "closing" and seen[5] == "closed", table.concat(seen, ","))
    -- A read that is still owed can be taken during the closing notice ...
    check(p .. "the bank still counts as open during the closing notice", openDuringClosing == true)
    check(p .. "and can still be read then", readDuringClosing ~= nil and readDuringClosing[2589] == 100)
    -- ... and never after it.
    check(p .. "the bank counts as closed inside onBankClosed", openDuringClose == false)
    check(p .. "closed again: nothing is read", Client:IsBankOpen() == false and Client:BankContents("character") == nil)
    check(p .. "closed again: no bank is usable", Client:BankUsable("character") == false and Client:BankUsable("account") == false)

    addon.events.PLAYER_LOGOUT("PLAYER_LOGOUT")
    check(p .. "PLAYER_LOGOUT -> onLogout", seen[6] == "logout", table.concat(seen, ","))

    -- Who the character is -----------------------------------------------------
    local rules = { [213] = true }   -- PvP
    local region = "EU"
    local guidCalls = 0
    -- The stand-in for a secret value is text, like a real GUID: only the
    -- secret check can keep it out (a type check would let it through).
    local SECRET = "Player-4444-SECRET00"
    local regionNumber = 3
    local guid = "Player-4444-0A1B2C3D"
    _G.issecretvalue = function(value) return value == SECRET end
    _G.UnitGUID = function(unit)
        guidCalls = guidCalls + 1
        return unit == "player" and guid or nil
    end
    -- The key first, then the name in the client's language (never a key).
    _G.UnitFactionGroup = function() return "Horde", "Die Horde" end
    _G.NameUtil = { GetUnmodifiedUnitFullName = function(unit) return unit == "player" and "Thrag Ironhide" or nil end }
    _G.C_GameRules = { IsGameRuleActive = function(rule) return rules[rule] == true end }
    _G.GetCurrentRegionName = function() return region end
    _G.GetCurrentRegion = function() return regionNumber end
    -- The realm name is a shard name here: it must never be part of a key.
    _G.GetRealmName = function() error("GetRealmName called on Forever") end

    local function identityOf(setup)
        local fresh = loadAdapter(16001)
        if setup then setup() end
        return fresh.Client:CharacterIdentity(), fresh.Client
    end

    local id = identityOf()
    check(p .. "identity: the GUID", id.guid == "Player-4444-0A1B2C3D", id.guid)
    check(p .. "identity: the full name", id.name == "Thrag Ironhide", id.name)
    check(p .. "identity: the faction", id.faction == "Horde", id.faction)
    check(p .. "identity: the world is region and ruleset", id.world == "eu-pvp", id.world)

    rules = {}
    check(p .. "world: no ruleset flag -> normal", identityOf().world == "eu-normal", identityOf().world)
    rules = { [214] = true }
    check(p .. "world: roleplay", identityOf().world == "eu-rp", identityOf().world)
    rules = { [213] = true, [214] = true }
    region = "US"
    check(p .. "world: roleplay PvP, another region", identityOf().world == "us-rppvp", identityOf().world)
    rules = { [10] = true, [213] = true }
    check(p .. "world: hardcore PvP", identityOf().world == "us-hc-pvp", identityOf().world)
    rules = { [10] = true }
    check(p .. "world: hardcore", identityOf().world == "us-hc-normal", identityOf().world)
    rules = { [213] = true }
    -- A region without a name (test realms): its number stands in for it.
    region = ""
    id = identityOf()
    check(p .. "world: no region name -> the region's number", id.world == "region3-pvp" and id.guid ~= nil, id.world)
    region = nil
    check(p .. "world: nil region name -> the region's number too", identityOf().world == "region3-pvp", identityOf().world)
    regionNumber = 1
    rules = {}
    check(p .. "world: another number, another ruleset", identityOf().world == "region1-normal", identityOf().world)
    rules = { [213] = true }
    -- Neither a name nor a number: no world (nothing is then taken for the same world).
    regionNumber = nil
    id = identityOf()
    check(p .. "world: no name and no number -> no world, the rest still read", id.world == nil and id.guid ~= nil, id.world)
    regionNumber = "3"
    check(p .. "world: a number that is not one -> no world", identityOf().world == nil)
    regionNumber = 3
    region = "EU"
    check(p .. "world: with a name the number is not used", identityOf().world == "eu-pvp")

    -- A value the client keeps secret is not read out.
    guid = SECRET
    id = identityOf()
    check(p .. "identity: a secret GUID is not returned", id.guid == nil and id.name == "Thrag Ironhide", id.guid)
    guid = "Player-4444-0A1B2C3D"

    -- Nothing of it changes during a session: read once, when all of it is there.
    local client
    region, regionNumber = "", nil
    id, client = identityOf()
    region, regionNumber = "EU", 3
    check(p .. "identity: an incomplete read is tried again", client:CharacterIdentity().world == "eu-pvp")
    guidCalls = 0
    guid = "Player-4444-CHANGED"
    id = client:CharacterIdentity()
    check(p .. "identity: a complete read is kept", id.guid == "Player-4444-0A1B2C3D" and guidCalls == 0, guidCalls)
    guid = "Player-4444-0A1B2C3D"
    -- A read that lacks the GUID, the name or the faction is not kept: what
    -- could not be read in the first moments would be missing all session.
    do
        local savedNameUtil, savedFaction = _G.NameUtil, _G.UnitFactionGroup
        local nameReadable, factionReadable = false, true
        _G.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
            return (nameReadable and unit == "player") and "Thrag Ironhide" or nil
        end }
        _G.UnitFactionGroup = function()
            if factionReadable then return "Horde", "Die Horde" end
            return nil
        end
        id, client = identityOf()
        check(p .. "identity: the name cannot be read yet", id.name == nil and id.guid == "Player-4444-0A1B2C3D", id.name)
        nameReadable = true
        check(p .. "identity: a read without the name is not kept", client:CharacterIdentity().name == "Thrag Ironhide",
            client:CharacterIdentity().name)
        factionReadable = false
        id, client = identityOf()
        check(p .. "identity: the faction cannot be read yet", id.faction == nil and id.name == "Thrag Ironhide", id.faction)
        factionReadable = true
        check(p .. "identity: a read without the faction is not kept", client:CharacterIdentity().faction == "Horde",
            client:CharacterIdentity().faction)
        guid = SECRET
        id, client = identityOf()
        check(p .. "identity: the GUID cannot be read yet", id.guid == nil and id.faction == "Horde", id.guid)
        guid = "Player-4444-0A1B2C3D"
        check(p .. "identity: a read without the GUID is not kept", client:CharacterIdentity().guid == "Player-4444-0A1B2C3D",
            client:CharacterIdentity().guid)
        guidCalls = 0
        guid = "Player-4444-CHANGED"
        check(p .. "identity: the complete read that followed is", client:CharacterIdentity().guid == "Player-4444-0A1B2C3D"
            and guidCalls == 0, guidCalls)
        guid = "Player-4444-0A1B2C3D"
        _G.NameUtil, _G.UnitFactionGroup = savedNameUtil, savedFaction
    end
    -- The world is not kept: the game rules can read false in the first
    -- moments after login, and a world frozen then would be wrong for good.
    rules = {}
    id, client = identityOf()
    check(p .. "identity: the rules read false at first", id.world == "eu-normal" and id.guid ~= nil, id.world)
    rules = { [213] = true }
    guidCalls = 0
    id = client:CharacterIdentity()
    check(p .. "identity: the world is worked out again at every ask", id.world == "eu-pvp", id.world)
    check(p .. "identity: while who the character is stays the kept read", id.guid == "Player-4444-0A1B2C3D"
        and id.name == "Thrag Ironhide" and id.faction == "Horde" and guidCalls == 0, guidCalls)
    rules = { [10] = true, [213] = true }
    check(p .. "identity: and again", client:CharacterIdentity().world == "eu-hc-pvp", client:CharacterIdentity().world)
    rules = { [213] = true }

    -- Self-Found by the game's own flag -------------------------------------------
    local flag, flagAsked = true, 0
    _G.C_PlayerInfo = { IsSelfFoundActive = function()
        flagAsked = flagAsked + 1
        return flag
    end }
    check(p .. "Self-Found: the game's flag", Client:IsSelfFoundCharacter() == true)
    flag = false
    check(p .. "Self-Found: asked again at every call, not kept", Client:IsSelfFoundCharacter() == false and flagAsked == 2,
        flagAsked)
    for _, value in ipairs({ 1, "yes", {} }) do
        flag = value
        check(p .. "Self-Found: a value that is not true is false (" .. type(value) .. ")", Client:IsSelfFoundCharacter() == false)
    end
    flag = nil
    check(p .. "Self-Found: no value is false", Client:IsSelfFoundCharacter() == false)
    _G.C_PlayerInfo = nil

    -- Handing a message to the game's error handler ----------------------------
    do
        local savedHandler = _G.geterrorhandler
        local handed = {}
        _G.geterrorhandler = function() return function(message) handed[#handed + 1] = message end end
        Client:ShowError("LazyProf: something failed")
        check(p .. "ShowError: the message goes to the game's error handler",
            #handed == 1 and handed[1] == "LazyProf: something failed", handed[1])
        for _, case in ipairs({
            { "a client without an error handler", false },
            { "an error handler that is not a function", function() return "broken" end },
            { "an error handler that fails", function() return function() error("handler down") end end },
            { "asking for the error handler fails", function() error("no handler today") end },
        }) do
            _G.geterrorhandler = case[2] or nil
            local ran, err = pcall(Client.ShowError, Client, "another")
            check(p .. "ShowError: " .. case[1] .. " - nothing raised, nothing handed on", ran and #handed == 1, err)
        end
        _G.geterrorhandler = savedHandler
    end

    -- What the client itself counts of an item ----------------------------------
    do
        local asked = {}
        _G.C_Item.GetItemCount = function(itemInfo, includeBank, includeUses, includeReagentBank, includeAccountBank)
            asked[#asked + 1] = table.concat({ tostring(itemInfo), tostring(includeBank), tostring(includeUses),
                tostring(includeReagentBank), tostring(includeAccountBank) }, ",")
            return 5 + (includeBank and 100 or 0) + (includeAccountBank and 60 or 0)
        end
        local carried, withBank, withAccountBank = Client:ClientItemCounts(2589)
        check(p .. "client counts: carried only, with the bank, with the bank and the account bank",
            carried == 5 and withBank == 105 and withAccountBank == 165,
            tostring(carried) .. "," .. tostring(withBank) .. "," .. tostring(withAccountBank))
        -- All five arguments are passed, as Blizzard does; charges and the
        -- reagent bank are never asked for.
        check(p .. "client counts: asked three times, with all five arguments",
            table.concat(asked, " | ") == "2589,false,false,false,false | 2589,true,false,false,false | 2589,true,false,false,true",
            table.concat(asked, " | "))
        check(p .. "client counts: three values", select("#", Client:ClientItemCounts(2589)) == 3)
        -- Without an item nothing is asked of the client: the answer only
        -- says that this client has such a count.
        asked = {}
        carried, withBank, withAccountBank = Client:ClientItemCounts(nil)
        check(p .. "client counts: without an item nothing is asked, and the three are zero",
            carried == 0 and withBank == 0 and withAccountBank == 0 and #asked == 0, #asked)
        _G.C_Item.GetItemCount = function() error("count down") end
        check(p .. "client counts: a failing count call is the caller's to catch", pcall(Client.ClientItemCounts, Client, 2589) == false)
        _G.C_Item.GetItemCount = nil
    end

    -- The clock ----------------------------------------------------------------
    _G.GetServerTime = function() return 1763900000 end
    check(p .. "Now is the server time", Client:Now() == 1763900000, Client:Now())

    -- Diagnostic -----------------------------------------------------------------
    addon.events.BANKFRAME_OPENED("BANKFRAME_OPENED")
    local lines = {}
    local ok, err = pcall(Client.RunStockDiagnostic, Client, lines)
    check(p .. "diag: no Lua error", ok, err)
    local text = table.concat(lines, "\n")
    check(p .. "diag: no SECTION ERROR", not text:find("SECTION ERROR", 1, true), text)
    check(p .. "diag: the bags, container by container", text:find("bag[5] slots=32 used=2", 1, true) ~= nil, text)
    check(p .. "diag: bank state", text:find("bank: open=true", 1, true) ~= nil
        and text:find("usesPlayerBags=true", 1, true) ~= nil, text)
    check(p .. "diag: raw facts of the character bank",
        text:find("bank character: canView=true lockedReason=nil tabs=2 [6:28/2 8:12/2]", 1, true) ~= nil, text)
    check(p .. "diag: raw facts of the account bank",
        text:find("bank account: canView=true lockedReason=nil tabs=1 [15:98/2]", 1, true) ~= nil, text)
    check(p .. "diag: what the adapter reads", text:find("adapter bank character: items=3 soulbound=1", 1, true) ~= nil, text)
    check(p .. "diag: the world's parts", text:find("region=EU", 1, true) ~= nil and text:find("regionNumber=3", 1, true) ~= nil
        and text:find("pvp=true", 1, true) ~= nil, text)
    -- Whether crafts may take reagents from the bank (they would change it while it is closed).
    check(p .. "diag: crafting from the bank", text:find("crafting from the bank: restricted=false", 1, true) ~= nil, text)
    rules[211] = true
    lines = {}
    Client:RunStockDiagnostic(lines)
    check(p .. "diag: crafting from the bank, restricted",
        table.concat(lines, "\n"):find("crafting from the bank: restricted=true", 1, true) ~= nil, table.concat(lines, "\n"))
    rules[211] = nil
    local savedRule = _G.Enum.GameRule.CraftFromBankRestricted
    _G.Enum.GameRule.CraftFromBankRestricted = nil
    lines = {}
    Client:RunStockDiagnostic(lines)
    check(p .. "diag: a client without that rule says so and prints the rest",
        table.concat(lines, "\n"):find("crafting from the bank: this client has no such rule", 1, true) ~= nil
        and table.concat(lines, "\n"):find("region=EU", 1, true) ~= nil, table.concat(lines, "\n"))
    _G.Enum.GameRule.CraftFromBankRestricted = savedRule
    check(p .. "diag: plain ASCII", not text:find("[\128-\255]"))
    bank[2].canView = false
    lines = {}
    Client:RunStockDiagnostic(lines)
    check(p .. "diag: a bank that cannot be read says so",
        table.concat(lines, "\n"):find("adapter bank account: not readable now", 1, true) ~= nil, table.concat(lines, "\n"))
    bank[2].canView = true
    _G.C_Bank.FetchPurchasedBankTabData = function() error("boom") end
    lines = {}
    ok = pcall(Client.RunStockDiagnostic, Client, lines)
    check(p .. "diag: a failing section is reported, the rest still prints",
        ok and table.concat(lines, "\n"):find("SECTION ERROR", 1, true) ~= nil
        and table.concat(lines, "\n"):find("region=EU", 1, true) ~= nil)
    _G.issecretvalue = nil
    _G.GetContainerNumSlots, _G.GetContainerItemInfo, _G.GetRealmName, _G.GetCurrentRegion = nil, nil, nil, nil
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

-- ===========================================================================
-- Diagnostic: the window is closed / CraftLib data checked against the client
-- ===========================================================================
section("diagnostic closed window", function()
    local p = "diag closed: "
    resetProfessionInfo()
    externalView = nil
    _G.ProfessionsFrame = makeProfessionsFrame()
    _G.ProfessionsFrame.visible = false
    local addon = loadAdapter(16001, 18, 18)
    _G.C_AddOns = { GetAddOnMetadata = function() return "0.11.0" end }
    _G.CraftLib = { IsReady = function() return true end, GetActiveProfile = function() return "FOREVER" end,
                    GetProfessions = function() return {} end }
    addon.Pathfinder = {}
    local lines = {}
    local ok, err = pcall(addon.Client.RunDiagnostic, addon.Client, lines)
    local text = table.concat(lines, "\n")
    check(p .. "no Lua error", ok, err)
    check(p .. "says the window is closed", text:find("profession window is closed", 1, true) ~= nil, text)
    check(p .. "no check against CraftLib", text:find("check difficulty", 1, true) == nil, text)

    _G.ProfessionsFrame.visible = true
    childInfo = { professionID = 0, skillLevel = 0, maxSkillLevel = 0 }
    baseInfo = { professionID = 0, skillLevel = 0, maxSkillLevel = 0 }
    lines = {}
    addon.Client:RunDiagnostic(lines)
    text = table.concat(lines, "\n")
    check(p .. "no profession: no misleading notInCraftLib count",
        text:find("notInCraftLib=", 1, true) == nil and text:find("no open profession to compare", 1, true) ~= nil, text)
    _G.CraftLib = nil
end)

section("diagnostic check", function()
    local p = "diag check: "
    resetProfessionInfo()
    externalView = nil
    _G.ProfessionsFrame = makeProfessionsFrame()
    local addon = loadAdapter(16001, 18, 18)
    _G.C_AddOns = { GetAddOnMetadata = function() return "0.11.0" end }
    _G.CraftLib = { IsReady = function() return true end, GetActiveProfile = function() return "FOREVER" end,
                    GetProfessions = function() return {} end }
    addon.Pathfinder = {}
    -- CraftLib: every recipe orange 1 / yellow 20 / green 40 / gray 60, product id + 100000.
    addon.Professions.registry.alchemy.recipes[1].reagents = { { itemId = 2589, count = 2 }, { itemId = 3371, count = 1 } }
    childInfo.skillLevel = 30          -- between yellow and green: medium
    childInfo.skillModifier = 0
    local saved = deepcopy(recipeInfos)
    recipeInfos[2329].maxTrivialLevel = 60   -- agrees
    recipeInfos[2330].maxTrivialLevel = 65   -- differs
    recipeInfos[3170].maxTrivialLevel = 0    -- client gives none
    -- 2329 learned medium (agrees), 3170 learned optimal (differs), 2330 not learned (skipped)
    C_TradeSkillUI.GetRecipeSchematic = function(id, isRecraft)
        assert(isRecraft == false, "isRecraft")
        if id == 2329 then
            return { outputItemID = 102329, reagentSlotSchematics = {
                { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 3371 } } },
                { reagentType = 1, quantityRequired = 2, reagents = { { itemID = 2589 } } },
                { reagentType = 0, quantityRequired = 1, reagents = { { itemID = 5555 } } },
            } }
        end
        if id == 2330 then
            return { outputItemID = 999, reagentSlotSchematics = {
                { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 2447 } } },
            } }
        end
        error("no schematic")
    end
    local lines = {}
    local ok, err = pcall(addon.Client.RunDiagnostic, addon.Client, lines)
    C_TradeSkillUI.GetRecipeSchematic = nil
    recipeInfos = saved
    local text = table.concat(lines, "\n")
    print(text)
    check(p .. "no Lua error", ok, err)
    check(p .. "no SECTION ERROR", not text:find("SECTION ERROR", 1, true), text)
    check(p .. "what was compared", text:find("check: alchemy, 3 recipes in both the client and CraftLib", 1, true) ~= nil, text)
    check(p .. "difficulty at the current skill",
        text:find("check difficulty at skill 30 (+0): agree=1 differ=1 sample(id:client/craftlib)=[3170:optimal/medium]", 1, true) ~= nil, text)
    check(p .. "gray level",
        text:find("check gray (client maxTrivialLevel): agree=1 differ=1 noClientValue=1 sample(id:client/craftlib)=[2330:65/60]", 1, true) ~= nil, text)
    check(p .. "reagents (basic slots only)",
        text:find("check reagents: agree=1 differ=1 errors=1 sample(id)=[2330]", 1, true) ~= nil, text)
    check(p .. "product",
        text:find("check product: agree=1 differ=1 sample(id:client/craftlib)=[2330:999/102330]", 1, true) ~= nil, text)
    check(p .. "plain ASCII", not text:find("[\128-\255]"))

    -- The racial modifier counts toward the skill the colours use.
    resetProfessionInfo()
    childInfo.skillLevel = 15
    childInfo.skillModifier = 15
    C_TradeSkillUI.GetRecipeSchematic = function() return { reagentSlotSchematics = {} } end
    lines = {}
    addon.Client:RunDiagnostic(lines)
    C_TradeSkillUI.GetRecipeSchematic = nil
    text = table.concat(lines, "\n")
    check(p .. "skill includes the modifier", text:find("check difficulty at skill 30 (+15)", 1, true) ~= nil, text)

    -- A learned recipe below CraftLib's orange level: that orange is too high.
    addon.Professions.registry.alchemy.recipes[3].skillRange = { orange = 50, yellow = 60, green = 70, gray = 80 }
    C_TradeSkillUI.GetRecipeSchematic = function() return { reagentSlotSchematics = {} } end
    lines = {}
    addon.Client:RunDiagnostic(lines)
    text = table.concat(lines, "\n")
    check(p .. "learned below orange counts as a difference",
        text:find("[3170:optimal/belowOrange]", 1, true) ~= nil, text)

    -- Someone else's list: the check says why it did not run.
    externalView = "linked"
    lines = {}
    addon.Client:RunDiagnostic(lines)
    C_TradeSkillUI.GetRecipeSchematic = nil
    externalView = nil
    text = table.concat(lines, "\n")
    check(p .. "not your own list: check skipped with a reason",
        text:find("check: skipped", 1, true) ~= nil and text:find("check difficulty", 1, true) == nil, text)
    _G.CraftLib = nil
    resetProfessionInfo()
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
