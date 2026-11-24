-- Core/Client/Forever.lua
-- WoW Forever implementation of LazyProf.Client: the one place that talks to
-- that client's profession window (ProfessionsFrame + C_TradeSkillUI), its
-- spell-book profession list and C_Item. Forever plays like Classic but runs
-- the retail engine, so none of the Classic trade-skill globals exist there.
--
-- Facts below cite Blizzard's UI source for this client (Gethe/wow-ui-source,
-- forever branch, 1.60.1 build 70938; paths under Interface/AddOns/) or the
-- dump of the running client's globals (Ketho BlizzardInterfaceResources,
-- forever branch: Resources/GlobalAPI.lua / Events.lua / LuaEnum.lua /
-- AtlasInfo.lua). Ones that could not be settled from source are listed for
-- an in-game check where they are used.
local ADDON_NAME, LazyProf = ...

if LazyProf.ClientFamily ~= "forever" then return end

local Client = {}
LazyProf.Client = Client

-- Enum.TradeskillRelativeDifficulty (LuaEnum.lua:7883-7888) -> the names the
-- arrow colours use. Same mapping Blizzard's recipe list draws with
-- (Blizzard_ProfessionsTemplates/Blizzard_ProfessionsRecipeList.lua:1-5, 292-297).
local DIFFICULTY = {
    [Enum.TradeskillRelativeDifficulty.Optimal] = "optimal",
    [Enum.TradeskillRelativeDifficulty.Medium] = "medium",
    [Enum.TradeskillRelativeDifficulty.Easy] = "easy",
    [Enum.TradeskillRelativeDifficulty.Trivial] = "trivial",
}

-- The recipe list ScrollBox: ProfessionsFrame
-- (Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.xml:10) > CraftingPage
-- (same file :68) > RecipeList (Blizzard_Professions/Blizzard_ProfessionsCrafting.xml:135)
-- > ScrollBox (Blizzard_ProfessionsTemplates/Blizzard_ProfessionsRecipeList.xml:76),
-- a WowScrollBoxList, i.e. ScrollBoxListMixin
-- (Blizzard_SharedXML/Shared/Scroll/ScrollTemplates.xml:4).
local function RecipeScrollBox()
    return ProfessionsFrame.CraftingPage.RecipeList.ScrollBox
end

-- Is the profession window open on its recipe list? On Forever the frame also
-- hosts a profession-book page and stays shown with it after the trade skill
-- closes (Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua:110-113,
-- 127-134), so the recipe list (CraftingPage) must be the page shown.
function Client:IsOpen()
    return (ProfessionsFrame ~= nil and ProfessionsFrame:IsShown()
        and ProfessionsFrame.CraftingPage:IsShown()) and true or false
end

-- Frame the side panels anchor to.
function Client:AnchorFrame()
    return ProfessionsFrame
end

-- How far right of the anchor frame's right edge the side panels sit by
-- default: 10 px past the profession side tabs, which hang outside the
-- window's right edge from 60 px down
-- (Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.xml:13-21). A tab is
-- as wide as the "common-sidetab" atlas (SidePanelTabButtonMixin,
-- Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.lua:311-330; wider on
-- this client, SharedUIPanelTemplates.xml:1013), 55 px here (Ketho
-- BlizzardInterfaceResources, forever branch, Resources/AtlasInfo.lua:3758).
local SIDE_TAB_WIDTH = 55
local PANEL_GAP = 10

function Client:PanelOffsetX()
    return SIDE_TAB_WIDTH + PANEL_GAP
end

-- The open profession, the way Blizzard reads it (Professions.GetProfessionInfo,
-- Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:1665-1676): the child
-- line, or the base line when the child's professionID is 0.
-- Verify in game: recipes and skill-ups follow the child line's skillLevel.
local function ProfessionInfo()
    local info = C_TradeSkillUI.GetChildProfessionInfo()
    if info.professionID == 0 then
        info = C_TradeSkillUI.GetBaseProfessionInfo()
    end
    return info
end

-- Registered profession key of a skill line (nil when none matches).
local function ProfKeyForSkillLine(skillLine)
    local key = LazyProf.Constants.SKILL_LINE_PROFESSION[skillLine]
    local registry = LazyProf.Professions and LazyProf.Professions.registry
    if key and registry and registry[key] then
        return key
    end
    return nil
end

-- Is the window showing the player's own list? Not when it shows a linked
-- player's, a guild member's or the guild's list, or NPC crafting - the same
-- test as Professions.InLocalCraftingMode
-- (Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:377-383; the calls
-- are in the client dump, GlobalAPI.lua:4409, 4425-4427).
local function ShowsOwnList()
    return not (C_TradeSkillUI.IsNPCCrafting() or C_TradeSkillUI.IsTradeSkillGuild()
        or C_TradeSkillUI.IsTradeSkillGuildMember() or C_TradeSkillUI.IsTradeSkillLinked())
end

-- Current profession line: profession key (nil when no registered profession
-- matches, or when the list is someone else's - so no path is built and their
-- recipes never reach the player's learned cache), skill level and max skill
-- level. The line is the parent when there is one
-- (Professions.GetEffectiveSkillLineID,
-- Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:1678-1681).
function Client:GetLine()
    local info = ProfessionInfo()
    local skillLine = info.parentProfessionID or info.professionID
    local key = ShowsOwnList() and ProfKeyForSkillLine(skillLine) or nil
    return key, info.skillLevel, info.maxSkillLevel
end

-- Name of the open profession when the window shows the player's own list
-- and no registered profession (no recipe data) matches its line, for the
-- "no recipe data" notice; nil otherwise. The name is the one Blizzard shows:
-- the parent line's name when there is one (displayName in
-- Professions.GetProfessionInfo, Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:1673;
-- fields in Blizzard_APIDocumentationGenerated/TradeSkillUITypesDocumentation.lua:361-376).
function Client:NoDataProfessionName()
    if not ShowsOwnList() then return nil end
    local info = ProfessionInfo()
    if ProfKeyForSkillLine(info.parentProfessionID or info.professionID) then return nil end
    local name = info.parentProfessionName or info.professionName
    if not name or name == "" then return nil end
    return name
end

-- Known recipe spell ids of the open profession: { [spellId] = true }. Every
-- learned id, whatever the list's filters show: Blizzard builds the visible
-- list from GetFilteredRecipeIDs
-- (Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:847), this reads the
-- unfiltered GetAllRecipeIDs (GlobalAPI.lua:4327; not in the API docs).
-- GetRecipeInfo may return nil (Blizzard_APIDocumentationGenerated/
-- TradeSkillUIDocumentation.lua:639-652).
-- Verify in game: GetAllRecipeIDs returns an array of recipe spell ids.
function Client:KnownRecipeIds(profKey)
    local known = {}
    for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs()) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and info.learned then
            known[recipeID] = true
        end
    end
    return known
end

-- The player's rank in a profession from the spell-book professions (works
-- with the window closed). GetProfessions returns up to seven indices with
-- nil for empty slots (Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua:4);
-- GetProfessionInfo's 7th return is the parent skill line (the same file
-- compares it with the effective line, :28-30, :48-51). 0 when not trained.
-- Verify in game: this rank equals the open window's skillLevel.
local function ProfessionIndices(...)
    return select("#", ...), { ... }
end

-- Rank and cap (maxRank, the 4th return: Blizzard_Professions/Camelot/
-- Blizzard_ProfessionsFrame.lua:48 names every return) of a profession, with
-- its window closed. 0 and nil when not trained.
-- Verify in game: this cap equals the open window's maxSkillLevel.
function Client:ProfessionRank(profKey)
    local skillLine
    for line, key in pairs(LazyProf.Constants.SKILL_LINE_PROFESSION) do
        if key == profKey then skillLine = line end
    end
    if not skillLine then return 0, nil end

    local count, indices = ProfessionIndices(GetProfessions())
    for i = 1, count do
        local index = indices[i]
        if index then
            local _, _, rank, maxRank, _, _, line = GetProfessionInfo(index)
            if line == skillLine then
                rank = rank or 0
                if type(maxRank) ~= "number" or maxRank < rank or maxRank <= 0 then
                    maxRank = nil
                end
                return rank, maxRank
            end
        end
    end
    return 0, nil
end

function Client:PlayerSkill(profKey)
    return (self:ProfessionRank(profKey))
end

-- Every return of the client's item-info call (11th = vendor sell price);
-- nothing until the item is cached
-- (Blizzard_APIDocumentationGenerated/ItemDocumentation.lua:626-629).
function Client:GetItemInfo(itemId)
    return C_Item.GetItemInfo(itemId)
end

-- Rows are found among the ScrollBox's live frames on every call; there is
-- no cache to drop.
function Client:InvalidateRowCache()
end

-- Row frame showing `recipe` right now, plus its difficulty ("optimal",
-- "medium", "easy", "trivial"). nil when the window is closed or the recipe
-- has no row in view (scrolled away, filtered out, or an unlearned recipe
-- while the list hides unlearned ones). The ScrollBox only holds frames for
-- the visible range (EnumerateFrames = ipairs over them,
-- Blizzard_SharedXML/Shared/Scroll/ScrollBoxListView.lua:169-171); each
-- frame's element data is a tree node whose .data carries recipeInfo
-- (Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:970; read the same
-- way at Blizzard_ProfessionsTemplates/Blizzard_ProfessionsRecipeList.lua:359-360).
-- Category and divider rows have no recipeInfo.
-- Verify in game: the element-data shape on the live client.
function Client:FindRecipeRow(recipe)
    if not self:IsOpen() or not recipe then return nil end
    for _, frame in RecipeScrollBox():EnumerateFrames() do
        local node = frame:GetElementData()
        local info = node and node.data and node.data.recipeInfo
        if info and info.recipeID == recipe.id then
            return frame, DIFFICULTY[info.relativeDifficulty]
        end
    end
    return nil
end

-- True when the recipe list could show unlearned recipes but its "show
-- unlearned" filter is off (Blizzard_APIDocumentationGenerated/
-- TradeSkillUIDocumentation.lua:849-856): the arrow cannot point at an
-- unlearned next recipe, so the window's learn step says so instead.
function Client:UnlearnedHiddenByFilter()
    return not C_TradeSkillUI.GetShowUnlearned()
end

-- Open / close reports. TRADE_SKILL_SHOW always reports an open (a new or a
-- switched trade skill). The recipe page also hides without the trade skill
-- closing: the Overview tab switches the frame to its profession-book page
-- (ProfessionsBookRightTabMixin:OnClick,
-- Blizzard_ProfessionsTemplates/Blizzard_ProfessionsTemplates.lua:975-979 ->
-- SelectBookPage, Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua:110-112),
-- and a profession tab switches back (same templates file :983-990). The
-- page hiding reports a close, its showing again an open. A close is reported
-- once (page hide and TRADE_SKILL_CLOSE both come when the window closes).
local reportedOpen = false   -- an open was reported and no close since
local openSerial = 0         -- number of opens reported
local lastHidden = nil       -- UnlearnedHiddenByFilter() at this open's last list update

local function ReportOpen(callbacks)
    reportedOpen = true
    openSerial = openSerial + 1
    lastHidden = nil
    callbacks.onOpen()
end

local function ReportClose(callbacks)
    if not reportedOpen then return end
    reportedOpen = false
    lastHidden = nil
    callbacks.onClose()
end

-- The recipe page showed. When the whole window opens it shows in the same
-- frame as TRADE_SKILL_SHOW, before or after it; wait one frame so that event
-- reports the open alone. Shown without that event (back from the book page):
-- report it here.
local function OnRecipePageShown(callbacks)
    if reportedOpen then return end
    local serial = openSerial
    C_Timer.After(0, function()
        if openSerial == serial and not reportedOpen and Client:IsOpen() then
            ReportOpen(callbacks)
        end
    end)
end

-- Re-point the arrow after the list scrolls or its visible range changes.
-- OnScroll fires on scrolling (Blizzard_SharedXML/Shared/Scroll/ScrollBox.lua:277);
-- OnDataRangeChanged when the visible range or the data changes - rebuilt,
-- sorted, resized or replaced data invalidates the range (ScrollBox.lua:789-793;
-- ScrollBoxListView.lua:697-699, same folder). Callbacks get (owner, ...)
-- (Blizzard_SharedXMLBase/CallbackRegistry.lua:112-139, 206-213).
-- Also hooks the recipe page's show/hide for the reports above.
-- The professions UI loads on demand on the first TRADE_SKILL_SHOW
-- (Blizzard_Game/Mainline/EventImplementation.lua:475-477,
-- Blizzard_Professions/Blizzard_Professions_Bootstrap.lua:3-11), so this runs
-- from the event handlers until the frame exists, then once.
local frameHooked = false
local scrollToken = 0
local function HookFrame(callbacks)
    if frameHooked or not ProfessionsFrame then return end

    local function OnListMoved()
        -- Debounce: only the latest change's callback refreshes.
        scrollToken = scrollToken + 1
        local token = scrollToken
        C_Timer.After(0.05, function()
            if token == scrollToken then
                callbacks.onScroll()
            end
        end)
    end

    local scrollBox = RecipeScrollBox()
    scrollBox:RegisterCallback(BaseScrollBoxEvents.OnScroll, OnListMoved, Client)
    scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnDataRangeChanged, OnListMoved, Client)

    local page = ProfessionsFrame.CraftingPage
    page:HookScript("OnShow", function() OnRecipePageShown(callbacks) end)
    page:HookScript("OnHide", function() ReportClose(callbacks) end)
    frameHooked = true
end

-- The "show unlearned" filter changed during this open: re-render the
-- current path (the learn step's hint depends on it; nothing to
-- recalculate). The first list update of an open only records the value, so
-- a previous profession's path is never redrawn for the one just opened.
local function CheckUnlearnedFilter()
    local hidden = Client:UnlearnedHiddenByFilter()
    local changed = lastHidden ~= nil and hidden ~= lastHidden
    lastHidden = hidden
    if changed then
        LazyProf:UpdateDisplay()
    end
end

-- Register the profession-window events (Events.lua:1890-1902) and the list
-- callbacks. callbacks: onOpen(), onClose(), onUpdate(), onScroll().
-- A list update that arrives while the data source is still changing is
-- skipped and the next one is used, as Blizzard's own frame does
-- (Blizzard_Professions/Blizzard_ProfessionsFrame.lua:148-154).
-- Verify in game: TRADE_SKILL_LIST_UPDATE fires after a skill-up.
function Client:Start(callbacks)
    LazyProf:RegisterEvent("TRADE_SKILL_SHOW", function()
        HookFrame(callbacks)
        ReportOpen(callbacks)
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
        HookFrame(callbacks)
        if C_TradeSkillUI.IsDataSourceChanging() then return end
        callbacks.onUpdate()
        CheckUnlearnedFilter()
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", function()
        HookFrame(callbacks)
        callbacks.onUpdate()
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_CLOSE", function()
        ReportClose(callbacks)
    end)
end

-- Merchant ------------------------------------------------------------------
-- Events: MERCHANT_SHOW / MERCHANT_CLOSED / MERCHANT_UPDATE and, when the
-- merchant's filter changes its list, MERCHANT_FILTER_ITEM_UPDATE
-- (Events.lua:1331-1334; Blizzard's frame handles the same ones,
-- Blizzard_UIPanels_Game/Mainline/MerchantFrame.lua:8, 97).

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
    LazyProf:RegisterEvent("MERCHANT_FILTER_ITEM_UPDATE", function()
        if merchantOpen then callbacks.onUpdate() end
    end)
    LazyProf:RegisterEvent("MERCHANT_CLOSED", function()
        if not merchantOpen then return end   -- the event can fire twice per close
        merchantOpen = false
        callbacks.onClose()
    end)
end

function Client:IsMerchantOpen()
    return merchantOpen
end

-- The merchant window, for a panel to sit beside (a global frame that always
-- exists: Blizzard_UIPanels_Game/Mainline/MerchantFrame.xml:94).
function Client:MerchantAnchorFrame()
    return MerchantFrame
end

-- What the open merchant sells, one entry per list index:
--   index, itemId, name
--   price        copper for one purchase unit (a bundle of `bundle` items)
--   bundle       items per purchase unit
--   stock        the merchant's numAvailable as reported: above zero a limited
--                supply and zero sold out (the merchant UI shows both:
--                Blizzard_ItemButton/Mainline/ItemButtonTemplate.lua:40-55,
--                MerchantFrame.lua:373); below zero is taken as unlimited
--   maxStack     most items one purchase call may ask for
--   extendedCost priced in something other than gold alone
--   purchasable
-- The item table is C_MerchantFrame.GetItemInfo's (fields:
-- Blizzard_APIDocumentationGenerated/MerchantFrameDocumentation.lua:126-141);
-- it may return nothing. Blizzard reads the same calls at MerchantFrame.lua:
-- 253-300 (list), :359 (item id), :714 (max stack).
-- Verify in game: numAvailable of an unlimited item (/lp diag merchant).
function Client:MerchantItems()
    local items = {}
    for index = 1, GetMerchantNumItems() do
        local info = C_MerchantFrame.GetItemInfo(index)
        local itemId = GetMerchantItemID(index)
        if info and itemId then
            local bundle = (info.stackCount and info.stackCount > 0) and info.stackCount or 1
            items[#items + 1] = {
                index = index,
                itemId = itemId,
                name = info.name,
                price = info.price or 0,
                bundle = bundle,
                stock = info.numAvailable,
                maxStack = GetMerchantItemMaxStack(index) or bundle,
                extendedCost = (info.hasExtendedCost or info.currencyID ~= nil) and true or false,
                purchasable = info.isPurchasable and true or false,
            }
        end
    end
    return items
end

-- Buy `quantity` items of a list index: the count is in items, a multiple of
-- the bundle, at most the item's max stack - as Blizzard's own split-stack
-- purchase calls it (MerchantFrame.lua:656-666, 713-737).
-- Verify in game: whether purchases made outside a click are accepted
-- (/lp diag merchant; the purchase queue copes either way).
function Client:BuyFromMerchant(index, quantity)
    BuyMerchantItem(index, quantity)
end

-- Free general-purpose bag slots (backpack and the four bags; a bag that
-- only takes certain items reports a non-zero family and is left out).
-- C_Container.GetContainerNumFreeSlots returns numFreeSlots, bagFamily
-- (Blizzard_APIDocumentationGenerated/ContainerDocumentation.lua:297-309).
function Client:FreeBagSlots()
    local free = 0
    for bag = 0, 4 do
        local slots, family = C_Container.GetContainerNumFreeSlots(bag)
        if slots and (family == nil or family == 0) then
            free = free + slots
        end
    end
    return free
end

-- The character's money in copper.
function Client:Money()
    return GetMoney()
end

-- /lp diag merchant: the raw merchant values and what MerchantItems makes of
-- them. Read-only.
function Client:RunMerchantDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local function section(name, fn)
        local ok, err = pcall(fn)
        if not ok then add("SECTION ERROR: " .. name .. ": " .. tostring(err)) end
    end
    section("state", function()
        add("merchant: open=" .. tostring(merchantOpen) .. " frameShown="
            .. tostring(MerchantFrame ~= nil and MerchantFrame:IsShown())
            .. " numItems=" .. tostring(GetMerchantNumItems())
            .. " money=" .. tostring(GetMoney()) .. " freeSlots=" .. tostring(self:FreeBagSlots()))
    end)
    section("raw", function()
        for index = 1, math.min(GetMerchantNumItems() or 0, 12) do
            local info = C_MerchantFrame.GetItemInfo(index)
            if info then
                add("raw[" .. tostring(index) .. "] id=" .. tostring(GetMerchantItemID(index))
                    .. " name=" .. tostring(info.name) .. " price=" .. tostring(info.price)
                    .. " stackCount=" .. tostring(info.stackCount) .. " numAvailable=" .. tostring(info.numAvailable)
                    .. " isPurchasable=" .. tostring(info.isPurchasable) .. " hasExtendedCost=" .. tostring(info.hasExtendedCost)
                    .. " currencyID=" .. tostring(info.currencyID) .. " maxStack=" .. tostring(GetMerchantItemMaxStack(index)))
            else
                add("raw[" .. tostring(index) .. "] no info")
            end
        end
    end)
    section("items", function()
        local items = self:MerchantItems()
        add("adapter items=" .. tostring(#items))
        for i = 1, math.min(#items, 12) do
            local item = items[i]
            add("item[" .. tostring(item.index) .. "] id=" .. tostring(item.itemId) .. " price=" .. tostring(item.price)
                .. " bundle=" .. tostring(item.bundle) .. " stock=" .. tostring(item.stock)
                .. " maxStack=" .. tostring(item.maxStack) .. " extendedCost=" .. tostring(item.extendedCost)
                .. " purchasable=" .. tostring(item.purchasable))
        end
    end)
end

-- Trainer ---------------------------------------------------------------------
-- Events: TRAINER_SHOW / TRAINER_UPDATE / TRAINER_CLOSED (Events.lua:1906-1910).
-- The trainer UI itself loads on demand; only the calls below are used, never
-- its frames. Nothing here trains anything.

local trainerOpen = false

-- callbacks: onShow(), onUpdate(), onClose().
function Client:StartTrainer(callbacks)
    LazyProf:RegisterEvent("TRAINER_SHOW", function()
        trainerOpen = true
        callbacks.onShow()
    end)
    LazyProf:RegisterEvent("TRAINER_UPDATE", function()
        if trainerOpen then callbacks.onUpdate() end
    end)
    LazyProf:RegisterEvent("TRAINER_CLOSED", function()
        if not trainerOpen then return end
        trainerOpen = false
        callbacks.onClose()
    end)
end

-- A value the client marks as secret must not be read or stored (unit names
-- can be, in some situations).
local function Readable(value)
    if value == nil then return nil end
    if issecretvalue and issecretvalue(value) then return nil end
    return value
end

-- The open trainer, when it is a profession trainer: who and where.
--   name      the trainer's name (the window's title is UnitName("npc"):
--             Blizzard_TrainerUI/Mainline/Blizzard_TrainerUI.lua:440-449);
--             nil when the client keeps it secret
--   npcId     from the trainer's GUID (nil when unreadable)
--   zone, subZone, mapId
--   x, y      where the player stands, 0-1 on that map (nil where the client
--             gives no position, e.g. indoors on some maps)
--   faction   the player's
-- nil when no trainer is open or it is not a profession trainer
-- (IsTradeskillTrainer, used the same way at Blizzard_TrainerUI.lua:871).
function Client:TrainerInfo()
    if not trainerOpen or not IsTradeskillTrainer() then return nil end
    local info = { faction = UnitFactionGroup("player") }
    info.name = Readable(UnitName("npc"))
    local guid = Readable(UnitGUID("npc"))
    if type(guid) == "string" then
        -- Creature-0-<server>-<instance>-<zone>-<npc id>-<spawn>
        info.npcId = tonumber((select(6, strsplit("-", guid))))
    end
    info.zone = Readable(GetRealZoneText())
    info.subZone = Readable(GetSubZoneText())
    local mapId = C_Map.GetBestMapForUnit("player")
    info.mapId = mapId
    if mapId then
        local position = C_Map.GetPlayerMapPosition(mapId, "player")
        if position then
            local x, y = position:GetXY()
            if Readable(x) and Readable(y) then
                info.x, info.y = x, y
            end
        end
    end
    return info
end

-- What the open trainer lists (as its window's filters show it):
--   index, name, state ("available" | "unavailable" | "used"), cost (copper),
--   reqLevel
-- GetTrainerServiceInfo returns name, type, texture, reqLevel, subText,
-- category on this client and GetTrainerServiceCost returns moneyCost,
-- isProfession (Blizzard_TrainerUI.lua:469, 618, 692).
function Client:TrainerServices()
    local services = {}
    if not trainerOpen then return services end
    for index = 1, GetNumTrainerServices() or 0 do
        local name, state, _, reqLevel = GetTrainerServiceInfo(index)
        if Readable(name) and state ~= "header" then
            services[#services + 1] = {
                index = index,
                name = name,
                state = state,
                cost = (GetTrainerServiceCost(index)),
                reqLevel = reqLevel,
            }
        end
    end
    return services
end

-- /lp diag trainer: the raw trainer values and what the adapter makes of
-- them. Read-only.
function Client:RunTrainerDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local function section(name, fn)
        local ok, err = pcall(fn)
        if not ok then add("SECTION ERROR: " .. name .. ": " .. tostring(err)) end
    end
    section("state", function()
        add("trainer: open=" .. tostring(trainerOpen) .. " IsTradeskillTrainer=" .. tostring(IsTradeskillTrainer())
            .. " services=" .. tostring(GetNumTrainerServices()))
        local name = UnitName("npc")
        local secret = issecretvalue ~= nil and name ~= nil and issecretvalue(name) or false
        add("npc: nameSecret=" .. tostring(secret) .. " name=" .. (secret and "(secret)" or tostring(name)))
        local rank, maxRank, modifier = GetTrainerTradeskillRankValues()
        add("trainer rank values: rank=" .. tostring(rank) .. " maxRank=" .. tostring(maxRank)
            .. " modifier=" .. tostring(modifier))
    end)
    section("raw", function()
        for index = 1, math.min(GetNumTrainerServices() or 0, 10) do
            local name, state, _, reqLevel, subText, category = GetTrainerServiceInfo(index)
            local cost, isProfession = GetTrainerServiceCost(index)
            local skill, rank, hasReq = GetTrainerServiceSkillReq(index)
            add("raw[" .. tostring(index) .. "] name=" .. tostring(name) .. " type=" .. tostring(state)
                .. " reqLevel=" .. tostring(reqLevel) .. " subText=" .. tostring(subText) .. " category=" .. tostring(category)
                .. " cost=" .. tostring(cost) .. " isProfession=" .. tostring(isProfession)
                .. " skillReq=" .. tostring(skill) .. "/" .. tostring(rank) .. "/" .. tostring(hasReq)
                .. " skillLine=" .. tostring(GetTrainerServiceSkillLine(index)))
        end
    end)
    section("adapter", function()
        local info = self:TrainerInfo()
        if not info then
            add("adapter info: none (no profession trainer open)")
        else
            add("adapter info: name=" .. tostring(info.name) .. " npcId=" .. tostring(info.npcId)
                .. " zone=" .. tostring(info.zone) .. " subZone=" .. tostring(info.subZone)
                .. " mapId=" .. tostring(info.mapId) .. " x=" .. tostring(info.x) .. " y=" .. tostring(info.y)
                .. " faction=" .. tostring(info.faction))
        end
        add("adapter services=" .. tostring(#self:TrainerServices()))
    end)
end

-- Stock: bags, the bank, who the character is, the clock ------------------------
-- Paths below are under Blizzard_APIDocumentationGenerated/ unless they name
-- another folder.

-- Add what a container holds to `items` ({ [itemId] = count }) and the
-- soulbound part of it to `bound`; returns the container's slot count.
-- C_Container.GetContainerNumSlots(containerIndex) returns a number
-- (ContainerDocumentation.lua:313-326); GetContainerItemInfo(containerIndex,
-- slotIndex) returns a table with itemID, stackCount and isBound, or nothing
-- for an empty slot (ContainerDocumentation.lua:192-207, 766-781).
local function ReadContainer(container, items, bound)
    local slots = C_Container.GetContainerNumSlots(container)
    for slot = 1, slots do
        local info = C_Container.GetContainerItemInfo(container, slot)
        if info and info.itemID and info.stackCount then
            items[info.itemID] = (items[info.itemID] or 0) + info.stackCount
            if info.isBound then
                bound[info.itemID] = (bound[info.itemID] or 0) + info.stackCount
            end
        end
    end
    return slots
end

-- What the character carries: items, the soulbound part of them, and the
-- backpack's slot count (zero means the bags could not be read just now).
-- Carried bags are Enum.BagIndex.Backpack (0) to ReagentBag (5): four bag
-- slots and the reagent-bag slot (BagIndexConstantsDocumentation.lua:18-52;
-- the client's counts are in the dump, LuaEnum.lua:9729-9735). Blizzard's
-- own bag searches run over the same range
-- (Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua:400-427 with
-- Blizzard_FrameXMLBase/Constants.lua:165-170). The keyring (-1) is not stock.
function Client:BagContents()
    local items, bound = {}, {}
    local backpackSlots = 0
    for bag = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
        local slots = ReadContainer(bag, items, bound)
        if bag == Enum.BagIndex.Backpack then
            backpackSlots = slots
        end
    end
    return items, bound, backpackSlots
end

-- The bank. This client has the tab-based C_Bank bank
-- (Blizzard_UIPanels_Game/Blizzard_UIPanels_Game.toc:137-142 loads
-- Mainline/BankFrameTemplates.lua and Camelot/BankFrame.lua). A bank type
-- (Enum.BankType: Character = 0, Account = 2, ItemConstantsDocumentation.lua:17-27)
-- has purchased tabs, each a container of its own (Enum.BagIndex
-- CharacterBankTab_1..9 = 6..14, AccountBankTab_1..9 = 15..23,
-- BagIndexConstantsDocumentation.lua:18-52). Here the tabs after the first
-- are shown as bank bag slots (Blizzard_UIPanels_Game/Camelot/BankFrame.lua:136-191)
-- and a bought slot may be without a bag (Enum.BankTabFlags.AllowMissingBag,
-- ItemConstantsDocumentation.lua:5-15), so a single tab that reports no slots
-- is not taken for an unreadable bank.
-- Whether a bank's containers can be read while its window is closed could
-- not be settled from source, so they are only read between BANKFRAME_OPENED
-- and BANKFRAME_CLOSED (events without payload, BankDocumentation.lua:389-400).
local bankOpen = false

local function BankType(kind)
    if kind == "character" then return Enum.BankType.Character end
    if kind == "account" then return Enum.BankType.Account end
    return nil
end

function Client:IsBankOpen()
    return bankOpen
end

-- What a bank holds right now: items, the soulbound part of them, and how
-- many slots its tabs have together (a caller can tell by it whether two
-- reads saw the same bank). kind is "character" or "account". nil when it
-- cannot be read now - the window is closed, the bank may not be viewed, it
-- is locked, it has no tabs or none of them reports a slot - so that "could
-- not read" is never taken for "empty".
-- The gates and the reading are the bank window's own: C_Bank.CanViewBank
-- (Blizzard_UIPanels_Game/Mainline/BankFrameTemplates.lua:70), a non-nil
-- C_Bank.FetchBankLockedReason is locked (same file :872-874),
-- C_Bank.FetchPurchasedBankTabData(bankType) lists the tabs (:974-976;
-- BankDocumentation.lua:241-255, each with its container `ID`, :440-451),
-- read slot by slot (:1064-1070, :1126-1130, :578).
-- Verify in game (/lp diag stock with the bank open): the tab ids, their slot
-- counts and whether the account bank can be viewed at all.
function Client:BankContents(kind)
    local bankType = BankType(kind)
    if not bankOpen or bankType == nil then return nil end
    if not C_Bank.CanViewBank(bankType) then return nil end
    if C_Bank.FetchBankLockedReason(bankType) ~= nil then return nil end
    local tabs = C_Bank.FetchPurchasedBankTabData(bankType)
    if not tabs or #tabs == 0 then return nil end
    local items, bound = {}, {}
    local slots = 0
    for _, tab in ipairs(tabs) do
        slots = slots + ReadContainer(tab.ID, items, bound)
    end
    if slots == 0 then return nil end
    return items, bound, slots
end

-- Whether a bank can be used right now: its window is open, the bank may be
-- viewed, it is not locked and it has at least one purchased tab. These are
-- the first gates of BankContents above (the same calls, at the same lines of
-- the bank window's source); no slot is read. A bank that is not usable at
-- any moment of a visit cannot have been changed through that visit, which
-- is what the scanner asks this for. kind is "character" or "account".
function Client:BankUsable(kind)
    local bankType = BankType(kind)
    if not bankOpen or bankType == nil then return false end
    if not C_Bank.CanViewBank(bankType) then return false end
    if C_Bank.FetchBankLockedReason(bankType) ~= nil then return false end
    local tabs = C_Bank.FetchPurchasedBankTabData(bankType)
    return (tabs ~= nil and #tabs > 0) and true or false
end

-- Which bank a container id belongs to ("character" | "account"), nil for
-- the carried bags and anything else. A BAG_UPDATE carries the container id
-- (ContainerDocumentation.lua:659-667); the bank window reads it the same
-- way (Blizzard_UIPanels_Game/Mainline/BankFrameTemplates.lua:791-795).
function Client:BankKindOfBag(bagId)
    if type(bagId) ~= "number" then return nil end
    local index = Enum.BagIndex
    if bagId >= index.CharacterBankTab_1 and bagId <= index.CharacterBankTab_9 then
        return "character"
    elseif bagId >= index.AccountBankTab_1 and bagId <= index.AccountBankTab_9 then
        return "account"
    end
    return nil
end

-- The world a character lives in: region and ruleset, "eu-pvp", "us-normal",
-- "eu-rppvp", "eu-hc-pvp". This client has no realms - the realm name is a
-- shard that changes under the player - so stored data is scoped by this
-- key, never by a realm name. C_GameRules.IsGameRuleActive(gameRule)
-- (GameRulesDocumentation.lua:225-238) with Enum.GameRule.RPRuleset,
-- PvPRuleset and HardcoreRuleset (dump, LuaEnum.lua:3441, 3587-3588);
-- GetCurrentRegionName() is the region's short name (compared with "US" at
-- Blizzard_GroupFinder/Mainline/LFGList.lua:2422). Where the region has no
-- name its number stands in, "region3-pvp": GetCurrentRegion() returns a
-- number (LocaleDocumentation.lua:39-47; dump, GlobalAPI.lua:5382). nil when
-- there is neither: then nothing is taken for a character of the same world.
-- The second return is the region alone ("eu", "region3"), the key of what
-- a whole region shares (the account bank is remembered per region).
local function WorldKey()
    local region = GetCurrentRegionName()
    if type(region) == "string" and region ~= "" then
        region = region:lower()
    else
        local number = GetCurrentRegion()
        if type(number) ~= "number" then return nil, nil end
        region = "region" .. tostring(number)
    end
    local on, rule = C_GameRules.IsGameRuleActive, Enum.GameRule
    local ruleset = (on(rule.RPRuleset) and "rp" or "") .. (on(rule.PvPRuleset) and "pvp" or "")
    if ruleset == "" then ruleset = "normal" end
    if on(rule.HardcoreRuleset) then ruleset = "hc-" .. ruleset end
    return region .. "-" .. ruleset, region
end

-- Who the character is: { guid, name, world, faction, region }. A part that
-- cannot be read is nil (the caller saves nothing without a guid and counts
-- no alts without a world and a faction).
--   guid     UnitGUID("player") (UnitDocumentation.lua:1241-1255)
--   name     first name and surname, the way the client writes a full name
--            (NameUtil.GetUnmodifiedUnitFullName,
--            Blizzard_FrameXMLUtil/Camelot/NameUtil.lua:14-21)
--   world    WorldKey() above
--   region   the region part of it, WorldKey()'s second return
--   faction  UnitFactionGroup("player"), its first return
--            (UnitDocumentation.lua:1207-1222)
-- Guid, name and faction do not change during a session, so a complete read
-- of the three is kept. The world is worked out again at every ask (three
-- rule reads and the region): whether the game rules read true from the very
-- first moment after login is not known, and a world kept from a moment in
-- which they read false would file the character under the wrong world for
-- the whole session.
-- Verify in game: the GUID is the same after a relog and on another shard.
local who = nil

function Client:CharacterIdentity()
    local known = who
    if not known then
        local guid = Readable(UnitGUID("player"))
        known = {
            guid = type(guid) == "string" and guid or nil,
            name = Readable(NameUtil.GetUnmodifiedUnitFullName("player")),
            faction = Readable((UnitFactionGroup("player"))),
        }
        if known.guid and known.name and known.faction then
            who = known
        end
    end
    local world, region = WorldKey()
    return { guid = known.guid, name = known.name, world = world, faction = known.faction, region = region }
end

-- Whether the game itself marks the character Self-Found: such a character
-- can neither be sent anything nor send anything.
-- C_PlayerInfo.IsSelfFoundActive() returns a boolean
-- (PlayerInfoDocumentation.lua:322-329; in the client's function list, dump,
-- GlobalAPI.lua:3359). It is asked at every call: whether the flag can change
-- during a session is not known. Anything but true is false.
-- Verify in game: the gameSelfFound value of /lp diag stock on a character
-- that is Self-Found and on one that is not.
function Client:IsSelfFoundCharacter()
    return C_PlayerInfo.IsSelfFoundActive() == true
end

-- Hand a message to the game's error handler, which shows it when Lua
-- errors are displayed. geterrorhandler() returns the handler (a global of
-- this client: dump, GlobalAPI.lua:6884; Blizzard's UI source calls it the
-- same way, Blizzard_SharedXMLBase/ErrorUtil.lua:3 and :18-19). Asking for
-- the handler and calling it both run protected: a handler that is missing
-- or fails itself changes nothing, and nothing is raised from here.
function Client:ShowError(message)
    local found, handler = pcall(geterrorhandler)
    if found and type(handler) == "function" then
        pcall(handler, message)
    end
end

-- What the client itself counts of an item: carried only, with the bank,
-- and with the bank and the account bank.
-- C_Item.GetItemCount(itemInfo, includeBank, includeUses, includeReagentBank,
-- includeAccountBank) returns a number (ItemDocumentation.lua:451-467; in the
-- client's function list, dump, GlobalAPI.lua:2517). All five arguments are
-- passed, as Blizzard does (Blizzard_FrameXMLUtil/ItemUtil.lua:320); charges
-- and the reagent bank are never asked for.
-- Whether this count sees a bank while its window is closed is not known,
-- so nothing is worked out from it: only /lp diag stock prints the three
-- numbers beside what is remembered, and one paste taken away from the bank
-- settles it. Nothing else may use this until then.
-- Without an item id nothing is asked of the client and the three are zero:
-- the caller learns from it that this client has such a count (the Classic
-- adapter answers nil).
function Client:ClientItemCounts(itemId)
    if itemId == nil then return 0, 0, 0 end
    local carried = C_Item.GetItemCount(itemId, false, false, false, false)
    local withBank = C_Item.GetItemCount(itemId, true, false, false, false)
    local withAccountBank = C_Item.GetItemCount(itemId, true, false, false, true)
    return carried, withBank, withAccountBank
end

-- Server time in seconds (SystemTimeDocumentation.lua:30-36): the same on
-- every character and computer, which the computer's own clock is not.
function Client:Now()
    return GetServerTime()
end

-- Bank window and logout reports.
-- callbacks: onBankOpened(), onBankChanged(kind), onBankClosing(),
-- onBankClosed(), onLogout().
-- BANK_TABS_CHANGED carries the bank type (BankDocumentation.lua:379-388; the
-- bank window rebuilds itself on it, Blizzard_UIPanels_Game/Mainline/
-- BankFrameTemplates.lua:778-782); PLAYER_LOGOUT has no payload
-- (SystemDocumentation.lua:157-161).
-- The opening is reported after the bank counts as open: the caller reads
-- it in that very call.
-- A close is reported in two steps. onBankClosing runs while the bank still
-- counts as open, so a read that is still owed for a change of this very
-- frame can be taken; whether the client still holds the bank's contents
-- when BANKFRAME_CLOSED arrives could not be settled from source, so the
-- caller must not take such a read for more than it is (the scanner only
-- keeps one that looks like the reads before it, and marks the remembered
-- bank as in doubt when one of its containers reported a change that no
-- kept read came after). Then the bank counts as closed and onBankClosed
-- runs: from there on nothing is read.
-- Verify in game (/lp diag stock after a visit): the "bank visit close",
-- "after the close" and "bank updates while closed" lines; and after a
-- logout at the bank and the next login, the "bags at the bank" line.
-- BAG_UPDATE and BAG_UPDATE_DELAYED are not registered here: the addon
-- object has one handler per event and Core/Init.lua owns those two; it
-- passes them on.
function Client:StartStock(callbacks)
    LazyProf:RegisterEvent("BANKFRAME_OPENED", function()
        bankOpen = true
        callbacks.onBankOpened()
    end)
    LazyProf:RegisterEvent("BANK_TABS_CHANGED", function(_, bankType)
        if not bankOpen then return end
        if bankType == Enum.BankType.Character then
            callbacks.onBankChanged("character")
        elseif bankType == Enum.BankType.Account then
            callbacks.onBankChanged("account")
        end
    end)
    LazyProf:RegisterEvent("BANKFRAME_CLOSED", function()
        if not bankOpen then return end   -- the event can fire twice per close
        callbacks.onBankClosing()
        bankOpen = false
        callbacks.onBankClosed()
    end)
    LazyProf:RegisterEvent("PLAYER_LOGOUT", function()
        callbacks.onLogout()
    end)
end

-- /lp diag stock: the raw bag, bank and identity values and what the adapter
-- makes of them. Read-only.
function Client:RunStockDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local function section(name, fn)
        local ok, err = pcall(fn)
        if not ok then add("SECTION ERROR: " .. name .. ": " .. tostring(err)) end
    end
    local function Count(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    -- "slots/used" of a container
    local function Usage(container)
        local slots = C_Container.GetContainerNumSlots(container)
        local used = 0
        for slot = 1, slots do
            if C_Container.GetContainerItemInfo(container, slot) then used = used + 1 end
        end
        return slots, used
    end
    section("bags", function()
        for bag = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
            local slots, used = Usage(bag)
            add("bag[" .. tostring(bag) .. "] slots=" .. tostring(slots) .. " used=" .. tostring(used))
        end
        local items, bound, backpackSlots = self:BagContents()
        add("adapter bags: items=" .. tostring(Count(items)) .. " soulbound=" .. tostring(Count(bound))
            .. " backpackSlots=" .. tostring(backpackSlots))
    end)
    -- C_Bank.ShouldUsePlayerBagsInBank() returns a boolean
    -- (BankDocumentation.lua:322-329); the bank window asks it to decide
    -- how its tabs are laid out (Blizzard_UIPanels_Game/Mainline/
    -- BankFrameTemplates.lua:687, 793). Only reported here.
    section("bank", function()
        add("bank: open=" .. tostring(bankOpen)
            .. " usesPlayerBags=" .. tostring(C_Bank.ShouldUsePlayerBagsInBank()))
    end)
    for _, kind in ipairs({ "character", "account" }) do
        section("bank " .. kind, function()
            local bankType = BankType(kind)
            local tabs = C_Bank.FetchPurchasedBankTabData(bankType) or {}
            local parts = {}
            for _, tab in ipairs(tabs) do
                local slots, used = Usage(tab.ID)
                parts[#parts + 1] = tostring(tab.ID) .. ":" .. tostring(slots) .. "/" .. tostring(used)
            end
            add("bank " .. kind .. ": canView=" .. tostring(C_Bank.CanViewBank(bankType))
                .. " lockedReason=" .. tostring(C_Bank.FetchBankLockedReason(bankType))
                .. " tabs=" .. tostring(#tabs) .. " [" .. table.concat(parts, " ") .. "]")
            local items, bound = self:BankContents(kind)
            if items then
                add("adapter bank " .. kind .. ": items=" .. tostring(Count(items))
                    .. " soulbound=" .. tostring(Count(bound)))
            else
                add("adapter bank " .. kind .. ": not readable now")
            end
        end)
    end
    section("identity", function()
        local on, rule = C_GameRules.IsGameRuleActive, Enum.GameRule
        local guid = UnitGUID("player")
        local secret = issecretvalue ~= nil and guid ~= nil and issecretvalue(guid) or false
        add("world: region=" .. tostring(GetCurrentRegionName()) .. " regionNumber=" .. tostring(GetCurrentRegion())
            .. " rp=" .. tostring(on(rule.RPRuleset))
            .. " pvp=" .. tostring(on(rule.PvPRuleset)) .. " hardcore=" .. tostring(on(rule.HardcoreRuleset))
            .. " guidSecret=" .. tostring(secret) .. " serverTime=" .. tostring(GetServerTime()))
    end)
    -- Whether crafts may take reagents out of the bank. If they may, a craft
    -- changes the bank while its window is closed and the remembered bank is
    -- then behind until the next visit. Enum.GameRule.CraftFromBankRestricted
    -- is in the client's enum table (dump, LuaEnum.lua:3586); what the rule
    -- does in play is not documented, so it is only reported here.
    section("rules", function()
        local rule = Enum.GameRule.CraftFromBankRestricted
        if rule == nil then
            add("crafting from the bank: this client has no such rule")
        else
            add("crafting from the bank: restricted=" .. tostring(C_GameRules.IsGameRuleActive(rule)))
        end
    end)
end

-- /lp diag forever: a read-only dump of the client facts and of what this
-- adapter makes of them (documented in docs/development/TROUBLESHOOTING.md).
-- Each section runs under pcall so one failure prints "SECTION ERROR" and the
-- rest still prints. Numbers go through tostring (Forever's %d is 32-bit).
local function SortedSample(set, limit)
    local ids = {}
    for id in pairs(set) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for i = 1, math.min(limit, #ids) do out[i] = tostring(ids[i]) end
    return #ids, table.concat(out, ",")
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return table.concat(keys, ",")
end

-- The difficulty name the client would show for a recipe at this skill, from
-- CraftLib's thresholds (same bands as Utils.GetSkillColor; below yellow is
-- orange).
local function ExpectedDifficulty(skill, range)
    if skill < range.yellow then return "optimal" end
    if skill < range.green then return "medium" end
    if skill < range.gray then return "easy" end
    return "trivial"
end

-- "itemId x count" pairs, sorted, for comparing two reagent lists.
local function ReagentKey(pairsList)
    table.sort(pairsList)
    return table.concat(pairsList, ",")
end

-- Basic reagent slots of a client recipe schematic (the client's reagent
-- list: Blizzard_APIDocumentationGenerated/TradeSkillUITypesDocumentation.lua
-- CraftingRecipeSchematic / CraftingReagentSlotSchematic). Slots without an
-- item (currency) are left out.
local function ClientReagents(schematic)
    local list = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local first = slot.reagents and slot.reagents[1]
        if slot.reagentType == Enum.CraftingReagentType.Basic and first and first.itemID then
            list[#list + 1] = tostring(first.itemID) .. "x" .. tostring(slot.quantityRequired)
        end
    end
    return ReagentKey(list)
end

local function LibReagents(recipe)
    local list = {}
    for _, r in ipairs(recipe.reagents or {}) do
        if r.itemId then list[#list + 1] = tostring(r.itemId) .. "x" .. tostring(r.count) end
    end
    return ReagentKey(list)
end

-- /lp diag forever "check" lines: CraftLib's data for the open profession
-- against what the client itself says about each recipe both know:
--   difficulty  the client's difficulty at the current skill (learned recipes)
--               vs CraftLib's thresholds; a learned recipe below CraftLib's
--               orange level means that orange level is too high
--   gray        the client's maxTrivialLevel (TradeSkillRecipeInfo) vs gray
--   reagents    the schematic's basic reagents vs CraftLib's reagents
--   product     the schematic's output item vs CraftLib's itemId
-- Each line counts agreements and differences and samples the differences.
local function CheckAgainstCraftLib(profKey, prof, add)
    local byId = {}
    for _, r in ipairs(prof.recipes or {}) do byId[r.id] = r end
    local line = ProfessionInfo() or {}
    local modifier = line.skillModifier or 0
    local skill = (line.skillLevel or 0) + modifier

    local function tally() return { agree = 0, differ = {}, nDiffer = 0 } end
    local difficulty, gray, reagents, product = tally(), tally(), tally(), tally()
    local function count(t, same, sample)
        if same then t.agree = t.agree + 1 else t.nDiffer = t.nDiffer + 1; t.differ[sample] = true end
    end
    local compared, noClientGray, schematicErrors = 0, 0, 0

    for _, id in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
        local recipe = byId[id]
        local info = recipe and C_TradeSkillUI.GetRecipeInfo(id)
        if info then
            compared = compared + 1
            local range = recipe.skillRange
            local clientDifficulty = DIFFICULTY[info.relativeDifficulty]
            if range and info.learned and clientDifficulty then
                local mine = skill < range.orange and "belowOrange" or ExpectedDifficulty(skill, range)
                count(difficulty, mine == clientDifficulty, tostring(id) .. ":" .. clientDifficulty .. "/" .. mine)
            end
            if range then
                if info.maxTrivialLevel and info.maxTrivialLevel > 0 then
                    count(gray, info.maxTrivialLevel == range.gray,
                        tostring(id) .. ":" .. tostring(info.maxTrivialLevel) .. "/" .. tostring(range.gray))
                else
                    noClientGray = noClientGray + 1
                end
            end
            local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, id, false)
            if ok and schematic then
                count(reagents, ClientReagents(schematic) == LibReagents(recipe), tostring(id))
                if recipe.itemId and schematic.outputItemID and schematic.outputItemID > 0 then
                    count(product, schematic.outputItemID == recipe.itemId,
                        tostring(id) .. ":" .. tostring(schematic.outputItemID) .. "/" .. tostring(recipe.itemId))
                end
            else
                schematicErrors = schematicErrors + 1
            end
        end
    end

    local function sample(t) return select(2, SortedSample(t.differ, 10)) end
    add("check: " .. tostring(profKey) .. ", " .. tostring(compared)
        .. " recipes in both the client and CraftLib")
    add("check difficulty at skill " .. tostring(skill) .. " (+" .. tostring(modifier) .. "): agree="
        .. tostring(difficulty.agree) .. " differ=" .. tostring(difficulty.nDiffer)
        .. " sample(id:client/craftlib)=[" .. sample(difficulty) .. "]")
    add("check gray (client maxTrivialLevel): agree=" .. tostring(gray.agree) .. " differ="
        .. tostring(gray.nDiffer) .. " noClientValue=" .. tostring(noClientGray)
        .. " sample(id:client/craftlib)=[" .. sample(gray) .. "]")
    add("check reagents: agree=" .. tostring(reagents.agree) .. " differ=" .. tostring(reagents.nDiffer)
        .. " errors=" .. tostring(schematicErrors) .. " sample(id)=[" .. sample(reagents) .. "]")
    add("check product: agree=" .. tostring(product.agree) .. " differ=" .. tostring(product.nDiffer)
        .. " sample(id:client/craftlib)=[" .. sample(product) .. "]")
end

function Client:RunDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local function section(name, fn)
        local ok, err = pcall(fn)
        if not ok then add("SECTION ERROR: " .. name .. ": " .. tostring(err)) end
    end

    section("build", function()
        local version, build, _, interface = GetBuildInfo()
        add("diag forever: build=" .. tostring(version) .. " (" .. tostring(build) .. ") interface="
            .. tostring(interface) .. " WOW_PROJECT_ID=" .. tostring(WOW_PROJECT_ID)
            .. " WOW_PROJECT_CAMELOT=" .. tostring(WOW_PROJECT_CAMELOT)
            .. " family=" .. tostring(LazyProf.ClientFamily))
    end)

    if not self:IsOpen() then
        add("NOTE: the profession window is closed - open a profession for the profession, recipes and check lines.")
    end

    section("craftlib", function()
        local cl = _G.CraftLib
        if not cl then add("craftlib: absent"); return end
        add("craftlib: version=" .. tostring(C_AddOns.GetAddOnMetadata("CraftLib", "Version")) .. " profile="
            .. tostring(cl.GetActiveProfile and cl:GetActiveProfile())
            .. " ready=" .. tostring(cl.IsReady and cl:IsReady()))
        local count, recipeTotal, parts = 0, 0, {}
        for key, data in pairs(cl:GetProfessions() or {}) do
            count = count + 1
            local n = data.recipes and #data.recipes or 0
            recipeTotal = recipeTotal + n
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(n)
        end
        table.sort(parts)
        add("craftlib: professions=" .. tostring(count) .. " recipes=" .. tostring(recipeTotal)
            .. " [" .. table.concat(parts, " ") .. "]")
    end)

    section("window", function()
        add("window: IsOpen=" .. tostring(self:IsOpen())
            .. " ProfessionsFrame=" .. tostring(ProfessionsFrame ~= nil)
            .. " CraftingPageShown=" .. tostring(ProfessionsFrame ~= nil
                and ProfessionsFrame.CraftingPage ~= nil and ProfessionsFrame.CraftingPage:IsShown()))
        add("local crafting: linked=" .. tostring((C_TradeSkillUI.IsTradeSkillLinked()))
            .. " guild=" .. tostring(C_TradeSkillUI.IsTradeSkillGuild())
            .. " guildMember=" .. tostring(C_TradeSkillUI.IsTradeSkillGuildMember())
            .. " npc=" .. tostring(C_TradeSkillUI.IsNPCCrafting())
            .. " showsOwnList=" .. tostring(ShowsOwnList()))
    end)

    local profKey
    section("profession", function()
        local child = C_TradeSkillUI.GetChildProfessionInfo() or {}
        local base = C_TradeSkillUI.GetBaseProfessionInfo() or {}
        add("child: professionID=" .. tostring(child.professionID) .. " parentProfessionID="
            .. tostring(child.parentProfessionID) .. " skillLevel=" .. tostring(child.skillLevel)
            .. " maxSkillLevel=" .. tostring(child.maxSkillLevel)
            .. " skillModifier=" .. tostring(child.skillModifier))
        add("base: professionID=" .. tostring(base.professionID) .. " parentProfessionID="
            .. tostring(base.parentProfessionID) .. " skillLevel=" .. tostring(base.skillLevel)
            .. " maxSkillLevel=" .. tostring(base.maxSkillLevel)
            .. " skillModifier=" .. tostring(base.skillModifier))
        local key, skill, max = self:GetLine()
        profKey = key
        add("adapter GetLine: key=" .. tostring(key) .. " skill=" .. tostring(skill) .. "/" .. tostring(max))
        local registry = LazyProf.Professions and LazyProf.Professions.registry
        local prof = key and registry and registry[key]
        if prof then
            local ms = {}
            for i, m in ipairs(prof.milestones or {}) do ms[i] = tostring(m) end
            add("craftlib milestones: " .. table.concat(ms, ",") .. " (last = cap "
                .. tostring((prof.milestones or {})[#(prof.milestones or {})]) .. ")")
        else
            add("craftlib milestones: no registered profession for this line")
        end
    end)

    section("recipes", function()
        local ids = C_TradeSkillUI.GetAllRecipeIDs()
        if not ids then add("recipes: GetAllRecipeIDs returned nil"); return end
        local inClient, learned, matched = {}, 0, 0
        local registry = LazyProf.Professions and LazyProf.Professions.registry
        local prof = profKey and registry and registry[profKey]
        local inLib = {}
        if prof then
            for _, r in ipairs(prof.recipes) do inLib[r.id] = true end
        end
        for _, id in ipairs(ids) do
            inClient[id] = true
            local info = C_TradeSkillUI.GetRecipeInfo(id)
            if info and info.learned then learned = learned + 1 end
            if inLib[id] then matched = matched + 1 end
        end
        local missingLib, missingClient = {}, {}
        for id in pairs(inClient) do if not inLib[id] then missingLib[id] = true end end
        for id in pairs(inLib) do if not inClient[id] then missingClient[id] = true end end
        if not prof then
            add("recipes=" .. tostring(#ids) .. " learned=" .. tostring(learned)
                .. " (no open profession to compare with CraftLib)")
            return
        end
        add("recipes=" .. tostring(#ids) .. " learned=" .. tostring(learned)
            .. " craftlibMatched=" .. tostring(matched) .. " craftlibRecipes=" .. tostring(#prof.recipes))
        local n, sample = SortedSample(missingLib, 10)
        add("notInCraftLib=" .. tostring(n) .. " sample=[" .. sample .. "]")
        n, sample = SortedSample(missingClient, 10)
        add("notInClient=" .. tostring(n) .. " sample=[" .. sample .. "]")
    end)

    section("check", function()
        local registry = LazyProf.Professions and LazyProf.Professions.registry
        local prof = profKey and registry and registry[profKey]
        if not self:IsOpen() then return end   -- the NOTE line above says why
        if not prof then
            add("check: skipped - no profession of yours with recipe data is shown (another player's, guild or NPC list, or no data)")
            return
        end
        CheckAgainstCraftLib(profKey, prof, add)
    end)

    section("filters", function()
        add("filters: GetShowLearned=" .. tostring(C_TradeSkillUI.GetShowLearned())
            .. " GetShowUnlearned=" .. tostring(C_TradeSkillUI.GetShowUnlearned())
            .. " UnlearnedHiddenByFilter=" .. tostring(self:UnlearnedHiddenByFilter()))
    end)

    section("scrollbox", function()
        local box = ProfessionsFrame and ProfessionsFrame.CraftingPage
            and ProfessionsFrame.CraftingPage.RecipeList and ProfessionsFrame.CraftingPage.RecipeList.ScrollBox
        if not box then add("scrollbox: absent"); return end
        local count, firstKeys = 0, nil
        for _, frame in box:EnumerateFrames() do
            count = count + 1
            if not firstKeys then
                local node = frame:GetElementData()
                firstKeys = node and node.data and SortedKeys(node.data) or "no data"
            end
        end
        add("scrollbox: present visibleFrames=" .. tostring(count)
            .. " firstFrameDataKeys=" .. tostring(firstKeys))
    end)

    section("path", function()
        local path = LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath
        if not path then add("path: none"); return end
        add("path: steps=" .. tostring(#(path.steps or {})) .. " complete=" .. tostring(path.complete)
            .. " gaps=" .. tostring(#(path.gaps or {})))
    end)
end
