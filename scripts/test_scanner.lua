-- scripts/test_scanner.lua
--
-- Modules/Inventory/Scanner.lua: which owned stock counts.
--   - the bags are read live, through the client adapter
--   - with the Syndicator addon the bank, mail, own auctions, alts and guild
--     bank come from it, each as its setting says
--   - without it only the bags count, and a scan that was asked for bank or
--     alt stock says so (meta.bagsOnly)
--   - a Self-Found character - by the addon's setting or by the game's own
--     flag - gets no stock from other characters
-- Also the stock options, and the wiring in Core/Init.lua: bag updates never
-- plan the path again, a refresh carries what the scan says, the reset,
-- /lp diag stock.
--
-- Run from the addon root:  lua5.1 scripts/test_scanner.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })

-- A clock the test moves by hand: a scan is cached for the frame it ran in.
local fakeNow = 100
_G.GetTime = function() return fakeNow end
local function nextFrame() fakeNow = fakeNow + 0.01 end

-- No container or bank call may be made from the scanner itself.
local function forbidden(name)
    return function() error(name .. " used outside the client adapter") end
end
_G.C_Container = setmetatable({}, { __index = function(_, name) error("C_Container." .. tostring(name) .. " used outside the adapter") end })
_G.C_Bank = setmetatable({}, { __index = function(_, name) error("C_Bank." .. tostring(name) .. " used outside the adapter") end })
_G.GetContainerNumSlots = forbidden("GetContainerNumSlots")
_G.GetContainerItemInfo = forbidden("GetContainerItemInfo")

local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Modules/Inventory/Scanner.lua",
})
local Inventory = LazyProf.Inventory

-- The client adapter as the scanner sees it; every bag read is counted.
local client
local function resetClient()
    client = {
        gameSelfFound = false,           -- what the game's own Self-Found flag reads (or "fail")
        bags = { [2589] = 5 },
        reads = 0,
    }
end
resetClient()
LazyProf.Client = {
    BagContents = function()
        client.reads = client.reads + 1
        return client.bags
    end,
    IsSelfFoundCharacter = function()
        if client.gameSelfFound == "fail" then error("flag unreadable") end
        return client.gameSelfFound
    end,
    RunStockDiagnostic = function(_, lines) lines[#lines + 1] = "adapter: stock lines" end,
}

local function fresh(profile)
    LazyProf.db.global = { characters = {} }
    LazyProf.db.char = { learnedRecipes = {}, selfFoundMode = false }
    LazyProf.db.profile.includeBankItems = true
    LazyProf.db.profile.includeAltCharacters = true
    LazyProf.db.profile.includeGuildBank = false
    for k, v in pairs(profile or {}) do LazyProf.db.profile[k] = v end
    resetClient()
    _G.Syndicator = nil
    Inventory:InvalidateCache()
    nextFrame()
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

-- Syndicator character data, as the scanner reads it.
local function slots(list)
    local bag = {}
    for itemId, n in pairs(list) do bag[#bag + 1] = { itemID = itemId, itemCount = n } end
    return bag
end
local function installSyndicator()
    local chars = {
        ["Main-Realm"] = {
            details = { character = "Main", faction = "Horde", realmNormalized = "Realm" },
            bags = { slots({ [2589] = 3 }) },                     -- not used: own bags are read live
            bank = { slots({ [2589] = 30 }) },
            bankTabs = { { slots = slots({ [4306] = 2 }) } },
            mail = slots({ [2589] = 4 }),
            auctions = slots({ [765] = 6 }),
        },
        ["Alt-Realm"] = {
            details = { character = "Alt", faction = "Horde", realmNormalized = "Realm" },
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
    return chars
end

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
T.section("no Syndicator: the bags of this character only", function()
    fresh()
    client.bags = { [2589] = 5, [765] = 2 }
    local combined, breakdown, meta = scan()
    T.check("the bags count", combined[2589] == 5 and combined[765] == 2)
    T.check("and are named as bags", breakdown[2589].bags == 5 and breakdown[765].bags == 2)
    T.check("nothing but the bags", count(combined) == 2 and breakdown[2589].bank == nil and breakdown[2589].alts == nil)
    T.check("Syndicator is not used", Inventory:UsesSyndicator() == false)
    -- Bank and alts are on by default: the scan says that only the bags count.
    T.check("bank and alts asked for: the scan says only the bags count", meta ~= nil and meta.bagsOnly == true)
    LazyProf.db.profile.includeAltCharacters = false
    T.check("bank alone asked for: the same", (select(3, scan())).bagsOnly == true)
    LazyProf.db.profile.includeBankItems, LazyProf.db.profile.includeAltCharacters = false, true
    T.check("alts alone asked for: the same", (select(3, scan())).bagsOnly == true)
    LazyProf.db.profile.includeAltCharacters = false
    T.check("neither asked for: nothing to say", select(3, scan()) == nil)
    -- A Self-Found character gets no alt stock from Syndicator either: alts
    -- alone are then nothing Syndicator would add.
    LazyProf.db.profile.includeAltCharacters = true
    LazyProf.db.char.selfFoundMode = true
    T.check("Self-Found, alts alone: nothing to say", select(3, scan()) == nil)
    LazyProf.db.profile.includeBankItems = true
    T.check("Self-Found, bank asked for: only the bags count", (select(3, scan())).bagsOnly == true)
    LazyProf.db.char.selfFoundMode = false
    -- The guild bank alone is no reason: it always needed Syndicator, and says so.
    LazyProf.db.profile.includeBankItems, LazyProf.db.profile.includeAltCharacters = false, false
    LazyProf.db.profile.includeGuildBank = true
    combined, breakdown, meta = scan()
    T.check("guild bank alone: the bags, nothing to say", combined[2589] == 5 and breakdown[2589].guildBank == nil and meta == nil)
    -- Nothing is saved anywhere.
    T.check("nothing is saved", LazyProf.db.global.stock == nil and count(LazyProf.db.global) == 1)
end)

-- ===========================================================================
T.section("Syndicator present: bank, mail, auctions, alts and guild bank", function()
    fresh()
    installSyndicator()
    local combined, breakdown, meta = scan()
    T.check("Syndicator is used", Inventory:UsesSyndicator() == true)
    T.eq("bags (live) + bank + mail + the alt's bags and bank", combined[2589], 5 + 30 + 4 + 50 + 60)
    T.eq("bank from Syndicator", breakdown[2589].bank, 30)
    T.eq("bank tabs from Syndicator", breakdown[4306].bank, 2)
    T.eq("mail", breakdown[2589].mail, 4)
    T.eq("own auctions", breakdown[765].auctions, 6)
    T.check("the alt under Syndicator's name", breakdown[2589].alts["Alt-Realm"].bags == 50
        and breakdown[2589].alts["Alt-Realm"].bank == 60 and breakdown[2592].alts["Alt-Realm"].mail == 8)
    T.check("nothing to say: everything asked for is counted", meta == nil)
    T.check("the guild bank stays off by default", breakdown[2589].guildBank == nil)
    LazyProf.db.profile.includeGuildBank = true
    combined, breakdown = scan()
    T.eq("the guild bank when it is turned on", breakdown[2589].guildBank, 500)
    LazyProf.db.profile.includeGuildBank = false

    LazyProf.db.profile.includeBankItems = false
    combined, breakdown = scan()
    T.check("bank items off: no bank, the alts' bags and mail still", combined[2589] == 5 + 4 + 50
        and breakdown[2589].bank == nil and breakdown[2589].alts["Alt-Realm"].bank == nil, combined[2589])
    LazyProf.db.profile.includeBankItems = true
    LazyProf.db.profile.includeAltCharacters = false
    combined, breakdown, meta = scan()
    T.check("alts off: the character's own stock only", combined[2589] == 5 + 30 + 4 and breakdown[2589].alts == nil
        and combined[2592] == nil and meta == nil, combined[2589])
    LazyProf.db.profile.includeAltCharacters = true

    -- A Self-Found character gets nothing from the alts.
    LazyProf.db.char.selfFoundMode = true
    combined, breakdown = scan()
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
    -- The adapter answers true or false; anything else is not the flag.
    for _, value in ipairs({ 1, "yes" }) do
        client.gameSelfFound = value
        T.eq("a flag that is not true is none (" .. type(value) .. ")", (scan())[2589], 5 + 30 + 4 + 50 + 60 + 500)
    end
    -- A flag that cannot be read: the setting alone decides, and the scan works.
    client.gameSelfFound = "fail"
    local ok, failed = pcall(scan)
    T.check("an unreadable flag does not stop the scan", ok and failed[2589] == 5 + 30 + 4 + 50 + 60 + 500, failed)
    LazyProf.db.char.selfFoundMode = true
    T.eq("and the setting still decides", (scan())[2589], 5 + 30 + 4)
    LazyProf.db.char.selfFoundMode = false
    client.gameSelfFound = false
    LazyProf.db.profile.includeGuildBank = false

    -- A Syndicator without a record of the character: its bags still count.
    _G.Syndicator.API.GetByCharacterFullName = function() return nil end
    combined, breakdown, meta = scan()
    T.check("no Syndicator record: the bags", combined[2589] == 5 and count(combined) == 1 and meta == nil, combined[2589])
end)

-- ===========================================================================
T.section("frame cache", function()
    fresh()
    client.reads = 0
    local a1, b1, m1 = Inventory:ScanAll()
    local a2, b2, m2 = Inventory:ScanAll()
    T.eq("two scans in one frame read the bags once", client.reads, 1)
    T.check("and hand out the same three results", a1 == a2 and b1 == b2 and m1 == m2 and m1 ~= nil)
    nextFrame()
    Inventory:ScanAll()
    T.eq("the next frame reads again", client.reads, 2)

    -- A stock setting changed inside the frame is not answered from the
    -- frame's earlier scan, whoever changed it. Each setting on its own,
    -- with nothing but the setting changed between the two scans.
    installSyndicator()
    nextFrame()
    T.eq("everything on", (Inventory:ScanAll())[2589], 149)
    LazyProf.db.profile.includeAltCharacters = false
    T.eq("alts turned off in the same frame", (Inventory:ScanAll())[2589], 39)
    LazyProf.db.profile.includeAltCharacters = true
    T.eq("and on again", (Inventory:ScanAll())[2589], 149)
    LazyProf.db.profile.includeBankItems = false
    T.eq("bank items turned off in the same frame, nothing else", (Inventory:ScanAll())[2589], 59)
    LazyProf.db.profile.includeBankItems = true
    T.eq("and on again", (Inventory:ScanAll())[2589], 149)
    LazyProf.db.char.selfFoundMode = true
    T.eq("Self-Found turned on in the same frame, nothing else", (Inventory:ScanAll())[2589], 39)
    LazyProf.db.char.selfFoundMode = false
    -- The game's own Self-Found flag is asked at every scan: a scan made
    -- under the other answer does not serve.
    client.gameSelfFound = true
    T.eq("the game's Self-Found flag reads true in the same frame, nothing else", (Inventory:ScanAll())[2589], 39)
    client.gameSelfFound = false
    T.eq("and false again", (Inventory:ScanAll())[2589], 149)
    T.check("guild bank off", (select(2, Inventory:ScanAll()))[2589].guildBank == nil)
    LazyProf.db.profile.includeGuildBank = true
    T.eq("guild bank turned on in the same frame, nothing else", (select(2, Inventory:ScanAll()))[2589].guildBank, 500)
    LazyProf.db.profile.includeGuildBank = false
    T.check("and off again", (select(2, Inventory:ScanAll()))[2589].guildBank == nil)
    client.reads = 0
    Inventory:ScanAll()
    T.eq("unchanged settings: the frame's scan answers", client.reads, 0)
    -- Syndicator going away (or coming) in the same frame is not answered
    -- from the frame's earlier scan either.
    local syndicator = _G.Syndicator
    _G.Syndicator = nil
    local combined, _, meta = Inventory:ScanAll()
    T.check("Syndicator gone in the same frame: the bags only, and said so", combined[2589] == 5 and meta.bagsOnly == true)
    _G.Syndicator = syndicator
    T.eq("and back", (Inventory:ScanAll())[2589], 149)
    _G.Syndicator = nil
    -- InvalidateCache drops the frame's scan.
    T.eq("without Syndicator again", (Inventory:ScanAll())[2589], 5)
    client.bags = { [2589] = 9 }
    T.eq("the bags changed in the same frame: still the frame's scan", (Inventory:ScanAll())[2589], 5)
    Inventory:InvalidateCache()
    T.eq("after InvalidateCache: read again", (Inventory:ScanAll())[2589], 9)
end)

-- ===========================================================================
T.section("diagnostic lines", function()
    fresh()
    local lines = {}
    Inventory:RunDiagnostic(lines)
    local text = table.concat(lines, "\n")
    T.eq("without Syndicator: the source line says the bags only", lines[1], "source: the bags only (Syndicator is not installed)")
    T.eq("the settings, and beside the Self-Found setting what the game's own flag reads", lines[2],
        "settings: bank=true alts=true guildBank=false selfFound=false gameSelfFound=false")
    T.check("no line about remembered stock", not text:find("memory", 1, true) and not text:find("remembered", 1, true)
        and not text:find("bank visit", 1, true), text)

    installSyndicator()
    LazyProf.db.char.selfFoundMode = true
    client.gameSelfFound = true
    lines = {}
    Inventory:RunDiagnostic(lines)
    T.eq("with Syndicator: the source line names it", lines[1], "source: Syndicator (bank, mail, auctions, alts and guild bank)")
    T.eq("the settings as they stand", lines[2], "settings: bank=true alts=true guildBank=false selfFound=true gameSelfFound=true")
    client.gameSelfFound = "fail"
    lines = {}
    local ok, err = pcall(Inventory.RunDiagnostic, Inventory, lines)
    T.check("an unreadable flag: no Lua error", ok, err)
    T.check("and the line says so", (lines[2] or ""):find("gameSelfFound=not readable: ", 1, true) ~= nil, lines[2])
    client.gameSelfFound = false
    LazyProf.db.char.selfFoundMode = false
end)

-- ===========================================================================
-- The Syndicator block of /lp diag stock: one line per character Syndicator
-- knows, with every plain value of its record's details. Syndicator's record
-- layout is not known for sure, so every read is defensive.
T.section("diagnostic: what Syndicator knows of each character", function()
    fresh()
    local function dump()
        local lines = {}
        local ok, err = pcall(Inventory.RunDiagnostic, Inventory, lines)
        return lines, table.concat(lines, "\n"), ok, err
    end
    local function hasLine(text, line)
        return ("\n" .. text .. "\n"):find("\n" .. line .. "\n", 1, true) ~= nil
    end

    -- Not installed: one line says so.
    local lines, text = dump()
    T.check("not installed: one line", hasLine(text, "syndicator: not installed"), text)
    T.eq("not installed: after the source and settings lines", lines[3], "syndicator: not installed")

    -- Installed: a line per character, the plain values of its details sorted
    -- by key; tables and functions are left out.
    local chars = installSyndicator()
    chars["Main-Realm"].details = { realmNormalized = "Realm", className = "MAGE", level = 60, show = true,
        faction = "Alliance", character = "Main", hidden = false, lastSeen = 1763900000,
        nested = { a = 1 }, fn = function() end }
    chars["Alt-Shard 7"] = { details = { realmNormalized = "Shard7", character = "Alt", note = "two\nlines" } }
    chars["Bare-Realm"] = {}
    _G.Syndicator.API.GetAllCharacters = function() return { "Main-Realm", "Alt-Realm", "Alt-Shard 7", "Bare-Realm", "Gone-Realm" } end
    chars["Alt-Realm"].details = {}
    lines, text = dump()
    T.check("installed: a head line with the count and who is played",
        hasLine(text, 'syndicator: characters=5 current="Main-Realm"'), text)
    T.check("the current character: marked, its plain values sorted by key",
        hasLine(text, 'syndicator character: "Main-Realm" [current] character="Main" className="MAGE" faction="Alliance" '
            .. 'hidden=false lastSeen=1763900000 level=60 realmNormalized="Realm" show=true'), text)
    T.check("tables and functions are left out", not text:find("nested", 1, true) and not text:find("fn=", 1, true), text)
    T.check("another character: not marked; a line break in a value is a space",
        hasLine(text, 'syndicator character: "Alt-Shard 7" character="Alt" note="two lines" realmNormalized="Shard7"'), text)
    T.check("a record with empty details", hasLine(text, 'syndicator character: "Alt-Realm" details: no plain values'), text)
    T.check("a record without details", hasLine(text, 'syndicator character: "Bare-Realm" details: none'), text)
    T.check("a name without a record", hasLine(text, 'syndicator character: "Gone-Realm" record: none'), text)
    T.check("one line per character, in Syndicator's order", text:find('"Main-Realm"', 1, true) < text:find('"Alt-Realm"', 1, true)
        and text:find('"Alt-Shard 7"', 1, true) < text:find('"Bare-Realm"', 1, true))
    T.check("plain ASCII", not text:find("[\128-\255]"))
    -- Which alts count, and why the others do not (the scan's own rule).
    T.check("which alts count",
        hasLine(text, 'syndicator alts: counted none; not counted "Alt-Realm" (faction unknown), "Alt-Shard 7" (faction unknown), '
            .. '"Bare-Realm" (no details), "Gone-Realm" (no record)'), text)
    chars["Alt-Realm"].details = { faction = "Alliance", realmNormalized = "Realm" }
    chars["Alt-Shard 7"].details.faction = "Alliance"
    lines, text = dump()
    T.check("an alt that counts, and one of another realm",
        text:find('syndicator alts: counted "Alt-Realm"; not counted "Alt-Shard 7" (other realm),', 1, true) ~= nil, text)
    chars["Alt-Realm"].details = {}
    chars["Alt-Shard 7"].details.faction = nil
    -- The fields of one item as Syndicator stores it (says whether it marks
    -- soulbound items, and how); long text is shown by its length.
    chars["Main-Realm"].bags = { {}, { { itemID = 2589, itemCount = 3, isBound = false, itemLink = string.rep("x", 60), quality = 1 } } }
    lines, text = dump()
    T.check("the fields of the first stored item",
        hasLine(text, 'syndicator item fields: isBound=false itemCount=3 itemID=2589 itemLink=<60 characters> quality=1'), text)
    chars["Main-Realm"].bags, chars["Main-Realm"].bank = {}, {}
    lines, text = dump()
    T.check("no stored item: said", hasLine(text, "syndicator item fields: no stored item"), text)

    -- A record whose read fails, and details that are no table.
    _G.Syndicator.API.GetByCharacterFullName = function(name)
        if name == "Gone-Realm" then error("record boom") end
        if name == "Bare-Realm" then return { details = "text" } end
        return chars[name]
    end
    lines, text = dump()
    T.check("a failing record read is said in its line", text:find('syndicator character: "Gone-Realm" record: ', 1, true) ~= nil
        and text:find("record boom", 1, true) ~= nil, text)
    T.check("details that are no table", hasLine(text, 'syndicator character: "Bare-Realm" details: none'), text)
    T.check("the other characters still print", hasLine(text, 'syndicator character: "Alt-Realm" details: no plain values'), text)

    -- The character list and the current character, read defensively.
    _G.Syndicator.API.GetCurrentCharacter = nil
    lines, text = dump()
    T.check("no current-character call: said, and no character is marked",
        text:find("syndicator: characters=5 current=not readable: no Syndicator.API.GetCurrentCharacter", 1, true) ~= nil
        and not text:find("[current]", 1, true), text)
    _G.Syndicator.API.GetAllCharacters = function() error("list boom") end
    local ok, err
    lines, text, ok, err = dump()
    T.check("a failing list: no Lua error", ok, err)
    T.check("a failing list: said", text:find("syndicator: the character list could not be read: ", 1, true) ~= nil
        and text:find("list boom", 1, true) ~= nil, text)
    T.check("and the lines before it stay", lines[1] == "source: Syndicator (bank, mail, auctions, alts and guild bank)", lines[1])
    _G.Syndicator.API.GetAllCharacters = function() return nil end
    lines, text = dump()
    T.check("no list: said", hasLine(text, "syndicator: no character list"), text)
    _G.Syndicator.API.GetAllCharacters = nil
    lines, text, ok = dump()
    T.check("no list call: said, no Lua error", ok and text:find("syndicator: the character list could not be read: no Syndicator.API.GetAllCharacters", 1, true) ~= nil, text)

    -- At most 60 characters, then how many more.
    local many = {}
    for i = 1, 65 do many[i] = "Char" .. i .. "-Realm" end
    _G.Syndicator.API.GetAllCharacters = function() return many end
    _G.Syndicator.API.GetCurrentCharacter = function() return "Char1-Realm" end
    _G.Syndicator.API.GetByCharacterFullName = function(name) return { details = { character = name:match("^[^-]+") } } end
    lines, text = dump()
    local shown = 0
    for _, line in ipairs(lines) do
        if line:find("^syndicator character: ") then shown = shown + 1 end
    end
    T.eq("capped at 60 characters", shown, 60)
    T.check("then how many more", hasLine(text, "syndicator: 5 more"), text)
    T.check("the alts line stops at 60 as well", text:find("; not counted ", 1, true) ~= nil
        and text:find(", and 5 more", 1, true) ~= nil, text)
    T.check("the 60th is shown, the 61st not", text:find('"Char60-Realm"', 1, true) ~= nil and not text:find('"Char61-Realm"', 1, true))
    many = {}
    for i = 1, 60 do many[i] = "Char" .. i .. "-Realm" end
    lines, text = dump()
    T.check("exactly 60: no more-line", not text:find(" more", 1, true), text)

    -- A Syndicator whose API is no table at all: nothing is read.
    _G.Syndicator = { API = "broken" }
    lines, text, ok, err = dump()
    T.check("an API that is no table: no Lua error", ok, err)
    _G.Syndicator = nil
end)

-- ===========================================================================
-- Review F3: an alt counts only on the played character's realm (on WoW
-- Forever Syndicator records the ruleset there, "PvP") and faction, as
-- Syndicator recorded both, and without its soulbound items. The played
-- character's own bound items count.
T.section("Syndicator alts: same realm and faction, no soulbound items", function()
    fresh()
    local chars = installSyndicator()
    chars["Main-Realm"].bank = { { { itemID = 2589, itemCount = 30 }, { itemID = 4306, itemCount = 9, isBound = true } } }
    chars["Alt-Realm"].bags = { { { itemID = 2589, itemCount = 50 }, { itemID = 765, itemCount = 7, isBound = true } } }
    chars["Alt-Realm"].bank = { { { itemID = 2589, itemCount = 60, isBound = true } } }
    chars["Alt-Realm"].bankTabs = { { slots = { { itemID = 2589, itemCount = 6, isBound = true }, { itemID = 2592, itemCount = 2 } } } }
    chars["Other-Realm"] = { details = { faction = "Alliance", realmNormalized = "Realm" }, bags = { slots({ [2589] = 1000 }) } }
    chars["Far-Elsewhere"] = { details = { faction = "Horde", realmNormalized = "Elsewhere" }, bags = { slots({ [2589] = 2000 }) } }
    chars["Bare-Realm"] = { bags = { slots({ [2589] = 4000 }) } }
    _G.Syndicator.API.GetAllCharacters = function()
        return { "Main-Realm", "Alt-Realm", "Other-Realm", "Far-Elsewhere", "Bare-Realm" }
    end
    local combined, breakdown = scan()
    local alts = breakdown[2589].alts or {}
    T.eq("an alt of the same realm and faction counts, without its bound items", alts["Alt-Realm"] and alts["Alt-Realm"].bags, 50)
    T.check("its bound bank items are left out", alts["Alt-Realm"].bank == nil, alts["Alt-Realm"].bank)
    T.check("its bound bag items are left out", breakdown[765] == nil or breakdown[765].alts == nil)
    T.eq("its unbound bank-tab items count", breakdown[2592].alts["Alt-Realm"].bank, 2)
    T.check("an alt of the other faction does not count", alts["Other-Realm"] == nil)
    T.check("an alt of another realm does not count", alts["Far-Elsewhere"] == nil)
    T.check("an alt Syndicator has no details for does not count", alts["Bare-Realm"] == nil)
    T.eq("the played character's own bound items count", breakdown[4306].bank, 9 + 2)
    T.eq("in all", combined[2589], 5 + 30 + 4 + 50)
    -- A realm recorded only as `realm` (no realmNormalized) is compared too.
    chars["Far-Elsewhere"].details = { faction = "Horde", realm = "Realm" }
    chars["Main-Realm"].details = { faction = "Horde", realm = "Realm" }
    chars["Alt-Realm"].details = { faction = "Horde", realm = "Realm" }
    breakdown = select(2, scan())
    T.check("realm names without the normalized form: the same realm counts",
        breakdown[2589].alts["Far-Elsewhere"] ~= nil and breakdown[2589].alts["Alt-Realm"] ~= nil)
    -- The played character's realm or faction unknown: no alt can be judged.
    chars["Main-Realm"].details = nil
    combined, breakdown = scan()
    T.check("the played character's details unknown: no alt counts", breakdown[2589].alts == nil)
    T.eq("its own stock still does", combined[2589], 5 + 30 + 4)
end)

T.section("options", function()
    fresh()
    local stockOptions = LazyProf.options.args.display.args
    local bank, alts, guild = stockOptions.includeBankItems, stockOptions.includeAltCharacters, stockOptions.includeGuildBank
    local function text(value) return type(value) == "function" and value() or value end

    -- Without Syndicator the three options are greyed out and say why.
    for _, option in ipairs({ bank, alts, guild }) do
        T.check(option.name .. ": greyed out without Syndicator", option.disabled() == true)
        T.check(option.name .. ": says it needs Syndicator", text(option.desc):find("Requires: Syndicator addon installed.", 1, true) ~= nil,
            text(option.desc))
    end
    for _, option in ipairs({ bank, alts }) do
        T.check(option.name .. ": says what is counted without it",
            text(option.desc):find("Without it only the bags of the character you are playing are counted.", 1, true) ~= nil,
            text(option.desc))
        T.check(option.name .. ": says nothing of a memory of LazyProf's own",
            not text(option.desc):find("remembers", 1, true) and not text(option.desc):find("how old", 1, true), text(option.desc))
    end
    -- The defaults stay: both on (the scan then says only the bags count).
    T.check("defaults unchanged", LazyProf.defaults.profile.includeBankItems == true
        and LazyProf.defaults.profile.includeAltCharacters == true and LazyProf.defaults.profile.includeGuildBank == false)
    installSyndicator()
    for _, option in ipairs({ bank, alts, guild }) do
        T.check(option.name .. ": usable with Syndicator", option.disabled() == false)
    end
    T.check("bank: with Syndicator no longer says it is required",
        not text(bank.desc):find("Requires: Syndicator", 1, true) and text(bank.desc):find("Syndicator addon", 1, true) ~= nil,
        text(bank.desc))
    T.check("alts: with Syndicator no longer says it is required",
        not text(alts.desc):find("Requires: Syndicator", 1, true) and text(alts.desc):find("Syndicator addon", 1, true) ~= nil,
        text(alts.desc))
    _G.Syndicator = nil
    T.check("the forget button is gone", stockOptions.forgetStock == nil)

    -- Self-Found: what it means for stock.
    local selfFound = LazyProf.options.args.general.args.selfFoundMode
    local selfFoundText = text(selfFound.desc)
    for _, sentence in ipairs({
        "Such a character cannot be sent anything: stock of your other characters and of the guild bank is not counted for it.",
        "A character the game itself marks Self-Found is treated this way for stock even with this setting off.",
    }) do
        T.check("Self-Found: says, word for word: " .. sentence:sub(1, 44) .. "...", selfFoundText:find(sentence, 1, true) ~= nil,
            selfFoundText)
    end
    T.check("Self-Found: says nothing of a memory of LazyProf's own", not selfFoundText:find("remembers", 1, true), selfFoundText)
    T.check("alts: says, word for word, that a Self-Found character gets no alt stock",
        text(alts.desc):find("A character in Self-Found mode cannot be sent anything, so no alt stock is counted for it.", 1, true) ~= nil,
        text(alts.desc))
    T.check("guild bank: says, word for word, that it is not counted for a Self-Found character",
        text(guild.desc):find("A character in Self-Found mode cannot be handed anything, so the guild bank is not counted for it.",
            1, true) ~= nil, text(guild.desc))
    local reasons = {}
    local savedRecalc = LazyProf.Recalculate
    LazyProf.Recalculate = function(_, reason) reasons[#reasons + 1] = reason end
    selfFound.set(nil, true)
    T.check("Self-Found on: stored, and planned again", LazyProf.db.char.selfFoundMode == true and reasons[1] == "setting changed")
    selfFound.set(nil, false)
    bank.set(nil, false)
    T.check("bank option: stored, and planned again", LazyProf.db.profile.includeBankItems == false and reasons[3] == "setting changed")
    bank.set(nil, true)
    LazyProf.Recalculate = savedRecalc
    for _, option in ipairs({ bank, alts, guild, selfFound }) do
        T.check("plain ASCII: " .. option.name, not (text(option.desc) .. option.name):find("[\128-\255]"))
    end
end)

-- ===========================================================================
-- Core/Init.lua: bag updates, the refresh, the reset, the slash command.
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
        installSyndicator()
        local planned
        LazyProf.Client.GetLine = function() return "tailoring", 100, 150 end
        LazyProf.Client.IsOpen = function() return false end
        LazyProf.Pathfinder = { Calculate = function()
            planned = Inventory:ScanAll()
            return nil
        end }
        local display, general = LazyProf.options.args.display.args, LazyProf.options.args.general.args
        nextFrame()
        T.eq("this frame's scan counts the alt", (Inventory:ScanAll())[2589], 149)
        display.includeAltCharacters.set(nil, false)
        T.eq("alts turned off in the same frame: the planning scans again", planned[2589], 39)
        display.includeAltCharacters.set(nil, true)
        T.eq("and on again", planned[2589], 149)
        general.selfFoundMode.set(nil, true)
        T.eq("Self-Found turned on in the same frame", planned[2589], 39)
        general.selfFoundMode.set(nil, false)
        display.includeBankItems.set(nil, false)
        T.eq("bank items turned off in the same frame", planned[2589], 59)
        display.includeBankItems.set(nil, true)
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
        T.eq("this frame's scan", (Inventory:ScanAll())[2589], 5)
        client.bags = { [2589] = 6 }
        LazyProf:Recalculate("test")
        T.eq("a recalculation scans afresh", planned[2589], 6)
        client.bags = { [2589] = 5 }
        LazyProf.Pathfinder = nil
        Inventory:InvalidateCache()
    end

    -- OnEnable: BAG_UPDATE has its one handler in Init; no other stock event.
    local events = {}
    LazyProf.RegisterEvent = function(_, event, handler) events[event] = handler end
    LazyProf.Client.Start = function() end
    LazyProf:OnEnable()
    T.check("BAG_UPDATE keeps its one handler in Init", events.BAG_UPDATE == "OnBagUpdate")
    T.check("no batch notice, logout or bank event is asked for", events.BAG_UPDATE_DELAYED == nil
        and events.PLAYER_LOGOUT == nil and events.BANKFRAME_OPENED == nil and events.BANKFRAME_CLOSED == nil)
    T.check("the memory's entry points are gone", Inventory.Initialize == nil and Inventory.OnBagUpdate == nil
        and Inventory.OnLogout == nil and Inventory.ForgetRemembered == nil and LazyProf.OnDatabaseShutdown == nil
        and LazyProf.OnBagUpdateDelayed == nil and LazyProf.StockMemory == nil)

    -- The database needs no shutdown notice any more.
    do
        local callbacks = 0
        local savedDb, savedLibStub = LazyProf.db, _G.LibStub
        local fakeDb = { sv = {}, profile = savedDb.profile, char = savedDb.char, global = savedDb.global,
            RegisterCallback = function() callbacks = callbacks + 1 end }
        _G.LibStub = function() return { New = function() return fakeDb end } end
        LazyProf.RegisterChatCommand = function() end
        local savedSetup = LazyProf.SetupConfig
        LazyProf.SetupConfig = nil
        LazyProf:OnInitialize()
        T.eq("no database notice is asked for", callbacks, 0)
        LazyProf.SetupConfig = savedSetup
        _G.LibStub = savedLibStub
        LazyProf.db = savedDb
    end

    -- Bag updates: a light refresh, never a recalculation.
    local recalcs, shoppingRefreshes = 0, 0
    LazyProf.Recalculate = function() recalcs = recalcs + 1 end
    LazyProf.ScheduleRecalculation = function() recalcs = recalcs + 1 end
    LazyProf.ScheduleShoppingListRefresh = function() shoppingRefreshes = shoppingRefreshes + 1 end
    LazyProf.Client.IsOpen = function() return true end
    client.reads = 0
    LazyProf:OnBagUpdate("BAG_UPDATE", 0)
    LazyProf:OnBagUpdate("BAG_UPDATE", 5)
    T.eq("the shown list is refreshed, lightly", shoppingRefreshes, 2)
    T.eq("no recalculation from bag updates", recalcs, 0)
    T.eq("and the bags are not read for it", client.reads, 0)

    -- A refresh puts what the scan says on the shown paths with the stock itself.
    local live = { steps = { {} } }
    local planning = { steps = { {} } }
    LazyProf.Pathfinder = { currentPath = live }
    local redraws = 0
    LazyProf.GuideWindow = { PlanningPath = function() return planning end, Refresh = function() redraws = redraws + 1 end }
    nextFrame()
    LazyProf:RefreshShoppingList()
    T.check("refresh: the live path gets stock, sources and what the scan says",
        live.inventory ~= nil and live.sourceBreakdown ~= nil and live.stockMeta ~= nil and live.stockMeta.bagsOnly == true)
    T.check("refresh: the planning path gets the same", planning.stockMeta == live.stockMeta and planning.inventory == live.inventory)
    installSyndicator()
    nextFrame()
    LazyProf:RefreshShoppingList()
    T.check("refresh with Syndicator: nothing to say", live.stockMeta == nil and live.inventory[2589] == 149)
    _G.Syndicator = nil
    T.eq("refresh: one redraw each", redraws, 2)
    T.eq("refresh: still no recalculation", recalcs, 0)
    LazyProf.Pathfinder, LazyProf.GuideWindow = nil, nil

    -- /lp reset and "Reset All Settings": the database is reset and the
    -- window planned again; the player is told what went with the settings.
    do
        local resets = 0
        local reasons = {}
        LazyProf.db.ResetDB = function() resets = resets + 1 end
        LazyProf.Recalculate = function(_, reason) reasons[#reasons + 1] = reason end
        printed = {}
        LazyProf:SlashCommand("reset")
        T.check("/lp reset: the database is reset and planned again", resets == 1 and reasons[1] == "settings reset", resets)
        T.check("/lp reset: the player is told what was cleared", printed[1] == LazyProf.RESET_MESSAGE, printed[1])
        -- A reset wipes the whole saved database (AceDB ResetDB): the message
        -- names everything that goes, so nothing is a surprise later.
        local msg = LazyProf.RESET_MESSAGE
        for _, what in ipairs({ "vendor prices", "trainers", "targets", "chosen recipes", "routes",
                "craft-or-buy choices", "window positions", "Self-Found", "known recipes" }) do
            T.check("the message names what is cleared: " .. what, msg:find(what, 1, true) ~= nil, msg)
        end
        T.check("the message says nothing of remembered stock", not msg:find("remembered stock", 1, true), msg)
        local button = LazyProf.options.args.debug and LazyProf.options.args.debug.args.resetDB
        if not button then
            for _, group in pairs(LazyProf.options.args) do
                if type(group) == "table" and group.args and group.args.resetDB then button = group.args.resetDB end
            end
        end
        printed = {}
        button.func()
        T.check("Reset All Settings: the same", resets == 2 and reasons[2] == "settings reset" and printed[1] == LazyProf.RESET_MESSAGE)
        T.check("Reset All Settings: its texts say nothing of remembered stock",
            not button.desc:find("remembered stock", 1, true) and not button.confirmText:find("remembered stock", 1, true)
            and not button.desc:find("bank", 1, true) and not button.confirmText:find("bank", 1, true), button.desc)
        for _, what in ipairs({ "chosen recipes", "routes", "window positions", "Self-Found", "known recipes" }) do
            T.check("Reset All Settings: its confirmation names " .. what, button.confirmText:find(what, 1, true) ~= nil,
                button.confirmText)
        end
        LazyProf.db.ResetDB = nil
        LazyProf.Recalculate = function() recalcs = recalcs + 1 end
    end

    -- /lp diag stock
    local shown
    LazyProf.ShowDiagnosticOutput = function(_, text) shown = text end
    LazyProf:SlashCommand("diag stock")
    T.check("/lp diag stock opens the copyable window", type(shown) == "string")
    T.check("its first line names the client", shown:find("diag stock: build=1.60.1 (70938) interface=16001 family=forever", 1, true) == 1, shown)
    T.check("the adapter's lines are in it", shown:find("adapter: stock lines", 1, true) ~= nil, shown)
    T.check("and the scanner's", shown:find("source: the bags only (Syndicator is not installed)", 1, true) ~= nil
        and shown:find("syndicator: not installed", 1, true) ~= nil, shown)
    LazyProf.Client.RunStockDiagnostic = function() error("boom") end
    LazyProf:SlashCommand("diag stock")
    T.check("a failing adapter section is reported, the rest still prints",
        shown:find("SECTION ERROR: adapter", 1, true) ~= nil and shown:find("source: ", 1, true) ~= nil, shown)
    -- The scanner's section is protected the same way: a failure in it is
    -- reported in the window, and what the adapter printed stays.
    LazyProf.Client.RunStockDiagnostic = function(_, out) out[#out + 1] = "adapter: stock lines" end
    local realRun = Inventory.RunDiagnostic
    Inventory.RunDiagnostic = function() error("stock boom") end
    shown = nil
    local ran, runError = pcall(LazyProf.SlashCommand, LazyProf, "diag stock")
    Inventory.RunDiagnostic = realRun
    T.check("a failing stock section does not raise", ran, runError)
    T.check("it is reported with its error, after the adapter's lines", type(shown) == "string"
        and shown:find("adapter: stock lines\nSECTION ERROR: stock: ", 1, true) ~= nil
        and shown:find("stock boom", 1, true) ~= nil, shown)
    printed = {}
    LazyProf:SlashCommand("diag")
    local help = table.concat(printed, "\n")
    T.check("/lp diag lists the stock dump", help:find("/lp diag stock", 1, true) ~= nil)
    T.check("and no longer speaks of remembered banks", not help:find("remembered for your characters", 1, true), help)
    T.check("it names the characters Syndicator knows", help:find("the characters Syndicator knows", 1, true) ~= nil, help)
end)

T.finish()
