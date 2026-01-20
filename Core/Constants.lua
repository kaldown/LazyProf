-- Core/Constants.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Constants = {
    -- Skill milestones (when you need to train next rank)
    MILESTONES = {75, 150, 225, 300, 375},

    -- Skill-up probability by color
    SKILLUP_CHANCE = {
        orange = 1.0,
        yellow = 0.5,
        green = 0.25,
        gray = 0,
    },

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

    -- Cache TTL in seconds
    PRICE_CACHE_TTL = 300,        -- 5 minutes
    PRICE_STALE_THRESHOLD = 86400, -- 24 hours

    -- Profession IDs (spell IDs for TBC)
    PROFESSION_IDS = {
        FIRST_AID = 3273,
    },
}
