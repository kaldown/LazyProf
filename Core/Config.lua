-- Core/Config.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

-- Default saved variables
LazyProf.defaults = {
    profile = {
        -- Pathfinding
        strategy = Constants.STRATEGY.CHEAPEST,
        materialResolution = Constants.MATERIAL_RESOLUTION.COST_COMPARE,
        useIntermediates = true,
        suggestUnlearnedRecipes = true,

        -- Display
        displayMode = Constants.DISPLAY_MODE.ARROW_TOOLTIP,
        showMilestonePanel = true,
        showMissingMaterials = true,
        calculateFromCurrentSkill = false,
        includeBankItems = false,
        useOwnedMaterials = false,
        includeAltCharacters = false,

        -- Minimap button
        minimap = {
            hide = false,
        },

        -- Pricing
        priceSourcePriority = {
            Constants.PRICE_SOURCE.TSM,
            Constants.PRICE_SOURCE.AUCTIONATOR,
            Constants.PRICE_SOURCE.SCANNER,
            Constants.PRICE_SOURCE.VENDOR,
        },
        tsmPriceSource = Constants.TSM_PRICE_SOURCE.MIN_BUYOUT, -- Default to current AH prices

        -- Debug
        debug = false,
        debugCategories = {
            scoring = false,      -- Verbose recipe scoring (VERY noisy)
            pathfinder = true,    -- Path calculation summaries
            ui = false,           -- Window/panel state changes
            professions = false,  -- Profession registration
            pricing = false,      -- Price provider info
            arrow = false,        -- Arrow positioning
        },
    },
    char = {
        -- Per-character price cache
        priceCache = {},
        lastAHScan = 0,
        -- Cached learned recipes per profession (for planning mode)
        learnedRecipes = {},
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
                materialResolution = {
                    name = "Material Resolution",
                    desc = "How to handle craftable intermediate materials (e.g., smelt ore into bars)",
                    type = "select",
                    order = 4,
                    values = {
                        [Constants.MATERIAL_RESOLUTION.NONE] = "None (buy all materials)",
                        [Constants.MATERIAL_RESOLUTION.COST_COMPARE] = "Cost-compare (craft if cheaper)",
                        [Constants.MATERIAL_RESOLUTION.ALWAYS_CRAFT] = "Always craft (use raw materials)",
                    },
                    disabled = function() return LazyProf.db.profile.strategy ~= Constants.STRATEGY.CHEAPEST end,
                    get = function() return LazyProf.db.profile.materialResolution end,
                    set = function(_, v)
                        LazyProf.db.profile.materialResolution = v
                        LazyProf:Recalculate()
                    end,
                },
                materialResolutionNote = {
                    name = "|cFF888888Material resolution is only available with Cheapest strategy.|r",
                    type = "description",
                    order = 5,
                    hidden = function() return LazyProf.db.profile.strategy == Constants.STRATEGY.CHEAPEST end,
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
                minimapButton = {
                    name = "Show minimap button",
                    desc = "Show the LazyProf minimap button",
                    type = "toggle",
                    order = 0,
                    width = "full",
                    get = function() return not LazyProf.db.profile.minimap.hide end,
                    set = function(_, v)
                        LazyProf.db.profile.minimap.hide = not v
                        if v then
                            LazyProf.MinimapButton:Show()
                        else
                            LazyProf.MinimapButton:Hide()
                        end
                    end,
                },
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
                    desc = "When enabled, shows the leveling path starting from your " ..
                           "current skill level.\n\n" ..
                           "When disabled, shows the FULL leveling path from skill 1 " ..
                           "to max, useful for planning total materials needed.\n\n" ..
                           "Example: At Engineering 184, enabled shows 184-300, " ..
                           "disabled shows 1-300 (full path).",
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
                inventoryHeader = {
                    name = "Inventory Optimization",
                    type = "header",
                    order = 6,
                },
                useOwnedMaterials = {
                    name = "Use owned materials as free",
                    desc = "When enabled, materials you already own (in bags and bank) " ..
                           "are treated as FREE (0 cost) when calculating the cheapest " ..
                           "leveling path.\n\n" ..
                           "Example: If a recipe needs 10 Wool Cloth and you have 10 in " ..
                           "your bank, that recipe costs 0g instead of market price.\n\n" ..
                           "This helps the pathfinder choose recipes that use materials " ..
                           "you already have, minimizing actual gold spent.",
                    type = "toggle",
                    order = 7,
                    width = "full",
                    get = function() return LazyProf.db.profile.useOwnedMaterials end,
                    set = function(_, v)
                        LazyProf.db.profile.useOwnedMaterials = v
                        LazyProf:Recalculate()
                    end,
                },
                includeAltCharacters = {
                    name = "Include alt characters",
                    desc = "When enabled, materials on ALL your characters (bags and " ..
                           "banks) are considered when calculating path costs.\n\n" ..
                           "Requires: Syndicator addon installed.\n\n" ..
                           "Example: Your alt has 200 Silk Cloth. Recipes using Silk " ..
                           "will be preferred since you already own the materials.\n\n" ..
                           "Note: You'll need to transfer materials to your crafter " ..
                           "before crafting - the addon just helps you plan.",
                    type = "toggle",
                    order = 8,
                    width = "full",
                    disabled = function()
                        return not LazyProf.db.profile.useOwnedMaterials or not Syndicator
                    end,
                    get = function() return LazyProf.db.profile.includeAltCharacters end,
                    set = function(_, v)
                        LazyProf.db.profile.includeAltCharacters = v
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
                tsmNotInstalled = {
                    name = function()
                        local source = "Vendor prices only"
                        if Auctionator and Auctionator.API and Auctionator.API.v1 then
                            source = "Auctionator"
                        end
                        return "|cFFFFCC00Recommendation:|r Install TradeSkillMaster (TSM) for accurate AH prices. Without TSM, prices may be less accurate or unavailable.\n\n|cFF888888Currently using: " .. source .. "|r"
                    end,
                    type = "description",
                    order = 1.5,
                    hidden = function() return TSM_API ~= nil end,
                },
                tsmHeader = {
                    name = "TSM Settings",
                    type = "header",
                    order = 2,
                    hidden = function() return not TSM_API end,
                },
                tsmPriceSource = {
                    name = "TSM Price Source",
                    desc = "Which TSM price value to use for calculations",
                    type = "select",
                    order = 3,
                    width = "double",
                    hidden = function() return not TSM_API end,
                    values = {
                        [Constants.TSM_PRICE_SOURCE.MIN_BUYOUT] = "Min Buyout (current AH prices)",
                        [Constants.TSM_PRICE_SOURCE.MARKET] = "Market Value (realm average)",
                        [Constants.TSM_PRICE_SOURCE.REGION_AVG] = "Region Average (cross-realm)",
                    },
                    get = function() return LazyProf.db.profile.tsmPriceSource end,
                    set = function(_, v)
                        LazyProf.db.profile.tsmPriceSource = v
                        if LazyProf.PriceManager then
                            LazyProf.PriceManager:ClearCache()
                        end
                        LazyProf:Recalculate()
                    end,
                },
                tsmPriceDesc = {
                    name = "|cFF888888Min Buyout = what you can buy right now on AH\nMarket Value = recent average on your realm\nRegion Average = average across all realms (stable but may differ from local)|r",
                    type = "description",
                    order = 4,
                    hidden = function() return not TSM_API end,
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
                    width = "full",
                    get = function() return LazyProf.db.profile.debug end,
                    set = function(_, v) LazyProf.db.profile.debug = v end,
                },
                showDebugWindow = {
                    name = "Show Debug Window",
                    desc = "Open the debug log window to view captured messages.\n\n" ..
                           "Same as /lp log",
                    type = "execute",
                    order = 2,
                    hidden = function() return not LazyProf.db.profile.debug end,
                    func = function()
                        LazyProf:ShowDebugLog()
                    end,
                },
                categoriesHeader = {
                    name = "Debug Categories",
                    type = "header",
                    order = 10,
                    hidden = function() return not LazyProf.db.profile.debug end,
                },
                categoriesDesc = {
                    name = "Select which categories to capture. Use /lp log to view and filter logs.",
                    type = "description",
                    order = 11,
                    hidden = function() return not LazyProf.db.profile.debug end,
                },
                catScoring = {
                    name = "Pathfinder Scoring",
                    desc = "Detailed recipe scoring at each skill level.\n\n" ..
                           "WARNING: Very verbose - generates 10+ lines per skill level " ..
                           "during path calculation. Only enable when debugging scoring issues.",
                    type = "toggle",
                    order = 12,
                    hidden = function() return not LazyProf.db.profile.debug end,
                    get = function() return LazyProf.db.profile.debugCategories.scoring end,
                    set = function(_, v) LazyProf.db.profile.debugCategories.scoring = v end,
                },
                catPathfinder = {
                    name = "Pathfinder Core",
                    desc = "Path calculation summaries and results.\n\n" ..
                           "Shows when paths are calculated, total steps, and costs. " ..
                           "Recommended to keep enabled for general debugging.",
                    type = "toggle",
                    order = 13,
                    hidden = function() return not LazyProf.db.profile.debug end,
                    get = function() return LazyProf.db.profile.debugCategories.pathfinder end,
                    set = function(_, v) LazyProf.db.profile.debugCategories.pathfinder = v end,
                },
                catUI = {
                    name = "UI Updates",
                    desc = "Planning window and milestone panel state changes.\n\n" ..
                           "Shows when panels update, visibility changes, and frame state. " ..
                           "Useful for debugging display issues.",
                    type = "toggle",
                    order = 14,
                    hidden = function() return not LazyProf.db.profile.debug end,
                    get = function() return LazyProf.db.profile.debugCategories.ui end,
                    set = function(_, v) LazyProf.db.profile.debugCategories.ui = v end,
                },
                catProfessions = {
                    name = "Professions",
                    desc = "Profession registration and detection events.\n\n" ..
                           "Shows when professions are registered from CraftLib data.",
                    type = "toggle",
                    order = 15,
                    hidden = function() return not LazyProf.db.profile.debug end,
                    get = function() return LazyProf.db.profile.debugCategories.professions end,
                    set = function(_, v) LazyProf.db.profile.debugCategories.professions = v end,
                },
                catPricing = {
                    name = "Pricing",
                    desc = "Price provider selection and lookups.\n\n" ..
                           "Shows which price sources are being used (TSM, Auctionator, etc).",
                    type = "toggle",
                    order = 16,
                    hidden = function() return not LazyProf.db.profile.debug end,
                    get = function() return LazyProf.db.profile.debugCategories.pricing end,
                    set = function(_, v) LazyProf.db.profile.debugCategories.pricing = v end,
                },
                catArrow = {
                    name = "Arrow",
                    desc = "Arrow positioning and strategy changes.\n\n" ..
                           "Shows arrow placement and display mode changes.",
                    type = "toggle",
                    order = 17,
                    hidden = function() return not LazyProf.db.profile.debug end,
                    get = function() return LazyProf.db.profile.debugCategories.arrow end,
                    set = function(_, v) LazyProf.db.profile.debugCategories.arrow = v end,
                },
                resetHeader = {
                    name = "",
                    type = "header",
                    order = 90,
                },
                resetDB = {
                    name = "Reset All Settings",
                    desc = "Reset all settings to defaults",
                    type = "execute",
                    order = 91,
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
