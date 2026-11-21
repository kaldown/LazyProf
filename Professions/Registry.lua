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

-- Detect current profession from the open profession window
function Professions:DetectActive()
    if not LazyProf.Client:IsOpen() then
        self.active = nil
        return nil
    end

    -- Registered profession key for the window's line (nil when none matches)
    self.active = LazyProf.Client:GetLine()
    return self.active
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

    -- Known recipe spell ids from the open profession window (the client
    -- adapter resolves each visible row to its spell id).
    local knownSpellIds = LazyProf.Client:KnownRecipeIds(profName)

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
