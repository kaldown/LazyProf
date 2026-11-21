-- scripts/test_client.lua
--
-- Client adapter: Core/Client/Family.lua picks the client family once at load
-- ("forever" when WOW_PROJECT_ID == WOW_PROJECT_CAMELOT, both set, or when the
-- interface is 16000-19999; else "classic"), and Core/Client/Classic.lua is the
-- Classic implementation of LazyProf.Client (skill line, known recipes, player
-- skill, item info, anchor frame, events, diagnostic). Also checks that
-- Core/Init.lua routes its profession events through Client:Start.
--
-- Run from the addon root:  lua5.1 scripts/test_client.lua
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

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end

local function setBuild(interface, projectId, camelot)
    _G.GetBuildInfo = function() return "0.0.0", "0", "Jan 1 2000", interface end
    _G.WOW_PROJECT_ID = projectId
    _G.WOW_PROJECT_CAMELOT = camelot
end

local function family(interface, projectId, camelot)
    setBuild(interface, projectId, camelot)
    local addon = {}
    assert(loadfile("Core/Client/Family.lua"))("LazyProf", addon)
    return addon.ClientFamily
end

-- ===========================================================================
-- 1. Family detection (ruling L2)
-- ===========================================================================
section("family", function()
    local p = "family: "
    check(p .. "16001 -> forever", family(16001) == "forever", family(16001))
    check(p .. "11508 -> classic", family(11508) == "classic", family(11508))
    check(p .. "WOW_PROJECT_ID == WOW_PROJECT_CAMELOT == 18 with 11508 -> forever",
        family(11508, 18, 18) == "forever", family(11508, 18, 18))
    check(p .. "20505 -> classic", family(20505) == "classic")
    check(p .. "30300 -> classic", family(30300) == "classic")
    check(p .. "38001 -> classic", family(38001) == "classic")
    check(p .. "16000 -> forever", family(16000) == "forever")
    check(p .. "19999 -> forever", family(19999) == "forever")
    check(p .. "20000 -> classic", family(20000) == "classic")
    check(p .. "project id differs from CAMELOT -> classic", family(11508, 2, 18) == "classic")
    check(p .. "CAMELOT nil -> classic", family(11508, 18, nil) == "classic")
    check(p .. "nil interface -> classic", family(nil) == "classic")
end)

-- ===========================================================================
-- Classic stubs: trade-skill window, skill lines, item info, timers, events.
-- ===========================================================================
local fixture = {}
local recipeLinkEnabled = true
local function visibleRows()
    local rows = {}
    for _, row in ipairs(fixture) do
        if row.visible then rows[#rows + 1] = row end
    end
    return rows
end

_G.GetTradeSkillLine = function() return "Tailoring", 152, 225 end
_G.GetNumTradeSkills = function() return #visibleRows() end
_G.GetTradeSkillInfo = function(i)
    local row = visibleRows()[i]
    if not row then return nil end
    return row.name, (row.kind == "header") and "header" or "optimal", 0
end
_G.GetTradeSkillRecipeLink = function(i)
    if not recipeLinkEnabled then return nil end
    local row = visibleRows()[i]
    if not row or row.kind == "header" or not row.spellId then return nil end
    return string.format("|cffffd000|Henchant:%d|h[%s]|h|r", row.spellId, row.name)
end
_G.GetTradeSkillItemLink = function(i)
    local row = visibleRows()[i]
    if not row or row.kind == "header" or not row.itemId then return nil end
    return string.format("|cffffffff|Hitem:%d::::::::28:::::1:3524:::::|h[%s]|h|r", row.itemId, row.name)
end

local skillLines = {
    { name = "Professions", header = true },
    { name = "Tailoring", rank = 152, max = 225 },
    { name = "Leatherworking", rank = 75 },                 -- no cap reported
}
_G.GetNumSkillLines = function() return #skillLines end
_G.GetSkillLineInfo = function(i)
    local s = skillLines[i]
    return s.name, s.header and true or false, nil, s.rank, 0, 0, s.max
end

_G.GetItemInfo = function(itemId)
    if itemId ~= 2589 then return nil end
    return "Linen Cloth", "|Hitem:2589|h[Linen Cloth]|h", 1, 5, 0, "Trade Goods", "Cloth",
        20, "", "icon-linen", 13
end

local timers = {}
_G.C_Timer = { After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end }
local function runTimers()
    local list = timers
    timers = {}
    for _, t in ipairs(list) do t.fn() end
end

local function frameStub(visible)
    return { visible = visible, IsVisible = function(self) return self.visible end }
end

-- Load Family + Classic (+ the real Registry) into one addon table, the way
-- the TOC does. Registry's load-time CraftLib Initialize() is skipped.
local function loadAdapter(interface, projectId, camelot)
    setBuild(interface or 11508, projectId, camelot)
    local addon = {}
    addon.dependencyCheckFailed = true
    addon.db = { char = { learnedRecipes = {} } }
    addon.Utils = { DeepCopy = deepcopy }
    addon.Constants = { PROFESSIONS = {
        tailoring = { name = "Tailoring" },
        leatherworking = { name = "Leatherworking" },
        mining = { name = "Mining" },
    } }
    function addon:Debug() end
    addon.events = {}
    function addon:RegisterEvent(event, handler) self.events[event] = handler end
    assert(loadfile("Core/Client/Family.lua"))("LazyProf", addon)
    assert(loadfile("Core/Client/Classic.lua"))("LazyProf", addon)
    assert(loadfile("Professions/Registry.lua"))("LazyProf", addon)
    return addon
end

local function craftlibRecipe(id, name, itemId)
    return {
        id = id, name = name, itemId = itemId,
        reagents = { { itemId = (itemId or id) * 10, count = 1, name = "Mat" } },
        skillRange = { orange = 1, yellow = 20, green = 40, gray = 60 },
        source = { type = "trainer" },
    }
end
local function installRegistry(addon)
    addon.Professions.registry["tailoring"] = {
        id = 197, name = "Tailoring", milestones = {},
        recipes = {
            craftlibRecipe(2152, "Light Armor Kit", 2304),
            craftlibRecipe(7953, "Deviate Scale Cloak", 6466),
            craftlibRecipe(900, "Enchant Bracer - Minor Health", nil),
            craftlibRecipe(7700, "Major Armor Kit", 70000),
        },
    }
    addon.Professions.registry["leatherworking"] = {
        id = 165, name = "Leatherworking", milestones = {}, recipes = {},
    }
end

local function sortedKeys(set)
    local keys = {}
    for k in pairs(set) do keys[#keys + 1] = k end
    table.sort(keys)
    return table.concat(keys, ",")
end

-- ===========================================================================
-- 2. Only the active family's adapter installs itself
-- ===========================================================================
section("selection", function()
    local p = "selection: "
    local classic = loadAdapter(11508)
    check(p .. "classic client installs LazyProf.Client", type(classic.Client) == "table")
    local forever = loadAdapter(16001)
    check(p .. "forever client: Classic.lua leaves LazyProf.Client unset", forever.Client == nil)
    local camelot = loadAdapter(11508, 18, 18)
    check(p .. "camelot project: Classic.lua leaves LazyProf.Client unset", camelot.Client == nil)
    for _, m in ipairs({ "IsOpen", "GetLine", "KnownRecipeIds", "PlayerSkill", "ProfessionRank", "GetItemInfo",
                         "AnchorFrame", "PanelOffsetX", "NoDataProfessionName", "Start", "RunDiagnostic" }) do
        check(p .. "Client:" .. m .. " exists", type(classic.Client[m]) == "function")
    end
end)

-- ===========================================================================
-- 3. Classic adapter methods
-- ===========================================================================
section("classic", function()
    local p = "classic: "
    local addon = loadAdapter(11508)
    installRegistry(addon)
    local Client = addon.Client

    local key, rank, maxRank = Client:GetLine()
    check(p .. "GetLine -> tailoring, 152, 225", key == "tailoring" and rank == 152 and maxRank == 225,
        tostring(key) .. "," .. tostring(rank) .. "," .. tostring(maxRank))

    check(p .. "NoDataProfessionName for a profession with data -> nil", Client:NoDataProfessionName() == nil)

    _G.GetTradeSkillLine = function() return "Cooking", 40, 75 end
    key, rank, maxRank = Client:GetLine()
    check(p .. "GetLine unknown line -> nil key, rank kept", key == nil and rank == 40 and maxRank == 75)
    check(p .. "NoDataProfessionName for a line without data -> its name",
        Client:NoDataProfessionName() == "Cooking", Client:NoDataProfessionName())
    _G.GetTradeSkillLine = function() return nil, 0, 0 end
    check(p .. "NoDataProfessionName without a line name -> nil", Client:NoDataProfessionName() == nil)
    _G.GetTradeSkillLine = function() return "Tailoring", 152, 225 end

    _G.TradeSkillFrame = nil
    check(p .. "IsOpen without TradeSkillFrame -> false", Client:IsOpen() == false)
    check(p .. "AnchorFrame without TradeSkillFrame -> nil", Client:AnchorFrame() == nil)
    _G.TradeSkillFrame = frameStub(false)
    check(p .. "IsOpen hidden -> false", Client:IsOpen() == false)
    _G.TradeSkillFrame = frameStub(true)
    check(p .. "IsOpen visible -> true", Client:IsOpen() == true)
    check(p .. "AnchorFrame -> TradeSkillFrame", Client:AnchorFrame() == _G.TradeSkillFrame)
    check(p .. "PanelOffsetX -> 10 (panels sit 10 px right of the window)", Client:PanelOffsetX() == 10,
        Client:PanelOffsetX())

    -- Known recipes: the same sets test_learned.lua expects.
    recipeLinkEnabled = true
    fixture = {
        { kind = "header", name = "Tailoring", visible = true },
        { kind = "recipe", name = "Light Armor Kit", spellId = 2152, itemId = 2304, visible = true },
        { kind = "recipe", name = "Deviate Scale Cloak", spellId = 7953, itemId = 6466, visible = true },
    }
    check(p .. "KnownRecipeIds link path", sortedKeys(Client:KnownRecipeIds("tailoring")) == "2152,7953",
        sortedKeys(Client:KnownRecipeIds("tailoring")))
    recipeLinkEnabled = false
    check(p .. "KnownRecipeIds item path (recipe link nil)",
        sortedKeys(Client:KnownRecipeIds("tailoring")) == "2152,7953",
        sortedKeys(Client:KnownRecipeIds("tailoring")))
    fixture = {
        { kind = "header", name = "Tailoring", visible = true },
        { kind = "recipe", name = "Enchant Bracer - Minor Health", spellId = 900, visible = true },
    }
    check(p .. "KnownRecipeIds name path (no item link)",
        sortedKeys(Client:KnownRecipeIds("tailoring")) == "900",
        sortedKeys(Client:KnownRecipeIds("tailoring")))
    fixture = {
        { kind = "header", name = "Tailoring", visible = true },
        { kind = "recipe", name = "Light Armor Kit", spellId = 2152, itemId = 2304, visible = true },
        { kind = "recipe", name = "Hidden", spellId = 7700, itemId = 70000, visible = false },
    }
    check(p .. "KnownRecipeIds only visible rows", sortedKeys(Client:KnownRecipeIds("tailoring")) == "2152")

    -- Registry merges the adapter's set.
    local merged = {}
    for _, r in ipairs(addon.Professions:GetRecipesWithLearnedStatus("tailoring")) do merged[r.id] = r.learned end
    check(p .. "Registry learned via adapter", merged[2152] == true and merged[7700] == false)
    check(p .. "Registry caches learned set",
        addon.db.char.learnedRecipes.tailoring and addon.db.char.learnedRecipes.tailoring[2152] == true)

    -- DetectActive via IsOpen + GetLine.
    check(p .. "DetectActive -> tailoring", addon.Professions:DetectActive() == "tailoring")
    _G.TradeSkillFrame = frameStub(false)
    check(p .. "DetectActive closed -> nil", addon.Professions:DetectActive() == nil
        and addon.Professions.active == nil)
    _G.TradeSkillFrame = frameStub(true)

    check(p .. "PlayerSkill tailoring -> 152", Client:PlayerSkill("tailoring") == 152, Client:PlayerSkill("tailoring"))
    check(p .. "PlayerSkill leatherworking -> 75", Client:PlayerSkill("leatherworking") == 75)
    check(p .. "PlayerSkill not trained -> 0", Client:PlayerSkill("mining") == 0)
    check(p .. "PlayerSkill unknown key -> 0", Client:PlayerSkill("nope") == 0)

    -- Rank and cap with the profession window closed (7th return of the skill line).
    local rank, cap = Client:ProfessionRank("tailoring")
    check(p .. "ProfessionRank tailoring -> 152 of 225", rank == 152 and cap == 225, tostring(rank) .. "/" .. tostring(cap))
    rank, cap = Client:ProfessionRank("leatherworking")
    check(p .. "ProfessionRank without a reported cap -> rank, no cap", rank == 75 and cap == nil, tostring(cap))
    skillLines[2].max = 30   -- a cap below the rank cannot be a cap
    rank, cap = Client:ProfessionRank("tailoring")
    check(p .. "ProfessionRank with a cap below the rank -> no cap", rank == 152 and cap == nil, tostring(cap))
    skillLines[2].max = 225
    rank, cap = Client:ProfessionRank("mining")
    check(p .. "ProfessionRank not trained -> 0, no cap", rank == 0 and cap == nil)

    check(p .. "GetItemInfo returns every value", select("#", Client:GetItemInfo(2589)) == 11)
    check(p .. "GetItemInfo 11th return is the sell price", select(11, Client:GetItemInfo(2589)) == 13)
    check(p .. "GetItemInfo uncached -> nil", Client:GetItemInfo(1) == nil)
end)

-- ===========================================================================
-- 4. Classic Start: events and the scroll hook
-- ===========================================================================
section("start", function()
    local p = "start: "
    local addon = loadAdapter(11508)
    installRegistry(addon)
    local counts = { open = 0, close = 0, update = 0, scroll = 0 }
    _G.TradeSkillListScrollFrame = nil
    addon.Client:Start({
        onOpen = function() counts.open = counts.open + 1 end,
        onClose = function() counts.close = counts.close + 1 end,
        onUpdate = function() counts.update = counts.update + 1 end,
        onScroll = function() counts.scroll = counts.scroll + 1 end,
    })
    check(p .. "registers exactly the three trade-skill events",
        sortedKeys(addon.events) == "TRADE_SKILL_CLOSE,TRADE_SKILL_SHOW,TRADE_SKILL_UPDATE",
        sortedKeys(addon.events))

    -- The list scroll frame only exists after the trade-skill UI first opens.
    local origCalls = 0
    local scroll = { scripts = {} }
    function scroll:GetScript(name) return self.scripts[name] end
    function scroll:SetScript(name, fn) self.scripts[name] = fn end
    scroll.scripts.OnVerticalScroll = function() origCalls = origCalls + 1 end
    _G.TradeSkillListScrollFrame = scroll

    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    check(p .. "TRADE_SKILL_SHOW -> onOpen", counts.open == 1)
    local hooked = scroll.scripts.OnVerticalScroll
    timers = {}
    hooked(scroll, 10)
    check(p .. "scroll keeps the original handler", origCalls == 1)
    check(p .. "scroll waits 0.05s", #timers == 1 and timers[1].delay == 0.05)
    runTimers()
    check(p .. "scroll -> onScroll after the delay", counts.scroll == 1)

    addon.events.TRADE_SKILL_SHOW("TRADE_SKILL_SHOW")
    check(p .. "second show does not re-hook", scroll.scripts.OnVerticalScroll == hooked)
    addon.events.TRADE_SKILL_UPDATE("TRADE_SKILL_UPDATE")
    check(p .. "TRADE_SKILL_UPDATE -> onUpdate", counts.update == 1)
    addon.events.TRADE_SKILL_CLOSE("TRADE_SKILL_CLOSE")
    check(p .. "TRADE_SKILL_CLOSE -> onClose", counts.close == 1)
    _G.TradeSkillListScrollFrame = nil
end)

-- ===========================================================================
-- 5. Classic RunDiagnostic appends the learned-recipe lines
-- ===========================================================================
section("diagnostic", function()
    local p = "diagnostic: "
    local addon = loadAdapter(11508)
    installRegistry(addon)
    _G.TradeSkillFrame = frameStub(true)
    recipeLinkEnabled = true
    fixture = {
        { kind = "header", name = "Tailoring", visible = true },
        { kind = "recipe", name = "Light Armor Kit", spellId = 2152, itemId = 2304, visible = true },
        { kind = "recipe", name = "Deviate Scale Cloak", spellId = 7953, itemId = 6466, visible = true },
    }
    local lines = { "existing" }
    addon.Client:RunDiagnostic(lines)
    check(p .. "appends after existing lines", lines[1] == "existing" and #lines > 5, #lines)
    check(p .. "header line", lines[2] == "diag learned: Tailoring (key=tailoring) skill=152/225", lines[2])
    local text = table.concat(lines, "\n")
    check(p .. "scan line", text:find("scan: GetNumTradeSkills=3  headers=1  recipeRows=2  parsedIds=2  unparsed=0", 1, true) ~= nil)
    check(p .. "resolver result line", text:find("result: GetRecipesWithLearnedStatus -> 2/4 learned", 1, true) ~= nil)
    check(p .. "probe line", text:find("probe: C_TradeSkillUI=false", 1, true) ~= nil)
end)

-- ===========================================================================
-- 6. Init.lua routes profession events through Client:Start
-- ===========================================================================
section("init", function()
    local p = "init: "
    _G.LibStub = function(_name)
        return { NewAddon = function(_self, addon) return addon end }
    end
    _G.GetTime = function() return 0 end
    local addon = {}
    assert(loadfile("Core/Init.lua"))("LazyProf", addon)
    local events = {}
    function addon:RegisterEvent(event, handler) events[event] = handler end
    local startCallbacks
    local line = { "tailoring", 152, 225 }
    local open = true
    addon.Client = {
        Start = function(_self, callbacks) startCallbacks = callbacks end,
        GetLine = function() return line[1], line[2], line[3] end,
        IsOpen = function() return open end,
    }
    addon:OnEnable()
    -- No profession-window event here (those go through Client:Start);
    -- AUCTION_HOUSE_CLOSED has the same name on every client family.
    check(p .. "Init registers only AUCTION_HOUSE_CLOSED, BAG_UPDATE and GET_ITEM_INFO_RECEIVED",
        sortedKeys(events) == "AUCTION_HOUSE_CLOSED,BAG_UPDATE,GET_ITEM_INFO_RECEIVED", sortedKeys(events))
    check(p .. "OnEnable calls Client:Start", type(startCallbacks) == "table")
    for _, cb in ipairs({ "onOpen", "onClose", "onUpdate", "onScroll" }) do
        check(p .. "callback " .. cb, startCallbacks and type(startCallbacks[cb]) == "function")
    end

    local recalcs, refreshes = {}, 0
    addon.ScheduleRecalculation = function(_self, reason) recalcs[#recalcs + 1] = reason end
    addon.ScheduleShoppingListRefresh = function() refreshes = refreshes + 1 end
    startCallbacks.onOpen()
    check(p .. "onOpen schedules a recalculation", recalcs[1] == "trade skill opened", recalcs[1])

    addon.lastCalculatedSkill = 152
    addon.lastCalculatedProfKey = "tailoring"
    startCallbacks.onUpdate()
    check(p .. "onUpdate with unchanged skill and profession does not recalc", #recalcs == 1)
    line[2] = 153
    startCallbacks.onUpdate()
    check(p .. "onUpdate with changed skill recalcs", recalcs[2] == "skill changed", recalcs[2])
    -- Another profession at the same skill while the window stays open.
    addon.lastCalculatedSkill = 153
    line[1] = "leatherworking"
    startCallbacks.onUpdate()
    check(p .. "onUpdate with another profession at the same skill recalcs",
        recalcs[3] == "profession changed", recalcs[3])
    addon.lastCalculatedProfKey = "leatherworking"
    startCallbacks.onUpdate()
    check(p .. "onUpdate after that recalc does not recalc again", #recalcs == 3, #recalcs)
    -- A line with no registered profession (nil key) counts as a change too.
    line[1] = nil
    startCallbacks.onUpdate()
    check(p .. "onUpdate switching to an unregistered line recalcs", recalcs[4] == "profession changed", recalcs[4])
    line[1] = "tailoring"

    addon:OnBagUpdate()
    check(p .. "bag update while open refreshes the list", refreshes == 1)
    open = false
    addon:OnBagUpdate()
    check(p .. "bag update while closed does nothing", refreshes == 1)

    local hidden = 0
    local panel = { Hide = function() hidden = hidden + 1 end }
    panel.OnProfessionClosed = panel.Hide
    addon.ArrowManager, addon.GuideWindow, addon.MissingMaterialsPanel, addon.RecipeDetails =
        panel, panel, panel, panel
    startCallbacks.onClose()
    check(p .. "onClose hides the arrow, the window and the two panels", hidden == 4, hidden)

    local refreshed = 0
    addon.ArrowManager = { RefreshPosition = function() refreshed = refreshed + 1 end }
    startCallbacks.onScroll()
    check(p .. "onScroll refreshes the arrow position", refreshed == 1)
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
