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

-- The saved table, or nil when there is no database yet or the table is in
-- another format. The second return is the format number found.
local function Store()
    local global = LazyProf.db and LazyProf.db.global
    if not global then return nil, nil end
    if type(global.stock) ~= "table" then
        global.stock = {}
    end
    local stock = global.stock
    if stock.schema == nil then
        stock.schema = SCHEMA
    end
    if stock.schema ~= SCHEMA then
        return nil, stock.schema
    end
    stock.characters = stock.characters or {}
    stock.account = stock.account or {}
    return stock, SCHEMA
end

-- A copy holding only the positive counts.
local function Counts(items)
    local copy = {}
    for itemId, count in pairs(items or {}) do
        if type(count) == "number" and count > 0 then
            copy[itemId] = count
        end
    end
    return copy
end

local function Snapshot(items, bound, now)
    local snapshot = { items = Counts(items), at = now }
    local boundCounts = Counts(bound)
    if next(boundCounts) then
        snapshot.bound = boundCounts
    end
    return snapshot
end

-- What of a snapshot can be sent to another character: counts less their
-- soulbound part.
local function Sendable(snapshot)
    local items = {}
    local bound = snapshot.bound or {}
    for itemId, count in pairs(snapshot.items or {}) do
        local free = count - (bound[itemId] or 0)
        if free > 0 then
            items[itemId] = free
        end
    end
    return items
end

local function Size(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- The character's record, made when missing, with who it is brought up to
-- date. A value that could not be read this time keeps what was remembered.
local function Record(stock, identity, now)
    local record = stock.characters[identity.guid]
    if not record then
        record = {}
        stock.characters[identity.guid] = record
    end
    record.name = identity.name or record.name
    record.world = identity.world or record.world
    record.faction = identity.faction or record.faction
    if type(record.seen) ~= "number" or now > record.seen then
        record.seen = now
    end
    return record
end

local function Save(part, identity, items, bound, now)
    if not (identity and identity.guid and type(items) == "table" and type(now) == "number") then
        return false
    end
    local stock = Store()
    if not stock then return false end
    Record(stock, identity, now)[part] = Snapshot(items, bound, now)
    return true
end

-- Remember a character's bags. items / bound: { [itemId] = count }.
-- Returns whether anything was saved (never without a GUID or a time).
function StockMemory:SaveBags(identity, items, bound, now)
    return Save("bags", identity, items, bound, now)
end

-- Remember a character's bank.
function StockMemory:SaveBank(identity, items, bound, now)
    return Save("bank", identity, items, bound, now)
end

-- Remember the account-wide bank of a world.
function StockMemory:SaveAccountBank(world, items, now)
    if not (world and type(items) == "table" and type(now) == "number") then
        return false
    end
    local stock = Store()
    if not stock then return false end
    stock.account[world] = { items = Counts(items), at = now }
    return true
end

-- A character's own bank as last seen: items (soulbound ones included) and
-- the time. nil when it was never seen. The items table is the saved one:
-- read it, do not change it.
function StockMemory:OwnBank(guid)
    local stock = Store()
    local record = stock and guid and stock.characters[guid]
    local bank = record and record.bank
    if not bank then return nil end
    return bank.items, bank.at
end

-- The account-wide bank of a world as last seen: items (the saved table, as
-- above) and the time. nil when it was never seen.
function StockMemory:AccountBank(world)
    local stock = Store()
    local bank = stock and world and stock.account[world]
    if not bank then return nil end
    return bank.items, bank.at
end

-- The other remembered characters of this character's world and faction, by
-- name: { { guid, name, bags, bagsAt, bank, bankAt }, ... }. bags / bank are
-- what could be sent over (soulbound counts taken off); a part never seen is
-- nil.
-- A name belongs to one character of a world, so a record under the asking
-- character's own name is not an alt (it is a character that is gone, or
-- this one under an older id), and of several records under one name only
-- the one seen last counts. A record whose name was never readable is left
-- out: it could not be shown.
function StockMemory:Alts(identity)
    local list = {}
    local stock = Store()
    if not (stock and identity and identity.guid and identity.world and identity.faction) then
        return list
    end
    local byName = {}
    for guid, record in pairs(stock.characters) do
        local name = record.name
        if guid ~= identity.guid and name and name ~= identity.name
                and record.world == identity.world and record.faction == identity.faction then
            local seen = record.seen or 0
            local other = byName[name]
            if not other or seen > other.seen or (seen == other.seen and guid < other.guid) then
                byName[name] = { guid = guid, seen = seen, record = record }
            end
        end
    end
    for name, entry in pairs(byName) do
        local record = entry.record
        local alt = { guid = entry.guid, name = name }
        if record.bags then
            alt.bags, alt.bagsAt = Sendable(record.bags), record.bags.at
        end
        if record.bank then
            alt.bank, alt.bankAt = Sendable(record.bank), record.bank.at
        end
        list[#list + 1] = alt
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Drop the characters not seen for KEEP_DAYS days (a deleted character must
-- not supply stock for ever), and the account banks of worlds no remembered
-- character is left in. keepGuid: the character being played, which is never
-- dropped. Returns how many characters were dropped.
function StockMemory:Prune(now, keepGuid)
    local stock = Store()
    if not stock or type(now) ~= "number" then return 0 end
    local dropped = 0
    local limit = self.KEEP_DAYS * DAY
    for guid, record in pairs(stock.characters) do
        if guid ~= keepGuid and (type(record.seen) ~= "number" or now - record.seen > limit) then
            stock.characters[guid] = nil
            dropped = dropped + 1
        end
    end
    local worlds = {}
    for _, record in pairs(stock.characters) do
        if record.world then worlds[record.world] = true end
    end
    for world in pairs(stock.account) do
        if not worlds[world] then
            stock.account[world] = nil
        end
    end
    return dropped
end

-- Forget everything remembered, for every character and world.
function StockMemory:Forget()
    local stock = Store()
    if not stock then return end
    stock.characters = {}
    stock.account = {}
end

-- What is remembered, for the diagnostic:
--   { usable, schema,
--     characters = { { guid, name, world, faction, seen, bagItems, bagsAt, bankItems, bankAt }, ... },
--     account = { { world, items, at }, ... } }
-- bagItems / bankItems count distinct items (nil for a part never seen).
-- usable is false when there is no database or the saved table is in another
-- format (schema then says which).
function StockMemory:Summary()
    local stock, schema = Store()
    local summary = { usable = stock ~= nil, schema = schema, characters = {}, account = {} }
    if not stock then return summary end
    for guid, record in pairs(stock.characters) do
        summary.characters[#summary.characters + 1] = {
            guid = guid, name = record.name, world = record.world, faction = record.faction, seen = record.seen,
            bagItems = record.bags and Size(record.bags.items) or nil, bagsAt = record.bags and record.bags.at or nil,
            bankItems = record.bank and Size(record.bank.items) or nil, bankAt = record.bank and record.bank.at or nil,
        }
    end
    table.sort(summary.characters, function(a, b)
        local worldA, worldB = tostring(a.world), tostring(b.world)
        if worldA ~= worldB then return worldA < worldB end
        local nameA, nameB = tostring(a.name), tostring(b.name)
        if nameA ~= nameB then return nameA < nameB end
        return tostring(a.guid) < tostring(b.guid)
    end)
    for world, bank in pairs(stock.account) do
        summary.account[#summary.account + 1] = { world = world, items = Size(bank.items), at = bank.at }
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
