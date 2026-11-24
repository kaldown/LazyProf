-- scripts/test_stockflow.lua
--
-- Stock through a whole session, on the real WoW Forever adapter, the scanner
-- and the stock memory together (scripts/lib/stockworld.lua is the client):
-- bank visits, logins and logouts of several characters on one saved table,
-- and saved data that is not what the addon wrote. What the pieces do one by
-- one is in test_stockmemory.lua, test_scanner.lua and test_forever_client.lua.
--
-- Run from the addon root:  lua5.1 scripts/test_stockflow.lua

package.path = "./?.lua;" .. package.path
local T = require("scripts.lib.check").new()
local World = require("scripts.lib.stockworld")
World.install()
local slot = World.slot

local LINEN, SILK, HEARTHSTONE, BAR = 2589, 4306, 6948, 2770
local MAIN_GUID = "Player-4444-000000AA"

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- ===========================================================================
-- The clock of this client is the game's: a timer never runs in the frame
-- that asked for it, so what the addon counts per frame here is what it
-- counts in game.
-- ===========================================================================
T.section("the clock", function()
    World.reset()
    local ran = {}
    World.time = 5
    C_Timer.After(0, function()
        ran[#ran + 1] = "first at " .. tostring(World.time > 5)
        C_Timer.After(0, function() ran[#ran + 1] = "second at " .. tostring(World.time) end)
    end)
    World.advance(0)
    T.eq("a zero-delay timer does not run in the frame that asked for it", #ran, 0)
    World.nextFrame()
    T.eq("it runs on the next frame, at a later time", table.concat(ran, ","), "first at true")
    local after = World.time
    World.nextFrame()
    T.check("a zero-delay timer asked for by a timer runs one frame later still, not in the same pass",
        #ran == 2 and World.time > after, table.concat(ran, ","))
    -- Timers due at different moments each run at their own moment.
    World.reset()
    local seen = {}
    C_Timer.After(0.5, function() seen[#seen + 1] = World.time end)
    C_Timer.After(2, function() seen[#seen + 1] = World.time end)
    World.advance(3)
    T.check("a long step runs each timer at the moment it is due", seen[1] == 0.5 and seen[2] == 2 and World.time == 3,
        tostring(seen[1]) .. "," .. tostring(seen[2]))
end)

-- ===========================================================================
-- Saved stock that is not what the addon wrote must not stop the addon, and
-- must not put anything but real counts into a scan.
-- ===========================================================================
T.section("damaged saved stock", function()
    local function goodAlt()
        return { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde", seen = World.serverTime - 100,
                 bags = { items = { [LINEN] = 20 }, at = World.serverTime - 100 } }
    end
    local function with(change)
        local record = goodAlt()
        change(record)
        return { schema = 1, characters = { X = record }, account = {} }
    end
    local cases = {
        -- label, the saved stock, the linen a scan may count (5 are carried)
        { "the store is a string", function() return "broken" end, 5 },
        { "the store is an empty table", function() return {} end, 5 },
        { "another format", function() return { schema = 2, characters = { X = goodAlt() } } end, 5 },
        { "a format number that is text", function() return { schema = "1", characters = { X = goodAlt() } } end, 5 },
        { "characters is a string", function() return { schema = 1, characters = "x", account = {} } end, 5 },
        { "account is a number", function() return { schema = 1, characters = { X = goodAlt() }, account = 5 } end, 25 },
        { "a record that is true", function() return { schema = 1, characters = { X = true, Y = goodAlt() }, account = {} } end, 25 },
        { "a record that is a string", function() return { schema = 1, characters = { X = "gone" }, account = {} } end, 5 },
        { "the character's own record is a number", function() return { schema = 1, characters = { [MAIN_GUID] = 7 }, account = {} } end, 5 },
        { "a record without fields", function() return { schema = 1, characters = { X = {} }, account = {} } end, 5 },
        { "bags is a number", function() return with(function(r) r.bags = 5 end) end, 5 },
        { "bags without items", function() return with(function(r) r.bags = { at = 1 } end) end, 5 },
        { "a count that is a string", function() return with(function(r) r.bags.items[LINEN] = "abc" end) end, 5 },
        { "a count that is negative", function() return with(function(r) r.bags.items[LINEN] = -50 end) end, 5 },
        { "a count that is true", function() return with(function(r) r.bags.items[LINEN] = true end) end, 5 },
        { "own bank with a negative count", function() return { schema = 1, characters = { [MAIN_GUID] = { name = "Main Goldtooth",
            world = "eu-pvp", faction = "Horde", seen = 1, bank = { items = { [LINEN] = -30 }, at = 1 } } }, account = {} } end, 5 },
        { "own bank with a string count", function() return { schema = 1, characters = { [MAIN_GUID] = { name = "Main Goldtooth",
            world = "eu-pvp", faction = "Horde", seen = 1, bank = { items = { [LINEN] = "x" }, at = 1 } } }, account = {} } end, 5 },
        { "an account bank that is true", function() return { schema = 1, characters = {}, account = { ["eu-pvp"] = true } } end, 5 },
        { "a name that is a number", function() return { schema = 1, characters = { X = (function() local r = goodAlt(); r.name = 12; return r end)(),
            Y = goodAlt() }, account = {} } end, 25 },
        { "seen is a string", function() return with(function(r) r.seen = "yesterday" end) end, 5 },
        { "a part without a time", function() return with(function(r) r.bags.at = nil end) end, 25 },
    }
    for _, case in ipairs(cases) do
        local label, make, want = case[1], case[2], case[3]
        World.reset()
        World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
        local saved = { stock = make() }
        local addon = World.login(saved, { init = true })

        -- Login: the addon starts whatever the saved stock looks like.
        local ok, err = pcall(addon.OnEnable, addon)
        T.check(label .. ": the addon starts", ok, err)
        T.check(label .. ": the profession window's events are started", addon.clientStarted == true)
        T.check(label .. ": the bag event is registered", addon.events.BAG_UPDATE ~= nil)

        -- The first bag save, a scan, the dump.
        ok, err = pcall(World.advance, 3)
        T.check(label .. ": the bag save does not fail", ok, err)
        local combined, breakdown
        ok, err = pcall(function() combined, breakdown = World.scan(addon) end)
        T.check(label .. ": a scan does not fail", ok, err)
        T.eq(label .. ": linen counted", combined and combined[LINEN], want)
        local clean = true
        for itemId, n in pairs(combined or {}) do
            if type(itemId) ~= "number" or type(n) ~= "number" or n <= 0 or n ~= math.floor(n) then clean = false end
        end
        T.check(label .. ": only real counts in the scan", clean)
        local lines = {}
        ok, err = pcall(addon.Inventory.RunDiagnostic, addon.Inventory, lines)
        T.check(label .. ": the dump does not fail", ok, err)

        -- "Forget remembered characters" puts it right (a later format is left alone).
        ok, err = pcall(function() addon.Inventory:ForgetRemembered(); World.advance(3) end)
        T.check(label .. ": forget does not fail", ok, err)
        combined = World.scan(addon)
        T.eq(label .. ": after forget only the bags", combined[LINEN], 5)
        if label ~= "another format" and label ~= "a format number that is text" then
            local summary = addon.StockMemory:Summary()
            T.check(label .. ": after forget the character is remembered cleanly",
                summary.usable and summary.unreadable == 0 and #summary.characters == 1
                and summary.characters[1].guid == MAIN_GUID, #summary.characters)
        end
    end
end)

-- ===========================================================================
-- A client call that fails while the memory starts or is read must not stop
-- the addon either: the scan then counts the live bags, and the dump says why.
-- ===========================================================================
T.section("a failing client call", function()
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    local saved = { stock = { schema = 1, characters = { X = { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde",
        seen = World.serverTime, bags = { items = { [LINEN] = 20 }, at = World.serverTime } } }, account = {} } }
    local addon = World.login(saved, { init = true })
    local realRule = _G.C_GameRules.IsGameRuleActive
    _G.C_GameRules.IsGameRuleActive = function() error("bad argument #1 to 'IsGameRuleActive'") end

    local ok, err = pcall(addon.OnEnable, addon)
    T.check("the addon starts although who the character is cannot be read", ok, err)
    T.check("the profession window's events are started", addon.clientStarted == true)
    T.check("the other events are registered", addon.events.BAG_UPDATE ~= nil and addon.events.GET_ITEM_INFO_RECEIVED ~= nil)
    T.check("the bank and logout events are registered too", addon.events.BANKFRAME_OPENED ~= nil and addon.events.PLAYER_LOGOUT ~= nil)

    ok, err = pcall(World.advance, 3)
    T.check("the waiting bag save does not raise", ok, err)
    local combined, breakdown, meta
    ok, err = pcall(function() combined, breakdown, meta = World.scan(addon) end)
    T.check("a scan does not raise", ok, err)
    T.check("it counts the live bags only", combined ~= nil and combined[LINEN] == 5 and count(combined) == 1
        and breakdown[LINEN].bags == 5 and breakdown[LINEN].alts == nil)
    T.check("and still says its stock is LazyProf's own", meta ~= nil and meta.remembered == true)
    ok, err = pcall(function()
        World.bagUpdate(addon, 0, 6)
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(3)
        World.event(addon, "BANKFRAME_CLOSED")
        World.event(addon, "PLAYER_LOGOUT")
    end)
    T.check("bag updates, a bank visit and logout do not raise", ok, err)

    -- The reason is logged once, and the dump shows the last one.
    local logged = 0
    for _, line in ipairs(addon.debugLines) do
        if line:find("IsGameRuleActive", 1, true) then logged = logged + 1 end
    end
    T.eq("the reason is logged once, not at every call", logged, 1)
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    local text = table.concat(lines, "\n")
    T.check("the dump names the last failure", text:find("last error:", 1, true) ~= nil
        and text:find("IsGameRuleActive", 1, true) ~= nil, text)

    -- Once the call works again, so does the memory.
    _G.C_GameRules.IsGameRuleActive = realRule
    World.nextFrame()
    combined = World.scan(addon)
    T.eq("the call works again: the alt counts", combined[LINEN], 25)

    -- A healthy session has no error to show.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    addon = World.login({}, { init = true })
    addon:OnEnable()
    World.advance(3)
    lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("a healthy session: no error line", not table.concat(lines, "\n"):find("last error", 1, true))
    T.eq("a healthy session: nothing logged", #addon.debugLines, 0)
end)

-- ===========================================================================
-- A Self-Found character cannot send anything: what it holds is not offered
-- to its alts.
-- ===========================================================================
T.section("a Self-Found alt", function()
    local function session(saved, guid, name, linen, opts)
        World.reset()
        World.guid, World.name = guid, name
        World.containers = { [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, linen) } }
        local addon = World.login(saved, opts)
        World.advance(3)
        return addon
    end
    local function linenOf(addon)
        local combined, breakdown = World.scan(addon)
        return combined[LINEN], breakdown[LINEN].alts
    end

    local saved = {}
    local solo = session(saved, "Player-4444-000000SF", "Solo Goldtooth", 80, { selfFound = true })
    World.event(solo, "PLAYER_LOGOUT")
    local main = session(saved, MAIN_GUID, "Main Goldtooth", 5)
    local total, alts = linenOf(main)
    T.eq("the main counts only what it carries", total, 5)
    T.check("and names no alt", alts == nil)
    World.event(main, "PLAYER_LOGOUT")

    -- The mode is turned off on the alt: after its next save it counts.
    solo = session(saved, "Player-4444-000000SF", "Solo Goldtooth", 80, { selfFound = false })
    World.event(solo, "PLAYER_LOGOUT")
    main = session(saved, MAIN_GUID, "Main Goldtooth", 5)
    total, alts = linenOf(main)
    T.eq("with the mode off on the alt its linen counts", total, 85)
    T.check("under its name", alts ~= nil and alts["Solo Goldtooth"] ~= nil and alts["Solo Goldtooth"].bags == 80)

    -- Turned on in the middle of a session: the record follows without a bag change.
    World.event(main, "PLAYER_LOGOUT")
    solo = session(saved, "Player-4444-000000SF", "Solo Goldtooth", 80, { selfFound = false })
    solo.db.char.selfFoundMode = true
    solo.Inventory:OnSendingChanged()
    World.advance(3)
    main = session(saved, MAIN_GUID, "Main Goldtooth", 5)
    T.eq("turned on mid-session: its linen is no longer offered", (linenOf(main)), 5)

    -- A bank visit of a Self-Found character does not make it a source either.
    World.event(main, "PLAYER_LOGOUT")
    World.reset()
    World.guid, World.name = "Player-4444-000000SF", "Solo Goldtooth"
    World.containers = { [0] = { slots = 16, slot(LINEN, 80) }, [6] = { slots = 28, slot(LINEN, 300) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } } }
    solo = World.login(saved, { selfFound = true })
    World.advance(3)
    World.event(solo, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(solo, "BANKFRAME_CLOSED")
    T.check("the Self-Found character still counts its own bank", (select(2, World.scan(solo)))[LINEN].bank == 300)
    main = session(saved, MAIN_GUID, "Main Goldtooth", 5)
    T.eq("its bank is not offered either", (linenOf(main)), 5)
end)

-- ===========================================================================
-- An item moves between the bags and the bank and the window closes in the
-- same frame. What is owned (105 linen: 5 carried, 100 in the bank) must come
-- out of the scan afterwards, not 165 and not 100.
-- ===========================================================================
T.section("a bank change in the frame the window closes", function()
    -- A settled visit: 5 linen carried, 100 in the bank, 50 bars in the account bank.
    local function visit()
        World.reset()
        World.containers = {
            [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) },
            [6] = { slots = 28, slot(LINEN, 100) },
            [15] = { slots = 98, slot(BAR, 50) },
        }
        World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
        local addon = World.login({})
        World.advance(3)
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(3)
        return addon
    end
    local function linen(addon)
        local combined, breakdown = World.scan(addon)
        local where = breakdown[LINEN] or {}
        return combined[LINEN], where.bags, where.bank
    end
    local function withdraw60()
        World.containers[6][1] = slot(LINEN, 40)
        World.containers[0][3] = slot(LINEN, 60)
    end
    local function closedUpdates(addon)
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return (table.concat(lines, "\n"):match("bank updates while closed: [^\n]*"))
    end

    -- Before any visit: a bank container's update that arrives is counted as such.
    World.reset()
    local addon = World.login({})
    T.eq("a session without one says none", closedUpdates(addon), "bank updates while closed: 0")
    World.bagUpdate(addon, 7)
    World.bagUpdate(addon, 0)
    T.eq("one before the bank was ever opened is named as such", closedUpdates(addon),
        "bank updates while closed: 1, before the bank was opened this session")

    addon = visit()
    local total, bags, bank = linen(addon)
    T.check("settled: 5 carried, 100 in the bank", total == 105 and bags == 5 and bank == 100, total)

    -- Withdraw 60; both updates and the close arrive in one frame.
    addon = visit()
    withdraw60()
    World.bagUpdate(addon, 6, 0)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("withdraw and close in one frame: 65 carried, 40 in the bank", total == 105 and bags == 65 and bank == 40,
        tostring(total) .. " = " .. tostring(bags) .. " + " .. tostring(bank))
    T.eq("nothing arrived after the close", closedUpdates(addon), "bank updates while closed: 0")

    -- The same, the backpack's update first (the bank's contents change with the second).
    addon = visit()
    World.containers[0][3] = slot(LINEN, 60)
    World.bagUpdate(addon, 0)                 -- read at once: the bank still shows 100
    World.containers[6][1] = slot(LINEN, 40)
    World.bagUpdate(addon, 6)                 -- owed
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("the bank's change comes with the second update: taken at the close", total == 105 and bank == 40,
        tostring(total) .. " bank " .. tostring(bank))

    -- The window closes first; the client reports the change afterwards.
    -- It cannot be read any more: the remembered bank stays, and the dump
    -- counts the updates so that one paste shows whether the client does this.
    addon = visit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.nextFrame()
    withdraw60()
    World.bagUpdate(addon, 6, 0)
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("the change reported after the close: the remembered bank is kept as it was", bank == 100 and bags == 65,
        tostring(bags) .. " + " .. tostring(bank))
    T.eq("and the bank-container update is counted", closedUpdates(addon), "bank updates while closed: 1, last 0.0 s after closing")

    -- Deposit the 5 carried linen; closed in the same frame.
    addon = visit()
    World.containers[6][2] = slot(LINEN, 5)
    World.containers[0][2] = nil
    World.bagUpdate(addon, 0, 6)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("deposit and close in one frame: nothing carried, 105 in the bank", total == 105 and bags == nil and bank == 105,
        tostring(total) .. " = " .. tostring(bags) .. " + " .. tostring(bank))

    -- The control: one frame between the withdrawal and the close.
    addon = visit()
    withdraw60()
    World.bagUpdate(addon, 6, 0)
    World.nextFrame()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("a frame between the withdrawal and the close", total == 105 and bags == 65 and bank == 40, total)

    -- From the character bank into the account bank, closed in the same frame.
    addon = visit()
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[15][2] = slot(LINEN, 60)
    World.bagUpdate(addon, 6, 15)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("bank to account bank and close in one frame", total == 105 and bags == 5 and bank == 100, total)
    T.eq("of which 60 in the account bank", (addon.StockMemory:AccountBank("eu-pvp"))[LINEN], 60)

    -- The read taken at the close is kept only when it looks like the reads of
    -- the visit. Here the client has let go of the bank by the time of the
    -- close: the first read of the frame (65 carried, 40 banked) stands.
    local function closeWith(letGo)
        addon = visit()
        withdraw60()
        World.bagUpdate(addon, 6, 0)          -- read at once (40), one more owed
        letGo()
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(5)
        return (addon.StockMemory:OwnBank(MAIN_GUID))[LINEN]
    end
    T.eq("the bank reads as empty at the close: not kept", closeWith(function() World.containers[6] = { slots = 28 } end), 40)
    T.eq("the bank reads with fewer slots at the close: not kept",
        closeWith(function() World.containers[6] = { slots = 12, slot(LINEN, 7) } end), 40)
    T.eq("the bank may not be viewed at the close: not kept",
        closeWith(function() World.bank[0].canView = false; World.containers[6][1] = slot(LINEN, 7) end), 40)
    T.eq("the bank is locked at the close: not kept",
        closeWith(function() World.bank[0].locked = 2; World.containers[6][1] = slot(LINEN, 7) end), 40)
    T.eq("the bank has no tabs at the close: not kept",
        closeWith(function() World.bank[0].tabs = {}; World.containers[6][1] = slot(LINEN, 7) end), 40)
    T.eq("(a further change with everything in place is kept)",
        closeWith(function() World.containers[6][1] = slot(LINEN, 7) end), 7)

    -- A bank sort: eighteen bank-container updates in one frame read the bank at most twice.
    addon = visit()
    local reads = 0
    local real = addon.Client.BankContents
    addon.Client.BankContents = function(self, kind)
        if kind == "character" then reads = reads + 1 end
        return real(self, kind)
    end
    for _ = 1, 18 do World.bagUpdate(addon, 6) end
    T.eq("eighteen updates in a frame: one read at once", reads, 1)
    World.advance(5)
    T.eq("and one more on the next frame", reads, 2)
end)

-- ===========================================================================
-- What a bank visit starts with.
-- ===========================================================================
T.section("opening the bank", function()
    local function start(containers, bank)
        World.reset()
        World.containers, World.bank = containers, bank
        local addon = World.login({})
        World.advance(3)
        return addon
    end
    local function bankOf(addon)
        return addon.StockMemory:OwnBank(MAIN_GUID)
    end

    -- The first visit ever: no tab is bought when the window opens; the bank
    -- window buys the first one, and the client reports the change of tabs.
    local addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } }, { [0] = { tabs = {} } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    T.check("no tab yet: nothing to remember", bankOf(addon) == nil)
    World.bank[0].tabs = { { ID = 6 } }
    World.event(addon, "BANK_TABS_CHANGED", 0)
    T.check("the first tab is bought while the window is open: the bank is remembered",
        bankOf(addon) ~= nil and (bankOf(addon))[LINEN] == 100)
    -- A change of the guild bank's tabs is not ours.
    World.nextFrame()
    World.containers[6][1] = slot(LINEN, 90)
    World.event(addon, "BANK_TABS_CHANGED", 1)
    T.eq("a change of another bank's tabs reads nothing", (bankOf(addon))[LINEN], 100)

    -- The tabs are there but the bank cannot be read at the moment of opening;
    -- it can a moment later, and no event says so.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } },
        { [0] = { tabs = { { ID = 6 } }, locked = 1 } })
    World.event(addon, "BANKFRAME_OPENED")
    T.check("locked at opening: nothing remembered yet", bankOf(addon) == nil)
    World.bank[0].locked = nil
    World.advance(5)
    T.check("readable a moment later, without an event: remembered", bankOf(addon) ~= nil and (bankOf(addon))[LINEN] == 100)

    -- Part of the bank is there when the window opens; the rest follows without an event.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) }, [8] = { slots = 12 } },
        { [0] = { tabs = { { ID = 6 }, { ID = 8 } } } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(0.2)
    World.containers[8][1] = slot(SILK, 30)
    World.advance(5)
    World.event(addon, "BANKFRAME_CLOSED")
    local items = bankOf(addon)
    T.check("a part that arrives late without an event is remembered", items[LINEN] == 100 and items[SILK] == 30, items[SILK])

    -- With the bank open, a withdrawal is reported for the backpack only.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } }, { [0] = { tabs = { { ID = 6 } } } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][2] = slot(LINEN, 60)
    World.bagUpdate(addon, 0)
    T.eq("an update of a carried bag alone reads the open bank", (bankOf(addon))[LINEN], 40)

    -- A bank that is empty: remembered as seen, with nothing in it, once it can be believed.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28 } }, { [0] = { tabs = { { ID = 6 } } } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(1.5)
    T.check("an empty bank: not remembered before two seconds", bankOf(addon) == nil)
    World.advance(1)
    T.check("an empty bank: remembered as empty after two seconds", bankOf(addon) ~= nil and next((bankOf(addon))) == nil)

    -- A remembered bank is not emptied by an early read that finds nothing.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } } }
    local saved = {}
    addon = World.login(saved)
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.containers[6] = { slots = 28 }           -- the next visit: the items are late
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(0.6)
    T.eq("an empty read half a second after opening does not empty the remembered bank", (bankOf(addon))[LINEN], 100)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    T.eq("closed before it could be believed: the remembered bank stays", (bankOf(addon))[LINEN], 100)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(2.1)
    T.check("an empty read two seconds after opening does", next((bankOf(addon))) == nil)
end)

-- ===========================================================================
-- Two characters of one account: what the first one holds reaches the second.
-- ===========================================================================
T.section("two characters", function()
    local THREAD, WOOL, HERB = 2320, 2592, 765
    local DAY = 86400
    local saved = {}
    World.reset()
    World.guid, World.name = "Player-4444-000000AA", "Banker Goldtooth"
    -- Thread in the reagent bag, a soulbound hearthstone, linen in the bank.
    World.containers = {
        [0] = { slots = 16, slot(LINEN, 20), slot(HEARTHSTONE, 1, true) },
        [5] = { slots = 32, slot(THREAD, 40) },
        [6] = { slots = 28, slot(LINEN, 100), slot(SILK, 30) },
        [8] = { slots = 12, slot(WOOL, 10, true) },
        [15] = { slots = 98, slot(BAR, 50) },
    }
    World.bank = { [0] = { tabs = { { ID = 6 }, { ID = 8 } } }, [2] = { tabs = { { ID = 15 } } } }
    local banker = World.login(saved)
    local memory = banker.StockMemory
    local bankReads = 0
    local realContents = banker.Client.BankContents
    banker.Client.BankContents = function(self, kind)
        bankReads = bankReads + 1
        return realContents(self, kind)
    end
    World.advance(3)
    local summary = memory:Summary()
    T.check("after login the character's bags are remembered",
        #summary.characters == 1 and summary.characters[1].name == "Banker Goldtooth"
        and summary.characters[1].world == "eu-pvp" and summary.characters[1].bagItems == 3, summary.characters[1] and summary.characters[1].bagItems)
    T.check("the bank is not remembered before it was opened", memory:OwnBank(World.guid) == nil)
    T.eq("and was not asked for", bankReads, 0)
    local combined, breakdown, meta = World.scan(banker)
    T.check("closed bank: only the bags count, the reagent bag among them",
        combined[LINEN] == 20 and combined[THREAD] == 40 and combined[SILK] == nil and meta.bankSeenAt == nil)

    -- At the bank.
    World.event(banker, "BANKFRAME_OPENED")
    World.advance(3)
    combined, breakdown, meta = World.scan(banker)
    T.check("bank open: its tabs count as bank stock", breakdown[LINEN].bank == 100 and breakdown[SILK].bank == 30
        and breakdown[WOOL].bank == 10)
    T.check("bank open: the account bank counts as bank stock too", breakdown[BAR].bank == 50 and meta.accountSeenAt == World.serverTime)
    T.check("bank open: seen now", meta.bankSeenAt == World.serverTime)

    -- Take 60 linen out and leave. What is remembered - not a scan of the
    -- open bank - must hold the withdrawal.
    World.nextFrame()
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][3] = slot(LINEN, 60)
    World.bagUpdate(banker, 6, 0)
    World.nextFrame()
    World.event(banker, "BANKFRAME_CLOSED")
    T.eq("the withdrawal is in the memory after the close", (memory:OwnBank(World.guid))[LINEN], 40)
    combined, breakdown = World.scan(banker)
    T.check("a withdrawal is counted once", combined[LINEN] == 120 and breakdown[LINEN].bags == 80 and breakdown[LINEN].bank == 40,
        combined[LINEN])

    -- After the close the bank's containers may read as empty. Nothing may
    -- ask the adapter for the bank any more, whatever arrives.
    World.containers[6] = { slots = 28 }
    World.containers[8] = { slots = 12 }
    World.containers[15] = { slots = 98 }
    bankReads = 0
    World.bagUpdate(banker, 6, 0)
    World.advance(5)
    combined, breakdown, meta = World.scan(banker)
    T.eq("after the close the bank is not asked for again", bankReads, 0)
    T.check("after the close the bank is what was seen while it was open",
        breakdown[LINEN].bank == 40 and breakdown[SILK].bank == 30 and breakdown[BAR].bank == 50, breakdown[LINEN].bank)
    -- A visit so short that its second look is still waiting when the window
    -- closes: that look must not be taken from the closed bank.
    World.event(banker, "BANKFRAME_OPENED")
    World.advance(0.2)
    World.event(banker, "BANKFRAME_CLOSED")
    bankReads = 0
    World.advance(5)
    T.eq("a look that was still waiting is not taken after the close", bankReads, 0)
    T.eq("and the short visit that found nothing changed nothing", (memory:OwnBank(World.guid))[LINEN], 40)

    -- Loot just before logging out: the waiting save is written at logout.
    World.containers[0][4] = slot(HERB, 7)
    World.bagUpdate(banker, 0)
    World.event(banker, "PLAYER_LOGOUT")

    -- Two days later, the crafter of the same world and faction.
    local later = World.serverTime + 2 * DAY
    World.reset()
    World.serverTime = later
    World.guid, World.name = "Player-4444-000000BB", "Crafter Goldtooth"
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    local crafter = World.login(saved)
    World.advance(3)
    combined, breakdown, meta = World.scan(crafter)
    local alt = breakdown[LINEN].alts and breakdown[LINEN].alts["Banker Goldtooth"]
    T.check("the other character is an alt: its bags and its bank", alt ~= nil and alt.bags == 80 and alt.bank == 40,
        alt and (tostring(alt.bags) .. "/" .. tostring(alt.bank)))
    T.check("what it looted last is there (saved at logout)", breakdown[HERB] ~= nil and breakdown[HERB].alts["Banker Goldtooth"].bags == 7)
    T.check("its reagent bag is there", breakdown[THREAD].alts["Banker Goldtooth"].bags == 40)
    T.check("its soulbound items are not offered", combined[HEARTHSTONE] == nil and combined[WOOL] == nil)
    T.check("the account bank is this character's bank stock", breakdown[BAR].bank == 50 and breakdown[BAR].alts == nil)
    T.check("own bags are live", breakdown[LINEN].bags == 5)
    T.check("total linen: 5 carried, 80 + 40 on the alt", combined[LINEN] == 125, combined[LINEN])
    T.check("ages: the alt was seen two days ago, its bank too",
        crafter.StockMemory.AgeText(World.serverTime, meta.alts["Banker Goldtooth"].bags) == "2 days ago"
        and crafter.StockMemory.AgeText(World.serverTime, meta.alts["Banker Goldtooth"].bank) == "2 days ago"
        and crafter.StockMemory.AgeText(World.serverTime, meta.accountSeenAt) == "2 days ago")
    T.check("this character's own bank was never seen", meta.bankSeenAt == nil)

    -- Self-Found: nothing of the others.
    crafter.db.char.selfFoundMode = true
    combined = World.scan(crafter)
    T.check("Self-Found: only what the character carries", combined[LINEN] == 5 and combined[BAR] == nil and combined[THREAD] == nil)
    crafter.db.char.selfFoundMode = false

    -- The saved table: one record per character, a format number, plain data.
    T.check("saved: format 1, two characters, one account bank", saved.stock.schema == 1
        and saved.stock.characters["Player-4444-000000AA"] ~= nil
        and saved.stock.characters["Player-4444-000000BB"] ~= nil
        and saved.stock.account["eu-pvp"] ~= nil)
end)

T.finish()
