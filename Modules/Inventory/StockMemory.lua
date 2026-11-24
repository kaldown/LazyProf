-- Modules/Inventory/StockMemory.lua
-- What each character had in its bags and its bank when LazyProf last saw
-- them, and the account-wide bank of each world. With it, bank and alt stock
-- count when no inventory addon is installed (Modules/Inventory/Scanner.lua
-- decides when it is used).
--
-- Saved account-wide (LazyProfDB.global.stock), one record per character GUID:
--   stock.schema                 format number of this table (1)
--   stock.characters[guid] = {
--       name, world, faction,    who it is; alts are the characters of the
--                                same world and faction
--       seen,                    time of its last save of either kind
--       noSend,                  true when it cannot send anything to other
--                                characters (Self-Found); absent otherwise
--       bags = { items = { [itemId] = count }, bound = { [itemId] = count }, at },
--       bank = { items = ..., bound = ..., at },
--   }
--   stock.account[world] = { items = { [itemId] = count }, at }
-- `bound` holds how many of an item's count are soulbound (left out when
-- there are none): they stay in the owner's own bank, but another character
-- cannot be sent them. Times are server time in seconds. A save replaces the
-- record's table; nothing is ever appended. Characters not seen for
-- KEEP_DAYS days are dropped by Prune.
--
-- The format number is written here and is deliberately not among the
-- database defaults: the database strips saved values that equal a default
-- and puts the default back on load, so a default would relabel old data the
-- day the format changes. A table in a format this file does not know is
-- neither read nor written over.
--
-- The saved table is read defensively: it may have been edited by hand, cut
-- off by a crash or written by a build with a defect. A record that is not a
-- table is skipped, as is a bags / bank / bound part that is not one, an
-- item id that is not a number, a count that is not a positive whole number
-- and a name that is not text. Nothing negative is ever handed out, and what
-- is handed out is a copy. Reading changes nothing; the next save replaces
-- what was not a table.
--
-- This file is pure: who the character is, what it holds and what time it is
-- are passed in (the client adapter supplies them).
--   identity = { guid, name, world, faction }
local ADDON_NAME, LazyProf = ...

local StockMemory = {}
LazyProf.StockMemory = StockMemory

local SCHEMA = 1
local HOUR = 3600
local DAY = 86400
StockMemory.KEEP_DAYS = 180

-- The two saved tables - characters by GUID and account banks by world - and
-- the format number found. nil tables when there is no database yet or the
-- saved table is in another format.
-- repair: a save is coming, so whatever is not a table is replaced now;
-- without it a reader gets empty tables in their place and nothing is
-- written.
local function Store(repair)
    local global = LazyProf.db and LazyProf.db.global
    if type(global) ~= "table" then return nil, nil, nil end
    local stock = global.stock
    if type(stock) ~= "table" then
        if not repair then return {}, {}, SCHEMA end
        stock = {}
        global.stock = stock
    end
    if stock.schema == nil then
        if repair then stock.schema = SCHEMA end
    elseif stock.schema ~= SCHEMA then
        return nil, nil, stock.schema
    end
    local characters, account = stock.characters, stock.account
    if type(characters) ~= "table" then
        characters = {}
        if repair then stock.characters = characters end
    end
    if type(account) ~= "table" then
        account = {}
        if repair then stock.account = account end
    end
    return characters, account, SCHEMA
end

local function IsCount(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

-- A copy of an item table holding only what can be counted: item ids that
-- are numbers, with counts that are positive whole numbers.
local function Counts(items)
    local copy = {}
    if type(items) ~= "table" then return copy end
    for itemId, count in pairs(items) do
        if type(itemId) == "number" and IsCount(count) then
            copy[itemId] = count
        end
    end
    return copy
end

local function Text(value)
    return type(value) == "string" and value or nil
end

local function Time(value)
    return type(value) == "number" and value or nil
end

-- A saved part of a record (its bags or its bank) when it can be read: a
-- table with an items table. nil otherwise.
local function Part(record, key)
    local part = type(record) == "table" and record[key] or nil
    if type(part) ~= "table" or type(part.items) ~= "table" then return nil end
    return part
end

local function Snapshot(items, bound, now)
    local snapshot = { items = Counts(items), at = now }
    local boundCounts = Counts(bound)
    if next(boundCounts) then
        snapshot.bound = boundCounts
    end
    return snapshot
end

-- What of a saved part can be sent to another character: counts less their
-- soulbound part.
local function Sendable(part)
    local items = Counts(part.items)
    for itemId, boundCount in pairs(Counts(part.bound)) do
        local count = items[itemId]
        if count then
            items[itemId] = count > boundCount and (count - boundCount) or nil
        end
    end
    return items
end

local function Size(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- The character's record, made when missing (or when what is saved under its
-- GUID is not a table), with who it is brought up to date. A value that
-- could not be read this time keeps what was remembered.
local function Record(characters, identity, now)
    local record = characters[identity.guid]
    if type(record) ~= "table" then
        record = {}
        characters[identity.guid] = record
    end
    record.name = Text(identity.name) or Text(record.name)
    record.world = Text(identity.world) or Text(record.world)
    record.faction = Text(identity.faction) or Text(record.faction)
    if type(record.seen) ~= "number" or now > record.seen then
        record.seen = now
    end
    return record
end

local function Save(part, identity, items, bound, now, canSend)
    if not (type(identity) == "table" and identity.guid and type(items) == "table" and type(now) == "number") then
        return false
    end
    local characters = Store(true)
    if not characters then return false end
    local record = Record(characters, identity, now)
    record[part] = Snapshot(items, bound, now)
    record.noSend = (canSend == false) or nil
    return true
end

-- Remember a character's bags. items / bound: { [itemId] = count }.
-- canSend: false when the character cannot send anything to others
-- (Self-Found); its stock is then no alt stock for anyone. It is stored with
-- every save, so the caller passes the setting and this file reads none.
-- Returns whether anything was saved (never without a GUID or a time).
function StockMemory:SaveBags(identity, items, bound, now, canSend)
    return Save("bags", identity, items, bound, now, canSend)
end

-- Remember a character's bank.
function StockMemory:SaveBank(identity, items, bound, now, canSend)
    return Save("bank", identity, items, bound, now, canSend)
end

-- The character's setting changed between saves: note on its record whether
-- it can send. Returns whether there was a record to note it on.
function StockMemory:SetCanSend(guid, canSend)
    local characters = Store()
    local record = characters and guid ~= nil and characters[guid]
    if type(record) ~= "table" then return false end
    record.noSend = (canSend == false) or nil
    return true
end

-- Remember the account-wide bank of a world.
function StockMemory:SaveAccountBank(world, items, now)
    if not (type(world) == "string" and type(items) == "table" and type(now) == "number") then
        return false
    end
    local _, account = Store(true)
    if not account then return false end
    account[world] = { items = Counts(items), at = now }
    return true
end

-- A character's own bank as last seen: a copy of its items (soulbound ones
-- included) and the time. nil when it was never seen.
function StockMemory:OwnBank(guid)
    local characters = Store()
    local bank = characters and guid ~= nil and Part(characters[guid], "bank")
    if not bank then return nil end
    return Counts(bank.items), Time(bank.at)
end

-- The account-wide bank of a world as last seen: a copy of its items and the
-- time. nil when it was never seen.
function StockMemory:AccountBank(world)
    local _, account = Store()
    local bank = account and world ~= nil and account[world]
    if type(bank) ~= "table" or type(bank.items) ~= "table" then return nil end
    return Counts(bank.items), Time(bank.at)
end

-- Where each remembered character stands for the asking one:
--   { [guid] = "self"     the asking character itself
--            | "alt"      counted as an alt
--            | "world"    another world
--            | "faction"  another faction
--            | "nosend"   it cannot send anything (Self-Found)
--            | "noname"   its name was never readable: it could not be shown
--            | "name"     an older record under a name in use
--            | "unknown"  the asking character's world or faction is not known }
-- A name belongs to one character of a world: the record seen last under it
-- (of two seen at the same moment, the one whose id sorts first). That is
-- settled first, within the world, and only then is that one record asked
-- whether it is of the same faction and can send - so when the character of
-- a name cannot send or went over to the other faction, an older record of
-- its name never counts in its place. A record under the asking character's
-- own name is not an alt either (a character that is gone, or this one under
-- an older id). Entries that are not records have no standing.
local function Standing(characters, identity)
    local standing = {}
    if type(identity) ~= "table" then return standing end
    local known = identity.guid and identity.world and identity.faction
    local newest = {}   -- [name] = { guid, seen }: the record of the world seen last under that name
    local inWorld = {}  -- [guid] = record, the other records of the asking character's world
    for guid, record in pairs(characters) do
        if type(record) == "table" then
            if guid == identity.guid then
                standing[guid] = "self"
            elseif not known then
                standing[guid] = "unknown"
            elseif record.world ~= identity.world then
                standing[guid] = "world"
            else
                inWorld[guid] = record
                local name = Text(record.name)
                if name then
                    local seen = Time(record.seen) or 0
                    local other = newest[name]
                    if not other or seen > other.seen or (seen == other.seen and tostring(guid) < tostring(other.guid)) then
                        newest[name] = { guid = guid, seen = seen }
                    end
                end
            end
        end
    end
    for guid, record in pairs(inWorld) do
        local name = Text(record.name)
        if name and newest[name].guid ~= guid then
            standing[guid] = "name"
        elseif record.faction ~= identity.faction then
            standing[guid] = "faction"
        elseif record.noSend == true then
            standing[guid] = "nosend"
        elseif not name then
            standing[guid] = "noname"
        elseif name == identity.name then
            standing[guid] = "name"
        else
            standing[guid] = "alt"
        end
    end
    return standing
end

function StockMemory:Standing(identity)
    local characters = Store()
    if not characters then return {} end
    return Standing(characters, identity)
end

-- The other remembered characters of this character's world and faction, by
-- name: { { guid, name, bags, bagsAt, bank, bankAt }, ... } - those standing
-- as "alt" above. bags / bank are what could be sent over (soulbound counts
-- taken off); a part never seen is nil, and so is the time of a part that
-- has none.
function StockMemory:Alts(identity)
    local list = {}
    local characters = Store()
    if not characters then return list end
    for guid, standing in pairs(Standing(characters, identity)) do
        if standing == "alt" then
            local record = characters[guid]
            local alt = { guid = guid, name = record.name }
            local bags, bank = Part(record, "bags"), Part(record, "bank")
            if bags then
                alt.bags, alt.bagsAt = Sendable(bags), Time(bags.at)
            end
            if bank then
                alt.bank, alt.bankAt = Sendable(bank), Time(bank.at)
            end
            list[#list + 1] = alt
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- The saved table of characters itself, as a token: a caller that keeps
-- something worked out from the other characters can tell by it that the
-- whole saved table was replaced (a database reset). Not for reading. nil
-- while nothing is saved or the saved table is in another format.
function StockMemory:Token()
    local global = LazyProf.db and LazyProf.db.global
    local stock = type(global) == "table" and global.stock or nil
    if type(stock) ~= "table" or (stock.schema ~= nil and stock.schema ~= SCHEMA) then return nil end
    return type(stock.characters) == "table" and stock.characters or nil
end

-- Drop the characters not seen for KEEP_DAYS days (a deleted character must
-- not supply stock for ever) and whatever is saved in a record's place
-- without being one, and the account banks of worlds no remembered character
-- is left in. keepGuid: the character being played, whose entry is never
-- dropped. Returns how many entries were dropped.
function StockMemory:Prune(now, keepGuid)
    local characters, account = Store()
    if not characters or type(now) ~= "number" then return 0 end
    local dropped = 0
    local limit = self.KEEP_DAYS * DAY
    for guid, record in pairs(characters) do
        local seen = type(record) == "table" and Time(record.seen) or nil
        if guid ~= keepGuid and (not seen or now - seen > limit) then
            characters[guid] = nil
            dropped = dropped + 1
        end
    end
    local worlds = {}
    for _, record in pairs(characters) do
        if type(record) == "table" and Text(record.world) then
            worlds[record.world] = true
        end
    end
    for world in pairs(account) do
        if not worlds[world] then
            account[world] = nil
        end
    end
    return dropped
end

-- Forget everything remembered, for every character and world. Also what
-- puts a damaged saved table right again.
function StockMemory:Forget()
    local characters, account = Store(true)
    if not characters then return end
    for guid in pairs(characters) do characters[guid] = nil end
    for world in pairs(account) do account[world] = nil end
end

-- What is remembered, for the diagnostic:
--   { usable, schema, unreadable,
--     characters = { { guid, name, world, faction, seen, canSend, bagItems, bagsAt, bankItems, bankAt }, ... },
--     account = { { world, items, at }, ... } }
-- bagItems / bankItems count distinct items (nil for a part never seen).
-- usable is false when there is no database or the saved table is in another
-- format (schema then says which). unreadable counts the entries that are
-- not what this file writes and are skipped.
function StockMemory:Summary()
    local characters, account, schema = Store()
    local summary = { usable = characters ~= nil, schema = schema, unreadable = 0, characters = {}, account = {} }
    if not characters then return summary end
    for guid, record in pairs(characters) do
        if type(record) == "table" then
            local bags, bank = Part(record, "bags"), Part(record, "bank")
            summary.characters[#summary.characters + 1] = {
                guid = guid, name = Text(record.name), world = Text(record.world), faction = Text(record.faction),
                seen = Time(record.seen), canSend = record.noSend ~= true,
                bagItems = bags and Size(Counts(bags.items)) or nil, bagsAt = bags and Time(bags.at) or nil,
                bankItems = bank and Size(Counts(bank.items)) or nil, bankAt = bank and Time(bank.at) or nil,
            }
        else
            summary.unreadable = summary.unreadable + 1
        end
    end
    table.sort(summary.characters, function(a, b)
        local worldA, worldB = tostring(a.world), tostring(b.world)
        if worldA ~= worldB then return worldA < worldB end
        local nameA, nameB = tostring(a.name), tostring(b.name)
        if nameA ~= nameB then return nameA < nameB end
        return tostring(a.guid) < tostring(b.guid)
    end)
    for world, bank in pairs(account) do
        if type(bank) == "table" and type(bank.items) == "table" then
            summary.account[#summary.account + 1] = { world = world, items = Size(Counts(bank.items)), at = Time(bank.at) }
        else
            summary.unreadable = summary.unreadable + 1
        end
    end
    table.sort(summary.account, function(a, b) return tostring(a.world) < tostring(b.world) end)
    return summary
end

-- How long ago `at` was, seen from `now` (both server time in seconds), as
-- elapsed time: "less than an hour ago", "1 hour ago" / "N hours ago" up to
-- 23, then "1 day ago" / "N days ago" in whole 24-hour periods. Never
-- calendar days: twenty minutes that span a midnight are not "1 day". A time
-- ahead of the clock reads as less than an hour ago. nil without both times.
function StockMemory.AgeText(now, at)
    if type(now) ~= "number" or type(at) ~= "number" then return nil end
    local elapsed = now - at
    if elapsed < HOUR then
        return "less than an hour ago"
    end
    if elapsed < DAY then
        local hours = math.floor(elapsed / HOUR)
        return hours == 1 and "1 hour ago" or (tostring(hours) .. " hours ago")
    end
    local days = math.floor(elapsed / DAY)
    return days == 1 and "1 day ago" or (tostring(days) .. " days ago")
end
