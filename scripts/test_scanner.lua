-- scripts/test_scanner.lua
--
-- Modules/Inventory/Scanner.lua: which owned stock counts, and how the stock
-- memory is kept up to date.
--   - the bags are read through the client adapter
--   - with the Syndicator addon everything else comes from it, as before, and
--     LazyProf's own memory is neither read nor written
--   - without it the character's bank, the account bank and the alts come
--     from the memory (Modules/Inventory/StockMemory.lua), with how old each is
--   - the bags are remembered a moment after they change and at logout, the
--     bank only while its window is open and never as "nothing"
--   - a Self-Found character gets no stock from other characters
-- Also the wiring in Core/Init.lua: bag updates are passed on and never plan
-- the path again, a refresh carries the stock's age, /lp diag stock.
--
-- Run from the addon root:  lua5.1 scripts/test_scanner.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })

-- A clock and timers the test moves by hand (C_Timer.After returns nothing).
local fakeNow = 100
local timers = {}
_G.GetTime = function() return fakeNow end
_G.C_Timer = { After = function(delay, fn)
    timers[#timers + 1] = { due = fakeNow + math.max(0, delay), fn = fn }
end }
local function advance(dt)
    fakeNow = fakeNow + dt
    local progressed = true
    while progressed do
        progressed = false
        for i, t in ipairs(timers) do
            if t.due <= fakeNow + 1e-9 then
                table.remove(timers, i)
                t.fn()
                progressed = true
                break
            end
        end
    end
end
-- The next frame: timers asked for "as soon as possible" run, the scan cache is stale.
local function nextFrame() advance(0.01) end

-- No container, bank or clock call may be made from the scanner itself.
local function forbidden(name)
    return function() error(name .. " used outside the client adapter") end
end
_G.C_Container = setmetatable({}, { __index = function(_, name) error("C_Container." .. tostring(name) .. " used outside the adapter") end })
_G.C_Bank = setmetatable({}, { __index = function(_, name) error("C_Bank." .. tostring(name) .. " used outside the adapter") end })
_G.GetContainerNumSlots = forbidden("GetContainerNumSlots")
_G.GetContainerItemInfo = forbidden("GetContainerItemInfo")
_G.GetServerTime = forbidden("GetServerTime")

local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Modules/Inventory/StockMemory.lua",
    "Modules/Inventory/Scanner.lua",
})
local Inventory, Memory = LazyProf.Inventory, LazyProf.StockMemory

local DAY = 86400
local NOW = 20000 * DAY + 3600

local MAIN = { guid = "Player-1-MAIN", name = "Main Character", world = "eu-pvp", faction = "Alliance" }
local ALT = { guid = "Player-1-ALT", name = "Bank Alt", world = "eu-pvp", faction = "Alliance" }
local FARMER = { guid = "Player-1-FARM", name = "Farmer", world = "eu-pvp", faction = "Alliance" }
local HORDE = { guid = "Player-1-HORDE", name = "Other Side", world = "eu-pvp", faction = "Horde" }

-- The client adapter as the scanner sees it; every read is counted.
local client
local function resetClient()
    client = {
        identity = MAIN, now = NOW, bankOpen = false,
        bags = { [2589] = 5 }, bagsBound = {}, backpackSlots = 16,
        bank = { character = nil, account = nil },   -- [kind] = { items, bound }; nil = cannot be read now
        reads = { bags = 0, character = 0, account = 0 },
        started = nil,
    }
end
resetClient()
LazyProf.Client = {
    BagContents = function()
        client.reads.bags = client.reads.bags + 1
        return client.bags, client.bagsBound, client.backpackSlots
    end,
    IsBankOpen = function() return client.bankOpen end,
    BankContents = function(_, kind)
        client.reads[kind] = client.reads[kind] + 1
        local contents = client.bankOpen and client.bank[kind] or nil
        if not contents then return nil end
        return contents.items, contents.bound or {}
    end,
    BankKindOfBag = function(_, bagId)
        if type(bagId) ~= "number" then return nil end
        if bagId >= 6 and bagId <= 14 then return "character" end
        if bagId >= 15 and bagId <= 23 then return "account" end
        return nil
    end,
    CharacterIdentity = function() return client.identity end,
    Now = function() return client.now end,
    StartStock = function(_, callbacks) client.started = callbacks end,
    RunStockDiagnostic = function(_, lines) lines[#lines + 1] = "adapter: stock lines" end,
}

local refreshes = 0
LazyProf.ScheduleShoppingListRefresh = function() refreshes = refreshes + 1 end

local function fresh(profile)
    -- Let what the section before left waiting run out (a save asked for and
    -- never run would keep its "waiting" flag for the rest of the suite).
    advance(10)
    LazyProf.db.global = { characters = {} }
    LazyProf.db.char = { learnedRecipes = {}, selfFoundMode = false }
    LazyProf.db.profile.includeBankItems = true
    LazyProf.db.profile.includeAltCharacters = true
    LazyProf.db.profile.includeGuildBank = false
    for k, v in pairs(profile or {}) do LazyProf.db.profile[k] = v end
    resetClient()
    timers = {}
    refreshes = 0
    _G.Syndicator = nil
    Inventory:InvalidateCache()
    nextFrame()
    timers = {}
end

local function scan()
    Inventory:InvalidateCache()
    return Inventory:ScanAll()
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- ===========================================================================
T.section("bags", function()
    fresh()
    client.bags = { [2589] = 25, [765] = 11 }
    local items = Inventory:ScanBags()
    T.check("ScanBags is what the adapter reads", items[2589] == 25 and items[765] == 11)
    T.eq("GetItemCount counts the bags", Inventory:GetItemCount(2589), 25)
    T.eq("GetItemCount of something not carried", Inventory:GetItemCount(1), 0)
    local recipe = { reagents = { { itemId = 2589, count = 2 }, { itemId = 765, count = 12 } } }
    T.check("HasMaterials reads the bags", Inventory:HasMaterials(recipe) == false)
    local missing = Inventory:GetMissingMaterials(recipe, 1)
    T.check("GetMissingMaterials reads the bags", #missing == 1 and missing[1].itemId == 765 and missing[1].missing == 1)
end)

-- ===========================================================================
T.section("no inventory addon: nothing remembered yet", function()
    fresh()
    local combined, breakdown, meta = scan()
    T.eq("the bags count", combined[2589], 5)
    T.eq("and are named as bags", breakdown[2589].bags, 5)
    T.check("the scan says its stock outside the bags is remembered", meta ~= nil and meta.remembered == true)
    T.check("no bank seen yet: no age", meta.bankSeenAt == nil and meta.accountSeenAt == nil)
    T.check("no alts yet", next(meta.alts) == nil)
    T.check("nothing but the bags", count(combined) == 1 and breakdown[2589].bank == nil and breakdown[2589].alts == nil)
end)

-- ===========================================================================
T.section("no inventory addon: bank and alts from memory", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40, [6948] = 1 }, { [6948] = 1 }, NOW - 2 * DAY)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 10, [4306] = 3 }, NOW - 5 * DAY)
    Memory:SaveAccountBank("eu-normal", { [2589] = 9000 }, NOW)
    Memory:SaveBags(ALT, { [2589] = 20, [2592] = 6 }, { [2592] = 2 }, NOW - DAY)
    Memory:SaveBank(ALT, { [2589] = 100 }, {}, NOW - 30 * DAY)
    Memory:SaveBags(FARMER, { [765] = 12 }, {}, NOW)
    Memory:SaveBags(HORDE, { [2589] = 7000 }, {}, NOW)
    Memory:SaveBags(MAIN, { [2589] = 999 }, {}, NOW - DAY)   -- the character's own bags are read live, never from memory

    local combined, breakdown, meta = scan()
    T.eq("bags + own bank + account bank + the alt's bags and bank", combined[2589], 5 + 40 + 10 + 20 + 100)
    T.eq("bags are the live ones", breakdown[2589].bags, 5)
    T.eq("own bank and account bank are both bank stock", breakdown[2589].bank, 50)
    T.eq("the owner's own soulbound bank items count", breakdown[6948].bank, 1)
    T.eq("an alt's bags, under its name", breakdown[2589].alts["Bank Alt"].bags, 20)
    T.eq("an alt's bank, under its name", breakdown[2589].alts["Bank Alt"].bank, 100)
    T.eq("an alt's soulbound items are taken off", breakdown[2592].alts["Bank Alt"].bags, 4)
    T.eq("another alt", breakdown[765].alts["Farmer"].bags, 12)
    T.check("the other faction is no alt", breakdown[2589].alts["Other Side"] == nil)
    T.eq("the account bank of this world only", breakdown[4306].bank, 3)

    T.eq("age of the own bank", meta.bankSeenAt, NOW - 2 * DAY)
    T.eq("age of the account bank", meta.accountSeenAt, NOW - 5 * DAY)
    T.eq("age of an alt's bags", meta.alts["Bank Alt"].bags, NOW - DAY)
    T.eq("age of an alt's bank", meta.alts["Bank Alt"].bank, NOW - 30 * DAY)
    T.check("an alt whose bank was never seen has no bank age", meta.alts["Farmer"].bags == NOW and meta.alts["Farmer"].bank == nil)

    -- Bank off: no bank of anyone; alts keep their bags.
    LazyProf.db.profile.includeBankItems = false
    combined, breakdown, meta = scan()
    T.eq("bank off: bags and the alt's bags", combined[2589], 5 + 20)
    T.check("bank off: no bank stock", breakdown[2589].bank == nil and breakdown[2589].alts["Bank Alt"].bank == nil
        and combined[6948] == nil and combined[4306] == nil)
    T.check("bank off: no bank ages", meta.bankSeenAt == nil and meta.accountSeenAt == nil and meta.alts["Bank Alt"].bank == nil)
    T.eq("bank off: the alt's bags keep their age", meta.alts["Bank Alt"].bags, NOW - DAY)

    -- Alts off: own bank and account bank only.
    LazyProf.db.profile.includeBankItems = true
    LazyProf.db.profile.includeAltCharacters = false
    combined, breakdown, meta = scan()
    T.eq("alts off: bags and the bank", combined[2589], 5 + 40 + 10)
    T.check("alts off: no alt stock", breakdown[2589].alts == nil and combined[765] == nil and next(meta.alts) == nil)

    -- Both off: the bags.
    LazyProf.db.profile.includeBankItems = false
    combined, breakdown, meta = scan()
    T.check("both off: only the bags", count(combined) == 1 and combined[2589] == 5)
    T.check("both off: still marked as remembered stock", meta ~= nil and meta.remembered == true)
end)

-- ===========================================================================
T.section("no inventory addon: a character that cannot be told apart counts nothing", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW)
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    client.identity = { name = "Main Character", world = "eu-pvp", faction = "Alliance" }   -- the GUID could not be read
    local combined, breakdown, meta = scan()
    T.check("no guid: only the bags", count(combined) == 1 and combined[2589] == 5 and next(meta.alts) == nil)
    client.identity = { guid = MAIN.guid, name = "Main Character", faction = "Alliance" }   -- no world
    Memory:SaveAccountBank("eu-pvp", { [2589] = 10 }, NOW)
    combined, breakdown, meta = scan()
    T.eq("no world: the own bank still counts, no alts, no account bank", combined[2589], 5 + 40)
    T.check("no world: no alt named", breakdown[2589].alts == nil and meta.accountSeenAt == nil)
end)

-- ===========================================================================
T.section("Self-Found: nothing from other characters", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - DAY)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 10 }, NOW)
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    Memory:SaveBank(ALT, { [2589] = 100 }, {}, NOW)
    LazyProf.db.char.selfFoundMode = true
    local combined, breakdown, meta = scan()
    T.eq("memory: bags and the character's own bank", combined[2589], 5 + 40)
    T.check("memory: no alt stock", breakdown[2589].alts == nil and next(meta.alts) == nil)
    T.check("memory: the account bank is other characters' stock too", meta.accountSeenAt == nil and breakdown[2589].bank == 40)
    T.eq("memory: the own bank keeps its age", meta.bankSeenAt, NOW - DAY)
    LazyProf.db.char.selfFoundMode = false
    combined = scan()
    T.eq("memory: with the mode off everything counts again", combined[2589], 5 + 40 + 10 + 20 + 100)
end)

-- ===========================================================================
-- Syndicator character data, as the scanner reads it.
local function slots(list)
    local bag = {}
    for itemId, n in pairs(list) do bag[#bag + 1] = { itemID = itemId, itemCount = n } end
    return bag
end
local function installSyndicator()
    local chars = {
        ["Main-Realm"] = {
            bags = { slots({ [2589] = 3 }) },                     -- not used: own bags are read live
            bank = { slots({ [2589] = 30 }) },
            bankTabs = { { slots = slots({ [4306] = 2 }) } },
            mail = slots({ [2589] = 4 }),
            auctions = slots({ [765] = 6 }),
        },
        ["Alt-Realm"] = {
            bags = { slots({ [2589] = 50 }) },
            bank = { slots({ [2589] = 60 }) },
            mail = slots({ [2592] = 8 }),
            auctions = {},
        },
    }
    _G.Syndicator = { API = {
        GetCurrentCharacter = function() return "Main-Realm" end,
        GetByCharacterFullName = function(name) return chars[name] end,
        GetAllCharacters = function() return { "Main-Realm", "Alt-Realm" } end,
        GetCurrentGuild = function() return "Guild-Realm" end,
        GetByGuildFullName = function() return { bank = { { isViewable = true, slots = slots({ [2589] = 500 }) } } } end,
    } }
end

T.section("Syndicator present: as before, the memory is not used", function()
    fresh()
    -- Remembered stock that must not be counted beside Syndicator's.
    Memory:SaveBank(MAIN, { [2589] = 7777 }, {}, NOW)
    Memory:SaveBags(ALT, { [2589] = 8888 }, {}, NOW)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 9999 }, NOW)
    installSyndicator()

    -- Any use of the memory or of the bank reader fails this section.
    local saved = {}
    for _, name in ipairs({ "SaveBags", "SaveBank", "SaveAccountBank", "OwnBank", "AccountBank", "Alts", "Prune", "Forget" }) do
        saved[name] = Memory[name]
        Memory[name] = function() error("StockMemory:" .. name .. " used although Syndicator is installed") end
    end
    local savedContents = LazyProf.Client.BankContents
    LazyProf.Client.BankContents = function() error("the bank is read although Syndicator is installed") end
    client.bankOpen = true

    local ok, err = pcall(function()
        local combined, breakdown, meta = scan()
        T.eq("bags (live) + bank + mail + the alt's bags and bank", combined[2589], 5 + 30 + 4 + 50 + 60)
        T.eq("bank from Syndicator", breakdown[2589].bank, 30)
        T.eq("bank tabs from Syndicator", breakdown[4306].bank, 2)
        T.eq("mail", breakdown[2589].mail, 4)
        T.eq("own auctions", breakdown[765].auctions, 6)
        T.check("the alt under Syndicator's name", breakdown[2589].alts["Alt-Realm"].bags == 50
            and breakdown[2589].alts["Alt-Realm"].bank == 60 and breakdown[2592].alts["Alt-Realm"].mail == 8)
        T.check("no ages: this stock is not remembered by LazyProf", meta == nil)
        T.check("the guild bank stays off by default", breakdown[2589].guildBank == nil)
        LazyProf.db.profile.includeGuildBank = true
        combined, breakdown = scan()
        T.eq("the guild bank when it is turned on", breakdown[2589].guildBank, 500)
        LazyProf.db.profile.includeGuildBank = false

        -- Nothing is remembered or scheduled while Syndicator is there.
        timers = {}
        Inventory:Initialize()
        Inventory:OnBagUpdate(0)
        Inventory:OnBagUpdate(6)
        client.started.onBankOpened()
        client.started.onBankChanged("character")
        client.started.onBankClosed()
        client.started.onLogout()
        advance(5)
        T.check("no save, no bank read, no prune", true)
        T.check("Forget is not called either", pcall(Inventory.SaveBags, Inventory) and pcall(Inventory.ReadBank, Inventory))

        -- A Self-Found character gets nothing from the alts here either.
        LazyProf.db.char.selfFoundMode = true
        combined, breakdown, meta = scan()
        T.eq("Self-Found: bags, own bank and own mail", combined[2589], 5 + 30 + 4)
        T.check("Self-Found: no alt stock from Syndicator", breakdown[2589].alts == nil and combined[2592] == nil)
        T.eq("Self-Found: own auctions still count", breakdown[765].auctions, 6)
        LazyProf.db.char.selfFoundMode = false
    end)
    for name, fn in pairs(saved) do Memory[name] = fn end
    LazyProf.Client.BankContents = savedContents
    T.check("no use of the memory with Syndicator installed", ok, err)
    _G.Syndicator = nil
    T.eq("what was remembered before is untouched", (Memory:OwnBank(MAIN.guid))[2589], 7777)
end)

-- ===========================================================================
T.section("frame cache", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW)
    client.reads.bags = 0
    local a1, b1, m1 = Inventory:ScanAll()
    local a2, b2, m2 = Inventory:ScanAll()
    T.eq("two scans in one frame read the bags once", client.reads.bags, 1)
    T.check("and hand out the same three results", a1 == a2 and b1 == b2 and m1 == m2 and m1 ~= nil)
    nextFrame()
    Inventory:ScanAll()
    T.eq("the next frame reads again", client.reads.bags, 2)

    -- A change of the memory must not be hidden by the cache.
    local combined = Inventory:ScanAll()
    T.eq("before the bank is seen again", combined[2589], 45)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 70 } }
    client.started = nil
    Inventory:Initialize()
    client.started.onBankOpened()
    combined = Inventory:ScanAll()   -- same frame as the scan above
    T.eq("a saved bank is counted in the same frame", combined[2589], 75)
end)

-- ===========================================================================
T.section("the bags are remembered a moment after they change", function()
    fresh()
    Inventory:Initialize()
    T.check("the adapter's stock events are started", type(client.started) == "table"
        and type(client.started.onBankOpened) == "function" and type(client.started.onBankChanged) == "function"
        and type(client.started.onBankClosed) == "function" and type(client.started.onLogout) == "function")
    -- The character is remembered soon after login even when nothing changes.
    T.eq("start: one save is scheduled", #timers, 1)
    T.check("start: nothing saved yet", Memory:Summary().characters[1] == nil)
    advance(2.1)
    local summary = Memory:Summary()
    T.check("start: the bags are saved after the delay", #summary.characters == 1 and summary.characters[1].guid == MAIN.guid
        and summary.characters[1].bagsAt == NOW)

    -- A burst of bag updates: one save.
    client.reads.bags = 0
    client.bags = { [2589] = 8, [2592] = 3 }
    client.bagsBound = { [2592] = 3 }
    client.now = NOW + 60
    for _ = 1, 25 do
        Inventory:OnBagUpdate(0)
        Inventory:OnBagUpdate(3)
        Inventory:OnBagUpdate(5)
    end
    T.eq("many updates: one timer", #timers, 1)
    T.eq("many updates: nothing is read at once", client.reads.bags, 0)
    advance(1.9)
    T.eq("not before two seconds", client.reads.bags, 0)
    advance(0.2)
    T.eq("then one read", client.reads.bags, 1)
    T.eq("with the time of the save", Memory:Summary().characters[1].bagsAt, NOW + 60)
    advance(10)
    T.eq("and no second one", client.reads.bags, 1)
    Inventory:OnBagUpdate(0)
    advance(2.1)
    T.eq("a later update saves again", client.reads.bags, 2)

    -- What was saved is what an alt will be offered: soulbound taken off.
    client.identity = ALT
    local alts = Memory:Alts(ALT)
    T.check("the save holds the items and what is soulbound", #alts == 1 and alts[1].bags[2589] == 8 and alts[1].bags[2592] == nil)
    client.identity = MAIN

    -- A bank container's update is not a change of the bags.
    timers = {}
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(15)
    T.eq("a bank tab's update schedules no bag save", #timers, 0)
    Inventory:OnBagUpdate(nil)
    T.eq("an update without a container id counts as the bags", #timers, 1)
    advance(2.1)

    -- Bags that cannot be read must not replace what is remembered.
    client.bags, client.bagsBound, client.backpackSlots = {}, {}, 0
    client.now = NOW + 500
    Inventory:OnBagUpdate(0)
    advance(2.1)
    T.eq("a backpack without slots: the snapshot keeps its time", Memory:Summary().characters[1].bagsAt, NOW + 60)
    client.identity = ALT
    T.eq("a backpack without slots: and its content", Memory:Alts(ALT)[1].bags[2589], 8)
    client.identity = MAIN
    client.backpackSlots = 16
    Inventory:OnBagUpdate(0)
    advance(2.1)
    T.eq("bags that read as empty after a bag update are a real state and are saved",
        Memory:Summary().characters[1].bagItems, 0)

    -- At login no bag update says the bags are there yet: an empty read then
    -- (slots, but no items) is not saved over what is remembered.
    fresh()
    Memory:SaveBags(MAIN, { [2589] = 8 }, {}, NOW - DAY)
    client.bags = {}
    Inventory:Initialize()
    advance(2.1)
    T.eq("start: an empty read does not replace the snapshot", Memory:Summary().characters[1].bagItems, 1)
    T.eq("start: nor its time", Memory:Summary().characters[1].bagsAt, NOW - DAY)
    client.bags = { [2589] = 3, [765] = 1 }
    Inventory:Initialize()
    advance(2.1)
    T.eq("start: a read with items is saved", Memory:Summary().characters[1].bagItems, 2)

    -- Without a GUID nothing is saved.
    fresh()
    client.identity = { name = "Nobody", world = "eu-pvp", faction = "Alliance" }
    Inventory:OnBagUpdate(0)
    advance(2.1)
    T.eq("no guid: no record", #Memory:Summary().characters, 0)
end)

-- ===========================================================================
T.section("logout writes a pending bag save once", function()
    fresh()
    Inventory:Initialize()
    advance(2.1)
    client.reads.bags = 0
    client.started.onLogout()
    T.eq("nothing pending: logout reads nothing", client.reads.bags, 0)

    client.bags = { [2589] = 77 }
    client.now = NOW + 30
    Inventory:OnBagUpdate(0)
    T.eq("a change is waiting for its save", client.reads.bags, 0)
    client.started.onLogout()
    T.eq("logout saves it at once", client.reads.bags, 1)
    T.eq("with the new time", Memory:Summary().characters[1].bagsAt, NOW + 30)
    client.started.onLogout()
    Inventory:OnLogout()   -- the database's own shutdown notice asks for the same
    T.eq("a second logout notice does not save again", client.reads.bags, 1)
    advance(5)
    T.eq("and the timer that was waiting finds nothing to do", client.reads.bags, 1)

    -- Bags that cannot be read at logout keep the last snapshot.
    client.bags, client.backpackSlots = {}, 0
    client.now = NOW + 99
    Inventory:OnBagUpdate(0)
    client.started.onLogout()
    T.eq("logout with unreadable bags keeps the snapshot", Memory:Summary().characters[1].bagsAt, NOW + 30)
    -- Slots but no items at logout: the client may already have let go of
    -- the bags, so that is not taken for empty bags.
    advance(5)
    client.backpackSlots = 16
    client.now = NOW + 120
    Inventory:OnBagUpdate(0)
    client.started.onLogout()
    T.check("logout with bags that read as empty keeps the snapshot",
        Memory:Summary().characters[1].bagsAt == NOW + 30 and Memory:Summary().characters[1].bagItems == 1,
        Memory:Summary().characters[1].bagsAt)
end)

-- ===========================================================================
T.section("the bank is remembered only while its window is open", function()
    fresh()
    Inventory:Initialize()
    advance(2.1)
    local function bankOf() return Memory:OwnBank(MAIN.guid) end

    -- Closed: nothing is read, whatever arrives.
    client.bank.character = { items = { [2589] = 40 } }
    Inventory:OnBagUpdate(6)
    client.started.onBankChanged("character")
    nextFrame()
    T.check("closed: nothing remembered", bankOf() == nil)

    -- Opened: read at once.
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 40, [6948] = 1 }, bound = { [6948] = 1 } }
    client.bank.account = { items = { [4306] = 9 } }
    refreshes = 0
    client.started.onBankOpened()
    local items, at = bankOf()
    T.check("opened: the character bank is saved", items ~= nil and items[2589] == 40 and items[6948] == 1 and at == NOW)
    local account, accountAt = Memory:AccountBank("eu-pvp")
    T.check("opened: the account bank is saved for the world", account ~= nil and account[4306] == 9 and accountAt == NOW)
    T.check("opened: a shown list is asked to redraw", refreshes >= 1, refreshes)

    -- Changed: read again on the next frame, once for a burst, whatever container the update names.
    client.reads.character = 0
    client.bank.character = { items = { [2589] = 55 } }
    client.now = NOW + 10
    refreshes = 0
    for _ = 1, 20 do
        Inventory:OnBagUpdate(6)     -- a bank tab
        Inventory:OnBagUpdate(0)     -- the backpack: an item went one way or the other
    end
    client.started.onBankChanged("character")
    T.eq("changed: not read inside the event burst", client.reads.character, 0)
    nextFrame()
    T.eq("changed: one read on the next frame", client.reads.character, 1)
    items, at = bankOf()
    T.check("changed: the new contents and time", items[2589] == 55 and items[6948] == nil and at == NOW + 10)
    T.eq("changed: one redraw request", refreshes, 1)

    -- The adapter cannot read just now: what is remembered stays.
    client.bank.character = nil
    client.bank.account = nil
    client.now = NOW + 20
    Inventory:OnBagUpdate(6)
    nextFrame()
    items, at = bankOf()
    T.check("unreadable: the remembered bank is kept", items ~= nil and items[2589] == 55 and at == NOW + 10)
    T.check("unreadable: the account bank is kept", (Memory:AccountBank("eu-pvp"))[4306] == 9)
    client.started.onBankOpened()
    T.check("unreadable on open: kept as well", (bankOf())[2589] == 55)

    -- One bank readable, the other not: each is judged alone.
    client.bank.account = { items = { [4306] = 1 } }
    Inventory:OnBagUpdate(15)
    nextFrame()
    T.check("only the account bank readable: it is saved, the character bank kept",
        (Memory:AccountBank("eu-pvp"))[4306] == 1 and (bankOf())[2589] == 55)

    -- An empty bank that can be read is a real state (the window has been
    -- open for a while: see "an early read" below).
    advance(1)
    client.bank.character = { items = {} }
    Inventory:OnBagUpdate(6)
    nextFrame()
    items = bankOf()
    T.check("a readable empty bank is saved as empty", items ~= nil and next(items) == nil)

    -- Closing: nothing is read from a bank that is going away, and a read
    -- still waiting is dropped.
    client.bank.character = { items = { [2589] = 12 } }
    Inventory:OnBagUpdate(6)            -- a read is now waiting for the next frame
    client.bankOpen = false             -- the adapter counts the bank as closed before it reports the close
    client.reads.character = 0
    client.started.onBankClosed()
    nextFrame()
    T.eq("closed: the adapter is not asked to read", client.reads.character, 0)
    T.check("closed: the last read made while open stays", next((bankOf())) == nil)

    -- Open again later: the waiting-read flag was not left stuck.
    client.bankOpen = true
    client.started.onBankOpened()
    T.eq("reopened: saved again", (bankOf())[2589], 12)
    client.bank.character = { items = { [2589] = 13 } }
    Inventory:OnBagUpdate(6)
    nextFrame()
    T.eq("reopened: changes are read again", (bankOf())[2589], 13)

    -- Without a GUID nothing is saved; the account bank needs the world.
    fresh()
    Inventory:Initialize()
    client.identity = { name = "Nobody", faction = "Alliance" }
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 1 } }
    client.bank.account = { items = { [2589] = 2 } }
    client.started.onBankOpened()
    T.check("no guid and no world: nothing saved", #Memory:Summary().characters == 0 and #Memory:Summary().account == 0)
end)

-- ===========================================================================
-- Whether a bank's items are there the moment its window opens is not known.
-- A read that finds slots but no items right after opening is therefore not
-- taken for an empty bank: it is looked at again half a second later.
T.section("an early read does not empty the remembered bank", function()
    local function bankOf() return Memory:OwnBank(MAIN.guid) end
    local function start()
        fresh()
        Inventory:Initialize()
        advance(2.1)
        Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - DAY)
        Memory:SaveAccountBank("eu-pvp", { [4306] = 9 }, NOW - DAY)
        client.bankOpen = true
        client.bank.character = { items = {} }
        client.bank.account = { items = {} }
    end

    -- Opened and closed again before anything arrived.
    start()
    client.started.onBankOpened()
    local items, at = bankOf()
    T.check("empty at opening: the remembered bank is kept", items[2589] == 40 and at == NOW - DAY)
    T.check("empty at opening: the account bank is kept", (Memory:AccountBank("eu-pvp"))[4306] == 9)
    nextFrame()
    Inventory:OnBagUpdate(0)          -- an unrelated bag update while still nothing is there
    nextFrame()
    T.check("still empty a moment later: kept", (bankOf())[2589] == 40)
    client.bankOpen = false
    client.started.onBankClosed()
    client.reads.character = 0
    advance(2)
    T.check("closed before the items came: kept, and nothing read after the close",
        (bankOf())[2589] == 40 and client.reads.character == 0, client.reads.character)

    -- The items arrive a moment after the window.
    start()
    client.started.onBankOpened()
    nextFrame()
    client.bank.character = { items = { [2589] = 70 } }
    Inventory:OnBagUpdate(6)
    nextFrame()
    T.eq("items that arrive are saved at once", (bankOf())[2589], 70)

    -- No update follows: the bank is looked at again by itself.
    start()
    client.started.onBankOpened()
    client.bank.character = { items = { [2589] = 71 } }
    advance(0.4)
    T.eq("not yet looked at again", (bankOf())[2589], 40)
    advance(0.2)
    T.eq("looked at again half a second after opening", (bankOf())[2589], 71)

    -- The bank really is empty: saved as empty once the half second is over.
    start()
    client.now = NOW + 5
    client.started.onBankOpened()
    advance(0.6)
    items, at = bankOf()
    T.check("a bank that stays empty is saved as empty", items ~= nil and next(items) == nil and at == NOW + 5)
    local account = Memory:AccountBank("eu-pvp")
    T.check("and so is the account bank", account ~= nil and next(account) == nil)
    local waiting = #timers
    advance(5)
    T.eq("no further reads are scheduled once it is settled", #timers, 0)
    T.check("(one was waiting at most)", waiting <= 1, waiting)

    -- One bank has its items at once, the other not yet: each is judged alone.
    start()
    client.bank.character = { items = { [2589] = 72 } }
    client.started.onBankOpened()
    T.check("the bank that has items is saved, the empty one waits",
        (bankOf())[2589] == 72 and (Memory:AccountBank("eu-pvp"))[4306] == 9)

    -- A scan in that first moment counts what is remembered.
    start()
    client.started.onBankOpened()
    local combined = scan()
    T.eq("a scan right after opening counts the remembered bank", combined[2589], 5 + 40)

    -- Opened again later: the half second starts anew.
    start()
    client.bank.character = { items = { [2589] = 73 } }
    client.started.onBankOpened()
    advance(3)
    client.bankOpen = false
    client.started.onBankClosed()
    advance(3)
    client.bankOpen = true
    client.bank.character = { items = {} }
    client.started.onBankOpened()
    T.eq("a second visit: an empty first read is not trusted either", (bankOf())[2589], 73)
end)

-- ===========================================================================
T.section("a scan with the bank open counts what is in it now", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - 3 * DAY)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 90 } }
    refreshes = 0
    local combined, breakdown, meta = scan()
    T.eq("the open bank is read and counted", breakdown[2589].bank, 90)
    T.eq("and remembered with the time of the read", meta.bankSeenAt, NOW)
    T.eq("a scan asks for no redraw (it is the redraw)", refreshes, 0)
    client.bank.character = nil
    combined, breakdown, meta = scan()
    T.eq("open but unreadable: the remembered bank counts", breakdown[2589].bank, 90)
    LazyProf.db.profile.includeBankItems = false
    client.bank.character = { items = { [2589] = 5 } }
    client.reads.character = 0
    scan()
    T.eq("bank off: the scan does not read the bank", client.reads.character, 0)
end)

-- ===========================================================================
T.section("start: old characters are dropped, never the one being played", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - 400 * DAY)
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW - 181 * DAY)
    Memory:SaveBags(FARMER, { [765] = 12 }, {}, NOW - 10 * DAY)
    Inventory:Initialize()
    local guids = {}
    for _, c in ipairs(Memory:Summary().characters) do guids[c.guid] = true end
    T.check("an alt not seen for 181 days is dropped", guids[ALT.guid] == nil)
    T.check("an alt seen lately is kept", guids[FARMER.guid] == true)
    T.check("the character being played is kept with its old bank", guids[MAIN.guid] == true and (Memory:OwnBank(MAIN.guid))[2589] == 40)

    -- A GUID that cannot be read: better no cleanup than dropping the player's own record.
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - 400 * DAY)
    client.identity = { name = "Main Character", world = "eu-pvp", faction = "Alliance" }
    Inventory:Initialize()
    T.check("no guid at start: nothing is dropped", (Memory:OwnBank(MAIN.guid))[2589] == 40)
end)

-- ===========================================================================
T.section("forget", function()
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW)
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 10 }, NOW)
    local combined = Inventory:ScanAll()
    T.eq("before", combined[2589], 75)
    Inventory:ForgetRemembered()
    combined = Inventory:ScanAll()   -- same frame: the cache must not keep the forgotten stock
    T.eq("after: only the bags", combined[2589], 5)
    T.eq("nothing is remembered", #Memory:Summary().characters, 0)
    advance(2.1)
    local summary = Memory:Summary()
    T.check("the character being played is remembered again by itself",
        #summary.characters == 1 and summary.characters[1].guid == MAIN.guid)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 33 } }
    Inventory:ForgetRemembered()
    T.eq("with the bank open it is read again at once", (Memory:OwnBank(MAIN.guid))[2589], 33)
end)

-- ===========================================================================
T.section("diagnostic lines", function()
    fresh()
    Memory:SaveBags(MAIN, { [2589] = 5, [765] = 1 }, {}, NOW)
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - 2 * DAY)
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW - DAY)
    Memory:SaveBags(HORDE, { [2589] = 7 }, {}, NOW - 40 * DAY)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 10 }, NOW - 5 * DAY)
    local before = Memory:Summary()
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 999 } }
    local lines = {}
    Inventory:RunDiagnostic(lines)
    local text = table.concat(lines, "\n")
    T.check("says where stock outside the bags comes from", text:find("source: LazyProf's own memory", 1, true) ~= nil, text)
    T.check("the settings", text:find("settings: bank=true alts=true guildBank=false selfFound=false", 1, true) ~= nil, text)
    T.check("who the character is", text:find("identity: guid=Player-1-MAIN name=Main Character world=eu-pvp faction=Alliance", 1, true) ~= nil, text)
    T.check("how much is remembered", text:find("memory: format=1 characters=3 accountBanks=1", 1, true) ~= nil, text)
    T.check("this character, with ages",
        text:find("character: Main Character [this character] world=eu-pvp faction=Alliance bags=2 items (less than an hour ago) bank=1 items (2 days ago)", 1, true) ~= nil, text)
    T.check("an alt that counts",
        text:find("character: Bank Alt [alt] world=eu-pvp faction=Alliance bags=1 items (1 day ago) bank=never seen", 1, true) ~= nil, text)
    T.check("a character that does not count", text:find("character: Other Side [not counted] world=eu-pvp faction=Horde", 1, true) ~= nil, text)
    T.check("the account bank", text:find("account bank: world=eu-pvp items=1 (5 days ago)", 1, true) ~= nil, text)
    T.check("plain ASCII", not text:find("[\128-\255]"))
    -- Read-only: an open bank is not saved by the dump.
    local after = Memory:Summary()
    T.check("the dump saves nothing", (Memory:OwnBank(MAIN.guid))[2589] == 40
        and after.characters[1].seen == before.characters[1].seen and #timers == 0)

    installSyndicator()
    lines = {}
    Inventory:RunDiagnostic(lines)
    text = table.concat(lines, "\n")
    T.check("with Syndicator it says the memory is not used", text:find("source: Syndicator", 1, true) ~= nil
        and text:find("not used", 1, true) ~= nil, text)
    _G.Syndicator = nil

    -- Entries that are not what LazyProf writes are counted, not listed.
    LazyProf.db.global.stock.characters["Player-1-JUNK"] = true
    LazyProf.db.global.stock.account["eu-normal"] = "x"
    lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("unreadable entries are counted in the dump", table.concat(lines, "\n"):find("unreadable=2", 1, true) ~= nil,
        table.concat(lines, "\n"))

    LazyProf.db.global.stock = { schema = 9 }
    lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("another format is named, not read", table.concat(lines, "\n"):find("format=9", 1, true) ~= nil, table.concat(lines, "\n"))
end)

-- ===========================================================================
T.section("options", function()
    fresh()
    local stockOptions = LazyProf.options.args.display.args
    local bank, alts, guild, forget = stockOptions.includeBankItems, stockOptions.includeAltCharacters,
        stockOptions.includeGuildBank, stockOptions.forgetStock
    local function text(value) return type(value) == "function" and value() or value end

    -- Without Syndicator the two options work from LazyProf's own memory.
    LazyProf.ClientFamily = "forever"
    T.check("bank: usable without Syndicator on WoW Forever", bank.disabled() == false)
    T.check("alts: usable without Syndicator", alts.disabled == nil or alts.disabled() == false)
    T.check("guild bank: still needs Syndicator", guild.disabled() == true)
    T.check("bank: no longer says Syndicator is required", not text(bank.desc):find("Requires: Syndicator", 1, true))
    T.check("alts: no longer says Syndicator is required", not text(alts.desc):find("Requires: Syndicator", 1, true))
    T.check("guild bank: still says so", text(guild.desc):find("Requires: Syndicator", 1, true) ~= nil)
    T.check("bank: says what is remembered without an inventory addon",
        text(bank.desc):find("when you last opened it", 1, true) ~= nil, text(bank.desc))
    T.check("alts: says what is remembered without an inventory addon",
        text(alts.desc):find("each character's bags", 1, true) ~= nil, text(alts.desc))
    T.check("bank and alts: say where the age of remembered stock is shown",
        text(bank.desc):find("Collect first", 1, true) ~= nil and text(bank.desc):find("how old", 1, true) ~= nil
        and text(alts.desc):find("Collect first", 1, true) ~= nil and text(alts.desc):find("how old", 1, true) ~= nil)
    T.check("alts: says which characters and that soulbound items do not count",
        text(alts.desc):find("same world and faction", 1, true) ~= nil and text(alts.desc):find("soulbound", 1, true) ~= nil)
    -- The bank is not remembered on the other clients: the option would tick and count nothing.
    LazyProf.ClientFamily = "classic"
    T.check("bank: without Syndicator on a Classic client it stays greyed out", bank.disabled() == true)
    T.check("alts: usable there too (bags are remembered)", alts.disabled == nil or alts.disabled() == false)
    installSyndicator()
    T.check("bank: usable with Syndicator on any client", bank.disabled() == false)
    T.check("guild bank: usable with Syndicator", guild.disabled() == false)
    _G.Syndicator = nil
    LazyProf.ClientFamily = "forever"

    -- Forget remembered characters.
    T.check("the button exists", forget ~= nil and forget.type == "execute" and forget.name == "Forget remembered characters")
    T.check("it asks first", forget.confirm == true and type(forget.confirmText) == "string")
    T.check("it is shown while the memory is in use", forget.hidden() == false)
    installSyndicator()
    T.check("and hidden while Syndicator supplies the stock", forget.hidden() == true)
    _G.Syndicator = nil
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    local reasons = {}
    LazyProf.Recalculate = function(_, reason) reasons[#reasons + 1] = reason end
    forget.func()
    T.eq("the button forgets what is remembered", #Memory:Summary().characters, 0)
    T.eq("and plans again, as every stock setting does", reasons[1], "setting changed")
    for _, option in ipairs({ bank, alts, guild, forget }) do
        T.check("plain ASCII: " .. option.name, not (text(option.desc) .. option.name):find("[\128-\255]"))
    end
end)

-- ===========================================================================
-- Core/Init.lua: bag updates, the refresh, the slash command.
-- ===========================================================================
T.section("init wiring", function()
    fresh()
    _G.LibStub = function() return { NewAddon = function(_self, addon) return addon end } end
    _G.GetBuildInfo = function() return "1.60.1", "70938", "Nov 1 2026", 16001 end
    assert(loadfile("Core/Init.lua"))("LazyProf", LazyProf)
    local printed = {}
    LazyProf.Print = function(_, msg) printed[#printed + 1] = msg end
    LazyProf.ClientFamily = "forever"

    -- OnEnable starts the stock memory.
    local events = {}
    LazyProf.RegisterEvent = function(_, event, handler) events[event] = handler end
    LazyProf.Client.Start = function() end
    client.started = nil
    LazyProf:OnEnable()
    T.check("OnEnable starts the stock events", type(client.started) == "table")
    T.check("BAG_UPDATE keeps its one handler in Init", events.BAG_UPDATE == "OnBagUpdate")
    advance(2.1)

    -- Bag updates: passed on with the container id; never a recalculation.
    local recalcs, shoppingRefreshes = 0, 0
    LazyProf.Recalculate = function() recalcs = recalcs + 1 end
    LazyProf.ScheduleRecalculation = function() recalcs = recalcs + 1 end
    LazyProf.ScheduleShoppingListRefresh = function() shoppingRefreshes = shoppingRefreshes + 1 end
    LazyProf.Client.IsOpen = function() return true end
    local passed = {}
    local realOnBagUpdate = Inventory.OnBagUpdate
    Inventory.OnBagUpdate = function(self, bagId)
        passed[#passed + 1] = tostring(bagId)
        return realOnBagUpdate(self, bagId)
    end
    LazyProf:OnBagUpdate("BAG_UPDATE", 0)
    LazyProf:OnBagUpdate("BAG_UPDATE", 5)
    LazyProf:OnBagUpdate("BAG_UPDATE", 6)
    T.eq("each bag update is passed on with its container id", table.concat(passed, ","), "0,5,6")
    T.eq("the shown list is still refreshed, lightly", shoppingRefreshes, 3)
    client.bags = { [2589] = 123 }
    client.reads.bags = 0
    advance(2.1)
    T.eq("the bags are saved once for the burst", client.reads.bags, 1)
    T.eq("no recalculation from bag updates", recalcs, 0)
    Inventory.OnBagUpdate = realOnBagUpdate

    -- The database's shutdown notice writes a waiting save too. It is asked
    -- for when the database is made (the notice comes before the database
    -- tidies the saved tables at logout).
    local shutdown = {}
    local savedDb, savedLibStub = LazyProf.db, _G.LibStub
    local fakeDb = { sv = {}, profile = savedDb.profile, char = savedDb.char, global = savedDb.global,
        RegisterCallback = function(target, event, method) shutdown[#shutdown + 1] = { target = target, event = event, method = method } end }
    _G.LibStub = function() return { New = function() return fakeDb end } end
    LazyProf.RegisterChatCommand = function() end
    local savedSetup, savedMigrate = LazyProf.SetupConfig, LazyProf.MigrateSettings
    LazyProf.SetupConfig, LazyProf.MigrateSettings = nil, nil
    LazyProf:OnInitialize()
    T.check("the database's shutdown notice is asked for", #shutdown == 1 and shutdown[1].target == LazyProf
        and shutdown[1].event == "OnDatabaseShutdown" and type(LazyProf[shutdown[1].method]) == "function",
        #shutdown)
    -- A database without notices (its callback library missing) must not stop the addon from loading.
    fakeDb.RegisterCallback = nil
    local loaded, loadError = pcall(LazyProf.OnInitialize, LazyProf)
    T.check("a database without notices does not break loading", loaded, loadError)
    LazyProf.SetupConfig, LazyProf.MigrateSettings = savedSetup, savedMigrate
    _G.LibStub = savedLibStub
    LazyProf.db = savedDb

    LazyProf:OnBagUpdate("BAG_UPDATE", 0)
    client.reads.bags = 0
    LazyProf[shutdown[1].method](LazyProf)
    T.eq("database shutdown writes the waiting bag save", client.reads.bags, 1)

    -- A refresh puts the stock's age on the shown paths with the stock itself.
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - 2 * DAY)
    local live = { steps = { {} } }
    local planning = { steps = { {} } }
    LazyProf.Pathfinder = { currentPath = live }
    local redraws = 0
    LazyProf.GuideWindow = { PlanningPath = function() return planning end, Refresh = function() redraws = redraws + 1 end }
    nextFrame()
    LazyProf:RefreshShoppingList()
    T.check("refresh: the live path gets stock, sources and ages",
        live.inventory ~= nil and live.sourceBreakdown ~= nil and live.stockMeta ~= nil
        and live.stockMeta.bankSeenAt == NOW - 2 * DAY)
    T.check("refresh: the planning path gets the same", planning.stockMeta == live.stockMeta and planning.inventory == live.inventory)
    T.eq("refresh: one redraw", redraws, 1)
    T.eq("refresh: still no recalculation", recalcs, 0)

    -- /lp diag stock
    local shown
    LazyProf.ShowDiagnosticOutput = function(_, text) shown = text end
    LazyProf:SlashCommand("diag stock")
    T.check("/lp diag stock opens the copyable window", type(shown) == "string")
    T.check("its first line names the client", shown:find("diag stock: build=1.60.1 (70938) interface=16001 family=forever", 1, true) == 1, shown)
    T.check("the adapter's lines are in it", shown:find("adapter: stock lines", 1, true) ~= nil, shown)
    T.check("and the memory's", shown:find("memory: format=1 characters=1", 1, true) ~= nil, shown)
    LazyProf.Client.RunStockDiagnostic = function() error("boom") end
    LazyProf:SlashCommand("diag stock")
    T.check("a failing adapter section is reported, the rest still prints",
        shown:find("SECTION ERROR", 1, true) ~= nil and shown:find("memory: format=1", 1, true) ~= nil, shown)
    printed = {}
    LazyProf:SlashCommand("diag")
    T.check("/lp diag lists the stock dump", table.concat(printed, "\n"):find("/lp diag stock", 1, true) ~= nil)
end)

T.finish()
