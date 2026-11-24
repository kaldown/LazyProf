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
--   - a Self-Found character - by the addon's setting or by the game's own
--     flag - gets no stock from other characters and offers them none
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

local MAIN = { guid = "Player-1-MAIN", name = "Main Character", world = "eu-pvp", faction = "Alliance", region = "eu" }
local ALT = { guid = "Player-1-ALT", name = "Bank Alt", world = "eu-pvp", faction = "Alliance", region = "eu" }
local FARMER = { guid = "Player-1-FARM", name = "Farmer", world = "eu-pvp", faction = "Alliance", region = "eu" }
local HORDE = { guid = "Player-1-HORDE", name = "Other Side", world = "eu-pvp", faction = "Horde", region = "eu" }

-- The client adapter as the scanner sees it; every read is counted.
local client
local function resetClient()
    client = {
        identity = MAIN, now = NOW, bankOpen = false,
        readsBank = true,                            -- the adapter reads the bank at all (false: a Classic client)
        gameSelfFound = false,                       -- what the game's own Self-Found flag reads
        inFlight = false,                            -- a slot reads as locked: a move is on its way (true / false / "fail")
        clientCounts = nil,                          -- function(itemId): the client's own three counts; nil = this client has none
        bags = { [2589] = 5 }, bagsBound = {}, backpackSlots = 16,
        bagsLocked = {},                             -- the part of the bags in slots that read as locked
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
        return client.bags, client.bagsBound, client.backpackSlots, client.bagsLocked
    end,
    ReadsBank = function() return client.readsBank end,
    IsBankOpen = function() return client.bankOpen end,
    BankContents = function(_, kind)
        client.reads[kind] = client.reads[kind] + 1
        local contents = client.bankOpen and client.bank[kind] or nil
        if not contents then return nil end
        return contents.items, contents.bound or {}, contents.slots or 28, contents.locked or {}
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
    IsSelfFoundCharacter = function() return client.gameSelfFound end,
    -- Like the adapters: nil on a client without such a count; without an
    -- item, zeros and nothing asked.
    -- Like the adapter: whether a slot reads as locked, and the banks it
    -- could look at (those that can be read now) with how many items each
    -- shows.
    MoveInFlight = function()
        if client.inFlight == "fail" then error("locks unreadable") end
        local looked = {}
        for _, kind in ipairs({ "character", "account" }) do
            local contents = client.bankOpen and client.bank[kind]
            if contents then
                local n = 0
                for _ in pairs(contents.items) do n = n + 1 end
                looked[kind] = n
            end
        end
        return client.inFlight, looked
    end,
    ClientItemCounts = function(_, itemId)
        if not client.clientCounts then return nil end
        if itemId == nil then return 0, 0, 0 end
        return client.clientCounts(itemId)
    end,
    Now = function() return client.now end,
    StartStock = function(_, callbacks) client.started = callbacks end,
    RunStockDiagnostic = function(_, lines) lines[#lines + 1] = "adapter: stock lines" end,
}

local refreshes = 0
LazyProf.ScheduleShoppingListRefresh = function() refreshes = refreshes + 1 end

local function fresh(profile)
    -- Let what the section before left waiting run out (a save asked for and
    -- never run would keep its "waiting" flag for the rest of the suite),
    -- on a client that can tell the character apart (a save waits for that).
    client.identity = MAIN
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
    Memory:SaveAccountBank(MAIN, { [2589] = 10, [4306] = 3 }, NOW - 5 * DAY)
    Memory:SaveAccountBank({ guid = "Player-2-US", world = "us-normal", faction = "Alliance", region = "us" }, { [2589] = 9000 }, NOW)
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
    T.eq("the account bank of this region only", breakdown[4306].bank, 3)

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
    Memory:SaveAccountBank(MAIN, { [2589] = 10, [4306] = 3 }, NOW - 5 * DAY)
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

    Memory:MarkAccountBankDoubt("eu")
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
    -- And the scan names the alt, so that the list can say whose bank is
    -- missing from it.
    T.check("the scan names the alt whose bank is left out", type(meta.altBanksInDoubt) == "table"
        and #meta.altBanksInDoubt == 1 and meta.altBanksInDoubt[1] == "Bank Alt", meta.altBanksInDoubt and meta.altBanksInDoubt[1])
    local EXTRA = { guid = "Player-1-EXTRA", name = "Carl Extra", world = "eu-pvp", faction = "Alliance" }
    Memory:SaveBags(EXTRA, { [765] = 1 }, {}, NOW - DAY)
    Memory:SaveBank(EXTRA, { [2589] = 7 }, {}, NOW - DAY)
    Memory:MarkBankDoubt(EXTRA.guid)
    Memory:SaveBank(HORDE, { [2589] = 7 }, {}, NOW - DAY)
    Memory:MarkBankDoubt(HORDE.guid)
    Inventory:ForgetAltsPart()
    combined, breakdown, meta = scan()
    T.check("several: by name, and only characters that count as alts", #meta.altBanksInDoubt == 2
        and meta.altBanksInDoubt[1] == "Bank Alt" and meta.altBanksInDoubt[2] == "Carl Extra", table.concat(meta.altBanksInDoubt, ","))
    LazyProf.db.profile.includeBankItems = false
    combined, breakdown, meta = scan()
    T.check("bank items off: no alt's bank would count, none is named", meta.altBanksInDoubt == nil)
    LazyProf.db.profile.includeBankItems = true
    LazyProf.db.profile.includeAltCharacters = false
    combined, breakdown, meta = scan()
    T.check("alts off: none is named", meta.altBanksInDoubt == nil)
    LazyProf.db.profile.includeAltCharacters = true
    LazyProf.db.char.selfFoundMode = true
    combined, breakdown, meta = scan()
    T.check("Self-Found: none is named", meta.altBanksInDoubt == nil)
    LazyProf.db.char.selfFoundMode = false
    -- Back to the one alt with a bank in doubt.
    LazyProf.db.global.stock.characters[EXTRA.guid] = nil
    LazyProf.db.global.stock.characters[HORDE.guid].bank = nil
    Inventory:ForgetAltsPart()
    combined, breakdown, meta = scan()
    T.check("one again", #meta.altBanksInDoubt == 1 and meta.altBanksInDoubt[1] == "Bank Alt")

    -- The next save of a bank takes its mark away.
    Memory:SaveBank(MAIN, { [2589] = 41 }, {}, NOW)
    Memory:SaveAccountBank(MAIN, { [2589] = 11 }, NOW)
    combined, breakdown, meta = scan()
    T.eq("saved again: both count", combined[2589], 5 + 41 + 11 + 20)
    T.check("and nothing is in doubt", meta.bankInDoubt == nil and meta.accountInDoubt == nil and meta.bankSeenAt == NOW)

    -- A mark that is not what the memory writes (a damaged saved table) is
    -- taken for a mark: such a bank is not counted either.
    LazyProf.db.global.stock.characters[MAIN.guid].bank.doubt = "yes"
    LazyProf.db.global.stock.account.eu.doubt = 1
    combined, breakdown, meta = scan()
    T.eq("a damaged doubt mark: neither bank is counted", combined[2589], 5 + 20)
    T.check("and the scan says that both are in doubt", meta.bankInDoubt == true and meta.accountInDoubt == true)
end)

-- ===========================================================================
-- The account bank is remembered once per region and counts only for the
-- characters of the world and faction whose read it is: whether the game
-- shares it across worlds or factions is not known, and wherever a copy may
-- be another bank it is not counted. A read elsewhere makes the copy that
-- character's.
T.section("no inventory addon: the account bank counts only where it was read", function()
    fresh()
    local NORMAL = { guid = "Player-1-NORMAL", name = "Elsewhere", world = "eu-normal", faction = "Alliance", region = "eu" }
    local US = { guid = "Player-2-US", name = "Far Away", world = "us-pvp", faction = "Alliance", region = "us" }
    Memory:SaveAccountBank(MAIN, { [4306] = 10 }, NOW - DAY)
    local combined, _, meta = scan()
    T.check("read by this world and faction: counted", combined[4306] == 10 and meta.accountSeenAt == NOW - DAY)
    T.check("read here: nothing said of it being read elsewhere", meta.accountElsewhere == nil)
    -- The other faction or another world of the region: not counted, and the
    -- scan says why - it was read elsewhere, which is no doubt about it.
    for _, other in ipairs({ HORDE, NORMAL }) do
        client.identity = other
        combined, _, meta = scan()
        T.check(other.name .. ": not counted, and the scan says it was read elsewhere", combined[4306] == nil
            and meta.accountSeenAt == nil and meta.accountInDoubt == nil and meta.accountPending == nil
            and meta.accountElsewhere == true)
    end
    -- Only where bank items count for the character at all.
    client.identity = HORDE
    LazyProf.db.profile.includeBankItems = false
    T.check("bank items off: nothing said", select(3, scan()).accountElsewhere == nil)
    LazyProf.db.profile.includeBankItems = true
    LazyProf.db.char.selfFoundMode = true
    T.check("Self-Found: nothing said (the account bank is no stock of its own)", select(3, scan()).accountElsewhere == nil)
    LazyProf.db.char.selfFoundMode = false
    client.gameSelfFound = true
    T.check("the game's Self-Found flag: the same", select(3, scan()).accountElsewhere == nil)
    client.gameSelfFound = false
    client.identity = { guid = HORDE.guid, name = HORDE.name, faction = "Horde", region = "eu" }
    T.check("the character's world unknown: not said (the bank is not counted for that reason)",
        select(3, scan()).accountElsewhere == nil)
    -- Another region has a copy of its own (none here): nothing to say.
    client.identity = US
    combined, _, meta = scan()
    T.check(US.name .. ": not counted, and nothing is said of it", combined[4306] == nil and meta.accountSeenAt == nil
        and meta.accountInDoubt == nil and meta.accountPending == nil and meta.accountElsewhere == nil)
    -- In doubt: said only where it would count.
    Memory:MarkAccountBankDoubt("eu")
    client.identity = HORDE
    combined, _, meta = scan()
    T.check("in doubt, read by the other faction: not counted, said to be read elsewhere, not in doubt here",
        combined[4306] == nil and meta.accountInDoubt == nil and meta.accountElsewhere == true)
    client.identity = MAIN
    combined, _, meta = scan()
    T.check("in doubt, read here: not counted and named", combined[4306] == nil and meta.accountInDoubt == true
        and meta.accountElsewhere == nil)
    -- A copy read elsewhere without a single item: nothing it holds is left out.
    local saved = LazyProf.db.global.stock.account.eu
    LazyProf.db.global.stock.account.eu = { items = {}, at = NOW, world = "eu-pvp", faction = "Horde" }
    T.check("an empty copy read elsewhere: nothing said", select(3, scan()).accountElsewhere == nil)
    LazyProf.db.global.stock.account.eu = saved

    -- The other faction reads it: the copy is its own from then on.
    client.identity = HORDE
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    client.bank.account = { items = { [4306] = 3 }, slots = 98 }
    client.started.onBankOpened()
    advance(3)
    client.started.onBankClosing(); client.bankOpen = false; client.started.onBankClosed()
    advance(11)
    local items, _, doubt, world, faction = Memory:AccountBank("eu")
    T.check("a read by the other faction makes the copy its own, without the mark", items[4306] == 3 and doubt == false
        and world == "eu-pvp" and faction == "Horde")
    T.eq("and counts for it", (scan())[4306], 3)
    client.identity = MAIN
    combined, _, meta = scan()
    T.check("and no longer for this faction", combined[4306] == nil and meta.accountSeenAt == nil and meta.accountInDoubt == nil
        and meta.accountElsewhere == true)
    local lines = {}
    Inventory:RunDiagnostic(lines)
    local text = table.concat(lines, "\n")
    T.check("the dump says whose read it is and that it does not count here", text:find(
        "account bank: region=eu read by world=eu-pvp faction=Horde items=1 (less than an hour ago) - not counted (read in another world or by the other faction)",
        1, true) ~= nil, text)
    Memory:SaveAccountBank(US, { [1] = 1 }, NOW)
    lines = {}
    Inventory:RunDiagnostic(lines)
    text = table.concat(lines, "\n")
    T.check("and of another region's that it is that region's", text:find(
        "account bank: region=us read by world=us-pvp faction=Alliance items=1 (less than an hour ago) - not counted (another region)",
        1, true) ~= nil, text)

    -- A mark follows the copy of the region, whoever's read it is: a bank
    -- container update of this character after its close may be about the
    -- very bank the other faction's read saw.
    fresh()
    Memory:SaveBags(HORDE, { [1] = 1 }, {}, NOW)
    Memory:SaveAccountBank(HORDE, { [4306] = 3 }, NOW)
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    client.usable.account = true                     -- usable, but its reads are refused
    client.started.onBankOpened()
    advance(3)
    Inventory:OnBagUpdate(15)                        -- the account bank's own update: unsettled, never read back
    advance(1)
    client.started.onBankClosing(); client.bankOpen = false; client.started.onBankClosed()
    T.check("the close marks the copy of the region, read by the other faction", select(3, Memory:AccountBank("eu")) == true)
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
    Memory:SaveAccountBank(MAIN, { [2589] = 10 }, NOW)
    combined, breakdown, meta = scan()
    T.eq("no world: the own bank still counts, no alts, no account bank", combined[2589], 5 + 40)
    T.check("no world: no alt named", breakdown[2589].alts == nil and meta.accountSeenAt == nil)
end)

-- ===========================================================================
T.section("Self-Found: nothing from other characters", function()
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - DAY)
    Memory:SaveAccountBank(MAIN, { [2589] = 10 }, NOW)
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

    -- The game's own flag does the same with the setting off.
    client.gameSelfFound = true
    combined, breakdown, meta = scan()
    T.eq("the game's flag: bags and the character's own bank", combined[2589], 5 + 40)
    T.check("the game's flag: no alt stock, no account bank", breakdown[2589].alts == nil and next(meta.alts) == nil
        and meta.accountSeenAt == nil and breakdown[2589].bank == 40)
    -- Every save of its stock says that it cannot send.
    Inventory:SaveBags(true)
    T.check("the game's flag: its bags are saved as not to be sent",
        LazyProf.db.global.stock.characters[MAIN.guid].noSend == true)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 41 } }
    Inventory:Initialize()
    client.started.onBankOpened()
    T.check("the game's flag: so is its bank", (Memory:OwnBank(MAIN.guid))[2589] == 41
        and LazyProf.db.global.stock.characters[MAIN.guid].noSend == true)
    client.started.onBankClosing(); client.bankOpen = false; client.started.onBankClosed()
    advance(11)
    -- The adapter answers true or false; anything else is not the flag.
    for _, value in ipairs({ 1, "yes" }) do
        client.gameSelfFound = value
        T.eq("a flag that is not true is none (" .. type(value) .. ")", (scan())[2589], 5 + 41 + 10 + 20 + 100)
    end
    client.gameSelfFound = false
    Inventory:SaveBags(true)
    T.check("the flag off: its next save says that it can send", LazyProf.db.global.stock.characters[MAIN.guid].noSend == nil)
    T.eq("the flag off: everything counts again", (scan())[2589], 5 + 41 + 10 + 20 + 100)
    -- Either of the two is enough; the planner's mode stays the setting alone.
    LazyProf.db.char.selfFoundMode = true
    client.gameSelfFound = true
    T.eq("setting and flag both: as with one of them", (scan())[2589], 5 + 41)
    LazyProf.db.char.selfFoundMode = false
    client.gameSelfFound = false
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
    Memory:SaveAccountBank(MAIN, { [2589] = 9999 }, NOW)
    installSyndicator()

    -- Any use of the memory or of the bank reader fails this section. The
    -- memory's entry points run protected, so a use would not raise: each
    -- one is written down as well. Every function of the memory counts.
    local used = {}
    local saved = {}
    for name, fn in pairs(Memory) do
        if type(fn) == "function" then
            saved[name] = fn
            Memory[name] = function()
                used[#used + 1] = "StockMemory:" .. name
                error("StockMemory:" .. name .. " used although Syndicator is installed")
            end
        end
    end
    local savedContents, savedUsable = LazyProf.Client.BankContents, LazyProf.Client.BankUsable
    LazyProf.Client.BankContents = function()
        used[#used + 1] = "Client:BankContents"
        error("the bank is read although Syndicator is installed")
    end
    LazyProf.Client.BankUsable = function()
        used[#used + 1] = "Client:BankUsable"
        error("the bank is asked for although Syndicator is installed")
    end
    client.bankOpen = true
    -- What the dump says of the bank visit and of what is waiting: none of
    -- it may change either. With Syndicator installed the dump says only that
    -- the bank is not followed, so it is asked here as without it.
    local function visitState()
        local out, kept = {}, {}
        -- The dump goes on to list what is remembered, which the stand-ins
        -- above refuse: the lines wanted here come before that, and what the
        -- dump itself asked of the memory is not held against the scanner.
        local usedBefore = #used
        local syndicator = _G.Syndicator
        _G.Syndicator = nil
        pcall(Inventory.RunDiagnostic, Inventory, out)
        _G.Syndicator = syndicator
        for i = #used, usedBefore + 1, -1 do used[i] = nil end
        for _, line in ipairs(out) do
            if line:find("^bank visit") or line:find("^after the close") or line:find("^waiting:") then
                kept[#kept + 1] = line
            end
        end
        return table.concat(kept, "\n")
    end

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
        used = {}
        local stateBefore, bagReadsBefore = visitState(), client.reads.bags
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
        Inventory:OnLogout()
        Inventory:RequestBagSave(true)
        Inventory:OnSendingChanged()
        Inventory:OnSettingsReset()
        T.eq("no timer is asked for", #timers, 0)
        T.eq("nothing of the bank visit changes and nothing is left waiting", visitState(), stateBefore)
        advance(5)
        T.eq("no save, no bank read, no prune: neither the memory nor the bank is touched", table.concat(used, ", "), "")
        T.eq("and the bags are not read for it", client.reads.bags, bagReadsBefore)
        T.check("a save asked for directly does nothing either", Inventory:SaveBags(true) == false and #used == 0,
            table.concat(used, ", "))

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
        -- The game's own flag, with the setting off: the same.
        client.gameSelfFound = true
        combined, breakdown = Inventory:ScanAll()
        T.check("the game's Self-Found flag: no alt stock and no guild bank from Syndicator",
            combined[2589] == 5 + 30 + 4 and breakdown[2589].alts == nil and breakdown[2589].guildBank == nil, combined[2589])
        client.gameSelfFound = false
        LazyProf.db.profile.includeGuildBank = false
    end)
    for name, fn in pairs(saved) do Memory[name] = fn end
    LazyProf.Client.BankContents, LazyProf.Client.BankUsable = savedContents, savedUsable
    T.check("no use of the memory with Syndicator installed", ok, err)
    -- (The memory's entry points run protected: a call that was made and
    -- failed above would not have raised. It would have been counted.)
    local lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("and none that failed quietly", not table.concat(lines, "\n"):find("last error", 1, true), table.concat(lines, "\n"))

    -- The start-up cleaning writes nothing either: a character that would be
    -- dropped stays, with the account bank of its region.
    local OLD = { guid = "Player-1-OLD", name = "Old Alt", world = "us-normal", faction = "Alliance", region = "us" }
    Memory:SaveBags(OLD, { [1] = 1 }, {}, NOW - 400 * DAY)
    Memory:SaveAccountBank(OLD, { [1] = 1 }, NOW - 400 * DAY)
    Inventory:Initialize()
    T.check("start with Syndicator: nothing is dropped from the memory",
        LazyProf.db.global.stock.characters["Player-1-OLD"] ~= nil and Memory:AccountBank("us") ~= nil)
    -- Forgetting is the memory's too: with Syndicator installed it forgets
    -- nothing, reads no bank and asks for no save.
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 1 } }
    client.reads.character, client.reads.account = 0, 0
    timers = {}
    Inventory:ForgetRemembered()
    T.check("Forget with Syndicator: what is remembered stays", (Memory:OwnBank(MAIN.guid))[2589] == 7777
        and Memory:AccountBank("eu") ~= nil and LazyProf.db.global.stock.characters[ALT.guid] ~= nil)
    T.check("Forget with Syndicator: the open bank is not read and no save is asked for",
        client.reads.character == 0 and client.reads.account == 0 and #timers == 0, client.reads.character)
    client.bankOpen = false
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
    -- The game's own Self-Found flag is asked at every scan: a scan made
    -- under the other answer does not serve.
    client.gameSelfFound = true
    T.eq("the game's Self-Found flag reads true in the same frame, nothing else", (Inventory:ScanAll())[2589], 45)
    client.gameSelfFound = false
    T.eq("and false again", (Inventory:ScanAll())[2589], 65)
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
    -- The name is part of who the character is: an older record under its
    -- own name is no alt, and without the name that cannot be told. What was
    -- worked out while the name could not be read must not be kept.
    fresh()
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    Memory:SaveBags({ guid = "Player-1-OLDMAIN", name = MAIN.name, world = "eu-pvp", faction = "Alliance" }, { [2589] = 300 }, {},
        NOW - 9 * DAY)
    client.identity = { guid = MAIN.guid, world = "eu-pvp", faction = "Alliance" }     -- everything but the name
    nextFrame()
    T.eq("(fixture: without the name the older record of it cannot be told from an alt)", (Inventory:ScanAll())[2589], 325)
    client.identity = MAIN
    nextFrame()
    T.eq("the name is known a moment later: the older record of the character's own name is no alt", (Inventory:ScanAll())[2589], 25)
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

    -- A slot whose move is on its way is not saved: until its answer it
    -- shows what it held before the click, and that may be on its way into
    -- another slot already reported (a split, half answered) - it would be
    -- offered to the other characters twice.
    fresh()
    Inventory:Initialize()
    client.bags = { [2589] = 27, [2592] = 3 }
    client.bagsBound = { [2592] = 3 }
    client.bagsLocked = { [2589] = 16, [2592] = 3 }
    Inventory:OnBagUpdate(0)
    advance(2.1)
    local saved = LazyProf.db.global.stock.characters[MAIN.guid].bags
    T.check("a save leaves out what is in locked slots", saved.items[2589] == 11 and saved.items[2592] == nil and saved.bound == nil,
        tostring(saved.items[2589]))
    client.bagsLocked = {}
    Inventory:OnBagUpdate(0)
    advance(2.1)
    saved = LazyProf.db.global.stock.characters[MAIN.guid].bags
    T.check("(and the next one, with nothing locked, saves all)", saved.items[2589] == 27 and saved.items[2592] == 3)
    -- Ten soulbound and five others of one item, the five locked: what is
    -- left is all soulbound for all the save can tell - nothing of it offered.
    client.bags = { [2592] = 15 }
    client.bagsBound = { [2592] = 10 }
    client.bagsLocked = { [2592] = 5 }
    Inventory:OnBagUpdate(0)
    advance(2.1)
    saved = LazyProf.db.global.stock.characters[MAIN.guid].bags
    T.check("locked slots of an item partly soulbound: the rest is kept soulbound", saved.items[2592] == 10 and saved.bound[2592] == 10)
    client.bagsLocked = {}

    -- The character's id cannot be read when the first save is due: it is
    -- tried again every two seconds until it can be, and then no more.
    fresh()
    client.identity = { name = MAIN.name, world = MAIN.world, faction = MAIN.faction, region = MAIN.region }
    Inventory:Initialize()
    advance(2.1)
    T.check("no id: nothing saved, and the save waits again", Memory:Summary().characters[1] == nil and #timers == 1, #timers)
    advance(4)
    T.check("still no id: still waiting, one timer", Memory:Summary().characters[1] == nil and #timers == 1, #timers)
    client.identity = MAIN
    advance(2.1)
    T.check("the id readable: saved", Memory:Summary().characters[1] ~= nil and Memory:Summary().characters[1].guid == MAIN.guid)
    T.eq("and nothing waits any more", #timers, 0)

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
    local account, accountAt = Memory:AccountBank("eu")
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
    T.check("unreadable: the account bank is kept", (Memory:AccountBank("eu"))[4306] == 9)
    T.eq("a look that changed nothing asks for no redraw", refreshes, 0)

    -- One bank readable, the other not: each is judged alone.
    client.bank.account = { items = { [4306] = 1 } }
    Inventory:OnBagUpdate(15)
    advance(1)
    T.check("only the account bank readable: it is saved, the character bank kept",
        (Memory:AccountBank("eu"))[4306] == 1 and (bankOf())[2589] == 61)
    -- While a bank of the visit was refused at its last read it is read
    -- again every half second; readable again, it is read and kept.
    client.bank.character = { items = { [2589] = 61 } }
    local readsBefore = client.reads.character
    advance(0.6)
    T.check("the refused bank is read again by itself and kept", client.reads.character > readsBefore and (bankOf())[2589] == 61
        and select(3, scan()).bankPending == nil, client.reads.character - readsBefore)
    readsBefore = client.reads.character
    advance(2)
    T.eq("and once nothing wants another look, nothing reads it", client.reads.character, readsBefore)

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

    -- A bank of which no item is remembered reads as empty right after an
    -- update of its own container: that is believed on the second look
    -- only, like any emptied bank. (A deposit may just have gone in, and the
    -- client may be letting go of the bank before it reports the close.)
    fresh()
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    client.bank.character = { items = {}, slots = 28 }
    client.started.onBankOpened()
    advance(3)
    T.check("fixture: the bank is remembered as seen, with nothing in it", bankOf() ~= nil and next((bankOf())) == nil)
    client.now = NOW + 30
    Inventory:OnBagUpdate(6)                              -- read at once: empty again
    local _, keptAt = bankOf()
    T.check("empty after its own update, nothing remembered in it: one read is not kept", keptAt == NOW, keptAt)
    local unsettledLines = {}
    Inventory:RunDiagnostic(unsettledLines)
    T.check("the bank stays unsettled", table.concat(unsettledLines, "\n"):find(
        "lastRead=empty, not believed slots=28 unresolvedEmpty=true unsettled=true", 1, true) ~= nil, table.concat(unsettledLines, "\n"))
    advance(0.25)
    _, keptAt = bankOf()
    T.check("the second look 0.2 s later is kept, and settles it", keptAt == NOW + 30, keptAt)
    -- Closed before that second look: in doubt, as any bank whose update no
    -- kept read followed.
    Inventory:OnBagUpdate(6)
    client.started.onBankClosing()
    client.bankOpen = false
    client.started.onBankClosed()
    T.check("closed before the second look: in doubt", select(3, Memory:OwnBank(MAIN.guid)) == true)

    -- An empty read is a second look only when the first one came after the
    -- bank's last own update. The bank is emptied (one empty read, not
    -- believed), a stack is put back in before the second look, and then
    -- the client lets go of the bank: that empty read is the first since
    -- the deposit, and the one from before it is no second opinion.
    fresh()
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 6 }, slots = 28 }
    client.started.onBankOpened()
    advance(3)
    client.bank.character = { items = {}, slots = 28 }
    Inventory:OnBagUpdate(6)                              -- read at once: empty, not believed
    advance(0.19)
    client.bank.character = { items = { [2589] = 1 }, slots = 28 }
    Inventory:OnBagUpdate(6)                              -- a deposit, before the second look: the read is owed
    advance(0.0099)                                       -- 0.2 s after the last read, ahead of the trailing read
    client.bank.character = { items = {}, slots = 28 }    -- the client lets go
    Inventory:OnBagUpdate(6)                              -- read at once: empty again
    T.check("an empty read after a deposit is not believed on the strength of an empty read from before it",
        (bankOf())[2589] == 6, (bankOf())[2589])
    client.started.onBankClosing()
    client.bankOpen = false
    client.started.onBankClosed()
    T.check("closed then: what is remembered stays, in doubt", (bankOf())[2589] == 6 and select(3, Memory:OwnBank(MAIN.guid)) == true)
    -- Left alone, the second look after the update still settles it.
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 6 }, slots = 28 }
    client.started.onBankOpened()
    advance(3)
    client.bank.character = { items = {}, slots = 28 }
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(6)                              -- a second update of the same move: the read is owed
    advance(0.25)
    T.check("two updates of one move: the first empty read after them is not believed yet", (bankOf())[2589] == 6)
    advance(0.2)
    T.check("the look after it is", next((bankOf())) == nil)

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
    advance(0.6)                                           -- read again every half second while unsettled: kept
    combined, _, meta = scan()
    T.check("a kept read settles it", combined[2589] == 95 and meta.bankPending == nil, combined[2589])

    -- A bank whose last read was refused is left out too while the window
    -- is open: the read taken for a carried bag's update (the bag's part of
    -- a withdrawal, the bank's part still to come) could not see it, so
    -- what is remembered of it may be counted beside what just came out.
    visit()
    client.bags = { [2589] = 65 }
    client.bank.character = nil                            -- locked for a moment
    Inventory:OnBagUpdate(0)                               -- read at once: refused
    combined, _, meta = scan()
    T.check("refused at its last read: left out, as being read; the other counts", combined[2589] == 65
        and combined[4306] == 9 and meta.bankPending == true and meta.accountPending == nil, combined[2589])
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    advance(0.6)                                           -- readable again: the next repeated read
    combined, _, meta = scan()
    T.check("read again once it can be: counted, not left out", combined[2589] == 105 and meta.bankPending == nil, combined[2589])

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
    Memory:SaveAccountBank(MAIN, { [4306] = 9 }, NOW - DAY)
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
        return during, (scan())[2589], inDoubt(), select(3, Memory:AccountBank("eu"))
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

    -- A bank whose last read found it empty without being believed, and of
    -- which items are remembered: the evidence that it was emptied must not
    -- be thrown away, nor may what is remembered count again after the
    -- close - it is marked in doubt at the close.
    local function closeLine()
        local lines = {}
        Inventory:RunDiagnostic(lines)
        return (("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(bank visit close: [^\n]*)\n"))
    end
    visit()
    client.bags = { [2589] = 105 }                         -- the bank's last stack is taken out: both containers changed
    client.bank.character = { items = {}, slots = 28 }
    Inventory:OnBagUpdate(0)                               -- read at once: the bank empty, not believed
    refreshes = 0
    close()                                                -- nothing owed, the bank not unsettled
    T.check("an empty read not believed, items remembered: in doubt at the close", inDoubt() == true)
    T.eq("the dump says so", closeLine(),
        "bank visit close: owed=false unsettled=none readAgain=false kept=none markedInDoubt=character held=none moveInFlight=false unreadable=character")
    local combined, _, meta = scan()
    T.check("the stack is counted once, the bank is named", combined[2589] == 105 and meta.bankInDoubt == true
        and combined[4306] == 9 and meta.accountPending == nil, combined[2589])
    T.check("a shown list is asked to redraw", refreshes >= 1, refreshes)
    advance(1.5)
    combined, _, meta = scan()
    T.check("and it stays in doubt after the second: it is not counted again", combined[2589] == 105 and meta.bankInDoubt == true
        and meta.bankPending == nil, combined[2589])
    -- A glance at a bank emptied by a hand the memory never saw: two empty
    -- reads half a second apart, not believed before two seconds.
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 100 }, {}, NOW - DAY)
    Memory:SaveBags(MAIN, { [2589] = 5 }, {}, NOW - DAY)
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    client.bank.character = { items = {}, slots = 28 }
    client.started.onBankOpened()
    advance(1.5)
    close()
    T.check("a glance of 1.5 s at a bank found empty: in doubt", inDoubt() == true)
    advance(1.5)
    combined, _, meta = scan()
    T.check("and not counted again after the close", combined[2589] == 5 and meta.bankInDoubt == true, combined[2589])
    -- The held second stays for a read that was owed and not made up for at the close.
    visit()
    client.bags = { [2589] = 65 }
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    Inventory:OnBagUpdate(1)                               -- read at once: 40
    client.bags = { [2589] = 105 }
    client.bank.character = { items = {}, slots = 28 }
    Inventory:OnBagUpdate(0)                               -- owed
    client.bank.character = nil
    client.bank.account = nil                              -- refused at the close
    close()
    T.eq("a read owed at the close and refused: both banks are held, neither marked", closeLine(),
        "bank visit close: owed=true unsettled=none readAgain=true kept=none markedInDoubt=none held=character,account moveInFlight=false unreadable=character,account")
    combined, _, meta = scan()
    T.check("neither is counted for that second", combined[2589] == 105 and combined[4306] == nil and meta.bankPending == true
        and meta.accountPending == true, combined[2589])
    advance(0.05)
    Inventory:OnBagUpdate(6)
    advance(1)
    combined, _, meta = scan()
    T.check("the bank whose update came is in doubt, the other counts again", meta.bankInDoubt == true and meta.accountInDoubt == nil
        and combined[4306] == 9 and combined[2589] == 105, combined[2589])
    -- No update of the bank follows: after the second it counts again.
    visit()
    Inventory:OnBagUpdate(1)                               -- read at once
    Inventory:OnBagUpdate(0)                               -- owed
    client.bank.character = nil
    close()
    refreshes = 0
    advance(0.9)
    T.check("0.9 s after the close it is still left out", (scan())[2589] == 5 and select(3, scan()).bankPending == true)
    advance(0.098)
    T.check("and 0.998 s after it", (scan())[2589] == 5 and select(3, scan()).bankPending == true)
    advance(0.2)
    combined, _, meta = scan()
    T.check("no update of the bank within the second: it counts again, unmarked", combined[2589] == 105 and meta.bankPending == nil
        and inDoubt() == false, combined[2589])
    T.check("and a shown list was asked to redraw when that second was over", refreshes >= 1, refreshes)
    -- A bank the closing read was kept for is not held.
    visit()
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(0)                               -- owed
    close()
    T.eq("kept at the close: not held", closeLine(),
        "bank visit close: owed=true unsettled=none readAgain=true kept=character,account markedInDoubt=none held=none moveInFlight=false")
    -- The session ends inside that second: the update may never be heard,
    -- so the bank is marked.
    visit()
    Inventory:OnBagUpdate(1)
    Inventory:OnBagUpdate(0)                               -- owed
    client.bank.character = nil
    close()
    advance(0.5)
    client.started.onLogout()
    T.check("a logout while a bank is held marks it", inDoubt() == true and select(3, Memory:AccountBank("eu")) == false)
    local heldLines = {}
    Inventory:RunDiagnostic(heldLines)
    T.check("the dump says why", table.concat(heldLines, "\n"):find(
        "compared=0 marked=character (not read back before the session ended)", 1, true) ~= nil, table.concat(heldLines, "\n"))
    visit()
    client.bags = { [2589] = 105 }
    client.bank.character = { items = {}, slots = 28 }
    Inventory:OnBagUpdate(0)
    client.started.onLogout()                              -- with the bank open
    T.check("an empty read at a logout with the bank open: in doubt", inDoubt() == true)
    visit()
    Inventory:OnBagUpdate(1)
    Inventory:OnBagUpdate(0)
    client.bank.character = nil
    close()
    advance(1.5)
    client.started.onLogout()
    T.check("a logout after that second does not", inDoubt() == false)

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
        return inDoubt(), select(3, Memory:AccountBank("eu"))
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
    T.eq("nor is a bank held of which no item is remembered", closeLine(),
        "bank visit close: owed=true unsettled=none readAgain=true kept=account markedInDoubt=none held=none moveInFlight=false")
    client.started.onLogout()
    T.check("so a logout right after such a visit marks nothing", inDoubt() == false)
    -- A stack put into it and taken out again: its last read found it empty,
    -- and no update of its own came after that read - what is remembered
    -- (empty) agrees with what was read, so nothing is marked.
    local function inAndOut(closeAfter, lateUpdate)
        return emptyBank(0.1, function()
            client.bags = {}
            client.bank.character = { items = { [2589] = 5 }, slots = 28 }
            Inventory:OnBagUpdate(6)                       -- the deposit: unsettled, the read owed (spacing)
            Inventory:OnBagUpdate(0)
            advance(0.09)
            client.bags = { [2589] = 5 }
            client.bank.character = { items = {}, slots = 28 }
            Inventory:OnBagUpdate(6)                       -- the withdrawal, before that read: the trailing read finds it empty
            Inventory:OnBagUpdate(0)
            advance(closeAfter)
            if lateUpdate then Inventory:OnBagUpdate(6) end
        end)
    end
    doubt = inAndOut(0.5)
    T.check("in and out again, closed 0.5 s after: the bank remembered as empty is not marked", doubt == false, closeLine())
    T.check("(and is remembered as empty)", next((bankOf())) == nil)
    doubt = inAndOut(1.8)
    T.check("closed 1.8 s after: not marked either", doubt == false)
    doubt = inAndOut(0)
    T.check("closed in the frame of the withdrawal, before any read after it: in doubt", doubt == true)
    doubt = inAndOut(0.5, true)
    T.check("an update of its own after that empty read: unsettled again - in doubt", doubt == true)

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
    Memory:SaveAccountBank(MAIN, { [4306] = 9 }, NOW - DAY)
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
    T.check("and is not in doubt after it", select(3, Memory:AccountBank("eu")) == false)

    -- Which banks a visit can mark: only one that was usable at some read of
    -- it. The account bank is remembered from another character and this
    -- one may not view it. A move in its own bank, Escape while the read is
    -- still owed and the bank refused by then.
    local function blindVisit()
        fresh()
        Inventory:Initialize()
        advance(2.1)
        Memory:SaveAccountBank(MAIN, { [4306] = 9 }, NOW - DAY)
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
    T.check("the bank that was never usable in the visit is not", select(3, Memory:AccountBank("eu")) == false)
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
    T.check("usable at one read of the visit: it can be marked", select(3, Memory:AccountBank("eu")) == true)

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
        (Memory:AccountBank("eu"))[4306] == 4 and (bankOf())[2589] == 70)
    T.check("and only the character bank is in doubt", inDoubt() == true and select(3, Memory:AccountBank("eu")) == false)

    -- The dump says what the close did.
    local lines = {}
    Inventory:RunDiagnostic(lines)
    local text = table.concat(lines, "\n")
    T.check("the dump: what the close did",
        text:find("bank visit close: owed=true unsettled=character readAgain=true kept=account markedInDoubt=character held=none moveInFlight=false unreadable=character\n", 1, true) ~= nil, text)
    T.check("the dump: the bank marked in doubt",
        text:find("bank=1 items (less than an hour ago, in doubt: not counted)", 1, true) ~= nil, text)

    -- Only a bank whose record really carries the mark is named: of the
    -- account bank nothing is remembered here (it can be viewed and has its
    -- tab, but no read of it ever gave a slot), so there is nothing to mark.
    fresh()
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    client.usable.account = true
    client.bank.account = nil
    client.started.onBankOpened()
    advance(3)
    Inventory:OnBagUpdate(0)                               -- read at once
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(15)                              -- both banks unsettled, the read owed
    client.bank.character = nil
    close()
    T.check("fixture: nothing is remembered of the account bank", Memory:AccountBank("eu") == nil)
    T.eq("the dump names only the bank that got the mark", closeLine(),
        "bank visit close: owed=true unsettled=character,account readAgain=true kept=none markedInDoubt=character held=none moveInFlight=false unreadable=character,account")

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
    -- arrives is counted for the dump (the count runs for the whole session),
    -- with how many of them marked a bank.
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
    T.check("and how many marked a bank", line:find("(in the first 10 s of the session, only counted: 0; marked a bank in doubt: 2)", 1, true) ~= nil, line)

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

    -- A session without a visit: the client may load the bank's containers
    -- in the first moments, so an update then is only counted; later it
    -- marks that bank (a craft that took reagents from it, say).
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 100 }, {}, NOW - DAY)
    Memory:SaveBags(MAIN, { [2589] = 5 }, {}, NOW - DAY)
    Memory:SaveAccountBank(MAIN, { [4306] = 9 }, NOW - DAY)
    Inventory:Initialize()
    advance(9.9)
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(15)
    T.check("9.9 s into a session: only counted", inDoubt() == false and select(3, Memory:AccountBank("eu")) == false)
    advance(0.2)
    refreshes = 0
    Inventory:OnBagUpdate(6)
    T.check("10.1 s into it: the character's bank is marked", inDoubt() == true and select(3, Memory:AccountBank("eu")) == false)
    T.check("a shown list is asked to redraw", refreshes >= 1, refreshes)
    Inventory:OnBagUpdate(15)
    T.check("and an account bank container marks the account bank", select(3, Memory:AccountBank("eu")) == true)
    T.eq("still remembered", (bankOf())[2589], 100)
    local _, sessionLine = closedUpdates()
    T.eq("the dump says what came when", sessionLine,
        "bank updates while closed: 4, before the bank was opened this session (in the first 10 s of the session, only counted: 2; marked a bank in doubt: 2)")
    -- A visit early in the session: the client has the bank's containers
    -- by then, so the quiet start is over.
    fresh()
    Memory:SaveBags(MAIN, { [2589] = 5 }, {}, NOW - DAY)
    Inventory:Initialize()
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    client.started.onBankOpened()
    advance(1)
    client.started.onBankClosing(); client.bankOpen = false; client.started.onBankClosed()
    advance(1)
    Inventory:OnBagUpdate(6)
    T.check("after a visit, also in the first ten seconds: marked", inDoubt() == true)
end)

-- ===========================================================================
-- A move whose answer has not come when the window closes cannot be seen by
-- any read: a client may never report the bank's part of it once the window
-- is closed. The client locks the slots of a move from the click until its
-- answer, so a slot that reads as locked at the closing notice (or at a
-- logout with the bank open) marks every bank that was usable in the visit
-- and of which something is remembered.
T.section("a move still on its way at the close", function()
    local function bankDoubt() return (select(3, Memory:OwnBank(MAIN.guid))) end
    local function accountDoubt() return (select(3, Memory:AccountBank("eu"))) end
    local function visit(account)
        fresh()
        Inventory:Initialize()
        advance(2.1)
        client.bankOpen = true
        client.bank.character = { items = { [2589] = 100 }, slots = 28 }
        if account ~= false then client.bank.account = { items = { [4306] = 9 }, slots = 98 } end
        client.started.onBankOpened()
        advance(3)
    end
    local function close()
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
    end
    local function closeLine()
        local lines = {}
        Inventory:RunDiagnostic(lines)
        return (("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(bank visit close: [^\n]*)\n"))
    end

    visit()
    close()
    T.check("nothing on its way: no mark", bankDoubt() == false and accountDoubt() == false)
    T.check("and the dump says so", closeLine():find(" moveInFlight=false$") ~= nil, closeLine())

    -- A deposit clicked a moment before Escape: no update has come, the bank
    -- is settled, every read was kept - and yet the move is not answered.
    visit()
    client.inFlight = true
    refreshes = 0
    close()
    T.check("a slot locked at the closing notice: both banks of the visit are in doubt", bankDoubt() == true and accountDoubt() == true)
    T.check("the dump names them and why", closeLine() ==
        "bank visit close: owed=false unsettled=none readAgain=false kept=none markedInDoubt=character,account held=none moveInFlight=true",
        closeLine())
    T.check("a shown list is asked to redraw", refreshes >= 1, refreshes)
    client.inFlight = false
    advance(2)
    T.check("and nothing takes the marks away before the next visit", bankDoubt() == true and accountDoubt() == true)
    client.bankOpen = true
    client.started.onBankOpened()
    T.check("the next visit's read does", bankDoubt() == false and accountDoubt() == false)

    -- Only a bank that was usable in the visit, and of which something is remembered.
    visit(false)
    client.inFlight = true
    close()
    T.check("a bank never usable in the visit is not marked", bankDoubt() == true and Memory:AccountBank("eu") == nil)
    fresh()
    Memory:SaveAccountBank(MAIN, { [4306] = 9 }, NOW - DAY)
    Memory:SaveBags(MAIN, { [2589] = 5 }, {}, NOW - DAY)
    Inventory:Initialize()
    advance(2.1)
    client.bankOpen = true
    client.bank.character = nil
    client.bank.account = nil                         -- the account bank may not be viewed by this one
    client.started.onBankOpened()
    advance(3)
    client.inFlight = true
    close()
    T.check("nor a remembered bank this character could not use", accountDoubt() == false and Memory:OwnBank(MAIN.guid) == nil)

    -- A logout with the bank open is a close.
    visit()
    client.inFlight = true
    client.started.onLogout()
    T.check("a logout with the bank open and a slot locked: both in doubt", bankDoubt() == true and accountDoubt() == true)

    -- A lock that cannot be read is taken for a move on its way.
    visit()
    client.inFlight = "fail"
    local ok = pcall(close)
    T.check("the locks cannot be read: no error, both in doubt", ok and bankDoubt() == true and accountDoubt() == true)
    T.check("and the dump says that it was not known", closeLine():find(" moveInFlight=unknown unreadable=character,account$") ~= nil, closeLine())
    client.inFlight = false

    -- A bank that is marked for it is not held as well (it is in doubt already).
    visit()
    Inventory:OnBagUpdate(0)                          -- read at once
    Inventory:OnBagUpdate(0)                          -- owed
    client.bank.character = { items = {}, slots = 28 }
    client.inFlight = true
    close()
    T.check("marked, not held", closeLine():find("markedInDoubt=character,account held=none", 1, true) ~= nil, closeLine())
    client.inFlight = false
end)

-- ===========================================================================
-- A read of the open bank also sees which of its slots read as locked. A
-- lock that a kept read saw, and that no update of that bank's own
-- containers has answered since, is a move still on its way at the close -
-- also when the bank cannot be looked at then: the bank's part of a
-- withdrawal whose carried part was answered before the close may never be
-- reported on a client that sends no bank update once the window is closed.
T.section("a lock a kept read saw", function()
    local function bankDoubt() return (select(3, Memory:OwnBank(MAIN.guid))) end
    local function accountDoubt() return (select(3, Memory:AccountBank("eu"))) end
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
    local function close()
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
    end
    local function closeLine()
        local lines = {}
        Inventory:RunDiagnostic(lines)
        return (("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(bank visit close: [^\n]*)\n"))
    end
    -- A withdrawal of the 100: the carried part is answered, the bank's slot
    -- still reads as locked when the read for the carried bag's update is
    -- taken (and kept).
    local function carriedHalf()
        client.bank.character = { items = { [2589] = 100 }, slots = 28, locked = { [2589] = 100 } }
        client.bags = { [2589] = 105 }
        Inventory:OnBagUpdate(0)                      -- read at once, kept
        advance(0.3)
    end

    visit()
    carriedHalf()
    client.bank.character = nil                       -- at the closing notice the bank cannot be read
    close()
    T.check("the lock a kept read saw is a move on its way at the close: both banks of the visit in doubt",
        bankDoubt() == true and accountDoubt() == true)
    T.eq("and the dump says so as for a lock seen at the close", closeLine(),
        "bank visit close: owed=false unsettled=none readAgain=false kept=none markedInDoubt=character,account held=none"
        .. " moveInFlight=true unreadable=character")
    local combined = scan()
    T.eq("nothing counts twice", combined[2589], 105)

    -- The same at a logout with the bank open.
    visit()
    carriedHalf()
    client.bank.character = nil
    client.started.onLogout()
    T.check("a logout with the bank open: the same", bankDoubt() == true and accountDoubt() == true)

    -- The bank's own update answers it: the read after it, kept and without
    -- a lock, leaves nothing on its way.
    visit()
    carriedHalf()
    client.bank.character = { items = { [765] = 1 }, slots = 28 }
    Inventory:OnBagUpdate(6)                          -- read at once, kept, no lock
    client.bank.character = nil
    close()
    T.check("answered by the bank's own update and read back: no mark", bankDoubt() == false and accountDoubt() == false)
    T.check("and the dump says nothing was on its way", closeLine():find(" moveInFlight=false", 1, true) ~= nil, closeLine())

    -- The bank's own update clears it also when no read of it can be kept
    -- after it: the bank is then unsettled, and marked for that alone.
    visit()
    carriedHalf()
    client.bank.character = nil
    Inventory:OnBagUpdate(6)                          -- its read is refused
    close()
    T.check("its own update and no read after it: that bank is in doubt for being unsettled, the other is not",
        bankDoubt() == true and accountDoubt() == false)
    T.check("nothing was on its way", closeLine():find("unsettled=character", 1, true) ~= nil
        and closeLine():find(" moveInFlight=false", 1, true) ~= nil, closeLine())

    -- A later kept read that shows no lock clears it.
    visit()
    carriedHalf()
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    Inventory:OnBagUpdate(0)                          -- read at once (0.3 s later), kept, no lock
    client.bank.character = nil
    close()
    T.check("a later kept read without a lock: no mark", bankDoubt() == false and accountDoubt() == false)

    -- A lock seen by a read that was not kept says nothing (the read of an
    -- empty bank that is not believed sees no slot at all; a refused read
    -- sees nothing).
    visit()
    client.bank.character = { items = {}, slots = 28 }
    Inventory:OnBagUpdate(0)
    advance(0.05)
    client.bank.character = nil
    close()
    T.check("no kept read saw a lock: nothing on its way", closeLine():find(" moveInFlight=false", 1, true) ~= nil, closeLine())

    -- The next visit starts without it.
    visit()
    carriedHalf()
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    close()
    advance(5)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    client.started.onBankOpened()
    advance(3)
    client.bank.character = nil
    close()
    T.check("a later visit whose reads saw no lock: no mark", bankDoubt() == false and accountDoubt() == false)
end)

-- ===========================================================================
-- A second opening notice while the bank is open (the banker clicked again)
-- begins no visit of its own: the visit keeps what it knows - which bank was
-- usable, which is unsettled, which was refused - and both banks are
-- unsettled from it on, until a read of each is kept.
T.section("a second opening notice while the bank is open", function()
    local function bankDoubt() return (select(3, Memory:OwnBank(MAIN.guid))) end
    local function accountDoubt() return (select(3, Memory:AccountBank("eu"))) end
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
    local function close()
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
    end
    local function dump()
        local lines = {}
        Inventory:RunDiagnostic(lines)
        return "\n" .. table.concat(lines, "\n") .. "\n"
    end

    -- The character bank is locked for a moment, and a withdrawal from it is
    -- answered meanwhile: its own update unsettles it, and no read of it can
    -- be kept. The banker is clicked again before the lock ends.
    visit()
    client.bank.character = nil
    client.usable.character = false
    client.bags = { [2589] = 25 }
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(0)
    advance(0.4)
    local reads = client.reads.character
    client.started.onBankOpened()
    local text = dump()
    T.check("no visit of its own: the dump shows the visit opened 3.4 s ago, and the second notice",
        text:find("\nbank visit: open for 3.4 s; reads=6 owed=false openedAgain=1\n", 1, true) ~= nil, text)
    T.check("the bank is read again at once", client.reads.character == reads + 1, client.reads.character - reads)
    T.check("the locked bank stays unsettled and usable", text:find("\nbank visit character: usable=true kept=3 lastRead=refused slots=28 "
        .. "unresolvedEmpty=false unsettled=true\n", 1, true) ~= nil, text)
    local combined, _, meta = scan()
    T.check("it is left out meanwhile, the other bank (read back) counts", combined[2589] == 25 and combined[4306] == 9
        and meta.bankPending == true and meta.accountPending == nil, combined[2589])
    advance(0.6)
    close()
    T.check("still unsettled at the close: marked, as it would have been without the second notice", bankDoubt() == true)
    T.check("the account bank, read back after the second notice, is not", accountDoubt() == false)

    -- Readable banks: both are read again at once and settled by it.
    visit()
    reads = client.reads.account
    client.started.onBankOpened()
    combined, _, meta = scan()
    T.check("both read again at once and kept: both count", combined[2589] == 105 and combined[4306] == 9
        and meta.bankPending == nil and meta.accountPending == nil and client.reads.account == reads + 1, combined[2589])
    close()
    T.check("nothing marked at the close", bankDoubt() == false and accountDoubt() == false)

    -- Within 0.2 s of the last read the read is owed, and until it comes
    -- both banks are left out.
    visit()
    Inventory:OnBagUpdate(0)                          -- read at once
    client.started.onBankOpened()
    combined, _, meta = scan()
    T.check("the second notice right after a read: both banks are left out until the read",
        combined[2589] == 5 and meta.bankPending == true and meta.accountPending == true, combined[2589])
    text = dump()
    T.check("and both are unsettled", text:find("\nbank visit character: [^\n]* unsettled=true\n") ~= nil
        and text:find("\nbank visit account: [^\n]* unsettled=true\n") ~= nil, text)
    advance(0.3)
    combined, _, meta = scan()
    T.check("the trailing read brings them back", combined[2589] == 105 and combined[4306] == 9 and meta.bankPending == nil
        and meta.accountPending == nil, combined[2589])
    close()
    T.check("and the close marks nothing", bankDoubt() == false and accountDoubt() == false)

    -- A bank that was usable earlier in the visit stays a bank of the visit.
    visit()
    client.usable.account = false
    client.bank.account = nil                         -- locked from now on
    client.started.onBankOpened()
    advance(0.5)
    client.inFlight = true
    close()
    T.check("a slot locked at the close marks the bank usable before the second notice too", accountDoubt() == true)
    client.inFlight = false
end)

-- ===========================================================================
-- After the close the bank cannot be read any more. The answer of a last move
-- may still arrive, and a craft may take reagents from the closed bank: an
-- update of a bank container marks that bank at once, whenever it comes; a
-- carried count that has risen within a second, against what the bags held
-- at the closing notice, marks a bank that is remembered to hold that item.
T.section("after the close", function()
    local function bankOf() return Memory:OwnBank(MAIN.guid) end
    local function inDoubt() return (select(3, Memory:OwnBank(MAIN.guid))) end
    local function accountDoubt() return (select(3, Memory:AccountBank("eu"))) end
    -- 5 linen carried, 100 in the bank, 9 silk in the account bank; the
    -- window was open for three seconds and has just closed.
    local function closedVisit(atClose)
        fresh()
        Inventory:Initialize()
        advance(2.1)
        client.bankOpen = true
        client.bank.character = { items = { [2589] = 100 }, slots = 28 }
        client.bank.account = { items = { [4306] = 9 }, slots = 98 }
        client.started.onBankOpened()
        advance(3)
        if atClose then atClose() end
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
        client.reads.bags = 0
    end
    local function afterLine()
        local lines = {}
        Inventory:RunDiagnostic(lines)
        return (("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(after the close: [^\n]*)\n"))
    end

    -- An update of a bank container: that bank is marked at once, in the
    -- handler of the update, and the other bank is not.
    closedVisit()
    advance(0.08)
    refreshes = 0
    Inventory:OnBagUpdate(6)
    T.check("an update of a bank container after the close marks that bank at once", inDoubt() == true)
    T.check("and not the other bank", accountDoubt() == false)
    T.eq("still remembered", (bankOf())[2589], 100)
    T.check("a shown list is asked to redraw", refreshes >= 1, refreshes)
    T.eq("nothing was read for it", client.reads.bags, 0)
    local combined, breakdown, meta = scan()
    T.check("a scan counts the bags and the account bank", combined[2589] == 5 and combined[4306] == 9 and meta.bankInDoubt == true
        and meta.accountInDoubt == nil, combined[2589])
    T.eq("the dump names the bank and why", afterLine(),
        "after the close: bankUpdates=1 (last 0.1 s after the close) bagUpdates=0 compared=0 marked=character (bank container updated)")
    closedVisit()
    advance(0.08)
    Inventory:OnBagUpdate(15)
    T.check("an update of an account bank container marks the account bank alone", accountDoubt() == true and inDoubt() == false)
    -- Whenever it comes: the watch counts those of the ten seconds after
    -- the close, every one marks.
    closedVisit()
    advance(9.9)
    Inventory:OnBagUpdate(6)
    T.check("9.9 s after the close: marked", inDoubt() == true)
    closedVisit()
    advance(10.1)
    Inventory:OnBagUpdate(6)
    T.check("10.1 s after the close: marked too", inDoubt() == true)
    T.eq("(the watch counts only the first ten seconds)", afterLine(), "after the close: bankUpdates=0 bagUpdates=0 compared=0 marked=none")
    closedVisit()
    advance(600)
    Inventory:OnBagUpdate(15)
    T.check("ten minutes after the close: the account bank, alone", accountDoubt() == true and inDoubt() == false)
    -- A bank that was never usable in the visit is marked by its own
    -- update too: the update is that bank's own sign that it changed.
    fresh()
    Inventory:Initialize()
    advance(2.1)
    Memory:SaveAccountBank(MAIN, { [4306] = 9 }, NOW - DAY)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 100 }, slots = 28 }
    client.bank.account = nil
    client.started.onBankOpened()
    advance(3)
    client.started.onBankClosing()
    client.bankOpen = false
    client.started.onBankClosed()
    advance(0.08)
    Inventory:OnBagUpdate(15)
    Inventory:OnBagUpdate(6)
    T.check("an update of a bank that was never usable in the visit marks it", accountDoubt() == true and inDoubt() == true)
    T.eq("the dump counts both updates and names both banks", afterLine(),
        "after the close: bankUpdates=2 (last 0.1 s after the close) bagUpdates=0 compared=0 marked=character (bank container updated), account (bank container updated)")

    -- The watch for a carried count that rose is a second after a close at
    -- which every bank of the visit could be looked at for a move on its
    -- way (its locks were seen), and three seconds after one at which a
    -- bank could not be: the answer of a move into an empty carried slot
    -- from a bank that could not be looked at may come late, and it is
    -- seen only by the carried count.
    closedVisit()
    advance(2)
    client.bags = { [2589] = 5, [4306] = 3 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("every bank looked at: a rise two seconds after the close marks nothing", accountDoubt() == false)
    closedVisit(function() client.bank.account = nil end)        -- the account bank cannot be read at the close
    local blindLines = {}
    Inventory:RunDiagnostic(blindLines)
    T.check("the dump names the bank that could not be looked at", table.concat(blindLines, "\n"):find(
        "moveInFlight=false unreadable=account\n", 1, true) ~= nil, table.concat(blindLines, "\n"))
    advance(2)
    client.bags = { [2589] = 5, [4306] = 3 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("a bank not looked at: a rise two seconds after the close marks it", accountDoubt() == true and inDoubt() == false)
    closedVisit(function() client.bank.account = nil end)
    advance(2)
    client.bags = { [2589] = 9 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("but not the bank that was looked at: its watch is the second", inDoubt() == false)
    closedVisit(function() client.bank.account = { items = {}, slots = 98 } end)   -- reads empty, items remembered
    advance(2.5)
    client.bags = { [2589] = 5, [4306] = 3 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("a bank that reads empty at the close while items of it are remembered counts as not looked at", accountDoubt() == true)
    closedVisit(function() client.bank.account = nil end)
    advance(3.1)
    client.bags = { [2589] = 5, [4306] = 3 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("(three seconds after: nothing)", accountDoubt() == false)

    -- A client that reports the late answer for the carried bag alone: the
    -- count of an item has risen and the remembered bank holds that item.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    T.eq("the update itself reads nothing", client.reads.bags, 0)
    T.check("nothing is marked before something compared", inDoubt() == false)
    Inventory:OnBagUpdate(0)
    refreshes = 0
    nextFrame()
    T.eq("one comparison a frame later, however many updates there were", client.reads.bags, 1)
    T.check("a carried count rose for an item the bank holds: that bank is in doubt", inDoubt() == true)
    T.check("and a shown list is asked to redraw", refreshes >= 1, refreshes)
    T.check("the account bank holds none of it: not marked", accountDoubt() == false)
    T.eq("the dump says which item", afterLine(),
        "after the close: bankUpdates=0 bagUpdates=2 (last 0.1 s after the close) compared=1 marked=character (carried count rose: 2589)")
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.eq("the other bank is still compared for", client.reads.bags, 2)
    client.bags = { [2589] = 65, [4306] = 1 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("until it is marked too", accountDoubt() == true)
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.eq("once both are marked, nothing is compared any more", client.reads.bags, 3)

    -- A scan that comes before that comparison leaves the bank out of its
    -- own count and marks nothing: the comparison on the next frame decides
    -- (a stack on its way from one carried bag to another shows in both for
    -- a moment).
    closedVisit()
    advance(0.08)
    T.eq("this frame's scan, before the answer arrives", (Inventory:ScanAll())[2589], 105)
    client.reads.bags = 0
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    combined, breakdown, meta = Inventory:ScanAll()     -- no InvalidateCache: the update dropped the frame's scan
    T.check("a scan in the frame of the update does not count the bank beside the risen count",
        combined[2589] == 65 and meta.bankPending == true, combined[2589])
    T.check("and does not mark it", inDoubt() == false and meta.bankInDoubt == nil)
    T.check("the account bank, which holds none of the item, counts", combined[4306] == 9 and meta.accountPending == nil)
    T.eq("with the bags it read anyway: one read", client.reads.bags, 1)
    nextFrame()
    T.check("the comparison a frame later marks it", inDoubt() == true and client.reads.bags == 2, client.reads.bags)
    -- The count is back at the note by the next frame: nothing is marked.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 10 }                        -- a stack between two bags, in both for a moment
    Inventory:OnBagUpdate(1)
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("a stack shown in two carried bags for a moment: that scan leaves the bank out", combined[2589] == 10
        and meta.bankPending == true, combined[2589])
    client.bags = { [2589] = 5 }
    Inventory:OnBagUpdate(0)
    refreshes = 0
    nextFrame()
    T.check("and the comparison finds nothing risen: no mark", inDoubt() == false and (scan())[2589] == 105)
    T.check("a shown list is asked to redraw: the scan that left the bank out may have been drawn", refreshes >= 1, refreshes)

    -- A count that fell marks nothing, nor one that rose for an item no
    -- remembered bank of the visit holds.
    closedVisit()
    advance(0.08)
    client.bags = {}
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("an item that was carried is gone: nothing is marked", inDoubt() == false and accountDoubt() == false)
    T.eq("it was compared", client.reads.bags, 1)
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 5, [774] = 3 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("an item no remembered bank holds arrives: nothing is marked", inDoubt() == false and accountDoubt() == false)
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 5, [4306] = 1 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("an item the account bank holds arrives: the account bank is marked, the other not",
        accountDoubt() == true and inDoubt() == false)

    -- The note follows a count that falls: what was used up after the close
    -- must not hide a stack that arrives after it. Two linen are used up,
    -- then the answer of a withdrawal brings one back - less than was
    -- carried at the close, more than a moment ago.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 3 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("two linen used up after the close: nothing is marked", inDoubt() == false)
    client.bags = { [2589] = 4 }
    Inventory:OnBagUpdate(0)
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("one arrives after that: a scan in that frame leaves the bank out", combined[2589] == 4 and meta.bankPending == true,
        combined[2589])
    nextFrame()
    T.check("and the comparison marks it: the count rose against what was left", inDoubt() == true)
    -- Only the comparison lowers the note, when the frame's updates are
    -- through - not a scan in between. A stack on its way from one carried
    -- bag to another shows in neither for a moment when the source's update
    -- comes first; a scan at that moment must not turn the stack's arrival
    -- in the other bag into a rise.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 3 }                         -- two linen have left their bag ...
    Inventory:OnBagUpdate(0)
    T.eq("a scan between the two updates of a move among the carried bags counts bags and bank", (Inventory:ScanAll())[2589], 103)
    client.bags = { [2589] = 5 }                         -- ... and are in the other one
    Inventory:OnBagUpdate(1)
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("a scan after the second update leaves the bank out: the count rose against what the scan before it saw",
        combined[2589] == 5 and meta.bankPending == true and inDoubt() == false, combined[2589])
    nextFrame()
    T.check("the comparison marks nothing: against the note nothing has risen", inDoubt() == false)
    T.eq("and the bank counts again", (scan())[2589], 105)
    -- That is for the scans of one frame only: the comparison starts them afresh.
    Inventory:OnBagUpdate(0)
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("a scan after a later update is measured against the note again", combined[2589] == 105 and meta.bankPending == nil,
        combined[2589])
    -- A scan that saw a count fall does see what arrives after it, in the
    -- same frame: three linen are used up, then the answer of a withdrawal
    -- brings one - before the comparison has lowered the note.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 2 }
    Inventory:OnBagUpdate(0)
    T.eq("a scan after the fall counts bags and bank", (Inventory:ScanAll())[2589], 102)
    client.bags = { [2589] = 3 }
    Inventory:OnBagUpdate(0)
    combined, breakdown, meta = Inventory:ScanAll()
    T.check("a stack arriving in that frame, after the scan: the bank is left out, not counted beside it", combined[2589] == 3
        and meta.bankPending == true, combined[2589])
    -- The note is the scanner's own: the bags the adapter handed out are not changed by it.
    closedVisit()
    local handed = client.bags
    advance(0.08)
    client.bags = { [2589] = 3 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.eq("the table the adapter handed out at the close is left as it was", handed[2589], 5)

    -- Nothing changed in the bags: no doubt.
    closedVisit()
    advance(0.08)
    refreshes = 0
    Inventory:OnBagUpdate(0)
    Inventory:OnBagUpdate(1)
    nextFrame()
    T.check("updates that change no count mark nothing", inDoubt() == false and accountDoubt() == false)
    T.eq("they were compared once", client.reads.bags, 1)
    T.eq("and ask for no redraw: no scan left a bank out meanwhile", refreshes, 0)
    -- Bags that cannot be read are not compared: that decides nothing and
    -- the comparison stays due.
    client.bags, client.backpackSlots = { [2589] = 65 }, 0
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("bags that cannot be read mark nothing", inDoubt() == false)
    T.eq("and are not compared", afterLine(),
        "after the close: bankUpdates=0 bagUpdates=3 (last 0.1 s after the close) compared=1 marked=none")
    client.backpackSlots = 16
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("readable again and risen: marked", inDoubt() == true)

    -- Later than a second after the close a change of the bags is play.
    closedVisit()
    advance(1.5)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("a change of the bags 1.5 s after the close marks nothing", inDoubt() == false)
    T.eq("and nothing is compared", client.reads.bags, 0)
    T.eq("the dump: nothing came inside the watch", afterLine(), "after the close: bankUpdates=0 bagUpdates=0 compared=0 marked=none")

    -- No note is taken of bags that could not be read at the close. Without
    -- a note, an update of a carried bag within the second is all there is
    -- to go by: it marks the visit's banks, at once.
    closedVisit(function() client.bags, client.backpackSlots = { [2589] = 65 }, 0 end)
    client.backpackSlots = 16                           -- readable again, and holding what they held at the close
    advance(0.08)
    T.check("nothing is marked by the close itself", inDoubt() == false and accountDoubt() == false)
    Inventory:OnBagUpdate(0)
    T.check("no note of the bags: an update of a carried bag marks the visit's banks",
        inDoubt() == true and accountDoubt() == true)
    T.eq("the dump says why", afterLine(), "after the close: bankUpdates=0 bagUpdates=1 (last 0.1 s after the close) compared=0"
        .. " marked=character (no note of the bags), account (no note of the bags)")
    closedVisit(function() client.bags, client.backpackSlots = { [2589] = 65 }, 0 end)
    client.backpackSlots = 16
    advance(1.5)
    Inventory:OnBagUpdate(0)
    T.check("without a note too only inside the second", inDoubt() == false and accountDoubt() == false)

    -- A session without a visit: updates of bank containers are only counted.
    fresh()
    Inventory:ForgetRemembered()                        -- also ends the watch the visit above left
    Inventory:Initialize()
    advance(2.1)
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - DAY)
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(0)
    nextFrame()
    T.check("no visit in this session: nothing is marked", inDoubt() == false)
    T.eq("and there is no line for a watch", afterLine(), nil)

    -- A logout before that next frame: the comparison is made at logout.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    client.started.onLogout()
    T.check("a comparison still due at logout is made then", inDoubt() == true)
    T.eq("the dump has it", afterLine(),
        "after the close: bankUpdates=0 bagUpdates=1 (last 0.1 s after the close) compared=1 marked=character (carried count rose: 2589)")

    -- A new visit ends the watch, and its first kept read takes the mark away.
    closedVisit()
    advance(0.08)
    Inventory:OnBagUpdate(6)
    Inventory:OnBagUpdate(15)
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 40 }, slots = 28 }
    client.started.onBankOpened()
    T.check("the next visit's kept read clears the doubt", inDoubt() == false and (bankOf())[2589] == 40)
    T.check("of the account bank too", accountDoubt() == false)
    -- A comparison still due when the bank is opened again is made first.
    closedVisit()
    advance(0.08)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    client.bankOpen = true
    client.bank.character = nil                         -- cannot be read in the new visit
    client.started.onBankOpened()
    T.check("a comparison still due at the next opening is made before the visit begins", inDoubt() == true)
end)

-- ===========================================================================
-- The answer of a last move may arrive after the session has ended. That
-- session cannot see it; the next one can, because nothing else changes the
-- carried bags in between. So a session that ends with the bank open, or
-- within ten seconds after a close, leaves a note with the character's
-- record: what the carried bags held, and which banks the visit could use.
-- (What the next session does with it is in test_stockflow.lua.)
T.section("the end of a session at the bank", function()
    local function note() return Memory:BagsAtBank(MAIN.guid) end
    local function visit(character, account)
        fresh()
        Inventory:Initialize()
        advance(2.1)
        client.bankOpen = true
        if character ~= false then client.bank.character = { items = { [2589] = 100 }, slots = 28 } end
        if account ~= false then client.bank.account = { items = { [4306] = 9 }, slots = 98 } end
        client.started.onBankOpened()
        advance(3)
    end
    local function close()
        client.started.onBankClosing()
        client.bankOpen = false
        client.started.onBankClosed()
    end

    -- With the bank open.
    visit()
    T.check("during the visit there is no note", note() == nil)
    client.bags = { [2589] = 5, [765] = 2 }
    client.started.onLogout()
    local n = note()
    T.check("logout with the bank open: what the bags hold is noted with the record",
        n ~= nil and n.known == true and n.items[2589] == 5 and n.items[765] == 2 and count(n.items) == 2)
    T.check("for both banks, which the visit could use", n ~= nil and n.character == true and n.account == true)
    client.started.onLogout()
    Inventory:OnLogout()
    T.check("further logout notices leave the same note", note() ~= nil and note().items[2589] == 5)

    -- Within ten seconds after a close: the bags as they are at logout.
    visit()
    close()
    T.check("the close itself leaves no note", note() == nil)
    advance(5)
    client.bags = { [2589] = 7 }
    client.started.onLogout()
    n = note()
    T.check("logout five seconds after the close: the bags as they are at logout", n ~= nil and n.known == true
        and n.items[2589] == 7 and count(n.items) == 1)
    visit()
    close()
    advance(9.9)
    client.started.onLogout()
    T.check("9.9 s after the close: noted", note() ~= nil)
    visit()
    close()
    advance(10.1)
    client.started.onLogout()
    T.check("10.1 s after the close: not noted", note() == nil)
    -- Opened again and closed: the ten seconds count from the last close.
    visit()
    close()
    advance(8)
    client.bankOpen = true
    client.started.onBankOpened()
    advance(8)
    close()
    advance(8)
    client.started.onLogout()
    T.check("the ten seconds count from the last close", note() ~= nil)

    -- Bags that cannot be read at logout, or read as completely empty (not
    -- trusted at logout): the note of the close stands in.
    visit()
    close()
    advance(1)
    client.bags, client.backpackSlots = { [2589] = 9 }, 0
    client.started.onLogout()
    n = note()
    T.check("bags that cannot be read at logout: the note taken at the close", n ~= nil and n.known == true and n.items[2589] == 5)
    visit()
    close()
    advance(1)
    client.bags = {}
    client.started.onLogout()
    n = note()
    T.check("bags that read as completely empty at logout: the note taken at the close", n ~= nil and n.known == true
        and n.items[2589] == 5)
    -- Neither: the note says that the bags are not known.
    visit()
    client.backpackSlots = 0
    close()
    advance(1)
    client.started.onLogout()
    n = note()
    T.check("unreadable at the close and at logout: noted as not known", n ~= nil and n.known == false and n.items == nil
        and n.character == true)
    visit()
    client.backpackSlots = 0
    client.started.onLogout()
    n = note()
    T.check("the same at a logout with the bank open", n ~= nil and n.known == false)

    -- The note names only the banks the visit could use.
    visit(nil, false)                                    -- the account bank may not be viewed
    close()
    advance(1)
    client.started.onLogout()
    n = note()
    T.check("a bank that was never usable in the visit is not named", n ~= nil and n.character == true and n.account == false)
    visit(false, false)                                  -- neither bank
    close()
    advance(1)
    client.started.onLogout()
    T.check("no bank usable in the visit: no note", note() == nil)

    -- A visit that marked a bank leaves its note all the same.
    visit()
    close()
    advance(0.5)
    Inventory:OnBagUpdate(6)
    client.started.onLogout()
    T.check("a bank already in doubt: the note is left all the same", note() ~= nil
        and select(3, Memory:OwnBank(MAIN.guid)) == true)

    -- A comparison after the close still due at logout, the bags not
    -- readable: it can never be made - the banks of the visit are marked.
    visit()
    close()
    advance(0.3)
    client.bags = { [2589] = 65 }
    Inventory:OnBagUpdate(0)
    client.backpackSlots = 0
    client.started.onLogout()
    T.check("a comparison due and the bags unreadable at logout: both banks in doubt",
        select(3, Memory:OwnBank(MAIN.guid)) == true and select(3, Memory:AccountBank("eu")) == true)
    client.backpackSlots = 16

    -- With Syndicator nothing is noted.
    visit()
    _G.Syndicator = { API = {} }
    client.started.onLogout()
    _G.Syndicator = nil
    T.check("with Syndicator installed: no note", note() == nil)
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
            Memory:SaveAccountBank(MAIN, { [4306] = 9 }, NOW - DAY)
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
    T.check("empty at opening: the account bank is kept", (Memory:AccountBank("eu"))[4306] == 9)
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
    local account = Memory:AccountBank("eu")
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
    -- in doubt - its empty reads are a sign that it was emptied, and it is
    -- not counted until the next visit reads it.
    start()
    client.started.onBankOpened()
    advance(0.7)
    close()
    client.reads.character = 0
    advance(5)
    T.check("closed before it could be believed: kept, and nothing read after the close",
        (bankOf())[2589] == 40 and client.reads.character == 0, client.reads.character)
    T.check("and in doubt", select(3, Memory:OwnBank(MAIN.guid)) == true)

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
    -- (The account bank reads empty too and is read again every half
    -- second: the read for this update may wait for the spacing.)
    advance(0.45)
    T.check("the second look is", next((bankOf())) == nil)

    -- One bank has its items at once, the other not yet: each is judged alone.
    start()
    client.bank.character = { items = { [2589] = 75 } }
    client.started.onBankOpened()
    T.check("the bank that has items is saved, the empty one waits",
        (bankOf())[2589] == 75 and (Memory:AccountBank("eu"))[4306] == 9)

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
    T.eq("the half-second look, the two-second look, the trailing read and the repeated read are each waiting once", looks, 4)

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
    -- The game's Self-Found flag is asked outside the memory's part of a
    -- scan: a failure there must not get out either. The setting alone
    -- decides then.
    fresh()
    Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
    survives("asking the game whether the character is Self-Found", "IsSelfFoundCharacter", function()
        T.eq("the flag cannot be read: a scan counts as the setting says", (scan())[2589], 25)
        LazyProf.db.char.selfFoundMode = true
        T.eq("and with the setting on, as Self-Found", (scan())[2589], 5)
        LazyProf.db.char.selfFoundMode = false
        Inventory:SaveBags(true)
    end)
    -- What is saved is offered to the other characters: a record saved while
    -- the flag cannot be read says that it cannot send.
    T.check("a save made while the flag cannot be read is saved as unable to send",
        LazyProf.db.global.stock.characters[MAIN.guid] ~= nil and LazyProf.db.global.stock.characters[MAIN.guid].noSend == true)
    fresh()
    Memory:SaveBags(MAIN, { [2589] = 5 }, {}, NOW)
    survives("telling the record that the setting changed while the flag cannot be read", "IsSelfFoundCharacter", function()
        Inventory:OnSendingChanged()
    end)
    T.check("so is the record told then", LazyProf.db.global.stock.characters[MAIN.guid].noSend == true)
    fresh()
    Inventory:SaveBags(true)
    T.check("(with the flag readable and off, it can send)", LazyProf.db.global.stock.characters[MAIN.guid].noSend == nil)

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
        table.concat(watchLines, "\n"):find("after the close: bankUpdates=0 bagUpdates=1 (last 0.0 s after the close) compared=1", 1, true) ~= nil,
        table.concat(watchLines, "\n"))

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
-- The timed bag save needs the client's timer. A client without one, or a
-- timer call that fails, must not stop the addon from starting - and must not
-- leave a save "waiting" that no timer will ever run: every later request
-- would be turned away by it.
T.section("a bag save whose timer cannot be set", function()
    local function dump()
        local out = {}
        Inventory:RunDiagnostic(out)
        return table.concat(out, "\n")
    end
    local function waiting() return (dump():match("waiting: bagSave=(%a+)")) end
    local function failures() return tonumber((dump():match("; (%d+) this session"))) or 0 end
    local realTimer = _G.C_Timer
    for _, case in ipairs({
        { "a timer call that fails", { After = function() error("no timers today") end } },
        { "a client without timers", false },
    }) do
        local label = case[1]
        fresh()
        local before = failures()
        _G.C_Timer = case[2] or nil
        local ok, err = pcall(Inventory.Initialize, Inventory)
        T.check(label .. ": the start does not raise", ok, err)
        T.check(label .. ": the adapter's events are started all the same", type(client.started) == "table")
        T.eq(label .. ": no save is left waiting", waiting(), "false")
        T.check(label .. ": the failure is counted", failures() > before, failures() - before)
        ok, err = pcall(Inventory.OnBagUpdate, Inventory, 0)
        T.check(label .. ": a bag update does not raise", ok, err)
        T.eq(label .. ": and leaves no save waiting either", waiting(), "false")
        ok, err = pcall(Inventory.ForgetRemembered, Inventory)
        T.check(label .. ": forgetting does not raise", ok, err)
        T.eq(label .. ": and leaves none waiting", waiting(), "false")
        -- Once the timer can be set, the next request is not turned away.
        _G.C_Timer = realTimer
        timers = {}
        client.bags = { [2589] = 9, [765] = 2 }
        Inventory:OnBagUpdate(0)
        T.eq(label .. ": with a working timer the next bag update asks for a save", #timers, 1)
        T.eq(label .. ": which is waiting", waiting(), "true")
        advance(2.1)
        local summary = Memory:Summary()
        T.check(label .. ": and is written", #summary.characters == 1 and summary.characters[1].bagItems == 2
            and waiting() == "false", #summary.characters)
    end
    _G.C_Timer = realTimer
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
    Memory:SaveAccountBank(MAIN, { [2589] = 10 }, NOW)
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
    Memory:SaveAccountBank(MAIN, { [2589] = 10 }, NOW - 5 * DAY)
    local before = Memory:Summary()
    client.bankOpen = true
    client.bank.character = { items = { [2589] = 999 } }
    local lines = {}
    Inventory:RunDiagnostic(lines)
    local text = table.concat(lines, "\n")
    -- Whether a line is in a dump exactly as given, with nothing after it.
    local function hasLine(dumpText, line)
        return ("\n" .. dumpText .. "\n"):find("\n" .. line .. "\n", 1, true) ~= nil
    end
    -- The addon knows one inventory addon; the line names it.
    T.check("says where stock outside the bags comes from",
        lines[1] == "source: LazyProf's own memory (Syndicator is not installed)", lines[1])
    -- What a scan was tried for, and no more: which stock counts is said by
    -- the settings line and by each character's label.
    T.check("scan now: says that the memory reads, and nothing about what counts",
        hasLine(text, "scan now: the memory reads without error"), text)
    T.check("the memory line says when characters are dropped",
        hasLine(text, "memory: format=1 characters=3 accountBanks=1 (characters not seen for 180 days are dropped)"), text)
    T.check("the settings, and beside the Self-Found setting what the game's own flag reads",
        text:find("settings: bank=true alts=true guildBank=false selfFound=false gameSelfFound=false\n", 1, true) ~= nil, text)
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
    LazyProf.db.global.stock.characters["Player-1-UNSEEN"] = { name = "Timeless", world = "eu-pvp", faction = "Alliance", seen = 0 / 0,
        bags = { items = { [1] = 1 }, at = NOW } }
    found = labels()
    T.eq("label: a record without a usable time of its last save", found["Timeless"], "not counted (no time it was last seen)")
    LazyProf.db.global.stock.characters["Player-1-UNSEEN"] = nil

    LazyProf.db.profile.includeAltCharacters = false
    local _, offDump = labels()
    T.check("label: an alt while alts are off", offDump:find("character: Bank Alt [alt, not counted (alts off)]", 1, true) ~= nil, offDump)
    -- With bank items and alts both off nothing of the memory is counted:
    -- the line about the trial must not say that it is.
    LazyProf.db.profile.includeBankItems = false
    local _, bothOffDump = labels()
    T.check("scan now, bank items and alts off: the same line, no word of bank or alt stock being counted",
        hasLine(bothOffDump, "scan now: the memory reads without error")
        and not bothOffDump:find("are counted", 1, true), bothOffDump)
    LazyProf.db.profile.includeBankItems = true
    T.check("label: the other reasons stay as they are", offDump:find("character: Other Side [other faction]", 1, true) ~= nil
        and offDump:find("character: Solo [not counted (Self-Found)]", 1, true) ~= nil)
    LazyProf.db.profile.includeAltCharacters = true
    LazyProf.db.char.selfFoundMode = true
    local _, soloDump = labels()
    T.check("label: an alt while this character is Self-Found",
        soloDump:find("character: Bank Alt [not counted (this character is Self-Found)]", 1, true) ~= nil, soloDump)
    T.check("the settings line: the setting on, the game's flag off",
        soloDump:find("settings: bank=true alts=true guildBank=false selfFound=true gameSelfFound=false\n", 1, true) ~= nil, soloDump)
    T.check("scan now, Self-Found: the same line, no word of alt stock being counted",
        hasLine(soloDump, "scan now: the memory reads without error") and not soloDump:find("are counted", 1, true), soloDump)
    LazyProf.db.char.selfFoundMode = false
    -- Self-Found by the game's own flag, with the setting off: printed apart,
    -- and the alts are labelled as for the setting.
    client.gameSelfFound = true
    local _, flagDump = labels()
    T.check("the settings line: the setting off, the game's flag on",
        flagDump:find("settings: bank=true alts=true guildBank=false selfFound=false gameSelfFound=true\n", 1, true) ~= nil, flagDump)
    T.check("label: an alt while the game marks this character Self-Found",
        flagDump:find("character: Bank Alt [not counted (this character is Self-Found)]", 1, true) ~= nil, flagDump)
    client.gameSelfFound = false
    -- A flag that cannot be read is said to be so; the dump counts no failure for it.
    do
        local function failures(dumpText) return tonumber((dumpText:match("; (%d+) this session"))) or 0 end
        local _, healthyDump = labels()
        local realFlag = LazyProf.Client.IsSelfFoundCharacter
        LazyProf.Client.IsSelfFoundCharacter = function() error("flag down") end
        local _, brokenDump = labels()
        LazyProf.Client.IsSelfFoundCharacter = realFlag
        local _, afterDump = labels()
        T.check("the settings line: a flag that cannot be read",
            brokenDump:find("selfFound=false gameSelfFound=not readable: ", 1, true) ~= nil
            and brokenDump:find("flag down", 1, true) ~= nil, brokenDump)
        T.eq("the dump itself counts no failure for it", failures(afterDump), failures(healthyDump))
        T.check("and still labels the alt as counted (the setting alone decides then)",
            brokenDump:find("character: Bank Alt [alt, counted]", 1, true) ~= nil, brokenDump)
    end
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
    Memory:MarkAccountBankDoubt("eu")
    local _, accountDump = labels()
    T.check("the account bank in doubt", accountDump:find(
        "account bank: region=eu read by world=eu-pvp faction=Alliance items=1 (5 days ago, in doubt: not counted) - not counted (in doubt)",
        1, true) ~= nil, accountDump)
    Memory:SaveAccountBank(MAIN, { [2589] = 10 }, NOW - 5 * DAY)
    -- Read here, but not counted while bank items are off, nor for a
    -- character that is Self-Found (by the setting or by the game's flag):
    -- the line says so rather than "counted".
    local ACCOUNT_LINE = "account bank: region=eu read by world=eu-pvp faction=Alliance items=1 (5 days ago) - "
    LazyProf.db.profile.includeBankItems = false
    local _, accountOffDump = labels()
    T.check("the account bank while bank items are off", hasLine(accountOffDump, ACCOUNT_LINE .. "not counted (bank items are off)"),
        accountOffDump)
    LazyProf.db.profile.includeBankItems = true
    LazyProf.db.char.selfFoundMode = true
    local _, accountSoloDump = labels()
    T.check("the account bank of a Self-Found character",
        hasLine(accountSoloDump, ACCOUNT_LINE .. "not counted (this character is Self-Found)"), accountSoloDump)
    LazyProf.db.char.selfFoundMode = false
    client.gameSelfFound = true
    local _, accountFlagDump = labels()
    T.check("the account bank of a character the game marks Self-Found",
        hasLine(accountFlagDump, ACCOUNT_LINE .. "not counted (this character is Self-Found)"), accountFlagDump)
    client.gameSelfFound = false

    -- A character whose world or faction cannot be read counts nobody, and the dump says so in words.
    client.identity = { guid = MAIN.guid, name = "Main Character", faction = "Alliance" }
    local _, noWorld = labels()
    T.check("no world: said in words", noWorld:find("world: unknown - alts and the account bank are not counted", 1, true) ~= nil, noWorld)
    T.check("no world: the others are labelled for it",
        noWorld:find("character: Bank Alt [not counted (this character's world or faction is unknown)]", 1, true) ~= nil, noWorld)
    client.identity = { guid = MAIN.guid, name = "Main Character", world = "eu-pvp" }
    local _, noFaction = labels()
    T.check("no faction: said in words", noFaction:find("faction: unknown - alts are not counted", 1, true) ~= nil, noFaction)
    -- With Syndicator installed the memory is not used: what the world and
    -- the faction are does not decide what counts, and no line says it does.
    installSyndicator()
    client.identity = { guid = MAIN.guid, name = "Main Character" }
    local _, syndicatorUnknown = labels()
    T.check("with Syndicator, world and faction unknown: no line says that alts or the account bank are not counted",
        not syndicatorUnknown:find("world: unknown", 1, true) and not syndicatorUnknown:find("faction: unknown", 1, true)
        and not syndicatorUnknown:find("are not counted", 1, true), syndicatorUnknown)
    T.check("(and who the character is is still printed)",
        syndicatorUnknown:find("identity: guid=Player-1-MAIN name=Main Character world=nil faction=nil", 1, true) ~= nil,
        syndicatorUnknown)
    _G.Syndicator = nil
    client.identity = MAIN
    for _, guid in ipairs({ "Player-1-NORMAL", "Player-1-SOLO", "Player-1-OLDME", "Player-1-OLDALT", "Player-1-NAMELESS" }) do
        LazyProf.db.global.stock.characters[guid] = nil
    end
    T.check("the account bank: whose read it is, and that it counts here",
        text:find("account bank: region=eu read by world=eu-pvp faction=Alliance items=1 (5 days ago) - counted\n", 1, true) ~= nil
        or text:sub(-#"account bank: region=eu read by world=eu-pvp faction=Alliance items=1 (5 days ago) - counted")
            == "account bank: region=eu read by world=eu-pvp faction=Alliance items=1 (5 days ago) - counted", text)
    T.check("who the character is, with its region", text:find(
        "identity: guid=Player-1-MAIN name=Main Character world=eu-pvp faction=Alliance region=eu", 1, true) ~= nil, text)
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
    -- Nothing is dropped from the memory while Syndicator is installed: the
    -- line does not say that it is.
    T.check("with Syndicator the memory line does not speak of dropping characters",
        hasLine(text, "memory: format=1 characters=3 accountBanks=1") and not text:find("are dropped", 1, true), text)
    T.check("with Syndicator the source line names it",
        lines[1] == "source: Syndicator (LazyProf's own memory is not used and not updated)", lines[1])
    -- Nor is the bank followed then (the bank window is open here): one line
    -- in place of what a visit did, what is waiting and what came while the
    -- bank was closed.
    T.check("with Syndicator the bank is said not to be followed, in one line, after who the character is",
        text:find("\nidentity: [^\n]*\nbank: not followed %(Syndicator is installed%)\nmemory: format=1 ") ~= nil, text)
    T.check("and no line of a visit, of what is waiting or of the updates while the bank was closed",
        not text:find("waiting:", 1, true) and not text:find("bank visit", 1, true) and not text:find("after the close", 1, true)
        and not text:find("bags at the bank", 1, true) and not text:find("bank updates while closed", 1, true)
        and not text:find("bankOpen=", 1, true), text)
    -- An account bank remembered from before is not used either.
    T.check("with Syndicator the remembered account bank is listed as not used, not as counted",
        hasLine(text, "account bank: region=eu read by world=eu-pvp faction=Alliance items=1 (5 days ago)"
            .. " - remembered, not used (Syndicator is installed)"), text)
    _G.Syndicator = nil
    -- A client whose adapter does not read the bank at all (the Classic
    -- ones): the bank is said not to be followed there; what can be waiting
    -- is a save of the bags.
    client.readsBank = false
    lines = {}
    Inventory:RunDiagnostic(lines)
    text = table.concat(lines, "\n")
    T.check("a client that does not read the bank: the bag save that is waiting, then one line for the bank",
        text:find("\nidentity: [^\n]*\nwaiting: bagSave=false\nbank: not followed on this client\nmemory: format=1 ") ~= nil, text)
    T.check("and no line of a visit, of an open bank or of updates while it was closed",
        not text:find("bank visit", 1, true) and not text:find("after the close", 1, true)
        and not text:find("bags at the bank", 1, true) and not text:find("bank updates while closed", 1, true)
        and not text:find("bankOpen=", 1, true) and not text:find("bankRead=", 1, true), text)
    client.readsBank = true
    -- A memory that cannot be read: what a scan counts then, and why.
    do
        local realOwnBank = Memory.OwnBank
        Memory.OwnBank = function() error("bank table gone") end
        local _, brokenDump = labels()
        Memory.OwnBank = realOwnBank
        local line = brokenDump:match("scan now: [^\n]*")
        T.check("scan now, the memory cannot be read: bags only, with the error",
            line ~= nil and line:find("scan now: bags only - the memory cannot be read: ", 1, true) == 1
            and line:find("bank table gone", 1, true) ~= nil, brokenDump)
    end
    -- The try reads what a scan reads, no more: a Self-Found character's
    -- scan never reads the alts, so alts that cannot be read do not make the
    -- try fail for it - by the setting or by the game's flag.
    do
        local realAlts = Memory.Alts
        Memory.Alts = function() error("alts table gone") end
        local function scanNow()
            Inventory:ForgetAltsPart()
            local _, dumpText = labels()
            return dumpText:match("scan now: [^\n]*"), dumpText
        end
        local line, dumpText = scanNow()
        T.check("scan now, the alts cannot be read: bags only (fixture)",
            line ~= nil and line:find("alts table gone", 1, true) ~= nil, dumpText)
        LazyProf.db.char.selfFoundMode = true
        line, dumpText = scanNow()
        T.eq("scan now, the alts cannot be read but the character is Self-Found: the memory reads", line,
            "scan now: the memory reads without error")
        LazyProf.db.char.selfFoundMode = false
        client.gameSelfFound = true
        line, dumpText = scanNow()
        T.eq("scan now, the same for a character the game marks Self-Found", line, "scan now: the memory reads without error")
        client.gameSelfFound = false
        Memory.Alts = realAlts
        Inventory:ForgetAltsPart()
    end

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

    -- What the client itself counts of the character's remembered bank,
    -- beside what is remembered: one paste away from the bank says whether
    -- the client counts a bank while its window is closed.
    do
        local function dumpOf()
            local out = {}
            Inventory:RunDiagnostic(out)
            return table.concat(out, "\n"), out
        end
        local function countLines(out)
            local kept = {}
            for _, line in ipairs(out) do
                if line:find("client count", 1, true) then kept[#kept + 1] = line end
            end
            return kept
        end
        fresh()
        Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
        Memory:SaveBank(MAIN, { [2589] = 40, [765] = 3, [2770] = 9, [4306] = 2, [774] = 1, [6948] = 1 }, {}, NOW)
        Memory:SaveAccountBank(MAIN, { [2589] = 10, [774] = 4 }, NOW)
        client.bags = { [2589] = 5, [774] = 2 }
        -- A client that counts both banks while they are closed.
        local inBank = { [2589] = 40, [765] = 3, [2770] = 9, [4306] = 2, [774] = 1, [6948] = 1 }
        local inAccount = { [2589] = 10, [774] = 4 }
        local askedFor = {}
        client.clientCounts = function(itemId)
            askedFor[#askedFor + 1] = itemId
            local carried = client.bags[itemId] or 0
            return carried, carried + (inBank[itemId] or 0), carried + (inBank[itemId] or 0) + (inAccount[itemId] or 0)
        end
        local saveBefore = Memory:Summary().characters[1].seen
        local dump, out = dumpOf()
        local counts = countLines(out)
        T.eq("client counts: one line for each of the five lowest item ids of the remembered bank", #counts, 5)
        T.eq("client counts: the first line, word for word", counts[1],
            "client count 765: carried=0 withBank=3 withAccountBank=3; remembered: bags now=0 bank=3 accountBank=0")
        T.eq("client counts: an item held in the bags and in both banks", counts[2],
            "client count 774: carried=2 withBank=3 withAccountBank=7; remembered: bags now=2 bank=1 accountBank=4")
        T.eq("client counts: the third", counts[3],
            "client count 2589: carried=5 withBank=45 withAccountBank=55; remembered: bags now=5 bank=40 accountBank=10")
        T.check("client counts: lowest ids first, and no more than five",
            counts[4]:find("client count 2770: ", 1, true) == 1 and counts[5]:find("client count 4306: ", 1, true) == 1
            and not dump:find("client count 6948", 1, true), dump)
        T.eq("client counts: the client is asked for those five only", table.concat(askedFor, ","), "765,774,2589,2770,4306")
        T.check("client counts: after the bank's lines, before what is remembered",
            dump:find("\nbank updates while closed: [^\n]*\nclient count 765: ") ~= nil
            and dump:find("\nclient count 4306: [^\n]*\nmemory: format=1 ") ~= nil, dump)
        T.check("client counts: the dump stays read-only", Memory:Summary().characters[1].seen == saveBefore and #timers == 0)
        -- A client that does not count a closed bank: the lines say so by their numbers.
        client.clientCounts = function(itemId)
            local carried = client.bags[itemId] or 0
            return carried, carried, carried
        end
        T.eq("client counts: a client that sees only what is carried", countLines(select(2, dumpOf()))[3],
            "client count 2589: carried=5 withBank=5 withAccountBank=5; remembered: bags now=5 bank=40 accountBank=10")
        -- No account bank remembered for this world: said in words, not as a count.
        LazyProf.db.global.stock.account.eu = nil
        T.eq("client counts: no account bank remembered", countLines(select(2, dumpOf()))[1],
            "client count 765: carried=0 withBank=0 withAccountBank=0; remembered: bags now=0 bank=3 accountBank=never seen")
        -- Fewer than five items remembered: a line for each.
        Memory:SaveBank(MAIN, { [4306] = 2, [765] = 3 }, {}, NOW)
        counts = countLines(select(2, dumpOf()))
        T.check("client counts: two items remembered, two lines", #counts == 2 and counts[1]:find("client count 765: ", 1, true) == 1
            and counts[2]:find("client count 4306: ", 1, true) == 1, table.concat(counts, " | "))
        -- A bank marked in doubt is still what is remembered: it is compared.
        Memory:MarkBankDoubt(MAIN.guid)
        T.eq("client counts: a bank in doubt is compared all the same", #countLines(select(2, dumpOf())), 2)
        -- Nothing remembered of this character's bank: one line says so.
        Memory:SaveBank(MAIN, {}, {}, NOW)
        counts = countLines(select(2, dumpOf()))
        T.check("client counts: a bank remembered as empty has nothing to compare", #counts == 1
            and counts[1] == "client count: nothing remembered of this bank to compare", table.concat(counts, " | "))
        LazyProf.db.global.stock.characters[MAIN.guid].bank = nil
        counts = countLines(select(2, dumpOf()))
        T.check("client counts: nor has a bank never seen", #counts == 1
            and counts[1] == "client count: nothing remembered of this bank to compare", table.concat(counts, " | "))
        -- A client whose adapter has no such count: no line at all.
        Memory:SaveBank(MAIN, { [2589] = 40, [765] = 3 }, {}, NOW)
        client.clientCounts = nil
        dump, out = dumpOf()
        T.eq("client counts: an adapter without the count prints no line", #countLines(out), 0)
        LazyProf.db.global.stock.characters[MAIN.guid].bank = nil
        T.eq("client counts: nor the line about nothing to compare", #countLines(select(2, dumpOf())), 0)
        Memory:SaveBank(MAIN, { [2589] = 40, [765] = 3 }, {}, NOW)
        -- A count call that fails: said in its place, and the rest of the dump stays.
        client.clientCounts = function(itemId)
            if itemId == 2589 then error("count down") end
            return 0, 3, 3
        end
        dump, out = dumpOf()
        T.check("client counts: a failing count call is reported as a section error",
            dump:find("\nclient count 765: carried=0 withBank=3 withAccountBank=3; [^\n]*\nSECTION ERROR: client count: [^\n]*count down")
                ~= nil, dump)
        T.check("client counts: and the rest of the dump stays", dump:find("\nmemory: format=1 characters=2 ", 1, true) ~= nil
            and dump:find("\ncharacter: Main Character [this character]", 1, true) ~= nil
            and dump:find("\ncharacter: Bank Alt [alt, counted]", 1, true) ~= nil, dump)
        -- With Syndicator the memory is not in use: nothing to compare.
        client.clientCounts = function() return 1, 2, 3 end
        installSyndicator()
        T.eq("client counts: none with Syndicator installed", #countLines(select(2, dumpOf())), 0)
        _G.Syndicator = nil
        client.clientCounts = nil
    end

    -- Entries that are not what LazyProf writes are counted, not listed.
    LazyProf.db.global.stock.characters["Player-1-JUNK"] = true
    LazyProf.db.global.stock.account["eu-normal"] = "x"
    lines = {}
    Inventory:RunDiagnostic(lines)
    T.check("unreadable entries are counted in the dump", table.concat(lines, "\n"):find("unreadable=2", 1, true) ~= nil,
        table.concat(lines, "\n"))

    -- A saved table in a format this version does not read: the dump says
    -- so in words, and lists nothing of it as if it had been read.
    LazyProf.db.global.stock = { schema = 9, account = { ["eu-pvp"] = { items = { [2589] = 1 }, at = NOW } }, characters = {
        [ALT.guid] = { name = "Bank Alt", world = "eu-pvp", faction = "Alliance", seen = NOW,
            bags = { items = { [2589] = 20 }, at = NOW } } } }
    lines = {}
    Inventory:RunDiagnostic(lines)
    text = table.concat(lines, "\n")
    T.check("another format is named, and said not to be read",
        hasLine(text, "memory: format=9 - not a format this version reads; it is left alone"), text)
    T.check("that is the last line: no count of characters, no character and no account bank is listed",
        lines[#lines] == "memory: format=9 - not a format this version reads; it is left alone"
        and not text:find("characters=", 1, true) and not text:find("\ncharacter: ", 1, true)
        and not text:find("\naccount bank: ", 1, true), text)
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
    -- The sentences that carry the meaning, word for word: a text that said
    -- the opposite would still hold the few words looked for above.
    for _, sentence in ipairs({
        "Such a character cannot be sent anything: stock of your other characters and of the guild bank is not counted for it.",
        "It cannot send anything either: where LazyProf remembers the stock itself (no inventory addon installed), "
            .. "its own stock is not counted for your other characters.",
    }) do
        T.check("Self-Found: says, word for word: " .. sentence:sub(1, 44) .. "...", selfFoundText:find(sentence, 1, true) ~= nil,
            selfFoundText)
    end
    T.check("alts: says, word for word, that a Self-Found character gets no alt stock",
        text(alts.desc):find("A character in Self-Found mode cannot be sent anything, so no alt stock is counted for it.", 1, true) ~= nil,
        text(alts.desc))
    T.check("guild bank: says, word for word, that it is not counted for a Self-Found character",
        text(guild.desc):find("A character in Self-Found mode cannot be handed anything, so the guild bank is not counted for it.",
            1, true) ~= nil, text(guild.desc))
    T.check("Self-Found: says that the game's own Self-Found mark counts for stock with the setting off",
        selfFoundText:find("A character the game itself marks Self-Found is treated this way for stock even with this setting off.",
            1, true) ~= nil, selfFoundText)
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
    -- The memory's section is protected the same way: a failure in it is
    -- reported in the window, and what the adapter printed stays.
    LazyProf.Client.RunStockDiagnostic = function(_, out) out[#out + 1] = "adapter: stock lines" end
    local realRun = Inventory.RunDiagnostic
    Inventory.RunDiagnostic = function() error("memory boom") end
    shown = nil
    local ran, runError = pcall(LazyProf.SlashCommand, LazyProf, "diag stock")
    Inventory.RunDiagnostic = realRun
    T.check("a failing memory section does not raise", ran, runError)
    T.check("it is reported with its error, after the adapter's lines", type(shown) == "string"
        and shown:find("adapter: stock lines\nSECTION ERROR: memory: ", 1, true) ~= nil
        and shown:find("memory boom", 1, true) ~= nil, shown)
    printed = {}
    LazyProf:SlashCommand("diag")
    T.check("/lp diag lists the stock dump", table.concat(printed, "\n"):find("/lp diag stock", 1, true) ~= nil)
end)

T.finish()
