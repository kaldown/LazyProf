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
        { "an account bank that is true", function() return { schema = 1, characters = {}, account = { eu = true } } end, 5 },
        { "a name that is a number", function() return { schema = 1, characters = { X = (function() local r = goodAlt(); r.name = 12; return r end)(),
            Y = goodAlt() }, account = {} } end, 25 },
        { "seen is a string", function() return with(function(r) r.seen = "yesterday" end) end, 5 },
        { "a part without a time", function() return with(function(r) r.bags.at = nil end) end, 5 },
        { "a part whose time is far ahead", function() return with(function(r) r.bags.at = 1e300 end) end, 5 },
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

    -- Before the first save a saved stock that is not a table is still this
    -- version's format, with nothing in it: the dump must not call it another.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    local addon = World.login({ stock = "broken" })
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    local text = "\n" .. table.concat(lines, "\n") .. "\n"
    T.check("a saved stock that is text, before the first save: the dump reads it as empty, not as another format",
        text:find("\nmemory: format=1 characters=0 accountBanks=0 ", 1, true) ~= nil
        and not text:find("not a format this version reads", 1, true), text)
end)

-- ===========================================================================
-- Dropping old characters at login must not take a good account bank with it
-- because the characters beside it could not be read.
-- ===========================================================================
T.section("damaged characters beside a good account bank", function()
    local function login(characters)
        World.reset()
        World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
        local saved = { stock = { schema = 1, characters = characters,
            account = { eu = { items = { [BAR] = 50 }, at = World.serverTime - 100, world = "eu-pvp", faction = "Horde" } } } }
        local addon = World.login(saved)
        return addon, saved
    end
    local addon, saved = login("cut off")
    T.check("right after login the account bank is still there", type(saved.stock.account.eu) == "table")
    World.advance(3)
    T.eq("and it counts once the character is remembered again", (World.scan(addon))[BAR], 50)
    addon, saved = login({ [MAIN_GUID] = { name = "Main Goldtooth", faction = "Horde", seen = World.serverTime - 100 } })
    T.check("a record without a region: the account bank is kept", type(saved.stock.account.eu) == "table")
    World.advance(3)
    T.eq("and counts", (World.scan(addon))[BAR], 50)
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

    -- The player sees the first failure of a session: it is handed to the
    -- game's error handler, once. (The debug log gets it too, but that log
    -- drops everything while debugging is off, which is the default.)
    T.eq("the first failure is handed to the game's error handler, later ones are not", #World.errors, 1)
    T.check("it says whose it is, where it happened and what failed",
        World.errors[1] ~= nil and World.errors[1]:find("LazyProf", 1, true) ~= nil
        and World.errors[1]:find("(start)", 1, true) ~= nil and World.errors[1]:find("IsGameRuleActive", 1, true) ~= nil,
        World.errors[1])
    local logged = 0
    for _, line in ipairs(addon.debugLines) do
        if line:find("IsGameRuleActive", 1, true) then logged = logged + 1 end
    end
    T.eq("the reason is logged once, not at every call", logged, 1)
    -- The dump: the last failure, where, how many, and what a scan does now.
    local function dump()
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return table.concat(lines, "\n")
    end
    World.nextFrame()
    World.scan(addon)                              -- the last failure of the lot: a scan
    local text = dump()
    local where, howMany = text:match("last error: [^\n]*%(in: ([%a ]+); (%d+) this session")
    T.check("the dump names the last failure and where it happened", text:find("last error:", 1, true) ~= nil
        and text:find("IsGameRuleActive", 1, true) ~= nil and where == "scan", text)
    -- The error itself, not only where it happened: the line before "(in:".
    local said = text:match("last error: (.-) %(in: [%a ]+; %d+ this session")
    T.check("the last error line gives the error itself", said ~= nil and said:find("IsGameRuleActive", 1, true) ~= nil
        and said ~= where, text)
    T.check("and how many there were", tonumber(howMany) ~= nil and tonumber(howMany) > 3, howMany)
    T.check("and that a scan right now counts the bags only",
        text:find("scan now: bags only - the memory cannot be read: ", 1, true) ~= nil
        and not text:find("scan now: the memory reads", 1, true), text)
    local before = tonumber(howMany)
    dump()
    T.eq("the dump itself counts no failure", tonumber((dump():match("; (%d+) this session"))), before)

    -- Once the call works again, so does the memory - and the dump says so,
    -- while the failure stays on record.
    _G.C_GameRules.IsGameRuleActive = realRule
    World.nextFrame()
    combined = World.scan(addon)
    T.eq("the call works again: the alt counts", combined[LINEN], 25)
    text = dump()
    T.check("the dump: the memory reads again", text:find("scan now: the memory reads without error\n", 1, true) ~= nil
        and not text:find("scan now: bags only", 1, true), text)
    T.check("the dump: the failure is still on record", text:find("last error:", 1, true) ~= nil
        and tonumber((text:match("; (%d+) this session"))) == before, text)
    T.check("nothing says stock is left out while it is counted", not text:find("not counted while it lasts", 1, true), text)
    T.eq("no second report to the error handler", #World.errors, 1)

    -- A healthy session has no error to show.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    addon = World.login({}, { init = true })
    addon:OnEnable()
    World.advance(3)
    text = dump()
    T.check("a healthy session: no error line", not text:find("last error", 1, true))
    T.check("a healthy session: the memory reads", text:find("scan now: the memory reads without error\n", 1, true) ~= nil, text)
    T.eq("a healthy session: nothing logged", #addon.debugLines, 0)
    T.eq("a healthy session: nothing handed to the error handler", #World.errors, 0)

    -- One failure, long over: the dump must not say that stock is left out.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    addon = World.login({ stock = { schema = 1, characters = { X = { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde",
        seen = World.serverTime, bags = { items = { [LINEN] = 20 }, at = World.serverTime } } }, account = {} } })
    local realInfo = _G.C_Container.GetContainerItemInfo
    local failOnce = true
    _G.C_Container.GetContainerItemInfo = function(bag, index)
        if failOnce then failOnce = false; error("boom") end
        return realInfo(bag, index)
    end
    ok, err = pcall(World.advance, 3)             -- the first bag save fails
    _G.C_Container.GetContainerItemInfo = realInfo
    T.check("a failing bag save does not raise", ok, err)
    World.bagUpdate(addon, 0)
    World.advance(600)
    T.eq("ten minutes later bank and alts are counted", (World.scan(addon))[LINEN], 25)
    text = dump()
    T.check("the dump names that one failure", text:find("(in: bag save; 1 this session", 1, true) ~= nil, text)
    T.check("and says that the memory reads", text:find("scan now: the memory reads without error\n", 1, true) ~= nil, text)
    T.check("the later save went through (no flag was left set)",
        addon.db.global.stock.characters[MAIN_GUID] ~= nil and addon.db.global.stock.characters[MAIN_GUID].bags ~= nil
        and text:find("bagSave=false", 1, true) ~= nil, text)
    T.eq("that failure was shown once", #World.errors, 1)

    -- A client without an error handler, or one whose handler fails itself:
    -- the memory still never stops the addon.
    for _, case in ipairs({
        { "no error handler", nil },
        { "an error handler that is not a function", function() return "broken" end },
        { "an error handler that fails", function() return function() error("handler down") end end },
        { "asking for the error handler fails", function() error("no handler today") end },
    }) do
        World.reset()
        World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
        local savedHandler = _G.geterrorhandler
        _G.geterrorhandler = case[2]
        addon = World.login({})
        _G.C_GameRules.IsGameRuleActive = function() error("bad argument") end
        ok, err = pcall(function()
            World.advance(3)
            combined = World.scan(addon)
        end)
        _G.C_GameRules.IsGameRuleActive = realRule
        _G.geterrorhandler = savedHandler
        T.check(case[1] .. ": a failure in the memory still does not raise", ok, err)
        T.eq(case[1] .. ": the bags are counted", combined and combined[LINEN], 5)
    end
end)

-- ===========================================================================
-- A scan whose memory part fails half way hands out the live bags and nothing
-- of what it had added before the failure.
-- ===========================================================================
T.section("a scan that fails half way", function()
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    local now = World.serverTime
    local addon = World.login({ stock = { schema = 1, account = { eu = { items = { [BAR] = 50 }, at = now, world = "eu-pvp", faction = "Horde" } },
        characters = {
            [MAIN_GUID] = { name = "Main Goldtooth", world = "eu-pvp", faction = "Horde", seen = now,
                bank = { items = { [LINEN] = 100, [SILK] = 30 }, at = now } },
            X = { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde", seen = now, bags = { items = { [LINEN] = 20 }, at = now } },
        } } })
    World.advance(3)
    T.eq("healthy: bags, bank and alt", (World.scan(addon))[LINEN], 125)
    local realAlts = addon.StockMemory.Alts
    addon.StockMemory.Alts = function() error("alts cannot be read") end     -- fails after the banks were added
    addon.Inventory:ForgetAltsPart()
    World.nextFrame()
    local combined, breakdown, meta = World.scan(addon)
    addon.StockMemory.Alts = realAlts
    T.check("only the live bags come out", combined[LINEN] == 5 and count(combined) == 1, combined[LINEN])
    T.check("nothing of the bank that was added before the failure", combined[SILK] == nil and combined[BAR] == nil
        and breakdown[LINEN].bank == nil and breakdown[SILK] == nil)
    T.check("and no age of anything", meta ~= nil and meta.remembered == true and meta.bankSeenAt == nil
        and meta.accountSeenAt == nil and next(meta.alts) == nil)
    World.nextFrame()
    T.eq("the next scan is whole again", (World.scan(addon))[LINEN], 125)
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
-- The game has a Self-Found flag of its own. A character it marks is
-- Self-Found for stock whatever the addon's setting says: nothing of the
-- other characters is counted for it, and what it holds is not offered to
-- them.
-- ===========================================================================
T.section("a character the game itself marks Self-Found", function()
    local SOLO_GUID = "Player-4444-000000SF"
    local function session(saved, guid, name, linen, gameFlag, opts)
        World.reset()
        World.guid, World.name = guid, name
        World.gameSelfFound = gameFlag
        World.containers = { [0] = { slots = 16, slot(LINEN, linen) } }
        local addon = World.login(saved, opts)
        World.advance(3)
        return addon
    end
    local function dump(addon)
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return table.concat(lines, "\n")
    end

    -- The flag on, the setting at its default (off).
    local saved = {}
    local solo = session(saved, SOLO_GUID, "Solo Goldtooth", 20, true)
    T.check("fixture: the addon's own setting is off", solo.db.char.selfFoundMode == false)
    T.check("its record says that it cannot send", saved.stock.characters[SOLO_GUID] ~= nil
        and saved.stock.characters[SOLO_GUID].noSend == true)
    World.event(solo, "PLAYER_LOGOUT")
    T.check("and still does after logout", saved.stock.characters[SOLO_GUID].noSend == true)

    local main = session(saved, MAIN_GUID, "Main Goldtooth", 1, false)
    local combined, breakdown = World.scan(main)
    T.eq("nothing of it is counted for the other character", combined[LINEN], 1)
    T.check("which names no alt", breakdown[LINEN].alts == nil)
    T.check("the other character's dump says why",
        dump(main):find("character: Solo Goldtooth [not counted (Self-Found)]", 1, true) ~= nil, dump(main))
    World.event(main, "PLAYER_LOGOUT")

    saved.stock.accounteu = { items = { [BAR] = 50 }, at = World.serverTime, world = "eu-pvp", faction = "Horde" }
    solo = session(saved, SOLO_GUID, "Solo Goldtooth", 20, true)
    local meta
    combined, breakdown, meta = World.scan(solo)
    T.eq("nothing of the others is counted for it", combined[LINEN], 20)
    T.check("no alt is named, and the account bank is other characters' stock too",
        breakdown[LINEN].alts == nil and next(meta.alts) == nil and combined[BAR] == nil and meta.accountSeenAt == nil)
    local text = dump(solo)
    T.check("its dump prints the setting and the game's flag apart",
        text:find("settings: bank=true alts=true guildBank=false selfFound=false gameSelfFound=true", 1, true) ~= nil, text)
    T.check("and labels the other character for it",
        text:find("character: Main Goldtooth [not counted (this character is Self-Found)]", 1, true) ~= nil, text)
    -- Its own bank is its own stock, and is saved as not to be sent.
    World.containers[6] = { slots = 28, slot(LINEN, 300) }
    World.bank = { [0] = { tabs = { { ID = 6 } } } }
    World.event(solo, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(solo, "BANKFRAME_CLOSED")
    World.advance(11)
    T.eq("its own bank still counts for it", (World.scan(solo))[LINEN], 320)
    World.event(solo, "PLAYER_LOGOUT")
    main = session(saved, MAIN_GUID, "Main Goldtooth", 1, false)
    T.eq("the other character is offered neither its bags nor its bank", (World.scan(main))[LINEN], 1)
    World.event(main, "PLAYER_LOGOUT")

    -- The flag is gone (the mode was given up): the next save says so.
    solo = session(saved, SOLO_GUID, "Solo Goldtooth", 20, false)
    T.check("without the flag its next save says that it can send", saved.stock.characters[SOLO_GUID].noSend == nil)
    T.eq("and the others count for it again", (World.scan(solo))[LINEN], 321)
    World.event(solo, "PLAYER_LOGOUT")
    main = session(saved, MAIN_GUID, "Main Goldtooth", 1, false)
    T.eq("as it does for them, bank included", (World.scan(main))[LINEN], 321)
    World.event(main, "PLAYER_LOGOUT")

    -- The flag off and the setting on: as it always was.
    solo = session(saved, SOLO_GUID, "Solo Goldtooth", 20, false, { selfFound = true })
    T.check("flag off, setting on: the record says it cannot send", saved.stock.characters[SOLO_GUID].noSend == true)
    T.eq("flag off, setting on: only its own stock counts for it", (World.scan(solo))[LINEN], 320)
    text = dump(solo)
    T.check("flag off, setting on: the dump prints both",
        text:find("settings: bank=true alts=true guildBank=false selfFound=true gameSelfFound=false", 1, true) ~= nil, text)
    T.eq("nothing in all of this was handed to the game's error handler", #World.errors, 0)
end)

-- ===========================================================================
-- /lp diag stock prints what the client itself counts of the remembered bank
-- beside what is remembered. Whether the client's count sees a bank while its
-- window is closed is not known: these lines, pasted from a dump taken away
-- from the bank, settle it. Nothing else uses the count.
-- ===========================================================================
T.section("the stock dump: what the client itself counts", function()
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100), slot(SILK, 7) },
                         [15] = { slots = 98, slot(LINEN, 60) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
    local saved = {}
    local addon = World.login(saved, { init = true })
    addon:OnEnable()
    World.advance(3)
    local shown
    addon.ShowDiagnosticOutput = function(_, text) shown = text end
    local function dump()
        shown = nil
        addon:RunStockDiagnostic()
        return "\n" .. tostring(shown) .. "\n"
    end
    T.check("before the bank was ever open: nothing to compare",
        dump():find("\nclient count: nothing remembered of this bank to compare\n", 1, true) ~= nil, shown)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(11)
    local text = dump()
    -- A client that counts the banks while their window is closed.
    T.check("a client that counts the closed banks: the difference is the remembered bank",
        text:find("\nclient count 2589: carried=5 withBank=105 withAccountBank=165; remembered: bags now=5 bank=100 accountBank=60\n",
            1, true) ~= nil, shown)
    T.check("an item of the character bank alone",
        text:find("\nclient count 4306: carried=0 withBank=7 withAccountBank=7; remembered: bags now=0 bank=7 accountBank=0\n",
            1, true) ~= nil, shown)
    -- A client that does not.
    World.countsBank = false
    T.check("a client that does not count them: the three numbers are the same",
        dump():find("\nclient count 2589: carried=5 withBank=5 withAccountBank=5; remembered: bags now=5 bank=100 accountBank=60\n",
            1, true) ~= nil, shown)
    World.countsBank = true
    -- The count is only printed: a scan counts what is remembered, as before.
    local calls = 0
    local realCount = _G.C_Item.GetItemCount
    _G.C_Item.GetItemCount = function(...)
        calls = calls + 1
        return realCount(...)
    end
    World.bagUpdate(addon, 0)
    World.advance(3)
    T.eq("a scan counts bags, bank and account bank from what is remembered", (World.scan(addon))[LINEN], 165)
    T.eq("and nothing but the dump asks the client for its count", calls, 0)
    -- A count call that fails is said in the dump, and the rest of it stays.
    _G.C_Item.GetItemCount = function() error("count down") end
    text = dump()
    _G.C_Item.GetItemCount = realCount
    T.check("a failing count call: a section error in its place", text:find("\nSECTION ERROR: client count: ", 1, true) ~= nil
        and text:find("count down", 1, true) ~= nil, shown)
    T.check("and what is remembered is still listed",
        text:find("\nmemory: format=1 characters=1 accountBanks=1 ", 1, true) ~= nil
        and text:find("\ncharacter: Main Goldtooth [this character] ", 1, true) ~= nil
        and text:find("\naccount bank: region=eu read by world=eu-pvp faction=Horde items=1 ", 1, true) ~= nil, shown)
    T.eq("the dump's own failure is no failure of the memory: nothing is handed to the game's error handler", #World.errors, 0)
    -- The adapter's part: whether crafts may take reagents from the bank,
    -- as the profession window asks it, and the game rule beside it.
    text = dump()
    T.check("the adapter's part: crafting from the bank, in one line",
        text:find("\ncrafting from the bank: reagentsFromBankAllowed=false restrictedRule=false\n", 1, true) ~= nil, shown)
    World.reagentsFromBank = true
    T.check("a client that lets crafts take reagents from the bank says so",
        dump():find("\ncrafting from the bank: reagentsFromBankAllowed=true restrictedRule=false\n", 1, true) ~= nil, shown)
    World.reagentsFromBank = false
    T.check("and no section of the dump fails", not text:find("SECTION ERROR", 1, true), text)
end)

-- ===========================================================================
-- With Syndicator installed LazyProf does not follow the bank: the dump says
-- so in one line, at an open bank and after it, and nothing of a visit.
-- ===========================================================================
T.section("the stock dump with Syndicator installed", function()
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 1) }, [6] = { slots = 28, slot(LINEN, 10) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } } }
    _G.Syndicator = { API = { GetCurrentCharacter = function() return "Main-Shard" end,
        GetByCharacterFullName = function() return { bags = {}, bank = {} } end,
        GetAllCharacters = function() return {} end, GetCurrentGuild = function() return nil end } }
    local addon = World.login({}, { init = true })
    addon:OnEnable()
    local shown
    addon.ShowDiagnosticOutput = function(_, text) shown = text end
    local function dump()
        shown = nil
        addon:RunStockDiagnostic()
        return "\n" .. tostring(shown) .. "\n"
    end
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(1)
    World.bagUpdate(addon, 6, 0)
    World.advance(1)
    local function followed(text)
        return text:find("waiting:", 1, true) or text:find("bankOpen=", 1, true) or text:find("bank visit", 1, true)
            or text:find("after the close", 1, true) or text:find("bank updates while closed", 1, true)
            or text:find("bags at the bank", 1, true)
    end
    local text = dump()
    T.check("at an open bank: one line says the bank is not followed",
        text:find("\nbank: not followed (Syndicator is installed)\n", 1, true) ~= nil, shown)
    T.check("at an open bank: nothing of a visit, of an open bank or of what is waiting", not followed(text), shown)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(1)
    World.bagUpdate(addon, 6)
    World.advance(1)
    text = dump()
    T.check("after the close and an update of the bank's container: the same one line",
        text:find("\nbank: not followed (Syndicator is installed)\n", 1, true) ~= nil and not followed(text), shown)
    _G.Syndicator = nil
end)

-- ===========================================================================
-- A name belongs to one character of a world: the record seen last. An older
-- record of that name never counts in its place.
-- ===========================================================================
T.section("the newest record of a name decides", function()
    local now = World.serverTime
    local function linenWith(newer)
        World.reset()
        World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
        local older = { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde", seen = now - 5000,
            bags = { items = { [LINEN] = 20 }, at = now - 5000 } }
        local saved = { stock = { schema = 1, characters = { G1 = older, G2 = newer }, account = {} } }
        local addon = World.login(saved)
        World.advance(3)
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return (World.scan(addon))[LINEN], table.concat(lines, "\n")
    end
    local function record(change)
        local r = { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde", seen = now - 100,
            bags = { items = { [LINEN] = 7 }, at = now - 100 } }
        if change then change(r) end
        return r
    end
    local total, dump = linenWith(record(function(r) r.noSend = true end))
    T.eq("the newest record of the name is Self-Found: only the bags count", total, 5)
    T.check("the dump says why for both records",
        dump:find("character: Alt Goldtooth [not counted (Self-Found)]", 1, true) ~= nil
        and dump:find("character: Alt Goldtooth [not counted (an older record of this name)]", 1, true) ~= nil, dump)
    total, dump = linenWith(record(function(r) r.faction = "Alliance" end))
    T.eq("the newest record of the name is of the other faction: only the bags count", total, 5)
    T.check("the dump says so", dump:find("character: Alt Goldtooth [other faction]", 1, true) ~= nil
        and dump:find("character: Alt Goldtooth [not counted (an older record of this name)]", 1, true) ~= nil, dump)
    T.eq("the newest record of the name can send: it counts, the older one does not", (linenWith(record())), 12)
end)

-- ===========================================================================
-- The game rules that name the world can read false in the first moments
-- after login. The character must not be filed under that world for the rest
-- of the session.
-- ===========================================================================
T.section("the world is read again, not kept from login", function()
    local now = World.serverTime
    World.reset()
    World.rules = {}                               -- not there yet: the world reads as eu-normal
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    local saved = { stock = { schema = 1, account = { eu = { items = { [BAR] = 50 }, at = now - 100, world = "eu-pvp", faction = "Horde" } },
        characters = { ALT = { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde", seen = now - 100,
            bags = { items = { [LINEN] = 20 }, at = now - 100 } } } } }
    local addon = World.login(saved)
    local combined = World.scan(addon)
    T.check("while the rules read false nothing of eu-pvp counts", combined[LINEN] == 5 and combined[BAR] == nil, combined[LINEN])
    World.advance(3)
    T.eq("the first save files the character under what was read", saved.stock.characters[MAIN_GUID].world, "eu-normal")
    T.check("the start-up cleaning left the real world's account bank alone", saved.stock.account.eu ~= nil)

    World.rules = { [213] = true }                 -- the rules are there
    World.nextFrame()
    combined = World.scan(addon)
    T.eq("the alt of the real world counts as soon as the rules read true", combined[LINEN], 25)
    T.eq("and so does that world's account bank", combined[BAR], 50)
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("the dump names the world as it is now",
        table.concat(lines, "\n"):find("identity: guid=" .. MAIN_GUID .. " name=Main Goldtooth world=eu-pvp faction=Horde", 1, true) ~= nil,
        table.concat(lines, "\n"))
    World.bagUpdate(addon, 0)
    World.advance(3)
    T.eq("the next save puts the record right", saved.stock.characters[MAIN_GUID].world, "eu-pvp")

    -- Seen from the alt, the character is now one of its world.
    World.event(addon, "PLAYER_LOGOUT")
    World.reset()
    World.guid, World.name = "ALT", "Alt Goldtooth"
    World.containers = { [0] = { slots = 16, slot(LINEN, 20) } }
    local alt = World.login(saved)
    World.advance(3)
    T.eq("and its alt counts it", (World.scan(alt))[LINEN], 25)
end)

-- ===========================================================================
-- The bank. What is remembered of it is either what a read that can be
-- trusted saw, or it is marked in doubt and not counted; it is never replaced
-- by nothing on weak evidence. In every sequence below the scan must not
-- report more of an item than the player owns.
-- ===========================================================================

-- A bank visit: 5 linen carried, 100 in the bank, 50 bars in the account
-- bank; the window has been open for `openFor` seconds (3 when not given).
local function bankVisit(openFor, saved)
    World.reset()
    World.containers = {
        [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) },
        [6] = { slots = 28, slot(LINEN, 100) },
        [15] = { slots = 98, slot(BAR, 50) },
    }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
    local addon = World.login(saved or {})
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(openFor or 3)
    return addon
end

-- Counts the reads of the bank from here on (each read asks for the
-- character bank once).
local function countReads(addon)
    local reads = { n = 0 }
    local real = addon.Client.BankContents
    addon.Client.BankContents = function(self, kind)
        if kind == "character" then reads.n = reads.n + 1 end
        return real(self, kind)
    end
    return reads
end

-- What the memory holds of the character's bank: its items, and whether it
-- is marked in doubt.
local function bankOf(addon)
    local items, _, doubt = addon.StockMemory:OwnBank(MAIN_GUID)
    return items, doubt
end

-- What a scan counts of linen: in all, carried, in the bank; and the scan's
-- third return.
local function linen(addon)
    local combined, breakdown, meta = World.scan(addon)
    local where = breakdown[LINEN] or {}
    return combined[LINEN], where.bags, where.bank, meta
end

-- The linen the character really owns: carried, in the bank, in the account bank.
local function ownedLinen()
    local n = 0
    for bag, container in pairs(World.containers) do
        if bag >= 0 and bag <= 23 then
            for _, item in pairs(container) do
                if type(item) == "table" and item.itemID == LINEN then n = n + item.stackCount end
            end
        end
    end
    return n
end

-- The first row of the Shopping tab as the window would draw it from a scan
-- made now (the line that says a bank is not counted, when there is one).
local function firstShoppingRow(addon)
    if not addon.GuideViews then
        for _, path in ipairs({ "Core/Utils.lua", "Modules/Guide/Text.lua", "Modules/Guide/Views.lua" }) do
            assert(loadfile(path))("LazyProf", addon)
        end
    end
    local _, _, meta = World.scan(addon)
    local rows = addon.GuideViews.Shopping({ path = {}, missing = { rows = {} }, stockMeta = meta, now = World.serverTime })
    return rows[1] and rows[1].text
end

local NOT_COUNTED = "Your bank and the account bank are not counted: they may have changed after LazyProf last read them. "
    .. "They count again once they are read at the bank."
local BANK_NOT_COUNTED_LINE = "Your bank is not counted: it may have changed after LazyProf last read it. Open the bank to count it again."

-- A scan never counts more linen than is owned.
local function notOver(label, addon)
    local total = linen(addon) or 0
    T.check(label .. ": not more than is owned", total <= ownedLinen(), tostring(total) .. " of " .. tostring(ownedLinen()))
    return total
end

local function refuseBank()
    World.bank[0].canView = false
    World.bank[2].canView = false
end

-- 60 of the 100 banked linen go to the backpack. The four ways the client
-- may report it inside one frame.
local WITHDRAWALS = {
    { "the bank container's update first", function(addon)
        World.containers[6][1] = slot(LINEN, 40)
        World.containers[0][3] = slot(LINEN, 60)
        World.bagUpdate(addon, 6, 0)
    end },
    { "the carried bag's update first", function(addon)
        World.containers[6][1] = slot(LINEN, 40)
        World.containers[0][3] = slot(LINEN, 60)
        World.bagUpdate(addon, 0, 6)
    end },
    { "the carried bag's update first, the bank changing with the second", function(addon)
        World.containers[0][3] = slot(LINEN, 60)
        World.bagUpdate(addon, 0)
        World.containers[6][1] = slot(LINEN, 40)
        World.bagUpdate(addon, 6)
    end },
    { "the bank container's update first, the bags changing with the second", function(addon)
        World.containers[6][1] = slot(LINEN, 40)
        World.bagUpdate(addon, 6)
        World.containers[0][3] = slot(LINEN, 60)
        World.bagUpdate(addon, 0)
    end },
}

-- ===========================================================================
T.section("when the open bank is read", function()
    -- The opening: at once, and again half a second later.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) }, [15] = { slots = 98, slot(BAR, 50) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
    local addon = World.login({})
    World.advance(3)
    local reads = countReads(addon)
    World.event(addon, "BANKFRAME_OPENED")
    T.eq("read at once when the window opens", reads.n, 1)
    T.check("the adapter counts the bank as open by then: that read is not refused",
        bankOf(addon) ~= nil and (bankOf(addon))[LINEN] == 100)
    World.advance(0.49)
    T.eq("not again before half a second", reads.n, 1)
    World.advance(0.02)
    T.eq("again half a second after the opening, whatever the first read gave", reads.n, 2)
    World.advance(1.4)
    T.eq("not again before two seconds", reads.n, 2)
    World.advance(0.2)
    T.eq("and once more two seconds after the opening, whatever the reads before it gave", reads.n, 3)
    World.advance(5)
    T.eq("a bank that read with items every time is not looked at again", reads.n, 3)

    -- A bank that was refused: looked at once more two seconds after the
    -- opening, also when the other bank read well.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) }, [15] = { slots = 98, slot(BAR, 50) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } }, canView = false } }
    addon = World.login({})
    World.advance(3)
    reads = countReads(addon)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(0.6)
    T.eq("one bank refused: the two reads of every opening", reads.n, 2)
    World.bank[2].canView = true
    World.advance(1.3)
    T.check("just before two seconds: no further read, the refused bank not remembered",
        reads.n == 2 and addon.StockMemory:AccountBank("eu") == nil, reads.n)
    World.advance(0.2)
    T.eq("a refused read asks for the look two seconds after the opening", reads.n, 3)
    T.check("which remembers the bank that can be read by then", (addon.StockMemory:AccountBank("eu") or {})[BAR] == 50)
    World.advance(5)
    T.eq("and then no more", reads.n, 3)

    -- A change while the window is open: read at once when the last read is
    -- 0.2 s or more ago, else one trailing read 0.2 s after the last read.
    addon = bankVisit()
    reads = countReads(addon)
    World.containers[6][1] = slot(LINEN, 90)
    World.bagUpdate(addon, 6)
    T.eq("an update long after the last read: read at once", reads.n, 1)
    T.eq("and remembered at once", (bankOf(addon))[LINEN], 90)
    World.nextFrame()
    World.containers[6][1] = slot(LINEN, 80)
    local timers = #World.timers
    World.bagUpdate(addon, 6)
    T.eq("an update one frame after a read: not read at once", reads.n, 1)
    T.eq("one trailing read is asked for", #World.timers, timers + 1)
    for _ = 1, 5 do World.bagUpdate(addon, 6, 7) end
    T.eq("more updates meanwhile: still no read", reads.n, 1)
    T.eq("and no further timer", #World.timers, timers + 1)
    World.advance(0.15)
    T.eq("not before 0.2 s after the last read", reads.n, 1)
    World.advance(0.05)
    T.eq("one trailing read 0.2 s after the last read", reads.n, 2)
    T.eq("which sees what the updates left", (bankOf(addon))[LINEN], 80)
    World.advance(5)
    T.eq("and nothing after it", reads.n, 2)
    -- The trailing read can be asked for again in the same visit.
    World.containers[6][1] = slot(LINEN, 70)
    World.bagUpdate(addon, 6)
    T.eq("later: read at once again", reads.n, 3)
    World.nextFrame()
    World.containers[6][1] = slot(LINEN, 60)
    World.bagUpdate(addon, 6)
    World.advance(1)
    T.check("a second trailing read in the same visit", reads.n == 4 and (bankOf(addon))[LINEN] == 60, reads.n)
    -- A change of the bank's tabs is read by the same rule.
    World.containers[6][1] = slot(LINEN, 50)
    World.event(addon, "BANK_TABS_CHANGED", 0)
    T.check("a change of the tabs long after the last read: read at once", reads.n == 5 and (bankOf(addon))[LINEN] == 50, reads.n)
    World.nextFrame()
    World.containers[6][1] = slot(LINEN, 45)
    World.event(addon, "BANK_TABS_CHANGED", 0)
    T.eq("one right after a read: not at once", reads.n, 5)
    World.advance(1)
    T.check("but by the trailing read", reads.n == 6 and (bankOf(addon))[LINEN] == 45, reads.n)
    World.event(addon, "BANK_TABS_CHANGED", 1)
    T.eq("a change of the guild bank's tabs reads nothing", reads.n, 6)

    -- The client's notice that a batch of updates is complete: a read that
    -- is owed for this frame's updates is taken at once.
    addon = bankVisit()
    reads = countReads(addon)
    World.bagUpdateDelayed(addon)
    T.eq("batch complete with nothing owed: no read", reads.n, 0)
    World.containers[0][3] = slot(LINEN, 60)
    World.bagUpdate(addon, 0)
    T.check("the first update of the move is read at once: the bank has not changed yet",
        reads.n == 1 and (bankOf(addon))[LINEN] == 100, reads.n)
    World.containers[6][1] = slot(LINEN, 40)
    World.bagUpdate(addon, 6)
    T.eq("the second is owed", reads.n, 1)
    -- Until that read is taken the remembered bank may be behind the bags
    -- that just changed: a scan leaves it out instead of counting 165.
    local total, _, _, meta = linen(addon)
    T.check("while it is owed a scan does not count the bank, and says a read is on its way",
        total == 65 and meta.bankPending == true and meta.bankInDoubt == nil, total)
    T.eq("the scan itself read nothing", reads.n, 1)
    World.bagUpdateDelayed(addon)
    T.check("batch complete: the owed read is taken in the same frame", reads.n == 2 and (bankOf(addon))[LINEN] == 40, reads.n)
    total, _, _, meta = linen(addon)
    T.check("and the bank counts again", total == 105 and meta.bankPending == nil, total)
    World.bagUpdateDelayed(addon)
    T.eq("a second notice has nothing to read", reads.n, 2)
    World.advance(5)
    T.eq("and the trailing read that was waiting finds nothing owed", reads.n, 2)
    -- On a later frame, less than 0.2 s after a read, the notice does not
    -- read (a burst over many frames would otherwise read every frame).
    World.containers[6][1] = slot(LINEN, 30)
    World.bagUpdate(addon, 6)
    World.bagUpdateDelayed(addon)
    T.eq("a frame with one update: its one read", reads.n, 3)
    World.nextFrame()
    World.containers[6][1] = slot(LINEN, 20)
    World.bagUpdate(addon, 6)
    World.bagUpdateDelayed(addon)
    T.eq("the next frame's batch: left to the trailing read", reads.n, 3)
    World.advance(0.3)
    T.check("which takes it", reads.n == 4 and (bankOf(addon))[LINEN] == 20, reads.n)

    -- A scan never reads the bank: it counts what is remembered.
    addon = bankVisit()
    reads = countReads(addon)
    World.containers[6][1] = slot(LINEN, 7)           -- changed, and no update has said so
    total = linen(addon)
    T.eq("a scan with the bank open does not read it", reads.n, 0)
    T.eq("it counts the bank as remembered", total, 105)
end)

-- ===========================================================================
-- Reading both banks in full costs about a millisecond and leaves a table
-- per slot behind. The 0.2 s between two reads is what bounds that.
-- ===========================================================================
T.section("how often the open bank is read", function()
    -- A bank sort: eighteen bank-container updates a frame, three frames running.
    local addon = bankVisit()
    local reads = countReads(addon)
    for _ = 1, 3 do
        for _ = 1, 18 do World.bagUpdate(addon, 6) end
        World.nextFrame()
    end
    T.eq("a sort over three frames: one read at once", reads.n, 1)
    World.advance(5)
    T.eq("and one trailing read", reads.n, 2)

    -- The same with the client's batch notice after each frame's updates.
    addon = bankVisit()
    reads = countReads(addon)
    for _ = 1, 3 do
        for _ = 1, 18 do World.bagUpdate(addon, 6) end
        World.bagUpdateDelayed(addon)
        World.nextFrame()
    end
    World.advance(5)
    T.check("with batch notices: the first frame's two reads and one trailing read", reads.n <= 3, reads.n)

    -- Crafting at the open bank: 120 frames (1.92 s) with one carried-bag update each.
    for _, notices in ipairs({ false, true }) do
        addon = bankVisit()
        reads = countReads(addon)
        local most = 0
        for _ = 1, 120 do
            local before = reads.n
            World.bagUpdate(addon, 0)
            if notices then World.bagUpdateDelayed(addon) end
            World.nextFrame()
            most = math.max(most, reads.n - before)
        end
        World.advance(5)
        local label = notices and "crafting, with batch notices" or "crafting"
        -- One read at the start, then one for every 0.2 s of the 1.92 s. A
        -- batch notice in the frame of a read adds one more there, no more.
        local limit = notices and 22 or 11
        T.check(label .. ": bounded by the 0.2 s between reads, not by the frames", reads.n <= limit, reads.n)
        T.check(label .. ": and it does keep reading", reads.n >= 9, reads.n)
        T.check(label .. ": never more than two reads in a frame", most <= 2, most)
    end

    -- Looks of a visit that is over do nothing: not after the close ...
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28 } }
    World.bank = { [0] = { tabs = { { ID = 6 } } } }
    local saved = { stock = { schema = 1, account = {}, characters = { [MAIN_GUID] = { name = "Main Goldtooth", world = "eu-pvp",
        faction = "Horde", seen = World.serverTime, bank = { items = { [LINEN] = 100 }, at = World.serverTime } } } } }
    addon = World.login(saved)
    World.advance(3)
    reads = countReads(addon)
    World.event(addon, "BANKFRAME_OPENED")           -- reads as empty: the half-second and the two-second look wait
    World.bagUpdate(addon, 6)                        -- and a trailing read
    World.advance(0.1)
    T.eq("fixture: one read so far", reads.n, 1)
    World.event(addon, "BANKFRAME_CLOSED")
    local atClose = reads.n
    World.advance(5)
    T.eq("looks that were waiting are not taken after the close", reads.n, atClose)
    T.eq("and the bank that read as empty is remembered as it was", (bankOf(addon))[LINEN], 100)

    -- ... and not in the next visit: that one has its own.
    World.event(addon, "BANKFRAME_OPENED")           -- the first visit, at second 0
    World.bagUpdate(addon, 6)
    World.advance(0.3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.1)
    -- When each read of the second visit is taken, counted from its opening
    -- (the bank reads empty, so it is also read again every half second).
    local readAt = {}
    local opened
    local realRead = addon.Client.BankContents
    addon.Client.BankContents = function(self, kind)
        if kind == "character" then readAt[#readAt + 1] = string.format("%.2f", World.time - opened) end
        return realRead(self, kind)
    end
    opened = World.time
    World.event(addon, "BANKFRAME_OPENED")           -- the second visit, 0.4 s after the first
    T.eq("the second visit: its read at the opening", table.concat(readAt, ","), "0.00")
    World.advance(0.05)                              -- the first visit's half-second mark has passed
    T.eq("the first visit's half-second look does not read in the second", table.concat(readAt, ","), "0.00")
    World.advance(0.45)
    T.eq("the second visit has its own half-second look", table.concat(readAt, ","), "0.00,0.50")
    World.advance(1.2)                               -- 1.7 s: the first visit's two-second mark has passed
    T.eq("the first visit's two-second look does not read either: only the second visit's half-second reads",
        table.concat(readAt, ","), "0.00,0.50,1.00,1.50")
    T.eq("nothing was believed meanwhile", (bankOf(addon))[LINEN], 100)
    World.advance(0.31)
    T.eq("the second visit's own two-second look", readAt[#readAt], "2.00")
    T.check("which believes the empty bank: it was seen empty before, in this visit", next((bankOf(addon))) == nil)
    World.advance(3)
    T.eq("and nothing reads it after that", readAt[#readAt], "2.00")
    addon.Client.BankContents = realRead
end)

-- ===========================================================================
T.section("which read of the bank is kept", function()
    local function start(containers, bank, saved)
        World.reset()
        World.containers, World.bank = containers, bank
        local addon = World.login(saved or {})
        World.advance(3)
        return addon
    end
    local function remembering(linenInBank)
        return { stock = { schema = 1, account = {}, characters = { [MAIN_GUID] = { name = "Main Goldtooth", world = "eu-pvp",
            faction = "Horde", seen = World.serverTime, bank = { items = { [LINEN] = linenInBank }, at = World.serverTime } } } } }
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

    -- A bank the adapter refuses is not kept, and what is remembered stays.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 70) } },
        { [0] = { tabs = { { ID = 6 } }, locked = 1 } }, remembering(100))
    World.event(addon, "BANKFRAME_OPENED")
    T.eq("locked at opening: the remembered bank stays", (bankOf(addon))[LINEN], 100)
    World.bank[0].locked = nil
    World.advance(0.6)
    T.eq("readable half a second later, without an event: remembered", (bankOf(addon))[LINEN], 70)

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
    -- The same with the rest arriving a second after the opening: the look
    -- at two seconds reads the whole bank while the window is still open -
    -- also when every read before it found items in both banks.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) }, [8] = { slots = 12 },
                    [15] = { slots = 98, slot(BAR, 50) } },
        { [0] = { tabs = { { ID = 6 }, { ID = 8 } } }, [2] = { tabs = { { ID = 15 } } } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(1)
    World.containers[8][1] = slot(SILK, 30)
    World.advance(0.9)
    T.check("a part that arrives a second after the opening, without an event: not seen before two seconds",
        (bankOf(addon))[SILK] == nil, (bankOf(addon))[SILK])
    World.advance(0.2)
    T.eq("the look two seconds after the opening sees it", (bankOf(addon))[SILK], 30)

    -- With the bank open, a withdrawal may be reported for the backpack only.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } }, { [0] = { tabs = { { ID = 6 } } } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][2] = slot(LINEN, 60)
    World.bagUpdate(addon, 0)
    T.eq("an update of a carried bag alone reads the open bank", (bankOf(addon))[LINEN], 40)

    -- A bank without a single item, never seen before: remembered as seen,
    -- with nothing in it, two seconds after the opening and not earlier.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28 } }, { [0] = { tabs = { { ID = 6 } } } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(1.5)
    T.check("an empty bank never seen: not remembered before two seconds", bankOf(addon) == nil)
    World.advance(1)
    T.check("an empty bank never seen: remembered as empty after two seconds", bankOf(addon) ~= nil and next((bankOf(addon))) == nil)

    -- Items are remembered and the bank reads as empty: believed only on a
    -- second look, and never in the first two seconds of a visit that has
    -- not seen the bank with items.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28 } }, { [0] = { tabs = { { ID = 6 } } } }, remembering(100))
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(0.6)
    T.eq("empty at opening and half a second later: the remembered bank stays", (bankOf(addon))[LINEN], 100)
    World.bagUpdate(addon, 6)
    World.advance(1.3)
    T.eq("an update and more looks before two seconds: still", (bankOf(addon))[LINEN], 100)
    World.advance(0.2)
    T.check("two seconds after the opening, seen empty before: believed", next((bankOf(addon))) == nil)

    -- The items were late: the bank is not emptied, and nothing is in doubt.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28 } }, { [0] = { tabs = { { ID = 6 } } } }, remembering(100))
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(0.3)
    World.containers[6][1] = slot(LINEN, 95)
    World.bagUpdate(addon, 6)
    World.advance(5)
    local doubt
    items, doubt = bankOf(addon)
    T.check("items that arrive late replace the early empty read", items[LINEN] == 95 and doubt == false, items[LINEN])
    -- That early empty read is settled by then: it is no second opinion for
    -- an empty read that comes later in the visit.
    World.containers[6] = { slots = 28 }
    World.containers[0][2] = slot(LINEN, 100)
    World.bagUpdate(addon, 6, 0)
    T.eq("emptied later in that visit: one empty read is not believed", (bankOf(addon))[LINEN], 95)
    World.advance(0.25)
    T.check("the second look is", next((bankOf(addon))) == nil)

    -- A long visit; the bank is emptied. One read without items is not
    -- believed, the second look 0.2 s later is.
    addon = bankVisit(10)
    World.containers[6] = { slots = 28 }
    World.containers[0][3] = slot(LINEN, 100)
    World.bagUpdate(addon, 6, 0)
    T.eq("emptied late in a visit: the first empty read is not believed", (bankOf(addon))[LINEN], 100)
    notOver("emptied, before the second look", addon)
    World.advance(0.25)
    T.check("the second look believes it", next((bankOf(addon))) == nil)
    T.eq("and a scan counts what is carried", (linen(addon)), 105)

    -- A late empty read in a visit that never saw the bank with items (it was
    -- refused until then): the second look is still needed.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28 } },
        { [0] = { tabs = { { ID = 6 } }, locked = 1 } }, remembering(100))
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(5)
    World.bank[0].locked = nil
    World.bagUpdate(addon, 6)
    T.eq("refused for five seconds, then empty: one read is not believed", (bankOf(addon))[LINEN], 100)
    World.advance(0.25)
    T.check("the second look is", next((bankOf(addon))) == nil)

    -- An empty read with another slot count than the reads kept before is no
    -- second opinion in the first two seconds.
    addon = start({ [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } }, { [0] = { tabs = { { ID = 6 } } } })
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(1)
    World.containers[6] = { slots = 12 }
    World.bagUpdate(addon, 6)
    World.advance(0.5)
    T.eq("empty with other slots, twice, before two seconds: not believed", (bankOf(addon))[LINEN], 100)
    World.advance(0.6)
    T.check("at two seconds it is", next((bankOf(addon))) == nil)
end)

-- ===========================================================================
T.section("the close", function()
    -- Withdraw 60 and close in the same frame, the updates before the close.
    for index, move in ipairs(WITHDRAWALS) do
        for _, notice in ipairs({ false, true }) do
            for _, refused in ipairs({ false, true }) do
                local label = "withdraw and close in one frame, " .. move[1] .. (notice and ", batch notice" or "")
                    .. (refused and ", bank refused at the close" or "")
                local addon = bankVisit()
                move[2](addon)
                if notice then World.bagUpdateDelayed(addon) end
                notOver(label .. " (before the close)", addon)
                if refused then refuseBank() end
                World.event(addon, "BANKFRAME_CLOSED")
                notOver(label .. " (at the close)", addon)
                World.advance(5)
                local total, bags, bank, meta = linen(addon)
                notOver(label, addon)
                -- The bank was read after its own update: in that update's
                -- handler when it came first (the read then owed is for the
                -- carried bag), else at the batch notice or at the close.
                local bankUpdateFirst = index == 1 or index == 4
                if not refused or notice or bankUpdateFirst then
                    T.check(label .. ": 65 carried, 40 in the bank", total == 105 and bags == 65 and bank == 40,
                        tostring(total) .. " = " .. tostring(bags) .. " + " .. tostring(bank))
                    T.check(label .. ": nothing in doubt", meta.bankInDoubt == nil and meta.accountInDoubt == nil)
                else
                    -- It was not: the bank is unsettled, so it is not counted.
                    T.check(label .. ": only the 65 carried, the bank in doubt", total == 65 and bags == 65 and bank == nil
                        and meta.bankInDoubt == true, tostring(total) .. " = " .. tostring(bags) .. " + " .. tostring(bank))
                    T.check(label .. ": the bank is still remembered", bankOf(addon) ~= nil and select(2, bankOf(addon)) == true)
                    T.check(label .. ": the account bank, which no update named, is not in doubt", meta.accountInDoubt == nil)
                end
            end
        end
    end

    -- The control: a frame between the withdrawal and the close.
    local addon = bankVisit()
    WITHDRAWALS[1][2](addon)
    World.nextFrame()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    local total, bags, bank = linen(addon)
    T.check("a frame between the withdrawal and the close", total == 105 and bags == 65 and bank == 40, total)

    -- Deposit the 5 carried linen; closed in the same frame.
    addon = bankVisit()
    World.containers[6][2] = slot(LINEN, 5)
    World.containers[0][2] = nil
    World.bagUpdate(addon, 0, 6)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("deposit and close in one frame: nothing carried, 105 in the bank", total == 105 and bags == nil and bank == 105,
        tostring(total) .. " = " .. tostring(bags) .. " + " .. tostring(bank))

    -- From the character bank into the account bank, closed in the same frame.
    addon = bankVisit()
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[15][2] = slot(LINEN, 60)
    World.bagUpdate(addon, 6, 15)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    total, bags, bank = linen(addon)
    T.check("bank to account bank and close in one frame", total == 105 and bags == 5 and bank == 100, total)
    T.eq("of which 60 in the account bank", (addon.StockMemory:AccountBank("eu"))[LINEN], 60)

    -- A move clicked just before Escape: the client has locked its slots,
    -- and the answer comes after the close - on a client that may never
    -- report the bank's part of it then. Both banks are marked at the close.
    addon = bankVisit()
    World.containers[0][2] = slot(LINEN, 5, false, true)      -- the deposit's source, locked
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.2)
    World.containers[0][2] = nil                               -- the answer: only the carried bag reports
    World.containers[6][2] = slot(LINEN, 5)
    World.bagUpdate(addon, 0)
    World.advance(5)
    local meta
    total, bags, bank, meta = linen(addon)
    T.check("a deposit on its way at the close: the banks are in doubt, nothing counts twice",
        total == nil and meta.bankInDoubt == true and meta.accountInDoubt == true, total)
    -- The carried bag's part came before the close, the bank's part not: the
    -- bank's slot is still locked at the closing notice.
    addon = bankVisit()
    World.containers[0][3] = slot(LINEN, 60)
    World.containers[6][1] = slot(LINEN, 100, false, true)     -- still shown whole, locked
    World.bagUpdate(addon, 0)
    World.bagUpdateDelayed(addon)
    World.advance(0.05)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.2)
    World.containers[6][1] = slot(LINEN, 40)                   -- the bank's part, after the close: not reported
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("half a withdrawal heard at the close: the bank whose slot is locked is in doubt",
        total == 65 and bags == 65 and bank == nil and meta.bankInDoubt == true, total)
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("and the dump says that a move was on its way", table.concat(lines, "\n"):find("moveInFlight=true", 1, true) ~= nil,
        table.concat(lines, "\n"))

    -- The carried part of a withdrawal is answered while the bank is open,
    -- and the read taken for it (kept) sees the bank's slot still locked.
    -- At the closing notice the bank cannot be shown, and its update never
    -- comes. The lock that read saw is a move on its way at the close.
    addon = bankVisit()
    World.containers[6][1] = slot(LINEN, 100, false, true)     -- the click: the bank's slot locks
    World.advance(0.1)
    World.containers[0][3] = slot(LINEN, 100)                  -- the carried part
    World.bagUpdate(addon, 0)
    World.bagUpdateDelayed(addon)
    World.advance(0.2)
    World.bank[0].canView = false                              -- not shown at the closing notice
    World.event(addon, "BANKFRAME_CLOSED")
    World.bank[0].canView = true
    World.containers[6] = { slots = 28 }                       -- the bank's part, after the close: not reported
    World.advance(20)
    total, bags, bank, meta = linen(addon)
    T.check("a lock a kept read saw, the bank not shown at the close: in doubt, nothing counts twice",
        total == 105 and bags == 105 and bank == nil and meta.bankInDoubt == true, tostring(total) .. "/" .. tostring(bank))
    lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("and the dump says that a move was on its way", table.concat(lines, "\n"):find("moveInFlight=true", 1, true) ~= nil,
        table.concat(lines, "\n"))

    -- The banker is clicked again while the bank is open, and the client
    -- sends a second opening notice. The visit goes on with what it knows:
    -- here, that the bank is unsettled - its own update came while it was
    -- locked for a moment, and no read of it could be kept since.
    addon = bankVisit()
    World.bank[0].locked = 1
    World.containers[6][1] = nil                               -- 100 withdrawn while the bank is locked
    World.containers[0][3] = slot(LINEN, 100)
    World.bagUpdate(addon, 6, 0)
    World.bagUpdateDelayed(addon)
    World.advance(0.4)
    World.event(addon, "BANKFRAME_OPENED")                     -- the banker clicked again
    World.advance(0.6)
    World.event(addon, "BANKFRAME_CLOSED")                     -- still locked at the close
    World.bank[0].locked = nil
    World.advance(20)
    total, bags, bank, meta = linen(addon)
    T.check("a second opening notice while the bank is open: the visit keeps what it knew, the bank is in doubt",
        total == 105 and bags == 105 and bank == nil and meta.bankInDoubt == true, tostring(total) .. "/" .. tostring(bank))
    lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("and the dump counts the second notice", table.concat(lines, "\n"):find("openedAgain=1", 1, true) ~= nil,
        table.concat(lines, "\n"))

    -- The read taken at the close is kept only when it looks like the reads
    -- of the visit: not refused, at least one item, the same slot count. The
    -- bank's own update is still without a kept read here (the read taken
    -- for the carried bag's update came before it), so a closing read that
    -- is not kept leaves the bank in doubt.
    local function closeWith(letGo)
        addon = bankVisit()
        WITHDRAWALS[3][2](addon)                 -- the bank still read as 100; its own update came after
        letGo()
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(5)
        local items, doubt = bankOf(addon)
        return items[LINEN], doubt, notOver("a closing read that is not kept", addon)
    end
    local kept, doubt, counted = closeWith(function() World.containers[6] = { slots = 28 } end)
    T.check("the bank reads as empty at the close: not kept, and in doubt", kept == 100 and doubt == true and counted == 65,
        tostring(kept) .. "/" .. tostring(doubt) .. "/" .. tostring(counted))
    kept, doubt = closeWith(function() World.containers[6] = { slots = 12, slot(LINEN, 7) } end)
    T.check("the bank reads with fewer slots at the close: not kept", kept == 100 and doubt == true, kept)
    kept, doubt = closeWith(function() World.bank[0].canView = false; World.containers[6][1] = slot(LINEN, 7) end)
    T.check("the bank may not be viewed at the close: not kept", kept == 100 and doubt == true, kept)
    kept, doubt = closeWith(function() World.bank[0].locked = 2; World.containers[6][1] = slot(LINEN, 7) end)
    T.check("the bank is locked at the close: not kept", kept == 100 and doubt == true, kept)
    kept, doubt = closeWith(function() World.bank[0].tabs = {}; World.containers[6][1] = slot(LINEN, 7) end)
    T.check("the bank has no tabs at the close: not kept", kept == 100 and doubt == true, kept)
    kept, doubt = closeWith(function() World.containers[6][1] = slot(LINEN, 7) end)
    T.check("(a further change with everything in place is kept, and nothing is in doubt)", kept == 7 and doubt == false, kept)
    -- The bank's own update read in its handler: the read that is then owed
    -- is for the carried bag's update. Refused at the close, it marks
    -- nothing - what is remembered of the bank is what was read after its
    -- update.
    addon = bankVisit()
    WITHDRAWALS[1][2](addon)                     -- the bank's update first: read at once (40), one more owed
    refuseBank()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    local items
    items, doubt = bankOf(addon)
    T.check("a read owed for the carried bag's update alone, refused at the close: nothing is marked",
        items[LINEN] == 40 and doubt == false, items[LINEN])
    T.eq("and the withdrawal is counted once", notOver("a read owed for the carried bag's update", addon), 105)
    -- Each bank is judged alone: here only the character bank is refused.
    addon = bankVisit()
    WITHDRAWALS[3][2](addon)                     -- the bank still read as 100 when its read was taken
    World.bank[0].canView = false
    World.event(addon, "BANKFRAME_CLOSED")
    local combined, _, meta = World.scan(addon)
    T.check("one bank refused at the close: that one is in doubt, the other is read and counts",
        meta.bankInDoubt == true and meta.accountInDoubt == nil and combined[BAR] == 50 and combined[LINEN] == 65, combined[LINEN])

    -- A read that was owed is taken, but the bank is refused by then: the
    -- update it was owed for is still unanswered. The bank stays out of the
    -- counts, and the close settles it one way or the other.
    for _, readableAtClose in ipairs({ false, true }) do
        addon = bankVisit()
        WITHDRAWALS[3][2](addon)                 -- the bank still read as 100; one more read is owed
        refuseBank()
        World.advance(0.3)                       -- the trailing read: refused
        local label = "the trailing read is refused" .. (readableAtClose and ", the bank readable again at the close" or ", and so is the close")
        local total, _, _, meta = linen(addon)
        T.check(label .. ": while open the bank is not counted beside the bags that changed",
            total == 65 and meta.bankPending == true, total)
        if readableAtClose then
            World.bank[0].canView, World.bank[2].canView = nil, nil
        end
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(5)
        total, bags, bank, meta = linen(addon)
        notOver(label, addon)
        if readableAtClose then
            T.check(label .. ": the read at the close is kept", total == 105 and bank == 40 and meta.bankInDoubt == nil, total)
        else
            T.check(label .. ": in doubt", total == 65 and bank == nil and meta.bankInDoubt == true, total)
        end
    end
    -- The same without any carried-bag update: the bank's own update is
    -- enough. An item may have gone into the other bank.
    addon = bankVisit()
    World.containers[6][1] = slot(LINEN, 100)
    World.bagUpdate(addon, 6)
    World.nextFrame()
    World.bagUpdate(addon, 6)
    refuseBank()
    World.advance(0.3)
    World.event(addon, "BANKFRAME_CLOSED")
    T.check("an update of the bank's own container that no read could follow: in doubt, whatever the carried bags did",
        select(2, bankOf(addon)) == true and (linen(addon)) == 5, (linen(addon)))
    T.check("the account bank, which no update named, is not", select(3, addon.StockMemory:AccountBank("eu")) == false)

    -- A bank this character cannot view at all (here the account bank, known
    -- from another character) is not put in doubt by what it moves in its own.
    do
        local saved = { stock = { schema = 1,
            characters = { OTHER = { name = "Other Goldtooth", world = "eu-pvp", faction = "Horde", seen = World.serverTime - 100,
                bags = { items = { [SILK] = 1 }, at = World.serverTime - 100 } } },
            account = { eu = { items = { [BAR] = 50 }, at = World.serverTime - 100, world = "eu-pvp", faction = "Horde" } } } }
        World.reset()
        World.containers = { [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } }
        World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } }, canView = false } }
        addon = World.login(saved)
        World.advance(3)
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(3)
        WITHDRAWALS[3][2](addon)
        local combined, _, meta = World.scan(addon)
        T.check("a bank never readable in this visit stays counted while a read is owed", combined[BAR] == 50
            and meta.accountPending == nil and meta.bankPending == true, combined[BAR])
        World.advance(0.3)
        World.bagUpdate(addon, 0)
        World.advance(3)
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(5)
        combined, _, meta = World.scan(addon)
        T.check("and is not in doubt after the visit", combined[BAR] == 50 and meta.accountInDoubt == nil
            and combined[LINEN] == 105, combined[LINEN])

        -- Nor by a hurried end of that visit. The 5 carried linen go into
        -- the character bank and Escape follows in the same frame, the bank
        -- refused inside the close notice: the character bank is in doubt,
        -- the account bank - never usable in this visit - is not.
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(3)
        World.containers[0][3] = slot(SILK, 1)
        World.bagUpdate(addon, 0)                    -- read at once
        World.containers[6][2] = slot(LINEN, 5)
        World.containers[0][2] = nil
        World.bagUpdate(addon, 0, 6)                 -- owed
        World.bank[0].canView = false
        World.event(addon, "BANKFRAME_CLOSED")
        World.bank[0].canView = nil
        combined, _, meta = World.scan(addon)
        T.check("a deposit and Escape in one frame, the bank refused at the close: the bank that was used is in doubt",
            meta.bankInDoubt == true, tostring(meta.bankInDoubt))
        T.check("the bank this character may not view is not, and still counts", meta.accountInDoubt == nil and combined[BAR] == 50,
            tostring(meta.accountInDoubt))
        T.eq("the Shopping tab names the character's bank alone", firstShoppingRow(addon),
            "Your bank is not counted: it may have changed after LazyProf last read it. Open the bank to count it again.")

        -- Nor by a change of the carried bags in the second after a close.
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(3)
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(0.5)
        World.containers[0][4] = slot(LINEN, 3)
        World.bagUpdate(addon, 0)
        World.advance(3)
        combined, _, meta = World.scan(addon)
        T.check("a change of the bags after the close does not mark it either", meta.accountInDoubt == nil and combined[BAR] == 50,
            tostring(meta.accountInDoubt))
    end

    -- The bank is emptied one second after the opening and the window closed
    -- half a second later: the two reads in between settle it.
    for _, order in ipairs({ { 6, 0 }, { 0, 6 } }) do
        addon = bankVisit(1)
        if order[1] == 6 then
            World.containers[6] = { slots = 28 }
            World.containers[0][3] = slot(LINEN, 100)
            World.bagUpdate(addon, 6, 0)
        else
            World.containers[0][3] = slot(LINEN, 100)
            World.bagUpdate(addon, 0)
            World.containers[6] = { slots = 28 }
            World.bagUpdate(addon, 6)
        end
        notOver("emptied one second after opening", addon)
        World.advance(0.5)
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(5)
        local items, inDoubt = bankOf(addon)
        local label = "emptied at 1 s, closed at 1.5 s (update of " .. tostring(order[1]) .. " first)"
        T.check(label .. ": remembered as empty", items ~= nil and next(items) == nil and inDoubt == false)
        T.eq(label .. ": the scan counts what is carried", (linen(addon)), 105)
    end

    -- Emptied and closed in one frame: in doubt (or empty) - never counted twice.
    for index, move in ipairs({
        function(a) World.containers[6] = { slots = 28 }; World.containers[0][3] = slot(LINEN, 100); World.bagUpdate(a, 6, 0) end,
        function(a) World.containers[6] = { slots = 28 }; World.containers[0][3] = slot(LINEN, 100); World.bagUpdate(a, 0, 6) end,
        function(a) World.containers[0][3] = slot(LINEN, 100); World.bagUpdate(a, 0); World.containers[6] = { slots = 28 }; World.bagUpdate(a, 6) end,
        function(a) World.containers[6] = { slots = 28 }; World.bagUpdate(a, 6); World.containers[0][3] = slot(LINEN, 100); World.bagUpdate(a, 0) end,
    }) do
        for _, notice in ipairs({ false, true }) do
            addon = bankVisit(30)
            move(addon)
            if notice then World.bagUpdateDelayed(addon) end
            World.event(addon, "BANKFRAME_CLOSED")
            local label = "emptied and closed in one frame (" .. tostring(index) .. (notice and ", batch notice)" or ")")
            T.eq(label .. ": the scan counts what is carried, at once", notOver(label, addon), 105)
            World.advance(5)
            T.eq(label .. ": and later", notOver(label, addon), 105)
        end
    end

    -- The last stack of one bank is dragged into the other bank: no carried
    -- bag changes. Both updates in one frame, both containers changed, the
    -- batch notice in that frame, the bank readable inside the close notice.
    local function lastStack(from, to, closeAfter)
        World.reset()
        World.containers = {
            [0] = { slots = 16, slot(HEARTHSTONE, 1, true) },
            [6] = { slots = 28, slot(SILK, 5) },
            [15] = { slots = 98, slot(SILK, 5) },
        }
        World.containers[from] = { slots = World.containers[from].slots, [2] = slot(LINEN, 20) }
        World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
        addon = World.login({})
        World.advance(3)
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(5)
        World.containers[to][3] = World.containers[from][2]
        World.containers[from][2] = nil
        World.bagUpdate(addon, from)
        local between = linen(addon)                 -- between the two updates of the move
        World.bagUpdate(addon, to)
        World.bagUpdateDelayed(addon)
        local inFrame = linen(addon)
        if closeAfter > 0 then World.advance(closeAfter) end
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(10)
        local total, _, _, meta = linen(addon)
        return between, inFrame, total, meta
    end
    for _, way in ipairs({ { "the bank's last stack into the account bank", 6, 15, "bankInDoubt", "accountInDoubt" },
                           { "the account bank's last stack into the bank", 15, 6, "accountInDoubt", "bankInDoubt" } }) do
        for _, closeAfter in ipairs({ 0, 0.1, 0.3 }) do
            local label = way[1] .. ", Escape " .. (closeAfter == 0 and "in the same frame" or (closeAfter .. " s later"))
            local between, inFrame, total, meta = lastStack(way[2], way[3], closeAfter)
            T.check(label .. ": counted once between its two updates and in its frame", between == 20 and inFrame == 20,
                tostring(between) .. "/" .. tostring(inFrame))
            T.eq(label .. ": counted once ten seconds after the close", total, 20)
            if closeAfter < 0.2 then
                -- Before the second look at the emptied bank: it cannot be
                -- told from a bank the client let go of.
                T.check(label .. ": the emptied bank is in doubt, the other is not", meta[way[4]] == true and meta[way[5]] == nil)
            else
                T.check(label .. ": after the second look nothing is in doubt", meta.bankInDoubt == nil and meta.accountInDoubt == nil)
            end
        end
    end

    -- The bank's last stack is taken out, both containers changed, the
    -- bank's update first: a scan between the two updates of that frame.
    addon = bankVisit(30)
    World.containers[6] = { slots = 28 }
    World.containers[0][3] = slot(LINEN, 100)
    World.bagUpdate(addon, 6)
    T.eq("a scan between the two updates of the move that empties the bank counts the stack once",
        notOver("between the two updates", addon), 105)
    World.bagUpdate(addon, 0)
    World.bagUpdateDelayed(addon)
    T.eq("and so does one after them", notOver("after the two updates", addon), 105)

    -- An empty bank that is remembered as empty is not put in doubt by an
    -- ordinary visit: an empty read is believed only two seconds after the
    -- opening and never at the close, and that alone marks nothing.
    local function emptyBankVisit(play)
        World.reset()
        World.containers = { [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) }, [6] = { slots = 28 },
                             [15] = { slots = 98, slot(BAR, 50) } }
        World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
        addon = World.login({})
        World.advance(3)
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(3)
        World.event(addon, "BANKFRAME_CLOSED")       -- remembered as empty
        World.advance(5)
        World.event(addon, "BANKFRAME_OPENED")
        play()
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(5)
        local _, _, _, meta = linen(addon)
        return meta.bankInDoubt, meta.accountInDoubt, firstShoppingRow(addon)
    end
    local function deposit()
        World.containers[15][2] = slot(LINEN, 5)
        World.containers[0][2] = nil
        World.bagUpdate(addon, 0, 15)
    end
    local bankDoubt, accountDoubt, row = emptyBankVisit(function()
        World.advance(1)
        deposit()                                    -- into the other bank
        World.advance(0.5)
    end)
    T.check("an empty bank, a deposit into the other bank in a visit of 1.5 s: nothing in doubt",
        bankDoubt == nil and accountDoubt == nil and not tostring(row):find("not counted", 1, true), tostring(row))
    bankDoubt, accountDoubt, row = emptyBankVisit(function()
        World.advance(3)
        World.bagUpdate(addon, 0)                    -- an update that changes nothing, read at once
        World.nextFrame()
        deposit()                                    -- owed; Escape before the trailing read
    end)
    T.check("an empty bank, a deposit into the other bank and Escape before the next read: nothing in doubt",
        bankDoubt == nil and accountDoubt == nil and not tostring(row):find("not counted", 1, true), tostring(row))
    bankDoubt, accountDoubt, row = emptyBankVisit(function()
        World.advance(0.1)
        World.bagUpdate(addon, 0)                    -- an update that changes nothing
    end)
    T.check("an empty bank, a glance with a bag update that changes nothing: nothing in doubt",
        bankDoubt == nil and accountDoubt == nil and not tostring(row):find("not counted", 1, true), tostring(row))

    -- A long visit. The client lets go of the bank before it reports the
    -- close: the containers keep their slots but read as empty, and a bank
    -- container's update says so. The carried bags are untouched.
    local function letGoThen(ending, update)
        addon = bankVisit(30)
        World.containers[6] = { slots = 28 }
        World.containers[15] = { slots = 98 }
        World.bagUpdate(addon, update or 6)
        World.event(addon, ending)
        World.advance(5)
        local items, inDoubt = bankOf(addon)
        local account, _, accountDoubt = addon.StockMemory:AccountBank("eu")
        return items[LINEN], inDoubt, account[BAR], accountDoubt
    end
    -- Nothing tells that from the bank's last stacks having been moved out,
    -- so the bank whose container reported it is not replaced by nothing -
    -- and it is in doubt: on such a client every visit ends so. The other
    -- bank read as empty too (both are read at every read) and was not
    -- believed: in doubt as well.
    local linenLeft, inDoubt, barsLeft, accountDoubt = letGoThen("BANKFRAME_CLOSED")
    T.check("the client empties the bank before the close: the remembered bank is unchanged", linenLeft == 100 and barsLeft == 50,
        tostring(linenLeft) .. "/" .. tostring(barsLeft))
    T.check("the bank whose container reported it is in doubt, and the other one that read empty", inDoubt == true and accountDoubt == true)
    T.eq("so neither is counted", (linen(addon)), 5)
    T.eq("and the Shopping tab says so", firstShoppingRow(addon),
        "Your bank and the account bank are not counted: they may have changed after LazyProf last read them. "
            .. "They count again once they are read at the bank.")
    linenLeft, inDoubt, barsLeft, accountDoubt = letGoThen("BANKFRAME_CLOSED", 15)
    T.check("the same told by an account bank container's update: both in doubt", linenLeft == 100 and barsLeft == 50
        and inDoubt == true and accountDoubt == true, tostring(linenLeft) .. "/" .. tostring(barsLeft))
    -- The same client, after the bank was emptied and one stack put back:
    -- the empty read of the emptied bank, taken before the deposit, must not
    -- stand in as the second look for the empty read the client's letting
    -- go gives. The bank holds the 5 linen; it must not end up remembered
    -- as empty without a word.
    addon = bankVisit(30)
    World.containers[6] = { slots = 28 }
    World.containers[0][3] = slot(LINEN, 100)
    World.bagUpdate(addon, 6, 0)                 -- emptied: one empty read, not believed
    World.advance(0.19)
    World.containers[6][2] = slot(LINEN, 5)
    World.containers[0][2] = nil
    World.bagUpdate(addon, 6, 0)                 -- the 5 carried linen go in, before the second look
    World.time = World.time + 0.01               -- the frame the second look is due in, ahead of its timer
    World.containers[6] = { slots = 28 }         -- the client lets go and says so
    World.bagUpdate(addon, 6)
    World.event(addon, "BANKFRAME_CLOSED")
    World.containers[6] = { slots = 28, [2] = slot(LINEN, 5) }   -- what the bank really holds
    World.advance(5)
    do
        local items, inDoubtNow = bankOf(addon)
        T.check("emptied, a stack put back, then let go of: not remembered as empty", items[LINEN] == 100 and inDoubtNow == true,
            tostring(items[LINEN]) .. "/" .. tostring(inDoubtNow))
        T.eq("and the Shopping tab says the bank is not counted", firstShoppingRow(addon), BANK_NOT_COUNTED_LINE)
    end
    -- Several updates and the batch notice in that frame: the bank is read
    -- twice in it, and two reads of one frame are not a second look.
    addon = bankVisit(30)
    World.containers[6] = { slots = 28 }
    World.containers[15] = { slots = 98 }
    World.bagUpdate(addon, 6, 15, 6)
    World.bagUpdateDelayed(addon)
    T.check("read twice in the frame the client let go: nothing is believed", (bankOf(addon))[LINEN] == 100
        and (addon.StockMemory:AccountBank("eu"))[BAR] == 50, (bankOf(addon))[LINEN])
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(5)
    T.check("nor after the close: both banks unchanged, both in doubt", (bankOf(addon))[LINEN] == 100
        and select(2, bankOf(addon)) == true and select(3, addon.StockMemory:AccountBank("eu")) == true)
    linenLeft, inDoubt, barsLeft, accountDoubt = letGoThen("PLAYER_LOGOUT")
    T.check("the same at logout with the bank open: unchanged", linenLeft == 100 and barsLeft == 50,
        tostring(linenLeft) .. "/" .. tostring(barsLeft))
    -- The other bank read as empty too and could not be read back before
    -- the session ended: an update of its own could no longer be heard.
    T.check("both in doubt: the bank whose container reported it, and the one the session could not read back",
        inDoubt == true and accountDoubt == true)
    -- A move in the last frame before a logout with the bank open is judged like one before a close.
    addon = bankVisit(30)
    WITHDRAWALS[3][2](addon)
    World.event(addon, "PLAYER_LOGOUT")
    local items
    items, inDoubt = bankOf(addon)
    T.check("a withdrawal in the frame of a logout with the bank open: the read at logout is kept",
        items[LINEN] == 40 and inDoubt == false, items[LINEN])
    addon = bankVisit(30)
    WITHDRAWALS[3][2](addon)
    refuseBank()
    World.event(addon, "PLAYER_LOGOUT")
    World.event(addon, "PLAYER_LOGOUT")          -- the database's notice asks for the same
    items, inDoubt = bankOf(addon)
    T.check("the same with the bank refused by then: in doubt", items[LINEN] == 100 and inDoubt == true, items[LINEN])

    -- A window opened and closed within 0.3 s, nothing moved.
    local function glance(setup, remembered)
        World.reset()
        World.containers = { [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 90) } }
        World.bank = { [0] = { tabs = { { ID = 6 } } } }
        local saved = { stock = { schema = 1, account = {}, characters = { [MAIN_GUID] = { name = "Main Goldtooth", world = "eu-pvp",
            faction = "Horde", seen = World.serverTime, bank = { items = { [LINEN] = remembered or 100 }, at = World.serverTime } } } } }
        addon = World.login(saved)
        World.advance(3)
        setup()
        World.event(addon, "BANKFRAME_OPENED")
        World.advance(0.3)
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(5)
        local seen, seenDoubt = bankOf(addon)
        return seen[LINEN], seenDoubt
    end
    kept, doubt = glance(function() end)
    T.check("a glance: the remembered bank is what the opening read saw", kept == 90 and doubt == false, kept)
    kept, doubt = glance(function() World.containers[6] = { slots = 28 } end)
    T.check("a glance at a bank that reads as empty: unchanged, and in doubt (it may have been emptied)",
        kept == 100 and doubt == true, kept)
    kept, doubt = glance(function() World.bank[0].locked = 1 end)
    T.check("a glance at a bank that is refused: unchanged, not in doubt", kept == 100 and doubt == false, kept)

    -- The second BANKFRAME_CLOSED of one close changes nothing.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.event(addon, "BANKFRAME_CLOSED")
    T.eq("the close reported twice", (linen(addon)), 105)
end)

-- ===========================================================================
-- The window is closed first and the client reports the last move afterwards
-- (Escape right after the click: the close is local, the server's answer comes
-- a moment later). The bank cannot be read any more. What shows that a
-- remembered bank is behind is an update of one of its own containers in the
-- ten seconds after the close, or - on a client that reports the answer for
-- the carried bag alone - the carried count of an item the bank holds rising
-- in the second after the close.
-- ===========================================================================
local BANK_NOT_COUNTED = "Your bank is not counted: it may have changed after LazyProf last read it. Open the bank to count it again."

T.section("the answer of a last move arrives after the close", function()
    local function closedUpdates(addon)
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return (table.concat(lines, "\n"):match("bank updates while closed: [^\n]*"))
    end
    local function afterLine(addon)
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return (("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(after the close: [^\n]*)\n"))
    end

    -- Withdraw 60: both updates 80 ms after the close.
    for _, move in ipairs(WITHDRAWALS) do
        local addon = bankVisit()
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(0.08)
        local refreshes = addon.refreshes
        move[2](addon)
        local label = "a withdrawal reported 80 ms after the close, " .. move[1]
        -- A scan in the very frame of the updates must not count the 60 twice.
        local total, bags, bank, meta = linen(addon)
        T.check(label .. ": 65 carried and nothing else", total == 65 and bags == 65 and bank == nil,
            tostring(total) .. " = " .. tostring(bags) .. " + " .. tostring(bank))
        T.check(label .. ": the scan says the bank is in doubt, and not the account bank, which no update named",
            meta.bankInDoubt == true and meta.accountInDoubt == nil)
        local items, doubt = bankOf(addon)
        T.check(label .. ": the bank stays remembered, marked", items[LINEN] == 100 and doubt == true, items[LINEN])
        T.eq(label .. ": the Shopping tab says so in its first row", firstShoppingRow(addon), BANK_NOT_COUNTED)
        World.advance(5)
        T.eq(label .. ": and five seconds later", notOver(label, addon), 65)
        T.check(label .. ": a shown list is asked to redraw", addon.refreshes > refreshes, addon.refreshes - refreshes)
    end

    -- The bank container's update marks in its own handler: nothing waits
    -- for a frame or a scan.
    local addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.08)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][3] = slot(LINEN, 60)
    World.bagUpdate(addon, 6)
    T.check("an update of the bank's container after the close marks the bank at once", select(2, bankOf(addon)) == true)
    World.bagUpdate(addon, 0)
    T.eq("it is still counted for the dump", closedUpdates(addon),
        "bank updates while closed: 1, last 0.1 s after closing (in the first 10 s of the session, only counted: 0; marked a bank in doubt: 1)")
    T.eq("which names the bank and the reason", afterLine(addon), "after the close: bankUpdates=1 (last 0.1 s after the close)"
        .. " bagUpdates=1 (last 0.1 s after the close) compared=0 marked=character (bank container updated)")

    -- A deposit reported after the close.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.08)
    World.containers[6][2] = slot(LINEN, 5)
    World.containers[0][2] = nil
    World.bagUpdate(addon, 0, 6)
    local total, bags, bank, meta = linen(addon)
    T.check("a deposit reported after the close: the bank is in doubt", meta.bankInDoubt == true and total == nil and bank == nil,
        tostring(total))
    notOver("a deposit reported after the close", addon)

    -- A stack moved from the bank into the account bank: no carried bag
    -- changes, both banks report.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.1)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[15][2] = slot(LINEN, 60)
    World.bagUpdate(addon, 6, 15)
    World.bagUpdateDelayed(addon)
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("a move between the two banks reported after the close: both are in doubt",
        meta.bankInDoubt == true and meta.accountInDoubt == true and total == 5, tostring(total))
    T.eq("and the Shopping tab says so", firstShoppingRow(addon), NOT_COUNTED)

    -- Only the carried bag's update comes: the count of linen has risen and
    -- the remembered bank holds linen.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.08)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][3] = slot(LINEN, 60)
    World.bagUpdate(addon, 0)
    total, bags, bank, meta = linen(addon)
    T.check("only the carried bag's update after the close: a scan in that frame leaves the bank out, as being read",
        total == 65 and meta.bankPending == true and meta.bankInDoubt == nil, total)
    T.check("and marks nothing itself", select(2, bankOf(addon)) == false)
    World.nextFrame()
    total, bags, bank, meta = linen(addon)
    T.check("a frame later the bank is in doubt, the account bank - which holds no linen - is not",
        total == 65 and meta.bankInDoubt == true and meta.accountInDoubt == nil, total)
    T.eq("the dump names the item", afterLine(addon), "after the close: bankUpdates=0 bagUpdates=1 (last 0.1 s after the close)"
        .. " compared=1 marked=character (carried count rose: " .. LINEN .. ")")
    -- The same when no scan comes by.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.08)
    World.containers[0][3] = slot(LINEN, 60)
    World.bagUpdate(addon, 0)
    T.check("before the next frame nothing has compared yet", select(2, bankOf(addon)) == false)
    World.nextFrame()
    T.check("a frame later the bank is marked without any scan", select(2, bankOf(addon)) == true)

    -- A client that changes both containers of a move with the carried
    -- bag's update and reports the bank's container frames later. The last
    -- 100 linen are taken out and the window is closed between the two
    -- updates: the closing read finds the bank empty, which is never
    -- believed at the close, and the bank's own update is still to come.
    addon = bankVisit()
    World.containers[6] = { slots = 28 }
    World.containers[0][3] = slot(LINEN, 100)
    World.bagUpdate(addon, 0)                        -- read at once: the bank empty, not believed
    World.event(addon, "BANKFRAME_CLOSED")
    total, bags, bank, meta = linen(addon)
    T.check("the bank's update still to come at the close: the bank read empty is in doubt, not counted beside the stack",
        total == 105 and bank == nil and meta.bankInDoubt == true, tostring(total))
    World.advance(0.06)
    T.eq("and stays out", notOver("between the close and the bank's late update", addon), 105)
    World.bagUpdate(addon, 6)
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("the late update changes nothing of it", total == 105 and meta.bankInDoubt == true, tostring(total))
    -- The same with a logout between the two updates: the bank's update is
    -- never heard, and the bags the next session finds are the bags that
    -- were noted - only the mark set at logout keeps the stack from being
    -- counted twice.
    do
        local saved = {}
        addon = bankVisit(3, saved)
        World.containers[6] = { slots = 28 }
        World.containers[0][3] = slot(LINEN, 100)
        World.bagUpdate(addon, 0)
        World.event(addon, "PLAYER_LOGOUT")
        T.check("a logout before the bank's late update: the bank is marked at logout", select(2, bankOf(addon)) == true)
        World.timers = {}
        World.time = World.time + 30
        addon = World.login(saved)
        World.advance(3)
        total, bags, bank, meta = linen(addon)
        T.check("the next session counts the stack once", total == 105 and bank == nil and meta.bankInDoubt == true, tostring(total))
    end

    -- The player logs out (or reloads) in the frame the answer arrives,
    -- before the comparison of the next frame: it is made at logout, so the
    -- stack is not counted in the bags and in the bank from the next login.
    do
        local saved = {}
        addon = bankVisit(3, saved)
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(0.08)
        World.containers[6][1] = slot(LINEN, 40)
        World.containers[0][3] = slot(LINEN, 60)
        World.bagUpdate(addon, 0)
        World.event(addon, "PLAYER_LOGOUT")
        T.check("a logout in the frame of a late answer: the bank is marked at logout", select(2, bankOf(addon)) == true)
        World.timers = {}
        World.time = World.time + 30
        addon = World.login(saved)
        World.advance(3)
        total, bags, bank, meta = linen(addon)
        T.check("after the next login the withdrawn stack is counted once", total == 65 and bank == nil and meta.bankInDoubt == true, total)
    end

    -- A bank container's update alone. The client may only be letting go of
    -- the bank - or a stack went from one bank into the other: the two
    -- cannot be told apart, so the banks that reported are not counted.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.08)
    World.containers[6] = { slots = 28 }
    World.containers[15] = { slots = 98 }
    World.bagUpdate(addon, 6, 15)
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("bank containers' updates alone after the close: both banks in doubt, still remembered", total == 5 and bank == nil
        and meta.bankInDoubt == true and meta.accountInDoubt == true and (bankOf(addon))[LINEN] == 100, total)
    T.eq("the Shopping tab says so", firstShoppingRow(addon), NOT_COUNTED)
    T.eq("they are counted for the dump", closedUpdates(addon),
        "bank updates while closed: 2, last 0.1 s after closing (in the first 10 s of the session, only counted: 0; marked a bank in doubt: 2)")
    -- Whenever it comes: a craft may take reagents from the closed bank.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(60)
    World.containers[6][1] = slot(LINEN, 97)                   -- three used by a craft
    World.bagUpdate(addon, 6)
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("a bank container's update a minute after the close: that bank in doubt, the other still counts",
        total == 5 and meta.bankInDoubt == true and meta.accountInDoubt == nil, total)
    T.eq("the dump has it", closedUpdates(addon),
        "bank updates while closed: 1, last 60.0 s after closing (in the first 10 s of the session, only counted: 0; marked a bank in doubt: 1)")

    -- A carried bag's update that changes no count (a stack moved to another slot).
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.08)
    World.containers[0][2] = nil
    World.containers[0][9] = slot(LINEN, 5)
    World.bagUpdate(addon, 0)
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("a carried bag's update that changes no count: no doubt", total == 105 and bank == 100 and meta.bankInDoubt == nil, total)

    -- What else changes the carried bags in the second after a close: a
    -- count that falls, an item no remembered bank holds.
    local function afterClose(change)
        addon = bankVisit()
        World.event(addon, "BANKFRAME_CLOSED")
        World.advance(0.5)
        change()
        World.bagUpdate(addon, 0)
        World.advance(5)
        local _, _, _, m = linen(addon)
        return m.bankInDoubt, m.accountInDoubt, firstShoppingRow(addon)
    end
    local bankDoubt, accountDoubt, row = afterClose(function() World.containers[0][2] = slot(LINEN, 3) end)
    T.check("two linen used up half a second after the close: nothing is marked", bankDoubt == nil and accountDoubt == nil
        and not tostring(row):find("not counted", 1, true), tostring(row))
    bankDoubt, accountDoubt, row = afterClose(function() World.containers[0][3] = slot(SILK, 1) end)
    T.check("one silk looted, and no silk in either bank: nothing is marked", bankDoubt == nil and accountDoubt == nil
        and not tostring(row):find("not counted", 1, true), tostring(row))
    bankDoubt, accountDoubt, row = afterClose(function()
        World.containers[0][2] = slot(LINEN, 4)          -- a craft: one linen fewer, one bandage more
        World.containers[0][3] = slot(1251, 1)
    end)
    T.check("a craft completes: one linen fewer, one item more that no bank holds: nothing is marked",
        bankDoubt == nil and accountDoubt == nil, tostring(row))
    -- A count that rises for an item the bank holds cannot be told from the
    -- answer of a withdrawal: the bank that holds it is marked.
    bankDoubt, accountDoubt, row = afterClose(function() World.containers[0][3] = slot(LINEN, 2) end)
    T.check("two linen looted, and linen in the bank: the bank is in doubt, the account bank is not",
        bankDoubt == true and accountDoubt == nil, tostring(row))
    bankDoubt, accountDoubt = afterClose(function() World.containers[0][3] = slot(BAR, 1) end)
    T.check("a bar looted, and bars in the account bank: the account bank is in doubt, the bank is not",
        bankDoubt == nil and accountDoubt == true)

    -- The carried bags change a second and a half after the close: that is
    -- play, not the answer of a move.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(1.5)
    World.containers[0][3] = slot(LINEN, 3)
    World.bagUpdate(addon, 0)
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("a change of the bags 1.5 s after the close: no doubt", total == 108 and bank == 100 and meta.bankInDoubt == nil, total)
    -- An update inside the second that changes nothing does not stretch it.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.9)
    World.bagUpdate(addon, 0)
    World.advance(0.6)
    World.containers[0][3] = slot(LINEN, 3)
    World.bagUpdate(addon, 0)
    World.advance(5)
    T.check("an idle update inside the second, a change after it: no doubt", select(2, bankOf(addon)) == false)

    -- A session in which the bank was never closed marks nothing.
    local saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(15)
    World.event(addon, "PLAYER_LOGOUT")
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) } }
    addon = World.login(saved)
    World.advance(3)
    World.containers[0][2] = slot(LINEN, 9)
    World.bagUpdate(addon, 0, 6)
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("no close in this session: a change of the bags and an update of a bank container mark nothing",
        total == 114 and bank == 100 and meta.bankInDoubt == nil, total)

    -- Before any visit a bank container's update is counted as such.
    World.reset()
    addon = World.login({})
    T.eq("a session without one says none", closedUpdates(addon), "bank updates while closed: 0")
    World.bagUpdate(addon, 7)
    World.bagUpdate(addon, 0)
    T.eq("one before the bank was ever opened is named as such", closedUpdates(addon),
        "bank updates while closed: 1, before the bank was opened this session (in the first 10 s of the session, only counted: 1; marked a bank in doubt: 0)")
    -- In a session without a visit the client may load the bank's containers
    -- in the first moments: such an update is only counted then. Later one
    -- marks its bank.
    local saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(1)
    World.event(addon, "PLAYER_LOGOUT")
    World.containers = { [0] = World.containers[0], [6] = World.containers[6], [15] = World.containers[15] }
    addon = World.login(saved)
    World.bagUpdate(addon, 0)
    World.advance(1)
    World.bagUpdate(addon, 6, 15)
    World.advance(3)
    total, bags, bank, meta = linen(addon)
    T.check("the next session: updates in its first seconds are only counted", total == 105 and meta.bankInDoubt == nil
        and meta.accountInDoubt == nil, total)
    World.advance(10)
    World.containers[6][1] = slot(LINEN, 97)
    World.bagUpdate(addon, 6)
    total, bags, bank, meta = linen(addon)
    T.check("one fourteen seconds into it marks that bank", total == 5 and meta.bankInDoubt == true and meta.accountInDoubt == nil, total)
end)

-- ===========================================================================
-- The session ends (a logout or a reload) before the answer of a last move
-- is heard. That session cannot see it. It leaves a note of what the carried
-- bags held; the character's next session compares its bags with the note -
-- nothing else changes the bags in between - and marks the banks of that
-- visit in doubt when they differ.
-- ===========================================================================
T.section("the answer of a last move arrives after the session ended", function()
    local function sessionLine(addon)
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return (("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(bags at the bank [^\n]*)\n"))
    end
    -- The next session of the same character, `away` seconds later. The
    -- client shows the bags and the bank as they really are by then.
    local function relog(saved, away)
        World.timers = {}
        World.time = World.time + (away or 30)
        World.serverTime = World.serverTime + (away or 30)
        return World.login(saved)
    end
    local function note(saved)
        local record = saved.stock and saved.stock.characters[MAIN_GUID]
        return record and record.bagsAtBank
    end

    -- A withdrawal: 60 of the 100 banked linen are clicked out and the
    -- player logs out before the answer. The answer lands while nobody is
    -- there to hear it.
    local saved = {}
    local addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.05)
    World.event(addon, "PLAYER_LOGOUT")
    T.check("a logout right after the close leaves a note of the bags with the record", note(saved) ~= nil
        and note(saved).items[LINEN] == 5 and note(saved).banks.character == true and note(saved).banks.account == true)
    World.containers[6][1] = slot(LINEN, 40)             -- the answer, unheard
    World.containers[0][3] = slot(LINEN, 60)
    addon = relog(saved)
    local total, bags, bank, meta = linen(addon)
    T.check("the next session, before its bags are compared: the bank is left out, as being read",
        total == 65 and bank == nil and meta.bankPending == true and meta.accountPending == true and meta.bankInDoubt == nil,
        tostring(total))
    T.check("no line is shown for that", not tostring(firstShoppingRow(addon)):find("not counted", 1, true), firstShoppingRow(addon))
    T.eq("the dump says so", sessionLine(addon), "bags at the bank (from the last session): not compared yet")
    World.advance(1.9)
    T.check("still so 1.9 s after the login", select(4, linen(addon)).bankPending == true)
    World.advance(0.2)                                   -- the first save of the bags
    total, bags, bank, meta = linen(addon)
    T.check("when the bags are first saved they are compared: linen rose, the bank of that visit that holds linen is in doubt",
        total == 65 and bank == nil and meta.bankInDoubt == true and meta.accountInDoubt == nil and meta.bankPending == nil,
        tostring(total))
    T.eq("the Shopping tab says so", firstShoppingRow(addon), BANK_NOT_COUNTED_LINE)
    T.eq("and the dump: the account bank holds no linen", sessionLine(addon),
        "bags at the bank (from the last session): compared, different: character marked in doubt; account not marked (nothing it holds rose)")
    T.check("the note is gone", note(saved) == nil)
    T.check("a shown list was asked to redraw", addon.refreshes >= 1, addon.refreshes)
    notOver("a withdrawal answered after the logout", addon)
    World.event(addon, "PLAYER_LOGOUT")

    -- A deposit: the 5 carried linen are clicked into the bank, logout
    -- before the answer. Its carried slot is locked at the logout, so the
    -- banks are in doubt from then on; the comparison in the next session
    -- finds only a count that fell, which marks nothing more.
    saved = {}
    addon = bankVisit(3, saved)
    World.containers[0][2] = slot(LINEN, 5, false, true)
    World.event(addon, "PLAYER_LOGOUT")                  -- with the bank open
    T.check("a logout with the bank open leaves the note too", note(saved) ~= nil and note(saved).items[LINEN] == 5)
    World.containers[6][2] = slot(LINEN, 5)
    World.containers[0][2] = nil
    addon = relog(saved)
    World.bagUpdate(addon, 0)                            -- the bags arrive: the first bag update of the session
    World.nextFrame()                                    -- compared on the next frame
    total, bags, bank, meta = linen(addon)
    T.check("a deposit answered after the logout: the banks in doubt, the bank short of it is not counted",
        total == nil and meta.bankInDoubt == true and meta.accountInDoubt == true, tostring(total))
    T.check("the note is gone", note(saved) == nil)
    -- The same bags without a move on its way (a craft right after the
    -- login used them): only a count that fell - nothing is marked.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "PLAYER_LOGOUT")
    World.containers[0][2] = nil
    addon = relog(saved)
    World.bagUpdate(addon, 0)
    World.nextFrame()                                    -- compared on the next frame
    total, bags, bank, meta = linen(addon)
    T.check("a count that fell after the session: nothing in doubt", total == 100 and meta.bankInDoubt == nil
        and meta.accountInDoubt == nil and meta.bankPending == nil, tostring(total))
    T.eq("the dump says why", sessionLine(addon),
        "bags at the bank (from the last session): compared, different: none marked in doubt; character,account not marked (nothing it holds rose)")
    -- The first update of the session is half of a move between two carried
    -- bags: for that frame the stack shows in both. The comparison is made
    -- on the next frame, when it shows in one.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "PLAYER_LOGOUT")
    World.containers[1] = { slots = 8, slot(LINEN, 5) }      -- the stack's new place, reported first
    addon = relog(saved)
    World.bagUpdate(addon, 1)
    World.containers[0][2] = nil                             -- its old place, reported in the same frame
    World.bagUpdate(addon, 0)
    World.nextFrame()
    total, bags, bank, meta = linen(addon)
    T.check("a stack moved between carried bags at the login: equal, nothing in doubt", total == 105 and meta.bankInDoubt == nil
        and meta.bankPending == nil, tostring(total))

    -- Nothing was on its way: the bags are what they were, and the banks
    -- count again as soon as that is known.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(4)
    World.event(addon, "PLAYER_LOGOUT")
    addon = relog(saved)
    T.check("an ordinary logout four seconds after the close: the bank waits for the comparison",
        select(4, linen(addon)).bankPending == true)
    local refreshes = addon.refreshes
    World.advance(2.1)
    total, bags, bank, meta = linen(addon)
    T.check("the bags are as they were: both banks count, nothing in doubt", total == 105 and bank == 100
        and meta.bankPending == nil and meta.accountPending == nil and meta.bankInDoubt == nil and meta.accountInDoubt == nil,
        tostring(total))
    T.eq("the dump says so", sessionLine(addon), "bags at the bank (from the last session): compared, equal")
    T.check("the note is gone", note(saved) == nil)
    T.check("a shown list is asked to redraw: the bank counts again", addon.refreshes > refreshes, addon.refreshes - refreshes)
    World.event(addon, "PLAYER_LOGOUT")
    -- The same with the bags' update at login: compared at once.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(4)
    World.event(addon, "PLAYER_LOGOUT")
    addon = relog(saved)
    World.bagUpdate(addon, 0)
    World.nextFrame()                                    -- compared on the next frame
    total, bags, bank, meta = linen(addon)
    T.check("compared at the first bag update of the session", total == 105 and meta.bankPending == nil and meta.bankInDoubt == nil,
        tostring(total))

    -- Later than ten seconds after the close a session leaves no note. The
    -- next one compares its bags with what the last save of them held
    -- instead (a session may have ended without its saved data written),
    -- at the same moments: until its first bag update the bank waits.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(11)
    World.event(addon, "PLAYER_LOGOUT")
    T.check("a logout eleven seconds after the close leaves no note", note(saved) == nil)
    addon = relog(saved)
    total, bags, bank, meta = linen(addon)
    T.check("the next session leaves the bank out until its bags are compared with their last save",
        total == 5 and meta.bankPending == true, tostring(total))
    T.eq("with no line in the dump for a note", sessionLine(addon), nil)
    World.bagUpdate(addon, 0)
    World.nextFrame()
    total, bags, bank, meta = linen(addon)
    T.check("compared at the first bag update: the bags are as last saved, the bank counts", total == 105
        and meta.bankPending == nil and meta.bankInDoubt == nil, tostring(total))
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("and the dump says so", table.concat(lines, "\n"):find(
        "bags as last saved (no note from the last session): compared, equal", 1, true) ~= nil, table.concat(lines, "\n"))

    -- Bags that could not be read when the session ended: the note says
    -- that they are not known, and the next session marks.
    saved = {}
    addon = bankVisit(3, saved)
    World.containers[0] = nil                            -- no backpack slots: the bags cannot be read
    World.event(addon, "PLAYER_LOGOUT")
    T.check("bags that cannot be read at a logout with the bank open: noted as not known", note(saved) ~= nil
        and note(saved).items == nil)
    World.containers[0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) }
    addon = relog(saved)
    World.advance(2.1)
    total, bags, bank, meta = linen(addon)
    T.check("the next session cannot compare: the banks are in doubt", total == 5 and meta.bankInDoubt == true
        and meta.accountInDoubt == true, tostring(total))
    T.eq("the dump says why", sessionLine(addon), "bags at the bank (from the last session): unknown: character,account marked in doubt")
    -- A note that is not what the addon wrote counts the same.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(15)
    World.event(addon, "PLAYER_LOGOUT")
    saved.stock.characters[MAIN_GUID].bagsAtBank = "damaged"
    addon = relog(saved)
    World.advance(2.1)
    total, bags, bank, meta = linen(addon)
    T.check("a damaged note: both banks in doubt", total == 5 and meta.bankInDoubt == true and meta.accountInDoubt == true,
        tostring(total))
    T.check("and it is removed", note(saved) == nil)

    -- The bags of the next session cannot be read by the time of the first
    -- save, or read as completely empty without any bag update having come:
    -- that is no read to compare with. The banks are in doubt then.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(4)
    World.event(addon, "PLAYER_LOGOUT")
    World.containers[0] = { slots = 16 }                 -- slots, and not one item
    addon = relog(saved)
    World.advance(2.1)
    total, bags, bank, meta = linen(addon)
    T.check("bags that read as empty, and no bag update yet: not trusted, the banks are in doubt",
        meta.bankInDoubt == true and meta.accountInDoubt == true, tostring(total))
    T.eq("the dump calls that unknown", sessionLine(addon), "bags at the bank (from the last session): unknown: character,account marked in doubt")
    -- With a bag update before it, empty bags are a read like any other.
    saved = {}
    World.reset()
    World.containers = { [0] = { slots = 16 }, [6] = { slots = 28, slot(LINEN, 100) }, [15] = { slots = 98, slot(BAR, 50) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
    addon = World.login(saved)
    World.bagUpdate(addon, 0)
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(1)
    World.event(addon, "PLAYER_LOGOUT")
    T.check("a character that carries nothing: the note of the close says so", note(saved) ~= nil and next(note(saved).items) == nil)
    addon = relog(saved)
    World.bagUpdate(addon, 0)
    World.nextFrame()                                    -- compared on the next frame
    total, bags, bank, meta = linen(addon)
    T.check("empty then, empty now, told by a bag update: equal, the banks count", total == 100 and meta.bankInDoubt == nil
        and meta.bankPending == nil, tostring(total))
    -- Empty then, and empty at the first save without a bag update: what
    -- is read agrees with the note - equal too (a glance at the bank with
    -- nothing carried must not end in doubt).
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(1)
    World.event(addon, "PLAYER_LOGOUT")
    addon = relog(saved)
    World.advance(2.1)
    total, bags, bank, meta = linen(addon)
    T.check("empty then, empty at the first save: equal, the banks count", total == 100 and meta.bankInDoubt == nil
        and meta.accountInDoubt == nil and meta.bankPending == nil, tostring(total))
    T.eq("the dump says so", sessionLine(addon), "bags at the bank (from the last session): compared, equal")

    -- The bank is opened before the comparison was made: it is made first,
    -- so that no mark is set on a bank the new visit has just read.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.05)
    World.event(addon, "PLAYER_LOGOUT")
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][3] = slot(LINEN, 60)
    addon = relog(saved)
    World.advance(0.5)
    World.event(addon, "BANKFRAME_OPENED")
    total, bags, bank, meta = linen(addon)
    T.check("the bank opened half a second after the login: read, right and not in doubt", total == 105 and bank == 40
        and meta.bankInDoubt == nil and meta.accountInDoubt == nil and meta.bankPending == nil, tostring(total))
    T.eq("the comparison was made at the opening", sessionLine(addon),
        "bags at the bank (from the last session): compared, different: character marked in doubt; account not marked (nothing it holds rose)")
    World.advance(5)
    total, bags, bank, meta = linen(addon)
    T.check("and nothing marks it afterwards", total == 105 and meta.bankInDoubt == nil and meta.accountInDoubt == nil, tostring(total))
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(15)
    World.event(addon, "PLAYER_LOGOUT")

    -- The next session ends before it has compared: with bags it can read
    -- the comparison is made at logout, before the bags are saved - else the
    -- other characters would count the stack in these bags and in the bank.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.05)
    World.event(addon, "PLAYER_LOGOUT")
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][3] = slot(LINEN, 60)
    addon = relog(saved)
    World.advance(0.5)
    World.event(addon, "PLAYER_LOGOUT")                  -- half a second after the login
    T.check("a session of half a second: the comparison is made at its logout", note(saved) == nil
        and saved.stock.characters[MAIN_GUID].bank.doubt == true)
    T.eq("with the bags that are then saved", saved.stock.characters[MAIN_GUID].bags.items[LINEN], 65)

    -- A bank this character may not view was not usable in its visit: the
    -- note does not name it, and the next session neither waits for it nor
    -- marks it.
    saved = { stock = { schema = 1,
        characters = { OTHER = { name = "Other Goldtooth", world = "eu-pvp", faction = "Horde", seen = World.serverTime - 100,
            bags = { items = { [SILK] = 1 }, at = World.serverTime - 100 } } },
        account = { eu = { items = { [BAR] = 50 }, at = World.serverTime - 100, world = "eu-pvp", faction = "Horde" } } } }
    World.reset()
    World.containers = { [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } }, canView = false } }
    addon = World.login(saved)
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.05)
    World.event(addon, "PLAYER_LOGOUT")
    T.check("the note names the character's bank alone", note(saved) ~= nil and note(saved).banks.character == true
        and note(saved).banks.account == nil)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][3] = slot(LINEN, 60)
    addon = relog(saved)
    local combined
    combined, _, meta = World.scan(addon)
    T.check("the next session waits for the character's bank, not for the account bank", meta.bankPending == true
        and meta.accountPending == nil and combined[BAR] == 50)
    World.advance(2.1)
    combined, _, meta = World.scan(addon)
    T.check("and marks the character's bank alone", meta.bankInDoubt == true and meta.accountInDoubt == nil and combined[BAR] == 50
        and combined[LINEN] == 65, combined[LINEN])
    T.eq("the dump names it alone", sessionLine(addon), "bags at the bank (from the last session): compared, different: character marked in doubt")

    -- Another character in between counts the first one's bags and bank as
    -- they were remembered when it left: that is still one stack, not two.
    saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.05)
    World.event(addon, "PLAYER_LOGOUT")
    World.reset()
    World.guid, World.name = "Player-4444-000000BB", "Crafter Goldtooth"
    World.containers = { [0] = { slots = 16, slot(LINEN, 1) } }
    local crafter = World.login(saved)
    World.advance(3)
    combined, _, meta = World.scan(crafter)
    T.check("another character before the first one returns: its bags and its bank as remembered, 5 + 100 and the 1 carried",
        combined[LINEN] == 106 and meta.bankPending == nil and meta.accountPending == nil, combined[LINEN])
    T.check("the first one's note is still there for its own next session", note(saved) ~= nil)
end)

-- ===========================================================================
T.section("a bank in doubt until the next visit", function()
    -- 60 of the 100 banked linen are dragged into the account bank; Escape
    -- before the answer, which names both banks.
    local saved = {}
    local addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.08)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[15][2] = slot(LINEN, 60)
    World.bagUpdate(addon, 6, 15)
    World.advance(15)
    local total, bags, bank, meta = linen(addon)
    T.check("in doubt: the own bank is not counted", total == 5 and bank == nil and meta.bankInDoubt == true, total)
    local combined = World.scan(addon)
    T.check("nor the account bank", combined[BAR] == nil and meta.accountInDoubt == true)
    T.eq("the Shopping tab's first row says so", firstShoppingRow(addon), NOT_COUNTED)
    addon.db.profile.includeBankItems = false
    T.check("with \"Include bank items\" off there is nothing to say", not tostring(firstShoppingRow(addon)):find("not counted", 1, true),
        firstShoppingRow(addon))
    addon.db.profile.includeBankItems = true
    World.event(addon, "PLAYER_LOGOUT")

    -- Another character of the account: the first one's bags count, its bank does not.
    World.reset()
    World.guid, World.name = "Player-4444-000000BB", "Crafter Goldtooth"
    World.containers = { [0] = { slots = 16, slot(LINEN, 1) } }
    local crafter = World.login(saved)
    World.advance(3)
    local breakdown
    combined, breakdown, meta = World.scan(crafter)
    local alt = breakdown[LINEN].alts and breakdown[LINEN].alts["Main Goldtooth"]
    T.check("as an alt it supplies its bags only", combined[LINEN] == 6 and alt ~= nil and alt.bags == 5 and alt.bank == nil,
        combined[LINEN])
    T.check("the account bank is in doubt for this character too", combined[BAR] == nil and meta.accountInDoubt == true
        and meta.bankInDoubt == nil)
    T.eq("its Shopping tab names the account bank", firstShoppingRow(crafter),
        "The account bank is not counted: it may have changed after LazyProf last read it. "
            .. "It counts again once it is read at the bank.")
    -- The first character's bank is left out of this one's counts as well:
    -- the scan names it, and the Shopping tab has a second line for it.
    T.check("the scan names the alt whose bank is not counted", type(meta.altBanksInDoubt) == "table"
        and #meta.altBanksInDoubt == 1 and meta.altBanksInDoubt[1] == "Main Goldtooth")
    do
        local rows = crafter.GuideViews.Shopping({ path = {}, missing = { rows = {} }, stockMeta = meta, now = World.serverTime })
        T.eq("and the Shopping tab says so in its second row", rows[2] and rows[2].text,
            "The bank of Main Goldtooth is not counted: it may have changed after LazyProf last read it. "
            .. "Open the bank on that character to count it again.")
    end
    crafter.db.profile.includeAltCharacters = false
    T.check("with alts off there is nothing to say of it", select(3, World.scan(crafter)).altBanksInDoubt == nil)
    crafter.db.profile.includeAltCharacters = true
    World.event(crafter, "PLAYER_LOGOUT")

    -- Back on the first character: the next visit's kept read clears the mark.
    World.reset()
    World.containers = {
        [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) },
        [6] = { slots = 28, slot(LINEN, 40) },
        [15] = { slots = 98, slot(BAR, 50), slot(LINEN, 60) },
    }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
    addon = World.login(saved)
    World.advance(3)
    total, bags, bank, meta = linen(addon)
    T.check("after a relog it is still in doubt (5 carried, 1 on the other character)",
        total == 6 and bank == nil and meta.bankInDoubt == true, total)
    World.event(addon, "BANKFRAME_OPENED")
    total, bags, bank, meta = linen(addon)
    T.check("the next visit's first kept read clears it", total == 106 and bank == 100 and meta.bankInDoubt == nil
        and meta.accountInDoubt == nil, total)
    T.check("and the line is gone from the Shopping tab", not tostring(firstShoppingRow(addon)):find("not counted", 1, true),
        firstShoppingRow(addon))
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(15)
    World.event(addon, "PLAYER_LOGOUT")
    World.reset()
    World.guid, World.name = "Player-4444-000000BB", "Crafter Goldtooth"
    World.containers = { [0] = { slots = 16, slot(LINEN, 1) } }
    crafter = World.login(saved)
    World.advance(3)
    combined = World.scan(crafter)
    T.check("and the other character counts bank and account bank again", combined[LINEN] == 106 and combined[BAR] == 50, combined[LINEN])
    T.check("with no alt named any more", select(3, World.scan(crafter)).altBanksInDoubt == nil)
end)

-- ===========================================================================
-- A read, a comparison or a save that cannot be made when it is due is tried
-- again until it can be: what waits for it is left out meanwhile, and must
-- not stay left out without a word.
-- ===========================================================================
T.section("what cannot be done at once is tried again", function()
    -- The bank is refused for a moment after the two-second mark, while a
    -- deposit is answered; it can be read again without any event saying so.
    local addon = bankVisit(4)
    World.bank[0].locked = 1
    World.containers[0][2] = nil
    World.containers[6][2] = slot(LINEN, 5)
    World.bagUpdate(addon, 0, 6)
    World.bagUpdateDelayed(addon)
    World.advance(0.3)
    World.bank[0].locked = nil                    -- readable again; no event
    World.advance(0.7)
    local total, bags, bank, meta = linen(addon)
    T.check("a bank refused while unsettled is read again while the window is open: counted, not left out",
        total == 105 and bank == 105 and meta.bankPending == nil, tostring(total))
    World.advance(30)
    T.check("and nothing goes on reading it once it is settled", (function()
        local reads = 0
        local real = addon.Client.BankContents
        addon.Client.BankContents = function(self, kind) reads = reads + 1 return real(self, kind) end
        World.advance(5)
        addon.Client.BankContents = real
        return reads == 0
    end)())
    World.event(addon, "BANKFRAME_CLOSED")
    -- A bank this character may not view is not read again and again.
    World.reset()
    World.containers = { [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) },
                         [15] = { slots = 98, slot(BAR, 50) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } }, canView = false } }
    addon = World.login({})
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.bagUpdate(addon, 15)
    World.advance(5)
    local reads = 0
    local real = addon.Client.BankContents
    addon.Client.BankContents = function(self, kind) reads = reads + 1 return real(self, kind) end
    World.advance(5)
    addon.Client.BankContents = real
    T.eq("a bank that cannot be used is not read again", reads, 0)
    World.event(addon, "BANKFRAME_CLOSED")

    -- The comparison after the close is due, and the bags cannot be read on
    -- the frame after the update: it is made on a later frame.
    addon = bankVisit()
    World.containers[0][4] = slot(SILK, 2)
    World.bagUpdate(addon, 0)
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.3)
    World.containers[0][4] = nil                  -- a craft used the silk: a count that fell
    World.bagUpdate(addon, 0)
    local carried = World.containers[0]
    World.containers[0] = { slots = 0 }           -- the next frame the bags report no slots
    World.nextFrame()
    World.containers[0] = carried
    World.advance(1)
    total, bags, bank, meta = linen(addon)
    T.check("the comparison is made once the bags can be read: nothing marked, nothing left out",
        total == 105 and meta.bankPending == nil and meta.bankInDoubt == nil, tostring(total))
    World.advance(300)
    World.containers[0][4] = slot(LINEN, 3)       -- loot, minutes later
    World.bagUpdate(addon, 0)
    World.advance(1)
    total, bags, bank, meta = linen(addon)
    T.check("and a loot minutes later is no reason to leave the bank out", total == 108 and meta.bankPending == nil, tostring(total))
    -- The bags stay unreadable until the watch is over: the banks are marked.
    addon = bankVisit()
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(0.3)
    World.containers[0][3] = slot(LINEN, 60)      -- a count that rose; the bank holds linen
    World.bagUpdate(addon, 0)
    carried = World.containers[0]
    World.containers[0] = { slots = 0 }
    World.advance(1)
    World.containers[0] = carried
    World.advance(1)
    total, bags, bank, meta = linen(addon)
    T.check("the bags not readable until the second is over: the visit's banks are in doubt",
        meta.bankInDoubt == true and meta.accountInDoubt == true and meta.bankPending == nil, tostring(total))
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("and the dump says why", table.concat(lines, "\n"):find("marked=character (bags not readable for the comparison)", 1, true) ~= nil,
        table.concat(lines, "\n"))

    -- The session ended at the bank, and the character's id cannot be read
    -- for the first moments of the next one: the comparison with the note
    -- is tried again until it can be.
    local saved = {}
    addon = bankVisit(3, saved)
    World.event(addon, "PLAYER_LOGOUT")           -- with the bank open: a note is left
    local guid = World.guid
    World.guid = nil
    World.timers = {}
    World.time = World.time + 30
    addon = World.login(saved)
    World.bagUpdate(addon, 0)
    World.advance(3)
    World.guid = guid
    World.advance(2.5)
    total, bags, bank, meta = linen(addon)
    T.check("the id readable from the third second: within the next save the bags are compared",
        total == 105 and meta.bankPending == nil and meta.accountPending == nil and meta.bankInDoubt == nil, tostring(total))
    World.advance(600)
    total, bags, bank, meta = linen(addon)
    T.check("and the banks stay counted without any bag update", total == 105 and meta.bankPending == nil, tostring(total))
    World.event(addon, "PLAYER_LOGOUT")
end)

-- ===========================================================================
-- The note a session left at the bank names the banks its last visit could
-- use. A bank that another character read after the note was written is not
-- marked by it: that read is newer than anything the note could be about.
-- ===========================================================================
T.section("a note does not mark a bank read after it", function()
    local saved = {}
    local addon = bankVisit(3, saved)
    World.containers[0][2] = slot(LINEN, 5)
    World.event(addon, "PLAYER_LOGOUT")           -- the note: 5 linen carried
    -- The other character plays and reads the account bank.
    World.timers = {}
    World.time = World.time + 100
    World.serverTime = World.serverTime + 100
    local mainGuid, mainName = World.guid, World.name
    World.guid, World.name = "Player-4444-000000BB", "Alt Goldtooth"
    local mainBags = World.containers[0]
    World.containers[0] = { slots = 16, slot(HEARTHSTONE, 1, true) }
    local alt = World.login(saved)
    World.bagUpdate(alt, 0)
    World.advance(3)
    World.event(alt, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(alt, "BANKFRAME_CLOSED")
    World.advance(15)
    World.event(alt, "PLAYER_LOGOUT")
    -- The first character returns with other bags than the note says.
    World.timers = {}
    World.time = World.time + 100
    World.serverTime = World.serverTime + 100
    World.guid, World.name = mainGuid, mainName
    World.containers[0] = mainBags
    World.containers[0][3] = slot(LINEN, 7)
    addon = World.login(saved)
    World.bagUpdate(addon, 0)
    World.nextFrame()                                    -- compared on the next frame
    local total, bags, bank, meta = linen(addon)
    T.check("its own bank, named by the note, is in doubt", meta.bankInDoubt == true, tostring(total))
    T.check("the account bank, read by the other character since, is not", meta.accountInDoubt == nil
        and (select(2, World.scan(addon)))[BAR].bank == 50)
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("the dump says so", table.concat(lines, "\n"):find(
        "bags at the bank (from the last session): compared, different: character marked in doubt; account read since the note, not marked",
        1, true) ~= nil, table.concat(lines, "\n"))
end)

-- ===========================================================================
-- Two characters of one account: what the first one holds reaches the second.
-- ===========================================================================
-- A session that ends without its saved data written (the client is killed
-- or crashes) leaves nothing behind: the next one starts from what the
-- session before saved. A withdrawal made in the lost session is then in the
-- bags and still in the remembered bank. The last session left no note, so
-- the next one compares its bags with what the last save of them held.
T.section("a session that ended without its saved data written", function()
    local function copy(t)
        if type(t) ~= "table" then return t end
        local c = {}
        for k, v in pairs(t) do c[k] = copy(v) end
        return c
    end
    local function relog(saved)
        World.timers = {}
        World.time = World.time + 30
        World.serverTime = World.serverTime + 30
        return World.login(saved)
    end
    -- Session 1: a visit, an ordinary logout long after the close.
    local saved = {}
    local addon = bankVisit(3, saved)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(15)
    World.event(addon, "PLAYER_LOGOUT")
    local written = copy(saved)
    -- Session 2: 60 linen withdrawn at the bank, without hurry; then the
    -- client is killed: nothing of this session is written.
    addon = relog(saved)
    World.bagUpdate(addon, 0)
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.containers[6][1] = slot(LINEN, 40)
    World.containers[0][3] = slot(LINEN, 60)
    World.bagUpdate(addon, 6, 0)
    World.bagUpdateDelayed(addon)
    World.advance(1)
    World.event(addon, "BANKFRAME_CLOSED")
    World.advance(20)
    local total = linen(addon)
    T.eq("(the lost session counts it right)", total, 105)
    -- Session 3, from what session 1 wrote.
    addon = relog(written)
    local bags, bank, meta
    total, bags, bank, meta = linen(addon)
    T.check("before its bags are compared, the bank is left out: nothing counts twice", total == 65 and bank == nil
        and meta.bankPending == true, tostring(total))
    World.bagUpdate(addon, 0)
    World.nextFrame()
    total, bags, bank, meta = linen(addon)
    T.check("linen rose against the last save of the bags: the bank holding it is in doubt", total == 65 and bank == nil
        and meta.bankInDoubt == true and meta.bankPending == nil, tostring(total))
    T.eq("the Shopping tab says so", firstShoppingRow(addon), BANK_NOT_COUNTED_LINE)
    T.check("the account bank, which holds no linen, still counts", meta.accountInDoubt == nil
        and (select(2, World.scan(addon)))[BAR].bank == 50)
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    T.check("the dump says why", table.concat(lines, "\n"):find("bags as last saved (no note from the last session): "
        .. "compared, different: character marked in doubt; account not marked (nothing it holds rose)", 1, true) ~= nil,
        table.concat(lines, "\n"))
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    total, bags, bank, meta = linen(addon)
    T.check("the next visit reads it again: 65 carried, 40 in the bank", total == 105 and bank == 40 and meta.bankInDoubt == nil,
        tostring(total))
    notOver("a session that ended without its saved data written", addon)
end)

-- The times of a note and of a bank are read back from the saved table, and
-- a damaged one leans towards not counting: a note whose time is not a
-- number greater than zero and not later than a day after now marks the
-- banks it names. The exception for a bank read after the note holds only
-- for the account bank (another character may have read it since): nothing
-- but damage can make the character's own bank look read after its own
-- last session's note.
T.section("damaged times of a note and of a bank", function()
    local T0 = 20000 * 86400 + 3600
    -- The last session ended at the bank with a withdrawal of 20 linen on
    -- its way; its answer came after the logout: the linen is carried, the
    -- remembered bank still holds it.
    local function run(note, change)
        World.reset()
        local saved = { stock = { schema = 1, account = {}, characters = {
            [MAIN_GUID] = { name = "Main Goldtooth", world = "eu-pvp", faction = "Horde", region = "eu", seen = T0 - 100,
                            bags = { items = { [HEARTHSTONE] = 1 }, at = T0 - 100 },
                            bank = { items = { [LINEN] = 20 }, at = T0 - 100 },
                            bagsAtBank = note } } } }
        if change then change(saved.stock) end
        World.containers = { [0] = { slots = 16, slot(HEARTHSTONE, 1, true), slot(LINEN, 20) } }
        World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
        local addon = World.login(saved)
        World.bagUpdate(addon, 0)
        World.bagUpdateDelayed(addon)
        World.advance(3)
        local total, _, _, meta = linen(addon)
        local lines = {}
        addon.Inventory:RunDiagnostic(lines)
        return total, meta, ("\n" .. table.concat(lines, "\n") .. "\n"):match("\n(bags at the bank [^\n]*)\n")
    end
    local function note(at) return { items = { [HEARTHSTONE] = 1 }, banks = { character = true }, at = at } end
    local total, meta, line = run(note(T0 - 100))
    T.check("(a sound note: the risen linen marks the bank it names)", total == 20 and meta.bankInDoubt == true, total)
    for _, case in ipairs({ { "zero", 0 }, { "far back", -1e300 }, { "text", "x" }, { "missing", nil },
                            { "more than a day ahead", T0 + 2 * 86400 } }) do
        total, meta, line = run(note(case[2]))
        T.check("a note whose time is " .. case[1] .. ": the bank it names is in doubt, the linen counts once",
            total == 20 and meta.bankInDoubt == true, tostring(total))
        T.eq("and the dump says why", line,
            "bags at the bank (from the last session): unknown (the note's time is damaged): character marked in doubt")
    end
    -- Bags that equal the note: a damaged note still marks.
    World.reset()
    total, meta = run(note(0), function(stock) stock.characters[MAIN_GUID].bagsAtBank.items = { [HEARTHSTONE] = 1, [LINEN] = 20 } end)
    T.check("a damaged note marks even when the bags equal it", meta.bankInDoubt == true, tostring(total))
    -- The character's own bank looks read after the note: not an exception.
    total, meta, line = run(note(T0 - 100), function(stock) stock.characters[MAIN_GUID].bank.at = T0 - 50 end)
    T.check("the own bank saved after its own note is marked all the same", total == 20 and meta.bankInDoubt == true, tostring(total))
    T.eq("the dump says so", line, "bags at the bank (from the last session): compared, different: character marked in doubt")
    total, meta = run(note(T0 - 100), function(stock) stock.characters[MAIN_GUID].bank.at = 1e300 end)
    T.check("the own bank's time far ahead: not counted (and marked)", total == 20 and meta.bankInDoubt == true, tostring(total))
    -- The account bank read after the note: the exception holds while both
    -- times are sound.
    local function withAccount(noteAt, accountAt)
        return run({ items = { [HEARTHSTONE] = 1 }, banks = { character = true, account = true }, at = noteAt }, function(stock)
            stock.account.eu = { items = { [LINEN] = 7 }, at = accountAt, world = "eu-pvp", faction = "Horde" }
        end)
    end
    total, meta = withAccount(T0 - 100, T0 - 50)
    T.check("the account bank read after a sound note is not marked by it", meta.accountInDoubt == nil and total == 27, tostring(total))
    total, meta = withAccount(0, T0 - 50)
    T.check("after a damaged note it is", meta.accountInDoubt == true and total == 20, tostring(total))
    total, meta = withAccount(T0 - 100, T0 + 3 * 86400)
    T.check("and an account bank whose time is damaged is not counted", meta.accountInDoubt == true and total == 20, tostring(total))
end)

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
    -- ask the adapter for the bank any more, whatever arrives. (An update of
    -- a bank container would mark that bank: "the answer of a last move
    -- arrives after the close".)
    World.advance(11)
    World.containers[6] = { slots = 28 }
    World.containers[8] = { slots = 12 }
    World.containers[15] = { slots = 98 }
    bankReads = 0
    World.bagUpdate(banker, 0)
    World.advance(5)
    combined, breakdown, meta = World.scan(banker)
    T.eq("after the close the bank is not asked for again", bankReads, 0)
    T.check("after the close the bank is what was seen while it was open",
        breakdown[LINEN].bank == 40 and breakdown[SILK].bank == 30 and breakdown[BAR].bank == 50, breakdown[LINEN].bank)
    -- A visit so short that its second look is still waiting when the window
    -- closes: that look must not be taken from the closed bank.
    World.containers[6] = { slots = 28, slot(LINEN, 40), slot(SILK, 30) }
    World.containers[8] = { slots = 12, slot(WOOL, 10, true) }
    World.containers[15] = { slots = 98, slot(BAR, 50) }
    World.event(banker, "BANKFRAME_OPENED")
    World.advance(0.2)
    World.event(banker, "BANKFRAME_CLOSED")
    World.containers[6] = { slots = 28 }
    World.containers[8] = { slots = 12 }
    World.containers[15] = { slots = 98 }
    bankReads = 0
    World.advance(5)
    T.eq("a look that was still waiting is not taken after the close", bankReads, 0)
    T.check("and the short visit kept what its opening read saw", (memory:OwnBank(World.guid))[LINEN] == 40
        and select(3, memory:OwnBank(World.guid)) == false)

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
        and saved.stock.account.eu ~= nil)
end)

T.finish()
