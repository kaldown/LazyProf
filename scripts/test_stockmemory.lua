-- scripts/test_stockmemory.lua
--
-- The stock memory: what each character had in its bags and bank when LazyProf
-- last saw them, and the account-wide bank per world. It is what lets bank and
-- alt stock count when no inventory addon is installed. Pure: the character,
-- the items and the time are all passed in.
--
-- Run from the addon root:  lua5.1 scripts/test_stockmemory.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })
local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Modules/Inventory/StockMemory.lua",
})
local Memory = LazyProf.StockMemory

local DAY = 86400
local NOW = 20000 * DAY + 3600   -- one hour into a UTC day

local function fresh()
    LazyProf.db.global = { characters = {} }
end

local function who(guid, name, world, faction)
    return { guid = guid, name = name, world = world or "eu-pvp", faction = faction or "Alliance" }
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local MAIN = who("Player-1-MAIN", "Main Character")

T.section("store", function()
    T.check("defaults declare the store", type(LazyProf.defaults.global.stock) == "table")
    -- The database strips saved values that equal a default and puts the
    -- default back on load: a format number among the defaults would relabel
    -- old data the day the default changes.
    T.check("the format number is not a default", LazyProf.defaults.global.stock.schema == nil)
    fresh()
    T.check("nothing remembered at first: no bank", Memory:OwnBank(MAIN.guid) == nil)
    T.eq("nothing remembered at first: no alts", #Memory:Alts(MAIN), 0)
    T.eq("the store carries its format number once it exists", LazyProf.db.global.stock.schema, 1)
end)

T.section("save and read back", function()
    fresh()
    local items, bound = { [2589] = 40, [2592] = 3 }, { [2592] = 3 }
    T.check("a bank save reports success", Memory:SaveBank(MAIN, items, bound, NOW) == true)
    local got, at = Memory:OwnBank(MAIN.guid)
    T.check("the bank is read back", got ~= nil and got[2589] == 40)
    T.eq("with the time it was seen", at, NOW)
    T.eq("the owner's own bank keeps its soulbound items", got[2592], 3)

    -- The memory keeps its own copy.
    items[2589] = 1
    T.eq("changing the caller's table afterwards changes nothing", (Memory:OwnBank(MAIN.guid))[2589], 40)

    -- A second save replaces; nothing is added to the old one.
    Memory:SaveBank(MAIN, { [4306] = 7 }, {}, NOW + 60)
    got, at = Memory:OwnBank(MAIN.guid)
    T.check("a second save replaces the first", got[4306] == 7 and got[2589] == nil and got[2592] == nil)
    T.eq("and carries the new time", at, NOW + 60)
    T.eq("one record per character", count(LazyProf.db.global.stock.characters), 1)

    Memory:SaveBags(MAIN, { [2589] = 5 }, {}, NOW + 120)
    T.eq("saving the bags keeps the bank", (Memory:OwnBank(MAIN.guid))[4306], 7)
    T.eq("still one record", count(LazyProf.db.global.stock.characters), 1)

    T.check("another character has no bank", Memory:OwnBank("Player-1-OTHER") == nil)
    T.check("no guid asked: nothing", Memory:OwnBank(nil) == nil)

    -- Counts that are not positive numbers are not kept.
    Memory:SaveBank(MAIN, { [1] = 0, [2] = -3, [3] = "x", [4] = 2 }, {}, NOW)
    got = Memory:OwnBank(MAIN.guid)
    T.check("only positive counts are kept", got[4] == 2 and got[1] == nil and got[2] == nil and got[3] == nil)
end)

T.section("nothing is saved without a character or a time", function()
    fresh()
    T.check("no identity", Memory:SaveBags(nil, { [1] = 1 }, {}, NOW) == false)
    T.check("no guid", Memory:SaveBags({ name = "X", world = "eu-pvp", faction = "Alliance" }, { [1] = 1 }, {}, NOW) == false)
    T.check("no guid: bank", Memory:SaveBank({ name = "X" }, { [1] = 1 }, {}, NOW) == false)
    T.check("no time", Memory:SaveBags(MAIN, { [1] = 1 }, {}, nil) == false)
    T.check("no items table", Memory:SaveBank(MAIN, nil, {}, NOW) == false)
    T.check("account bank without a world", Memory:SaveAccountBank(nil, { [1] = 1 }, NOW) == false)
    T.check("account bank without items", Memory:SaveAccountBank("eu-pvp", nil, NOW) == false)
    T.eq("no record was made", count(LazyProf.db.global.stock and LazyProf.db.global.stock.characters), 0)

    local saved = LazyProf.db
    LazyProf.db = nil
    T.check("no database: a save does nothing", Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW) == false)
    T.check("no database: nothing to read", Memory:OwnBank(MAIN.guid) == nil and #Memory:Alts(MAIN) == 0
        and Memory:AccountBank("eu-pvp") == nil)
    T.check("no database: prune and forget do not fail", pcall(Memory.Prune, Memory, NOW) and pcall(Memory.Forget, Memory))
    LazyProf.db = saved
end)

T.section("alts", function()
    fresh()
    local zed = who("Player-1-ZED", "Zed Alt")
    local amy = who("Player-1-AMY", "Amy Alt")
    local horde = who("Player-1-HORDE", "Horde Alt", "eu-pvp", "Horde")
    local other = who("Player-1-NORMAL", "Normal Alt", "eu-normal")
    Memory:SaveBags(MAIN, { [2589] = 9 }, {}, NOW)
    Memory:SaveBags(zed, { [2589] = 20, [2592] = 5, [774] = 2 }, { [2592] = 2, [774] = 2 }, NOW - DAY)
    Memory:SaveBank(zed, { [2589] = 100, [6948] = 1 }, { [6948] = 1 }, NOW - 3 * DAY)
    Memory:SaveBags(amy, { [4306] = 12 }, {}, NOW - 2 * DAY)
    Memory:SaveBags(horde, { [2589] = 500 }, {}, NOW)
    Memory:SaveBags(other, { [2589] = 700 }, {}, NOW)

    local alts = Memory:Alts(MAIN)
    T.eq("same world and faction only, and never the character itself", #alts, 2)
    T.check("sorted by name", alts[1].name == "Amy Alt" and alts[2].name == "Zed Alt")
    T.eq("guid is given", alts[2].guid, "Player-1-ZED")
    T.eq("an alt's bags", alts[2].bags[2589], 20)
    T.eq("soulbound counts are taken off", alts[2].bags[2592], 3)
    T.check("an item that is all soulbound is left out", alts[2].bags[774] == nil)
    T.eq("when the bags were seen", alts[2].bagsAt, NOW - DAY)
    T.eq("an alt's bank", alts[2].bank[2589], 100)
    T.check("soulbound in the bank is left out too", alts[2].bank[6948] == nil)
    T.eq("when the bank was seen", alts[2].bankAt, NOW - 3 * DAY)
    T.check("an alt whose bank was never seen has none", alts[1].bank == nil and alts[1].bankAt == nil)
    T.eq("its bags are there", alts[1].bags[4306], 12)

    -- What is handed out is not the saved table.
    alts[2].bags[2589] = 1
    T.eq("the list is a copy", Memory:Alts(MAIN)[2].bags[2589], 20)

    -- The owner's own bank is not thinned.
    Memory:SaveBank(MAIN, { [6948] = 1 }, { [6948] = 1 }, NOW)
    T.eq("soulbound stays in the owner's own bank", (Memory:OwnBank(MAIN.guid))[6948], 1)

    T.eq("seen from the other faction", #Memory:Alts(horde), 0)
    T.eq("seen from the other world", #Memory:Alts(other), 0)
    T.eq("without a world nothing is an alt", #Memory:Alts({ guid = "Player-1-X", faction = "Alliance" }), 0)
    T.eq("without a faction nothing is an alt", #Memory:Alts({ guid = "Player-1-X", world = "eu-pvp" }), 0)
    T.eq("without a guid nothing is an alt", #Memory:Alts({ world = "eu-pvp", faction = "Alliance" }), 0)
end)

T.section("one name, one character", function()
    -- A name belongs to one character of a world. A second record under the
    -- same name is a character that is gone (or the same one under an older
    -- id): its stock must not be counted beside the real one.
    fresh()
    Memory:SaveBags(MAIN, { [2589] = 9 }, {}, NOW)
    Memory:SaveBags(who("Player-1-OLDMAIN", "Main Character"), { [2589] = 50 }, {}, NOW - 10 * DAY)
    T.eq("a record under the asking character's own name is not an alt", #Memory:Alts(MAIN), 0)

    Memory:SaveBags(who("Player-1-GONE", "Bank Alt"), { [2589] = 30 }, {}, NOW - 20 * DAY)
    Memory:SaveBags(who("Player-1-NEW", "Bank Alt"), { [2589] = 4 }, {}, NOW - DAY)
    local alts = Memory:Alts(MAIN)
    T.eq("two records under one name count once", #alts, 1)
    T.eq("the one seen last", alts[1].guid, "Player-1-NEW")
    T.eq("with its own stock", alts[1].bags[2589], 4)

    -- A record whose name could not be read cannot be shown, so it is not counted.
    Memory:SaveBags({ guid = "Player-1-NONAME", world = "eu-pvp", faction = "Alliance" }, { [2589] = 77 }, {}, NOW)
    T.eq("a record without a name is not an alt", #Memory:Alts(MAIN), 1)
    -- A later save that cannot read the name keeps the one it had.
    Memory:SaveBags({ guid = "Player-1-NEW", world = "eu-pvp", faction = "Alliance" }, { [2589] = 6 }, {}, NOW)
    alts = Memory:Alts(MAIN)
    T.check("a save without a name keeps the remembered name", #alts == 1 and alts[1].name == "Bank Alt"
        and alts[1].bags[2589] == 6)
end)

T.section("account bank", function()
    fresh()
    T.check("none at first", Memory:AccountBank("eu-pvp") == nil)
    T.check("a save reports success", Memory:SaveAccountBank("eu-pvp", { [2589] = 60 }, NOW) == true)
    local items, at = Memory:AccountBank("eu-pvp")
    T.check("read back per world", items ~= nil and items[2589] == 60 and at == NOW)
    T.check("another world has its own", Memory:AccountBank("eu-normal") == nil)
    Memory:SaveAccountBank("eu-pvp", { [4306] = 2 }, NOW + 5)
    items, at = Memory:AccountBank("eu-pvp")
    T.check("a second save replaces", items[4306] == 2 and items[2589] == nil and at == NOW + 5)
    T.check("no world asked: nothing", Memory:AccountBank(nil) == nil)
end)

T.section("prune", function()
    fresh()
    local old = who("Player-1-OLD", "Old Alt")
    local kept = who("Player-1-KEPT", "Kept Alt")
    local edge = who("Player-1-EDGE", "Edge Alt")
    local away = who("Player-1-AWAY", "Away Alt", "us-normal")
    Memory:SaveBags(old, { [1] = 1 }, {}, NOW - 181 * DAY)
    Memory:SaveBags(kept, { [1] = 1 }, {}, NOW - 179 * DAY)
    Memory:SaveBags(edge, { [1] = 1 }, {}, NOW - 180 * DAY)
    Memory:SaveBags(away, { [1] = 1 }, {}, NOW - 200 * DAY)
    Memory:SaveAccountBank("eu-pvp", { [1] = 1 }, NOW - 300 * DAY)
    Memory:SaveAccountBank("us-normal", { [1] = 1 }, NOW - 200 * DAY)
    T.eq("two characters are dropped", Memory:Prune(NOW), 2)
    local chars = LazyProf.db.global.stock.characters
    T.check("not seen for 181 days: dropped", chars[old.guid] == nil)
    T.check("seen 179 days ago: kept", chars[kept.guid] ~= nil)
    T.check("seen exactly 180 days ago: kept", chars[edge.guid] ~= nil)
    T.check("the account bank stays while a character of its world is remembered", Memory:AccountBank("eu-pvp") ~= nil)
    T.check("and goes with the last character of its world", Memory:AccountBank("us-normal") == nil)

    -- "Seen" is the last save of either kind.
    fresh()
    Memory:SaveBags(old, { [1] = 1 }, {}, NOW - 400 * DAY)
    Memory:SaveBank(old, { [1] = 1 }, {}, NOW - 10 * DAY)
    Memory:Prune(NOW)
    T.check("a bank seen lately keeps the character", LazyProf.db.global.stock.characters[old.guid] ~= nil)
    fresh()
    Memory:SaveBank(old, { [1] = 1 }, {}, NOW - 10 * DAY)
    Memory:SaveBags(old, { [1] = 1 }, {}, NOW - 400 * DAY)   -- an older time must not move "seen" back
    Memory:Prune(NOW)
    T.check("an older save does not move the last-seen time back", LazyProf.db.global.stock.characters[old.guid] ~= nil)

    -- The character being played is here, however long ago it was saved.
    fresh()
    Memory:SaveBank(MAIN, { [2589] = 8 }, {}, NOW - 500 * DAY)
    Memory:SaveAccountBank("eu-pvp", { [1] = 1 }, NOW - 500 * DAY)
    T.eq("the character being played is never dropped", Memory:Prune(NOW, MAIN.guid), 0)
    T.check("its bank is still remembered", (Memory:OwnBank(MAIN.guid))[2589] == 8)
    T.check("and its world's account bank", Memory:AccountBank("eu-pvp") ~= nil)
    T.check("prune without a time does nothing", Memory:Prune(nil) == 0 and Memory:OwnBank(MAIN.guid) ~= nil)
end)

T.section("forget", function()
    fresh()
    Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW)
    Memory:SaveBank(MAIN, { [1] = 1 }, {}, NOW)
    Memory:SaveBags(who("Player-1-ALT", "Alt"), { [1] = 1 }, {}, NOW)
    Memory:SaveAccountBank("eu-pvp", { [1] = 1 }, NOW)
    Memory:Forget()
    T.check("no bank", Memory:OwnBank(MAIN.guid) == nil)
    T.eq("no alts", #Memory:Alts(MAIN), 0)
    T.check("no account bank", Memory:AccountBank("eu-pvp") == nil)
    T.eq("no records", count(LazyProf.db.global.stock.characters), 0)
    T.check("saving works again afterwards", Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW) == true)
end)

T.section("another format is left alone", function()
    -- Data written in a format this version does not know (a newer build's)
    -- is neither read nor written over.
    fresh()
    local theirs = { schema = 2, characters = { [MAIN.guid] = { something = "else" } } }
    LazyProf.db.global.stock = theirs
    T.check("nothing is read from it", Memory:OwnBank(MAIN.guid) == nil and #Memory:Alts(MAIN) == 0)
    T.check("nothing is saved into it", Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW) == false
        and Memory:SaveBank(MAIN, { [1] = 1 }, {}, NOW) == false
        and Memory:SaveAccountBank("eu-pvp", { [1] = 1 }, NOW) == false)
    Memory:Prune(NOW + 1000 * DAY)
    Memory:Forget()
    T.check("it is untouched", LazyProf.db.global.stock == theirs and theirs.schema == 2
        and theirs.characters[MAIN.guid].something == "else" and theirs.characters[MAIN.guid].bags == nil)
    T.eq("the summary says which format it found", Memory:Summary().schema, 2)
    T.check("and that it is not used", Memory:Summary().usable == false)
end)

T.section("age text", function()
    local HOUR = 3600
    -- Ages are elapsed time, never calendar days: something seen twenty
    -- minutes ago must not read "1 day ago" because midnight lay in between.
    T.eq("the same moment", Memory.AgeText(NOW, NOW), "less than an hour ago")
    T.eq("twenty minutes", Memory.AgeText(NOW, NOW - 20 * 60), "less than an hour ago")
    T.eq("one second short of an hour", Memory.AgeText(NOW, NOW - HOUR + 1), "less than an hour ago")
    T.eq("one hour", Memory.AgeText(NOW, NOW - HOUR), "1 hour ago")
    T.eq("an hour and fifty-nine minutes", Memory.AgeText(NOW, NOW - 2 * HOUR + 60), "1 hour ago")
    T.eq("two hours", Memory.AgeText(NOW, NOW - 2 * HOUR), "2 hours ago")
    T.eq("twenty-three hours", Memory.AgeText(NOW, NOW - 23 * HOUR), "23 hours ago")
    T.eq("one second short of a day", Memory.AgeText(NOW, NOW - DAY + 1), "23 hours ago")
    T.eq("one day", Memory.AgeText(NOW, NOW - DAY), "1 day ago")
    T.eq("forty-seven hours are still one day", Memory.AgeText(NOW, NOW - 47 * HOUR), "1 day ago")
    T.eq("two days", Memory.AgeText(NOW, NOW - 2 * DAY), "2 days ago")
    T.eq("forty days", Memory.AgeText(NOW, NOW - 40 * DAY), "40 days ago")
    local midnight = 20000 * DAY
    T.eq("twenty minutes across a UTC midnight", Memory.AgeText(midnight + 600, midnight - 600), "less than an hour ago")
    T.eq("a time ahead of the clock (a clock that went back)", Memory.AgeText(NOW, NOW + 3 * DAY), "less than an hour ago")
    T.check("nothing to say without a time", Memory.AgeText(NOW, nil) == nil and Memory.AgeText(nil, NOW) == nil
        and Memory.AgeText(NOW, "yesterday") == nil)
    for _, at in ipairs({ NOW, NOW - 5 * HOUR, NOW - 5 * DAY }) do
        T.check("plain ASCII: " .. Memory.AgeText(NOW, at), not Memory.AgeText(NOW, at):find("[\128-\255]"))
    end
end)

T.section("summary", function()
    fresh()
    Memory:SaveBags(MAIN, { [1] = 1, [2] = 2 }, {}, NOW)
    Memory:SaveBank(MAIN, { [3] = 3 }, {}, NOW - DAY)
    Memory:SaveBags(who("Player-1-ALT", "Alt", "eu-normal", "Horde"), { [1] = 1 }, {}, NOW - 2 * DAY)
    Memory:SaveAccountBank("eu-pvp", { [1] = 1, [2] = 1, [3] = 1 }, NOW - 4 * DAY)
    local s = Memory:Summary()
    T.check("usable, format 1", s.usable == true and s.schema == 1)
    T.eq("every character, whatever its world", #s.characters, 2)
    local alt, main = s.characters[1], s.characters[2]
    T.check("sorted by world, then name", alt.world == "eu-normal" and main.world == "eu-pvp")
    T.check("who it is", main.guid == MAIN.guid and main.name == "Main Character" and main.faction == "Alliance")
    T.check("bags: distinct items and when", main.bagItems == 2 and main.bagsAt == NOW)
    T.check("bank: distinct items and when", main.bankItems == 1 and main.bankAt == NOW - DAY)
    T.check("a bank never seen", alt.bankItems == nil and alt.bankAt == nil)
    T.eq("last seen", main.seen, NOW)
    T.check("account banks", #s.account == 1 and s.account[1].world == "eu-pvp" and s.account[1].items == 3
        and s.account[1].at == NOW - 4 * DAY)
end)

T.finish()
