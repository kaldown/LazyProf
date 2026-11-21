-- scripts/test_charstore.lua
--
-- Per-character planner data (targets, pins, craft choices, last tab) is kept
-- account-wide under the character's GUID, so it does not depend on the
-- character or realm name.
--
-- Run from the addon root:  lua5.1 scripts/test_charstore.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })
local guid = "Player-1-0000AAAA"
_G.UnitGUID = function(unit) return unit == "player" and guid or nil end

local LazyProf = harness.loadLazyProf({ "Core/Constants.lua", "Core/Utils.lua", "Core/Config.lua", "Core/CharStore.lua" })
LazyProf.db.global = { characters = {} }
local Store = LazyProf.CharStore

T.section("store", function()
    T.check("defaults declare the account-wide table",
        type(LazyProf.defaults.global) == "table" and type(LazyProf.defaults.global.characters) == "table")

    local a = Store:Get()
    T.check("Get returns a table", type(a) == "table")
    T.check("Get returns the same table again", Store:Get() == a)
    T.check("the table sits under the GUID", LazyProf.db.global.characters[guid] == a)
    T.check("craft choices table exists", type(a.craftChoices) == "table")

    local prof = Store:Profession("tailoring")
    T.check("Profession creates a record with a pin list", type(prof) == "table" and type(prof.pins) == "table")
    T.check("Profession returns the same record again", Store:Profession("tailoring") == prof)
    T.check("no target by default", prof.target == nil)
    prof.target = 225
    T.eq("stored target is kept", Store:Profession("tailoring").target, 225)
    T.check("another profession has its own record", Store:Profession("alchemy") ~= prof)

    guid = "Player-1-0000BBBB"
    local b = Store:Get()
    T.check("another character has another table", b ~= a)
    T.check("and no target of the first one", Store:Profession("tailoring").target == nil)

    guid = nil
    local temp = Store:Get()
    T.check("no GUID yet: still a usable table", type(temp) == "table" and type(temp.craftChoices) == "table")
    local count = 0
    for _ in pairs(LazyProf.db.global.characters) do count = count + 1 end
    T.eq("no GUID yet: nothing is saved for it", count, 2)

    guid = "Player-1-0000AAAA"
    T.check("the first character's data is back", Store:Get() == a and Store:Profession("tailoring").target == 225)

    LazyProf.db.global = nil
    T.check("no database yet: still a usable table", type(Store:Get()) == "table")
end)

T.finish()
