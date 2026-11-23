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

T.finish()
