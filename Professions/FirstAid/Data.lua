-- Professions/FirstAid/Data.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

-- First Aid recipe database
-- Skill ranges: orange (100%), yellow (50%), green (25%), gray (0%)
-- Note: Algorithm considers green recipes if they're cheaper per skillup overall
local FirstAidRecipes = {
    -- Linen Bandage
    {
        id = 3275,
        name = "Linen Bandage",
        itemId = 1251,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 30, green = 45, gray = 55 },
        reagents = {
            { itemId = 2589, count = 1 }, -- Linen Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Heavy Linen Bandage
    {
        id = 3276,
        name = "Heavy Linen Bandage",
        itemId = 2581,
        skillRequired = 40,
        skillRange = { orange = 40, yellow = 50, green = 75, gray = 90 },
        reagents = {
            { itemId = 2589, count = 2 }, -- Linen Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Wool Bandage
    {
        id = 3277,
        name = "Wool Bandage",
        itemId = 3530,
        skillRequired = 80,
        skillRange = { orange = 80, yellow = 95, green = 130, gray = 150 },
        reagents = {
            { itemId = 2592, count = 1 }, -- Wool Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Heavy Wool Bandage
    {
        id = 3278,
        name = "Heavy Wool Bandage",
        itemId = 3531,
        skillRequired = 115,
        skillRange = { orange = 115, yellow = 130, green = 150, gray = 170 },
        reagents = {
            { itemId = 2592, count = 2 }, -- Wool Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Silk Bandage
    {
        id = 7928,
        name = "Silk Bandage",
        itemId = 6450,
        skillRequired = 150,
        skillRange = { orange = 150, yellow = 165, green = 180, gray = 195 },
        reagents = {
            { itemId = 4306, count = 1 }, -- Silk Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Heavy Silk Bandage
    {
        id = 7929,
        name = "Heavy Silk Bandage",
        itemId = 6451,
        skillRequired = 180,
        skillRange = { orange = 180, yellow = 195, green = 210, gray = 225 },
        reagents = {
            { itemId = 4306, count = 2 }, -- Silk Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Mageweave Bandage
    {
        id = 10840,
        name = "Mageweave Bandage",
        itemId = 8544,
        skillRequired = 210,
        skillRange = { orange = 210, yellow = 225, green = 240, gray = 255 },
        reagents = {
            { itemId = 4338, count = 1 }, -- Mageweave Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Heavy Mageweave Bandage
    {
        id = 10841,
        name = "Heavy Mageweave Bandage",
        itemId = 8545,
        skillRequired = 240,
        skillRange = { orange = 240, yellow = 255, green = 270, gray = 285 },
        reagents = {
            { itemId = 4338, count = 2 }, -- Mageweave Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Runecloth Bandage
    {
        id = 18629,
        name = "Runecloth Bandage",
        itemId = 14529,
        skillRequired = 260,
        skillRange = { orange = 260, yellow = 275, green = 290, gray = 305 },
        reagents = {
            { itemId = 14047, count = 1 }, -- Runecloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Heavy Runecloth Bandage
    {
        id = 18630,
        name = "Heavy Runecloth Bandage",
        itemId = 14530,
        skillRequired = 290,
        skillRange = { orange = 290, yellow = 300, green = 325, gray = 340 },
        reagents = {
            { itemId = 14047, count = 2 }, -- Runecloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Any Trainer" },
    },
    -- Netherweave Bandage (TBC)
    {
        id = 27032,
        name = "Netherweave Bandage",
        itemId = 21990,
        skillRequired = 300,
        skillRange = { orange = 300, yellow = 330, green = 345, gray = 360 },
        reagents = {
            { itemId = 21877, count = 1 }, -- Netherweave Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Outland Trainer" },
    },
    -- Heavy Netherweave Bandage (TBC)
    {
        id = 27033,
        name = "Heavy Netherweave Bandage",
        itemId = 21991,
        skillRequired = 330,
        skillRange = { orange = 330, yellow = 345, green = 360, gray = 375 },
        reagents = {
            { itemId = 21877, count = 2 }, -- Netherweave Cloth
        },
        source = { type = Constants.SOURCE_TYPE.TRAINER, location = "Outland Trainer" },
    },
}

-- Register First Aid profession
LazyProf.Professions:Register("firstAid", {
    id = 3273,
    name = "First Aid",
    milestones = { 75, 150, 225, 300, 375 },
    recipes = FirstAidRecipes,
})
