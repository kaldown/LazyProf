-- Professions/Registry.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Professions = {}
local Professions = LazyProf.Professions

-- Registered profession data (populated from CraftLib)
Professions.registry = {}

-- Current active profession (detected from open window)
Professions.active = nil

-- Initialize registry from CraftLib
function Professions:Initialize()
    local CraftLib = _G.CraftLib
    if not CraftLib or not CraftLib:IsReady() then
        return
    end

    -- Skip if already initialized
    if next(self.registry) ~= nil then
        return
    end

    -- Load all professions from CraftLib
    for key, data in pairs(CraftLib:GetProfessions()) do
        self.registry[key] = {
            id = data.id,
            name = data.name,
            milestones = data.milestones,
            recipes = data.recipes,
        }
    end
end

-- Register a profession module (for local overrides/additions)
function Professions:Register(name, data)
    if self.registry[name] then
        LazyProf:Debug("professions", "Profession already registered: " .. name)
        return
    end

    -- Validate required fields
    assert(data.id, "Profession must have id")
    assert(data.name, "Profession must have name")
    assert(data.milestones, "Profession must have milestones")
    assert(data.recipes, "Profession must have recipes")

    self.registry[name] = {
        id = data.id,
        name = data.name,
        milestones = data.milestones,
        recipes = data.recipes,
        -- Optional hooks for special professions
        onCraft = data.onCraft,
        specializations = data.specializations,
    }

    LazyProf:Debug("professions", "Registered profession: " .. name)
end

-- Auto-initialize from CraftLib on load (skip if dependency check failed)
if not LazyProf.dependencyCheckFailed then
    Professions:Initialize()
end

-- Get profession by internal name
function Professions:Get(name)
    return self.registry[name]
end

-- Detect current profession from TradeSkill window
function Professions:DetectActive()
    if not TradeSkillFrame or not TradeSkillFrame:IsVisible() then
        self.active = nil
        return nil
    end

    local skillName = GetTradeSkillLine()
    if not skillName then
        self.active = nil
        return nil
    end

    -- Find matching registered profession
    for name, data in pairs(self.registry) do
        if data.name == skillName then
            self.active = name
            return name
        end
    end

    self.active = nil
    return nil
end

-- Get active profession data
function Professions:GetActive()
    -- Always detect fresh - profession window may have changed
    self:DetectActive()
    return self.active and self.registry[self.active] or nil
end

-- Get all reagent item IDs across all registered professions
function Professions:GetAllReagentIds()
    local reagentIds = {}
    local seen = {}

    for _, profData in pairs(self.registry) do
        for _, recipe in ipairs(profData.recipes) do
            for _, reagent in ipairs(recipe.reagents) do
                if not seen[reagent.itemId] then
                    seen[reagent.itemId] = true
                    table.insert(reagentIds, reagent.itemId)
                end
            end
        end
    end

    return reagentIds
end

-- Get recipes with learned status from WoW API
function Professions:GetRecipesWithLearnedStatus(profName)
    local profData = self:Get(profName)
    if not profData then return {} end

    -- Reverse indexes from this profession's CraftLib recipes, so a visible
    -- trade-skill row can be mapped to its spell id (recipe.id) even when the
    -- client's recipe-link API is unavailable. Scoped to the active profession to
    -- avoid cross-profession item/name collisions.
    local idByItemId = {}   -- crafted-item id -> recipe spell id
    local idByName = {}     -- recipe name      -> recipe spell id
    for _, recipe in ipairs(profData.recipes) do
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

    -- Cache learned recipes for planning mode
    if profName and next(knownSpellIds) then
        LazyProf.db.char.learnedRecipes = LazyProf.db.char.learnedRecipes or {}
        LazyProf.db.char.learnedRecipes[profName] = knownSpellIds
    end

    -- Merge with our recipe data
    local recipes = LazyProf.Utils.DeepCopy(profData.recipes)
    for _, recipe in ipairs(recipes) do
        recipe.learned = knownSpellIds[recipe.id] or false
    end

    return recipes
end
