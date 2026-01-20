-- Libs/CraftDB/Data/FirstAid.lua
-- First Aid recipes for TBC Classic (includes Vanilla recipes)
local CraftDB = LibStub("CraftDB")
local C = CraftDB.Constants

local recipes = {
    -- Linen Bandage (Vanilla)
    {
        id = 3275,
        name = "Linen Bandage",
        itemId = 1251,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 30, green = 45, gray = 55 },
        reagents = {
            { itemId = 2589, name = "Linen Cloth", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Heavy Linen Bandage (Vanilla)
    {
        id = 3276,
        name = "Heavy Linen Bandage",
        itemId = 2581,
        skillRequired = 40,
        skillRange = { orange = 40, yellow = 50, green = 75, gray = 90 },
        reagents = {
            { itemId = 2589, name = "Linen Cloth", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Wool Bandage (Vanilla)
    {
        id = 3277,
        name = "Wool Bandage",
        itemId = 3530,
        skillRequired = 80,
        skillRange = { orange = 80, yellow = 95, green = 130, gray = 150 },
        reagents = {
            { itemId = 2592, name = "Wool Cloth", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Heavy Wool Bandage (Vanilla)
    {
        id = 3278,
        name = "Heavy Wool Bandage",
        itemId = 3531,
        skillRequired = 115,
        skillRange = { orange = 115, yellow = 130, green = 150, gray = 170 },
        reagents = {
            { itemId = 2592, name = "Wool Cloth", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Silk Bandage (Vanilla)
    {
        id = 7928,
        name = "Silk Bandage",
        itemId = 6450,
        skillRequired = 150,
        skillRange = { orange = 150, yellow = 165, green = 180, gray = 195 },
        reagents = {
            { itemId = 4306, name = "Silk Cloth", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Heavy Silk Bandage (Vanilla)
    {
        id = 7929,
        name = "Heavy Silk Bandage",
        itemId = 6451,
        skillRequired = 180,
        skillRange = { orange = 180, yellow = 195, green = 210, gray = 225 },
        reagents = {
            { itemId = 4306, name = "Silk Cloth", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Mageweave Bandage (Vanilla)
    {
        id = 10840,
        name = "Mageweave Bandage",
        itemId = 8544,
        skillRequired = 210,
        skillRange = { orange = 210, yellow = 225, green = 240, gray = 255 },
        reagents = {
            { itemId = 4338, name = "Mageweave Cloth", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Heavy Mageweave Bandage (Vanilla)
    {
        id = 10841,
        name = "Heavy Mageweave Bandage",
        itemId = 8545,
        skillRequired = 240,
        skillRange = { orange = 240, yellow = 255, green = 270, gray = 285 },
        reagents = {
            { itemId = 4338, name = "Mageweave Cloth", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Runecloth Bandage (Vanilla)
    {
        id = 18629,
        name = "Runecloth Bandage",
        itemId = 14529,
        skillRequired = 260,
        skillRange = { orange = 260, yellow = 275, green = 290, gray = 305 },
        reagents = {
            { itemId = 14047, name = "Runecloth", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Heavy Runecloth Bandage (Vanilla)
    {
        id = 18630,
        name = "Heavy Runecloth Bandage",
        itemId = 14530,
        skillRequired = 290,
        skillRange = { orange = 290, yellow = 300, green = 325, gray = 340 },
        reagents = {
            { itemId = 14047, name = "Runecloth", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Netherweave Bandage (TBC)
    {
        id = 27032,
        name = "Netherweave Bandage",
        itemId = 21990,
        skillRequired = 300,
        skillRange = { orange = 300, yellow = 330, green = 345, gray = 360 },
        reagents = {
            { itemId = 21877, name = "Netherweave Cloth", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.TBC,
    },
    -- Heavy Netherweave Bandage (TBC)
    {
        id = 27033,
        name = "Heavy Netherweave Bandage",
        itemId = 21991,
        skillRequired = 330,
        skillRange = { orange = 330, yellow = 345, green = 360, gray = 375 },
        reagents = {
            { itemId = 21877, name = "Netherweave Cloth", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.TBC,
    },
}

-- Register with CraftDB
CraftDB:RegisterProfession("firstAid", {
    id = C.PROFESSION_ID.FIRST_AID,
    name = "First Aid",
    expansion = C.EXPANSION.TBC,
    milestones = { 75, 150, 225, 300, 375 },
    recipes = recipes,
})
