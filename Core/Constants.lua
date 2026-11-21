-- Core/Constants.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Constants = {
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
        VENDOR_SELL = "vendorsell",
    },

    -- Minimum reagent price (copper) used as a last-resort floor when neither a
    -- market source nor a vendor SELL price is known. Guarantees every reagent
    -- has a non-zero price so cost-per-skillup scoring never degenerates to
    -- math.huge (which makes recipe selection arbitrary when no AH data exists).
    MIN_REAGENT_PRICE = 1,

    -- Lowest skill-up chance at which a green recipe may bridge a skill range
    -- where no orange/yellow recipe can be chosen (green recipes excluded by
    -- the setting). Below it the remaining range is reported as a gap.
    BRIDGE_MIN_CHANCE = 0.10,

    -- TSM price source options
    TSM_PRICE_SOURCE = {
        MIN_BUYOUT = "DBMinBuyout",       -- Current minimum buyout (what you can buy NOW)
        RECENT = "DBRecent",              -- Latest snapshot value (current prices, outliers removed)
        MARKET = "DBMarket",              -- Realm market value (14-day weighted average)
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
    -- An Auctionator price last seen this many days ago or more counts as stale
    -- (Auctionator reports whole days). TSM does not report the age of its data.
    PRICE_STALE_DAYS = 3,
    -- An auction price seen this many days ago or less (0 = a scan made today)
    -- is used before the configured price-source order: it is newer than the
    -- TSM snapshot, which only reaches the game at login or /reload.
    AUCTION_FRESH_DAYS = 0,

    -- Profession IDs (spell IDs for TBC)
    PROFESSION_IDS = {
        FIRST_AID = 3273,
    },

    -- Profession skill-line ids -> profession keys (CraftLib's profession table
    -- carries spell ids, not skill lines). Used by the WoW Forever client
    -- adapter, which identifies the open profession by its skill line.
    SKILL_LINE_PROFESSION = {
        [129] = "firstAid",
        [164] = "blacksmithing",
        [165] = "leatherworking",
        [171] = "alchemy",
        [185] = "cooking",
        [186] = "mining",
        [197] = "tailoring",
        [202] = "engineering",
        [333] = "enchanting",
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
