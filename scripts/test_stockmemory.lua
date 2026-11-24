-- scripts/test_stockmemory.lua
--
-- The stock memory: what each character had in its bags and bank when LazyProf
-- last saw them, and the account-wide bank per region. It is what lets bank and
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

local function who(guid, name, world, faction, region)
    return { guid = guid, name = name, world = world or "eu-pvp", faction = faction or "Alliance", region = region or "eu" }
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

    -- Reading changes nothing. A saved table without a format number yet is
    -- read as this format, and no reader writes the number into it: that is
    -- for the first save.
    local bare = { account = { eu = { items = { [2770] = 5 }, at = NOW, world = "eu-pvp", faction = "Alliance" } }, characters = {
        [MAIN.guid] = { name = "Main Character", world = "eu-pvp", faction = "Alliance", seen = NOW,
            bank = { items = { [2589] = 40 }, at = NOW }, bagsAtBank = { items = {}, banks = { character = true }, at = NOW } },
        ["Player-1-ALT"] = { name = "Alt", world = "eu-pvp", faction = "Alliance", seen = NOW,
            bags = { items = { [2589] = 20 }, at = NOW } } } }
    LazyProf.db.global = { stock = bare }
    T.check("a table without a format number is read", (Memory:OwnBank(MAIN.guid))[2589] == 40
        and (Memory:AccountBank("eu"))[2770] == 5 and #Memory:Alts(MAIN) == 1 and Memory:Standing(MAIN)[MAIN.guid] == "self"
        and #Memory:Summary().characters == 2 and Memory:BagsAtBank(MAIN.guid) ~= nil and Memory:Token() == bare.characters)
    T.check("and no reader writes the format number", bare.schema == nil, bare.schema)
    Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW)
    T.eq("the first save does", bare.schema, 1)
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
    T.check("account bank without a character", Memory:SaveAccountBank(nil, { [1] = 1 }, NOW) == false)
    T.check("account bank without a region", Memory:SaveAccountBank({ guid = "P-1", world = "eu-pvp", faction = "Alliance" }, { [1] = 1 }, NOW) == false)
    T.check("account bank without a world", Memory:SaveAccountBank({ guid = "P-1", region = "eu", faction = "Alliance" }, { [1] = 1 }, NOW) == false)
    T.check("account bank without a faction", Memory:SaveAccountBank({ guid = "P-1", region = "eu", world = "eu-pvp" }, { [1] = 1 }, NOW) == false)
    T.check("account bank without items", Memory:SaveAccountBank(MAIN, nil, NOW) == false)
    T.check("account bank without a time", Memory:SaveAccountBank(MAIN, { [1] = 1 }, nil) == false)
    T.eq("no record was made", count(LazyProf.db.global.stock and LazyProf.db.global.stock.characters), 0)

    local saved = LazyProf.db
    LazyProf.db = nil
    T.check("no database: a save does nothing", Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW) == false)
    T.check("no database: nothing to read", Memory:OwnBank(MAIN.guid) == nil and #Memory:Alts(MAIN) == 0
        and Memory:AccountBank("eu") == nil)
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
    -- A save brings the name up to date: a character can be renamed.
    Memory:SaveBags(who("Player-1-NEW", "Renamed Alt"), { [2589] = 5 }, {}, NOW - DAY + 60)
    alts = Memory:Alts(MAIN)
    T.check("a save under a new name renames the record", #alts == 2 and alts[2].guid == "Player-1-NEW"
        and alts[2].name == "Renamed Alt" and alts[2].bags[2589] == 5, alts[1] and alts[1].name)
    T.check("the older record of the old name is the character of that name again",
        alts[1].guid == "Player-1-GONE" and alts[1].name == "Bank Alt")
    Memory:SaveBags(who("Player-1-NEW", "Bank Alt"), { [2589] = 4 }, {}, NOW - DAY + 120)
    -- The same for the world and the faction it is filed under.
    Memory:SaveBags(who("Player-1-MOVED", "Moved Alt", "eu-normal", "Horde"), { [2589] = 2 }, {}, NOW)
    T.eq("fixture: another world and faction is no alt", #Memory:Alts(MAIN), 1)
    Memory:SaveBags(who("Player-1-MOVED", "Moved Alt"), { [2589] = 2 }, {}, NOW)
    T.eq("a save under another world and faction refiles the record", #Memory:Alts(MAIN), 2)
    LazyProf.db.global.stock.characters["Player-1-MOVED"] = nil
    -- A later save that cannot read the name keeps the one it had.
    Memory:SaveBags({ guid = "Player-1-NEW", world = "eu-pvp", faction = "Alliance" }, { [2589] = 6 }, {}, NOW)
    alts = Memory:Alts(MAIN)
    T.check("a save without a name keeps the remembered name", #alts == 1 and alts[1].name == "Bank Alt"
        and alts[1].bags[2589] == 6)
    -- The same for the world and the faction: a save that could not read one
    -- of them keeps what was remembered, and the character stays filed where
    -- it was.
    local record = LazyProf.db.global.stock.characters["Player-1-NEW"]
    Memory:SaveBags({ guid = "Player-1-NEW", name = "Bank Alt", faction = "Alliance" }, { [2589] = 7 }, {}, NOW)
    T.eq("a save without a world keeps the remembered world", record.world, "eu-pvp")
    Memory:SaveBank({ guid = "Player-1-NEW", name = "Bank Alt", world = "eu-pvp" }, { [2589] = 50 }, {}, NOW)
    T.eq("a save without a faction keeps the remembered faction", record.faction, "Alliance")
    Memory:NoteBagsAtBank({ guid = "Player-1-NEW" }, { [2589] = 7 }, { character = true }, NOW)
    T.check("a note without any of them keeps all three", record.name == "Bank Alt" and record.world == "eu-pvp"
        and record.faction == "Alliance")
    alts = Memory:Alts(MAIN)
    T.check("so it is still the alt of that name, with what the saves held", #alts == 1 and alts[1].guid == "Player-1-NEW"
        and alts[1].bags[2589] == 7 and alts[1].bank[2589] == 50, alts[1] and alts[1].guid)
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
    T.check("none at first", Memory:AccountBank("eu") == nil)
    T.check("a save reports success", Memory:SaveAccountBank(MAIN, { [2589] = 60 }, NOW) == true)
    local items, at, doubt, world, faction = Memory:AccountBank("eu")
    T.check("read back per region", items ~= nil and items[2589] == 60 and at == NOW and doubt == false, at)
    T.check("with the world and faction of the character whose read it is", world == "eu-pvp" and faction == "Alliance",
        tostring(world) .. "," .. tostring(faction))
    T.check("another region has its own", Memory:AccountBank("us") == nil)
    T.check("a world is no region", Memory:AccountBank("eu-pvp") == nil)
    Memory:SaveAccountBank(MAIN, { [4306] = 2 }, NOW + 5)
    items, at = Memory:AccountBank("eu")
    T.check("a second save replaces", items[4306] == 2 and items[2589] == nil and at == NOW + 5)
    T.check("no region asked: nothing", Memory:AccountBank(nil) == nil)
    -- One copy per region: a character of another world or of the other
    -- faction that reads it makes the copy its own.
    Memory:SaveAccountBank(who("Player-1-HORDE", "Other Side", "eu-pvp", "Horde"), { [774] = 3 }, NOW + 6)
    items, at, doubt, world, faction = Memory:AccountBank("eu")
    T.check("a read by the other faction replaces the copy and makes it that faction's",
        items[774] == 3 and items[4306] == nil and world == "eu-pvp" and faction == "Horde")
    Memory:SaveAccountBank(who("Player-1-NORMAL", "Elsewhere", "eu-normal", "Alliance"), { [765] = 1 }, NOW + 7)
    items, at, doubt, world, faction = Memory:AccountBank("eu")
    T.check("so does a read in another world of the region", items[765] == 1 and world == "eu-normal" and faction == "Alliance")
    Memory:SaveAccountBank(who("Player-1-US", "Far Away", "us-pvp", "Alliance", "us"), { [1] = 1 }, NOW + 8)
    T.check("a read in another region is that region's", (Memory:AccountBank("us"))[1] == 1 and (Memory:AccountBank("eu"))[765] == 1)
    T.check("the summary lists one per region, with whose read it is", (function()
        local list = Memory:Summary().account
        return #list == 2 and list[1].region == "eu" and list[1].world == "eu-normal" and list[1].faction == "Alliance"
            and list[1].items == 1 and list[2].region == "us" and list[2].world == "us-pvp"
    end)())

    -- An entry without the world and faction of its read (the older shape,
    -- one per world) is not read, and the next save removes it.
    fresh()
    LazyProf.db.global.stock = { schema = 1, characters = {}, account = {
        ["eu-pvp"] = { items = { [2589] = 50 }, at = NOW }, eu = { items = { [2589] = 40 }, at = NOW } } }
    T.check("an entry of the older shape is not read", Memory:AccountBank("eu-pvp") == nil and Memory:AccountBank("eu") == nil)
    T.check("nor can it be marked", Memory:MarkAccountBankDoubt("eu") == false and Memory:MarkAccountBankDoubt("eu-pvp") == false)
    T.check("the summary counts it as unreadable", #Memory:Summary().account == 0 and Memory:Summary().unreadable == 2)
    for label, entry in pairs({ ["a world that is a number"] = { items = {}, at = NOW, world = 5, faction = "Horde" },
                                ["a faction that is a table"] = { items = {}, at = NOW, world = "eu-pvp", faction = {} } }) do
        LazyProf.db.global.stock.account.eu = entry
        T.check(label .. ": not read", Memory:AccountBank("eu") == nil)
    end
    Memory:SaveAccountBank(who("Player-1-US", "Far Away", "us-pvp", "Alliance", "us"), { [1] = 1 }, NOW)
    T.check("the next save of an account bank removes what could not be read",
        LazyProf.db.global.stock.account["eu-pvp"] == nil and LazyProf.db.global.stock.account.eu == nil
        and (Memory:AccountBank("us"))[1] == 1)

    -- The memory keeps a copy of its own, holding only what can be counted.
    fresh()
    local mine = { [2589] = 60, [4306] = -3, [774] = 2.5, [765] = "x", name = 7 }
    Memory:SaveAccountBank(MAIN, mine, NOW + 10)
    local kept = LazyProf.db.global.stock.account.eu.items
    T.check("what is saved is not the caller's table", kept ~= mine)
    T.check("and holds only positive whole counts under numeric ids", kept[2589] == 60 and count(kept) == 1, count(kept))
    mine[2589] = 1
    T.eq("changing the caller's table afterwards changes nothing", (Memory:AccountBank("eu"))[2589], 60)
    items = Memory:AccountBank("eu")
    items[2589] = 9999
    T.eq("and what is handed out is a copy too", (Memory:AccountBank("eu"))[2589], 60)
end)

-- A remembered bank can be marked "in doubt": the addon has reason to think
-- it is behind. It stays remembered - the mark only says that it must not be
-- counted - and the next save of that bank takes the mark away.
T.section("a bank in doubt", function()
    fresh()
    local zed = who("Player-1-ZED", "Zed Alt")
    T.check("nothing remembered: nothing to mark", Memory:MarkBankDoubt(MAIN.guid) == false
        and Memory:MarkAccountBankDoubt("eu") == false)
    T.check("marking makes nothing", LazyProf.db.global.stock == nil)
    Memory:SaveBags(MAIN, { [2589] = 9 }, {}, NOW)
    T.check("bags only: no bank to mark", Memory:MarkBankDoubt(MAIN.guid) == false
        and LazyProf.db.global.stock.characters[MAIN.guid].bank == nil)

    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - DAY)
    local items, at, doubt = Memory:OwnBank(MAIN.guid)
    T.check("a saved bank is not in doubt", items[2589] == 40 and doubt == false, doubt)
    T.check("marking says that the mark is new", Memory:MarkBankDoubt(MAIN.guid) == true)
    items, at, doubt = Memory:OwnBank(MAIN.guid)
    T.check("the bank stays remembered, with its time, and says it is in doubt",
        items ~= nil and items[2589] == 40 and at == NOW - DAY and doubt == true, doubt)
    T.check("marking it again changes nothing", Memory:MarkBankDoubt(MAIN.guid) == false)
    local summary = Memory:Summary()
    T.check("the summary names the mark", summary.characters[1].bankDoubt == true and summary.characters[1].bankItems == 1)
    Memory:SaveBags(MAIN, { [2589] = 10 }, {}, NOW)
    T.check("a save of the bags leaves the mark", select(3, Memory:OwnBank(MAIN.guid)) == true)
    Memory:SaveBank(MAIN, { [2589] = 41 }, {}, NOW)
    items, at, doubt = Memory:OwnBank(MAIN.guid)
    T.check("the next save of the bank takes it away", items[2589] == 41 and doubt == false, doubt)
    T.check("and the summary follows", Memory:Summary().characters[1].bankDoubt == false)

    -- An alt whose bank is in doubt: its bags still count, its bank does not.
    Memory:SaveBags(zed, { [2589] = 20 }, {}, NOW - DAY)
    Memory:SaveBank(zed, { [2589] = 100 }, {}, NOW - 2 * DAY)
    T.check("an alt's bank can be marked", Memory:MarkBankDoubt(zed.guid) == true)
    local alts = Memory:Alts(MAIN)
    T.check("the alt is still an alt, with its bags", #alts == 1 and alts[1].bags[2589] == 20 and alts[1].bagsAt == NOW - DAY)
    T.check("its bank is not handed out, and the list says why", alts[1].bank == nil and alts[1].bankAt == nil
        and alts[1].bankDoubt == true)
    Memory:SaveBank(zed, { [2589] = 100 }, {}, NOW)
    alts = Memory:Alts(MAIN)
    T.check("after its next bank save it is handed out again", alts[1].bank ~= nil and alts[1].bank[2589] == 100
        and alts[1].bankDoubt == nil)

    -- The account bank of a region.
    Memory:SaveAccountBank(MAIN, { [2770] = 50 }, NOW - DAY)
    items, at, doubt = Memory:AccountBank("eu")
    T.check("a saved account bank is not in doubt", items[2770] == 50 and doubt == false, doubt)
    T.check("another region's cannot be marked", Memory:MarkAccountBankDoubt("us") == false)
    T.check("marking says that the mark is new", Memory:MarkAccountBankDoubt("eu") == true)
    T.check("marking it again changes nothing", Memory:MarkAccountBankDoubt("eu") == false)
    items, at, doubt = Memory:AccountBank("eu")
    T.check("the account bank stays remembered and says it is in doubt", items[2770] == 50 and at == NOW - DAY and doubt == true)
    T.check("the summary names it", Memory:Summary().account[1].doubt == true)
    Memory:SaveAccountBank(MAIN, { [2770] = 51 }, NOW)
    items, at, doubt = Memory:AccountBank("eu")
    T.check("its next save takes the mark away", items[2770] == 51 and doubt == false and Memory:Summary().account[1].doubt == false)

    -- A mark that is not what this file writes (a saved table that was
    -- damaged) is a mark all the same: any value but nothing and false. In
    -- doubt about the doubt, the bank is not counted.
    local records = LazyProf.db.global.stock
    for _, value in ipairs({ "yes", 1, 0, {} }) do
        local what = "a mark that is " .. (type(value) == "table" and "a table" or tostring(value))
        records.characters[MAIN.guid].bank.doubt = value
        records.characters[zed.guid].bank.doubt = value
        records.account.eu.doubt = value
        T.check(what .. ": the own bank and the account bank are in doubt", select(3, Memory:OwnBank(MAIN.guid)) == true
            and select(3, Memory:AccountBank("eu")) == true)
        local list = Memory:Alts(MAIN)
        T.check(what .. ": an alt's bank is not handed out", #list == 1 and list[1].bank == nil and list[1].bankDoubt == true
            and list[1].bags[2589] == 20)
        local sum = Memory:Summary()
        T.check(what .. ": the summary names all three", sum.characters[1].bankDoubt == true and sum.characters[2].bankDoubt == true
            and sum.account[1].doubt == true)
        T.check(what .. ": marking again is not new", Memory:MarkBankDoubt(MAIN.guid) == false
            and Memory:MarkAccountBankDoubt("eu") == false)
    end
    records.characters[MAIN.guid].bank.doubt = false
    records.characters[zed.guid].bank.doubt = false
    records.account.eu.doubt = false
    T.check("false is no mark", select(3, Memory:OwnBank(MAIN.guid)) == false and select(3, Memory:AccountBank("eu")) == false
        and Memory:Alts(MAIN)[1].bank ~= nil and Memory:Summary().characters[1].bankDoubt == false)
    records.characters[MAIN.guid].bank.doubt = "yes"
    Memory:SaveBank(MAIN, { [2589] = 41 }, {}, NOW)
    T.check("the next save takes a damaged mark away too", select(3, Memory:OwnBank(MAIN.guid)) == false)
    T.check("nothing to mark without a character or a region", Memory:MarkBankDoubt(nil) == false
        and Memory:MarkAccountBankDoubt(nil) == false)
    LazyProf.db.global.stock.characters["Player-1-JUNK"] = true
    LazyProf.db.global.stock.account["eu-rp"] = "x"
    T.check("what is not a record cannot be marked", Memory:MarkBankDoubt("Player-1-JUNK") == false
        and Memory:MarkAccountBankDoubt("eu-rp") == false and LazyProf.db.global.stock.characters["Player-1-JUNK"] == true)

    -- Another format is not marked either.
    fresh()
    local theirs = { schema = 2, characters = { [MAIN.guid] = { bank = { items = { [1] = 1 } } } },
                     account = { eu = { items = {}, world = "eu-pvp", faction = "Alliance" } } }
    LazyProf.db.global.stock = theirs
    T.check("another format: nothing is marked", Memory:MarkBankDoubt(MAIN.guid) == false
        and Memory:MarkAccountBankDoubt("eu") == false and theirs.characters[MAIN.guid].bank.doubt == nil
        and theirs.account.eu.doubt == nil)
end)

-- A session that ends at the bank leaves a note with the character's record:
-- what its carried bags held then and which banks its last visit could use.
-- The character's next session compares its bags with it (Scanner.lua).
T.section("the bags at the bank", function()
    fresh()
    T.check("nothing remembered: no note", Memory:BagsAtBank(MAIN.guid) == nil)
    Memory:SaveBags(MAIN, { [2589] = 5 }, {}, NOW - DAY)
    Memory:SaveBank(MAIN, { [2589] = 40 }, {}, NOW - DAY)
    T.check("a character without a note has none", Memory:BagsAtBank(MAIN.guid) == nil)

    local held = { [2589] = 5, [6948] = 1 }
    T.check("noting reports success", Memory:NoteBagsAtBank(MAIN, held, { character = true, account = false }, NOW) == true)
    local note = Memory:BagsAtBank(MAIN.guid)
    T.check("the note holds the counts", note ~= nil and note.known == true and note.items[2589] == 5 and note.items[6948] == 1
        and count(note.items) == 2)
    T.check("and which banks it is about", note.character == true and note.account == false)
    T.eq("and when it was written", note.at, NOW)
    held[2589] = 99
    T.eq("it is a copy of what was passed", Memory:BagsAtBank(MAIN.guid).items[2589], 5)
    note.items[2589] = 77
    T.eq("and hands out a copy", Memory:BagsAtBank(MAIN.guid).items[2589], 5)
    T.check("the bags and the bank of the record are untouched", (Memory:OwnBank(MAIN.guid))[2589] == 40
        and Memory:Summary().characters[1].bagItems == 1)
    -- A later save of the bags or the bank keeps the note.
    Memory:SaveBags(MAIN, { [2589] = 6 }, {}, NOW + 1)
    Memory:SaveBank(MAIN, { [2589] = 41 }, {}, NOW + 1)
    T.check("saving bags or bank keeps the note", Memory:BagsAtBank(MAIN.guid) ~= nil)
    -- A new note replaces the old one.
    Memory:NoteBagsAtBank(MAIN, {}, { account = true }, NOW + 2)
    note = Memory:BagsAtBank(MAIN.guid)
    T.check("a new note replaces the old one: empty bags, the account bank alone", note.known == true and next(note.items) == nil
        and note.character == false and note.account == true)
    -- Bags that could not be read: the note says that it is not known.
    Memory:NoteBagsAtBank(MAIN, nil, { character = true, account = true }, NOW + 3)
    note = Memory:BagsAtBank(MAIN.guid)
    T.check("without items the note says the bags are not known", note.known == false and note.items == nil
        and note.character == true and note.account == true)

    T.check("clearing says there was one", Memory:ClearBagsAtBank(MAIN.guid) == true)
    T.check("and it is gone", Memory:BagsAtBank(MAIN.guid) == nil and LazyProf.db.global.stock.characters[MAIN.guid].bagsAtBank == nil)
    T.check("clearing again says there was none", Memory:ClearBagsAtBank(MAIN.guid) == false)
    T.check("the record itself stays", (Memory:OwnBank(MAIN.guid))[2589] == 41)

    -- A character never seen before gets a record with the note.
    local NEW = who("Player-1-NEW", "New Character")
    T.check("a note for a character without a record makes the record", Memory:NoteBagsAtBank(NEW, { [1] = 1 }, { character = true }, NOW)
        and Memory:BagsAtBank(NEW.guid).items[1] == 1 and Memory:Summary().characters[2].name == "New Character")

    -- Nothing is noted without a character, a time or the banks.
    T.check("no guid: nothing noted", Memory:NoteBagsAtBank({ name = "Nobody" }, {}, { character = true }, NOW) == false)
    T.check("no time: nothing noted", Memory:NoteBagsAtBank(MAIN, {}, { character = true }, nil) == false)
    T.check("no banks: nothing noted", Memory:NoteBagsAtBank(MAIN, {}, nil, NOW) == false and Memory:BagsAtBank(MAIN.guid) == nil)
    T.check("nothing to read or clear without a character", Memory:BagsAtBank(nil) == nil and Memory:ClearBagsAtBank(nil) == false)

    -- A note that is not what this file writes counts as unknown, for both
    -- banks: nothing in it can be relied on.
    local record = LazyProf.db.global.stock.characters[MAIN.guid]
    for label, damaged in pairs({
        ["a note that is text"] = "yesterday",
        ["a note that is true"] = true,
        ["a note whose items are a number"] = { items = 7, banks = { character = true }, at = NOW },
        ["a note without banks"] = { items = { [2589] = 5 }, at = NOW },
        ["a note whose banks are text"] = { items = { [2589] = 5 }, banks = "both", at = NOW },
    }) do
        record.bagsAtBank = damaged
        note = Memory:BagsAtBank(MAIN.guid)
        T.check(label .. ": unknown, both banks", note ~= nil and note.known == false and note.items == nil
            and note.character == true and note.account == true)
    end
    -- Counts that cannot be counts are left out: the note then differs from
    -- any bags, which is the safe side.
    record.bagsAtBank = { items = { [2589] = 5, [4306] = -3, bad = 2, [765] = "x" }, banks = { character = true }, at = NOW }
    note = Memory:BagsAtBank(MAIN.guid)
    T.check("counts that are no counts are left out", note.known == true and note.items[2589] == 5 and count(note.items) == 1)
    for _, at in ipairs({ "noon", 0 / 0, math.huge }) do
        record.bagsAtBank = { items = {}, banks = { character = true }, at = at }
        T.check("a time that is no time (" .. tostring(at) .. ") is none", Memory:BagsAtBank(MAIN.guid).at == nil)
    end
    record.bagsAtBank = { items = { [2589] = 5, [4306] = -3, bad = 2, [765] = "x" }, banks = { character = true }, at = NOW }
    T.check("reading changed nothing", record.bagsAtBank.items[4306] == -3)
    T.check("a damaged note can be cleared", Memory:ClearBagsAtBank(MAIN.guid) == true and record.bagsAtBank == nil)
    LazyProf.db.global.stock.characters["Player-1-JUNK"] = "gone"
    T.check("what is not a record has no note", Memory:BagsAtBank("Player-1-JUNK") == nil and Memory:ClearBagsAtBank("Player-1-JUNK") == false)

    -- Another format: neither read nor written.
    local theirs = { schema = 9, characters = { [MAIN.guid] = { bagsAtBank = { items = {}, banks = { character = true } } } } }
    LazyProf.db.global.stock = theirs
    T.check("another format: no note is read, written or cleared", Memory:BagsAtBank(MAIN.guid) == nil
        and Memory:NoteBagsAtBank(MAIN, {}, { character = true }, NOW) == false and Memory:ClearBagsAtBank(MAIN.guid) == false
        and theirs.characters[MAIN.guid].bagsAtBank ~= nil)

    -- Forget removes it with the record.
    fresh()
    Memory:NoteBagsAtBank(MAIN, { [1] = 1 }, { character = true }, NOW)
    Memory:Forget()
    T.check("forgetting everything forgets the note", Memory:BagsAtBank(MAIN.guid) == nil)
end)

T.section("prune", function()
    fresh()
    local old = who("Player-1-OLD", "Old Alt")
    local kept = who("Player-1-KEPT", "Kept Alt")
    local edge = who("Player-1-EDGE", "Edge Alt")
    local away = who("Player-1-AWAY", "Away Alt", "us-normal", "Alliance", "us")
    Memory:SaveBags(old, { [1] = 1 }, {}, NOW - 181 * DAY)
    Memory:SaveBags(kept, { [1] = 1 }, {}, NOW - 179 * DAY)
    Memory:SaveBags(edge, { [1] = 1 }, {}, NOW - 180 * DAY)
    Memory:SaveBags(away, { [1] = 1 }, {}, NOW - 200 * DAY)
    Memory:SaveAccountBank(MAIN, { [1] = 1 }, NOW - 300 * DAY)
    Memory:SaveAccountBank(away, { [1] = 1 }, NOW - 200 * DAY)
    T.eq("two characters are dropped", Memory:Prune(NOW), 2)
    local chars = LazyProf.db.global.stock.characters
    T.check("not seen for 181 days: dropped", chars[old.guid] == nil)
    T.check("seen 179 days ago: kept", chars[kept.guid] ~= nil)
    T.check("seen exactly 180 days ago: kept", chars[edge.guid] ~= nil)
    T.check("the account bank stays while a character of its region is remembered", Memory:AccountBank("eu") ~= nil)
    T.check("and goes with the last character of its region", Memory:AccountBank("us") == nil)

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
    Memory:SaveAccountBank(MAIN, { [1] = 1 }, NOW - 500 * DAY)
    T.eq("the character being played is never dropped", Memory:Prune(NOW, MAIN.guid), 0)
    T.check("its bank is still remembered", (Memory:OwnBank(MAIN.guid))[2589] == 8)
    T.check("and its region's account bank", Memory:AccountBank("eu") ~= nil)
    T.check("prune without a time does nothing", Memory:Prune(nil) == 0 and Memory:OwnBank(MAIN.guid) ~= nil)

    -- An account bank is dropped only when it is known that no character is
    -- of its region. Characters that cannot be read prove nothing.
    local function accountAfter(characters)
        fresh()
        LazyProf.db.global.stock = { schema = 1, characters = characters,
            account = { eu = { items = { [2770] = 50 }, at = NOW - DAY, world = "eu-pvp", faction = "Alliance" } } }
        Memory:Prune(NOW, MAIN.guid)
        return Memory:AccountBank("eu")
    end
    T.check("the characters are not a table: the account bank stays", accountAfter("cut off") ~= nil)
    T.check("the characters are missing: the account bank stays", accountAfter(nil) ~= nil)
    T.check("the played character's record has no region: the account bank stays",
        accountAfter({ [MAIN.guid] = { name = "Main Character", world = "us-pvp", faction = "Alliance", seen = NOW - DAY } }) ~= nil)
    T.check("the played character's record is not a record: the account bank stays", accountAfter({ [MAIN.guid] = 7 }) ~= nil)
    T.check("a record with a region that is not text: the account bank stays",
        accountAfter({ ["Player-1-ODD"] = { name = "Odd", world = "us-pvp", region = 12, faction = "Alliance", seen = NOW - DAY } }) ~= nil)
    T.check("(every character read, none of them of that region: it goes)",
        accountAfter({ [MAIN.guid] = { name = "Main Character", world = "us-normal", region = "us", faction = "Alliance", seen = NOW - DAY } }) == nil)
    T.check("(a character of the region in another world keeps it)",
        accountAfter({ [MAIN.guid] = { name = "Main Character", world = "eu-normal", region = "eu", faction = "Horde", seen = NOW - DAY } }) ~= nil)
    T.check("(no character at all, and the table is one: it goes)", accountAfter({}) == nil)
    T.check("a save notes the region on the character's record", (function()
        fresh()
        Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW)
        local record = LazyProf.db.global.stock.characters[MAIN.guid]
        Memory:SaveBags({ guid = MAIN.guid }, { [1] = 1 }, {}, NOW)
        return record.region == "eu"
    end)())
end)

T.section("forget", function()
    fresh()
    Memory:SaveBags(MAIN, { [1] = 1 }, {}, NOW)
    Memory:SaveBank(MAIN, { [1] = 1 }, {}, NOW)
    Memory:SaveBags(who("Player-1-ALT", "Alt"), { [1] = 1 }, {}, NOW)
    Memory:SaveAccountBank(MAIN, { [1] = 1 }, NOW)
    Memory:Forget()
    T.check("no bank", Memory:OwnBank(MAIN.guid) == nil)
    T.eq("no alts", #Memory:Alts(MAIN), 0)
    T.check("no account bank", Memory:AccountBank("eu") == nil)
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
        and Memory:SaveAccountBank(MAIN, { [1] = 1 }, NOW) == false)
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
            out.account = Memory:AccountBank("eu")
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
        { "bound is a number", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.bound = 3; return r end)() }, account = {} }, 0 },
        { "a count that is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = "abc"; return r end)() }, account = {} }, 0 },
        { "a count that is negative", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = -50; return r end)() }, account = {} }, 0 },
        { "a count that is true", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = true; return r end)() }, account = {} }, 0 },
        { "a count that is not whole", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items[2589] = 2.5; return r end)() }, account = {} }, 0 },
        { "an item id that is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.items = { ["2589"] = 20 }; return r end)() }, account = {} }, 0 },
        { "a bound count larger than the count", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.bound = { [2589] = 50 }; return r end)() }, account = {} }, 0 },
        { "a bound count that is negative", { schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.bound = { [2589] = -5 }; return r end)() }, account = {} }, 0 },
        { "own bank with a negative count", { schema = 1, characters = { [MAIN.guid] = own({ [2589] = -30 }) }, account = {} }, 0 },
        { "own bank with a string count", { schema = 1, characters = { [MAIN.guid] = own({ [2589] = "x", [4306] = 2 }) }, account = {} }, 0 },
        { "own bank is true", { schema = 1, characters = { [MAIN.guid] = { seen = 1, bank = true } }, account = {} }, 0 },
        { "an account bank that is true", { schema = 1, characters = {}, account = { eu = true } }, 0 },
        { "an account bank without items", { schema = 1, characters = {}, account = { eu = { at = 5, world = "eu-pvp", faction = "Alliance" } } }, 0 },
        { "an account bank with a negative count", { schema = 1, characters = {}, account = { eu = { items = { [2589] = -4, [4306] = 1 }, at = 5, world = "eu-pvp", faction = "Alliance" } } }, 0 },
        { "a name that is a number", { schema = 1, characters = { X = (function() local r = goodAlt(); r.name = 12; return r end)(), [ALT.guid] = goodAlt() }, account = {} }, 20 },
        { "a world that is a table", { schema = 1, characters = { X = (function() local r = goodAlt(); r.world = {}; return r end)() }, account = {} }, 0 },
        { "seen is a string", { schema = 1, characters = { X = (function() local r = goodAlt(); r.seen = "yesterday"; return r end)() }, account = {} }, 0 },
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

    -- A part without an items table was never seen: that is not the same as
    -- seen and empty (an empty bank is a fact, a missing one is not).
    LazyProf.db.global = { characters = {}, stock = { schema = 1, account = {}, characters = {
        [MAIN.guid] = { name = "Main Character", world = "eu-pvp", faction = "Alliance", seen = NOW,
            bags = { at = NOW }, bank = { at = NOW } },
        [ALT.guid] = { name = "Alt Character", world = "eu-pvp", faction = "Alliance", seen = NOW - 100,
            bags = { at = NOW - 100 }, bank = { at = NOW - 100, doubt = true } } } } }
    T.check("a bank without an items table is a bank never seen, not an empty one", Memory:OwnBank(MAIN.guid) == nil)
    local partless = Memory:Summary()
    T.check("the summary says never seen for both parts of both characters", #partless.characters == 2
        and partless.characters[1].bagItems == nil and partless.characters[1].bankItems == nil
        and partless.characters[2].bagItems == nil and partless.characters[2].bankItems == nil
        and partless.characters[1].bankDoubt == false and partless.characters[2].bankDoubt == false)
    local partlessAlts = Memory:Alts(MAIN)
    T.check("an alt's parts without items are not handed out, nor is its bank called in doubt", #partlessAlts == 1
        and partlessAlts[1].bags == nil and partlessAlts[1].bank == nil and partlessAlts[1].bankDoubt == nil)
    T.check("and there is no bank to mark", Memory:MarkBankDoubt(MAIN.guid) == false
        and LazyProf.db.global.stock.characters[MAIN.guid].bank.doubt == nil)

    -- A part without a usable time is counted but has no age.
    local out = read({ schema = 1, characters = { X = (function() local r = goodAlt(); r.bags.at = "noon"; return r end)() }, account = {} })
    T.check("a part without a usable time has no time", out.alts[1] ~= nil and out.alts[1].bagsAt == nil)
    -- The summary says how many records it could not read.
    out = read({ schema = 1, characters = { X = true, Y = "gone", [ALT.guid] = goodAlt() }, account = { eu = true } })
    T.check("the summary lists what it can read and counts the rest",
        #out.summary.characters == 1 and out.summary.unreadable == 3, out.summary.unreadable)

    -- Reading repairs nothing by itself ...
    local broken = { schema = 1, characters = "x", account = 5 }
    read(broken)
    T.check("reading leaves the saved table as it was", broken.characters == "x" and broken.account == 5)
    -- ... a save does.
    LazyProf.db.global = { stock = broken }
    T.check("a save into it works", Memory:SaveBags(MAIN, { [2589] = 3 }, {}, NOW) == true
        and Memory:SaveAccountBank(MAIN, { [2589] = 4 }, NOW) == true)
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
        [ALT.guid] = goodAlt() }, account = { eu = true, us = { items = {}, at = 1, world = "us-pvp", faction = "Alliance" } } } }
    local ok, dropped = pcall(Memory.Prune, Memory, NOW, MAIN.guid)
    T.check("prune does not fail on them", ok, dropped)
    local characters = LazyProf.db.global.stock.characters
    T.check("prune drops what is not a record, keeps the good one and the played character's entry",
        characters.X == nil and characters.Y == nil and characters.Z == nil and characters[ALT.guid] ~= nil
        and characters[MAIN.guid] ~= nil)
    for _, stock in ipairs({ "broken", { schema = 1, characters = "x", account = 5 },
            { schema = 1, characters = { X = true }, account = { eu = true } } }) do
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

-- A damaged value of the fields that say whether something may be counted
-- reads the way that counts less: "cannot send" and a note's banks are set
-- by anything but nothing and false, a soulbound part that cannot be read
-- keeps its whole part back, and a record without a usable time is no
-- record seen at all.
T.section("damaged values lean towards not counting", function()
    local ALT = who("Player-1-ALT", "Alt Character")
    local function alt(change)
        local record = { name = "Alt Character", world = "eu-pvp", faction = "Alliance", seen = NOW - 100,
                         bags = { items = { [2589] = 20 }, at = NOW - 100 }, bank = { items = { [2589] = 7 }, at = NOW - 100 } }
        change(record)
        LazyProf.db.global = { characters = {}, stock = { schema = 1, account = {}, characters = { [ALT.guid] = record } } }
        return record
    end
    local function counted()
        local n = 0
        for _, a in ipairs(Memory:Alts(MAIN)) do n = n + ((a.bags or {})[2589] or 0) + ((a.bank or {})[2589] or 0) end
        return n
    end

    for _, value in ipairs({ "yes", 1, 0, {}, "false" }) do
        alt(function(r) r.noSend = value end)
        T.eq("cannot send = " .. type(value) .. " " .. tostring(value) .. ": not an alt", counted(), 0)
        T.eq("and so it stands", Memory:Standing(MAIN)[ALT.guid], "nosend")
        T.check("and the summary says it cannot send", Memory:Summary().characters[1].canSend == false)
    end
    alt(function(r) r.noSend = false end)
    T.eq("cannot send = false: an alt", counted(), 27)
    T.check("(and the summary says it can send)", Memory:Summary().characters[1].canSend == true)

    for _, value in ipairs({ "yes", 1, {} }) do
        local record = alt(function(r) r.bagsAtBank = { items = { [2589] = 5 }, banks = { character = value, account = value }, at = NOW } end)
        local note = Memory:BagsAtBank(ALT.guid)
        T.check("a note whose banks read " .. type(value) .. ": both banks are named", note.character == true and note.account == true)
        record.bagsAtBank.banks = { character = false }
        note = Memory:BagsAtBank(ALT.guid)
        T.check("(false and nothing name no bank)", note.character == false and note.account == false)
    end

    for label, bound in pairs({ ["a number"] = 3, ["text"] = "x", ["true"] = true,
                                ["a table with an id that is text"] = { ["2589"] = 3 },
                                ["a table with a negative count"] = { [2589] = -2 } }) do
        alt(function(r) r.bags.bound = bound end)
        local alts = Memory:Alts(MAIN)
        T.check("a soulbound part that is " .. label .. ": those bags are not offered, the bank still is",
            #alts == 1 and alts[1].bags == nil and alts[1].bagsAt == nil and alts[1].bank[2589] == 7, counted())
    end
    alt(function(r) r.bank.bound = "x" end)
    local alts = Memory:Alts(MAIN)
    T.check("the same for a bank: its soulbound part cannot be read, it is not offered",
        alts[1].bank == nil and alts[1].bankAt == nil and alts[1].bags[2589] == 20)
    alt(function(r) r.bags.bound = { [2589] = 5 } end)
    T.eq("(a soulbound part that can be read is taken off as before)", counted(), 15 + 7)

    for _, seen in ipairs({ 0 / 0, math.huge, -math.huge, "noon" }) do
        alt(function(r) r.seen = seen end)
        T.eq("seen = " .. tostring(seen) .. ": no alt", counted(), 0)
        T.eq("seen = " .. tostring(seen) .. ": it stands as never seen", Memory:Standing(MAIN)[ALT.guid], "unseen")
        local record = LazyProf.db.global.stock.characters[ALT.guid]
        T.check("seen = " .. tostring(seen) .. ": nor does it take a name from a record that was seen", (function()
            LazyProf.db.global.stock.characters["Player-1-ALT2"] = { name = "Alt Character", world = "eu-pvp", faction = "Alliance",
                seen = NOW - 5000, bags = { items = { [2589] = 3 }, at = NOW - 5000 } }
            local n = counted()
            LazyProf.db.global.stock.characters["Player-1-ALT2"] = nil
            return n == 3
        end)())
        T.eq("seen = " .. tostring(seen) .. ": dropped at the start", Memory:Prune(NOW, MAIN.guid), 1)
        T.check("seen = " .. tostring(seen) .. ": gone", LazyProf.db.global.stock.characters[ALT.guid] == nil and record ~= nil)
        alt(function(r) r.seen = seen end)
        Memory:SaveBags(ALT, { [2589] = 20 }, {}, NOW)
        T.eq("seen = " .. tostring(seen) .. ": the character's own next save repairs it",
            LazyProf.db.global.stock.characters[ALT.guid].seen, NOW)
    end
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
    -- A time that is a number but no time (a damaged saved table): no age,
    -- rather than "nan days ago".
    local nan = 0 / 0
    T.check("a time that cannot be compared has no age", Memory.AgeText(NOW, nan) == nil and Memory.AgeText(nan, NOW) == nil
        and Memory.AgeText(nan, nan) == nil, tostring(Memory.AgeText(NOW, nan)))
    T.check("nor has a time without end", Memory.AgeText(NOW, -math.huge) == nil and Memory.AgeText(NOW, math.huge) == nil
        and Memory.AgeText(math.huge, NOW) == nil and Memory.AgeText(math.huge, math.huge) == nil,
        tostring(Memory.AgeText(NOW, -math.huge)))
    for _, at in ipairs({ NOW, NOW - 5 * HOUR, NOW - 5 * DAY }) do
        T.check("plain ASCII: " .. Memory.AgeText(NOW, at), not Memory.AgeText(NOW, at):find("[\128-\255]"))
    end
end)

T.section("summary", function()
    fresh()
    Memory:SaveBags(MAIN, { [1] = 1, [2] = 2 }, {}, NOW)
    Memory:SaveBank(MAIN, { [3] = 3 }, {}, NOW - DAY)
    Memory:SaveBags(who("Player-1-ALT", "Alt", "eu-normal", "Horde"), { [1] = 1 }, {}, NOW - 2 * DAY)
    Memory:SaveAccountBank(MAIN, { [1] = 1, [2] = 1, [3] = 1 }, NOW - 4 * DAY)
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
    T.check("account banks", #s.account == 1 and s.account[1].region == "eu" and s.account[1].world == "eu-pvp"
        and s.account[1].faction == "Alliance" and s.account[1].items == 3 and s.account[1].at == NOW - 4 * DAY)
end)

T.finish()
