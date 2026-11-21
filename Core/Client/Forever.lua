-- Core/Client/Forever.lua
-- WoW Forever implementation of LazyProf.Client: the one place that talks to
-- that client's profession window (ProfessionsFrame + C_TradeSkillUI), its
-- spell-book profession list and C_Item. Forever plays like Classic but runs
-- the retail engine, so none of the Classic trade-skill globals exist there.
--
-- Facts below cite Blizzard's UI source for this client (1.60.1 build 70938,
-- paths under Interface/AddOns/) or the dump of the running client's globals
-- (GlobalAPI.lua / Events.lua / LuaEnum.lua). Ones that could not be settled
-- from source are listed for an in-game check where they are used.
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

function Client:PlayerSkill(profKey)
    local skillLine
    for line, key in pairs(LazyProf.Constants.SKILL_LINE_PROFESSION) do
        if key == profKey then skillLine = line end
    end
    if not skillLine then return 0 end

    local count, indices = ProfessionIndices(GetProfessions())
    for i = 1, count do
        local index = indices[i]
        if index then
            local _, _, rank, _, _, _, line = GetProfessionInfo(index)
            if line == skillLine then
                return rank or 0
            end
        end
    end
    return 0
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
-- unlearned next recipe, so the milestone panel says so instead.
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
-- current path (the milestone panel's hint depends on it; nothing to
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

    section("craftlib", function()
        local cl = _G.CraftLib
        if not cl then add("craftlib: absent"); return end
        add("craftlib: version=" .. tostring(cl.version or cl.VERSION) .. " profile="
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
        add("recipes=" .. tostring(#ids) .. " learned=" .. tostring(learned)
            .. " craftlibMatched=" .. tostring(matched) .. " craftlibRecipes=" .. tostring(prof and #prof.recipes or "n/a"))
        local n, sample = SortedSample(missingLib, 10)
        add("notInCraftLib=" .. tostring(n) .. " sample=[" .. sample .. "]")
        n, sample = SortedSample(missingClient, 10)
        add("notInClient=" .. tostring(n) .. " sample=[" .. sample .. "]")
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
