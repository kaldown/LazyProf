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

-- The player's rank in a profession, read from the skill-line list (works with
-- the profession window closed). 0 when not trained or unknown.
function Client:PlayerSkill(profKey)
    local profInfo = LazyProf.Constants.PROFESSIONS[profKey]
    if not profInfo then return 0 end

    local targetName = profInfo.name:lower()

    -- Classic/TBC uses GetSkillLineInfo instead of GetProfessions
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank = GetSkillLineInfo(i)
        if not isHeader and skillName and skillName:lower() == targetName then
            return skillRank or 0
        end
    end

    return 0
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
-- learned recipes only), so the milestone panel's hidden-recipe hint, which
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
