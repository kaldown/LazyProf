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
    T.check("reading makes nothing", LazyProf.db.global.stock == nil)
    Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW)
    T.eq("the store carries its format number from the first save", LazyProf.db.global.stock.schema, 1)
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

    -- What is handed out is a copy: a caller cannot change what is remembered.
    got = Memory:OwnBank(MAIN.guid)
    got[4306] = 9999
    T.eq("the bank handed out is a copy", (Memory:OwnBank(MAIN.guid))[4306], 7)

    T.check("another character has no bank", Memory:OwnBank("Player-1-OTHER") == nil)
    T.check("no guid asked: nothing", Memory:OwnBank(nil) == nil)

    -- Only item ids that are numbers with counts that are positive whole numbers are kept.
    Memory:SaveBank(MAIN, { [1] = 0, [2] = -3, [3] = "x", [4] = 2, [5] = 1.5, [6] = math.huge, name = 3, [7] = true }, {}, NOW)
    got = Memory:OwnBank(MAIN.guid)
    T.check("only positive whole counts under numeric ids are kept", got[4] == 2 and count(got) == 1, count(got))
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

    -- The record seen last is the character of that name, whatever it is: when
    -- it cannot send, or has gone over to the other faction, the older record
    -- under its name does not count in its place.
    local function named(newer)
        fresh()
        Memory:SaveBags(MAIN, { [2589] = 9 }, {}, NOW)
        Memory:SaveBags(who("Player-1-GONE", "Bank Alt"), { [2589] = 30 }, {}, NOW - 20 * DAY)
        newer()
        return Memory:Alts(MAIN), Memory:Standing(MAIN)
    end
    local list, standing = named(function()
        Memory:SaveBags(who("Player-1-NEW", "Bank Alt"), { [2589] = 4 }, {}, NOW - DAY, false)
    end)
    T.eq("the newest record of a name cannot send: nobody of that name counts", #list, 0)
    T.check("the newest stands as unable to send, the older as an older record of the name",
        standing["Player-1-NEW"] == "nosend" and standing["Player-1-GONE"] == "name",
        tostring(standing["Player-1-NEW"]) .. "/" .. tostring(standing["Player-1-GONE"]))
    list, standing = named(function()
        Memory:SaveBags(who("Player-1-NEW", "Bank Alt", "eu-pvp", "Horde"), { [2589] = 4 }, {}, NOW - DAY)
    end)
    T.eq("the newest record of a name is of the other faction: nobody of that name counts", #list, 0)
    T.check("the newest stands as the other faction, the older as an older record of the name",
        standing["Player-1-NEW"] == "faction" and standing["Player-1-GONE"] == "name",
        tostring(standing["Player-1-NEW"]) .. "/" .. tostring(standing["Player-1-GONE"]))
    -- A record of the same name in another world is another character.
    list, standing = named(function()
        Memory:SaveBags(who("Player-1-NEW", "Bank Alt", "eu-normal"), { [2589] = 4 }, {}, NOW - DAY, false)
    end)
    T.check("a newer record of the name in another world leaves this world's one an alt",
        #list == 1 and list[1].guid == "Player-1-GONE" and standing["Player-1-NEW"] == "world", #list)
    -- Seen at the same moment: one of the two, and always the same one.
    list = named(function()
        Memory:SaveBags(who("Player-1-AAA", "Bank Alt"), { [2589] = 4 }, {}, NOW - 20 * DAY, false)
    end)
    T.eq("two records of a name seen at the same time: the first by id decides", #list, 0)
    fresh()
    Memory:SaveBags(MAIN, { [2589] = 9 }, {}, NOW)
    Memory:SaveBags(who("Player-1-GONE", "Bank Alt"), { [2589] = 30 }, {}, NOW - 20 * DAY)
    Memory:SaveBags(who("Player-1-NEW", "Bank Alt"), { [2589] = 4 }, {}, NOW - DAY)

    -- A record whose name could not be read cannot be shown, so it is not counted.
    Memory:SaveBags({ guid = "Player-1-NONAME", world = "eu-pvp", faction = "Alliance" }, { [2589] = 77 }, {}, NOW)
    T.eq("a record without a name is not an alt", #Memory:Alts(MAIN), 1)
    -- A later save that cannot read the name keeps the one it had.
    Memory:SaveBags({ guid = "Player-1-NEW", world = "eu-pvp", faction = "Alliance" }, { [2589] = 6 }, {}, NOW)
    alts = Memory:Alts(MAIN)
    T.check("a save without a name keeps the remembered name", #alts == 1 and alts[1].name == "Bank Alt"
        and alts[1].bags[2589] == 6)
end)

-- A character that cannot send anything (Self-Found) is no source of stock
-- for the others. Whether it can is stored with each of its saves; the store
-- is told, it does not read settings.
T.section("a character that cannot send", function()
    fresh()
    local solo = who("Player-1-SOLO", "Solo Alt")
    Memory:SaveBags(MAIN, { [2589] = 9 }, {}, NOW)
    Memory:SaveBags(solo, { [2589] = 80 }, {}, NOW, false)
    Memory:SaveBank(solo, { [2589] = 300 }, {}, NOW, false)
    T.eq("it is not an alt", #Memory:Alts(MAIN), 0)
    T.check("its own bank is still its own", (Memory:OwnBank(solo.guid))[2589] == 300)
    local s = Memory:Summary()
    T.check("the summary says it cannot send", s.characters[2].guid == solo.guid and s.characters[2].canSend == false
        and s.characters[1].canSend == true)

    -- The mode goes off: its next save says so, whichever part is saved.
    Memory:SaveBags(solo, { [2589] = 80 }, {}, NOW + 60, true)
    local alts = Memory:Alts(MAIN)
    T.check("a later save that can send makes it an alt again, bank included",
        #alts == 1 and alts[1].bags[2589] == 80 and alts[1].bank[2589] == 300)
    Memory:SaveBank(solo, { [2589] = 300 }, {}, NOW + 120, false)
    T.eq("and a bank save that cannot send takes it out again", #Memory:Alts(MAIN), 0)
    Memory:SaveBags(solo, { [2589] = 80 }, {}, NOW + 180)
    T.eq("a save that does not say counts as able to send", #Memory:Alts(MAIN), 1)

    -- The setting can change without a save: the record is told directly.
    T.check("told that it cannot send", Memory:SetCanSend(solo.guid, false) == true and #Memory:Alts(MAIN) == 0)
    T.check("told that it can again", Memory:SetCanSend(solo.guid, true) == true and #Memory:Alts(MAIN) == 1)
    T.check("a character that is not remembered: nothing to tell", Memory:SetCanSend("Player-1-NOBODY", false) == false
        and Memory:Summary().characters[3] == nil)
    T.check("no guid: nothing to tell", Memory:SetCanSend(nil, false) == false)

    -- A record from before this was stored counts as able to send.
    fresh()
    LazyProf.db.global.stock = { schema = 1, account = {}, characters = { [solo.guid] = {
        name = "Solo Alt", world = "eu-pvp", faction = "Alliance", seen = NOW,
        bags = { items = { [2589] = 80 }, at = NOW } } } }
    T.eq("a record without the field is an alt", #Memory:Alts(MAIN), 1)
    T.check("and the summary says it can send", Memory:Summary().characters[1].canSend == true)
    -- Seen from the character that cannot send itself: the others are still
    -- listed (whether it counts them is the scanner's decision).
    Memory:SaveBags(MAIN, { [2589] = 9 }, {}, NOW)
    T.eq("the store does not judge the asking character", #Memory:Alts(solo), 1)
end)

-- Why each remembered character is or is not an alt of the asking one (the
-- dump prints it; Alts is exactly the ones standing as "alt").
T.section("standing", function()
    fresh()
    local function save(guid, name, world, faction, at, canSend)
        Memory:SaveBags({ guid = guid, name = name, world = world, faction = faction }, { [2589] = 1 }, {}, at or NOW, canSend)
    end
    save(MAIN.guid, "Main Character", "eu-pvp", "Alliance")
    save("G-ALT", "Alt", "eu-pvp", "Alliance")
    save("G-WORLD", "Elsewhere", "eu-normal", "Alliance")
    save("G-FACTION", "Other Side", "eu-pvp", "Horde")
    save("G-SOLO", "Solo", "eu-pvp", "Alliance", NOW, false)
    save("G-OLDME", "Main Character", "eu-pvp", "Alliance", NOW - 9 * DAY)
    save("G-OLDALT", "Alt", "eu-pvp", "Alliance", NOW - 9 * DAY)
    save("G-NONAME", nil, "eu-pvp", "Alliance")
    LazyProf.db.global.stock.characters["G-JUNK"] = true
    local standing = Memory:Standing(MAIN)
    T.eq("the asking character", standing[MAIN.guid], "self")
    T.eq("an alt", standing["G-ALT"], "alt")
    T.eq("another world", standing["G-WORLD"], "world")
    T.eq("another faction", standing["G-FACTION"], "faction")
    T.eq("cannot send", standing["G-SOLO"], "nosend")
    T.eq("an older record under the asking character's name", standing["G-OLDME"], "name")
    T.eq("an older record under an alt's name", standing["G-OLDALT"], "name")
    T.eq("no name", standing["G-NONAME"], "noname")
    T.check("what is not a record has no standing", standing["G-JUNK"] == nil)
    local alts = Memory:Alts(MAIN)
    T.check("Alts is the ones standing as alt", #alts == 1 and alts[1].guid == "G-ALT")
    -- A world or faction that is not known: nobody can be told to be an alt.
    standing = Memory:Standing({ guid = MAIN.guid, name = "Main Character", faction = "Alliance" })
    T.check("asking without a world", standing[MAIN.guid] == "self" and standing["G-ALT"] == "unknown" and standing["G-WORLD"] == "unknown")
    standing = Memory:Standing({ guid = MAIN.guid, world = "eu-pvp" })
    T.eq("asking without a faction", standing["G-ALT"], "unknown")
    T.check("asking without anything", next(Memory:Standing(nil)) == nil)
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

-- The saved table can hold anything: a file edited by hand, cut off by a
-- crash, or written by a build with a defect. Whatever is not what this file
-- writes is skipped, never an error, and never a negative count.
T.section("saved data that is not what the addon wrote", function()
    local ALT = who("Player-1-ALT", "Alt Character")
    local function goodAlt()
        return { name = "Alt Character", world = "eu-pvp", faction = "Alliance", seen = NOW - 100,
                 bags = { items = { [2589] = 20 }, at = NOW - 100 } }
    end
    local function own(bankItems)
        return { name = "Main Character", world = "eu-pvp", faction = "Alliance", seen = NOW - 50,
                 bank = { items = bankItems, at = NOW - 50 } }
    end
    -- What every reader makes of a saved table: no error, nothing negative.
    local function read(stock)
        LazyProf.db.global = { characters = {}, stock = stock }
        local out = {}
        local ok, err = pcall(function()
            out.bank = Memory:OwnBank(MAIN.guid)
            out.account = Memory:AccountBank("eu-pvp")
            out.alts = Memory:Alts(MAIN)
            out.summary = Memory:Summary()
        end)
        out.ok, out.err = ok, err
        out.negative = false
        local function scan(items)
            for itemId, n in pairs(items or {}) do
                if type(itemId) ~= "number" or type(n) ~= "number" or n <= 0 or n ~= math.floor(n) then out.negative = true end
            end
        end
        scan(out.bank); scan(out.account)
        for _, alt in ipairs(out.alts or {}) do scan(alt.bags); scan(alt.bank) end
        return out
    end
    local function linen(out)
        local n = 0
        for _, alt in ipairs(out.alts or {}) do n = n + ((alt.bags or {})[2589] or 0) + ((alt.bank or {})[2589] or 0) end
        return n + ((out.bank or {})[2589] or 0) + ((out.account or {})[2589] or 0)
    end

    local cases = {
        -- label, the saved table, the linen that may be counted from it
        { "the store is a string", "broken", 0 },
        { "the store is an empty table", {}, 0 },
        { "characters is a string", { schema = 1, characters = "x", account = {} }, 0 },
        { "account is a number", { schema = 1, characters = { [ALT.guid] = goodAlt() }, account = 5 }, 20 },
        { "a record that is true", { schema = 1, characters = { X = true, [ALT.guid] = goodAlt() }, account = {} }, 20 },
        { "a record that is a string", { schema = 1, characters = { X = "gone" }, account = {} }, 0 },
        { "the character's own record is a number", { schema = 1, characters = { [MAIN.guid] = 7 }, account = {} }, 0 },
        { "a record without fields", { schema = 1, characters = { X = {} }, account = {} }, 0 },
        { "bags is a number", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags = 5; return r end)() }, account = {} }, 0 },
        { "bags without items", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags = { at = 1 }; return r end)() }, account = {} }, 0 },
        { "bags.items is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items = "x"; return r end)() }, account = {} }, 0 },
        { "bound is a number", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.bound = 3; return r end)() }, account = {} }, 20 },
        { "a count that is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = "abc"; return r end)() }, account = {} }, 0 },
        { "a count that is negative", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = -50; return r end)() }, account = {} }, 0 },
        { "a count that is true", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = true; return r end)() }, account = {} }, 0 },
        { "a count that is not whole", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = 2.5; return r end)() }, account = {} }, 0 },
        { "an item id that is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items = { ["2589"] = 20 }; return r end)() }, account = {} }, 0 },
        { "a bound count larger than the count", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.bound = { [2589] = 50 }; return r end)() }, account = {} }, 0 },
        { "a bound count that is negative", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.bound = { [2589] = -5 }; return r end)() }, account = {} }, 20 },
        { "own bank with a negative count", { schema = 1, characters = { [MAIN.guid] = own({ [2589] = -30 }) }, account = {} }, 0 },
        { "own bank with a string count", { schema = 1, characters = { [MAIN.guid] = own({ [2589] = "x", [4306] = 2 }) }, account = {} }, 0 },
        { "own bank is true", { schema = 1, characters = { [MAIN.guid] = { seen = 1, bank = true } }, account = {} }, 0 },
        { "an account bank that is true", { schema = 1, characters = {}, account = { ["eu-pvp"] = true } }, 0 },
        { "an account bank without items", { schema = 1, characters = {}, account = { ["eu-pvp"] = { at = 5 } } }, 0 },
        { "an account bank with a negative count", { schema = 1, characters = {}, account = { ["eu-pvp"] = { items = { [2589] = -4, [4306] = 1 }, at = 5 } } }, 0 },
        { "a name that is a number", { schema = 1, characters = { X = (function() local r = goodAlt(); r.name = 12; return r end)(), [ALT.guid] = goodAlt() }, account = {} }, 20 },
        { "a world that is a table", { schema = 1, characters = { X = (function() local r = goodAlt(); r.world = {}; return r end)() }, account = {} }, 0 },
        { "seen is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.seen = "yesterday"; return r end)() }, account = {} }, 20 },
        { "two records of one name, one with seen as a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.seen = "x"; r.bags.items[2589] = 99; return r end)(), [ALT.guid] = goodAlt() }, account = {} }, 20 },
        { "a part without a time", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.at = nil; return r end)() }, account = {} }, 20 },
        { "a part whose time is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.at = "noon"; return r end)() }, account = {} }, 20 },
        { "a key that is a number", { schema = 1, characters = { [7] = goodAlt(), [8] = goodAlt() }, account = {} }, 20 },
    }
    for _, case in ipairs(cases) do
        local label, stock, want = case[1], case[2], case[3]
        local out = read(stock)
        T.check(label .. ": no error", out.ok, out.err)
        T.check(label .. ": nothing but positive whole counts", out.negative == false)
        T.eq(label .. ": linen counted", linen(out), want)
    end

    -- A part without a usable time is counted but has no age.
    local out = read({ schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.at = "noon"; return r end)() }, account = {} })
    T.check("a part without a usable time has no time", out.alts[1] ~= nil and out.alts[1].bagsAt == nil)
    -- The summary says how many records it could not read.
    out = read({ schema = 1, characters = { X = true, Y = "gone", [ALT.guid] = goodAlt() }, account = { ["eu-pvp"] = true } })
    T.check("the summary lists what it can read and counts the rest",
        #out.summary.characters == 1 and out.summary.unreadable == 3, out.summary.unreadable)

    -- Reading repairs nothing by itself ...
    local broken = { schema = 1, characters = "x", account = 5 }
    read(broken)
    T.check("reading leaves the saved table as it was", broken.characters == "x" and broken.account == 5)
    -- ... a save does.
    LazyProf.db.global = { stock = broken }
    T.check("a save into it works", Memory:SaveBags(MAIN, { [2589] = 3 }, {}, NOW) == true
        and Memory:SaveAccountBank("eu-pvp", { [2589] = 4 }, NOW) == true)
    T.check("and replaces what was not a table", type(broken.characters) == "table" and type(broken.account) == "table"
        and broken.characters[MAIN.guid].bags.items[2589] == 3)
    LazyProf.db.global = { stock = "broken" }
    T.check("a store that was a string is replaced by the first save", Memory:SaveBank(MAIN, { [2589] = 3 }, {}, NOW) == true
        and type(LazyProf.db.global.stock) == "table" and LazyProf.db.global.stock.schema == 1)
    -- The character's own record that is not a table is replaced by its next save.
    LazyProf.db.global = { stock = { schema = 1, characters = { [MAIN.guid] = 7, [ALT.guid] = "gone" }, account = {} } }
    T.check("a save over a record that is not a table", Memory:SaveBank(MAIN, { [2589] = 8 }, {}, NOW) == true
        and (Memory:OwnBank(MAIN.guid))[2589] == 8)
    -- A name, world or faction that is not text is dropped by the next save.
    LazyProf.db.global = { stock = { schema = 1, characters = { [MAIN.guid] = { name = 12, world = {}, faction = true } }, account = {} } }
    Memory:SaveBags({ guid = MAIN.guid }, { [1] = 1 }, {}, NOW)
    local record = LazyProf.db.global.stock.characters[MAIN.guid]
    T.check("who a record is holds text or nothing", record.name == nil and record.world == nil and record.faction == nil)

    -- Prune and Forget cope, and Forget repairs.
    LazyProf.db.global = { stock = { schema = 1, characters = { X = true, Y = "gone", Z = { seen = "x" }, [MAIN.guid] = 7,
        [ALT.guid] = goodAlt() }, account = { ["eu-pvp"] = true, ["us-pvp"] = { items = {}, at = 1 } } } }
    local ok, dropped = pcall(Memory.Prune, Memory, NOW, MAIN.guid)
    T.check("prune does not fail on them", ok, dropped)
    local characters = LazyProf.db.global.stock.characters
    T.check("prune drops what is not a record, keeps the good one and the played character's entry",
        characters.X == nil and characters.Y == nil and characters.Z == nil and characters[ALT.guid] ~= nil
        and characters[MAIN.guid] ~= nil)
    for _, stock in ipairs({ "broken", { schema = 1, characters = "x", account = 5 },
            { schema = 1, characters = { X = true }, account = { ["eu-pvp"] = true } } }) do
        LazyProf.db.global = { stock = stock }
        T.check("forget does not fail", pcall(Memory.Forget, Memory))
        local after = LazyProf.db.global.stock
        T.check("forget leaves a clean store", type(after) == "table" and type(after.characters) == "table"
            and next(after.characters) == nil and type(after.account) == "table" and next(after.account) == nil)
        T.check("that saves again", Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW) == true)
    end
    -- A format number that is not this version's (even the text "1") is another format.
    out = read({ schema = "1", characters = { [ALT.guid] = goodAlt() } })
    T.check("a format number that is text is not this format", out.ok and linen(out) == 0 and out.summary.usable == false)
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
