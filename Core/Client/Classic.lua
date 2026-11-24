-- Core/Client/Classic.lua
-- Classic implementation of LazyProf.Client: the one place that talks to the
-- Classic profession window (TradeSkillFrame + the GetTradeSkill* API), the
-- skill-line list and the item cache. Used on Era/Anniversary, SoD, TBC and
-- WotLK clients. Callers never touch those client APIs directly.
local ADDON_NAME, LazyProf = ...

if LazyProf.ClientFamily ~= "classic" then return end

local Client = {}
LazyProf.Client = Client

-- Is the profession window open?
function Client:IsOpen()
    return (TradeSkillFrame and TradeSkillFrame:IsVisible()) and true or false
end

-- Frame the side panels anchor to.
function Client:AnchorFrame()
    return TradeSkillFrame
end

-- How far right of the anchor frame's right edge the side panels sit by default.
function Client:PanelOffsetX()
    return 10
end

-- Map the open trade-skill line to its registered profession key.
local function ProfKeyForName(skillName)
    if not skillName then return nil end
    local registry = LazyProf.Professions and LazyProf.Professions.registry
    if not registry then return nil end
    for name, data in pairs(registry) do
        if data.name == skillName then
            return name
        end
    end
    return nil
end

-- Current trade-skill line: profession key (nil when no registered profession
-- matches the window's line name), current rank and max rank as the client
-- reports them.
function Client:GetLine()
    local skillName, currentSkill, maxSkill = GetTradeSkillLine()
    return ProfKeyForName(skillName), currentSkill, maxSkill
end

-- Name of the open trade-skill line when no registered profession (no recipe
-- data) matches it, for the "no recipe data" notice; nil otherwise.
function Client:NoDataProfessionName()
    local skillName = GetTradeSkillLine()
    if not skillName or skillName == "" or ProfKeyForName(skillName) then
        return nil
    end
    return skillName
end

-- Known recipe spell ids for the open profession: { [spellId] = true }.
function Client:KnownRecipeIds(profKey)
    local profData = LazyProf.Professions and LazyProf.Professions:Get(profKey)
    local recipes = profData and profData.recipes or {}

    -- Reverse indexes from this profession's CraftLib recipes, so a visible
    -- trade-skill row can be mapped to its spell id (recipe.id) even when the
    -- client's recipe-link API is unavailable. Scoped to the active profession to
    -- avoid cross-profession item/name collisions.
    local idByItemId = {}   -- crafted-item id -> recipe spell id
    local idByName = {}     -- recipe name      -> recipe spell id
    for _, recipe in ipairs(recipes) do
        if recipe.itemId then idByItemId[recipe.itemId] = recipe.id end
        if recipe.name then idByName[recipe.name] = recipe.id end
    end

    -- Get list of known recipe spell IDs from TradeSkill window.
    -- Each visible non-header row is resolved to a spell id by a layered fallback:
    --   (a) recipe link (enchant:/spell:) - works where the API is populated;
    --   (b) crafted-item id -> recipe.id - REQUIRED on clients (e.g. Season of
    --       Discovery) where GetTradeSkillRecipeLink returns nil for every row but
    --       the item link is populated (confirmed via /lp diag learned);
    --   (c) recipe name - REQUIRED for enchant-on-gear recipes that craft no item
    --       (recipe.itemId nil, no item link).
    local knownSpellIds = {}
    local numSkills = GetNumTradeSkills()
    for i = 1, numSkills do
        local skillName, skillType, _, _, _, _ = GetTradeSkillInfo(i)
        if skillType ~= "header" then
            local spellId
            -- (a) recipe link
            local link = GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(i)
            if link then
                spellId = tonumber(link:match("enchant:(%d+)") or link:match("spell:(%d+)"))
            end
            -- (b) crafted-item id
            if not spellId then
                local itemLink = GetTradeSkillItemLink and GetTradeSkillItemLink(i)
                local itemId = itemLink and tonumber(itemLink:match("item:(%d+)"))
                if itemId then spellId = idByItemId[itemId] end
            end
            -- (c) recipe name
            if not spellId and skillName then
                spellId = idByName[skillName]
            end
            if spellId then
                knownSpellIds[spellId] = true
            end
        end
    end
    return knownSpellIds
end

-- Rank and cap of a profession, read from the skill-line list (works with
-- the profession window closed). 0 and nil when not trained or unknown. The
-- cap is the skill line's 7th return (its maximum rank); a value that cannot
-- be a cap (missing, or below the rank) is reported as unknown rather than
-- trusted.
function Client:ProfessionRank(profKey)
    local profInfo = LazyProf.Constants.PROFESSIONS[profKey]
    if not profInfo then return 0, nil end

    local targetName = profInfo.name:lower()

    -- Classic/TBC uses GetSkillLineInfo instead of GetProfessions
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank, _, _, skillMaxRank = GetSkillLineInfo(i)
        if not isHeader and skillName and skillName:lower() == targetName then
            skillRank = skillRank or 0
            if type(skillMaxRank) ~= "number" or skillMaxRank < skillRank or skillMaxRank <= 0 then
                skillMaxRank = nil
            end
            return skillRank, skillMaxRank
        end
    end

    return 0, nil
end

-- The player's rank in a profession (0 when not trained or unknown).
function Client:PlayerSkill(profKey)
    return (self:ProfessionRank(profKey))
end

-- Every return of the client's item-info call (11th = vendor sell price).
function Client:GetItemInfo(itemId)
    return GetItemInfo(itemId)
end

-- Recipe-name -> trade-skill index cache (scrolling asks for the same recipe
-- many times); dropped whenever the window's list changes.
local rowIndexCache = {}

function Client:InvalidateRowCache()
    rowIndexCache = {}
end

-- Trade-skill list index of a recipe (name match, headers skipped), cached.
local function FindRecipeIndex(recipe)
    local targetName = recipe and recipe.name
    if not targetName then return nil end
    local cached = rowIndexCache[targetName]
    if cached ~= nil then return cached or nil end

    for i = 1, GetNumTradeSkills() do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType ~= "header" and skillName == targetName then
            rowIndexCache[targetName] = i
            return i
        end
    end
    rowIndexCache[targetName] = false   -- remember the miss
    return nil
end

-- Number of visible skill buttons (varies by game version/UI addons).
local function VisibleRowCount()
    local count = 0
    for i = 1, 30 do
        local button = _G["TradeSkillSkill" .. i]
        if button and button:IsShown() then
            count = i
        else
            break
        end
    end
    return count > 0 and count or 8
end

-- Row frame showing `recipe` right now, plus its difficulty ("optimal",
-- "medium", "easy", "trivial"). nil when the window is closed, the recipe is
-- not in the list, or it is scrolled out of view.
function Client:FindRecipeRow(recipe)
    if not self:IsOpen() then return nil end
    local recipeIndex = FindRecipeIndex(recipe)
    if not recipeIndex then return nil end

    local scrollOffset = 0
    if TradeSkillListScrollFrame and FauxScrollFrame_GetOffset then
        scrollOffset = FauxScrollFrame_GetOffset(TradeSkillListScrollFrame)
    end

    local buttonIndex = recipeIndex - scrollOffset
    if buttonIndex < 1 or buttonIndex > VisibleRowCount() then return nil end

    local button = _G["TradeSkillSkill" .. buttonIndex]
    if not button or not button:IsVisible() then return nil end

    local _, skillType = GetTradeSkillInfo(recipeIndex)
    return button, skillType
end

-- The Classic trade-skill window has no "show unlearned" filter (it lists
-- learned recipes only), so the window's hidden-recipe hint, which
-- is about that filter, never applies here.
function Client:UnlearnedHiddenByFilter()
    return false
end

-- Hook the trade-skill list scroll frame so the arrow follows scrolling. The
-- frame belongs to the load-on-demand trade-skill UI, so this runs on open.
local scrollHooked = false
local scrollToken = 0
local function HookScroll(callbacks)
    if scrollHooked or not TradeSkillListScrollFrame then return end

    local origScript = TradeSkillListScrollFrame:GetScript("OnVerticalScroll")
    TradeSkillListScrollFrame:SetScript("OnVerticalScroll", function(frame, offset, ...)
        if origScript then
            origScript(frame, offset, ...)
        end
        -- Debounce: only the latest scroll's callback refreshes.
        scrollToken = scrollToken + 1
        local token = scrollToken
        C_Timer.After(0.05, function()
            if token == scrollToken then
                callbacks.onScroll()
            end
        end)
    end)
    scrollHooked = true
end

-- Register the profession-window events and hooks.
-- callbacks: onOpen(), onClose(), onUpdate(), onScroll().
function Client:Start(callbacks)
    LazyProf:RegisterEvent("TRADE_SKILL_SHOW", function()
        Client:InvalidateRowCache()
        callbacks.onOpen()
        HookScroll(callbacks)
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_UPDATE", function()
        Client:InvalidateRowCache()
        callbacks.onUpdate()
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_CLOSE", function()
        callbacks.onClose()
    end)
end

-- Merchant ------------------------------------------------------------------
-- The Classic merchant calls are used the way these clients have long had
-- them, but none of it could be checked against client source here, so every
-- call is looked up first and a value that does not have the expected type
-- drops the item: without them the merchant panel simply stays away.

local merchantOpen = false

-- callbacks: onShow(), onUpdate(), onClose().
function Client:StartMerchant(callbacks)
    LazyProf:RegisterEvent("MERCHANT_SHOW", function()
        merchantOpen = true
        callbacks.onShow()
    end)
    LazyProf:RegisterEvent("MERCHANT_UPDATE", function()
        if merchantOpen then callbacks.onUpdate() end
    end)
    LazyProf:RegisterEvent("MERCHANT_CLOSED", function()
        if not merchantOpen then return end
        merchantOpen = false
        callbacks.onClose()
    end)
end

function Client:IsMerchantOpen()
    return merchantOpen
end

-- The merchant window, for a panel to sit beside (nil when it is not there).
function Client:MerchantAnchorFrame()
    return MerchantFrame
end

-- What the open merchant sells (see the Forever adapter for the fields).
-- Positional item info: name, texture, price, quantity, numAvailable,
-- isPurchasable, isUsable, extendedCost.
function Client:MerchantItems()
    local items = {}
    if not (GetMerchantNumItems and GetMerchantItemInfo and GetMerchantItemMaxStack) then
        return items
    end
    for index = 1, GetMerchantNumItems() or 0 do
        local name, _, price, quantity, numAvailable, isPurchasable, _, extendedCost = GetMerchantItemInfo(index)
        local itemId = GetMerchantItemID and GetMerchantItemID(index)
        if not itemId and GetMerchantItemLink then
            local link = GetMerchantItemLink(index)
            itemId = link and tonumber(link:match("item:(%d+)"))
        end
        if itemId and type(price) == "number" and type(numAvailable) == "number" then
            local bundle = (type(quantity) == "number" and quantity > 0) and quantity or 1
            local maxStack = GetMerchantItemMaxStack(index)
            items[#items + 1] = {
                index = index,
                itemId = itemId,
                name = name,
                price = price,
                bundle = bundle,
                stock = numAvailable,
                maxStack = (type(maxStack) == "number" and maxStack > 0) and maxStack or bundle,
                extendedCost = extendedCost and true or false,
                purchasable = isPurchasable ~= false,
            }
        end
    end
    return items
end

-- Buy `quantity` items of a list index.
function Client:BuyFromMerchant(index, quantity)
    if BuyMerchantItem then
        BuyMerchantItem(index, quantity)
    end
end

-- Free general-purpose bag slots (backpack and the four bags).
function Client:FreeBagSlots()
    local getFree = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not getFree then return 0 end
    local free = 0
    for bag = 0, 4 do
        local slots, family = getFree(bag)
        if slots and (family == nil or family == 0) then
            free = free + slots
        end
    end
    return free
end

-- The character's money in copper.
function Client:Money()
    return GetMoney and GetMoney() or 0
end

-- /lp diag merchant: the raw merchant values and what MerchantItems makes of
-- them. Read-only.
function Client:RunMerchantDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    add("merchant: open=" .. tostring(merchantOpen)
        .. " numItems=" .. tostring(GetMerchantNumItems and GetMerchantNumItems())
        .. " money=" .. tostring(self:Money()) .. " freeSlots=" .. tostring(self:FreeBagSlots()))
    add("api: GetMerchantItemInfo=" .. tostring(GetMerchantItemInfo ~= nil) .. " GetMerchantItemID="
        .. tostring(GetMerchantItemID ~= nil) .. " GetMerchantItemMaxStack=" .. tostring(GetMerchantItemMaxStack ~= nil)
        .. " BuyMerchantItem=" .. tostring(BuyMerchantItem ~= nil))
    if GetMerchantItemInfo and GetMerchantNumItems then
        for index = 1, math.min(GetMerchantNumItems() or 0, 12) do
            local name, _, price, quantity, numAvailable, isPurchasable, _, extendedCost = GetMerchantItemInfo(index)
            add("raw[" .. tostring(index) .. "] name=" .. tostring(name) .. " price=" .. tostring(price)
                .. " quantity=" .. tostring(quantity) .. " numAvailable=" .. tostring(numAvailable)
                .. " isPurchasable=" .. tostring(isPurchasable) .. " extendedCost=" .. tostring(extendedCost))
        end
    end
    local items = self:MerchantItems()
    add("adapter items=" .. tostring(#items))
    for i = 1, math.min(#items, 12) do
        local item = items[i]
        add("item[" .. tostring(item.index) .. "] id=" .. tostring(item.itemId) .. " price=" .. tostring(item.price)
            .. " bundle=" .. tostring(item.bundle) .. " stock=" .. tostring(item.stock)
            .. " maxStack=" .. tostring(item.maxStack) .. " extendedCost=" .. tostring(item.extendedCost))
    end
end

-- Trainer ---------------------------------------------------------------------
-- Remembering visited trainers needs the trainer window's service list, whose
-- return order on these clients could not be confirmed. Rather than read it
-- on a guess, the Classic adapter reports nothing: no trainer is remembered
-- and no fee is recorded here.

function Client:StartTrainer(callbacks)
end

function Client:TrainerInfo()
    return nil
end

function Client:TrainerServices()
    return {}
end

function Client:RunTrainerDiagnostic(lines)
    lines[#lines + 1] = "trainer: visited trainers are not recorded on this client"
end

-- Stock: bags, the bank, who the character is, the clock ------------------------

-- What the character carries: items ({ [itemId] = count }), the soulbound
-- part of them, and the backpack's slot count (zero means the bags could not
-- be read just now). Backpack and the four bags, through whichever container
-- call the client has: the table-returning one, or the older positional one
-- (count is its 2nd return, the item link its 7th). The older call does not
-- say what is soulbound, so on such a client nothing is reported as bound.
function Client:BagContents()
    local items, bound = {}, {}
    local backpackSlots = 0
    local modern = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo
    if not modern and not (GetContainerNumSlots and GetContainerItemInfo) then
        return items, bound, backpackSlots
    end
    for bag = 0, 4 do
        local slots = (modern and C_Container.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)) or 0
        if bag == 0 then
            backpackSlots = slots
        end
        for slot = 1, slots do
            local itemId, count, isBound
            if modern then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info then
                    itemId, count, isBound = info.itemID, info.stackCount, info.isBound
                end
            else
                local _, itemCount, _, _, _, _, itemLink = GetContainerItemInfo(bag, slot)
                if itemLink then
                    itemId = tonumber(itemLink:match("item:(%d+)"))
                    count = itemCount
                end
            end
            if itemId and count then
                items[itemId] = (items[itemId] or 0) + count
                if isBound then
                    bound[itemId] = (bound[itemId] or 0) + count
                end
            end
        end
    end
    return items, bound, backpackSlots
end

-- Whether a move of items is still on its way: a slot of the carried bags
-- reads as locked - the table-returning container call's isLocked, or the
-- older positional call's third return. Without a container call, false.
-- (No bank is read on these clients, so nothing here depends on it.)
function Client:MoveInFlight()
    local modern = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo
    if not modern and not (GetContainerNumSlots and GetContainerItemInfo) then return false end
    for bag = 0, 4 do
        local slots = (modern and C_Container.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)) or 0
        for slot = 1, slots do
            local locked
            if modern then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                locked = info and info.isLocked
            else
                locked = select(3, GetContainerItemInfo(bag, slot))
            end
            if locked then return true end
        end
    end
    return false
end

-- The bank is not read on these clients: its calls and events could not be
-- checked against client source here, and a bank read on a guess could
-- remember a wrong or an empty bank. So the bank never counts as open,
-- nothing is returned for it, no bank is usable and no container is a bank
-- container; bank stock on these clients comes from an inventory addon only.
function Client:IsBankOpen()
    return false
end

function Client:BankContents(kind)
    return nil
end

function Client:BankUsable(kind)
    return false
end

function Client:BankKindOfBag(bagId)
    return nil
end

-- Who the character is: { guid, name, world, faction, region }. Realms are
-- real on these clients, so the realm name is the world; the region is the
-- region's short name in lower case, where the client has the call. A part
-- the client cannot give is nil. (No bank is read here, so nothing is
-- remembered per region on these clients.)
function Client:CharacterIdentity()
    local region = GetCurrentRegionName and GetCurrentRegionName() or nil
    return {
        guid = UnitGUID and UnitGUID("player") or nil,
        name = UnitName and (UnitName("player")) or nil,
        world = GetRealmName and GetRealmName() or nil,
        faction = UnitFactionGroup and (UnitFactionGroup("player")) or nil,
        region = (type(region) == "string" and region ~= "") and region:lower() or nil,
    }
end

-- Whether the game itself marks the character Self-Found (it can then
-- neither be sent anything nor send anything). The clients that have the mode
-- say so through C_PlayerInfo.IsSelfFoundActive(); not every client of this
-- family has that call, and where it is missing nothing says so: false.
-- Asked at every call. Anything but true is false.
function Client:IsSelfFoundCharacter()
    if C_PlayerInfo and C_PlayerInfo.IsSelfFoundActive then
        return C_PlayerInfo.IsSelfFoundActive() == true
    end
    return false
end

-- Hand a message to the game's error handler (geterrorhandler() returns
-- it), which shows it when Lua errors are displayed. Asking for the handler
-- and calling it both run protected: a client without one, or a handler that
-- fails itself, changes nothing, and nothing is raised from here.
function Client:ShowError(message)
    local found, handler = pcall(geterrorhandler)
    if found and type(handler) == "function" then
        pcall(handler, message)
    end
end

-- What the client itself counts of an item, with and without the bank, is
-- not asked on these clients: no bank is remembered here to compare it with
-- (see the bank note above). nil, whatever is asked.
function Client:ClientItemCounts(itemId)
    return nil
end

-- Server time in seconds; the computer's clock on a client without that call.
function Client:Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

-- callbacks: onBankOpened(), onBankChanged(kind), onBankClosing(),
-- onBankClosed(), onLogout(). Only logout is reported here (see the bank
-- note above). BAG_UPDATE belongs to Core/Init.lua, which passes bag updates
-- on.
function Client:StartStock(callbacks)
    LazyProf:RegisterEvent("PLAYER_LOGOUT", function()
        callbacks.onLogout()
    end)
end

-- /lp diag stock: the bags as this adapter reads them. Read-only.
function Client:RunStockDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local modern = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo
    local legacy = GetContainerNumSlots and GetContainerItemInfo
    add("api: C_Container=" .. tostring(modern and true or false) .. " GetContainerItemInfo=" .. tostring(legacy and true or false)
        .. " GetServerTime=" .. tostring(GetServerTime ~= nil))
    if modern or legacy then
        for bag = 0, 4 do
            local slots = (modern and C_Container.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)) or 0
            add("bag[" .. tostring(bag) .. "] slots=" .. tostring(slots))
        end
    end
    local items, bound, backpackSlots = self:BagContents()
    local itemCount, boundCount = 0, 0
    for _ in pairs(items) do itemCount = itemCount + 1 end
    for _ in pairs(bound) do boundCount = boundCount + 1 end
    add("adapter bags: items=" .. tostring(itemCount) .. " soulbound=" .. tostring(boundCount)
        .. " backpackSlots=" .. tostring(backpackSlots))
    add("bank: not recorded on this client")
end

-- /lp diag learned: append learned-recipe detection lines to `lines`. It
-- contrasts what each id-resolution path sees: the legacy recipe-link scan
-- (parsedIds), the active filter/header state, CraftLib match counts, the real
-- resolver's learned/total result, and the C_TradeSkillUI capability probe.
-- Read-only: the only state touched is the same learnedRecipes cache the normal
-- scan already writes. The caller checks Client:IsOpen() first.
function Client:RunDiagnostic(lines)
    local p = function(s) lines[#lines + 1] = s end

    local profKey = LazyProf.Professions:DetectActive()
    local profData = profKey and LazyProf.Professions:Get(profKey)
    local lineName, curSkill, maxSkill = GetTradeSkillLine()
    p(string.format("diag learned: %s (key=%s) skill=%s/%s",
        tostring(lineName), tostring(profKey), tostring(curSkill), tostring(maxSkill)))

    -- 1. Replicate the production scan and gather counts.
    local knownSpellIds = {}
    local numSkills = GetNumTradeSkills() or 0
    local headers, rows, parsed, unparsed = 0, 0, 0, 0
    for i = 1, numSkills do
        local _, skillType = GetTradeSkillInfo(i)
        if skillType == "header" then
            headers = headers + 1
        else
            rows = rows + 1
            local link = GetTradeSkillRecipeLink(i)
            local spellId = link and tonumber(link:match("enchant:(%d+)") or link:match("spell:(%d+)"))
            if spellId then
                knownSpellIds[spellId] = true
                parsed = parsed + 1
            else
                unparsed = unparsed + 1
            end
        end
    end
    p(string.format("scan: GetNumTradeSkills=%d  headers=%d  recipeRows=%d  parsedIds=%d  unparsed=%d",
        numSkills, headers, rows, parsed, unparsed))

    -- 1b. Raw row detail: WHY the per-row parse yields no spell id (link nil vs
    -- unexpected format). Pipes are doubled so the link shows literally instead
    -- of rendering as a clickable hyperlink in the EditBox.
    p(string.format("api: GetTradeSkillRecipeLink=%s GetTradeSkillItemLink=%s",
        tostring(GetTradeSkillRecipeLink ~= nil), tostring(GetTradeSkillItemLink ~= nil)))
    local function esc(s) return s and (tostring(s):gsub("|", "||")) or "nil" end
    local shown = 0
    for i = 1, numSkills do
        local sName, sType, numAvail = GetTradeSkillInfo(i)
        if sType ~= "header" and shown < 8 then
            shown = shown + 1
            local rLink = GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(i)
            local iLink = GetTradeSkillItemLink and GetTradeSkillItemLink(i)
            p(string.format("row[%d] %s type=%s avail=%s", i, tostring(sName), tostring(sType), tostring(numAvail)))
            p("  recipeLink=" .. esc(rLink))
            p("  itemLink=" .. esc(iLink))
        end
    end

    -- 2. Active filter signals (whichever are queryable on this client; all guarded).
    local nameFilter = GetTradeSkillItemNameFilter and GetTradeSkillItemNameFilter()
    p(string.format("filter: nameFilter=%q", tostring(nameFilter or "")))
    local haveMatsBtn = _G["TradeSkillFrameAvailableFilterCheckButton"]
    if haveMatsBtn and haveMatsBtn.GetChecked then
        p(string.format("filter: haveMaterialsChecked=%s", tostring(haveMatsBtn:GetChecked() and true or false)))
    else
        p("filter: haveMaterials checkbox not found by name (version-specific)")
    end
    p(string.format("filter: hasSubClassFilter=%s hasInvSlotFilter=%s",
        tostring(GetTradeSkillSubClassFilter ~= nil), tostring(GetTradeSkillInvSlotFilter ~= nil)))

    -- 3. CraftLib match stats for the active profession.
    if profData and profData.recipes then
        local total, learnedCount = 0, 0
        local craftlibIds = {}
        local sampleUnlearned = {}
        for _, recipe in ipairs(profData.recipes) do
            total = total + 1
            craftlibIds[recipe.id] = true
            if knownSpellIds[recipe.id] then
                learnedCount = learnedCount + 1
            elseif #sampleUnlearned < 8 then
                sampleUnlearned[#sampleUnlearned + 1] =
                    string.format("%s(id=%s)", tostring(recipe.name), tostring(recipe.id))
            end
        end
        p(string.format("craftlib: recipes=%d  matchedLearned=%d  flaggedUnlearned=%d",
            total, learnedCount, total - learnedCount))
        if #sampleUnlearned > 0 then
            p("craftlib: sample flagged-unlearned: " .. table.concat(sampleUnlearned, ", "))
        end
        -- Scanned ids that match NO CraftLib recipe id (the H2 direction).
        local unmatched, sampleUnmatched = 0, {}
        for spellId in pairs(knownSpellIds) do
            if not craftlibIds[spellId] then
                unmatched = unmatched + 1
                if #sampleUnmatched < 8 then sampleUnmatched[#sampleUnmatched + 1] = tostring(spellId) end
            end
        end
        p(string.format("craftlib: scannedIdsWithNoCraftLibMatch=%d", unmatched))
        if #sampleUnmatched > 0 then
            p("craftlib: sample unmatched scanned ids: " .. table.concat(sampleUnmatched, ", "))
        end
    else
        p("craftlib: no active profession data (DetectActive returned nil)")
    end

    -- 3b. Production result. Sections 1/3 above replicate the LEGACY recipe-link
    -- scan (so parsedIds documents WHY the old path failed). This line calls the
    -- real resolver, which now also maps via crafted-item id and name - post-fix
    -- it should report a healthy learned count, not 0.
    if profKey then
        local resolved = LazyProf.Professions:GetRecipesWithLearnedStatus(profKey)
        local rTotal, rLearned = 0, 0
        for _, recipe in ipairs(resolved) do
            rTotal = rTotal + 1
            if recipe.learned then rLearned = rLearned + 1 end
        end
        p(string.format("result: GetRecipesWithLearnedStatus -> %d/%d learned", rLearned, rTotal))
    end

    -- 4. Capability probe: filter-immune C_TradeSkillUI path.
    local hasCTSU = C_TradeSkillUI ~= nil
    local hasGetAll = hasCTSU and C_TradeSkillUI.GetAllRecipeIDs ~= nil
    local hasGetInfo = hasCTSU and C_TradeSkillUI.GetRecipeInfo ~= nil
    p(string.format("probe: C_TradeSkillUI=%s GetAllRecipeIDs=%s GetRecipeInfo=%s",
        tostring(hasCTSU), tostring(hasGetAll), tostring(hasGetInfo)))
    if hasGetAll then
        local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
        if ok and type(ids) == "table" then
            local ctsuKnown = 0
            if hasGetInfo then
                for _, rid in ipairs(ids) do
                    local okI, info = pcall(C_TradeSkillUI.GetRecipeInfo, rid)
                    if okI and type(info) == "table" and info.learned then
                        ctsuKnown = ctsuKnown + 1
                    end
                end
            end
            p(string.format("probe: GetAllRecipeIDs=%d learnedPerGetRecipeInfo=%d (vs legacy parsedIds=%d)",
                #ids, ctsuKnown, parsed))
        else
            p("probe: GetAllRecipeIDs call failed or returned non-table")
        end
    end
end
