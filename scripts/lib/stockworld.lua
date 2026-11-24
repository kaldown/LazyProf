-- scripts/lib/stockworld.lua
--
-- A WoW Forever client just big enough to follow stock through it: carried
-- bags, the bank, who the character is, a clock with timers. Sessions of
-- characters share one saved table, and each session loads the real Forever
-- adapter, the stock memory and the scanner (and Core/Init.lua on request),
-- so the three are checked together and not against a stand-in.
--
--   local World = require("scripts.lib.stockworld")
--   World.install()                         -- stubs the client; call once
--   World.reset()                           -- a fresh client state
--   World.containers[6] = { slots = 28, World.slot(2589, 100) }   -- World.slot(id, n, bound, locked)
--   World.bank[0] = { tabs = { { ID = 6 } } }          -- [bankType]: tabs, canView, locked
--   World.gameSelfFound = true              -- the game itself marks the character Self-Found
--   World.countsBank = false                -- the client's own item count leaves the banks out
--   local addon = World.login(saved, { selfFound = false, init = false })
--   World.event(addon, "BANKFRAME_OPENED")  -- a client event the adapter registered
--   World.bagUpdate(addon, 6, 0)            -- BAG_UPDATE for each container id given
--   World.bagUpdateDelayed(addon)           -- BAG_UPDATE_DELAYED: that batch of updates is complete
--   World.advance(0.5); World.nextFrame()
--   World.scan(addon)                       -- ScanAll past the frame cache
--
-- Counters (World.calls) say how often the client was asked: slots (container
-- slot counts), tabs (bank tab lists). World.errors holds what was handed to
-- the client's error handler (what the player's error display would show).

local World = {}

World.time = 0                -- GetTime()
World.FRAME = 0.016           -- seconds from one frame to the next
World.serverTime = 20000 * 86400 + 3600
World.timers = {}
World.containers = {}
World.bank = {}
World.rules = {}
World.region = "EU"
World.regionNumber = 3
World.guid = "Player-4444-000000AA"
World.name = "Main Goldtooth"
World.faction = "Horde"
World.gameSelfFound = false   -- C_PlayerInfo.IsSelfFoundActive()
World.countsBank = true       -- C_Item.GetItemCount counts the banks' containers when asked to
World.reagentsFromBank = false   -- ReagentsFromBankAllowed(): crafts may take reagents from the bank
World.calls = { slots = 0, tabs = 0 }
World.errors = {}

-- A slot as GetContainerItemInfo reads it. isLocked: the client has locked
-- the slot - a move of it is on its way (the click is made, the answer has
-- not come).
function World.slot(itemId, stack, isBound, isLocked)
    return { itemID = itemId, stackCount = stack, isBound = isBound and true or false, isLocked = isLocked and true or false }
end

-- A fresh client: an empty backpack, no bank, a PvP world in Europe, the
-- clock at zero, nothing waiting.
function World.reset()
    World.time = 0
    World.serverTime = 20000 * 86400 + 3600
    World.timers = {}
    World.containers = { [0] = { slots = 16 } }
    World.bank = {}
    World.rules = { [213] = true }
    World.region = "EU"
    World.regionNumber = 3
    World.guid = "Player-4444-000000AA"
    World.name = "Main Goldtooth"
    World.faction = "Horde"
    World.gameSelfFound = false
    World.countsBank = true
    World.reagentsFromBank = false
    World.calls = { slots = 0, tabs = 0 }
    World.errors = {}
end

-- Install the client's globals (they read World's fields when called).
function World.install()
    _G.Enum = {
        TradeskillRelativeDifficulty = { Optimal = 0, Medium = 1, Easy = 2, Trivial = 3 },
        CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 },
        BagIndex = { Accountbanktab = -3, Characterbanktab = -2, Keyring = -1, Backpack = 0,
                     Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
                     CharacterBankTab_1 = 6, CharacterBankTab_9 = 14,
                     AccountBankTab_1 = 15, AccountBankTab_9 = 23 },
        BankType = { Character = 0, Guild = 1, Account = 2 },
        GameRule = { HardcoreRuleset = 10, CraftFromBankRestricted = 211, PvPRuleset = 213, RPRuleset = 214 },
    }
    _G.BaseScrollBoxEvents = { OnScroll = "OnScroll" }
    _G.ScrollBoxListMixin = { Event = { OnDataRangeChanged = "OnDataRangeChanged" } }
    _G.GetBuildInfo = function() return "1.60.1", "70938", "Nov 1 2026", 16001 end
    _G.WOW_PROJECT_ID, _G.WOW_PROJECT_CAMELOT = 18, 18
    _G.GetTime = function() return World.time end
    _G.GetServerTime = function() return World.serverTime end
    -- Like the client's: returns nothing (no handle to keep), and never runs
    -- a timer in the frame that asked for it - at the earliest one frame
    -- later, whoever asked (an event or another timer).
    _G.C_Timer = { After = function(delay, fn)
        World.timers[#World.timers + 1] = { due = World.time + math.max(World.FRAME, delay), fn = fn }
    end }
    _G.C_Container = {
        GetContainerNumSlots = function(bag)
            World.calls.slots = World.calls.slots + 1
            return World.containers[bag] and World.containers[bag].slots or 0
        end,
        GetContainerItemInfo = function(bag, index)
            return World.containers[bag] and World.containers[bag][index] or nil
        end,
        GetContainerNumFreeSlots = function() return 0, 0 end,
    }
    _G.C_Bank = {
        CanViewBank = function(bankType)
            return World.bank[bankType] ~= nil and World.bank[bankType].canView ~= false
        end,
        FetchBankLockedReason = function(bankType)
            return World.bank[bankType] and World.bank[bankType].locked or nil
        end,
        FetchPurchasedBankTabData = function(bankType)
            World.calls.tabs = World.calls.tabs + 1
            return World.bank[bankType] and World.bank[bankType].tabs or {}
        end,
        ShouldUsePlayerBagsInBank = function() return true end,
    }
    _G.C_GameRules = { IsGameRuleActive = function(rule) return World.rules[rule] == true end }
    _G.GetCurrentRegionName = function() return World.region end
    _G.GetCurrentRegion = function() return World.regionNumber end
    -- The faction's key first, then its name in the client's language: only
    -- the first is the same for every player, so it alone may be a key.
    _G.UnitFactionGroup = function() return World.faction, World.faction .. " (in the client's language)" end
    _G.UnitGUID = function(unit) return unit == "player" and World.guid or nil end
    _G.NameUtil = { GetUnmodifiedUnitFullName = function() return World.name end }
    _G.C_PlayerInfo = { IsSelfFoundActive = function() return World.gameSelfFound end }
    -- The client's own count of an item: what the carried bags hold (0-5),
    -- with the character bank's tabs (6-14) and the account bank's (15-23)
    -- when asked for. Whether the real client counts a bank while its window
    -- is closed is not known; World.countsBank = false is a client that
    -- does not.
    _G.C_Item = { GetItemCount = function(itemId, includeBank, _includeUses, _includeReagentBank, includeAccountBank)
        local function held(first, last)
            local count = 0
            for bag = first, last do
                local container = World.containers[bag]
                for index = 1, container and container.slots or 0 do
                    local info = container[index]
                    if info and info.itemID == itemId then count = count + info.stackCount end
                end
            end
            return count
        end
        local count = held(0, 5)
        if includeBank and World.countsBank then count = count + held(6, 14) end
        if includeAccountBank and World.countsBank then count = count + held(15, 23) end
        return count
    end }
    _G.ReagentsFromBankAllowed = function() return World.reagentsFromBank end
    _G.issecretvalue = nil
    _G.geterrorhandler = function()
        return function(message) World.errors[#World.errors + 1] = tostring(message) end
    end
    _G.Syndicator = nil
    _G.InCombatLockdown = function() return false end
    -- The realm name is a shard name on this client and the Classic container
    -- calls do not exist: neither may be reached.
    _G.GetRealmName = function() error("GetRealmName called on Forever") end
    _G.GetContainerNumSlots = function() error("global GetContainerNumSlots called on Forever") end
    _G.GetContainerItemInfo = function() error("global GetContainerItemInfo called on Forever") end
    World.reset()
end

-- Move the clock on by dt seconds, running the timers that come due on the
-- way. The clock stops at each moment something is due and runs one pass
-- there: every timer due by then, in the order they were asked for. What a
-- timer asks for in turn is due a frame later at the earliest (see
-- C_Timer.After above), so it runs in a later pass, at a later time - as on
-- the client, where a zero-delay timer runs on the next frame.
function World.advance(dt)
    local target = World.time + dt
    while true do
        local due
        for _, timer in ipairs(World.timers) do
            if timer.due <= target + 1e-9 and (not due or timer.due < due) then
                due = timer.due
            end
        end
        if not due then break end
        if due > World.time then World.time = due end
        local pass, rest = {}, {}
        for _, timer in ipairs(World.timers) do
            if timer.due <= World.time + 1e-9 then
                pass[#pass + 1] = timer
            else
                rest[#rest + 1] = timer
            end
        end
        World.timers = rest
        for i, timer in ipairs(pass) do
            local ok, err = pcall(timer.fn)
            if not ok then
                -- The timers of this pass that have not run stay waiting.
                for j = #pass, i + 1, -1 do
                    table.insert(World.timers, 1, pass[j])
                end
                error(err, 0)
            end
        end
    end
    World.time = target
end

-- The next frame: the clock moves by one frame, and what was asked for "as
-- soon as possible" during this one runs.
function World.nextFrame()
    World.advance(World.FRAME)
end

-- One character's session on the saved table `saved` (LazyProfDB.global).
-- opts.selfFound: the character's Self-Found setting. opts.init: also load
-- Core/Init.lua (the session then has OnEnable, OnBagUpdate, the slash
-- command). Without it the scanner is started directly.
function World.login(saved, opts)
    opts = opts or {}
    World.timers = {}
    local addon = {}
    addon.db = {
        profile = { includeBankItems = true, includeAltCharacters = true, includeGuildBank = false },
        char = { learnedRecipes = {}, selfFoundMode = opts.selfFound or false },
        global = saved,
    }
    addon.Utils = {}
    addon.debugLines = {}
    function addon:Debug(category, message) self.debugLines[#self.debugLines + 1] = tostring(message) end
    function addon:IsDebugEnabled() return false end
    addon.events = {}
    function addon:RegisterEvent(event, handler) self.events[event] = handler end
    addon.refreshes = 0
    function addon:ScheduleShoppingListRefresh() self.refreshes = self.refreshes + 1 end
    local function load(path) assert(loadfile(path))("LazyProf", addon) end
    load("Core/Constants.lua")
    load("Core/Client/Family.lua")
    load("Core/Client/Classic.lua")
    load("Core/Client/Forever.lua")
    load("Modules/Inventory/StockMemory.lua")
    load("Modules/Inventory/Scanner.lua")
    if opts.init then
        local savedLibStub = _G.LibStub
        _G.LibStub = function() return { NewAddon = function(_self, target) return target end } end
        local debug = addon.Debug
        load("Core/Init.lua")
        _G.LibStub = savedLibStub
        addon.Debug = debug              -- keep collecting what is logged
        addon.Print = function() end
        addon.Professions = { Initialize = function() end }
        addon.clientStarted = false
        addon.Client.Start = function() addon.clientStarted = true end
    else
        addon.Inventory:Initialize()
    end
    return addon
end

-- A client event, the way the event library hands it to a function handler.
function World.event(addon, name, ...)
    local handler = addon.events[name]
    assert(handler, "no handler registered for " .. tostring(name))
    if type(handler) == "string" then
        return addon[handler](addon, name, ...)
    end
    return handler(name, ...)
end

-- BAG_UPDATE for each container id given, in order. The adapter does not
-- register that event (Core/Init.lua owns it and passes it on), so without
-- Init the scanner is told directly.
function World.bagUpdate(addon, ...)
    for i = 1, select("#", ...) do
        local bagId = select(i, ...)
        if addon.events.BAG_UPDATE then
            World.event(addon, "BAG_UPDATE", bagId)
        else
            addon.Inventory:OnBagUpdate(bagId)
        end
    end
end

-- BAG_UPDATE_DELAYED: the client's notice that a batch of bag updates is
-- complete. Core/Init.lua owns that event too.
function World.bagUpdateDelayed(addon)
    if addon.events.BAG_UPDATE_DELAYED then
        World.event(addon, "BAG_UPDATE_DELAYED")
    else
        addon.Inventory:OnBagUpdateDelayed()
    end
end

-- A scan past the frame cache.
function World.scan(addon)
    addon.Inventory:InvalidateCache()
    return addon.Inventory:ScanAll()
end

return World
