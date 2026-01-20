-- Libs/CraftDB/Data/Cooking.lua
-- Cooking recipes for TBC Classic (includes Vanilla recipes)
-- Sources: wowhead.com/tbc, wow-professions.com
local CraftDB = LibStub("CraftDB")
local C = CraftDB.Constants

local recipes = {
    --------------------------------------------------------------------------------
    -- Apprentice (1-75)
    --------------------------------------------------------------------------------

    -- Charred Wolf Meat (1)
    {
        id = 2538,
        name = "Charred Wolf Meat",
        itemId = 2679,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 45, green = 65, gray = 85 },
        reagents = {
            { itemId = 2672, name = "Stringy Wolf Meat", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Roasted Boar Meat (1)
    {
        id = 2540,
        name = "Roasted Boar Meat",
        itemId = 2681,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 45, green = 65, gray = 85 },
        reagents = {
            { itemId = 2673, name = "Chunk of Boar Meat", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Spice Bread (1)
    {
        id = 37836,
        name = "Spice Bread",
        itemId = 30817,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 15, green = 35, gray = 55 },
        reagents = {
            { itemId = 30817, name = "Simple Flour", count = 1 },
            { itemId = 2678, name = "Mild Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.TBC,
    },
    -- Herb Baked Egg (1)
    {
        id = 8604,
        name = "Herb Baked Egg",
        itemId = 6888,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 45, green = 65, gray = 85 },
        reagents = {
            { itemId = 6889, name = "Small Egg", count = 1 },
            { itemId = 2678, name = "Mild Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Brilliant Smallfish (1)
    {
        id = 7751,
        name = "Brilliant Smallfish",
        itemId = 6290,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 45, green = 65, gray = 85 },
        reagents = {
            { itemId = 6291, name = "Raw Brilliant Smallfish", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Slitherskin Mackerel (1)
    {
        id = 7752,
        name = "Slitherskin Mackerel",
        itemId = 787,
        skillRequired = 1,
        skillRange = { orange = 1, yellow = 45, green = 65, gray = 85 },
        reagents = {
            { itemId = 6303, name = "Raw Slitherskin Mackerel", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Smoked Bear Meat (40)
    {
        id = 2541,
        name = "Smoked Bear Meat",
        itemId = 2680,
        skillRequired = 40,
        skillRange = { orange = 40, yellow = 80, green = 100, gray = 120 },
        reagents = {
            { itemId = 3173, name = "Bear Meat", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Longjaw Mud Snapper (50)
    {
        id = 7753,
        name = "Longjaw Mud Snapper",
        itemId = 4592,
        skillRequired = 50,
        skillRange = { orange = 50, yellow = 90, green = 110, gray = 130 },
        reagents = {
            { itemId = 6289, name = "Raw Longjaw Mud Snapper", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },

    --------------------------------------------------------------------------------
    -- Journeyman (75-150)
    --------------------------------------------------------------------------------

    -- Boiled Clams (50)
    {
        id = 6499,
        name = "Boiled Clams",
        itemId = 5525,
        skillRequired = 50,
        skillRange = { orange = 50, yellow = 90, green = 110, gray = 130 },
        reagents = {
            { itemId = 5503, name = "Clam Meat", count = 1 },
            { itemId = 159, name = "Refreshing Spring Water", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Crab Cake (75)
    {
        id = 2542,
        name = "Crab Cake",
        itemId = 2682,
        skillRequired = 75,
        skillRange = { orange = 75, yellow = 115, green = 135, gray = 155 },
        reagents = {
            { itemId = 2674, name = "Crawler Meat", count = 1 },
            { itemId = 2678, name = "Mild Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Bristle Whisker Catfish (100)
    {
        id = 7755,
        name = "Bristle Whisker Catfish",
        itemId = 4593,
        skillRequired = 100,
        skillRange = { orange = 100, yellow = 140, green = 160, gray = 180 },
        reagents = {
            { itemId = 6308, name = "Raw Bristle Whisker Catfish", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Seasoned Wolf Kabob (100)
    {
        id = 6500,
        name = "Seasoned Wolf Kabob",
        itemId = 5527,
        skillRequired = 100,
        skillRange = { orange = 100, yellow = 140, green = 160, gray = 180 },
        reagents = {
            { itemId = 5471, name = "Lean Wolf Flank", count = 2 },
            { itemId = 2665, name = "Stormwind Seasoning Herbs", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.QUEST },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Dry Pork Ribs (80)
    {
        id = 2546,
        name = "Dry Pork Ribs",
        itemId = 2687,
        skillRequired = 80,
        skillRange = { orange = 80, yellow = 120, green = 140, gray = 160 },
        reagents = {
            { itemId = 2677, name = "Boar Ribs", count = 1 },
            { itemId = 2678, name = "Mild Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Hot Lion Chops (125)
    {
        id = 3397,
        name = "Hot Lion Chops",
        itemId = 3220,
        skillRequired = 125,
        skillRange = { orange = 125, yellow = 175, green = 195, gray = 215 },
        reagents = {
            { itemId = 3731, name = "Lion Meat", count = 1 },
            { itemId = 2692, name = "Hot Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Curiously Tasty Omelet (130)
    {
        id = 3376,
        name = "Curiously Tasty Omelet",
        itemId = 3665,
        skillRequired = 130,
        skillRange = { orange = 130, yellow = 170, green = 190, gray = 210 },
        reagents = {
            { itemId = 3685, name = "Raptor Egg", count = 1 },
            { itemId = 2692, name = "Hot Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },

    --------------------------------------------------------------------------------
    -- Expert (150-225)
    --------------------------------------------------------------------------------

    -- Roast Raptor (175)
    {
        id = 3400,
        name = "Roast Raptor",
        itemId = 3726,
        skillRequired = 175,
        skillRange = { orange = 175, yellow = 215, green = 235, gray = 255 },
        reagents = {
            { itemId = 3404, name = "Raptor Flesh", count = 1 },
            { itemId = 2692, name = "Hot Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Mithril Head Trout (175)
    {
        id = 20916,
        name = "Mithril Head Trout",
        itemId = 8364,
        skillRequired = 175,
        skillRange = { orange = 175, yellow = 215, green = 235, gray = 255 },
        reagents = {
            { itemId = 8365, name = "Raw Mithril Head Trout", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Spider Sausage (200)
    {
        id = 21175,
        name = "Spider Sausage",
        itemId = 17222,
        skillRequired = 200,
        skillRange = { orange = 200, yellow = 240, green = 260, gray = 280 },
        reagents = {
            { itemId = 2251, name = "Crunchy Spider Leg", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.TRAINER },
        expansion = C.EXPANSION.VANILLA,
    },

    --------------------------------------------------------------------------------
    -- Artisan (225-300)
    --------------------------------------------------------------------------------

    -- Spotted Yellowtail (225)
    {
        id = 18238,
        name = "Spotted Yellowtail",
        itemId = 6887,
        skillRequired = 225,
        skillRange = { orange = 225, yellow = 265, green = 285, gray = 305 },
        reagents = {
            { itemId = 4603, name = "Raw Spotted Yellowtail", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Monster Omelet (225)
    {
        id = 15933,
        name = "Monster Omelet",
        itemId = 12218,
        skillRequired = 225,
        skillRange = { orange = 225, yellow = 265, green = 285, gray = 305 },
        reagents = {
            { itemId = 12207, name = "Giant Egg", count = 1 },
            { itemId = 3713, name = "Soothing Spices", count = 2 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Tender Wolf Steak (225)
    {
        id = 22480,
        name = "Tender Wolf Steak",
        itemId = 18045,
        skillRequired = 225,
        skillRange = { orange = 225, yellow = 265, green = 285, gray = 305 },
        reagents = {
            { itemId = 12208, name = "Tender Wolf Meat", count = 1 },
            { itemId = 3713, name = "Soothing Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Mightfish Steak (275)
    {
        id = 18246,
        name = "Mightfish Steak",
        itemId = 13934,
        skillRequired = 275,
        skillRange = { orange = 275, yellow = 300, green = 312, gray = 325 },
        reagents = {
            { itemId = 13893, name = "Large Raw Mightfish", count = 1 },
            { itemId = 2692, name = "Hot Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },
    -- Baked Salmon (275)
    {
        id = 18247,
        name = "Baked Salmon",
        itemId = 13935,
        skillRequired = 275,
        skillRange = { orange = 275, yellow = 300, green = 312, gray = 325 },
        reagents = {
            { itemId = 13889, name = "Raw Whitescale Salmon", count = 1 },
            { itemId = 3713, name = "Soothing Spices", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.VANILLA,
    },

    --------------------------------------------------------------------------------
    -- Master (300-375) - TBC
    --------------------------------------------------------------------------------

    -- Ravager Dog (300)
    {
        id = 33284,
        name = "Ravager Dog",
        itemId = 27687,
        skillRequired = 300,
        skillRange = { orange = 300, yellow = 320, green = 340, gray = 360 },
        reagents = {
            { itemId = 27674, name = "Ravager Flesh", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Buzzard Bites (300)
    {
        id = 33279,
        name = "Buzzard Bites",
        itemId = 27651,
        skillRequired = 300,
        skillRange = { orange = 300, yellow = 320, green = 340, gray = 360 },
        reagents = {
            { itemId = 27671, name = "Buzzard Meat", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Blackened Trout (300)
    {
        id = 33290,
        name = "Blackened Trout",
        itemId = 27694,
        skillRequired = 300,
        skillRange = { orange = 300, yellow = 320, green = 340, gray = 360 },
        reagents = {
            { itemId = 27422, name = "Barbed Gill Trout", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Feltail Delight (300)
    {
        id = 33291,
        name = "Feltail Delight",
        itemId = 27695,
        skillRequired = 300,
        skillRange = { orange = 300, yellow = 320, green = 340, gray = 360 },
        reagents = {
            { itemId = 27425, name = "Spotted Feltail", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Talbuk Steak (325)
    {
        id = 33289,
        name = "Talbuk Steak",
        itemId = 27693,
        skillRequired = 325,
        skillRange = { orange = 325, yellow = 345, green = 355, gray = 365 },
        reagents = {
            { itemId = 27678, name = "Talbuk Venison", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Roasted Clefthoof (325)
    {
        id = 33287,
        name = "Roasted Clefthoof",
        itemId = 27691,
        skillRequired = 325,
        skillRange = { orange = 325, yellow = 345, green = 355, gray = 365 },
        reagents = {
            { itemId = 27677, name = "Clefthoof Meat", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Warp Burger (325)
    {
        id = 33288,
        name = "Warp Burger",
        itemId = 27692,
        skillRequired = 325,
        skillRange = { orange = 325, yellow = 345, green = 355, gray = 365 },
        reagents = {
            { itemId = 27681, name = "Warped Flesh", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Golden Fish Sticks (325)
    {
        id = 33295,
        name = "Golden Fish Sticks",
        itemId = 27699,
        skillRequired = 325,
        skillRange = { orange = 325, yellow = 345, green = 355, gray = 365 },
        reagents = {
            { itemId = 27438, name = "Golden Darter", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
    -- Crunchy Serpent (335)
    {
        id = 33293,
        name = "Crunchy Serpent",
        itemId = 27697,
        skillRequired = 335,
        skillRange = { orange = 335, yellow = 355, green = 365, gray = 375 },
        reagents = {
            { itemId = 27682, name = "Serpent Flesh", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.QUEST },
        expansion = C.EXPANSION.TBC,
    },
    -- Mok'Nathal Shortribs (335)
    {
        id = 33292,
        name = "Mok'Nathal Shortribs",
        itemId = 27696,
        skillRequired = 335,
        skillRange = { orange = 335, yellow = 355, green = 365, gray = 375 },
        reagents = {
            { itemId = 31670, name = "Raptor Ribs", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.QUEST },
        expansion = C.EXPANSION.TBC,
    },
    -- Spicy Crawdad (350)
    {
        id = 33296,
        name = "Spicy Crawdad",
        itemId = 27700,
        skillRequired = 350,
        skillRange = { orange = 350, yellow = 365, green = 372, gray = 380 },
        reagents = {
            { itemId = 27439, name = "Furious Crawdad", count = 1 },
        },
        source = { type = C.SOURCE_TYPE.VENDOR },
        expansion = C.EXPANSION.TBC,
    },
}

-- Register with CraftDB
CraftDB:RegisterProfession("cooking", {
    id = C.PROFESSION_ID.COOKING,
    name = "Cooking",
    expansion = C.EXPANSION.TBC,
    milestones = { 75, 150, 225, 300, 375 },
    recipes = recipes,
})
