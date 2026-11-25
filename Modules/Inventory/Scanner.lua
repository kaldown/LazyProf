-- Modules/Inventory/Scanner.lua
-- Which owned stock counts: for the route, every total and the shopping list.
--
-- The bags the character carries are always read live, through the client
-- adapter. Everything else comes from the Syndicator addon, when it is
-- installed: the character's bank, mail and own auctions, the alts (their
-- bags, banks, mail and auctions) and the guild bank, each as its setting
-- says. Without Syndicator only the carried bags count; a scan that was
-- asked for bank or alt stock then says so (its meta.bagsOnly), and the
-- Shopping tab tells the player in one line.
-- A Self-Found character cannot be sent anything, so nothing that belongs to
-- other characters is counted for it (alts, the guild bank). A character is
-- Self-Found here when the game itself marks it so (the client adapter asks)
-- or the addon's Self-Found setting is on; which recipes the planner allows
-- follows the setting alone.
local ADDON_NAME, LazyProf = ...

LazyProf.Inventory = {}
local Inventory = LazyProf.Inventory

-- ============================================================================
-- Layer 1: Source Providers
-- Each returns {[itemId] = count}
-- ============================================================================

-- The bags the character carries, read by the client adapter (which bags
-- there are and how a slot is read differ per client; on WoW Forever the
-- reagent bag is one of them).
function Inventory:ScanBags()
    return LazyProf.Client:BagContents()
end

-- Can a stored slot be counted? An alt's soulbound items cannot be sent
-- (leaveBound), so they are left out; Syndicator marks them `isBound`.
local function Counts(slot, leaveBound)
    return slot and slot.itemID and not (leaveBound and slot.isBound == true)
end

-- Scan bags from Syndicator character data (for alts: leaveBound)
function Inventory:ScanBagsSyndicator(charData, leaveBound)
    local items = {}
    if not charData or not charData.bags then return items end

    for _, bag in ipairs(charData.bags) do
        if bag then
            for _, slot in ipairs(bag) do
                if Counts(slot, leaveBound) then
                    items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                end
            end
        end
    end

    return items
end

-- Scan bank via Syndicator character data (for an alt: leaveBound)
function Inventory:ScanBank(charData, leaveBound)
    local items = {}
    if not charData then return items end

    -- Legacy bank bags
    if charData.bank then
        for _, bag in ipairs(charData.bank) do
            if bag then
                for _, slot in ipairs(bag) do
                    if Counts(slot, leaveBound) then
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
                    if Counts(slot, leaveBound) then
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

-- How many items a source holds: for a debug line only (see ScanAll).
local function CountItems(items)
    local count = 0
    for _ in pairs(items) do count = count + 1 end
    return count
end

-- Is the Syndicator addon there to read stock from?
function Inventory:UsesSyndicator()
    return (Syndicator and Syndicator.API) and true or false
end

-- The addon's own Self-Found setting (per character, off by default).
local function SelfFoundSetting()
    local char = LazyProf.db and LazyProf.db.char
    return (char and char.selfFoundMode) and true or false
end

-- A Self-Found character cannot be sent anything: nothing of the other
-- characters is counted for it. It is one when the setting is on or the
-- game itself marks it (the adapter's answer, asked at every call and never
-- kept: a scan made under the other answer must not serve). The adapter's
-- call runs protected: when it fails the setting alone decides.
local function IsSelfFound()
    if SelfFoundSetting() then return true end
    local Client = LazyProf.Client
    local asked, marked = pcall(Client.IsSelfFoundCharacter, Client)
    if not asked then
        LazyProf:Debug("pathfinder", "Inventory scan: the game's Self-Found flag could not be read: " .. tostring(marked))
    end
    return asked and marked == true
end

-- Frame-level cache: ScanAll is called many times per frame (once per recipe in
-- GetCandidates). Cache results so only the first call per frame does real work.
local scanCache = { time = 0, combined = nil, breakdown = nil, meta = nil }

-- Whether an alt's stock counts for the character being played (review F3):
-- the same realm (on WoW Forever Syndicator records the ruleset, "PvP",
-- there) and the same faction, as Syndicator recorded both for each of them.
-- An alt that cannot be judged does not count. Returns counts, and why not.
local function DetailsOf(record)
    return type(record) == "table" and type(record.details) == "table" and record.details or nil
end
local function RealmOf(details)
    return details.realmNormalized or details.realm
end
local function AltCounts(currentRecord, altRecord)
    local current = DetailsOf(currentRecord)
    if not (current and current.faction and RealmOf(current)) then
        return false, "the played character's realm or faction is unknown"
    end
    if type(altRecord) ~= "table" then return false, "no record" end
    local alt = DetailsOf(altRecord)
    if not alt then return false, "no details" end
    if not alt.faction then return false, "faction unknown" end
    if alt.faction ~= current.faction then return false, "other faction" end
    if not RealmOf(alt) then return false, "realm unknown" end
    if RealmOf(alt) ~= RealmOf(current) then return false, "other realm" end
    return true
end
Inventory.AltCounts = AltCounts

-- Stock from Syndicator: the character's bank, mail and auctions, the alts,
-- the guild bank (the last two not for a Self-Found character: selfFound,
-- as the scan found it). logLines: build the lines for the debug log.
local function AddSyndicatorStock(self, combined, breakdown, countAlts, selfFound, logLines)
    local charName = Syndicator.API.GetCurrentCharacter()
    local charData = charName and Syndicator.API.GetByCharacterFullName(charName)

    if charData then
        for _, source in ipairs(PER_CHAR_SOURCES) do
            if not source.configKey or LazyProf.db.profile[source.configKey] then
                local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                local items = self[scanMethod](self, charData)
                mergeSource(items, source.key, nil, combined, breakdown)

                if logLines then
                    LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in %s", CountItems(items), source.key))
                end
            elseif logLines then
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
                    if altData and AltCounts(charData, altData) then
                        -- Bags (soulbound items cannot be sent: left out)
                        local altBags = self:ScanBagsSyndicator(altData, true)
                        mergeSource(altBags, "bags", altName, combined, breakdown)

                        -- Bank, mail, auctions (respecting config for bank)
                        for _, source in ipairs(PER_CHAR_SOURCES) do
                            if not source.configKey or LazyProf.db.profile[source.configKey] then
                                local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                                local items = self[scanMethod](self, altData, true)
                                mergeSource(items, source.key, altName, combined, breakdown)
                            end
                        end

                        if logLines then
                            totalAltItems = totalAltItems + CountItems(altBags)
                        end
                    end
                end
            end
        end

        if logLines then
            LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items from alts", totalAltItems))
        end
    elseif logLines then
        LazyProf:Debug("pathfinder", "Inventory scan: alts not counted")
    end

    -- Guild bank (if enabled). It is other characters' stock as well: a
    -- Self-Found character, which cannot be handed anything, does not count it.
    if LazyProf.db.profile.includeGuildBank and not selfFound then
        local guildItems = self:ScanGuildBank()
        mergeSource(guildItems, "guildBank", nil, combined, breakdown)

        if logLines then
            LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in guild bank", CountItems(guildItems)))
        end
    elseif logLines then
        LazyProf:Debug("pathfinder", "Inventory scan: guild bank disabled")
    end
end

-- Scan all inventory sources based on settings
-- Returns: combinedInventory, sourceBreakdown, meta
--   combinedInventory  { [itemId] = count } over every source that counts
--   sourceBreakdown    { [itemId] = { bags, bank, mail, auctions, guildBank,
--                        alts = { [name] = { bags, bank, mail, auctions } } } }
--   meta               what the scan says of the stock it could count; nil
--                      when there is nothing to say. { bagsOnly = true }:
--                      bank or alt stock was asked for (its setting is on, and
--                      for alts the character is not Self-Found) but only the
--                      carried bags count, as Syndicator is not installed.
function Inventory:ScanAll()
    -- Return cached results if called again in the same frame, unless a
    -- setting that decides which stock counts has changed since
    local now = GetTime()
    local profile = LazyProf.db.profile
    local countBank = profile.includeBankItems and true or false
    local wantAlts = profile.includeAltCharacters and true or false
    local countGuild = profile.includeGuildBank and true or false
    local selfFound = IsSelfFound()
    local syndicator = self:UsesSyndicator()
    if scanCache.combined and scanCache.time == now and scanCache.countBank == countBank
            and scanCache.wantAlts == wantAlts and scanCache.countGuild == countGuild
            and scanCache.selfFound == selfFound and scanCache.syndicator == syndicator then
        return scanCache.combined, scanCache.breakdown, scanCache.meta
    end

    local combined = {}
    local breakdown = {}
    local meta = nil
    -- The lines for the debug log - counting each source's items, a
    -- formatted line per source - are built only while that log takes them:
    -- a scan runs for every calculation and for every light refresh.
    local logLines = LazyProf:IsDebugEnabled("pathfinder")

    -- 1. Current character bags (read live, always on)
    local bagItems = self:ScanBags()
    mergeSource(bagItems, "bags", nil, combined, breakdown)

    if logLines then
        LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in bags", CountItems(bagItems)))
    end

    -- 2. Everything outside the bags: from Syndicator, or nothing
    local countAlts = wantAlts and not selfFound
    if syndicator then
        AddSyndicatorStock(self, combined, breakdown, countAlts, selfFound, logLines)
    else
        if countBank or countAlts then
            meta = { bagsOnly = true }
        end
        if logLines then
            LazyProf:Debug("pathfinder", "Inventory scan: bags only (Syndicator is not installed)")
        end
    end

    scanCache.time = now
    scanCache.combined = combined
    scanCache.breakdown = breakdown
    scanCache.meta = meta
    scanCache.countBank, scanCache.wantAlts = countBank, wantAlts
    scanCache.countGuild, scanCache.selfFound = countGuild, selfFound
    scanCache.syndicator = syndicator

    return combined, breakdown, meta
end

-- Invalidate the ScanAll cache (call when inventory or a stock setting
-- changes mid-frame)
function Inventory:InvalidateCache()
    scanCache.time = 0
    scanCache.combined = nil
    scanCache.breakdown = nil
    scanCache.meta = nil
end

-- ============================================================================
-- /lp diag stock
-- ============================================================================

-- The Syndicator block of the dump: one line per character Syndicator
-- knows, with every plain value (string, number, boolean) of its record's
-- `details`. On WoW Forever the realm name is a shard name that can change,
-- so these lines show whether Syndicator keeps the same character twice
-- under two realm names. Syndicator's record layout is not part of its
-- documented API, so everything is read defensively: a call that is missing
-- or fails, or a table that is not there, is said in the line, never raised.
local SYNDICATOR_CHARACTERS_SHOWN = 60

-- Call a Syndicator.API function by name, protected. Returns whether it ran
-- and its first result (or what went wrong).
local function SyndicatorCall(name, ...)
    local api = Syndicator and Syndicator.API
    if type(api) ~= "table" then return false, "no Syndicator.API" end
    local fn = api[name]
    if type(fn) ~= "function" then return false, "no Syndicator.API." .. name end
    return pcall(fn, ...)
end

-- A plain value as the dump prints it: text in quotes, on one line.
local function PlainValue(value)
    if type(value) == "string" then
        return '"' .. value:gsub("%c", " ") .. '"'
    end
    return tostring(value)
end

-- One character's line: its name, whether it is the one being played, and
-- the plain values of its record's details, sorted by key.
local function SyndicatorCharacterLine(name, current)
    local text = "syndicator character: " .. PlainValue(name) .. (name == current and " [current]" or "")
    local ok, record = SyndicatorCall("GetByCharacterFullName", name)
    if not ok then
        return text .. " record: " .. tostring(record)
    end
    if type(record) ~= "table" then
        return text .. " record: none"
    end
    local details = record.details
    if type(details) ~= "table" then
        return text .. " details: none"
    end
    local keys = {}
    for key, value in pairs(details) do
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. PlainValue(details[key])
    end
    return text .. (#parts > 0 and (" " .. table.concat(parts, " ")) or " details: no plain values")
end

-- The first item stored for a character (bags, then bank), or nil.
local function FirstStoredItem(record)
    if type(record) ~= "table" then return nil end
    for _, key in ipairs({ "bags", "bank" }) do
        local list = record[key]
        if type(list) == "table" then
            for _, bag in ipairs(list) do
                if type(bag) == "table" then
                    for _, slot in pairs(bag) do
                        if type(slot) == "table" and slot.itemID then return slot end
                    end
                end
            end
        end
    end
    return nil
end

-- The plain fields of one stored item, sorted by key; text longer than 30
-- characters (an item link) is shown by its length.
local function ItemFieldsLine(record)
    local item = FirstStoredItem(record)
    if not item then return "syndicator item fields: no stored item" end
    local keys = {}
    for key, value in pairs(item) do
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = item[key]
        local shown = (type(value) == "string" and #value > 30) and ("<" .. #value .. " characters>") or PlainValue(value)
        parts[#parts + 1] = tostring(key) .. "=" .. shown
    end
    return "syndicator item fields: " .. table.concat(parts, " ")
end

-- Which of Syndicator's characters count as alts (Inventory.AltCounts, the
-- scan's own rule), and why the others do not.
local function AltsLine(names, current)
    local currentRecord
    if current then
        local read, record = SyndicatorCall("GetByCharacterFullName", current)
        if read then currentRecord = record end
    end
    local counted, notCounted = {}, {}
    local more = math.max(0, #names - SYNDICATOR_CHARACTERS_SHOWN)
    for index, name in ipairs(names) do
        if index > SYNDICATOR_CHARACTERS_SHOWN then break end
        if name ~= current then
            local read, record = SyndicatorCall("GetByCharacterFullName", name)
            local counts, why = false, "the record could not be read"
            if read then counts, why = AltCounts(currentRecord, record) end
            if counts then
                counted[#counted + 1] = PlainValue(name)
            else
                notCounted[#notCounted + 1] = PlainValue(name) .. " (" .. why .. ")"
            end
        end
    end
    return "syndicator alts: counted " .. (#counted > 0 and table.concat(counted, ", ") or "none")
        .. "; not counted " .. (#notCounted > 0 and table.concat(notCounted, ", ") or "none")
        .. (more > 0 and (", and " .. more .. " more") or ""), currentRecord
end

local function AddSyndicatorLines(add)
    if not (Syndicator and Syndicator.API) then
        add("syndicator: not installed")
        return
    end
    local listed, names = SyndicatorCall("GetAllCharacters")
    if not listed then
        add("syndicator: the character list could not be read: " .. tostring(names))
        return
    end
    if type(names) ~= "table" then
        add("syndicator: no character list")
        return
    end
    local currentRead, current = SyndicatorCall("GetCurrentCharacter")
    add("syndicator: characters=" .. tostring(#names) .. " current="
        .. (currentRead and PlainValue(current) or ("not readable: " .. tostring(current))))
    if not currentRead then current = nil end
    for index, name in ipairs(names) do
        if index > SYNDICATOR_CHARACTERS_SHOWN then
            add("syndicator: " .. tostring(#names - SYNDICATOR_CHARACTERS_SHOWN) .. " more")
            break
        end
        local built, line = pcall(SyndicatorCharacterLine, name, current)
        add(built and line or ("syndicator character: " .. tostring(name) .. " could not be read: " .. tostring(line)))
    end
    local built, line, currentRecord = pcall(AltsLine, names, current)
    add(built and line or ("syndicator alts: could not be judged: " .. tostring(line)))
    local fieldsBuilt, fields = pcall(ItemFieldsLine, built and currentRecord or nil)
    add(fieldsBuilt and fields or ("syndicator item fields: could not be read: " .. tostring(fields)))
end

-- /lp diag stock: where stock outside the bags comes from, the settings that
-- decide which stock counts, and what Syndicator knows of each character.
-- Read-only.
function Inventory:RunDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local Client = LazyProf.Client
    local profile = LazyProf.db.profile

    if self:UsesSyndicator() then
        add("source: Syndicator (bank, mail, auctions, alts and guild bank)")
    else
        add("source: the bags only (Syndicator is not installed)")
    end
    -- The Self-Found setting and the game's own flag, apart: either makes
    -- the character Self-Found for stock.
    local flagRead, gameFlag = pcall(Client.IsSelfFoundCharacter, Client)
    add("settings: bank=" .. tostring(profile.includeBankItems) .. " alts=" .. tostring(profile.includeAltCharacters)
        .. " guildBank=" .. tostring(profile.includeGuildBank) .. " selfFound=" .. tostring(SelfFoundSetting())
        .. " gameSelfFound=" .. (flagRead and tostring(gameFlag == true) or ("not readable: " .. tostring(gameFlag))))

    -- A section of its own: whatever Syndicator hands back, the lines above stay.
    local listed, err = pcall(AddSyndicatorLines, add)
    if not listed then
        add("SECTION ERROR: syndicator: " .. tostring(err))
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
