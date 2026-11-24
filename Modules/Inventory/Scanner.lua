-- Modules/Inventory/Scanner.lua
-- Which owned stock counts: for the route, every total and the shopping list.
--
-- The bags are always read live (through the client adapter). Stock outside
-- them comes from one of two places:
--   - the Syndicator addon, when it is installed: bank, mail, own auctions,
--     alts, guild bank. LazyProf's own memory is then neither read nor
--     written.
--   - otherwise LazyProf's own memory (StockMemory.lua): the character's bank
--     and the account bank as last read with the bank window open, and the
--     bags and banks of the other characters of the same world and faction.
--     This file keeps that memory up to date.
-- A Self-Found character cannot be sent anything, so nothing that belongs to
-- other characters is counted for it, from either place (alts, the account
-- bank, the guild bank); and it cannot send anything, so the memory does not
-- offer what it holds to the others.
--
-- The memory can never stop the addon: everything that touches it runs
-- protected (see Protected), and a scan that cannot read it counts the bags.
-- The first failure of a session is handed to the game's error handler.
--
-- THE BAGS are remembered BAG_SAVE_DELAY (2 s) after a bag update - one save
-- for a burst of updates - and, when a save is still waiting, at logout. Bags
-- that report no backpack slots could not be read and are not saved. Bags
-- that read as completely empty are saved only when a bag update came before
-- the read: at login and at logout nothing says the client has the bags'
-- contents, and slots without items would otherwise replace the snapshot
-- with nothing.
--
-- THE BANK (the character's and the account's; WoW Forever only) is read only
-- while its window is open, and never by a scan: a scan counts what is
-- remembered. What is remembered of a bank is either what a read that can be
-- trusted saw, or it is marked IN DOUBT and not counted until the next
-- visit. It is never replaced by "nothing" on weak evidence, and never
-- counted while there is reason to think it is behind.
-- Not known about the client, and so not assumed either way: whether the bank
-- can still be read inside the close notice; whether the bag updates of a
-- last move can arrive after the window closed; whether the client empties
-- the bank's containers (keeping their slots) and sends bag updates before
-- the close notice; whether the items are all there the moment the window
-- opens.
--
-- 1. When the bank is read.
--    - At once when the window opens, again BANK_SETTLE (0.5 s) after the
--      opening whatever the first read gave, and BANK_EMPTY_TRUST (2 s)
--      after the opening when a read before that mark was refused or found a
--      bank empty without being believed.
--    - On a bag update (of any container: an item may have gone into the
--      bank or come out of it) or a change of the bank's tabs: at once when
--      the last read is BANK_READ_SPACING (0.2 s) or more ago. Otherwise the
--      read is owed, and one trailing read is taken 0.2 s after the last
--      read.
--    - When the client says that a batch of bag updates is complete
--      (BAG_UPDATE_DELAYED): an owed read is taken at once when the last
--      read was taken in this very frame (it came before the batch was
--      complete) or is 0.2 s old. On a later frame within the 0.2 s the
--      trailing read stays in charge, so a burst that runs over many frames
--      is not read in every one of them.
--    Reading both banks in full costs about a millisecond and leaves a table
--    per slot behind; the 0.2 s between reads is what bounds that.
-- 2. Which read is kept, bank by bank.
--    - Refused by the adapter: not kept.
--    - With items: kept.
--    - Without a single item while nothing with items is remembered for that
--      bank: kept 2 s or more after the opening ("seen, nothing in it").
--    - Without a single item while items are remembered: believed only when
--      (a) this visit already kept a read with items of the same slot count,
--      or it is 2 s or more after the opening, and (b) an earlier read of
--      this visit, taken on an earlier frame, found the bank empty too.
--      Until then the empty read is unresolved and one more read is taken:
--      the trailing read when only (b) is missing, else the look at 2 s.
--    A kept read replaces what is remembered and takes a doubt mark away.
-- 3. When a bank is behind. The carried bags "changed since the last kept
--    read" of a bank when a bag update of a container that is no bank
--    container arrived in the frame of that read or later - so the order of
--    a move's two updates inside one frame does not matter, and only a read
--    kept on a later frame clears it. An update is "unanswered" for a bank
--    until a read has seen that bank again: a read that is still owed has
--    not, and neither has one the adapter refused. A bank that was usable
--    at some read of this visit (see "Which banks a visit can mark" below)
--    is BEHIND while an update is unanswered for it or its empty read is
--    unresolved, and the carried bags changed since its last kept read.
--    While the window is open a scan leaves a bank that is behind out (it
--    says so in its third return); the next read that sees the bank brings
--    it back.
-- 4. The close: the adapter's closing notice, which comes while the bank
--    still counts as open, and likewise a logout with the bank open. When a
--    read is owed, an update is unanswered or an empty read is unresolved,
--    the bank is read once more, and a bank is kept from that read only when
--    the read is not refused, holds at least one item and has the slot count
--    of the last read kept in this visit. A bank that is still behind after
--    that - or that was not kept although a read was owed and the carried
--    bags changed - is marked in doubt.
-- 5. After the close. The carried bags' contents (item -> count) are noted
--    at the closing notice. A bag update in the CLOSE_WATCH (1 s) after it,
--    whatever container it names, has them compared with the note - on the
--    next frame, or by a scan that comes first. When a count differs, the
--    answer of a last move arrived late: the banks of the visit are marked
--    in doubt. An update that changes no count marks nothing (the
--    client may only be letting go of the bank), nor does anything later
--    than the second, or a session without a close. Updates of bank
--    containers that arrive while the bank is closed are counted for
--    /lp diag stock.
-- Which banks a visit can mark (rules 4 and 5): only a bank that was USABLE
--    at some moment of it - the adapter says so (window open, the bank may
--    be viewed, is not locked, has a tab), and it is asked at every read of
--    the visit, the closing one included. A bank that never was (one this
--    character may not view, say) cannot have been changed through the
--    visit: it is neither behind nor marked, whatever is moved in the other
--    one. And a mark is only ever set on a bank of which something is
--    remembered.
-- 6. In doubt is a mark saved with the remembered bank (StockMemory.lua). A
--    bank that carries it is not counted by any scan - not for its own
--    character, not as an alt's bank (the alt's bags still count), not as
--    the account bank - and the scan's third return says so; the Shopping
--    tab shows a line for it. The next kept read of that bank takes the mark
--    away.
local ADDON_NAME, LazyProf = ...

LazyProf.Inventory = {}
local Inventory = LazyProf.Inventory

-- ============================================================================
-- Layer 1: Source Providers
-- Each returns {[itemId] = count}
-- ============================================================================

-- The bags the character carries, read by the client adapter (which bags
-- there are and how a slot is read differ per client). After the items the
-- adapter's other two returns follow: the soulbound part of them, and the
-- backpack's slot count (zero: the bags could not be read just now).
function Inventory:ScanBags()
    return LazyProf.Client:BagContents()
end

-- Scan bags from Syndicator character data (for alts)
function Inventory:ScanBagsSyndicator(charData)
    local items = {}
    if not charData or not charData.bags then return items end

    for _, bag in ipairs(charData.bags) do
        if bag then
            for _, slot in ipairs(bag) do
                if slot and slot.itemID then
                    items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                end
            end
        end
    end

    return items
end

-- Scan bank via Syndicator character data
function Inventory:ScanBank(charData)
    local items = {}
    if not charData then return items end

    -- Legacy bank bags
    if charData.bank then
        for _, bag in ipairs(charData.bank) do
            if bag then
                for _, slot in ipairs(bag) do
                    if slot and slot.itemID then
                        items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                    end
                end
            end
        end
    end

    -- Modern bank tabs
    if charData.bankTabs then
        for _, tab in ipairs(charData.bankTabs) do
            if tab and tab.slots then
                for _, slot in ipairs(tab.slots) do
                    if slot and slot.itemID then
                        items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                    end
                end
            end
        end
    end

    return items
end

-- Scan mail from Syndicator character data
function Inventory:ScanMail(charData)
    local items = {}
    if not charData or not charData.mail then return items end

    for _, mailItem in ipairs(charData.mail) do
        if mailItem and mailItem.itemID then
            items[mailItem.itemID] = (items[mailItem.itemID] or 0) + (mailItem.itemCount or 1)
        end
    end

    return items
end

-- Scan active auctions from Syndicator character data
function Inventory:ScanAuctions(charData)
    local items = {}
    if not charData or not charData.auctions then return items end

    for _, auction in ipairs(charData.auctions) do
        if auction and auction.itemID then
            items[auction.itemID] = (items[auction.itemID] or 0) + (auction.itemCount or 1)
        end
    end

    return items
end

-- Scan guild bank via Syndicator API
function Inventory:ScanGuildBank()
    local items = {}
    if not Syndicator or not Syndicator.API then return items end

    local guildName = Syndicator.API.GetCurrentGuild()
    if not guildName then return items end

    local guildData = Syndicator.API.GetByGuildFullName(guildName)
    if not guildData or not guildData.bank then return items end

    for _, tab in ipairs(guildData.bank) do
        if tab and tab.isViewable and tab.slots then
            for _, slot in ipairs(tab.slots) do
                if slot and slot.itemID then
                    items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                end
            end
        end
    end

    return items
end

-- ============================================================================
-- Layer 2: Aggregator
-- Orchestrates which sources to scan based on config, merges results
-- ============================================================================

-- Per-character sources scanned via Syndicator charData
local PER_CHAR_SOURCES = {
    { key = "bank",     configKey = "includeBankItems" },
    { key = "mail",     configKey = nil },  -- always on
    { key = "auctions", configKey = nil },  -- always on
}

-- Merge items from a source into combined inventory and sourceBreakdown
local function mergeSource(items, sourceKey, charName, combined, breakdown)
    for itemId, count in pairs(items) do
        combined[itemId] = (combined[itemId] or 0) + count

        if not breakdown[itemId] then
            breakdown[itemId] = {}
        end

        if charName then
            -- Alt character source
            if not breakdown[itemId].alts then
                breakdown[itemId].alts = {}
            end
            if not breakdown[itemId].alts[charName] then
                breakdown[itemId].alts[charName] = {}
            end
            breakdown[itemId].alts[charName][sourceKey] = (breakdown[itemId].alts[charName][sourceKey] or 0) + count
        else
            -- Current character or global source
            breakdown[itemId][sourceKey] = (breakdown[itemId][sourceKey] or 0) + count
        end
    end
end

-- Is the Syndicator addon there to read stock from?
function Inventory:UsesSyndicator()
    return (Syndicator and Syndicator.API) and true or false
end

-- A Self-Found character can neither be sent anything nor send anything:
-- nothing of the other characters is counted for it, and what it holds is
-- not offered to them (every save of its stock says so).
local function IsSelfFound()
    local char = LazyProf.db and LazyProf.db.char
    return (char and char.selfFoundMode) and true or false
end

-- The memory must never stop the addon: a damaged saved table or a client
-- call that fails would otherwise break login or every scan. Its entry
-- points therefore run protected. A failure is not hidden: the first one of
-- a session is handed to the game's error handler, so the player's error
-- display shows it once (the debug log gets it too, but drops it while
-- debugging is off); every one is counted, and /lp diag stock prints the
-- last one, where it happened, how many there were and whether a scan right
-- now is whole.
local memoryErrors = { count = 0, last = nil, where = nil }

-- Hand a message to the game's error handler. geterrorhandler() returns it
-- (a global of the WoW Forever client: Ketho BlizzardInterfaceResources,
-- forever branch, Resources/GlobalAPI.lua:6884; Blizzard's UI source of that
-- client calls it the same way, Interface/AddOns/Blizzard_SharedXMLBase/
-- ErrorUtil.lua:3 and :18-19). A client without it, or a handler that fails
-- itself, changes nothing here.
local function ShowError(message)
    if type(geterrorhandler) ~= "function" then return end
    local found, handler = pcall(geterrorhandler)
    if found and type(handler) == "function" then
        pcall(handler, message)
    end
end

local function NoteMemoryError(where, err)
    memoryErrors.count = memoryErrors.count + 1
    memoryErrors.last = tostring(err)
    memoryErrors.where = where
    if memoryErrors.count == 1 then
        local message = "LazyProf: its memory of your stock failed (" .. where .. "): " .. tostring(err)
        LazyProf:Debug("pathfinder", message)
        ShowError(message .. " - bank and alt stock may be missing from the lists; /lp diag stock says more.")
    end
end

-- Run fn(...) protected. Returns whether it ran through, then its first result.
local function Protected(where, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        NoteMemoryError(where, result)
        return false, nil
    end
    return true, result
end

-- Defined with the bank's rules further down ("Keeping the memory").
local BankBehind        -- is the open bank of that kind behind right now (rule 3)?
local SettleAfterClose  -- the comparison due after a bag update that followed a close (rule 5)

-- Frame-level cache: ScanAll is called many times per frame (once per recipe in
-- GetCandidates). Cache results so only the first call per frame does real work.
local scanCache = { time = 0, combined = nil, breakdown = nil, meta = nil }

-- Stock from Syndicator: the character's bank, mail and auctions, the alts,
-- the guild bank (the last two not for a Self-Found character).
local function AddSyndicatorStock(self, combined, breakdown, countAlts)
    local charName = Syndicator.API.GetCurrentCharacter()
    local charData = charName and Syndicator.API.GetByCharacterFullName(charName)

    if charData then
        for _, source in ipairs(PER_CHAR_SOURCES) do
            if not source.configKey or LazyProf.db.profile[source.configKey] then
                local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                local items = self[scanMethod](self, charData)
                mergeSource(items, source.key, nil, combined, breakdown)

                local count = 0
                for _ in pairs(items) do count = count + 1 end
                LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in %s", count, source.key))
            else
                LazyProf:Debug("pathfinder", "Inventory scan: " .. source.key .. " disabled")
            end
        end
    end

    -- Alt characters (if enabled, and the character can be sent things)
    if countAlts then
        local currentChar = Syndicator.API.GetCurrentCharacter()
        local allChars = Syndicator.API.GetAllCharacters()
        local totalAltItems = 0

        if allChars then
            for _, altName in ipairs(allChars) do
                if altName ~= currentChar then
                    local altData = Syndicator.API.GetByCharacterFullName(altName)
                    if altData then
                        -- Bags
                        local altBags = self:ScanBagsSyndicator(altData)
                        mergeSource(altBags, "bags", altName, combined, breakdown)

                        -- Bank, mail, auctions (respecting config for bank)
                        for _, source in ipairs(PER_CHAR_SOURCES) do
                            if not source.configKey or LazyProf.db.profile[source.configKey] then
                                local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                                local items = self[scanMethod](self, altData)
                                mergeSource(items, source.key, altName, combined, breakdown)
                            end
                        end

                        for itemId in pairs(altBags) do totalAltItems = totalAltItems + 1 end
                    end
                end
            end
        end

        LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items from alts", totalAltItems))
    else
        LazyProf:Debug("pathfinder", "Inventory scan: alts not counted")
    end

    -- Guild bank (if enabled). It is other characters' stock as well: a
    -- Self-Found character, which cannot be handed anything, does not count it.
    if LazyProf.db.profile.includeGuildBank and not IsSelfFound() then
        local guildItems = self:ScanGuildBank()
        mergeSource(guildItems, "guildBank", nil, combined, breakdown)

        local guildCount = 0
        for _ in pairs(guildItems) do guildCount = guildCount + 1 end
        LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in guild bank", guildCount))
    else
        LazyProf:Debug("pathfinder", "Inventory scan: guild bank disabled")
    end
end

-- The alts' part of a scan, kept between scans. Building it copies every
-- alt's stock, and the light refresh scans up to three times a second while
-- crafting. It depends on who the character is (its id, and the world and
-- faction it is of right now - the world is read again at every ask and can
-- differ from the one read at login), on whether banks count and on the other
-- characters' saved records - so it is kept under those and built again when
-- any of them differs, when the saved table was replaced as a whole, and when
-- the other characters changed (Forget, and dropping old ones at the start).
-- What the character itself saves does not touch it. Its tables are handed to
-- every scan as they are: read them, do not change them.
--   { guid, world, faction, countBank, token,
--     totals  = { [itemId] = count over all alts },
--     sources = { [itemId] = { [name] = { bags, bank } } },
--     seen    = { [name] = { bags = time, bank = time } } }
local altsPart = nil

local function BuildAltsPart(identity, countBank)
    local part = { guid = identity.guid, world = identity.world, faction = identity.faction, countBank = countBank,
                   totals = {}, sources = {}, seen = {} }
    local where = {}
    for _, alt in ipairs(LazyProf.StockMemory:Alts(identity)) do
        local seen = {}
        if alt.bags then
            mergeSource(alt.bags, "bags", alt.name, part.totals, where)
            seen.bags = alt.bagsAt
        end
        if countBank and alt.bank then
            mergeSource(alt.bank, "bank", alt.name, part.totals, where)
            seen.bank = alt.bankAt
        end
        part.seen[alt.name] = seen
    end
    for itemId, entry in pairs(where) do
        part.sources[itemId] = entry.alts
    end
    return part
end

-- The alts' part for this character and setting: the kept one, or a new one.
local function AltsPart(identity, countBank)
    local token = LazyProf.StockMemory:Token()
    local part = altsPart
    if part and token ~= nil and part.token == token and part.guid == identity.guid
            and part.world == identity.world and part.faction == identity.faction and part.countBank == countBank then
        return part
    end
    part = BuildAltsPart(identity, countBank)
    part.token = token
    -- Kept only once the character is fully known: before that nothing is
    -- an alt, and that answer must not stick.
    local known = identity.guid and identity.name and identity.world and identity.faction
    altsPart = (token ~= nil and known) and part or nil
    return part
end

-- The other characters' saved records changed: build the alts' part anew.
function Inventory:ForgetAltsPart()
    altsPart = nil
end

-- Stock from LazyProf's own memory. Returns how old each part is:
--   { remembered = true,
--     bankSeenAt     when the character's bank was seen (nil: never, or not counted)
--     accountSeenAt  when the account bank of its world was seen
--     bankInDoubt    true when the character's bank is remembered but in doubt
--     accountInDoubt true when the account bank of its world is
--     bankPending    true when the character's bank is left out because it
--                    is open and behind: a read is on its way
--     accountPending the same for the account bank
--     alts = { [name] = { bags = time, bank = time } } }   the alts counted
-- The character's own bank and the account bank are both bank stock (the
-- account bank is other characters' stock too, so a character that cannot
-- receive anything does not count it). An alt's bank needs both settings.
-- A bank in doubt (rule 6 at the top of this file) is not counted: not the
-- character's own, not the account bank, and not an alt's (its bags still
-- are). Nor is the open bank while it is behind (rule 3). The marks are only
-- set for a bank that would count otherwise. Nothing is read from the client
-- here and nothing is written.
local function AddRememberedStock(self, combined, breakdown, countAlts)
    local Memory, Client = LazyProf.StockMemory, LazyProf.Client
    local countBank = LazyProf.db.profile.includeBankItems and true or false
    local identity = Client:CharacterIdentity() or {}
    local meta = { remembered = true, alts = {} }

    if countBank then
        local items, seenAt, doubt = Memory:OwnBank(identity.guid)
        if items and doubt then
            meta.bankInDoubt = true
        elseif items and BankBehind("character") then
            meta.bankPending = true
        elseif items then
            mergeSource(items, "bank", nil, combined, breakdown)
            meta.bankSeenAt = seenAt
        end
        if not IsSelfFound() then
            items, seenAt, doubt = Memory:AccountBank(identity.world)
            if items and doubt then
                meta.accountInDoubt = true
            elseif items and BankBehind("account") then
                meta.accountPending = true
            elseif items then
                mergeSource(items, "bank", nil, combined, breakdown)
                meta.accountSeenAt = seenAt
            end
        end
    end

    if countAlts then
        local part = AltsPart(identity, countBank)
        for itemId, count in pairs(part.totals) do
            combined[itemId] = (combined[itemId] or 0) + count
            local entry = breakdown[itemId]
            if not entry then
                entry = {}
                breakdown[itemId] = entry
            end
            entry.alts = part.sources[itemId]
        end
        meta.alts = part.seen
    end
    return meta
end

-- The memory's part of a scan. A comparison that is due after a close (rule
-- 5) is made first, with the bags the scan has just read - so that no scan
-- counts a bank beside the items that have just come out of it. The bank
-- itself is never read here.
local function ScanMemory(self, combined, breakdown, countAlts, bagItems, backpackSlots)
    if backpackSlots and backpackSlots > 0 then
        SettleAfterClose(bagItems)
    end
    return AddRememberedStock(self, combined, breakdown, countAlts)
end

-- Scan all inventory sources based on settings
-- Returns: combinedInventory, sourceBreakdown, meta
--   combinedInventory  { [itemId] = count } over every source that counts
--   sourceBreakdown    { [itemId] = { bags, bank, mail, auctions, guildBank,
--                        alts = { [name] = { bags, bank, mail, auctions } } } }
--   meta               how old the remembered parts are (AddRememberedStock);
--                      nil when the stock comes from Syndicator
function Inventory:ScanAll()
    -- Return cached results if called again in the same frame, unless a
    -- setting that decides which stock counts has changed since
    local now = GetTime()
    local profile = LazyProf.db.profile
    local countBank = profile.includeBankItems and true or false
    local wantAlts = profile.includeAltCharacters and true or false
    local countGuild = profile.includeGuildBank and true or false
    local selfFound = IsSelfFound()
    if scanCache.combined and scanCache.time == now and scanCache.countBank == countBank
            and scanCache.wantAlts == wantAlts and scanCache.countGuild == countGuild
            and scanCache.selfFound == selfFound then
        return scanCache.combined, scanCache.breakdown, scanCache.meta
    end

    local combined = {}
    local breakdown = {}
    local meta = nil

    -- 1. Current character bags (read live, always on)
    local bagItems, _, backpackSlots = self:ScanBags()
    mergeSource(bagItems, "bags", nil, combined, breakdown)

    local bagCount = 0
    for _ in pairs(bagItems) do bagCount = bagCount + 1 end
    LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in bags", bagCount))

    -- 2. Everything outside the bags
    local countAlts = wantAlts and not selfFound
    if self:UsesSyndicator() then
        AddSyndicatorStock(self, combined, breakdown, countAlts)
    else
        local ok, result = Protected("scan", ScanMemory, self, combined, breakdown, countAlts, bagItems, backpackSlots)
        if ok then
            meta = result
        else
            -- The memory could not be read: count what is carried, nothing else.
            combined, breakdown = {}, {}
            mergeSource(bagItems, "bags", nil, combined, breakdown)
            meta = { remembered = true, alts = {} }
        end
    end

    scanCache.time = now
    scanCache.combined = combined
    scanCache.breakdown = breakdown
    scanCache.meta = meta
    scanCache.countBank, scanCache.wantAlts = countBank, wantAlts
    scanCache.countGuild, scanCache.selfFound = countGuild, selfFound

    return combined, breakdown, meta
end

-- Forget this frame's scan: what the character itself holds has changed.
local function InvalidateFrame()
    scanCache.time = 0
    scanCache.combined = nil
    scanCache.breakdown = nil
    scanCache.meta = nil
end

-- Invalidate the ScanAll cache (call when inventory or a stock setting
-- changes mid-frame). The alts' part is not dropped by this: it is kept under
-- what it depends on (see AltsPart).
function Inventory:InvalidateCache()
    InvalidateFrame()
end

-- ============================================================================
-- Keeping the memory
-- Nothing here plans the path again; a change of what is remembered only
-- asks the shown list to redraw. With Syndicator installed none of it does
-- anything. The rules are at the top of this file.
-- ============================================================================

local BAG_SAVE_DELAY = 2
local BANK_SETTLE = 0.5         -- the second look, this long after the opening
local BANK_EMPTY_TRUST = 2      -- an empty bank is not believed earlier after the opening
local BANK_READ_SPACING = 0.2   -- least time between two reads that changes ask for
local CLOSE_WATCH = 1           -- how long after the close a late answer is watched for
local CLOCK_SLACK = 0.001       -- a timer may run a hair before its mark
local BANK_KINDS = { "character", "account" }

-- First-wins debounces on a pending flag (C_Timer.After returns nothing).
local bagSavePending = false
local bagUpdateSeen = false     -- a bag update asked for the waiting save

-- The bank visit in progress, or the last one (kept for /lp diag stock):
--   openedAt, closedAt   GetTime() of the opening and of the close
--   lastReadAt           GetTime() of the last read; GetTime() is the same
--                        all through a frame, so it also names the frame
--   reads                how many reads were taken
--   owed                 an update arrived after the last read
--   confirm              an empty read waits for its second look
--   trailingPending      the trailing read's timer is waiting
--   lookPending[mark]    the look `mark` seconds after the opening is waiting
--   bagsUpdateAt         frame of the last update of a carried bag
--   closing              what the closing notice did (see CloseVisit)
--   character, account   per bank:
--     slots      slot count of the last read kept
--     keptItems  a read with items was kept
--     keptAt     frame of the last read kept
--     emptyAt    frame of the first empty read not believed yet (unresolved)
--     usable     the adapter called the bank usable at some read of this visit
--     unread     an update arrived that no read has seen the bank after
--     kept       how many reads were kept
--     last       what the last read gave, in words
local visit = nil
local bankClosedAt = nil        -- GetTime() of the last close
-- Bank containers' updates that arrived while the bank was closed.
local closedBankUpdates = { count = 0, lastAfter = nil }
-- The watch after a close (rule 5):
--   at, guid, world   when the window closed, and whose banks the visit read
--   usable[kind]      the bank was usable in the visit: it can be marked
--   note              the carried bags' contents at the closing notice
--   updates           bag updates that arrived inside the watch
--   carried           one of them named a carried bag
--   owed, pending     a comparison is due; its timer is waiting
--   compared          how many comparisons were made
--   changed           a count differed: the banks were marked in doubt
local watch = nil

-- Remember what the character carries. trustEmpty: a bag update came before
-- this read, so bags without a single item are really empty. Returns whether
-- it was saved.
function Inventory:SaveBags(trustEmpty)
    if self:UsesSyndicator() then return false end
    local Client = LazyProf.Client
    local items, bound, backpackSlots = Client:BagContents()
    if not backpackSlots or backpackSlots <= 0 then
        return false   -- the bags could not be read just now
    end
    if not trustEmpty and next(items) == nil then
        return false   -- slots but no items, and nothing says they are loaded
    end
    return LazyProf.StockMemory:SaveBags(Client:CharacterIdentity(), items, bound, Client:Now(), not IsSelfFound())
end

-- fromUpdate: asked for by a bag update (see SaveBags).
function Inventory:RequestBagSave(fromUpdate)
    if self:UsesSyndicator() then return end
    if fromUpdate then
        bagUpdateSeen = true
    end
    if bagSavePending then return end
    bagSavePending = true
    C_Timer.After(BAG_SAVE_DELAY, function()
        if not bagSavePending then return end   -- written at logout meanwhile
        bagSavePending = false
        local trustEmpty = bagUpdateSeen
        bagUpdateSeen = false
        Protected("bag save", Inventory.SaveBags, Inventory, trustEmpty)
    end)
end

-- The bank -------------------------------------------------------------------

local function NewVisit()
    local v = { openedAt = GetTime(), reads = 0, owed = false, confirm = false, trailingPending = false, lookPending = {} }
    for _, kind in ipairs(BANK_KINDS) do
        v[kind] = { kept = 0, keptItems = false, usable = false, unread = false }
    end
    return v
end

-- The visit in progress; nil while the bank is closed. A bank that counts as
-- open without its opening having been reported begins a visit here.
local function OpenVisit()
    if not LazyProf.Client:IsBankOpen() then return nil end
    if not visit or visit.closedAt then
        visit = NewVisit()
    end
    return visit
end

-- Rule 3. The carried bags changed since that bank's last kept read: an
-- update of a carried bag arrived in the frame of that read or later.
local function BagsChangedSince(v, state)
    return v.bagsUpdateAt ~= nil and (state.keptAt == nil or v.bagsUpdateAt >= state.keptAt)
end

-- That bank is behind: what is remembered of it may not be what is in it,
-- while the bags that are counted live have changed.
local function Behind(v, state)
    return state.usable and (state.unread or state.emptyAt ~= nil) and BagsChangedSince(v, state)
end

-- For a scan: is the open bank of that kind behind right now?
BankBehind = function(kind)
    local v = visit
    if not v or v.closedAt or v.closing then return false end
    return Behind(v, v[kind])
end

-- Does the memory hold items for that bank?
local function RemembersItems(kind, identity)
    local Memory = LazyProf.StockMemory
    local items
    if kind == "character" then
        items = Memory:OwnBank(identity.guid)
    else
        items = Memory:AccountBank(identity.world)
    end
    return items ~= nil and next(items) ~= nil
end

local function SaveBank(kind, identity, items, bound, now)
    if kind == "character" then
        return LazyProf.StockMemory:SaveBank(identity, items, bound, now, not IsSelfFound())
    end
    return LazyProf.StockMemory:SaveAccountBank(identity.world, items, now)
end

-- Mark the remembered bank of that kind in doubt. Returns whether that
-- changed what is remembered (there is such a bank, and it was not marked).
local function MarkDoubt(kind, guid, world)
    if kind == "character" then
        return LazyProf.StockMemory:MarkBankDoubt(guid)
    end
    return LazyProf.StockMemory:MarkAccountBankDoubt(world)
end

-- One read of the open bank, both kinds, keeping what rule 2 allows (rule 4
-- for the read at the closing notice: `closing`, which also has the kinds it
-- kept noted in keptNow). Returns whether what is remembered changed, and
-- whether a kind was refused or found empty without being believed before
-- the two-second mark (the look at that mark is then wanted).
-- Whether a bank is behind may be different after any read, so the frame's
-- scan is dropped first.
local function ReadBank(v, closing, keptNow)
    local Client = LazyProf.Client
    InvalidateFrame()
    local identity = Client:CharacterIdentity() or {}
    local now, frame = Client:Now(), GetTime()
    local late = frame - v.openedAt >= BANK_EMPTY_TRUST - CLOCK_SLACK
    v.lastReadAt = frame
    v.reads = v.reads + 1
    v.owed = false
    v.confirm = false
    local changed, lookWanted = false, false
    for _, kind in ipairs(BANK_KINDS) do
        local state = v[kind]
        -- Asked at every read: usable once is enough for the visit.
        if Client:BankUsable(kind) then
            state.usable = true
        end
        local items, bound, slots = Client:BankContents(kind)
        local keep = false
        if not items then
            state.last = "refused"
            lookWanted = lookWanted or not late
        elseif next(items) ~= nil then
            keep = not closing or (state.slots ~= nil and slots == state.slots)
            state.last = keep and "items" or "items, another slot count"
        elseif closing then
            -- Never believed from this read: the client may have let go of
            -- the bank already. It makes no empty read unresolved either.
            state.last = "empty"
        else
            local remembered = RemembersItems(kind, identity)
            local sameBank = state.keptItems and state.slots == slots
            if not remembered then
                keep = late
            else
                keep = (late or sameBank) and state.emptyAt ~= nil and state.emptyAt < frame
            end
            if keep then
                state.last = "empty, believed"
            else
                -- Seen, if not believed: the update it follows is answered,
                -- and the bank is unresolved from here on.
                state.last = "empty, not believed"
                state.emptyAt = state.emptyAt or frame
                state.unread = false
                lookWanted = lookWanted or not late
                -- Only the second look is missing: it comes with the trailing read.
                if remembered and (late or sameBank) then
                    v.confirm = true
                end
            end
        end
        if keep then
            if SaveBank(kind, identity, items, bound, now) then
                state.slots = slots
                state.keptAt = frame
                state.emptyAt = nil
                state.unread = false
                state.kept = state.kept + 1
                if next(items) ~= nil then
                    state.keptItems = true
                end
                if keptNow then
                    keptNow[kind] = true
                end
                changed = true
            else
                state.last = state.last .. ", not saved"
            end
        end
    end
    return changed, lookWanted
end

local LookAtBank

-- The look `mark` seconds after this visit's opening; one per mark is waiting
-- at most. A visit that is over by then is not looked at.
local function ScheduleLook(v, mark)
    if v.lookPending[mark] then return end
    v.lookPending[mark] = true
    C_Timer.After(math.max(0, v.openedAt + mark - GetTime()), function()
        v.lookPending[mark] = nil
        if visit ~= v or v.closedAt then return end
        Protected("bank read", LookAtBank, Inventory)
    end)
end

-- The trailing read: BANK_READ_SPACING after the last read, when a read is
-- owed or an empty read waits for its second look by then. One is waiting at
-- most; a read taken meanwhile moves it on.
local function ScheduleTrailing(v)
    if v.trailingPending then return end
    v.trailingPending = true
    local function fire()
        if visit ~= v or v.closedAt then
            v.trailingPending = false
            return
        end
        local wait = (v.lastReadAt or 0) + BANK_READ_SPACING - GetTime()
        if wait > CLOCK_SLACK then
            C_Timer.After(wait, fire)
            return
        end
        v.trailingPending = false
        if v.owed or v.confirm then
            Protected("bank read", LookAtBank, Inventory)
        end
    end
    C_Timer.After(math.max(0, (v.lastReadAt or GetTime()) + BANK_READ_SPACING - GetTime()), fire)
end

-- Read the open bank now and ask for what the read leaves open: the look at
-- the two-second mark, the second look at an empty bank. A shown list is
-- asked to redraw when the read changed what is remembered. Returns whether
-- it did.
LookAtBank = function(self)
    local v = OpenVisit()
    if not v then return false end
    local changed, lookWanted = ReadBank(v, false)
    if lookWanted then
        ScheduleLook(v, BANK_EMPTY_TRUST)
    end
    if v.confirm then
        ScheduleTrailing(v)
    end
    if changed and LazyProf.ScheduleShoppingListRefresh then
        LazyProf:ScheduleShoppingListRefresh()
    end
    return changed
end

-- Something changed while the bank is open (a bag update, a change of its
-- tabs): read it now when the last read is long enough ago, else the read is
-- owed and the trailing read takes it.
function Inventory:OnBankChange()
    if self:UsesSyndicator() then return end
    local v = OpenVisit()
    if not v then return end
    -- Unanswered for both banks until a read has seen them again; whether a
    -- bank is behind may change with that, so the frame's scan is dropped.
    v.character.unread, v.account.unread = true, true
    InvalidateFrame()
    if v.lastReadAt == nil or GetTime() - v.lastReadAt >= BANK_READ_SPACING - CLOCK_SLACK then
        LookAtBank(self)
    else
        v.owed = true
        ScheduleTrailing(v)
    end
end

function Inventory:OnBankOpened()
    if self:UsesSyndicator() then return end
    -- A comparison still due from the last close is made before its watch ends.
    if watch and watch.owed then
        Protected("bank close", SettleAfterClose)
    end
    watch = nil
    visit = NewVisit()
    Protected("bank read", LookAtBank, self)
    ScheduleLook(visit, BANK_SETTLE)
end

local function SameCounts(a, b)
    for itemId, count in pairs(a) do
        if b[itemId] ~= count then return false end
    end
    for itemId in pairs(b) do
        if a[itemId] == nil then return false end
    end
    return true
end

-- Rule 4, at the adapter's closing notice and at a logout with the bank
-- open; once per visit. visit.closing says afterwards what was done:
--   owed, unanswered, unresolved   what the visit still had open
--   read               the bank was read once more
--   kept[kind]         that read was kept for the kind
--   doubt[kind]        the kind was still behind: marked in doubt
-- It also takes the note of the carried bags for the watch after the close.
local function CloseVisit(self)
    local v = OpenVisit()
    if not v or v.closing then return end
    local Client = LazyProf.Client
    local done = { owed = v.owed, unanswered = false, unresolved = false, read = false, kept = {}, doubt = {} }
    v.closing = done
    for _, kind in ipairs(BANK_KINDS) do
        local state = v[kind]
        if state.emptyAt ~= nil then
            done.unresolved = true
        end
        if state.usable and state.unread then
            done.unanswered = true
        end
    end
    local changed = false
    if done.owed or done.unanswered or done.unresolved then
        -- Protected on its own: a read that fails is a read that kept
        -- nothing, and what follows must still be done.
        done.read = true
        local _, kept = Protected("bank close", ReadBank, v, true, done.kept)
        changed = kept and true or false
    end
    local identity = Client:CharacterIdentity() or {}
    for _, kind in ipairs(BANK_KINDS) do
        local state = v[kind]
        if not done.kept[kind] and state.usable and (Behind(v, state) or (done.owed and BagsChangedSince(v, state))) then
            done.doubt[kind] = true
            if MarkDoubt(kind, identity.guid, identity.world) then
                changed = true
            end
        end
    end
    local items, _, backpackSlots = Client:BagContents()
    watch = {
        at = GetTime(), guid = identity.guid, world = identity.world,
        usable = { character = v.character.usable, account = v.account.usable },
        note = (backpackSlots and backpackSlots > 0) and items or nil,
        updates = 0, compared = 0, owed = false, pending = false,
    }
    if changed then
        InvalidateFrame()
        if LazyProf.ScheduleShoppingListRefresh then
            LazyProf:ScheduleShoppingListRefresh()
        end
    end
end

-- The window is closing and the bank still counts as open.
function Inventory:OnBankClosing()
    if self:UsesSyndicator() then return end
    Protected("bank close", CloseVisit, self)
end

-- The bank counts as closed now: nothing is read any more.
function Inventory:OnBankClosed()
    bankClosedAt = GetTime()
    if visit and not visit.closedAt then
        visit.closedAt = bankClosedAt
        visit.owed = false
    end
end

-- Rule 5: the comparison that is due after an update inside the watch.
-- bagItems: the carried bags, when the caller has just read them (a scan);
-- otherwise they are read here. A read that cannot be trusted (no backpack
-- slots) decides nothing and leaves the comparison due. Returns whether a
-- bank was marked.
SettleAfterClose = function(bagItems)
    local w = watch
    if not w or not w.owed then return false end
    local items = bagItems
    if not items then
        local read, _, backpackSlots = LazyProf.Client:BagContents()
        if not backpackSlots or backpackSlots <= 0 then return false end
        items = read
    end
    w.owed = false
    w.compared = w.compared + 1
    local differs
    if w.note then
        differs = not SameCounts(w.note, items)
    else
        -- No note could be taken at the close: an update of a carried bag
        -- is then all there is to go by.
        differs = w.carried == true
    end
    if not differs then return false end
    w.changed = true
    local marked = false
    for _, kind in ipairs(BANK_KINDS) do
        if w.usable[kind] and MarkDoubt(kind, w.guid, w.world) then
            marked = true
        end
    end
    if marked then
        InvalidateFrame()
        if LazyProf.ScheduleShoppingListRefresh then
            LazyProf:ScheduleShoppingListRefresh()
        end
    end
    return marked
end

-- A bag update while the bank is closed: inside the watch after a close it
-- asks for the comparison - on the next frame (one timer, a pending flag),
-- or by a scan that comes first.
local function WatchUpdate(carried)
    local w = watch
    if not w or w.changed then return end
    if GetTime() - w.at > CLOSE_WATCH + CLOCK_SLACK then return end
    w.updates = w.updates + 1
    if carried then
        w.carried = true
    end
    w.owed = true
    InvalidateFrame()
    if w.pending then return end
    w.pending = true
    C_Timer.After(0, function()
        w.pending = false
        if watch == w then
            Protected("bank close", SettleAfterClose)
        end
    end)
end

local function BagUpdated(self, bagId)
    local Client = LazyProf.Client
    local bankKind = Client:BankKindOfBag(bagId)
    local v = OpenVisit()
    if v then
        if not bankKind then
            v.bagsUpdateAt = GetTime()
        end
        self:OnBankChange()
    else
        if bankKind then
            -- It cannot be read now. Counted, so that one dump shows whether
            -- the client reports bank changes after the window closed.
            closedBankUpdates.count = closedBankUpdates.count + 1
            closedBankUpdates.lastAfter = bankClosedAt and (GetTime() - bankClosedAt) or nil
        end
        WatchUpdate(not bankKind)
    end
    if not bankKind then
        self:RequestBagSave(true)
    end
end

-- A bag update (Core/Init.lua passes every BAG_UPDATE on with its container
-- id). While the bank is open the bank is read again (rule 1); an update of
-- a bank container is not a change of the bags.
function Inventory:OnBagUpdate(bagId)
    if self:UsesSyndicator() then return end
    Protected("bag update", BagUpdated, self, bagId)
end

local function BatchComplete(self)
    local v = OpenVisit()
    if not v or not v.owed then return end
    local frame = GetTime()
    if v.lastReadAt == nil or v.lastReadAt == frame or frame - v.lastReadAt >= BANK_READ_SPACING - CLOCK_SLACK then
        LookAtBank(self)
    end
end

-- The client says a batch of bag updates is complete (Core/Init.lua passes
-- BAG_UPDATE_DELAYED on): a read owed for this frame's updates is taken now.
function Inventory:OnBagUpdateDelayed()
    if self:UsesSyndicator() then return end
    Protected("bag update", BatchComplete, self)
end

-- Logout (the client's event, and the database's own shutdown notice, which
-- is sure to come before the saved tables are tidied; either may come first
-- and both may come). With the bank still open the visit ends as at a close.
-- Then a bag save that is still waiting is written.
function Inventory:OnLogout()
    if self:UsesSyndicator() then return end
    if visit and not visit.closedAt and not visit.closing then
        Protected("logout", CloseVisit, self)
    end
    if not bagSavePending then return end
    bagSavePending = false
    bagUpdateSeen = false
    Protected("logout", self.SaveBags, self, false)
end

-- Start listening (called once the addon is enabled). Characters not seen
-- for a long time are dropped here - never the one being played - and the
-- character is remembered shortly after login even if its bags never change.
-- Nothing in here can stop the addon from starting.
function Inventory:Initialize()
    Protected("start", function()
        LazyProf.Client:StartStock({
            onBankOpened = function() Inventory:OnBankOpened() end,
            onBankChanged = function() Protected("bank read", Inventory.OnBankChange, Inventory) end,
            onBankClosing = function() Inventory:OnBankClosing() end,
            onBankClosed = function() Inventory:OnBankClosed() end,
            onLogout = function() Inventory:OnLogout() end,
        })
    end)
    if self:UsesSyndicator() then return end
    Protected("start", function()
        local Client = LazyProf.Client
        local identity = Client:CharacterIdentity() or {}
        if identity.guid then
            LazyProf.StockMemory:Prune(Client:Now(), identity.guid)
        end
    end)
    self:ForgetAltsPart()
    self:RequestBagSave()
end

-- The Self-Found setting changed: what is remembered of this character says
-- from now on whether it can send (its alts read that), and the next scan
-- starts afresh.
function Inventory:OnSendingChanged()
    self:InvalidateCache()
    if self:UsesSyndicator() then return end
    Protected("setting", function()
        local identity = LazyProf.Client:CharacterIdentity() or {}
        LazyProf.StockMemory:SetCanSend(identity.guid, not IsSelfFound())
    end)
end

-- Every setting went back to its default (the options' reset; what is
-- remembered was kept through it, see LazyProf:ResetSettings): nothing a scan
-- kept may answer any more, and the character's record says again whether it
-- can send, as the setting stands now.
function Inventory:OnSettingsReset()
    self:ForgetAltsPart()
    self:OnSendingChanged()
end

-- Forget every remembered character and account bank (the options button).
-- The character being played is remembered again by itself: its bags with
-- the next save, and its bank at once when the bank window is open.
function Inventory:ForgetRemembered()
    LazyProf.StockMemory:Forget()
    self:InvalidateCache()
    self:ForgetAltsPart()
    watch = nil
    Protected("bank read", LookAtBank, self)
    self:RequestBagSave()
end

-- /lp diag stock: where stock outside the bags comes from, who the character
-- is, what the current or the last bank visit did and what is remembered.
-- Read-only (an open bank is neither read nor saved by it).
function Inventory:RunDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local Memory, Client = LazyProf.StockMemory, LazyProf.Client
    local profile = LazyProf.db.profile

    if self:UsesSyndicator() then
        add("source: Syndicator (LazyProf's own memory is not used and not updated)")
    else
        add("source: LazyProf's own memory (no inventory addon)")
    end
    add("settings: bank=" .. tostring(profile.includeBankItems) .. " alts=" .. tostring(profile.includeAltCharacters)
        .. " guildBank=" .. tostring(profile.includeGuildBank) .. " selfFound=" .. tostring(IsSelfFound()))

    if memoryErrors.count > 0 then
        add("last error: " .. tostring(memoryErrors.last) .. " (in: " .. tostring(memoryErrors.where) .. "; "
            .. tostring(memoryErrors.count) .. " this session; the first was handed to the game's error display)")
    end
    -- What a scan does right now: tried here, on tables that are thrown
    -- away, so that a failure long over does not read as stock left out.
    if not self:UsesSyndicator() then
        local whole, err = pcall(AddRememberedStock, self, {}, {}, profile.includeAltCharacters and not IsSelfFound())
        if whole then
            add("scan now: whole - bank and alt stock are counted from the memory")
        else
            add("scan now: bags only - the memory cannot be read: " .. tostring(err))
        end
    end

    -- Who the character is may be the very call that fails: the rest of the
    -- dump is still worth having.
    local identityRead, identity = pcall(Client.CharacterIdentity, Client)
    if not identityRead then
        add("identity: could not be read: " .. tostring(identity))
        identity = {}
    end
    identity = identity or {}
    local now = Client:Now()
    add("identity: guid=" .. tostring(identity.guid) .. " name=" .. tostring(identity.name)
        .. " world=" .. tostring(identity.world) .. " faction=" .. tostring(identity.faction))
    if not identity.world then
        add("world: unknown - alts and the account bank are not counted")
    end
    if not identity.faction then
        add("faction: unknown - alts are not counted")
    end
    local v = visit
    local bankReadWaiting = v ~= nil and not v.closedAt
        and (v.owed or v.confirm or v.trailingPending or next(v.lookPending) ~= nil) or false
    add("waiting: bagSave=" .. tostring(bagSavePending) .. " bankRead=" .. tostring(bankReadWaiting)
        .. " bankOpen=" .. tostring(Client:IsBankOpen()))
    -- The bank visit in progress or the last one: which rules fired.
    if not v then
        add("bank visit: none this session")
    else
        local frame = GetTime()
        local head
        if v.closedAt then
            head = string.format("bank visit: closed %.1f s ago after %.1f s", frame - v.closedAt, v.closedAt - v.openedAt)
        else
            head = string.format("bank visit: open for %.1f s", frame - v.openedAt)
        end
        add(head .. "; reads=" .. tostring(v.reads) .. " owed=" .. tostring(v.owed)
            .. " carriedBagsUpdated=" .. tostring(v.bagsUpdateAt ~= nil))
        for _, kind in ipairs(BANK_KINDS) do
            local state = v[kind]
            add("bank visit " .. kind .. ": usable=" .. tostring(state.usable) .. " kept=" .. tostring(state.kept)
                .. " lastRead=" .. tostring(state.last or "none")
                .. " slots=" .. tostring(state.slots) .. " unresolvedEmpty=" .. tostring(state.emptyAt ~= nil)
                .. " unansweredUpdate=" .. tostring(state.usable and state.unread)
                .. " bagsChangedSinceKept=" .. tostring(BagsChangedSince(v, state)))
        end
        local done = v.closing
        if done then
            local function names(set)
                local list = {}
                for _, kind in ipairs(BANK_KINDS) do
                    if set[kind] then list[#list + 1] = kind end
                end
                return #list > 0 and table.concat(list, ",") or "none"
            end
            add("bank visit close: owed=" .. tostring(done.owed) .. " unansweredUpdate=" .. tostring(done.unanswered)
                .. " unresolvedEmpty=" .. tostring(done.unresolved)
                .. " readAgain=" .. tostring(done.read) .. " kept=" .. names(done.kept)
                .. " markedInDoubt=" .. names(done.doubt))
        end
    end
    if watch then
        add("after the close: bagUpdates=" .. tostring(watch.updates) .. " compared=" .. tostring(watch.compared)
            .. " carriedBagsChanged=" .. tostring(watch.changed == true)
            .. (watch.changed and " (the remembered banks were marked in doubt)" or ""))
    end
    -- Whether the client reports bank changes after the window closed (they
    -- cannot be read then, so the remembered bank misses them).
    local closedLine = "bank updates while closed: " .. tostring(closedBankUpdates.count)
    if closedBankUpdates.count > 0 then
        if closedBankUpdates.lastAfter then
            closedLine = closedLine .. string.format(", last %.1f s after closing", closedBankUpdates.lastAfter)
        else
            closedLine = closedLine .. ", before the bank was opened this session"
        end
    end
    add(closedLine)

    local summary = Memory:Summary()
    if not summary.usable then
        add("memory: format=" .. tostring(summary.schema) .. " - not a format this version reads; it is left alone")
        return
    end
    add("memory: format=" .. tostring(summary.schema) .. " characters=" .. tostring(#summary.characters)
        .. " accountBanks=" .. tostring(#summary.account)
        .. " (characters not seen for " .. tostring(Memory.KEEP_DAYS) .. " days are dropped)")
    if summary.unreadable > 0 then
        add("memory: unreadable=" .. tostring(summary.unreadable)
            .. " (saved entries that are not what LazyProf writes; they are skipped, and Forget remembered characters removes them)")
    end

    -- What happens to each character's stock, and why.
    local STANDING = {
        self = "this character",
        world = "other world",
        faction = "other faction",
        nosend = "not counted (Self-Found)",
        noname = "not counted (no name)",
        name = "not counted (an older record of this name)",
        unknown = "not counted (this character's world or faction is unknown)",
    }
    local standing = Memory:Standing(identity)
    local usesSyndicator = self:UsesSyndicator()
    local function part(label, items, at, doubt)
        if items == nil then return label .. "=never seen" end
        return label .. "=" .. tostring(items) .. " items (" .. tostring(Memory.AgeText(now, at) or "no time")
            .. (doubt and ", in doubt: not counted" or "") .. ")"
    end
    for _, c in ipairs(summary.characters) do
        local label = STANDING[standing[c.guid]]
        if usesSyndicator then
            -- Left over from a time without it: listed, but nothing of it counts.
            label = "remembered, not used (Syndicator is installed)"
        elseif standing[c.guid] == "alt" then
            if IsSelfFound() then
                label = "not counted (this character is Self-Found)"
            elseif not profile.includeAltCharacters then
                label = "alt, not counted (alts off)"
            elseif not profile.includeBankItems then
                label = "alt, counted (bags only: bank items are off)"
            else
                label = "alt, counted"
            end
        end
        add("character: " .. tostring(c.name) .. " [" .. tostring(label) .. "] world=" .. tostring(c.world)
            .. " faction=" .. tostring(c.faction) .. " " .. part("bags", c.bagItems, c.bagsAt)
            .. " " .. part("bank", c.bankItems, c.bankAt, c.bankDoubt) .. " guid=" .. tostring(c.guid))
    end
    for _, bank in ipairs(summary.account) do
        add("account bank: world=" .. tostring(bank.world) .. " items=" .. tostring(bank.items)
            .. " (" .. tostring(Memory.AgeText(now, bank.at) or "no time") .. (bank.doubt and ", in doubt: not counted" or "") .. ")")
    end
end

-- ============================================================================
-- Utility methods
-- ============================================================================

-- Get count of specific item in bags
function Inventory:GetItemCount(itemId)
    local items = self:ScanBags()
    return items[itemId] or 0
end

-- Check if we have enough materials for a recipe
function Inventory:HasMaterials(recipe, inventory)
    inventory = inventory or self:ScanBags()

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        if have < reagent.count then
            return false
        end
    end
    return true
end

-- Get missing materials for a recipe (quantity needed - quantity owned)
function Inventory:GetMissingMaterials(recipe, quantity, inventory)
    inventory = inventory or self:ScanBags()
    local missing = {}

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        local need = reagent.count * quantity
        local short = math.max(0, need - have)

        if short > 0 then
            table.insert(missing, {
                itemId = reagent.itemId,
                have = have,
                need = need,
                missing = short,
            })
        end
    end

    return missing
end
