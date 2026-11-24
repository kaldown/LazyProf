-- Modules/Inventory/Scanner.lua
-- Which owned stock counts: for the route, every total and the shopping list.
--
-- The bags are always read live (through the client adapter). Stock outside
-- them comes from one of two places:
--   - the Syndicator addon, when it is installed: bank, mail, own auctions,
--     alts, guild bank. Nothing below changes that, and LazyProf's own memory
--     is then neither read nor written.
--   - otherwise LazyProf's own memory (StockMemory.lua): the character's bank
--     and the account bank as last seen with the bank window open, and the
--     bags and banks of the other characters of the same world and faction.
--     This file keeps that memory up to date (see "Keeping the memory").
-- A Self-Found character cannot be sent anything, so nothing that belongs to
-- other characters is counted for it, from either place.
local ADDON_NAME, LazyProf = ...

LazyProf.Inventory = {}
local Inventory = LazyProf.Inventory

-- ============================================================================
-- Layer 1: Source Providers
-- Each returns {[itemId] = count}
-- ============================================================================

-- The bags the character carries, read by the client adapter (which bags
-- there are and how a slot is read differ per client).
function Inventory:ScanBags()
    return (LazyProf.Client:BagContents())
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
-- points therefore run protected. A failure is not hidden: the first one is
-- written to the debug log, and /lp diag stock prints the last one and how
-- many there were.
local memoryErrors = { count = 0, last = nil, where = nil }

local function NoteMemoryError(where, err)
    memoryErrors.count = memoryErrors.count + 1
    memoryErrors.last = tostring(err)
    memoryErrors.where = where
    if memoryErrors.count == 1 then
        LazyProf:Debug("pathfinder", "Stock memory failed (" .. where .. "): " .. tostring(err))
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

-- Frame-level cache: ScanAll is called many times per frame (once per recipe in
-- GetCandidates). Cache results so only the first call per frame does real work.
local scanCache = { time = 0, combined = nil, breakdown = nil, meta = nil }

-- Stock from Syndicator: the character's bank, mail and auctions, the alts,
-- the guild bank.
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

    -- Guild bank (if enabled)
    if LazyProf.db.profile.includeGuildBank then
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
-- crafting. It depends on who the character is, on whether banks count and
-- on the other characters' saved records - so it is kept under those and
-- built again when the character or that setting differs, when the saved
-- table was replaced as a whole, and when the other characters changed
-- (Forget, and dropping old ones at the start). What the character itself
-- saves does not touch it. Its tables are handed to every scan as they are:
-- read them, do not change them.
--   { guid, countBank, token,
--     totals  = { [itemId] = count over all alts },
--     sources = { [itemId] = { [name] = { bags, bank } } },
--     seen    = { [name] = { bags = time, bank = time } } }
local altsPart = nil

local function BuildAltsPart(identity, countBank)
    local part = { guid = identity.guid, countBank = countBank, totals = {}, sources = {}, seen = {} }
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
    if part and token ~= nil and part.token == token and part.guid == identity.guid and part.countBank == countBank then
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
--     alts = { [name] = { bags = time, bank = time } } }   the alts counted
-- The character's own bank and the account bank are both bank stock (the
-- account bank is other characters' stock too, so a character that cannot
-- receive anything does not count it). An alt's bank needs both settings.
local function AddRememberedStock(self, combined, breakdown, countAlts)
    local Memory, Client = LazyProf.StockMemory, LazyProf.Client
    local countBank = LazyProf.db.profile.includeBankItems and true or false
    local identity = Client:CharacterIdentity() or {}
    local meta = { remembered = true, alts = {} }

    if countBank then
        -- With the bank window open, count what is in it now (unless this
        -- frame has read it already).
        if Client:IsBankOpen() and not self:BankReadThisFrame() then
            self:LookAtOpenBank()
        end
        local items, seenAt = Memory:OwnBank(identity.guid)
        if items then
            mergeSource(items, "bank", nil, combined, breakdown)
            meta.bankSeenAt = seenAt
        end
        if not IsSelfFound() then
            items, seenAt = Memory:AccountBank(identity.world)
            if items then
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

-- Scan all inventory sources based on settings
-- Returns: combinedInventory, sourceBreakdown, meta
--   combinedInventory  { [itemId] = count } over every source that counts
--   sourceBreakdown    { [itemId] = { bags, bank, mail, auctions, guildBank,
--                        alts = { [name] = { bags, bank, mail, auctions } } } }
--   meta               how old the remembered parts are (AddRememberedStock);
--                      nil when the stock comes from Syndicator
function Inventory:ScanAll()
    -- Return cached results if called again in the same frame
    local now = GetTime()
    if scanCache.combined and scanCache.time == now then
        return scanCache.combined, scanCache.breakdown, scanCache.meta
    end

    local combined = {}
    local breakdown = {}
    local meta = nil

    -- 1. Current character bags (read live, always on)
    local bagItems = self:ScanBags()
    mergeSource(bagItems, "bags", nil, combined, breakdown)

    local bagCount = 0
    for _ in pairs(bagItems) do bagCount = bagCount + 1 end
    LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in bags", bagCount))

    -- 2. Everything outside the bags
    local countAlts = LazyProf.db.profile.includeAltCharacters and not IsSelfFound()
    if self:UsesSyndicator() then
        AddSyndicatorStock(self, combined, breakdown, countAlts)
    else
        local ok, result = Protected("scan", AddRememberedStock, self, combined, breakdown, countAlts)
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
-- Nothing here plans the path again; a changed bank only asks the shown list
-- to redraw. With Syndicator installed none of it does anything.
--
-- Bags: saved BAG_SAVE_DELAY seconds after a bag update (one save for a burst
-- of updates) and, when a save is still waiting, at logout. Bags that report
-- no backpack slots could not be read and are not saved. Bags that read as
-- completely empty are saved only when a bag update came before the read: at
-- login and at logout nothing says the client has the bags' contents, and
-- slots without items would otherwise replace the snapshot with nothing.
--
-- Bank: read while the bank window is open only.
--   A change: the first bag update of a frame (whatever container it names -
--     an item may have gone into the bank or come out of it) and a change of
--     the bank's tabs read the bank in the same call. More of them in that
--     frame leave one further read, taken on the next frame.
--   The close: the adapter reports it in two steps. A read still owed is
--     taken during the first, while the bank still counts as open - the next
--     frame would be too late. Whether the client still has the bank then is
--     not known, so that read is only kept when it looks like a normal read
--     of this visit: the adapter does not refuse it, it holds at least one
--     item, and its slot count is that of the last read kept in this visit.
--     After the second step nothing is read. A bank container's update that
--     still arrives then cannot be read; it is counted for /lp diag stock.
--   The opening: whether the items are there the moment the window opens is
--     not known either. The bank is read at once, always once more
--     BANK_SETTLE seconds later, and a read without a single item is only
--     believed BANK_EMPTY_TRUST seconds after the opening; when a read before
--     that mark found nothing, or was refused, the bank is looked at again at
--     the mark.
--   The adapter returns nothing for a bank it cannot read, and then what is
--   remembered stays.
-- ============================================================================

local BAG_SAVE_DELAY = 2
local BANK_SETTLE = 0.5
local BANK_EMPTY_TRUST = 2
local BANK_KINDS = { "character", "account" }

-- First-wins debounces on a pending flag (C_Timer.After returns nothing).
local bagSavePending = false
local bagUpdateSeen = false     -- a bag update asked for the waiting save

local bankOpenedAt = nil        -- GetTime() when this visit's window opened
local bankClosedAt = nil        -- GetTime() of the last close
local bankReadThisFrame = false -- cleared by a zero-delay timer
local bankReadOwed = false      -- one more read, for the next frame
local bankLookPending = {}      -- [mark] = true while the look at that mark is waiting
local visitSlots = {}           -- [kind] = slot count of the last read kept in this visit
-- Bank containers' updates that arrived while the bank was closed.
local closedBankUpdates = { count = 0, lastAfter = nil }

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

-- Read the open bank (the character's and the account's) and remember what
-- can be kept of it. closing: the read taken while the window closes, which
-- is held to the stricter rule above. Returns whether anything was saved,
-- and whether a bank read as empty before that could be believed or was
-- refused (it is then worth another look).
function Inventory:ReadBank(closing)
    if self:UsesSyndicator() then return false, false end
    local Client, Memory = LazyProf.Client, LazyProf.StockMemory
    if not Client:IsBankOpen() then return false, false end
    local identity = Client:CharacterIdentity() or {}
    local now = Client:Now()
    local openFor = bankOpenedAt and (GetTime() - bankOpenedAt) or math.huge
    local saved, unsettled = false, false
    for _, kind in ipairs(BANK_KINDS) do
        local items, bound, slots = Client:BankContents(kind)
        local keep
        if not items then
            keep = false
            unsettled = true
        elseif next(items) == nil then
            -- Not a single item: believed only well after the opening, and
            -- never from the read at the close.
            keep = (not closing) and openFor >= BANK_EMPTY_TRUST
            unsettled = unsettled or not keep
        elseif closing then
            keep = visitSlots[kind] ~= nil and slots == visitSlots[kind]
        else
            keep = true
        end
        if keep then
            local ok
            if kind == "character" then
                ok = Memory:SaveBank(identity, items, bound, now, not IsSelfFound())
            else
                ok = Memory:SaveAccountBank(identity.world, items, now)
            end
            if ok then
                saved = true
                visitSlots[kind] = slots
            end
        end
    end
    if saved then
        InvalidateFrame()
    end
    return saved, unsettled
end

local LookAtBank

-- The bank is looked at again `mark` seconds after its window opened; one
-- such look per mark is waiting at most. A window opened again meanwhile
-- moves the look to the new opening's mark.
local function LookAtMark(mark)
    if bankLookPending[mark] or not bankOpenedAt then return end
    bankLookPending[mark] = true
    local function fire()
        local wait = bankOpenedAt + mark - GetTime()
        if wait > 0.001 and LazyProf.Client:IsBankOpen() then
            C_Timer.After(wait, fire)
            return
        end
        bankLookPending[mark] = nil
        Protected("bank read", LookAtBank, Inventory, true)
    end
    C_Timer.After(math.max(0, bankOpenedAt + mark - GetTime()), fire)
end

-- One read of the open bank, the one of this frame. redraw: let a shown list
-- redraw when the read changed what is remembered (a scan passes false: it
-- is the redraw). Returns whether anything was saved.
LookAtBank = function(self, redraw)
    if not bankReadThisFrame then
        bankReadThisFrame = true
        C_Timer.After(0, function() bankReadThisFrame = false end)
    end
    local saved, unsettled = self:ReadBank()
    if unsettled and bankOpenedAt and GetTime() - bankOpenedAt < BANK_EMPTY_TRUST then
        LookAtMark(BANK_EMPTY_TRUST)
    end
    if saved and redraw and LazyProf.ScheduleShoppingListRefresh then
        LazyProf:ScheduleShoppingListRefresh()
    end
    return saved
end

-- The bank opened or changed: remember it and let a shown list redraw.
function Inventory:OnBankSeen()
    return LookAtBank(self, true)
end

-- The same look without the redraw, for a scan (which is the redraw).
function Inventory:LookAtOpenBank()
    return LookAtBank(self, false)
end

-- Has this frame read the bank already?
function Inventory:BankReadThisFrame()
    return bankReadThisFrame
end

-- Something changed while the bank is open (a bag update, a change of its
-- tabs): read it now when this frame has not read it yet, else leave one
-- read for the next frame.
function Inventory:OnBankChange()
    if self:UsesSyndicator() or not LazyProf.Client:IsBankOpen() then return end
    if not bankReadThisFrame then
        LookAtBank(self, true)
    elseif not bankReadOwed then
        bankReadOwed = true
        C_Timer.After(0, function()
            if not bankReadOwed then return end   -- taken at the close meanwhile
            bankReadOwed = false
            -- reads nothing when the bank has closed meanwhile
            Protected("bank read", LookAtBank, Inventory, true)
        end)
    end
end

function Inventory:OnBankOpened()
    if self:UsesSyndicator() then return end
    bankOpenedAt = GetTime()
    bankReadOwed = false
    visitSlots = {}
    Protected("bank read", LookAtBank, self, true)
    LookAtMark(BANK_SETTLE)
end

-- The window is closing and the bank still counts as open: take the read
-- that is still owed, by the stricter rule (see ReadBank).
function Inventory:OnBankClosing()
    if not bankReadOwed then return end
    Protected("bank read", function()
        if self:ReadBank(true) and LazyProf.ScheduleShoppingListRefresh then
            LazyProf:ScheduleShoppingListRefresh()
        end
    end)
end

-- The bank counts as closed now: nothing is read any more, and a read that
-- was owed is not owed any longer.
function Inventory:OnBankClosed()
    bankClosedAt = GetTime()
    bankReadOwed = false
end

-- A bag update (Core/Init.lua passes every BAG_UPDATE on with its container
-- id). While the bank is open the bank is read again; an update of a bank
-- container is not a change of the bags.
function Inventory:OnBagUpdate(bagId)
    if self:UsesSyndicator() then return end
    Protected("bag update", function()
        local Client = LazyProf.Client
        local bankKind = Client:BankKindOfBag(bagId)
        if Client:IsBankOpen() then
            self:OnBankChange()
        elseif bankKind then
            -- It cannot be read now. Counted, so that one dump shows whether
            -- the client reports bank changes after the window closed.
            closedBankUpdates.count = closedBankUpdates.count + 1
            closedBankUpdates.lastAfter = bankClosedAt and (GetTime() - bankClosedAt) or nil
        end
        if not bankKind then
            self:RequestBagSave(true)
        end
    end)
end

-- Logout (the client's event, and the database's own shutdown notice, which
-- is sure to come before the saved tables are tidied): write a bag save that
-- is still waiting.
function Inventory:OnLogout()
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

-- Forget every remembered character and account bank (the options button).
-- The character being played is remembered again by itself.
function Inventory:ForgetRemembered()
    LazyProf.StockMemory:Forget()
    self:InvalidateCache()
    self:ForgetAltsPart()
    visitSlots = {}
    Protected("bank read", self.LookAtOpenBank, self)
    self:RequestBagSave()
end

-- /lp diag stock: where stock outside the bags comes from, who the character
-- is and what is remembered. Read-only (an open bank is not saved by it).
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
            .. tostring(memoryErrors.count) .. " so far this session - stock outside the bags is not counted while it lasts)")
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
    add("waiting: bagSave=" .. tostring(bagSavePending) .. " bankRead=" .. tostring(bankReadOwed or next(bankLookPending) ~= nil)
        .. " bankOpen=" .. tostring(Client:IsBankOpen()))
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

    local isAlt = {}
    for _, alt in ipairs(Memory:Alts(identity)) do isAlt[alt.guid] = true end
    local function part(label, items, at)
        if items == nil then return label .. "=never seen" end
        return label .. "=" .. tostring(items) .. " items (" .. tostring(Memory.AgeText(now, at)) .. ")"
    end
    for _, c in ipairs(summary.characters) do
        local role = "not counted"
        if c.guid == identity.guid then
            role = "this character"
        elseif isAlt[c.guid] then
            role = "alt"
        end
        add("character: " .. tostring(c.name) .. " [" .. role .. "] world=" .. tostring(c.world)
            .. " faction=" .. tostring(c.faction) .. " " .. part("bags", c.bagItems, c.bagsAt)
            .. " " .. part("bank", c.bankItems, c.bankAt) .. " guid=" .. tostring(c.guid))
    end
    for _, bank in ipairs(summary.account) do
        add("account bank: world=" .. tostring(bank.world) .. " items=" .. tostring(bank.items)
            .. " (" .. tostring(Memory.AgeText(now, bank.at)) .. ")")
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
