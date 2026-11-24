-- scripts/test_stockreset.lua
--
-- "Reset All Settings" and /lp reset against the real database library
-- (Libs/Ace3/AceDB-3.0), with the real WoW Forever adapter, scanner and stock
-- memory (scripts/lib/stockworld.lua is the client). What LazyProf remembers
-- of the characters' bags and banks is not a setting: a reset must keep it,
-- count it in the very next scan and still have it after logout.
--
-- Run from the addon root:  lua5.1 scripts/test_stockreset.lua

package.path = "./?.lua;" .. package.path
local T = require("scripts.lib.check").new()
local World = require("scripts.lib.stockworld")
World.install()
local slot = World.slot

local LINEN, BAR = 2589, 2770
local MAIN_GUID = "Player-4444-000000AA"

-- What the database library asks of the client.
local frames = {}
_G.CreateFrame = function()
    local frame = { events = {} }
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:UnregisterAllEvents() self.events = {} end
    function frame:SetScript(_, fn) self.script = fn end
    function frame:Hide() end
    function frame:Show() end
    frames[#frames + 1] = frame
    return frame
end
_G.GetRealmName = function() return "Shard-7" end      -- the database's own profile key; never the stock's
_G.UnitName = function() return "Main" end
_G.UnitNameUnmodified = function() return "Main", "Goldtooth" end
_G.UnitClass = function() return "Mage", "MAGE" end
_G.UnitRace = function() return "Orc", "Orc" end
_G.GetLocale = function() return "enUS" end
_G.securecallfunction = function(fn, ...) return fn(...) end
_G.strlenutf8 = string.len
_G.strmatch, _G.format, _G.tinsert, _G.strlower = string.match, string.format, table.insert, string.lower
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
dofile("Libs/Ace3/LibStub/LibStub.lua")
dofile("Libs/Ace3/CallbackHandler-1.0/CallbackHandler-1.0.lua")
dofile("Libs/Ace3/AceDB-3.0/AceDB-3.0.lua")
-- The addon library only has to hand the addon table back.
local addonLib = LibStub:NewLibrary("AceAddon-3.0", 1)
addonLib.NewAddon = function(_, target) return target end

-- The client saving the variables at logout: the database tidies them first.
local function logout()
    for _, frame in ipairs(frames) do
        if frame.events.PLAYER_LOGOUT and frame.script then frame.script(frame, "PLAYER_LOGOUT") end
    end
end

-- One session on the saved variable LazyProfDB, started the way the game
-- starts the addon. session.recalcs lists the recalculations asked for.
local function session()
    World.timers = {}
    local addon = { Utils = {}, events = {}, recalcs = {}, printed = {} }
    function addon:Debug() end
    function addon:IsDebugEnabled() return false end
    function addon:RegisterEvent(event, handler) self.events[event] = handler end
    function addon:RegisterChatCommand() end
    function addon:Print(message) self.printed[#self.printed + 1] = message end
    local function load(path) assert(loadfile(path))("LazyProf", addon) end
    load("Core/Constants.lua")
    load("Core/Utils.lua")
    load("Core/Client/Family.lua")
    load("Core/Client/Classic.lua")
    load("Core/Client/Forever.lua")
    load("Core/Config.lua")
    load("Modules/Inventory/StockMemory.lua")
    load("Modules/Inventory/Scanner.lua")
    load("Core/Init.lua")
    addon.SetupConfig = nil                         -- the options window's libraries are not loaded here
    addon.Client.Start = function() end             -- nor is the profession window
    addon.Recalculate = function(self, reason) self.recalcs[#self.recalcs + 1] = tostring(reason) end
    addon:OnInitialize()
    addon:OnEnable()
    return addon
end

-- The option of that name, wherever it sits in the options tree.
local function option(options, name)
    for key, entry in pairs(options.args or {}) do
        if key == name then return entry end
        if type(entry) == "table" and entry.args then
            local found = option(entry, name)
            if found then return found end
        end
    end
    return nil
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- A character with a bank, an alt and an account bank remembered, and a few
-- settings moved off their defaults.
local function remembered()
    World.reset()
    World.containers = { [0] = { slots = 16, slot(LINEN, 5) }, [6] = { slots = 28, slot(LINEN, 100) },
                         [15] = { slots = 98, slot(BAR, 50) } }
    World.bank = { [0] = { tabs = { { ID = 6 } } }, [2] = { tabs = { { ID = 15 } } } }
    _G.LazyProfDB = nil
    local addon = session()
    World.advance(3)
    World.event(addon, "BANKFRAME_OPENED")
    World.advance(3)
    World.event(addon, "BANKFRAME_CLOSED")
    addon.db.global.stock.characters.ALT = { name = "Alt Goldtooth", world = "eu-pvp", faction = "Horde",
        seen = World.serverTime, bags = { items = { [LINEN] = 20 }, at = World.serverTime } }
    addon.Inventory:ForgetAltsPart()
    addon.db.profile.marginPercent = 25
    addon.db.global.vendorPrices[LINEN] = 12
    World.nextFrame()
    return addon
end

local function linen(addon)
    addon.Inventory:InvalidateCache()
    local combined, breakdown = addon.Inventory:ScanAll()
    return combined[LINEN], combined[BAR], breakdown
end

-- ===========================================================================
T.section("/lp reset keeps the remembered stock", function()
    local addon = remembered()
    local total, bars = linen(addon)
    T.check("before: bags, bank, alt and account bank", total == 125 and bars == 50, tostring(total) .. "/" .. tostring(bars))
    local default = addon.defaults.profile.marginPercent
    T.check("fixture: a setting is off its default", default ~= 25)

    addon.recalcs = {}
    addon:SlashCommand("reset")
    T.eq("the setting is back at its default", addon.db.profile.marginPercent, default)
    T.check("the other account-wide data went with it, as before", addon.db.global.vendorPrices[LINEN] == nil)
    T.check("the remembered characters are still there", type(addon.db.global.stock) == "table"
        and addon.db.global.stock.schema == 1 and count(addon.db.global.stock.characters) == 2,
        count(addon.db.global.stock and addon.db.global.stock.characters))
    -- No frame has passed: the scan must not answer from before the reset.
    local combined = addon.Inventory:ScanAll()
    T.check("the very next scan counts them", combined[LINEN] == 125 and combined[BAR] == 50, combined[LINEN])
    T.check("a recalculation is asked for, so that what is shown is redrawn", #addon.recalcs == 1, #addon.recalcs)
    T.check("the player is told", #addon.printed > 0)

    World.advance(5)
    total, bars = linen(addon)
    T.check("five seconds later still", total == 125 and bars == 50, total)
    logout()
    T.check("after logout the saved file still holds the stock",
        type(_G.LazyProfDB.global) == "table" and type(_G.LazyProfDB.global.stock) == "table"
        and _G.LazyProfDB.global.stock.characters[MAIN_GUID] ~= nil and _G.LazyProfDB.global.stock.characters.ALT ~= nil
        and _G.LazyProfDB.global.stock.account["eu-pvp"] ~= nil)
    addon = session()
    World.advance(3)
    total, bars = linen(addon)
    T.check("and the next session counts it", total == 125 and bars == 50, total)
end)

-- ===========================================================================
T.section("Reset All Settings keeps the remembered stock", function()
    local addon = remembered()
    local button = option(addon.options, "resetDB")
    T.check("the button exists and asks first", button ~= nil and button.type == "execute" and button.confirm == true)
    T.check("it says that remembered characters are kept and where they are forgotten",
        tostring(button.desc):find("LazyProf remembers for your characters are kept", 1, true) ~= nil
        and tostring(button.desc):find("Forget remembered characters", 1, true) ~= nil, button.desc)
    addon.recalcs = {}
    button.func()
    T.eq("the setting is back at its default", addon.db.profile.marginPercent, addon.defaults.profile.marginPercent)
    local combined = addon.Inventory:ScanAll()
    T.check("the very next scan counts bank, alt and account bank", combined[LINEN] == 125 and combined[BAR] == 50, combined[LINEN])
    T.check("a recalculation is asked for", #addon.recalcs == 1, #addon.recalcs)
    logout()
    T.check("after logout the saved file still holds the stock", type(_G.LazyProfDB.global) == "table"
        and type(_G.LazyProfDB.global.stock) == "table" and count(_G.LazyProfDB.global.stock.characters) == 2)

    -- "Forget remembered characters" is the button that forgets them.
    addon = session()
    World.advance(3)
    option(addon.options, "forgetStock").func()
    T.eq("forgetting is its own button: only the bags are left", (linen(addon)), 5)
end)

-- ===========================================================================
T.section("a reset and the Self-Found setting", function()
    -- The setting is per character and goes back to off with the reset. The
    -- record of the character must say at once that it can send again.
    local addon = remembered()
    addon.db.char.selfFoundMode = true
    addon.Inventory:OnSendingChanged()
    T.check("fixture: the record says it cannot send", addon.db.global.stock.characters[MAIN_GUID].noSend == true)
    T.eq("fixture: a Self-Found character counts its own bank only", (linen(addon)), 105)
    addon:SlashCommand("reset")
    T.check("the setting is off again", addon.db.char.selfFoundMode == false)
    T.check("and the record says so without waiting for a save", addon.db.global.stock.characters[MAIN_GUID].noSend == nil)
    T.eq("the alt counts again in the next scan", (addon.Inventory:ScanAll())[LINEN], 125)

    -- A character the game itself marks Self-Found is not a matter of the
    -- settings: it stays one through a reset.
    addon = remembered()
    World.gameSelfFound = true
    addon.Inventory:OnSendingChanged()
    T.check("fixture: marked by the game, the record says it cannot send",
        addon.db.char.selfFoundMode == false and addon.db.global.stock.characters[MAIN_GUID].noSend == true)
    addon:SlashCommand("reset")
    T.check("after the reset the record still says so", addon.db.global.stock.characters[MAIN_GUID].noSend == true)
    T.eq("and the scan still counts its own bank only", (addon.Inventory:ScanAll())[LINEN], 105)
    World.gameSelfFound = false
end)

-- ===========================================================================
T.section("a reset and saved stock that is not the addon's", function()
    -- A format this version does not read is not the reset's to delete either.
    local addon = remembered()
    local theirs = { schema = 2, characters = { X = { something = "else" } } }
    addon.db.global.stock = theirs
    addon:SlashCommand("reset")
    T.check("another format is kept untouched", addon.db.global.stock == theirs and theirs.schema == 2
        and theirs.characters.X.something == "else")
    -- A value that is no table at all is not carried over: the reset leaves
    -- the empty default, and the memory starts again.
    addon = remembered()
    addon.db.global.stock = "broken"
    local ok, err = pcall(addon.SlashCommand, addon, "reset")
    T.check("a damaged value does not stop the reset", ok, err)
    T.check("and is not put back", type(addon.db.global.stock) == "table")
    World.bagUpdate(addon, 0)
    World.advance(3)
    T.check("the character is remembered again by itself", addon.db.global.stock.characters ~= nil
        and addon.db.global.stock.characters[MAIN_GUID] ~= nil)

    -- With Syndicator installed the memory is not in use, and still not the reset's to delete.
    addon = remembered()
    _G.Syndicator = { API = { GetCurrentCharacter = function() return nil end, GetAllCharacters = function() return {} end } }
    local before = addon.db.global.stock
    ok, err = pcall(addon.SlashCommand, addon, "reset")
    _G.Syndicator = nil
    T.check("with Syndicator the reset works", ok, err)
    T.check("and the remembered stock is kept as it was", addon.db.global.stock == before and count(before.characters) == 2)
end)

T.finish()
