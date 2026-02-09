-- Core/Constants.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Constants = {
    -- Skill milestones (when you need to train next rank)
    MILESTONES = {75, 150, 225, 300, 375},

    -- Recipe source types
    SOURCE_TYPE = {
        TRAINER = "trainer",
        VENDOR = "vendor",
        DROP = "drop",
        REPUTATION = "reputation",
        QUEST = "quest",
    },

    -- Price source names
    PRICE_SOURCE = {
        TSM = "tsm",
        AUCTIONATOR = "auctionator",
        SCANNER = "scanner",
        VENDOR = "vendor",
    },

    -- TSM price source options
    TSM_PRICE_SOURCE = {
        MIN_BUYOUT = "DBMinBuyout",       -- Current minimum buyout (what you can buy NOW)
        MARKET = "DBMarket",              -- Realm market value (recent average)
        REGION_AVG = "DBRegionMarketAvg", -- Regional average (manipulation resistant, but may differ from local)
    },

    -- Display modes
    DISPLAY_MODE = {
        ARROW_TOOLTIP = "arrowWithTooltip",
        SIMPLE_ARROW = "simpleArrow",
    },

    -- Pathfinding strategies
    STRATEGY = {
        CHEAPEST = "cheapest",
        FASTEST = "fastest",
    },

    -- Material resolution modes (for Cheapest strategy)
    MATERIAL_RESOLUTION = {
        NONE = "none",           -- Buy all materials from AH
        COST_COMPARE = "cost",   -- Craft intermediates if cheaper
        ALWAYS_CRAFT = "craft",  -- Always use raw materials
    },

    -- Cache TTL in seconds
    PRICE_CACHE_TTL = 300,        -- 5 minutes
    PRICE_STALE_THRESHOLD = 86400, -- 24 hours

    -- Profession IDs (spell IDs for TBC)
    PROFESSION_IDS = {
        FIRST_AID = 3273,
    },

    -- Profession display info for browser
    PROFESSIONS = {
        alchemy = {
            name = "Alchemy",
            icon = "Interface\\Icons\\Trade_Alchemy",
        },
        blacksmithing = {
            name = "Blacksmithing",
            icon = "Interface\\Icons\\Trade_BlackSmithing",
        },
        cooking = {
            name = "Cooking",
            icon = "Interface\\Icons\\INV_Misc_Food_15",
        },
        enchanting = {
            name = "Enchanting",
            icon = "Interface\\Icons\\Trade_Engraving",
        },
        engineering = {
            name = "Engineering",
            icon = "Interface\\Icons\\Trade_Engineering",
        },
        firstAid = {
            name = "First Aid",
            icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
        },
        jewelcrafting = {
            name = "Jewelcrafting",
            icon = "Interface\\Icons\\INV_Misc_Gem_01",
        },
        leatherworking = {
            name = "Leatherworking",
            icon = "Interface\\Icons\\Trade_LeatherWorking",
        },
        mining = {
            name = "Mining",
            icon = "Interface\\Icons\\Trade_Mining",
        },
        tailoring = {
            name = "Tailoring",
            icon = "Interface\\Icons\\Trade_Tailoring",
        },
    },
}
