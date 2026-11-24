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
                         "AnchorFrame", "PanelOffsetX", "NoDataProfessionName", "Start", "RunDiagnostic",
                         "StartMerchant", "IsMerchantOpen", "MerchantAnchorFrame", "MerchantItems", "BuyFromMerchant",
                         "FreeBagSlots", "Money", "RunMerchantDiagnostic",
                         "StartTrainer", "TrainerInfo", "TrainerServices", "RunTrainerDiagnostic",
                         "BagContents", "IsBankOpen", "BankContents", "BankUsable", "BankKindOfBag", "CharacterIdentity", "Now",
                         "IsSelfFoundCharacter",
                         "StartStock", "RunStockDiagnostic" }) do
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
-- 4b. Merchant: the positional item call, and staying inert without it
-- ===========================================================================
section("merchant", function()
    local p = "merchant: "
    local addon = loadAdapter(11508)
    local Client = addon.Client
    local list = {
        { "Coarse Thread", "tex", 10, 1, -1, true, true, nil, id = 2320, maxStack = 20 },
        { "Empty Vial", "tex", 100, 5, -1, true, true, nil, id = 3371, maxStack = 20 },
        { "Gray Dye", "tex", 350, 1, 3, true, true, nil, id = 4340, maxStack = 10 },
        { "Token Thing", "tex", 0, 1, -1, true, true, true, id = 9999, maxStack = 1 },
        { "Odd", "tex", nil, 1, -1, true, true, nil, id = 1234, maxStack = 1 },   -- no price reported
    }
    _G.GetMerchantNumItems = function() return #list end
    _G.GetMerchantItemInfo = function(index) return unpack(list[index], 1, 8) end
    _G.GetMerchantItemID = nil   -- not on every Classic client: the link is parsed instead
    _G.GetMerchantItemLink = function(index) return "|cffffffff|Hitem:" .. list[index].id .. "::::|h[x]|h|r" end
    _G.GetMerchantItemMaxStack = function(index) return list[index].maxStack end
    local bought = {}
    _G.BuyMerchantItem = function(index, quantity) bought[#bought + 1] = index .. "x" .. tostring(quantity) end
    _G.GetMoney = function() return 5000 end
    _G.C_Container = nil
    _G.GetContainerNumFreeSlots = function(bag) return bag == 0 and 3 or (bag == 1 and 5 or 0), bag == 1 and 32 or 0 end

    local items = Client:MerchantItems()
    check(p .. "items with a sane price and stock", #items == 4, #items)
    check(p .. "item id from the link when the id call is missing", items[1].itemId == 2320, items[1].itemId)
    check(p .. "bundle from the quantity return", items[2].bundle == 5 and items[2].price == 100)
    check(p .. "stock passed as reported", items[1].stock == -1 and items[3].stock == 3)
    check(p .. "extended cost flagged", items[4].extendedCost == true and items[1].extendedCost == false)
    _G.GetMerchantItemID = function(index) return list[index].id + 1 end
    check(p .. "the id call is used when the client has it", Client:MerchantItems()[1].itemId == 2321)

    Client:BuyFromMerchant(1, 20)
    check(p .. "buy passes index and item count", bought[1] == "1x20", bought[1])
    check(p .. "money", Client:Money() == 5000)
    check(p .. "free slots: general-purpose bags only, older bag call", Client:FreeBagSlots() == 3, Client:FreeBagSlots())

    local seen = {}
    Client:StartMerchant({
        onShow = function() seen[#seen + 1] = "show" end,
        onUpdate = function() seen[#seen + 1] = "update" end,
        onClose = function() seen[#seen + 1] = "close" end,
    })
    addon.events.MERCHANT_SHOW()
    addon.events.MERCHANT_UPDATE()
    addon.events.MERCHANT_CLOSED()
    addon.events.MERCHANT_CLOSED()
    check(p .. "show, update, one close", table.concat(seen, ",") == "show,update,close", table.concat(seen, ","))

    local lines = {}
    local ok, err = pcall(Client.RunMerchantDiagnostic, Client, lines)
    check(p .. "diag: no Lua error", ok, err)
    check(p .. "diag: raw and adapter lines", table.concat(lines, "\n"):find("numAvailable=-1", 1, true) ~= nil
        and table.concat(lines, "\n"):find("adapter items=4", 1, true) ~= nil)

    -- A client without the calls: nothing listed, nothing bought, no error.
    _G.GetMerchantItemInfo, _G.BuyMerchantItem, _G.GetMoney, _G.GetContainerNumFreeSlots = nil, nil, nil, nil
    check(p .. "no item call: no items", #Client:MerchantItems() == 0)
    check(p .. "no buy call: no error", pcall(Client.BuyFromMerchant, Client, 1, 1))
    check(p .. "no money call: zero", Client:Money() == 0)
    check(p .. "no bag call: zero free slots", Client:FreeBagSlots() == 0)
    lines = {}
    check(p .. "diag without the calls: no Lua error", pcall(Client.RunMerchantDiagnostic, Client, lines))
end)

-- ===========================================================================
-- 4c. Trainer: nothing is read on Classic clients
-- ===========================================================================
section("trainer", function()
    local p = "trainer: "
    local addon = loadAdapter(11508)
    local Client = addon.Client
    -- Trainer calls exist on these clients, but must not be relied on.
    _G.GetNumTrainerServices = function() error("trainer list read on a Classic client") end
    _G.GetTrainerServiceInfo = function() error("trainer service read on a Classic client") end
    local called = false
    Client:StartTrainer({ onShow = function() called = true end, onUpdate = function() called = true end,
        onClose = function() called = true end })
    check(p .. "no trainer events are registered", addon.events.TRAINER_SHOW == nil and addon.events.TRAINER_UPDATE == nil)
    check(p .. "no trainer info", Client:TrainerInfo() == nil)
    check(p .. "no services", #Client:TrainerServices() == 0)
    local lines = {}
    Client:RunTrainerDiagnostic(lines)
    check(p .. "the diagnostic says so", lines[1] == "trainer: visited trainers are not recorded on this client", lines[1])
    check(p .. "nothing called back", called == false)
    _G.GetNumTrainerServices, _G.GetTrainerServiceInfo = nil, nil
end)

-- ===========================================================================
-- 4d. Stock: bags through either container API; the bank is not read here
-- ===========================================================================
section("stock", function()
    local p = "stock: "
    local addon = loadAdapter(11508)
    local Client = addon.Client

    -- [bag] = { slots, [slot] = { itemId, count, bound } }
    local bags = {
        [0] = { slots = 16, { 2589, 20 }, { 2589, 5 }, nil, { 6948, 1, true } },
        [1] = { slots = 8, { 2592, 10, true }, { 2592, 4 } },
        [4] = { slots = 6, { 4306, 7 } },
        [5] = { slots = 20, { 99999, 1 } },    -- not a carried bag on these clients
        [-1] = { slots = 4, { 5396, 1 } },     -- keyring
    }
    local asked = {}
    local function numSlots(bag)
        asked[#asked + 1] = bag
        return bags[bag] and bags[bag].slots or 0
    end

    -- The table-returning container API, where the client has it.
    _G.GetContainerNumSlots, _G.GetContainerItemInfo = nil, nil
    _G.C_Container = {
        GetContainerNumSlots = numSlots,
        GetContainerItemInfo = function(bag, index)
            local entry = bags[bag] and bags[bag][index]
            if not entry then return nil end
            return { itemID = entry[1], stackCount = entry[2], isBound = entry[3] and true or false }
        end,
    }
    local items, bound, backpackSlots = Client:BagContents()
    check(p .. "bags: stacks are added up", items[2589] == 25 and items[2592] == 14 and items[4306] == 7, items[2589])
    check(p .. "bags: the backpack and the four bags only", table.concat(asked, ",") == "0,1,2,3,4", table.concat(asked, ","))
    check(p .. "bags: nothing beyond them", items[99999] == nil and items[5396] == nil)
    check(p .. "bags: soulbound counts are split off", bound[2592] == 10 and bound[6948] == 1 and bound[2589] == nil)
    check(p .. "bags: the backpack's slot count is the third return", backpackSlots == 16, backpackSlots)

    -- The older positional API: count is the 2nd return, the link the 7th.
    _G.C_Container = nil
    _G.GetContainerNumSlots = numSlots
    _G.GetContainerItemInfo = function(bag, index)
        local entry = bags[bag] and bags[bag][index]
        if not entry then return nil end
        return "tex", entry[2], false, 1, false, false, "|cffffffff|Hitem:" .. entry[1] .. "::::::::60:::::|h[x]|h|r"
    end
    asked = {}
    items, bound, backpackSlots = Client:BagContents()
    check(p .. "older call: item id from the link, count from the second return",
        items[2589] == 25 and items[2592] == 14 and items[4306] == 7, items[2589])
    check(p .. "older call: the same five containers", table.concat(asked, ",") == "0,1,2,3,4", table.concat(asked, ","))
    check(p .. "older call: it does not say what is soulbound", next(bound) == nil)
    check(p .. "older call: backpack slots", backpackSlots == 16, backpackSlots)

    -- No container call at all: nothing, and the backpack counts as unread.
    _G.GetContainerNumSlots, _G.GetContainerItemInfo = nil, nil
    items, bound, backpackSlots = Client:BagContents()
    check(p .. "no container call: empty, no backpack slots, no error",
        type(items) == "table" and next(items) == nil and type(bound) == "table" and backpackSlots == 0)

    -- The bank is not read on these clients.
    _G.C_Bank = { FetchPurchasedBankTabData = function() error("bank read on a Classic client") end }
    check(p .. "the bank never counts as open", Client:IsBankOpen() == false)
    check(p .. "no bank contents", Client:BankContents("character") == nil and Client:BankContents("account") == nil)
    check(p .. "no bank is usable", Client:BankUsable("character") == false and Client:BankUsable("account") == false)
    check(p .. "no container is a bank container", Client:BankKindOfBag(6) == nil and Client:BankKindOfBag(-1) == nil)
    _G.C_Bank = nil

    local seen = {}
    local before = {}
    for event in pairs(addon.events) do before[event] = true end
    Client:StartStock({
        onBankOpened = function() seen[#seen + 1] = "opened" end,
        onBankChanged = function() seen[#seen + 1] = "changed" end,
        onBankClosing = function() seen[#seen + 1] = "closing" end,
        onBankClosed = function() seen[#seen + 1] = "closed" end,
        onLogout = function() seen[#seen + 1] = "logout" end,
    })
    local added = {}
    for event in pairs(addon.events) do
        if not before[event] then added[event] = true end
    end
    check(p .. "only the logout event is registered", sortedKeys(added) == "PLAYER_LOGOUT", sortedKeys(added))
    addon.events.PLAYER_LOGOUT("PLAYER_LOGOUT")
    check(p .. "PLAYER_LOGOUT -> onLogout", table.concat(seen, ",") == "logout", table.concat(seen, ","))

    -- Who the character is: realms are real on these clients.
    _G.UnitGUID = function(unit) return unit == "player" and "Player-5555-00ABCDEF" or nil end
    _G.UnitName = function(unit) return unit == "player" and "Thrag" or nil, nil end
    _G.GetRealmName = function() return "Nightslayer" end
    _G.UnitFactionGroup = function() return "Horde", "Horde" end
    local id = Client:CharacterIdentity()
    check(p .. "identity: guid, name, realm as the world, faction",
        id.guid == "Player-5555-00ABCDEF" and id.name == "Thrag" and id.world == "Nightslayer" and id.faction == "Horde",
        tostring(id.guid) .. "," .. tostring(id.name) .. "," .. tostring(id.world) .. "," .. tostring(id.faction))
    _G.UnitGUID = nil
    check(p .. "identity: no GUID call, no guid, no error", Client:CharacterIdentity().guid == nil)
    _G.UnitGUID = function() return "Player-5555-00ABCDEF" end

    -- Self-Found by the game's own flag: asked where the client has the
    -- call, which not every client of this family does.
    _G.C_PlayerInfo = nil
    check(p .. "Self-Found: a client without the call is not Self-Found, and no error",
        select(2, pcall(Client.IsSelfFoundCharacter, Client)) == false)
    _G.C_PlayerInfo = {}
    check(p .. "Self-Found: nor one whose table lacks the call", select(2, pcall(Client.IsSelfFoundCharacter, Client)) == false)
    local flag, flagAsked = true, 0
    _G.C_PlayerInfo = { IsSelfFoundActive = function()
        flagAsked = flagAsked + 1
        return flag
    end }
    check(p .. "Self-Found: the game's flag where the client has it", Client:IsSelfFoundCharacter() == true)
    flag = false
    check(p .. "Self-Found: asked again at every call, not kept", Client:IsSelfFoundCharacter() == false and flagAsked == 2,
        flagAsked)
    for _, value in ipairs({ 1, "yes", {} }) do
        flag = value
        check(p .. "Self-Found: a value that is not true is false (" .. type(value) .. ")", Client:IsSelfFoundCharacter() == false)
    end
    _G.C_PlayerInfo = nil

    _G.GetServerTime = function() return 1763900000 end
    check(p .. "Now is the server time", Client:Now() == 1763900000, Client:Now())
    _G.GetServerTime = nil
    _G.time = function() return 1700000000 end
    check(p .. "Now without a server-time call is the clock the client has", Client:Now() == 1700000000, Client:Now())
    _G.time = nil
    _G.GetServerTime = function() return 1763900000 end

    _G.C_Container = nil
    _G.GetContainerNumSlots = numSlots
    _G.GetContainerItemInfo = function() return nil end
    local lines = {}
    local ok, err = pcall(Client.RunStockDiagnostic, Client, lines)
    check(p .. "diag: no Lua error", ok, err)
    local text = table.concat(lines, "\n")
    check(p .. "diag: says the bank is not recorded here", text:find("bank: not recorded on this client", 1, true) ~= nil, text)
    check(p .. "diag: the bags", text:find("bag[0] slots=16", 1, true) ~= nil, text)
    _G.GetContainerNumSlots, _G.GetContainerItemInfo = nil, nil
    lines = {}
    check(p .. "diag without the container calls: no Lua error", pcall(Client.RunStockDiagnostic, Client, lines))
    _G.GetRealmName = nil
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
    local inventory = { started = 0, updates = {} }
    addon.Inventory = {
        Initialize = function() inventory.started = inventory.started + 1 end,
        OnBagUpdate = function(_, bagId) inventory.updates[#inventory.updates + 1] = tostring(bagId) end,
    }
    addon:OnEnable()
    check(p .. "OnEnable starts the inventory (bank and logout events are the adapter's)", inventory.started == 1,
        inventory.started)
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

    addon:OnBagUpdate("BAG_UPDATE", 2)
    check(p .. "bag update while open refreshes the list", refreshes == 1)
    open = false
    addon:OnBagUpdate("BAG_UPDATE", 7)
    check(p .. "bag update while closed refreshes nothing", refreshes == 1)
    check(p .. "every bag update is passed to the inventory with its container id",
        table.concat(inventory.updates, ",") == "2,7", table.concat(inventory.updates, ","))
    check(p .. "bag updates never schedule a recalculation", #recalcs == 4, #recalcs)

    local hidden = 0
    local panel = { Hide = function() hidden = hidden + 1 end }
    panel.OnProfessionClosed = panel.Hide
    addon.ArrowManager, addon.GuideWindow, addon.RecipeDetails = panel, panel, panel
    startCallbacks.onClose()
    check(p .. "onClose hides the arrow, the window and the recipe details", hidden == 3, hidden)

    local refreshed = 0
    addon.ArrowManager = { RefreshPosition = function() refreshed = refreshed + 1 end }
    startCallbacks.onScroll()
    check(p .. "onScroll refreshes the arrow position", refreshed == 1)
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
