-- Core/Config.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

-- Default saved variables
LazyProf.defaults = {
    profile = {
        -- Pathfinding
        strategy = Constants.STRATEGY.CHEAPEST,
        useIntermediates = true,
        suggestUnlearnedRecipes = true,
        includeDropRecipes = false,

        -- Display
        displayMode = Constants.DISPLAY_MODE.ARROW_TOOLTIP,
        showMilestonePanel = true,
        showMissingMaterials = true,
        calculateFromCurrentSkill = false,
        includeBankItems = false,

        -- Pricing
        priceSourcePriority = {
            Constants.PRICE_SOURCE.TSM,
            Constants.PRICE_SOURCE.AUCTIONATOR,
            Constants.PRICE_SOURCE.SCANNER,
            Constants.PRICE_SOURCE.VENDOR,
        },
        autoScanAH = false,

        -- Debug
        debug = false,
    },
    char = {
        -- Per-character price cache
        priceCache = {},
        lastAHScan = 0,
    },
}

-- AceConfig options table
LazyProf.options = {
    name = "LazyProf",
    handler = LazyProf,
    type = "group",
    args = {
        general = {
            name = "General",
            type = "group",
            order = 1,
            args = {
                strategyHeader = {
                    name = "Pathfinding",
                    type = "header",
                    order = 1,
                },
                strategy = {
                    name = "Strategy",
                    desc = "Algorithm for calculating optimal path",
                    type = "select",
                    order = 2,
                    values = {
                        [Constants.STRATEGY.CHEAPEST] = "Cheapest (minimize gold)",
                        [Constants.STRATEGY.FASTEST] = "Fastest (minimize crafts)",
                    },
                    get = function() return LazyProf.db.profile.strategy end,
                    set = function(_, v)
                        LazyProf.db.profile.strategy = v
                        LazyProf:Recalculate()
                    end,
                },
                strategyWarning = {
                    name = "|cFFFF6666Warning:|r Fastest strategy prioritizes fewer crafts over cost. This can be significantly more expensive than Cheapest.",
                    type = "description",
                    order = 3,
                    hidden = function() return LazyProf.db.profile.strategy ~= Constants.STRATEGY.FASTEST end,
                },
                useIntermediates = {
                    name = "Calculate intermediate crafts",
                    desc = "Include sub-component costs in path calculation (e.g., craft Heavy Blasting Powder for Heavy Dynamite)",
                    type = "toggle",
                    order = 3,
                    width = "full",
                    get = function() return LazyProf.db.profile.useIntermediates end,
                    set = function(_, v)
                        LazyProf.db.profile.useIntermediates = v
                        LazyProf:Recalculate()
                    end,
                },
                suggestUnlearnedRecipes = {
                    name = "Suggest unlearned recipes",
                    desc = "Include recipes you haven't learned yet in path calculation",
                    type = "toggle",
                    order = 4,
                    width = "full",
                    get = function() return LazyProf.db.profile.suggestUnlearnedRecipes end,
                    set = function(_, v)
                        LazyProf.db.profile.suggestUnlearnedRecipes = v
                        LazyProf:Recalculate()
                    end,
                },
            },
        },
        display = {
            name = "Display",
            type = "group",
            order = 2,
            args = {
                displayMode = {
                    name = "Arrow Style",
                    desc = "How to display the recommended recipe indicator",
                    type = "select",
                    order = 1,
                    values = {
                        [Constants.DISPLAY_MODE.ARROW_TOOLTIP] = "Arrow + Tooltip",
                        [Constants.DISPLAY_MODE.SIMPLE_ARROW] = "Simple Arrow",
                    },
                    get = function() return LazyProf.db.profile.displayMode end,
                    set = function(_, v)
                        LazyProf.db.profile.displayMode = v
                        LazyProf:UpdateDisplay()
                    end,
                },
                showMilestonePanel = {
                    name = "Show milestone breakdown",
                    desc = "Display skill bracket breakdown panel",
                    type = "toggle",
                    order = 2,
                    width = "full",
                    get = function() return LazyProf.db.profile.showMilestonePanel end,
                    set = function(_, v)
                        LazyProf.db.profile.showMilestonePanel = v
                        LazyProf:UpdateDisplay()
                    end,
                },
                showMissingMaterials = {
                    name = "Show missing materials",
                    desc = "Display shopping list panel",
                    type = "toggle",
                    order = 3,
                    width = "full",
                    get = function() return LazyProf.db.profile.showMissingMaterials end,
                    set = function(_, v)
                        LazyProf.db.profile.showMissingMaterials = v
                        LazyProf:UpdateDisplay()
                    end,
                },
                calculateFromCurrentSkill = {
                    name = "Calculate from current skill",
                    desc = "Show materials needed from your current skill level instead of the full milestone bracket (e.g., at skill 148, show 148-150 instead of 75-150)",
                    type = "toggle",
                    order = 4,
                    width = "full",
                    get = function() return LazyProf.db.profile.calculateFromCurrentSkill end,
                    set = function(_, v)
                        LazyProf.db.profile.calculateFromCurrentSkill = v
                        LazyProf:Recalculate()
                    end,
                },
                includeBankItems = {
                    name = "Include bank items",
                    desc = Syndicator and "Count items in your bank when calculating missing materials" or "Count items in your bank when calculating missing materials. Requires Baganator addon.",
                    type = "toggle",
                    order = 5,
                    width = "full",
                    disabled = function() return not Syndicator end,
                    get = function() return LazyProf.db.profile.includeBankItems end,
                    set = function(_, v)
                        LazyProf.db.profile.includeBankItems = v
                        LazyProf:Recalculate()
                    end,
                },
            },
        },
        pricing = {
            name = "Pricing",
            type = "group",
            order = 3,
            args = {
                desc = {
                    name = "Price sources are checked in order. First available price is used.",
                    type = "description",
                    order = 1,
                },
                autoScanAH = {
                    name = "Auto-scan Auction House",
                    desc = "Automatically scan prices when opening the Auction House",
                    type = "toggle",
                    order = 2,
                    width = "full",
                    get = function() return LazyProf.db.profile.autoScanAH end,
                    set = function(_, v) LazyProf.db.profile.autoScanAH = v end,
                },
                scanButton = {
                    name = "Scan AH Now",
                    desc = "Manually trigger Auction House price scan (must have AH open)",
                    type = "execute",
                    order = 3,
                    func = function()
                        if LazyProf.PriceManager then
                            LazyProf.PriceManager:ScanAuctionHouse()
                        else
                            LazyProf:Print("Price manager not loaded.")
                        end
                    end,
                },
            },
        },
        debug = {
            name = "Debug",
            type = "group",
            order = 99,
            args = {
                debugMode = {
                    name = "Enable debug messages",
                    type = "toggle",
                    order = 1,
                    get = function() return LazyProf.db.profile.debug end,
                    set = function(_, v) LazyProf.db.profile.debug = v end,
                },
                resetDB = {
                    name = "Reset All Settings",
                    desc = "Reset all settings to defaults",
                    type = "execute",
                    order = 2,
                    confirm = true,
                    confirmText = "Are you sure you want to reset all LazyProf settings?",
                    func = function()
                        LazyProf.db:ResetDB()
                        LazyProf:Print("Settings reset to defaults.")
                    end,
                },
            },
        },
    },
}

-- Register config with Ace
function LazyProf:SetupConfig()
    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable("LazyProf", self.options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions("LazyProf", "LazyProf")
    self.configRegistered = true
end
