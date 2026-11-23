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

-- A Self-Found character cannot receive anything from other characters.
local function CannotReceive()
    local char = LazyProf.db and LazyProf.db.char
    return (char and char.selfFoundMode) and true or false
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
        -- With the bank window open, count what is in it now.
        if Client:IsBankOpen() then
            self:ReadBank()
        end
        local items, seenAt = Memory:OwnBank(identity.guid)
        if items then
            mergeSource(items, "bank", nil, combined, breakdown)
            meta.bankSeenAt = seenAt
        end
        if not CannotReceive() then
            items, seenAt = Memory:AccountBank(identity.world)
            if items then
                mergeSource(items, "bank", nil, combined, breakdown)
                meta.accountSeenAt = seenAt
            end
        end
    end

    if countAlts then
        for _, alt in ipairs(Memory:Alts(identity)) do
            local seen = {}
            if alt.bags then
                mergeSource(alt.bags, "bags", alt.name, combined, breakdown)
                seen.bags = alt.bagsAt
            end
            if countBank and alt.bank then
                mergeSource(alt.bank, "bank", alt.name, combined, breakdown)
                seen.bank = alt.bankAt
            end
            meta.alts[alt.name] = seen
        end
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
    local countAlts = LazyProf.db.profile.includeAltCharacters and not CannotReceive()
    if self:UsesSyndicator() then
        AddSyndicatorStock(self, combined, breakdown, countAlts)
    else
        meta = AddRememberedStock(self, combined, breakdown, countAlts)
    end

    scanCache.time = now
    scanCache.combined = combined
    scanCache.breakdown = breakdown
    scanCache.meta = meta

    return combined, breakdown, meta
end

-- Invalidate the ScanAll cache (call when inventory changes mid-frame)
function Inventory:InvalidateCache()
    scanCache.time = 0
    scanCache.combined = nil
    scanCache.breakdown = nil
    scanCache.meta = nil
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
-- Bank: read while the bank window is open only - when it opens, and on the
-- frame after anything changes while it is open. The adapter returns nothing
-- for a bank it cannot read, and then what is remembered stays. For
-- BANK_SETTLE seconds after the window opened a read that finds no item at
-- all is not taken for an empty bank either (whether the items are there the
-- moment the window opens is not known): it is looked at again when that
-- time is over. Nothing is read when the window closes: whether the bank can
-- still be read at that moment is not known, and a read that found slots
-- without items would replace the memory with an empty bank.
-- ============================================================================

local BAG_SAVE_DELAY = 2
local BANK_READ_DELAY = 0   -- the next frame
local BANK_SETTLE = 0.5

-- First-wins debounces on a pending flag (C_Timer.After returns nothing).
local bagSavePending = false
local bagUpdateSeen = false     -- a bag update asked for the waiting save
local bankReadPending = false
local bankLookAgainPending = false
local bankOpenedAt = nil        -- GetTime() when the bank window opened

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
    return LazyProf.StockMemory:SaveBags(Client:CharacterIdentity(), items, bound, Client:Now())
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
        Inventory:SaveBags(trustEmpty)
    end)
end

-- Read the open bank (the character's and the account's) and remember what
-- can be read. Returns whether anything was saved.
function Inventory:ReadBank()
    if self:UsesSyndicator() then return false end
    local Client, Memory = LazyProf.Client, LazyProf.StockMemory
    if not Client:IsBankOpen() then return false end
    local identity = Client:CharacterIdentity() or {}
    local now = Client:Now()
    -- Just opened: no items at all may only mean they are not there yet.
    local settleLeft = bankOpenedAt and (bankOpenedAt + BANK_SETTLE - GetTime()) or 0
    local lookAgain = false
    local function Usable(items)
        if not items then return false end
        if settleLeft > 0 and next(items) == nil then
            lookAgain = true
            return false
        end
        return true
    end

    local saved = false
    local items, bound = Client:BankContents("character")
    if Usable(items) then
        saved = Memory:SaveBank(identity, items, bound, now) or saved
    end
    items = Client:BankContents("account")
    if Usable(items) then
        saved = Memory:SaveAccountBank(identity.world, items, now) or saved
    end
    if saved then
        self:InvalidateCache()
    end
    if lookAgain and not bankLookAgainPending then
        -- A flag of its own: a change meanwhile is still read on the next frame.
        bankLookAgainPending = true
        C_Timer.After(settleLeft, function()
            bankLookAgainPending = false
            Inventory:OnBankSeen()
        end)
    end
    return saved
end

-- The bank opened or changed: remember it and let a shown list redraw.
function Inventory:OnBankSeen()
    if self:ReadBank() and LazyProf.ScheduleShoppingListRefresh then
        LazyProf:ScheduleShoppingListRefresh()
    end
end

function Inventory:RequestBankRead()
    if bankReadPending or self:UsesSyndicator() then return end
    bankReadPending = true
    C_Timer.After(BANK_READ_DELAY, function()
        bankReadPending = false
        Inventory:OnBankSeen()   -- reads nothing when the bank has closed meanwhile
    end)
end

function Inventory:OnBankOpened()
    bankOpenedAt = GetTime()
    self:OnBankSeen()
end

-- A bag update (Core/Init.lua passes every BAG_UPDATE on with its container
-- id). While the bank is open an item may have gone into it or come out of
-- it whatever container the update names, so the bank is read again; an
-- update of a bank container is not a change of the bags.
function Inventory:OnBagUpdate(bagId)
    if self:UsesSyndicator() then return end
    local Client = LazyProf.Client
    if Client:IsBankOpen() then
        self:RequestBankRead()
    end
    if not Client:BankKindOfBag(bagId) then
        self:RequestBagSave(true)
    end
end

-- Logout (the client's event, and the database's own shutdown notice, which
-- is sure to come before the saved tables are tidied): write a bag save that
-- is still waiting.
function Inventory:OnLogout()
    if not bagSavePending then return end
    bagSavePending = false
    bagUpdateSeen = false
    self:SaveBags(false)
end

-- Start listening (called once the addon is enabled). Characters not seen
-- for a long time are dropped here - never the one being played - and the
-- character is remembered shortly after login even if its bags never change.
function Inventory:Initialize()
    LazyProf.Client:StartStock({
        onBankOpened = function() Inventory:OnBankOpened() end,
        onBankChanged = function() Inventory:RequestBankRead() end,
        onBankClosed = function() end,
        onLogout = function() Inventory:OnLogout() end,
    })
    if self:UsesSyndicator() then return end
    local Client = LazyProf.Client
    local identity = Client:CharacterIdentity() or {}
    if identity.guid then
        LazyProf.StockMemory:Prune(Client:Now(), identity.guid)
    end
    self:RequestBagSave()
end

-- Forget every remembered character and account bank (the options button).
-- The character being played is remembered again by itself.
function Inventory:ForgetRemembered()
    LazyProf.StockMemory:Forget()
    self:InvalidateCache()
    self:ReadBank()
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
        .. " guildBank=" .. tostring(profile.includeGuildBank) .. " selfFound=" .. tostring(CannotReceive()))

    local identity = Client:CharacterIdentity() or {}
    local now = Client:Now()
    add("identity: guid=" .. tostring(identity.guid) .. " name=" .. tostring(identity.name)
        .. " world=" .. tostring(identity.world) .. " faction=" .. tostring(identity.faction))
    add("waiting: bagSave=" .. tostring(bagSavePending) .. " bankRead=" .. tostring(bankReadPending or bankLookAgainPending)
        .. " bankOpen=" .. tostring(Client:IsBankOpen()))

    local summary = Memory:Summary()
    if not summary.usable then
        add("memory: format=" .. tostring(summary.schema) .. " - not a format this version reads; it is left alone")
        return
    end
    add("memory: format=" .. tostring(summary.schema) .. " characters=" .. tostring(#summary.characters)
        .. " accountBanks=" .. tostring(#summary.account)
        .. " (characters not seen for " .. tostring(Memory.KEEP_DAYS) .. " days are dropped)")

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
