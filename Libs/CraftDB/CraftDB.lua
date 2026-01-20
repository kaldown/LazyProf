-- Libs/CraftDB/CraftDB.lua
-- Embedded CraftDB library for LazyProf
-- Source: https://github.com/kaldown/CraftDB

local MAJOR, MINOR = "CraftDB", 1
local CraftDB = LibStub:NewLibrary(MAJOR, MINOR)
if not CraftDB then return end

-- Version info
CraftDB.version = "0.1.0"
CraftDB.dataVersion = 1

-- Internal storage
CraftDB.professions = {}
CraftDB.items = {}

-- Constants
CraftDB.Constants = {
    -- Game expansions
    EXPANSION = {
        VANILLA = 1,
        TBC = 2,
        WOTLK = 3,
        CATA = 4,
        MOP = 5,
        WOD = 6,
        LEGION = 7,
        BFA = 8,
        SHADOWLANDS = 9,
        DRAGONFLIGHT = 10,
        TWW = 11,
    },

    -- Recipe source types
    SOURCE_TYPE = {
        TRAINER = "trainer",
        VENDOR = "vendor",
        DROP = "drop",
        REPUTATION = "reputation",
        QUEST = "quest",
        DISCOVERY = "discovery",
        WORLD_DROP = "world_drop",
    },

    -- Profession IDs (spell IDs)
    PROFESSION_ID = {
        -- Primary
        ALCHEMY = 2259,
        BLACKSMITHING = 2018,
        ENCHANTING = 7411,
        ENGINEERING = 4036,
        HERBALISM = 2366,
        JEWELCRAFTING = 25229,
        LEATHERWORKING = 2108,
        MINING = 2575,
        SKINNING = 8613,
        TAILORING = 3908,
        -- Secondary
        COOKING = 2550,
        FIRST_AID = 3273,
        FISHING = 7620,
    },

    -- Skill difficulty colors
    DIFFICULTY = {
        ORANGE = "orange",
        YELLOW = "yellow",
        GREEN = "green",
        GRAY = "gray",
    },
}

--------------------------------------------------------------------------------
-- Profession Registration API
--------------------------------------------------------------------------------

function CraftDB:RegisterProfession(professionKey, data)
    if self.professions[professionKey] then
        local existing = self.professions[professionKey]
        for _, recipe in ipairs(data.recipes or {}) do
            table.insert(existing.recipes, recipe)
        end
    else
        self.professions[professionKey] = {
            id = data.id,
            name = data.name,
            expansion = data.expansion,
            milestones = data.milestones or {},
            recipes = data.recipes or {},
        }
    end

    for _, recipe in ipairs(data.recipes or {}) do
        if recipe.itemId then
            self.items[recipe.itemId] = recipe
        end
    end
end

--------------------------------------------------------------------------------
-- Query API
--------------------------------------------------------------------------------

function CraftDB:GetProfessions()
    return self.professions
end

function CraftDB:GetProfession(professionKey)
    return self.professions[professionKey]
end

function CraftDB:GetRecipes(professionKey)
    local profession = self.professions[professionKey]
    return profession and profession.recipes or {}
end

function CraftDB:GetAvailableRecipes(professionKey, skillLevel)
    local recipes = self:GetRecipes(professionKey)
    local available = {}

    for _, recipe in ipairs(recipes) do
        if recipe.skillRequired <= skillLevel then
            table.insert(available, recipe)
        end
    end

    return available
end

function CraftDB:GetRecipeBySpellId(professionKey, spellId)
    local recipes = self:GetRecipes(professionKey)

    for _, recipe in ipairs(recipes) do
        if recipe.id == spellId then
            return recipe
        end
    end

    return nil
end

function CraftDB:GetRecipeByItemId(itemId)
    return self.items[itemId]
end

function CraftDB:GetRecipeDifficulty(recipe, skillLevel)
    local range = recipe.skillRange
    if not range then return "gray" end

    if skillLevel < range.yellow then
        return "orange"
    elseif skillLevel < range.green then
        return "yellow"
    elseif skillLevel < range.gray then
        return "green"
    else
        return "gray"
    end
end

function CraftDB:IsReady()
    return next(self.professions) ~= nil
end
