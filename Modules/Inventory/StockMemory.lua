-- Modules/Inventory/StockMemory.lua
-- What each character had in its bags and its bank when LazyProf last saw
-- them, and the account-wide bank of each region. With it, bank and alt stock
-- count when no inventory addon is installed (Modules/Inventory/Scanner.lua
-- decides when it is used).
--
-- Saved account-wide (LazyProfDB.global.stock), one record per character GUID:
--   stock.schema                 format number of this table (1)
--   stock.characters[guid] = {
--       name, world, faction,    who it is; alts are the characters of the
--       region                   same world and faction
--       seen,                    time of its last save of either kind
--       noSend,                  true when it cannot send anything to other
--                                characters (Self-Found); absent otherwise
--       bags = { items = { [itemId] = count }, bound = { [itemId] = count }, at },
--       bank = { items = ..., bound = ..., at, doubt },
--       bagsAtBank = { items = { [itemId] = count }, banks = { character, account }, at },
--   }
--   stock.account[region] = { items = { [itemId] = count }, at, doubt, world, faction }
-- The account bank is remembered once per region (the region part of the
-- world: a world is a region and a ruleset). Whether the game's account bank
-- is shared by the whole account, per world or per faction is not known, so
-- the record keeps the world and the faction of the character whose read it
-- is, and it counts only for the characters of that world and faction (the
-- caller decides that by them); a read by a character of another world or
-- faction makes the copy that character's. That way it is never counted
-- where it may be another bank. An entry without its world and faction (an
-- older shape) is not read, and the next save of an account bank removes it.
-- `bound` holds how many of an item's count are soulbound (left out when
-- there are none): they stay in the owner's own bank, but another character
-- cannot be sent them. Times are server time in seconds. A save replaces the
-- table of the part it saves (`bags`, `bank` or `bagsAtBank`) and brings who
-- the character is up to date; the rest of the record stays, and nothing is
-- ever appended. Characters not seen for KEEP_DAYS days are dropped by Prune.
-- `doubt` is true on a bank the caller has reason to think is behind what is
-- really in it (MarkBankDoubt / MarkAccountBankDoubt; absent otherwise). The
-- bank stays remembered, but it is handed out with that mark, and an alt's
-- bank that carries it is not handed out at all. The next save of the bank
-- replaces its table and with it the mark. Read back, any value but nothing
-- and false is the mark: a saved table that was damaged must lean towards
-- not counting a bank, never towards counting one that was in doubt.
--
-- `bagsAtBank` is a note left by a session that ended at the bank (with its
-- window open or shortly after it closed): what the carried bags held at
-- that moment - `items` is absent when that could not be read - and which of
-- the two banks (`banks.character`, `banks.account`: true or absent) the
-- session's last visit could use. The answer of a move may arrive after a
-- session has ended; the character's next session compares its bags with the
-- note and takes it away (NoteBagsAtBank / BagsAtBank / ClearBagsAtBank; the
-- caller decides what follows from a difference).
--
-- The format number is written here and is deliberately not among the
-- database defaults: the database strips saved values that equal a default
-- and puts the default back on load, so a default would relabel old data the
-- day the format changes. A table in a format this file does not know is
-- neither read nor written over.
--
-- The saved table is read defensively: it may have been edited by hand, cut
-- off by a crash or written by a build with a defect. A record that is not a
-- table is skipped, as is a bags / bank part that is not one, an item id
-- that is not a number, a count that is not a positive whole number and a
-- name that is not text. Nothing negative is ever handed out, and what is
-- handed out is a copy. Reading changes nothing; the next save replaces what
-- was not a table. A damaged value leans towards counting less, never more:
-- `noSend`, `doubt` and a note's banks are set by any value but nothing and
-- false; a part whose `bound` is there but cannot be read (not a table, or
-- an entry that is no count of an item) is not offered to the other
-- characters at all; a time that is not a finite number is no time - a
-- record without a usable `seen` is no alt of anyone and is dropped by Prune;
-- and the time of a part, a bank or a note that is not a number greater
-- than zero and not later than one day after now is damaged (SoundTime): a
-- part or a bank with such a time is not counted, a note with one is taken
-- as not known.
--
-- This file is pure: who the character is, what it holds and what time it is
-- are passed in (the client adapter supplies them).
--   identity = { guid, name, world, faction, region }
local ADDON_NAME, LazyProf = ...

local StockMemory = {}
LazyProf.StockMemory = StockMemory

local SCHEMA = 1
local HOUR = 3600
local DAY = 86400
StockMemory.KEEP_DAYS = 180

-- The two saved tables - characters by GUID and account banks by region - and
-- the format number found. nil tables when there is no database yet or the
-- saved table is in another format.
-- repair: a save is coming, so whatever is not a table is replaced now;
-- without it a reader gets empty tables in their place and nothing is
-- written.
-- The fourth return says whether the characters were found as a table: an
-- empty table handed out in their place is not "no characters".
local function Store(repair)
    local global = LazyProf.db and LazyProf.db.global
    if type(global) ~= "table" then return nil, nil, nil, false end
    local stock = global.stock
    if type(stock) ~= "table" then
        if not repair then return {}, {}, SCHEMA, false end
        stock = {}
        global.stock = stock
    end
    if stock.schema == nil then
        if repair then stock.schema = SCHEMA end
    elseif stock.schema ~= SCHEMA then
        return nil, nil, stock.schema, false
    end
    local characters, account = stock.characters, stock.account
    local charactersFound = type(characters) == "table"
    if not charactersFound then
        characters = {}
        if repair then stock.characters = characters end
    end
    if type(account) ~= "table" then
        account = {}
        if repair then stock.account = account end
    end
    return characters, account, SCHEMA, charactersFound
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

-- A time: a number that has an end and can be compared. Not-a-number and
-- the infinite ones are no time (a record seen "infinitely late" would never
-- be dropped).
local function Time(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

-- A time read back that can be trusted: a number greater than zero and not
-- later than one day after `now` (the caller's server time). Anything else
-- is a damaged time - nothing, not a number, zero or below, or so far ahead
-- that no clock of this account wrote it - and leans towards not counting:
-- a part or a bank whose time is damaged is not handed out as stock (Alts;
-- the scanner does the same for the character's own banks), and a note
-- whose time is damaged is taken as not known (the scanner's rule 5c).
function StockMemory.SoundTime(value, now)
    return Time(value) ~= nil and value > 0 and type(now) == "number" and value <= now + DAY
end

-- A saved yes / no that must lean towards not counting when damaged: any
-- value but nothing and false is yes.
local function Set(value)
    return value ~= nil and value ~= false
end

-- A saved part of a record (its bags or its bank) when it can be read: a
-- table with an items table. nil otherwise.
local function Part(record, key)
    local part = type(record) == "table" and record[key] or nil
    if type(part) ~= "table" or type(part.items) ~= "table" then return nil end
    return part
end

-- Does a saved bank carry the doubt mark? Any value but nil and false does
-- (see `doubt` at the top of this file).
local function InDoubt(bank)
    return Set(bank.doubt)
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
-- soulbound part. nil when the soulbound part cannot be read - it is there
-- and not a table, or holds an entry that is not a count of an item: how
-- much of the part is soulbound is then not known, so none of it is offered.
local function Sendable(part)
    local bound = part.bound
    if bound ~= nil then
        if type(bound) ~= "table" then return nil end
        for itemId, count in pairs(bound) do
            if type(itemId) ~= "number" or not IsCount(count) then return nil end
        end
    end
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
    record.region = Text(identity.region) or Text(record.region)
    if not Time(record.seen) or now > record.seen then
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

-- The account bank remembered for a region, when it can be read: a table
-- with an items table and the world and faction of its reader. nil otherwise.
local function AccountEntry(account, region)
    local bank = region ~= nil and account[region] or nil
    if type(bank) ~= "table" or type(bank.items) ~= "table" or not Text(bank.world) or not Text(bank.faction) then
        return nil
    end
    return bank
end

-- Remember the account-wide bank as the character `identity` read it: under
-- its region, with its world and faction. Nothing is saved without all three.
-- Whatever could not be read among the account banks (an entry of an older
-- shape too) is removed with it.
function StockMemory:SaveAccountBank(identity, items, now)
    if not (type(identity) == "table" and Text(identity.region) and Text(identity.world) and Text(identity.faction)
            and type(items) == "table" and type(now) == "number") then
        return false
    end
    local _, account = Store(true)
    if not account then return false end
    for region in pairs(account) do
        if not AccountEntry(account, region) then account[region] = nil end
    end
    account[identity.region] = { items = Counts(items), at = now, world = identity.world, faction = identity.faction }
    return true
end

-- A character's own bank as last seen: a copy of its items (soulbound ones
-- included), the time, and whether it is in doubt (then it must not be
-- counted). nil when it was never seen.
function StockMemory:OwnBank(guid)
    local characters = Store()
    local bank = characters and guid ~= nil and Part(characters[guid], "bank")
    if not bank then return nil end
    return Counts(bank.items), Time(bank.at), InDoubt(bank)
end

-- The account-wide bank of a region as last seen: a copy of its items, the
-- time, whether it is in doubt, and the world and faction of the character
-- whose read it is (it counts only for that world and faction). nil when it
-- was never seen.
function StockMemory:AccountBank(region)
    local _, account = Store()
    local bank = account and AccountEntry(account, region)
    if not bank then return nil end
    return Counts(bank.items), Time(bank.at), InDoubt(bank), bank.world, bank.faction
end

-- Mark a character's remembered bank as in doubt: it is behind what is
-- really in the bank, as far as the caller can tell. Returns whether the
-- mark is new (false when no bank is remembered for it, or it is marked
-- already). The next save of that bank takes the mark away.
function StockMemory:MarkBankDoubt(guid)
    local characters = Store()
    local bank = characters and guid ~= nil and Part(characters[guid], "bank")
    if not bank or InDoubt(bank) then return false end
    bank.doubt = true
    return true
end

-- The same for the account-wide bank of a region, whoever's read it is.
function StockMemory:MarkAccountBankDoubt(region)
    local _, account = Store()
    local bank = account and AccountEntry(account, region)
    if not bank or InDoubt(bank) then return false end
    bank.doubt = true
    return true
end

-- Leave a note with the character's record: what its carried bags held when
-- its session ended at the bank. items: { [itemId] = count }, or nil when
-- they could not be read (the note then says that they are not known).
-- banks: { character = bool, account = bool }, the banks the note is about.
-- Returns whether it was written (never without a GUID, the banks or a
-- time). The record's bags and bank are not touched.
function StockMemory:NoteBagsAtBank(identity, items, banks, now)
    if not (type(identity) == "table" and identity.guid and type(banks) == "table" and type(now) == "number") then
        return false
    end
    if items ~= nil and type(items) ~= "table" then return false end
    local characters = Store(true)
    if not characters then return false end
    local record = Record(characters, identity, now)
    record.bagsAtBank = {
        items = items and Counts(items) or nil,
        banks = { character = banks.character and true or nil, account = banks.account and true or nil },
        at = now,
    }
    return true
end

-- The note a character's last session left, nil when there is none:
--   { known, items, character, account, at }
-- known: the bags' contents are known (items is then a copy of them; nil
-- otherwise). character / account: whether the note is about that bank. at:
-- when it was written (nil when that cannot be read). A note that is not
-- what this file writes counts as not known, for both banks. Reading changes
-- nothing.
function StockMemory:BagsAtBank(guid)
    local characters = Store()
    local record = characters and guid ~= nil and characters[guid]
    if type(record) ~= "table" or record.bagsAtBank == nil then return nil end
    local note = record.bagsAtBank
    if type(note) ~= "table" or type(note.banks) ~= "table" or (note.items ~= nil and type(note.items) ~= "table") then
        return { known = false, character = true, account = true }
    end
    return {
        known = note.items ~= nil,
        items = note.items ~= nil and Counts(note.items) or nil,
        character = Set(note.banks.character),
        account = Set(note.banks.account),
        at = Time(note.at),
    }
end

-- Take that note away. Returns whether there was one.
function StockMemory:ClearBagsAtBank(guid)
    local characters = Store()
    local record = characters and guid ~= nil and characters[guid]
    if type(record) ~= "table" or record.bagsAtBank == nil then return false end
    record.bagsAtBank = nil
    return true
end

-- Where each remembered character stands for the asking one:
--   { [guid] = "self"     the asking character itself
--            | "alt"      counted as an alt
--            | "world"    another world
--            | "faction"  another faction
--            | "nosend"   it cannot send anything (Self-Found)
--            | "noname"   its name was never readable: it could not be shown
--            | "name"     an older record under a name in use
--            | "unseen"   it has no usable time of its last save
--            | "unknown"  the asking character's world or faction is not known }
-- A name belongs to one character of a world: the record seen last under it
-- (of two seen at the same moment, the one whose id sorts first). That is
-- settled first, within the world, and only then is that one record asked
-- whether it is of the same faction and can send - so when the character of
-- a name cannot send or went over to the other faction, an older record of
-- its name never counts in its place. A record under the asking character's
-- own name is not an alt either (a character that is gone, or this one under
-- an older id). A record without a usable time of its last save takes part in
-- none of that: how old it is cannot be told, and Prune drops it. Entries that
-- are not records have no standing.
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
            elseif not Time(record.seen) then
                standing[guid] = "unseen"
            elseif record.world ~= identity.world then
                standing[guid] = "world"
            else
                inWorld[guid] = record
                local name = Text(record.name)
                if name then
                    local seen = Time(record.seen)
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
        elseif Set(record.noSend) then
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
-- name: { { guid, name, bags, bagsAt, bank, bankAt, bankDoubt }, ... } -
-- those standing as "alt" above. bags / bank are what could be sent over
-- (soulbound counts taken off); a part never seen is nil, and so is a part
-- whose soulbound share cannot be read (see Sendable) or whose time is
-- damaged (see SoundTime; now: the caller's server time), with its time. A
-- bank in doubt, or with a damaged time, is not handed out: bankDoubt is
-- then true and bank / bankAt are nil, while the bags still count.
function StockMemory:Alts(identity, now)
    local list = {}
    local characters = Store()
    if not characters then return list end
    for guid, standing in pairs(Standing(characters, identity)) do
        if standing == "alt" then
            local record = characters[guid]
            local alt = { guid = guid, name = record.name }
            local bags, bank = Part(record, "bags"), Part(record, "bank")
            local sendable = bags and StockMemory.SoundTime(bags.at, now) and Sendable(bags)
            if sendable then
                alt.bags, alt.bagsAt = sendable, bags.at
            end
            if bank and (InDoubt(bank) or not StockMemory.SoundTime(bank.at, now)) then
                alt.bankDoubt = true
            elseif bank then
                sendable = Sendable(bank)
                if sendable then
                    alt.bank, alt.bankAt = sendable, bank.at
                end
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
-- without being one, and the account banks of regions no remembered
-- character is of. keepGuid: the character being played, whose entry is
-- never dropped. Returns how many entries were dropped.
-- An account bank goes only when it is known that nobody is of its region:
-- when the characters could not be read (they are not a table, or what is
-- left of them holds an entry without a readable region) none is dropped.
function StockMemory:Prune(now, keepGuid)
    local characters, account, _, charactersFound = Store()
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
    if not charactersFound then return dropped end
    local regions = {}
    for _, record in pairs(characters) do
        local region = type(record) == "table" and Text(record.region) or nil
        if not region then return dropped end
        regions[region] = true
    end
    for region in pairs(account) do
        if not regions[region] then
            account[region] = nil
        end
    end
    return dropped
end

-- Forget everything remembered, for every character and region. Also what
-- puts a damaged saved table right again.
function StockMemory:Forget()
    local characters, account = Store(true)
    if not characters then return end
    for guid in pairs(characters) do characters[guid] = nil end
    for region in pairs(account) do account[region] = nil end
end

-- What is remembered, for the diagnostic (now: the caller's server time):
--   { usable, schema, unreadable,
--     characters = { { guid, name, world, faction, seen, canSend, bagItems, bagsAt, bagsDamaged,
--                      bankItems, bankAt, bankDoubt, bankDamaged }, ... },
--     account = { { region, world, faction, items, at, doubt, damaged }, ... } }
-- bagItems / bankItems count distinct items (nil for a part never seen);
-- bankDoubt / doubt say whether that bank is marked in doubt, bagsDamaged /
-- bankDamaged / damaged whether the time of a part that was seen is damaged
-- (see SoundTime: it is then not counted); an account bank's world and
-- faction are those of the character whose read it is.
-- usable is false when there is no database or the saved table is in another
-- format (schema then says which). unreadable counts the entries that are
-- not what this file writes and are skipped.
function StockMemory:Summary(now)
    local characters, account, schema = Store()
    local summary = { usable = characters ~= nil, schema = schema, unreadable = 0, characters = {}, account = {} }
    if not characters then return summary end
    for guid, record in pairs(characters) do
        if type(record) == "table" then
            local bags, bank = Part(record, "bags"), Part(record, "bank")
            summary.characters[#summary.characters + 1] = {
                guid = guid, name = Text(record.name), world = Text(record.world), faction = Text(record.faction),
                seen = Time(record.seen), canSend = not Set(record.noSend),
                bagItems = bags and Size(Counts(bags.items)) or nil, bagsAt = bags and Time(bags.at) or nil,
                bagsDamaged = (bags and not StockMemory.SoundTime(bags.at, now)) or false,
                bankItems = bank and Size(Counts(bank.items)) or nil, bankAt = bank and Time(bank.at) or nil,
                bankDoubt = (bank and InDoubt(bank)) or false,
                bankDamaged = (bank and not StockMemory.SoundTime(bank.at, now)) or false,
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
    for region in pairs(account) do
        local bank = AccountEntry(account, region)
        if bank then
            summary.account[#summary.account + 1] = { region = region, world = bank.world, faction = bank.faction,
                                                      items = Size(Counts(bank.items)), at = Time(bank.at), doubt = InDoubt(bank),
                                                      damaged = not StockMemory.SoundTime(bank.at, now) }
        else
            summary.unreadable = summary.unreadable + 1
        end
    end
    table.sort(summary.account, function(a, b) return tostring(a.region) < tostring(b.region) end)
    return summary
end

-- How long ago `at` was, seen from `now` (both server time in seconds), as
-- elapsed time: "less than an hour ago", "1 hour ago" / "N hours ago" up to
-- 23, then "1 day ago" / "N days ago" in whole 24-hour periods. Never
-- calendar days: twenty minutes that span a midnight are not "1 day". A time
-- ahead of the clock reads as less than an hour ago. nil without both times,
-- and nil when the time between them is no time at all: a saved time that is
-- a number but cannot be compared (not-a-number) or has no end would
-- otherwise read "nan days ago" or "inf days ago".
function StockMemory.AgeText(now, at)
    if type(now) ~= "number" or type(at) ~= "number" then return nil end
    local elapsed = now - at
    if elapsed ~= elapsed or elapsed == math.huge or elapsed == -math.huge then return nil end
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
