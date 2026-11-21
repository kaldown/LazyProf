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

-- Current profession line: profession key (nil when no registered profession
-- matches), skill level and max skill level. The line is the parent when there
-- is one (Professions.GetEffectiveSkillLineID,
-- Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:1678-1681).
function Client:GetLine()
    local info = ProfessionInfo()
    local skillLine = info.parentProfessionID or info.professionID
    return ProfKeyForSkillLine(skillLine), info.skillLevel, info.maxSkillLevel
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

-- Re-point the arrow after the list scrolls or its visible range changes.
-- OnScroll fires on scrolling (Blizzard_SharedXML/Shared/Scroll/ScrollBox.lua:277);
-- OnDataRangeChanged when the visible range or the data changes - rebuilt,
-- sorted, resized or replaced data invalidates the range (ScrollBox.lua:789-793;
-- ScrollBoxListView.lua:697-699, same folder). Callbacks get (owner, ...)
-- (Blizzard_SharedXMLBase/CallbackRegistry.lua:112-139, 206-213).
-- The professions UI loads on demand on the first TRADE_SKILL_SHOW
-- (Blizzard_Game/Mainline/EventImplementation.lua:475-477,
-- Blizzard_Professions/Blizzard_Professions_Bootstrap.lua:3-11), so this runs
-- from the event handlers until the frame exists, then once.
local scrollHooked = false
local scrollToken = 0
local function HookScroll(callbacks)
    if scrollHooked or not ProfessionsFrame then return end

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
    scrollHooked = true
end

-- Register the profession-window events (Events.lua:1890-1902) and the list
-- callbacks. callbacks: onOpen(), onClose(), onUpdate(), onScroll().
-- A list update that arrives while the data source is still changing is
-- skipped and the next one is used, as Blizzard's own frame does
-- (Blizzard_Professions/Blizzard_ProfessionsFrame.lua:148-154).
-- Verify in game: TRADE_SKILL_LIST_UPDATE fires after a skill-up.
function Client:Start(callbacks)
    LazyProf:RegisterEvent("TRADE_SKILL_SHOW", function()
        HookScroll(callbacks)
        callbacks.onOpen()
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
        HookScroll(callbacks)
        if C_TradeSkillUI.IsDataSourceChanging() then return end
        callbacks.onUpdate()
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", function()
        HookScroll(callbacks)
        callbacks.onUpdate()
    end)
    LazyProf:RegisterEvent("TRADE_SKILL_CLOSE", function()
        callbacks.onClose()
    end)
end

-- /lp diag learned on Forever. The Forever dump comes with the diagnostic
-- command for this client; until then one line says so.
function Client:RunDiagnostic(lines)
    lines[#lines + 1] = "diag learned: WoW Forever client - this diagnostic is not available here yet."
end
