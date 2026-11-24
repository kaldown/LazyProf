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

-- A clock and timers the test moves by hand. Like the client's, C_Timer.After
-- returns nothing and never runs a timer in the frame that asked for it: at
-- the earliest one frame later, whoever asked (an event or another timer).
local FRAME = 0.01
local fakeNow = 100
local timers = {}
_G.GetTime = function() return fakeNow end
_G.C_Timer = { After = function(delay, fn)
    timers[#timers + 1] = { due = fakeNow + math.max(FRAME, delay), fn = fn }
end }
-- Move the clock on, stopping at each moment something is due to run one
-- pass there: every timer due by then, in the order they were asked for.
local function advance(dt)
    local target = fakeNow + dt
    while true do
        local due
        for _, t in ipairs(timers) do
            if t.due <= target + 1e-9 and (not due or t.due < due) then due = t.due end
        end
        if not due then break end
        if due > fakeNow then fakeNow = due end
        local pass, rest = {}, {}
        for _, t in ipairs(timers) do
            if t.due <= fakeNow + 1e-9 then pass[#pass + 1] = t else rest[#rest + 1] = t end
        end
        timers = rest
        for _, t in ipairs(pass) do t.fn() end
    end
    fakeNow = target
end
-- The next frame: timers asked for "as soon as possible" run, the scan cache is stale.
local function nextFrame() advance(FRAME) end

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
        usable = {},                                 -- [kind] = true / false: says so whatever the bank reads
        asked = { character = 0, account = 0 },      -- how often BankUsable was asked
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
        return contents.items, contents.bound or {}, contents.slots or 28
    end,
    -- A bank that hands out contents is usable; client.usable[kind] says
    -- otherwise (true: usable although it cannot be read just now).
    BankUsable = function(_, kind)
        client.asked[kind] = client.asked[kind] + 1
        if not client.bankOpen then return false end
        if client.usable[kind] ~= nil then return client.usable[kind] end
        return client.bank[kind] ~= nil
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
    Inventory:OnBankClosed()          -- a bank visit the section before left open is over
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
-- The test's own clock behaves like the game's.
T.section("the clock", function()
    local ran = {}
    local start = fakeNow
    C_Timer.After(0, function()
        ran[#ran + 1] = fakeNow > start
        C_Timer.After(0, function() ran[#ran + 1] = fakeNow end)
    end)
    advance(0)
    T.eq("a zero-delay timer does not run in the frame that asked for it", #ran, 0)
    nextFrame()
    T.check("it runs on the next frame, at a later time", #ran == 1 and ran[1] == true, #ran)
    local after = fakeNow
    nextFrame()
    T.check("one asked for by a timer runs a frame later still", #ran == 2 and fakeNow > after, #ran)
    local seen = {}
    start = fakeNow
    C_Timer.After(0.5, function() seen[#seen + 1] = fakeNow - start end)
    C_Timer.After(2, function() seen[#seen + 1] = fakeNow - start end)
    advance(3)
    T.check("a long step runs each timer at the moment it is due",
        #seen == 2 and math.abs(seen[1] - 0.5) < 1e-6 and math.abs(seen[2] - 2) < 1e-6, tostring(seen[1]) .. "," .. tostring(seen[2]))
end)

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
-- A remembered bank that is marked in doubt is behind what is really in it,
-- as far as the addon can tell: no scan counts it, and the scan says so.
T.section("no inventory addon: a bank in doubt is not counted", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40, [6948] = 1 }, {}, NOW - 2 * DAY)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 10, [4306] = 3 }, NOW - 5 * DAY)
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW - DAY)
    Memory:SaveBank(ALT, { [2589] = 100 }, {}, NOW - 30 * DAY)
    local combined, breakdown, meta = scan()
    T.eq("nothing in doubt: everything counts", combined[2589], 5 + 40 + 10 + 20 + 100)
    T.check("and the scan says nothing of doubt", meta.bankInDoubt == nil and meta.accountInDoubt == nil)

    Memory:MarkBankDoubt(MAIN.guid)
    combined, breakdown, meta = scan()
    T.eq("own bank in doubt: it is not counted", combined[2589], 5 + 10 + 20 + 100)
    T.check("nothing of it is", combined[6948] == nil and breakdown[2589].bank == 10)
    T.check("the scan says that the own bank is in doubt", meta.bankInDoubt == true and meta.accountInDoubt == nil)
    T.check("and gives it no age, the account bank keeps its own", meta.bankSeenAt == nil and meta.accountSeenAt == NOW - 5 * DAY)

    Memory:MarkAccountBankDoubt("eu-pvp")
    combined, breakdown, meta = scan()
    T.eq("account bank in doubt too: neither is counted", combined[2589], 5 + 20 + 100)
    T.check("no bank stock at all", breakdown[2589].bank == nil and combined[4306] == nil)
    T.check("the scan says both", meta.bankInDoubt == true and meta.accountInDoubt == true and meta.accountSeenAt == nil)

    -- Nothing of the bank counts with the setting off: there is nothing to say.
    LazyProf.db.profile.includeBankItems = false
    combined, breakdown, meta = scan()
    T.check("bank items off: no word of doubt", combined[2589] == 5 + 20 and meta.bankInDoubt == nil and meta.accountInDoubt == nil)
    LazyProf.db.profile.includeBankItems = true
    -- The account bank is not a Self-Found character's stock: nothing to say of it.
    LazyProf.db.char.selfFoundMode = true
    combined, breakdown, meta = scan()
    T.check("Self-Found: only the own bank's doubt is named", combined[2589] == 5 and meta.bankInDoubt == true
        and meta.accountInDoubt == nil)
    LazyProf.db.char.selfFoundMode = false

    -- An alt whose bank is in doubt supplies its bags only.
    Memory:MarkBankDoubt(ALT.guid)
    Inventory:ForgetAltsPart()
    combined, breakdown, meta = scan()
    T.eq("an alt's bank in doubt: its bags only", combined[2589], 5 + 20)
    T.check("named as bags, with their age and no bank age", breakdown[2589].alts["Bank Alt"].bags == 20
        and breakdown[2589].alts["Bank Alt"].bank == nil and meta.alts["Bank Alt"].bags == NOW - DAY
        and meta.alts["Bank Alt"].bank == nil)

    -- The next save of a bank takes its mark away.
    Memory:SaveBank(MAIN, { [2589] = 41 }, {}, NOW)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 11 }, NOW)
    combined, breakdown, meta = scan()
    T.eq("saved again: both count", combined[2589], 5 + 41 + 11 + 20)
    T.check("and nothing is in doubt", meta.bankInDoubt == nil and meta.accountInDoubt == nil and meta.bankSeenAt == NOW)
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
        Inventory:OnBagUpdateDelayed()
        client.started.onBankOpened()
        client.started.onBankChanged("character")
        Inventory:OnBankChange()
        Inventory:OnBagUpdate(0)
        Inventory:OnBagUpdateDelayed()
        client.started.onBankClosing()
        client.started.onBankClosed()
        Inventory:OnBagUpdate(0)
        client.started.onLogout()
        T.eq("no timer is asked for", #timers, 0)
        advance(5)
        T.check("no save, no bank read, no prune", true)
        T.check("a save asked for directly does nothing either", Inventory:SaveBags(true) == false)

        -- A Self-Found character gets nothing from the alts here either.
        LazyProf.db.char.selfFoundMode = true
        combined, breakdown, meta = scan()
        T.eq("Self-Found: bags, own bank and own mail", combined[2589], 5 + 30 + 4)
        T.check("Self-Found: no alt stock from Syndicator", breakdown[2589].alts == nil and combined[2592] == nil)
        T.eq("Self-Found: own auctions still count", breakdown[765].auctions, 6)
        -- Nor from the guild bank, which is other characters' stock as well.
        LazyProf.db.profile.includeGuildBank = true
        combined, breakdown = scan()
        T.check("Self-Found: the guild bank is not counted although it is turned on",
            combined[2589] == 5 + 30 + 4 and breakdown[2589].guildBank == nil, combined[2589])
        LazyProf.db.char.selfFoundMode = false
        combined, breakdown = Inventory:ScanAll()      -- same frame: the scan made as Self-Found must not answer
        T.eq("(with the mode off the guild bank counts)", breakdown[2589].guildBank, 500)
        LazyProf.db.profile.includeGuildBank = false
    end)
    for name, fn in pairs(saved) do Memory[name] = fn end
    LazyProf.Client.BankContents = savedContents
    T.check("no use of the memory with Syndicator installed", ok, err)
    -- (The memory's entry points run protected: a call that was made and
    -- failed above would not have raised. It would have been counted.)
    local lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("and none that failed quietly", not table.concat(lines, "\n"):find("last error", 1, true), table.concat(lines, "\n"))

    -- The start-up cleaning writes nothing either: a character that would be
    -- dropped stays, with the account bank of its world.
    Memory:SaveBags({ guid = "Player-1-OLD", name = "Old Alt", world = "us-normal", faction = "Alliance" }, { [1] = 1 }, {}, NOW - 400 * DAY)
    Memory:SaveAccountBank("us-normal", { [1] = 1 }, NOW - 400 * DAY)
    Inventory:Initialize()
    T.check("start with Syndicator: nothing is dropped from the memory",
        LazyProf.db.global.stock.characters["Player-1-OLD"] ~= nil and Memory:AccountBank("us-normal") ~= nil)
    _G.Syndicator = nil
    T.eq("what was remembered before is untouched", (Memory:OwnBank(MAIN.guid))[2589], 7777)
    Inventory:Initialize()
    T.check("(without Syndicator the same start drops it)", LazyProf.db.global.stock.characters["Player-1-OLD"] == nil)
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

    -- A stock setting changed inside the frame is not answered from the
    -- frame's earlier scan, whoever changed it. Each of the four settings on
    -- its own, with nothing but the setting changed between the two scans.
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    Inventory:ForgetAltsPart()
    nextFrame()
    T.eq("alts on", (Inventory:ScanAll())[2589], 65)
    LazyProf.db.profile.includeAltCharacters = false
    T.eq("alts turned off in the same frame", (Inventory:ScanAll())[2589], 45)
    LazyProf.db.profile.includeAltCharacters = true
    T.eq("and on again", (Inventory:ScanAll())[2589], 65)
    LazyProf.db.profile.includeBankItems = false
    T.eq("bank items turned off in the same frame, nothing else", (Inventory:ScanAll())[2589], 25)
    LazyProf.db.profile.includeBankItems = true
    T.eq("and on again", (Inventory:ScanAll())[2589], 65)
    LazyProf.db.char.selfFoundMode = true
    T.eq("Self-Found turned on in the same frame, nothing else", (Inventory:ScanAll())[2589], 45)
    LazyProf.db.char.selfFoundMode = false
    client.reads.bags = 0
    T.eq("everything back on", (Inventory:ScanAll())[2589], 65)
    Inventory:ScanAll()
    T.eq("unchanged settings: the frame's scan answers", client.reads.bags, 1)
    -- The guild bank setting only does something with Syndicator.
    installSyndicator()
    nextFrame()
    T.check("guild bank off", (select(2, Inventory:ScanAll()))[2589].guildBank == nil)
    LazyProf.db.profile.includeGuildBank = true
    T.eq("guild bank turned on in the same frame, nothing else", (select(2, Inventory:ScanAll()))[2589].guildBank, 500)
    LazyProf.db.profile.includeGuildBank = false
    T.check("and off again", (select(2, Inventory:ScanAll()))[2589].guildBank == nil)
    client.reads.bags = 0
    Inventory:ScanAll()
    T.eq("unchanged settings with Syndicator: the frame's scan answers", client.reads.bags, 0)
    _G.Syndicator = nil
    nextFrame()
    LazyProf.db.global.stock.characters[ALT.guid] = nil
    Inventory:ForgetAltsPart()
    nextFrame()

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
-- Building the alts' part of a scan copies every alt's stock. The light
-- refresh scans up to three times a second while crafting, so that part is
-- kept between scans and built again only when it can have changed.
T.section("the alts' part is kept between scans", function()
    fresh()
    for i = 1, 20 do
        local alt = { guid = "Player-1-ALT" .. i, name = "Alt Number " .. i, world = "eu-pvp", faction = "Alliance" }
        local bags, bank, bound = {}, {}, {}
        for k = 1, 40 do
            bags[3000 + ((i * 31 + k) % 500)] = 20
            bank[3000 + ((i * 17 + k) % 500)] = 10
            if k % 9 == 0 then bound[3000 + ((i * 31 + k) % 500)] = 5 end
        end
        Memory:SaveBags(alt, bags, bound, NOW - i * 3600)
        Memory:SaveBank(alt, bank, {}, NOW - i * 7200)
    end
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW)
    Inventory:Initialize()
    advance(2.1)

    local built = 0
    local realAlts = Memory.Alts
    Memory.Alts = function(...)
        built = built + 1
        return realAlts(...)
    end
    local function same(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do if not same(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    -- What a scan gives when nothing is kept.
    local function uncached()
        Inventory:ForgetAltsPart()
        local before = built
        local combined, breakdown, meta = scan()
        built = before
        Inventory:ForgetAltsPart()
        return combined, breakdown, meta
    end
    local wantCombined, wantBreakdown, wantMeta = uncached()
    T.check("fixture: the alts hold stock", count(wantMeta.alts) == 20 and count(wantCombined) > 100, count(wantCombined))

    built = 0
    local allSame = true
    for _ = 1, 50 do
        nextFrame()
        local combined, breakdown, meta = Inventory:ScanAll()
        if not (same(combined, wantCombined) and same(breakdown, wantBreakdown) and same(meta, wantMeta)) then allSame = false end
    end
    T.eq("fifty scans build the alts' part once", built, 1)
    T.check("and each gives what an uncached scan gives", allSame)

    -- What the character itself does leaves it alone.
    client.bags = { [2589] = 6, [765] = 2 }
    Inventory:SaveBags(true)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 41 } }
    built = 0
    client.started.onBankOpened()
    advance(3)
    client.bankOpen = false
    Inventory:InvalidateCache()              -- as every recalculation does
    local combined, breakdown, meta = Inventory:ScanAll()
    T.eq("the character's own saves, a bank visit and a recalculation do not build it again", built, 0)
    T.check("while its own stock is the new one", breakdown[2589].bags == 6 and breakdown[2589].bank == 41)

    -- Bank items off: another part (no alt banks), built once.
    LazyProf.db.profile.includeBankItems = false
    built = 0
    for _ = 1, 5 do nextFrame(); combined, breakdown, meta = Inventory:ScanAll() end
    T.eq("another setting for the bank: built once more", built, 1)
    local anyBank = false
    for _, where in pairs(breakdown) do
        for _, sources in pairs(where.alts or {}) do if sources.bank then anyBank = true end end
    end
    T.check("and without the alts' banks", anyBank == false)
    LazyProf.db.profile.includeBankItems = true
    nextFrame()
    Inventory:ScanAll()

    -- Alts off or Self-Found: not asked for at all.
    LazyProf.db.profile.includeAltCharacters = false
    built = 0
    nextFrame()
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("alts off: not built, nothing of them counted", built == 0 and next(meta.alts) == nil)
    LazyProf.db.profile.includeAltCharacters = true
    LazyProf.db.char.selfFoundMode = true
    nextFrame()
    Inventory:InvalidateCache()
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("Self-Found: not built, nothing of them counted", built == 0 and next(meta.alts) == nil)
    LazyProf.db.char.selfFoundMode = false

    -- Forget: the other characters changed.
    nextFrame()
    Inventory:ScanAll()
    built = 0
    Inventory:ForgetRemembered()
    combined, breakdown, meta = Inventory:ScanAll()
    T.eq("after Forget it is built again", built, 1)
    T.check("and holds nobody", next(meta.alts) == nil and count(combined) == count(client.bags))

    -- The saved table was replaced as a whole (a database reset): the part of the old one is not used.
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    Inventory:ForgetAltsPart()
    nextFrame()
    T.eq("an alt again", (Inventory:ScanAll())[2589], 26)
    LazyProf.db.global = { characters = {} }
    nextFrame()
    built = 0
    T.eq("the saved table replaced: its alts are gone from the scan", (Inventory:ScanAll())[2589], 6)

    -- Dropping old characters at the start is a change of the others too.
    fresh()
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW - 181 * DAY)
    Memory:SaveBags(FARMER, { [2589] = 7 }, {}, NOW)
    nextFrame()
    T.eq("before the start: both alts", (Inventory:ScanAll())[2589], 5 + 20 + 7)
    Inventory:Initialize()
    nextFrame()
    T.eq("after the start dropped the old one: only the other", (Inventory:ScanAll())[2589], 5 + 7)

    -- It is kept for the world and faction the character is of right now.
    fresh()
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    Memory:SaveBags(HORDE, { [2589] = 7000 }, {}, NOW)
    Memory:SaveBags({ guid = "Player-1-NORMAL", name = "Elsewhere", world = "eu-normal", faction = "Alliance" }, { [2589] = 300 }, {}, NOW)
    nextFrame()
    T.eq("the alts of this world and faction", (Inventory:ScanAll())[2589], 25)
    client.identity = { guid = MAIN.guid, name = MAIN.name, world = "eu-normal", faction = "Alliance" }
    nextFrame()
    T.eq("the world reads differently: the part of the other world is not used", (Inventory:ScanAll())[2589], 305)
    client.identity = { guid = MAIN.guid, name = MAIN.name, world = "eu-pvp", faction = "Horde" }
    nextFrame()
    T.eq("the faction reads differently: neither", (Inventory:ScanAll())[2589], 7005)
    client.identity = MAIN
    nextFrame()
    T.eq("and back", (Inventory:ScanAll())[2589], 25)
    -- Another character of the same world and faction has other alts.
    Memory:SaveBags(MAIN, { [2589] = 3 }, {}, NOW)
    client.identity = ALT
    nextFrame()
    T.eq("asked as another character: its own alts, not the part kept for the first", (Inventory:ScanAll())[2589], 5 + 3)
    client.identity = MAIN

    -- While who the character is cannot be read, nothing is kept.
    fresh()
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    client.identity = { guid = MAIN.guid, faction = "Alliance" }     -- no world yet, no name
    nextFrame()
    T.eq("the character is not known yet: no alts", (Inventory:ScanAll())[2589], 5)
    client.identity = MAIN
    nextFrame()
    T.eq("known a moment later: the alts count", (Inventory:ScanAll())[2589], 25)
    Memory.Alts = realAlts
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
-- The bank's rules, as the scanner applies them to what the adapter hands
-- it. (Whole visits on the real adapter are in test_stockflow.lua.)
T.section("the bank is read only while its window is open", function()
    fresh()
    Inventory:Initialize()
    advance(2.1)
    local function bankOf() return Memory:OwnBank(MAIN.guid) end

    -- Closed: nothing is read, whatever arrives.
    client.bank.character = { items = { [2589] = 40 } }
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdateDelayed()
    client.started.onBankChanged("character")
    nextFrame()
    T.check("closed: nothing remembered", bankOf() == nil)
    T.eq("closed: the adapter is not even asked", client.reads.character, 0)

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
    advance(3)   -- past the looks that follow an opening (see below)

    -- A change long after the last read is read in the same call, whatever
    -- container it names: an item that left for the backpack may be
    -- reported for the backpack alone.
    client.reads.character = 0
    client.bank.character = { items = { [2589] = 55 } }
    client.now = NOW + 10
    refreshes = 0
    Inventory:OnBagUpdate(0)
    T.eq("a carried-bag update while the bank is open reads it at once", client.reads.character, 1)
    items, at = bankOf()
    T.check("and it is remembered at once, with the time", items[2589] == 55 and items[6948] == nil and at == NOW + 10)
    T.eq("one redraw request", refreshes, 1)
    -- More changes within 0.2 s of that read: one trailing read, one timer.
    local waiting = #timers
    for _ = 1, 20 do
        Inventory:OnBagUpdate(6)
        Inventory:OnBagUpdate(7)
    end
    client.started.onBankChanged("character")
    T.eq("more changes right after it do not read again", client.reads.character, 1)
    T.eq("they ask for one trailing read, with one timer", #timers, waiting + 1)
    client.bank.character = { items = { [2589] = 56 } }
    advance(0.19)
    T.eq("not before 0.2 s after the last read", client.reads.character, 1)
    advance(0.02)
    T.eq("then the trailing read", client.reads.character, 2)
    T.eq("which sees what the changes left", (bankOf())[2589], 56)
    advance(1)
    T.eq("and nothing after it", client.reads.character, 2)
    -- The pending flag is cleared: a trailing read can be asked for again.
    client.bank.character = { items = { [2589] = 57 } }
    Inventory:OnBagUpdate(6)
    T.eq("a bank-container update long after the last read reads at once", (bankOf())[2589], 57)
    nextFrame()
    client.bank.character = { items = { [2589] = 58 } }
    Inventory:OnBagUpdate(6)
    T.eq("one right after it does not", (bankOf())[2589], 57)
    advance(0.3)
    T.check("a second trailing read in the same visit takes it", (bankOf())[2589] == 58 and client.reads.character == 4,
        client.reads.character)
    advance(1)
    client.bank.character = { items = { [2589] = 59 } }
    client.started.onBankChanged("character")
    T.eq("a change of the bank's tabs reads at once", (bankOf())[2589], 59)
    advance(1)

    -- The client's notice that a batch of updates is complete takes a read
    -- that is owed for this frame's updates.
    client.reads.character = 0
    Inventory:OnBagUpdateDelayed()
    T.eq("batch complete with nothing owed: no read", client.reads.character, 0)
    Inventory:OnBagUpdate(0)                              -- read at once; the bank has not changed yet
    client.bank.character = { items = { [2589] = 60 } }
    Inventory:OnBagUpdate(6)                              -- owed
    T.eq("the second update of a frame is owed", (bankOf())[2589], 59)
    Inventory:OnBagUpdateDelayed()
    T.check("batch complete: taken in the same frame", (bankOf())[2589] == 60 and client.reads.character == 2, client.reads.character)
    Inventory:OnBagUpdateDelayed()
    advance(1)
    T.eq("nothing more: not by a second notice, not by the trailing read", client.reads.character, 2)
    -- A frame later, within 0.2 s of a read, the notice leaves it to the trailing read.
    Inventory:OnBagUpdate(6)
    nextFrame()
    client.reads.character = 0
    client.bank.character = { items = { [2589] = 61 } }
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdateDelayed()
    T.eq("a batch one frame after a read is not read by its notice", client.reads.character, 0)
    advance(0.3)
    T.check("but by the trailing read", client.reads.character == 1 and (bankOf())[2589] == 61, client.reads.character)
    advance(1)

    -- The adapter cannot read just now: what is remembered stays, and
    -- nothing is asked to redraw.
    client.bank.character = nil
    client.bank.account = nil
    client.now = NOW + 20
    refreshes = 0
    Inventory:OnBagUpdate(6)
    advance(1)
    items, at = bankOf()
    T.check("unreadable: the remembered bank is kept", items ~= nil and items[2589] == 61 and at == NOW + 10)
    T.check("unreadable: the account bank is kept", (Memory:AccountBank("eu-pvp"))[4306] == 9)
    T.eq("a look that changed nothing asks for no redraw", refreshes, 0)

    -- One bank readable, the other not: each is judged alone.
    client.bank.account = { items = { [4306] = 1 } }
    Inventory:OnBagUpdate(15)
    advance(1)
    T.check("only the account bank readable: it is saved, the character bank kept",
        (Memory:AccountBank("eu-pvp"))[4306] == 1 and (bankOf())[2589] == 61)

    -- The bank reads without a single item, long into the visit: one such
    -- read is not believed (and asks for no redraw), the second look is.
    client.bank.character = { items = {} }
    client.bank.account = nil
    refreshes = 0
    Inventory:OnBagUpdate(6)
    T.check("emptied: the first empty read is not believed", (bankOf())[2589] == 61 and refreshes == 0, refreshes)
    local emptyLines = {}
    Inventory:RunDiagnostic(emptyLines)
    T.check("the dump: the bank read empty after its own update, that is not believed yet and the bank is unsettled",
        table.concat(emptyLines, "\n"):find(
        "lastRead=empty, not believed slots=28 unresolvedEmpty=true unsettled=true", 1, true) ~= nil,
        table.concat(emptyLines, "\n"))
    T.check("the dump: the bank that was refused had no update of its own and is not unsettled",
        table.concat(emptyLines, "\n"):find(
        "lastRead=refused slots=28 unresolvedEmpty=false unsettled=false", 1, true) ~= nil,
        table.concat(emptyLines, "\n"))
    advance(0.25)
    items = bankOf()
    T.check("the second look 0.2 s later is: saved as empty", items ~= nil and next(items) == nil)
    T.eq("and that asks for a redraw", refreshes, 1)

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
-- A bank is unsettled from the moment an update of one of its own containers
-- arrives (or its tabs change) until a read of that bank taken after that
-- update is kept. While its window is open a scan leaves an unsettled bank
-- out, and both banks while a read is owed, and says so.
T.section("unsettled", function()
    local function bankOf() return Memory:OwnBank(MAIN.guid) end
    -- 5 linen carried, 100 in the bank, 9 silk in the account bank; the
    -- window has been open for three seconds.
    local function visit()
        fresh()
        Inventory:Initialize()
        advance(2.1)
        client.bankOpen = true
        client.bank.character = { items = { [2589] = 100 }, slots = 28 }
        client.bank.account = { items = { [4306] = 9 }, slots = 98 }
        client.started.onBankOpened()
        advance(3)
    end
    local function visitLine(kind)
        local lines = {}
        Inventory:RunDiagnostic(lines)
        return (("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(bank visit " .. kind .. ": [^\n]*)\n"))
    end

    -- An update of a carried bag unsettles no bank. Read at once it leaves
    -- nothing open; while its read is owed, both banks are left out.
    visit()
    Inventory:OnBagUpdate(0)                               -- read at once
    local combined, _, meta = scan()
    T.check("an update of a carried bag, read at once: both banks count", combined[2589] == 105 and combined[4306] == 9
        and meta.bankPending == nil and meta.accountPending == nil, combined[2589])
    nextFrame()
    Inventory:OnBagUpdate(0)                               -- within 0.2 s of that read: owed
    combined, _, meta = scan()
    T.check("while a read is owed both banks are left out", combined[2589] == 5 and combined[4306] == nil, combined[2589])
    T.check("and the scan says a read is on its way, not that they are in doubt", meta.bankPending == true
        and meta.accountPending == true and meta.bankInDoubt == nil and meta.accountInDoubt == nil and meta.bankSeenAt == nil)
    T.eq("neither bank is unsettled by it", visitLine("character"),
        "bank visit character: usable=true kept=4 lastRead=items slots=28 unresolvedEmpty=false unsettled=false")
    advance(0.3)                                           -- the trailing read
    combined, _, meta = scan()
    T.check("the read brings them back", combined[2589] == 105 and combined[4306] == 9 and meta.bankPending == nil
        and meta.accountPending == nil, combined[2589])

    -- An update of a bank's own container unsettles that bank and not the
    -- other, until a read of it is kept.
    visit()
    client.bank.character = nil                            -- cannot be read just now
    Inventory:OnBagUpdate(6)                               -- read at once: refused
    combined, _, meta = scan()
    T.check("its own update and a refused read: that bank is left out, the other counts",
        combined[2589] == 5 and combined[4306] == 9 and meta.bankPending == true and meta.accountPending == nil, combined[2589])
    T.eq("the dump says so", visitLine("character"),
        "bank visit character: usable=true kept=3 lastRead=refused slots=28 unresolvedEmpty=false unsettled=true")
    advance(1)
    combined, _, meta = scan()
    T.check("it stays out while no read of it is kept", combined[2589] == 5 and meta.bankPending == true, combined[2589])
    client.bank.character = { items = { [2589] = 90 }, slots = 28 }
    Inventory:OnBagUpdate(0)                               -- any update reads the bank: kept
    combined, _, meta = scan()
    T.check("a kept read settles it", combined[2589] == 95 and meta.bankPending == nil, combined[2589])

    -- An empty read that is not believed is not kept: it settles nothing.
    -- Here the bank's last stack goes into the account bank; no carried bag
    -- changes.
    visit()
    client.bank.character = { items = {}, slots = 28 }
    client.bank.account = { items = { [4306] = 9, [2589] = 100 }, slots = 98 }
    Inventory:OnBagUpdate(6)                               -- read at once: empty, not believed; the account bank is kept
    Inventory:OnBagUpdate(15)
    Inventory:OnBagUpdateDelayed()
    combined, _, meta = scan()
    T.check("the bank's last stack moved into the account bank: counted once", combined[2589] == 105
        and meta.bankPending == true and meta.accountPending == nil, combined[2589])
    advance(0.25)                                          -- the second look believes it
    combined, _, meta = scan()
    T.check("after the second look the bank is remembered as empty and settled", combined[2589] == 105
        and meta.bankPending == nil and next((bankOf())) == nil, combined[2589])

    -- The same move told the other way round: the account bank's update
    -- comes first. Its read finds the bank empty, which is not believed,
    -- while the bank's own update is still to come: a scan between the two
    -- updates leaves the bank out all the same.
    visit()
    client.bank.character = { items = {}, slots = 28 }
    client.bank.account = { items = { [4306] = 9, [2589] = 100 }, slots = 98 }
    Inventory:OnBagUpdate(15)                              -- read at once
    combined, _, meta = scan()
    T.check("an empty read that is not believed, before the bank's own update: the bank is left out",
        combined[2589] == 105 and meta.bankPending == true and meta.accountPending == nil, combined[2589])
    T.eq("it is not unsettled: no update of its own has come", visitLine("character"),
        "bank visit character: usable=true kept=3 lastRead=empty, not believed slots=28 unresolvedEmpty=true unsettled=false")
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdateDelayed()
    T.eq("nor is it counted after its own update", (scan())[2589], 105)

    -- A matter of order, not of frames. A read taken in the handler of the
    -- update comes after it ...
    visit()
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(6)                               -- read in its handler: kept
    T.eq("a read taken in the handler of the bank's own update settles it", visitLine("character"),
        "bank visit character: usable=true kept=4 lastRead=items slots=28 unresolvedEmpty=false unsettled=false")
    T.eq("and the scan counts the bank", (scan())[2589], 105)
    -- ... a read taken earlier in the same frame does not.
    visit()
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)                               -- read at once: the bank has not changed yet
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    Inventory:OnBagUpdate(6)                               -- the same frame: owed
    T.eq("a read taken earlier in the frame of the bank's update does not", visitLine("character"),
        "bank visit character: usable=true kept=4 lastRead=items slots=28 unresolvedEmpty=false unsettled=true")
    combined, _, meta = scan()
    T.check("the bank is left out until the next read", combined[2589] == 65 and meta.bankPending == true, combined[2589])
    Inventory:OnBagUpdateDelayed()
    T.eq("which the batch notice takes in that frame", (scan())[2589], 105)

    -- A change of a bank's tabs unsettles that bank.
    visit()
    client.usable.account = true                           -- viewable, with its tabs
    client.bank.account = nil                              -- but no slot reads just now
    client.started.onBankChanged("account")                -- read at once: refused
    combined, _, meta = scan()
    T.check("a change of the account bank's tabs unsettles the account bank alone", combined[4306] == nil
        and meta.accountPending == true and meta.bankPending == nil and combined[2589] == 105, combined[2589])

    -- A bank that was never usable in the visit is not left out, whatever
    -- updates name its containers.
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Memory:SaveAccountBank("eu-pvp", { [4306] = 9 }, NOW - DAY)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    client.bank.account = nil
    client.started.onBankOpened()
    advance(3)
    Inventory:OnBagUpdate(15)
    advance(3)
    combined, _, meta = scan()
    T.check("an update for a bank that was never usable: it goes on counting", combined[4306] == 9 and meta.accountPending == nil,
        combined[4306])

    -- Bank items switched off: nothing of the bank, and nothing said of it.
    visit()
    LazyProf.db.profile.includeBankItems = false
    Inventory:OnBagUpdate(0)
    nextFrame()
    Inventory:OnBagUpdate(6)
    combined, _, meta = scan()
    T.check("bank items off: no word of a read on its way", combined[2589] == 5 and meta.bankPending == nil and meta.accountPending == nil)
end)

-- ===========================================================================
-- The adapter reports a close in two steps. During the first the bank still
-- counts as open: when a read is owed or a bank is unsettled, the bank is
-- read once more - kept only when it looks like the reads before it. A bank
-- that is still unsettled then is marked in doubt, and nothing else is.
T.section("the close", function()
    local function bankOf() return Memory:OwnBank(MAIN.guid) end
    local function inDoubt() return (select(3, Memory:OwnBank(MAIN.guid))) end
    local function visit(first)
        fresh()
        Inventory:Initialize()
        advance(2.1)
        client.bankOpen = true
        client.bank.character = first or { items = { [2589] = 100 }, slots = 28 }
        client.bank.account = { items = { [4306] = 9 }, slots = 98 }
        client.started.onBankOpened()
        advance(3)
        client.reads.character = 0
    end
    local function close()
        client.started.onBankClosing()
        client.bankOpen = false          -- the adapter stops counting it as open between the two notices
        client.started.onBankClosed()
    end

    -- Nothing changed: nothing is owed, nothing is read.
    visit()
    close()
    T.eq("no change before the close: no read", client.reads.character, 0)
    advance(3)
    T.eq("and none afterwards", client.reads.character, 0)

    -- One update, read at once; the close owes nothing.
    visit()
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    Inventory:OnBagUpdate(6)
    close()
    T.eq("a single update was read when it came; the close reads nothing", client.reads.character, 1)
    T.eq("the withdrawal is remembered", (bankOf())[2589], 40)

    -- Two updates and the close in one frame: the owed read is taken at the close.
    visit()
    client.bank.character = { items = { [2589] = 70 }, slots = 28 }
    Inventory:OnBagUpdate(0)           -- read at once: 70
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    Inventory:OnBagUpdate(6)           -- owed
    T.eq("before the close the first read stands", (bankOf())[2589], 70)
    refreshes = 0
    close()
    T.eq("the owed read is taken during the closing notice", client.reads.character, 2)
    T.check("and kept: it looks like the reads of this visit", (bankOf())[2589] == 40 and inDoubt() == false)
    T.check("a shown list is asked to redraw", refreshes >= 1, refreshes)
    local waitingLines = {}
    Inventory:RunDiagnostic(waitingLines)
    T.check("after the close no bank read is waiting any more",
        table.concat(waitingLines, "\n"):find("bankRead=false bankOpen=false", 1, true) ~= nil, table.concat(waitingLines, "\n"))
    advance(3)
    T.eq("the trailing read that was waiting does not run after the close", client.reads.character, 2)

    -- The read at the close is not kept when it does not look like a normal
    -- read. The bank's own update came after the last kept read, so the bank
    -- is unsettled: in doubt then.
    local function owed(closingState, onlyBank)
        visit()
        client.bank.character = { items = { [2589] = 70 }, slots = 28 }
        Inventory:OnBagUpdate(onlyBank and 6 or 0)         -- read at once: 70
        Inventory:OnBagUpdate(6)                           -- the bank's own update: unsettled, the read owed
        client.bank.character = closingState
        close()
        return (bankOf())[2589], inDoubt()
    end
    local kept, doubt = owed({ items = {}, slots = 28 })
    T.check("a closing read without a single item is not kept; the bank is in doubt", kept == 70 and doubt == true, kept)
    kept, doubt = owed({ items = { [2589] = 3 }, slots = 12 })
    T.check("a closing read with fewer slots is not kept; in doubt", kept == 70 and doubt == true, kept)
    kept, doubt = owed({ items = { [2589] = 3 }, slots = 40 })
    T.check("a closing read with more slots is not kept; in doubt", kept == 70 and doubt == true, kept)
    kept, doubt = owed(nil)
    T.check("a closing read the adapter refuses is not kept; in doubt", kept == 70 and doubt == true, kept)
    kept, doubt = owed({ items = { [2589] = 3 }, slots = 28 })
    T.check("(the same read with the same slots is kept, and nothing is in doubt)", kept == 3 and doubt == false, kept)
    -- No carried bag needs to have been updated for that: a move between the
    -- two banks changes none.
    kept, doubt = owed({ items = {}, slots = 28 }, true)
    T.check("only bank containers were updated: an empty closing read leaves the bank in doubt", kept == 70 and doubt == true, kept)
    kept, doubt = owed(nil, true)
    T.check("only bank containers were updated: a refused closing read leaves it in doubt", kept == 70 and doubt == true, kept)
    -- A read that is owed for an update of a carried bag marks nothing by
    -- itself: the bank's own update was read in its handler, the bank is
    -- settled, and what is remembered of it is right.
    local function owedForBags(closingState)
        visit()
        client.bank.character = { items = { [2589] = 70 }, slots = 28 }
        Inventory:OnBagUpdate(6)                           -- read at once: 70, kept
        Inventory:OnBagUpdate(0)                           -- owed
        client.reads.character = 0
        client.bank.character = closingState
        close()
        return (bankOf())[2589], inDoubt(), client.reads.character
    end
    local readAgain
    kept, doubt, readAgain = owedForBags(nil)
    T.check("a read owed for a carried bag's update: the close reads once more", readAgain == 1, readAgain)
    T.check("refused: nothing is kept and nothing is marked", kept == 70 and doubt == false, kept)
    kept, doubt = owedForBags({ items = {}, slots = 28 })
    T.check("empty: nothing is kept and nothing is marked", kept == 70 and doubt == false, kept)
    kept, doubt = owedForBags({ items = { [2589] = 60 }, slots = 28 })
    T.check("readable: kept", kept == 60 and doubt == false, kept)

    -- The last stack of the bank goes into the account bank and the window
    -- is closed before the second look at the emptied bank: no carried bag
    -- changed. The stack must not stay counted in both banks.
    local function lastStackAcross(closeAfter)
        visit()
        client.bank.character = { items = {}, slots = 28 }
        client.bank.account = { items = { [4306] = 9, [2589] = 100 }, slots = 98 }
        Inventory:OnBagUpdate(6)                           -- read at once: the bank empty (not believed), the account bank kept
        Inventory:OnBagUpdate(15)
        Inventory:OnBagUpdateDelayed()
        local during = (scan())[2589]
        if closeAfter > 0 then advance(closeAfter) end
        close()
        return during, (scan())[2589], inDoubt(), select(3, Memory:AccountBank("eu-pvp"))
    end
    local during, after, accountDoubt
    during, after, doubt, accountDoubt = lastStackAcross(0)
    T.check("the bank's last stack into the account bank: counted once in the frame of the move", during == 105, during)
    T.check("closed in that frame: counted once, the emptied bank in doubt, the other not",
        after == 105 and doubt == true and accountDoubt == false, tostring(after) .. "/" .. tostring(doubt))
    during, after, doubt, accountDoubt = lastStackAcross(0.1)
    T.check("closed 0.1 s later: the same", after == 105 and doubt == true and accountDoubt == false,
        tostring(after) .. "/" .. tostring(doubt))
    during, after, doubt, accountDoubt = lastStackAcross(0.3)
    T.check("closed 0.3 s later, after the second look: remembered as empty, nothing in doubt",
        after == 105 and doubt == false and accountDoubt == false and next((bankOf())) == nil, tostring(after) .. "/" .. tostring(doubt))

    -- An empty bank that is remembered as empty: an empty read of it that is
    -- not believed yet is no reason for a mark.
    local function emptyBank(openFor, during_)
        fresh()
        Inventory:Initialize()
        advance(2.1)
        Memory:SaveBank(MAIN, {}, {}, NOW - DAY)
        client.bankOpen = true
        client.bank.character = { items = {}, slots = 28 }
        client.bank.account = { items = { [4306] = 9 }, slots = 98 }
        client.started.onBankOpened()
        advance(openFor)
        during_()
        close()
        return inDoubt(), select(3, Memory:AccountBank("eu-pvp"))
    end
    doubt, accountDoubt = emptyBank(1, function()
        client.bags = {}
        client.bank.account = { items = { [4306] = 9, [2589] = 5 }, slots = 98 }
        Inventory:OnBagUpdate(0)                           -- a deposit into the other bank, read at once
        Inventory:OnBagUpdate(15)
        advance(0.5)
    end)
    T.check("an empty bank, a deposit into the other one in a visit of 1.5 s: neither is in doubt", doubt == false and accountDoubt == false)
    doubt, accountDoubt = emptyBank(0.1, function() Inventory:OnBagUpdate(0) end)
    T.check("an empty bank, a glance with one bag update that changes nothing: neither is in doubt",
        doubt == false and accountDoubt == false)

    -- A read that was owed is taken and refused: the update is still
    -- unanswered. The close reads once more and settles it.
    local function refusedTrailing(atClose)
        visit()
        client.bank.character = { items = { [2589] = 70 }, slots = 28 }
        Inventory:OnBagUpdate(0)           -- read at once: 70
        Inventory:OnBagUpdate(6)           -- owed
        client.bank.character = nil
        advance(0.3)                       -- the trailing read: refused
        local combined, _, meta = scan()
        T.check("a refused trailing read: a scan still leaves the bank out", combined[2589] == 5 and meta.bankPending == true,
            combined[2589])
        client.reads.character = 0
        client.bank.character = atClose
        close()
        T.eq("the close reads the bank once more", client.reads.character, 1)
        return (bankOf())[2589], inDoubt()
    end
    kept, doubt = refusedTrailing(nil)
    T.check("refused again at the close: in doubt", kept == 70 and doubt == true, kept)
    kept, doubt = refusedTrailing({ items = { [2589] = 40 }, slots = 28 })
    T.check("readable at the close: kept, nothing in doubt", kept == 40 and doubt == false, kept)
    -- A bank the visit never got to read is not behind, whatever is moved.
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Memory:SaveAccountBank("eu-pvp", { [4306] = 9 }, NOW - DAY)
    Memory:SaveBags(ALT, { [1] = 1 }, {}, NOW)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    client.bank.account = nil                              -- not viewable by this character
    client.started.onBankOpened()
    advance(3)
    Inventory:OnBagUpdate(0)
    Inventory:OnBagUpdate(6)
    local combined, _, meta = scan()
    T.check("a bank never read in the visit stays counted while a read is owed", combined[4306] == 9 and meta.accountPending == nil
        and meta.bankPending == true, combined[4306])
    advance(1)
    Inventory:OnBagUpdate(0)
    advance(1)
    close()
    T.check("and is not in doubt after it", select(3, Memory:AccountBank("eu-pvp")) == false)

    -- Which banks a visit can mark: only one that was usable at some read of
    -- it. The account bank is remembered from another character and this
    -- one may not view it. A move in its own bank, Escape while the read is
    -- still owed and the bank refused by then.
    local function blindVisit()
        fresh()
        Inventory:Initialize()
        advance(2.1)
        Memory:SaveAccountBank("eu-pvp", { [4306] = 9 }, NOW - DAY)
        client.bankOpen = true
        client.bank.character = { items = { [2589] = 100 }, slots = 28 }
        client.bank.account = nil                          -- may not be viewed
        client.started.onBankOpened()
        advance(3)
    end
    blindVisit()
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)                               -- read at once: the bank as it was
    Inventory:OnBagUpdate(6)                               -- owed
    client.bank.character = nil
    close()
    T.check("a hurried close: the bank that was used is in doubt", inDoubt() == true)
    T.check("the bank that was never usable in the visit is not", select(3, Memory:AccountBank("eu-pvp")) == false)
    T.check("it was asked at every read of the visit, the closing one included",
        client.asked.account == client.reads.account and client.reads.account >= 4, client.asked.account)
    local blindLines = {}
    Inventory:RunDiagnostic(blindLines)
    T.check("the dump: which bank was usable", table.concat(blindLines, "\n"):find("bank visit character: usable=true", 1, true) ~= nil
        and table.concat(blindLines, "\n"):find("bank visit account: usable=false", 1, true) ~= nil, table.concat(blindLines, "\n"))
    -- Usable at one read is enough: a bank that is refused later can still
    -- have been changed before.
    blindVisit()
    client.usable.account = true                           -- can be viewed, has its tab; no slot reads
    Inventory:OnBagUpdate(15)
    advance(1)
    client.usable.account = false
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    Inventory:OnBagUpdate(15)
    close()
    T.check("usable at one read of the visit: it can be marked", select(3, Memory:AccountBank("eu-pvp")) == true)

    -- No read of this visit was kept for that bank: nothing to compare with, nothing kept.
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Memory:SaveBank(MAIN, { [2589] = 500 }, {}, NOW - DAY)
    client.bankOpen = true
    client.bank.character = nil                       -- refused all through the visit
    client.started.onBankOpened()
    advance(3)
    Inventory:OnBagUpdate(0)
    Inventory:OnBagUpdate(6)
    client.bank.character = { items = { [2589] = 3 }, slots = 28 }
    close()
    T.eq("a bank never read in this visit is not saved from the closing read", (bankOf())[2589], 500)
    T.check("its own update came while it could not be read: in doubt", inDoubt() == true)

    -- Each bank is judged alone at the close.
    visit()
    client.bank.character = { items = { [2589] = 70 }, slots = 28 }
    Inventory:OnBagUpdate(0)
    Inventory:OnBagUpdate(6)
    client.bank.character = { items = {}, slots = 28 }
    client.bank.account = { items = { [4306] = 4 }, slots = 98 }
    close()
    T.check("at the close: the account bank's read is kept, the character bank's empty one is not",
        (Memory:AccountBank("eu-pvp"))[4306] == 4 and (bankOf())[2589] == 70)
    T.check("and only the character bank is in doubt", inDoubt() == true and select(3, Memory:AccountBank("eu-pvp")) == false)

    -- The dump says what the close did.
    local lines = {}
    Inventory:RunDiagnostic(lines)
    local text = table.concat(lines, "\n")
    T.check("the dump: what the close did",
        text:find("bank visit close: owed=true unsettled=character readAgain=true kept=account markedInDoubt=character", 1, true) ~= nil, text)
    T.check("the dump: the bank marked in doubt",
        text:find("bank=1 items (less than an hour ago, in doubt: not counted)", 1, true) ~= nil, text)

    -- A logout with the bank open ends the visit the same way, once.
    visit()
    client.bank.character = { items = { [2589] = 70 }, slots = 28 }
    Inventory:OnBagUpdate(0)
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    Inventory:OnBagUpdate(6)
    client.started.onLogout()
    T.check("logout with the bank open: the owed read is taken and kept", (bankOf())[2589] == 40 and client.reads.character == 2,
        client.reads.character)
    client.started.onLogout()
    Inventory:OnLogout()
    T.eq("a second logout notice does not read again", client.reads.character, 2)
    close()
    T.eq("nor does a close notice that still follows", client.reads.character, 2)
    -- Also when the read at the first notice could not settle anything.
    visit()
    client.bank.character = { items = {}, slots = 28 }
    Inventory:OnBagUpdate(6)           -- read at once: empty, not believed; the bank is unsettled
    client.started.onLogout()
    T.eq("logout with an unsettled bank: the bank is read once more", client.reads.character, 2)
    client.started.onLogout()
    close()
    T.eq("and only once, whatever notices follow", client.reads.character, 2)
    T.check("the remembered bank is unchanged, and in doubt: its update was never followed by a read that could be kept",
        (bankOf())[2589] == 100 and inDoubt() == true)

    -- After the close nothing is read, and a bank-container update that still
    -- arrives is counted for the dump (the count runs for the whole session).
    local function closedUpdates()
        local out = {}
        Inventory:RunDiagnostic(out)
        local line = table.concat(out, "\n"):match("bank updates while closed: [^\n]*") or ""
        return tonumber(line:match("closed: (%d+)")), line
    end
    visit()
    local before = closedUpdates()
    close()
    client.bank.character = { items = { [2589] = 1 }, slots = 28 }
    client.bankOpen = false
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(0)       -- a carried bag: not a bank update
    advance(0.2)
    Inventory:OnBagUpdate(15)
    local counted, line = closedUpdates()
    advance(3)
    T.eq("closed: the adapter is not asked to read", client.reads.character, 0)
    T.eq("closed: the remembered bank is unchanged", (bankOf())[2589], 100)
    T.eq("the dump counts the bank updates that came while it was closed", counted, before + 2)
    T.check("and says how long after the close the last one came", line:find(", last 0.2 s after closing", 1, true) ~= nil, line)

    -- Open again: the count of an earlier visit stays for the paste, and reads work again.
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 12 }, slots = 28 }
    client.started.onBankOpened()
    T.eq("reopened: saved again", (bankOf())[2589], 12)
    advance(3)
    client.bank.character = { items = { [2589] = 13 }, slots = 28 }
    Inventory:OnBagUpdate(6)
    T.eq("reopened: changes are read again", (bankOf())[2589], 13)

    -- While it is open such an update is a change to read, not one to count.
    before = closedUpdates()
    nextFrame()
    Inventory:OnBagUpdate(6)
    T.eq("an update while the bank is open is not counted", (closedUpdates()), before)
end)

-- ===========================================================================
-- The second after the close: the carried bags are compared with what they
-- held at the closing notice.
T.section("after the close", function()
    local function bankOf() return Memory:OwnBank(MAIN.guid) end
    local function inDoubt() return (select(3, Memory:OwnBank(MAIN.guid))) end
    local function closedVisit()
        fresh()
        Inventory:Initialize()
        advance(2.1)
        client.bankOpen = true
        client.bank.character = { items = { [2589] = 100 }, slots = 28 }
        client.bank.account = { items = { [4306] = 9 }, slots = 98 }
        client.started.onBankOpened()
        advance(3)
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
        client.reads.bags = 0
    end

    -- The answer of a last move: the bags changed.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 65 }
    refreshes = 0
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(0)
    T.eq("the updates themselves read nothing", client.reads.bags, 0)
    T.check("nothing is marked before something compared", inDoubt() == false)
    nextFrame()
    T.eq("one comparison a frame later, however many updates there were", client.reads.bags, 1)
    T.check("the bags changed: both remembered banks are in doubt", inDoubt() == true
        and select(3, Memory:AccountBank("eu-pvp")) == true)
    T.eq("still remembered", (bankOf())[2589], 100)
    T.check("a shown list is asked to redraw", refreshes >= 1, refreshes)
    local combined, breakdown, meta = scan()
    T.check("a scan counts neither", combined[2589] == 65 and combined[4306] == nil and meta.bankInDoubt == true
        and meta.accountInDoubt == true, combined[2589])
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.eq("once marked, nothing is compared any more", client.reads.bags, 1 + 1)   -- the scan above read the bags once

    -- A scan that comes before the next frame makes the comparison itself,
    -- also when the frame has scanned before the update came.
    closedVisit()
    advance(0.08)
    T.eq("this frame's scan, before the answer arrives", (Inventory:ScanAll())[2589], 105)
    client.reads.bags = 0
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    combined, breakdown, meta = Inventory:ScanAll()     -- no InvalidateCache: the update dropped the frame's scan
    T.check("a scan in the frame of the update does not count the bank", combined[2589] == 65 and meta.bankInDoubt == true,
        combined[2589])
    T.eq("with the bags it read anyway: one read", client.reads.bags, 1)
    nextFrame()
    T.eq("and the timer has nothing left to compare", client.reads.bags, 1)

    -- Only the banks that were usable in the visit are marked: here the
    -- account bank is remembered from another character and this one may
    -- not view it.
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Memory:SaveAccountBank("eu-pvp", { [4306] = 9 }, NOW - DAY)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    client.bank.account = nil
    client.started.onBankOpened()
    advance(3)
    client.started.onBankClosing()
    client.bankOpen = false
    client.started.onBankClosed()
    advance(0.08)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("a late answer marks the bank that was usable", inDoubt() == true)
    T.check("and not the one that never was", select(3, Memory:AccountBank("eu-pvp")) == false)
    combined, breakdown, meta = scan()
    T.check("which goes on counting", combined[4306] == 9 and meta.accountInDoubt == nil, combined[4306])

    -- An item the bags did not hold at the close is a change too.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 5, [4306] = 9 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("an item that was not carried before arrives: marked", inDoubt() == true)
    closedVisit()
    advance(0.08)
    client.bags = {}
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("an item that was carried is gone: marked", inDoubt() == true)

    -- Nothing changed in the bags: no doubt, whatever container the update names.
    closedVisit()
    advance(0.08)
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("updates that change no count mark nothing", inDoubt() == false and select(3, Memory:AccountBank("eu-pvp")) == false)
    T.eq("they were compared once", client.reads.bags, 1)
    -- Bags that cannot be read decide nothing; the next update compares again.
    client.bags, client.backpackSlots = {}, 0
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("bags that cannot be read mark nothing", inDoubt() == false)
    client.bags, client.backpackSlots = { [2589] = 65 }, 16
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("readable again and changed: marked", inDoubt() == true)

    -- Later than a second after the close nothing is watched.
    closedVisit()
    advance(1.5)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("a change of the bags 1.5 s after the close marks nothing", inDoubt() == false)
    T.eq("and nothing is compared", client.reads.bags, 0)

    -- The dump tells it.
    local lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("the dump: nothing came inside the watch",
        table.concat(lines, "\n"):find("after the close: bagUpdates=0 compared=0 carriedBagsChanged=false", 1, true) ~= nil,
        table.concat(lines, "\n"))
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(0)
    nextFrame()
    lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("the dump: a late answer",
        table.concat(lines, "\n"):find("after the close: bagUpdates=2 compared=1 carriedBagsChanged=true (the remembered banks were marked in doubt)", 1, true) ~= nil,
        table.concat(lines, "\n"))

    -- A new visit ends the watch, and its first kept read takes the mark away.
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    client.started.onBankOpened()
    T.check("the next visit's kept read clears the doubt", inDoubt() == false and (bankOf())[2589] == 40)
    T.check("of the account bank too", select(3, Memory:AccountBank("eu-pvp")) == false)
end)

-- ===========================================================================
-- Whether a bank's items are there the moment its window opens is not known.
-- So the bank is always looked at once more half a second after it opened,
-- and a read without a single item is not believed in the first two seconds
-- (when one came earlier, or the bank was refused, it is looked at again at
-- that mark).
T.section("the first moments after opening", function()
    local function bankOf() return Memory:OwnBank(MAIN.guid) end
    local function start(remembered)
        fresh()
        Inventory:Initialize()
        advance(2.1)
        if remembered ~= false then
            Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - DAY)
            Memory:SaveAccountBank("eu-pvp", { [4306] = 9 }, NOW - DAY)
        end
        client.bankOpen = true
        client.bank.character = { items = {} }
        client.bank.account = { items = {} }
        client.reads.character = 0
    end
    local function close()
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
    end

    -- Always a second look, whatever the first read gave.
    start()
    client.bank.character = { items = { [2589] = 70 } }
    client.bank.account = { items = { [4306] = 1 } }
    client.started.onBankOpened()
    T.eq("the first read is taken at once", (bankOf())[2589], 70)
    T.eq("one read so far", client.reads.character, 1)
    client.bank.character = { items = { [2589] = 70, [765] = 4 } }   -- the rest arrived, without any event
    advance(0.4)
    T.eq("not looked at again before half a second", client.reads.character, 1)
    advance(0.2)
    T.eq("looked at again half a second after opening", client.reads.character, 2)
    T.eq("the part that arrived late is remembered", (bankOf())[765], 4)
    -- And always a third, two seconds after the opening: a bank that was
    -- there only in part and completed without any bag update is read whole
    -- while its window is still open.
    client.bank.character = { items = { [2589] = 70, [765] = 4, [2592] = 9 } }
    advance(1.3)
    T.eq("not looked at again before two seconds", client.reads.character, 2)
    advance(0.2)
    T.eq("looked at again two seconds after opening, although both reads found items", client.reads.character, 3)
    T.eq("what arrived after the second look is remembered", (bankOf())[2592], 9)
    advance(5)
    T.eq("and then no more", client.reads.character, 3)

    -- Refused at opening, readable a moment later, no event.
    start()
    client.bank.character = nil
    client.started.onBankOpened()
    T.eq("refused at opening: the remembered bank stays", (bankOf())[2589], 40)
    client.bank.character = { items = { [2589] = 71 } }
    advance(0.6)
    T.eq("readable at the second look: remembered", (bankOf())[2589], 71)

    -- Still refused at half a second: one more look at the two-second mark.
    -- The other bank read well all along, so only the refusal asks for it.
    start()
    client.bank.character = nil
    client.bank.account = { items = { [4306] = 1 } }
    client.started.onBankOpened()
    advance(0.6)
    T.eq("the two reads of every opening", client.reads.character, 2)
    client.bank.character = { items = { [2589] = 72 } }
    advance(1.2)
    T.eq("still refused at half a second: not yet", (bankOf())[2589], 40)
    advance(0.3)
    T.check("a refused read asks for the look two seconds after opening", (bankOf())[2589] == 72 and client.reads.character == 3,
        client.reads.character)
    advance(10)
    T.eq("and then no more", client.reads.character, 3)

    -- No item at all: not believed at opening, not at half a second.
    start()
    client.started.onBankOpened()
    T.check("empty at opening: the remembered bank is kept", (bankOf())[2589] == 40)
    T.check("empty at opening: the account bank is kept", (Memory:AccountBank("eu-pvp"))[4306] == 9)
    Inventory:OnBagUpdate(6)
    advance(0.3)
    T.check("an update and its trailing read while still nothing is there: kept", (bankOf())[2589] == 40)
    advance(0.3)
    T.check("empty at half a second: the remembered bank is still kept", (bankOf())[2589] == 40)
    advance(1.3)
    T.check("just before two seconds: still kept", (bankOf())[2589] == 40)
    client.now = NOW + 5
    advance(0.2)
    local items, at = bankOf()
    T.check("empty two seconds after opening, and seen empty before: believed, the bank is saved as empty",
        items ~= nil and next(items) == nil and at == NOW + 5)
    local account = Memory:AccountBank("eu-pvp")
    T.check("and so is the account bank", account ~= nil and next(account) == nil)
    advance(10)
    T.eq("nothing is left waiting", #timers, 0)

    -- A bank that really is empty and was never seen: remembered as seen, with nothing in it.
    start(false)
    client.started.onBankOpened()
    advance(1.9)
    T.check("never remembered, empty: nothing saved before two seconds", bankOf() == nil)
    advance(0.2)
    items = bankOf()
    T.check("never remembered, empty: saved as empty at two seconds", items ~= nil and next(items) == nil)

    -- Closed before the two seconds are over: the remembered bank stays,
    -- and nothing is in doubt (the carried bags did not change).
    start()
    client.started.onBankOpened()
    advance(0.7)
    close()
    client.reads.character = 0
    advance(5)
    T.check("closed before it could be believed: kept, and nothing read after the close",
        (bankOf())[2589] == 40 and client.reads.character == 0, client.reads.character)
    T.check("and not in doubt", select(3, Memory:OwnBank(MAIN.guid)) == false)

    -- The items arrive a moment after the window, with an update.
    start()
    client.started.onBankOpened()
    nextFrame()
    client.bank.character = { items = { [2589] = 73 } }
    Inventory:OnBagUpdate(6)
    advance(0.2)
    T.eq("items that arrive with an update are saved by the trailing read", (bankOf())[2589], 73)

    -- The bank is emptied in the first two seconds, after it was read with
    -- items: believed on the second look, without waiting for the mark.
    start()
    client.bank.character = { items = { [2589] = 74 } }
    client.started.onBankOpened()
    advance(1)
    client.bank.character = { items = {} }
    Inventory:OnBagUpdate(6)
    T.eq("emptied one second after opening: the first empty read is not believed", (bankOf())[2589], 74)
    advance(0.25)
    T.check("the second look is", next((bankOf())) == nil)

    -- One bank has its items at once, the other not yet: each is judged alone.
    start()
    client.bank.character = { items = { [2589] = 75 } }
    client.started.onBankOpened()
    T.check("the bank that has items is saved, the empty one waits",
        (bankOf())[2589] == 75 and (Memory:AccountBank("eu-pvp"))[4306] == 9)

    -- A scan in that first moment leaves a bank out whose empty read is not
    -- believed yet: what is remembered of it is contradicted by the latest
    -- read, and its stock may be in the other bank by now.
    start()
    client.started.onBankOpened()
    local combined, _, meta = scan()
    T.check("a scan right after an opening that found the bank empty leaves it out, as being read",
        combined[2589] == 5 and meta.bankPending == true and meta.bankInDoubt == nil, combined[2589])
    client.bank.character = { items = { [2589] = 40 } }
    client.bank.account = { items = { [4306] = 9 } }
    advance(0.6)                          -- the look at half a second finds the items
    combined, _, meta = scan()
    T.check("when its items have arrived it counts again", combined[2589] == 5 + 40 and meta.bankPending == nil, combined[2589])

    -- Each look has one timer, however often it is asked for.
    start()
    client.started.onBankOpened()
    for _ = 1, 5 do
        Inventory:OnBagUpdate(6)      -- each read that finds nothing would ask for the two-second look again
        nextFrame()
    end
    advance(0.001)
    local looks = 0
    for _, t in ipairs(timers) do
        if t.due > fakeNow + 0.05 then looks = looks + 1 end
    end
    T.eq("the half-second look, the two-second look and the trailing read are each waiting once", looks, 3)

    -- Opened again shortly after: the looks are counted from the new opening.
    start()
    client.bank.character = { items = { [2589] = 76 } }
    client.started.onBankOpened()
    advance(0.3)
    close()
    advance(0.1)
    client.bankOpen = true
    client.bank.character = { items = {} }
    client.started.onBankOpened()
    advance(0.2)                          -- 0.6 s after the first opening, 0.2 s after the second
    T.eq("a second visit: an early empty read is not believed", (bankOf())[2589], 76)
    client.bank.character = { items = { [2589] = 77 } }
    client.reads.character = 0
    advance(0.2)                          -- 0.4 s after the second opening
    T.eq("the first visit's look does not stand in for the second visit's", client.reads.character, 0)
    advance(0.2)
    T.eq("the second visit gets its own half-second look", (bankOf())[2589], 77)
end)

-- ===========================================================================
T.section("a scan never reads the bank", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - 3 * DAY)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 90 } }
    refreshes = 0
    local combined, breakdown, meta = scan()
    T.eq("bank open: the scan does not ask the adapter for it", client.reads.character, 0)
    T.eq("it counts what is remembered", breakdown[2589].bank, 40)
    T.eq("with the age of that", meta.bankSeenAt, NOW - 3 * DAY)
    T.eq("and asks for no redraw", refreshes, 0)

    -- The open bank while a read is owed: a scan leaves both banks out until
    -- that read.
    Inventory:Initialize()
    client.bank.account = { items = { [4306] = 9 } }
    client.started.onBankOpened()
    advance(3)
    T.eq("fixture: the visit's reads are remembered", (scan())[2589], 5 + 90)
    nextFrame()
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)                               -- read at once: the bank has not changed yet
    Inventory:ScanAll()                                    -- this frame's scan, kept for the frame
    client.bank.character = { items = { [2589] = 30 } }
    Inventory:OnBagUpdate(6)                               -- owed
    client.reads.character = 0
    combined, breakdown, meta = Inventory:ScanAll()        -- the update dropped the frame's scan
    T.check("a read is owed: the bank is left out, not counted beside the bags that changed",
        combined[2589] == 65 and breakdown[2589].bank == nil, combined[2589])
    T.check("the scan says a read is on its way, not that the bank is in doubt",
        meta.bankPending == true and meta.accountPending == true and meta.bankInDoubt == nil and meta.bankSeenAt == nil)
    T.eq("and still reads nothing", client.reads.character, 0)
    Inventory:OnBagUpdateDelayed()
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("after the read the bank counts again, in the same frame", combined[2589] == 95 and meta.bankPending == nil
        and meta.accountPending == nil, combined[2589])
    -- The same without any update of a carried bag: an item may have gone
    -- into the other bank.
    advance(1)
    Inventory:OnBagUpdate(6)
    nextFrame()
    Inventory:OnBagUpdate(6)
    combined, breakdown, meta = scan()
    T.check("an update of the bank's own container while the read is owed: left out too",
        combined[2589] == 65 and meta.bankPending == true, combined[2589])
    advance(1)
    combined, breakdown, meta = scan()
    T.check("until the trailing read", combined[2589] == 95 and meta.bankPending == nil, combined[2589])
    LazyProf.db.profile.includeBankItems = false
    Inventory:OnBagUpdate(0)
    Inventory:OnBagUpdate(6)
    combined, breakdown, meta = scan()
    T.check("bank items off: nothing of the bank, and nothing said of it", combined[2589] == 65 and meta.bankPending == nil)
end)

-- ===========================================================================
-- Nothing that touches the memory may raise into the game: not from an
-- event, not from a timer, not from the options. Each entry point is tried
-- with the client call it depends on failing. Every failure is counted.
T.section("no entry point lets a failure out", function()
    local function failures()
        local lines = {}
        Inventory:RunDiagnostic(lines)
        local n = table.concat(lines, "\n"):match("; (%d+) this session")
        return tonumber(n) or 0
    end
    local function openBank()
        fresh()
        Inventory:Initialize()
        advance(2.1)
        client.bankOpen = true
        client.bank.character = { items = { [2589] = 100 }, slots = 28 }
        client.bank.account = { items = { [4306] = 9 }, slots = 98 }
        client.started.onBankOpened()
        advance(3)
    end
    local real = {}
    for name, fn in pairs(LazyProf.Client) do real[name] = fn end
    local function breakCall(name)
        LazyProf.Client[name] = function() error(name .. " failed") end
    end
    local function restore()
        for name, fn in pairs(real) do LazyProf.Client[name] = fn end
    end
    -- Run `action` with the adapter's `call` failing; it must not raise, and
    -- the failure must be counted (so it really was reached).
    local function survives(label, call, action)
        local before = failures()
        breakCall(call)
        local ok, err = pcall(action)
        restore()
        T.check(label .. ": does not raise", ok, err)
        T.check(label .. ": and the failure is counted", failures() > before, failures() - before)
    end

    openBank()
    survives("a bag update with the bank open", "BankContents", function() Inventory:OnBagUpdate(0) end)
    openBank()
    survives("a bag update when the container cannot be told", "BankKindOfBag", function() Inventory:OnBagUpdate(0) end)
    openBank()
    Inventory:OnBagUpdate(6)
    nextFrame()
    Inventory:OnBagUpdate(6)                                -- owed: the trailing read is waiting
    survives("the trailing read", "BankContents", function() advance(1) end)
    openBank()
    survives("a change of the bank's tabs", "BankContents", function() client.started.onBankChanged("character") end)
    openBank()
    Inventory:OnBagUpdate(0)                                -- read at once
    Inventory:OnBagUpdate(6)                                -- owed, in the same frame
    survives("the batch notice", "BankContents", function() Inventory:OnBagUpdateDelayed() end)
    fresh()
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    survives("the read at the opening and the looks after it", "BankContents", function()
        client.started.onBankOpened()
        advance(3)
    end)
    openBank()
    Inventory:OnBagUpdate(6)
    nextFrame()
    Inventory:OnBagUpdate(6)
    survives("the closing notice", "BankContents", function()
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
    end)
    openBank()
    Inventory:OnBagUpdate(6)
    nextFrame()
    Inventory:OnBagUpdate(6)
    survives("a logout with the bank open", "BankContents", function() client.started.onLogout() end)
    openBank()
    client.started.onBankClosing()
    client.bankOpen = false
    client.started.onBankClosed()
    Inventory:OnBagUpdate(0)
    survives("the comparison after the close", "BagContents", function() nextFrame() end)
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Inventory:OnBagUpdate(0)                                -- a bag save is waiting
    survives("the save at logout", "BagContents", function() client.started.onLogout() end)
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Inventory:OnBagUpdate(0)
    survives("the timed bag save", "BagContents", function() advance(3) end)
    openBank()
    survives("the look at the open bank after Forget", "BankContents", function() Inventory:ForgetRemembered() end)
    fresh()
    Inventory:Initialize()
    advance(2.1)
    survives("the note that the Self-Found setting changed", "CharacterIdentity", function() Inventory:OnSendingChanged() end)
    fresh()
    survives("starting the adapter's events", "StartStock", function() Inventory:Initialize() end)
    fresh()
    survives("dropping old characters at the start", "Now", function() Inventory:Initialize() end)
    fresh()
    survives("a scan", "CharacterIdentity", function() T.eq("which then counts the bags", (scan())[2589], 5) end)

    -- A read at the close that fails is a read that was not kept: the bank
    -- it was owed for must not go on counting as it was remembered.
    openBank()
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)                                -- read at once: the bank as it was
    Inventory:OnBagUpdate(6)                                -- owed
    breakCall("BankContents")
    local closed, closeError = pcall(function()
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
    end)
    restore()
    T.check("a failing read at the close does not raise", closed, closeError)
    T.check("and leaves the bank it was owed for in doubt", select(3, Memory:OwnBank(MAIN.guid)) == true)
    T.eq("so that a scan counts what is carried and no more", (scan())[2589], 65)
    client.bags = { [2589] = 66 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    local watchLines = {}
    Inventory:RunDiagnostic(watchLines)
    T.check("the watch after the close was still set up",
        table.concat(watchLines, "\n"):find("after the close: bagUpdates=1 compared=1", 1, true) ~= nil, table.concat(watchLines, "\n"))

    -- No pending flag is left set by a failure: everything works afterwards.
    openBank()
    Inventory:OnBagUpdate(6)
    nextFrame()
    Inventory:OnBagUpdate(6)
    breakCall("BankContents")
    advance(1)                                              -- the trailing read fails
    restore()
    client.bank.character = { items = { [2589] = 77 }, slots = 28 }
    Inventory:OnBagUpdate(6)                                -- read at once
    nextFrame()
    client.bank.character = { items = { [2589] = 78 }, slots = 28 }
    Inventory:OnBagUpdate(6)                                -- owed again
    advance(1)
    T.eq("after a failed trailing read the next one is taken", (Memory:OwnBank(MAIN.guid))[2589], 78)
    advance(10)
    local lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("and nothing is left waiting", table.concat(lines, "\n"):find("waiting: bagSave=false bankRead=false", 1, true) ~= nil,
        table.concat(lines, "\n"))
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
        text:find("character: Bank Alt [alt, counted] world=eu-pvp faction=Alliance bags=1 items (1 day ago) bank=never seen", 1, true) ~= nil, text)
    T.check("a character of the other faction", text:find("character: Other Side [other faction] world=eu-pvp faction=Horde", 1, true) ~= nil, text)
    T.check("the world is known: no warning about it", not text:find("world: unknown", 1, true) and not text:find("faction: unknown", 1, true))

    -- The label says what happens to a character's stock, and why.
    local function labels(setup)
        if setup then setup() end
        local out = {}
        Inventory:RunDiagnostic(out)
        local found = {}
        for _, line in ipairs(out) do
            local name, label = line:match("^character: (.-) %[(.-)%]")
            if name then found[name] = label end
        end
        return found, table.concat(out, "\n")
    end
    Memory:SaveBags({ guid = "Player-1-NORMAL", name = "Elsewhere", world = "eu-normal", faction = "Alliance" }, { [1] = 1 }, {}, NOW)
    Memory:SaveBags({ guid = "Player-1-SOLO", name = "Solo", world = "eu-pvp", faction = "Alliance" }, { [1] = 1 }, {}, NOW, false)
    Memory:SaveBags({ guid = "Player-1-OLDME", name = "Main Character", world = "eu-pvp", faction = "Alliance" }, { [1] = 1 }, {}, NOW - 9 * DAY)
    Memory:SaveBags({ guid = "Player-1-OLDALT", name = "Bank Alt", world = "eu-pvp", faction = "Alliance" }, { [1] = 1 }, {}, NOW - 9 * DAY)
    Memory:SaveBags({ guid = "Player-1-NAMELESS", world = "eu-pvp", faction = "Alliance" }, { [1] = 1 }, {}, NOW)
    local found, dump = labels()
    T.check("label: this character", dump:find("character: Main Character [this character] world=eu-pvp", 1, true) ~= nil, dump)
    T.check("label: an older record under this character's name",
        dump:find("character: Main Character [not counted (an older record of this name)]", 1, true) ~= nil, dump)
    T.check("label: an alt that is counted, and an older record under its name",
        dump:find("character: Bank Alt [alt, counted]", 1, true) ~= nil
        and dump:find("character: Bank Alt [not counted (an older record of this name)]", 1, true) ~= nil, dump)
    T.eq("label: another world", found["Elsewhere"], "other world")
    T.eq("label: another faction", found["Other Side"], "other faction")
    T.eq("label: a character that cannot send", found["Solo"], "not counted (Self-Found)")
    T.check("label: a record without a name", dump:find("character: nil [not counted (no name)]", 1, true) ~= nil, dump)

    LazyProf.db.profile.includeAltCharacters = false
    local _, offDump = labels()
    T.check("label: an alt while alts are off", offDump:find("character: Bank Alt [alt, not counted (alts off)]", 1, true) ~= nil, offDump)
    T.check("label: the other reasons stay as they are", offDump:find("character: Other Side [other faction]", 1, true) ~= nil
        and offDump:find("character: Solo [not counted (Self-Found)]", 1, true) ~= nil)
    LazyProf.db.profile.includeAltCharacters = true
    LazyProf.db.char.selfFoundMode = true
    local _, soloDump = labels()
    T.check("label: an alt while this character is Self-Found",
        soloDump:find("character: Bank Alt [not counted (this character is Self-Found)]", 1, true) ~= nil, soloDump)
    LazyProf.db.char.selfFoundMode = false
    -- With "Include bank items" off an alt supplies its bags only: the label says so.
    Memory:SaveBank(ALT, { [2589] = 100 }, {}, NOW - DAY)
    LazyProf.db.profile.includeBankItems = false
    local _, bankOffDump = labels()
    T.check("label: an alt while bank items are off",
        bankOffDump:find("character: Bank Alt [alt, counted (bags only: bank items are off)]", 1, true) ~= nil, bankOffDump)
    LazyProf.db.profile.includeBankItems = true
    local _, bankOnDump = labels()
    T.check("label: with bank items on it is counted whole", bankOnDump:find("character: Bank Alt [alt, counted]", 1, true) ~= nil, bankOnDump)
    -- An alt whose bank is in doubt: its bank part says so.
    Memory:MarkBankDoubt(ALT.guid)
    local _, doubtDump = labels()
    T.check("label: an alt whose bank is in doubt", doubtDump:find(
        "character: Bank Alt [alt, counted] world=eu-pvp faction=Alliance bags=1 items (1 day ago) bank=1 items (1 day ago, in doubt: not counted)",
        1, true) ~= nil, doubtDump)
    LazyProf.db.global.stock.characters[ALT.guid].bank = nil
    -- An account bank in doubt.
    Memory:MarkAccountBankDoubt("eu-pvp")
    local _, accountDump = labels()
    T.check("the account bank in doubt", accountDump:find("account bank: world=eu-pvp items=1 (5 days ago, in doubt: not counted)", 1, true) ~= nil,
        accountDump)
    Memory:SaveAccountBank("eu-pvp", { [2589] = 10 }, NOW - 5 * DAY)

    -- A character whose world or faction cannot be read counts nobody, and the dump says so in words.
    client.identity = { guid = MAIN.guid, name = "Main Character", faction = "Alliance" }
    local _, noWorld = labels()
    T.check("no world: said in words", noWorld:find("world: unknown - alts and the account bank are not counted", 1, true) ~= nil, noWorld)
    T.check("no world: the others are labelled for it",
        noWorld:find("character: Bank Alt [not counted (this character's world or faction is unknown)]", 1, true) ~= nil, noWorld)
    client.identity = { guid = MAIN.guid, name = "Main Character", world = "eu-pvp" }
    local _, noFaction = labels()
    T.check("no faction: said in words", noFaction:find("faction: unknown - alts are not counted", 1, true) ~= nil, noFaction)
    client.identity = MAIN
    for _, guid in ipairs({ "Player-1-NORMAL", "Player-1-SOLO", "Player-1-OLDME", "Player-1-OLDALT", "Player-1-NAMELESS" }) do
        LazyProf.db.global.stock.characters[guid] = nil
    end
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
    -- What is still remembered from before is listed, but nobody of it counts.
    T.check("with Syndicator no remembered character is labelled as counted",
        not text:find("alt, counted", 1, true) and not text:find("[this character]", 1, true), text)
    T.check("each says that the memory is not used",
        text:find("character: Bank Alt [remembered, not used (Syndicator is installed)]", 1, true) ~= nil
        and text:find("character: Main Character [remembered, not used (Syndicator is installed)]", 1, true) ~= nil
        and text:find("character: Other Side [remembered, not used (Syndicator is installed)]", 1, true) ~= nil, text)
    T.check("and no trial of the memory is made", not text:find("scan now:", 1, true), text)
    _G.Syndicator = nil

    -- "waiting" names every read of the bank that is still to come: a look
    -- after the opening, a trailing read, a read that is owed.
    do
        local function waiting()
            local out = {}
            Inventory:RunDiagnostic(out)
            return (table.concat(out, "\n"):match("waiting: [^\n]*"))
        end
        fresh()
        Inventory:Initialize()
        advance(2.1)
        T.eq("nothing waiting", waiting(), "waiting: bagSave=false bankRead=false bankOpen=false")
        client.bankOpen = true
        client.bank.character = { items = { [2589] = 1 } }
        client.bank.account = { items = { [4306] = 1 } }
        client.started.onBankOpened()
        T.eq("after the opening the looks at half a second and at two seconds are waiting", waiting(),
            "waiting: bagSave=false bankRead=true bankOpen=true")
        advance(0.6)
        T.eq("after the first the look at the two-second mark is still waiting", waiting(),
            "waiting: bagSave=false bankRead=true bankOpen=true")
        advance(1.5)
        T.eq("after it nothing is", waiting(), "waiting: bagSave=false bankRead=false bankOpen=true")
        client.bank.account = nil                           -- refused all through the next visit
        client.started.onBankClosing(); client.bankOpen = false; client.started.onBankClosed()
        client.bankOpen = true
        client.started.onBankOpened()
        advance(2.1)
        T.eq("nor after the looks of a second visit", waiting(), "waiting: bagSave=false bankRead=false bankOpen=true")
        Inventory:OnBagUpdate(6)
        nextFrame()
        Inventory:OnBagUpdate(6)
        T.eq("an owed read and its trailing read are waiting", waiting(), "waiting: bagSave=false bankRead=true bankOpen=true")
        advance(0.3)
        T.eq("after it nothing is", waiting(), "waiting: bagSave=false bankRead=false bankOpen=true")
        Inventory:OnBagUpdate(0)
        T.eq("a bag save is named too", waiting(), "waiting: bagSave=true bankRead=false bankOpen=true")
        -- The visit lines say what was read and kept.
        local out = {}
        Inventory:RunDiagnostic(out)
        local visitText = table.concat(out, "\n")
        T.check("the visit: how long it is open, how often it was read",
            visitText:find("bank visit: open for 2.4 s; reads=5 owed=false\n", 1, true) ~= nil, visitText)
        T.check("the visit: what was kept of the character bank",
            visitText:find("bank visit character: usable=true kept=5 lastRead=items slots=28 unresolvedEmpty=false unsettled=false\n", 1, true) ~= nil,
            visitText)
        T.check("the visit: a bank that was refused all along",
            visitText:find("bank visit account: usable=false kept=0 lastRead=refused slots=nil unresolvedEmpty=false unsettled=false\n", 1, true) ~= nil,
            visitText)
        advance(3)
    end

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

    -- Self-Found is stored with the character's stock, so turning it on or
    -- off has the character saved again (its alts read the stored value).
    local selfFound = LazyProf.options.args.general.args.selfFoundMode
    LazyProf.Recalculate = function() end
    -- Its tooltip says what LazyProf does: other characters' stock is never
    -- counted for a Self-Found character; whether its own stock counts for
    -- the others is LazyProf's to decide only where it remembers the stock.
    local selfFoundText = text(selfFound.desc)
    T.check("Self-Found: says that no stock of other characters is counted for it",
        selfFoundText:find("stock of your other characters", 1, true) ~= nil and selfFoundText:find("guild bank", 1, true) ~= nil,
        selfFoundText)
    T.check("Self-Found: does not claim to keep its stock from the others whatever supplies the stock",
        not selfFoundText:find("and its own stock is not counted for them.", 1, true)
        and selfFoundText:find("remembers the stock itself", 1, true) ~= nil, selfFoundText)
    T.check("Self-Found: plain ASCII", not selfFoundText:find("[\128-\255]"))
    Inventory:SaveBags(true)
    T.check("before: the character is remembered as able to send", Memory:Summary().characters[1].canSend == true)
    selfFound.set(nil, true)
    T.check("Self-Found on: the setting is stored", LazyProf.db.char.selfFoundMode == true)
    T.check("Self-Found on: the remembered character can no longer send", Memory:Summary().characters[1].canSend == false)
    Inventory:SaveBags(true)
    T.check("Self-Found on: its next save says the same", Memory:Summary().characters[1].canSend == false)
    selfFound.set(nil, false)
    T.check("Self-Found off: it can send again", Memory:Summary().characters[1].canSend == true)
    installSyndicator()
    selfFound.set(nil, true)
    T.check("with Syndicator the memory is not touched", Memory:Summary().characters[1].canSend == true)
    selfFound.set(nil, false)
    _G.Syndicator = nil

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

    -- A stock setting changed in a frame that already scanned: the planning
    -- that follows must see the new setting, not the frame's earlier scan.
    do
        Memory:SaveBags(ALT, { [2589] = 80 }, {}, NOW)
        local planned
        LazyProf.Client.GetLine = function() return "tailoring", 100, 150 end
        LazyProf.Client.IsOpen = function() return false end
        LazyProf.Pathfinder = { Calculate = function()
            planned = Inventory:ScanAll()
            return nil
        end }
        local display, general = LazyProf.options.args.display.args, LazyProf.options.args.general.args
        nextFrame()
        T.eq("this frame's scan counts the alt", (Inventory:ScanAll())[2589], 85)
        display.includeAltCharacters.set(nil, false)
        T.eq("alts turned off in the same frame: the planning scans again", planned[2589], 5)
        display.includeAltCharacters.set(nil, true)
        T.eq("and on again", planned[2589], 85)
        general.selfFoundMode.set(nil, true)
        T.eq("Self-Found turned on in the same frame", planned[2589], 5)
        general.selfFoundMode.set(nil, false)
        T.eq("and off again", planned[2589], 85)
        Memory:SaveBank(MAIN, { [2589] = 10 }, {}, NOW)
        Inventory:InvalidateCache()
        T.eq("with a remembered bank", (Inventory:ScanAll())[2589], 95)
        display.includeBankItems.set(nil, false)
        T.eq("bank items turned off in the same frame", planned[2589], 85)
        display.includeBankItems.set(nil, true)
        T.eq("and on again", planned[2589], 95)
        installSyndicator()
        nextFrame()
        local _, sources = Inventory:ScanAll()
        T.check("with Syndicator: this frame's scan has no guild bank", sources[2589].guildBank == nil)
        local plannedSources
        LazyProf.Pathfinder.Calculate = function()
            planned, plannedSources = Inventory:ScanAll()
            return nil
        end
        display.includeGuildBank.set(nil, true)
        T.eq("guild bank turned on in the same frame: the planning scans again", plannedSources[2589].guildBank, 500)
        display.includeGuildBank.set(nil, false)
        T.check("and off again", plannedSources[2589].guildBank == nil)
        _G.Syndicator = nil
        nextFrame()
        -- A recalculation never plans from the frame's earlier scan, whatever
        -- made it stale: here the bags, with no setting touched.
        T.eq("this frame's scan", (Inventory:ScanAll())[2589], 95)
        client.bags = { [2589] = 6 }
        LazyProf:Recalculate("test")
        T.eq("a recalculation scans afresh", planned[2589], 96)
        client.bags = { [2589] = 5 }
        LazyProf.Pathfinder = nil
        Memory:Forget()
        Inventory:InvalidateCache()
    end

    -- OnEnable starts the stock memory.
    local events = {}
    LazyProf.RegisterEvent = function(_, event, handler) events[event] = handler end
    LazyProf.Client.Start = function() end
    client.started = nil
    LazyProf:OnEnable()
    T.check("OnEnable starts the stock events", type(client.started) == "table")
    T.check("BAG_UPDATE keeps its one handler in Init", events.BAG_UPDATE == "OnBagUpdate")
    -- The notice that a batch of bag updates is complete has its one handler
    -- there too, on the client whose bank is read.
    T.check("the batch notice is registered in Init on WoW Forever", events.BAG_UPDATE_DELAYED == "OnBagUpdateDelayed"
        and type(LazyProf.OnBagUpdateDelayed) == "function", tostring(events.BAG_UPDATE_DELAYED))
    local notices = 0
    local realDelayed = Inventory.OnBagUpdateDelayed
    Inventory.OnBagUpdateDelayed = function(self)
        notices = notices + 1
        return realDelayed(self)
    end
    LazyProf:OnBagUpdateDelayed("BAG_UPDATE_DELAYED")
    T.eq("and passed on to the scanner", notices, 1)
    Inventory.OnBagUpdateDelayed = realDelayed
    do
        local classicEvents = {}
        LazyProf.RegisterEvent = function(_, event, handler) classicEvents[event] = handler end
        LazyProf.ClientFamily = "classic"
        LazyProf:OnEnable()
        LazyProf.ClientFamily = "forever"
        LazyProf.RegisterEvent = function(_, event, handler) events[event] = handler end
        T.check("on the other clients it is not asked for (the bank is not read there)",
            classicEvents.BAG_UPDATE == "OnBagUpdate" and classicEvents.BAG_UPDATE_DELAYED == nil)
    end
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
