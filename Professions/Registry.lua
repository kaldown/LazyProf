-- Professions/Registry.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Professions = {}
local Professions = LazyProf.Professions

-- Registered profession data
Professions.registry = {}

-- Current active profession (detected from open window)
Professions.active = nil

-- Register a profession module
function Professions:Register(name, data)
    if self.registry[name] then
        if LazyProf.Debug then LazyProf:Debug("Profession already registered: " .. name) end
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

    if LazyProf.Debug then LazyProf:Debug("Registered profession: " .. name) end
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
    if not self.active then
        self:DetectActive()
    end
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

    -- Get list of known recipe spell IDs from TradeSkill window
    local knownSpellIds = {}
    local numSkills = GetNumTradeSkills()
    for i = 1, numSkills do
        local skillName, skillType, _, _, _, _ = GetTradeSkillInfo(i)
        if skillType ~= "header" then
            local link = GetTradeSkillRecipeLink(i)
            if link then
                local spellId = tonumber(link:match("enchant:(%d+)") or link:match("spell:(%d+)"))
                if spellId then
                    knownSpellIds[spellId] = true
                end
            end
        end
    end

    -- Merge with our recipe data
    local recipes = LazyProf.Utils.DeepCopy(profData.recipes)
    for _, recipe in ipairs(recipes) do
        recipe.learned = knownSpellIds[recipe.id] or false
    end

    return recipes
end
