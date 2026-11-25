-- Core/Config.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

-- Default saved variables
LazyProf.defaults = {
    profile = {
        -- Pathfinding
        strategy = Constants.STRATEGY.CHEAPEST,
        materialResolution = Constants.MATERIAL_RESOLUTION.COST_COMPARE,
        suggestUnlearnedRecipes = true,
        includeGreenRecipes = false,
        includeCurrencyRecipes = false,
        -- "Spare crafts": extra crafts for bad luck, as a percentage of each step
        useMargin = false,
        marginPercent = 15,
        -- What crafted items are counted as selling for (Constants.SALE_MODE)
        saleValueMode = Constants.SALE_MODE.VENDOR,

        -- Display
        displayMode = Constants.DISPLAY_MODE.ARROW_TOOLTIP,
        -- Open the LazyProf window beside the profession window
        openWithProfession = true,
        -- Show the window's advanced controls and details ("More options")
        showAdvanced = false,
        -- Which owned stock counts (for the route, every total and the
        -- shopping list). The guild bank is shared, so it stays off.
        includeBankItems = true,
        includeAltCharacters = true,
        includeGuildBank = false,
        -- Side-panel positions the user dragged to: [key] = { point, relPoint, x, y }
        panelPositions = {},
        -- Sizes of resizable panels the user changed: [key] = { width, height }
        panelSizes = {},

        -- Minimap button
        minimap = {
            hide = false,
        },

        -- Pricing
        priceSourcePriority = {
            Constants.PRICE_SOURCE.TSM,
            Constants.PRICE_SOURCE.AUCTIONATOR,
            Constants.PRICE_SOURCE.SCANNER,
        },
        tsmPriceSource = Constants.TSM_PRICE_SOURCE.RECENT, -- Default to current AH prices (outliers removed)
        useVendorSellFallback = true, -- Floor every reagent at its vendor sell value when no market price exists (lets scoring work with no AH)

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
    -- Account-wide. characters[guid] holds each character's planner data
    -- (targets, pins, craft choices, last tab): see Core/CharStore.lua.
    global = {
        characters = {},
        -- Vendor prices seen at merchants: [itemId] = copper per item
        -- (Modules/Shopping/VendorMemory.lua)
        vendorPrices = {},
        -- Profession trainers visited and the fees they charged, per client
        -- profile (Modules/Guide/TrainerMemory.lua)
        trainers = {},
        trainerFees = {},
    },
    char = {
        -- Per-character price cache
        priceCache = {},
        -- Cached learned recipes per profession (for planning mode)
        learnedRecipes = {},
        -- Self-found mode: only suggest recipes obtainable without AH/trade (per character)
        selfFoundMode = false,
    },
}

-- What the player is told after a reset ("Reset All Settings" below and
-- /lp reset, LazyProf:ResetSettings in Core/Init.lua): what went with the
-- settings.
LazyProf.RESET_MESSAGE = "Settings reset to defaults. Vendor prices, trainers, targets and craft-or-buy choices "
    .. "were cleared."

-- The stock options say "Requires: Syndicator" and are greyed out while it
-- is missing. Asked when the options are shown: Syndicator may load after
-- LazyProf.
local function NeedsSyndicator()
    return not LazyProf.Inventory:UsesSyndicator()
end
local function SyndicatorNote()
    if NeedsSyndicator() then
        return "Requires: Syndicator addon installed. Without it only the bags of the " ..
               "character you are playing are counted.\n\n"
    end
    return ""
end

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
                        LazyProf:Recalculate("setting changed")
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
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                materialResolutionNote = {
                    name = "|cFF888888Material resolution is only available with Cheapest strategy.|r",
                    type = "description",
                    order = 5,
                    hidden = function() return LazyProf.db.profile.strategy == Constants.STRATEGY.CHEAPEST end,
                },
                suggestUnlearnedRecipes = {
                    name = "Suggest unlearned recipes",
                    desc = "Include recipes you haven't learned yet in path calculation",
                    type = "toggle",
                    order = 3,
                    width = "full",
                    get = function() return LazyProf.db.profile.suggestUnlearnedRecipes end,
                    set = function(_, v)
                        LazyProf.db.profile.suggestUnlearnedRecipes = v
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                saleValueMode = {
                    name = "Count what crafts sell for",
                    desc = "The crafted items are worth something when you sell them. The " ..
                           "Cheapest strategy counts that when it compares recipes whose " ..
                           "reagents all have a real price.\n\n" ..
                           "Sold to a vendor: the vendor's price, which you always get.\n" ..
                           "Sold at auction: the auction price after the 5% cut (never less " ..
                           "than the vendor's price). An auction may not sell.\n" ..
                           "Do not count: costs only.",
                    type = "select",
                    order = 3.2,
                    values = {
                        [Constants.SALE_MODE.VENDOR] = "Sold to a vendor",
                        [Constants.SALE_MODE.AUCTION] = "Sold at auction (after the 5% cut)",
                        [Constants.SALE_MODE.NONE] = "Do not count",
                    },
                    sorting = { Constants.SALE_MODE.VENDOR, Constants.SALE_MODE.AUCTION, Constants.SALE_MODE.NONE },
                    get = function() return LazyProf.db.profile.saleValueMode end,
                    set = function(_, v)
                        LazyProf.db.profile.saleValueMode = v
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                includeCurrencyRecipes = {
                    name = "Include recipes bought with currency (e.g. Merchant's Favor)",
                    desc = "When enabled, recipes sold only for a currency (not gold) are " ..
                           "included in path calculations. Their currency price is shown " ..
                           "but not counted in the gold cost.",
                    type = "toggle",
                    order = 3.5,
                    width = "full",
                    get = function() return LazyProf.db.profile.includeCurrencyRecipes end,
                    set = function(_, v)
                        LazyProf.db.profile.includeCurrencyRecipes = v
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                includeGreenRecipes = {
                    name = "Include green recipes",
                    desc = "When enabled, recipes with green difficulty (low skillup " ..
                           "chance) are included in path calculations.\n\n" ..
                           "|cFFFF6666Warning:|r Green skillup rates are unreliable. " ..
                           "There is no proven formula for how WoW calculates green " ..
                           "skillup probability. The displayed percentage may be " ..
                           "significantly higher than the actual in-game rate.\n\n" ..
                           "Enable at your own risk. You may waste gold crafting " ..
                           "items that never give a skillup.\n\n" ..
                           "Example: A green recipe showing 50% chance may in " ..
                           "practice give 0 skillups across 10+ crafts.",
                    type = "toggle",
                    order = 4,
                    width = "full",
                    get = function() return LazyProf.db.profile.includeGreenRecipes end,
                    set = function(_, v)
                        LazyProf.db.profile.includeGreenRecipes = v
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                marginPercent = {
                    name = "Spare crafts (percent)",
                    desc = "Skill-ups are a matter of chance, so the planned number of crafts " ..
                           "is an average. With \"Spare crafts\" ticked in the LazyProf window " ..
                           "(under More options), every step plans this many percent more " ..
                           "crafts and reagents, rounded up once per step.\n\n" ..
                           "The margin never changes which recipes are chosen.",
                    type = "range",
                    order = 5,
                    min = 5,
                    max = 30,
                    step = 5,
                    get = function() return LazyProf.db.profile.marginPercent end,
                    set = function(_, v)
                        LazyProf.db.profile.marginPercent = v
                        LazyProf:UpdateDisplay()
                    end,
                },
                selfFoundMode = {
                    name = "Self-Found mode",
                    desc = "When enabled, the path only suggests recipes you can complete " ..
                           "without the Auction House or trading with other players.\n\n" ..
                           "A recipe is excluded if any reagent can only be obtained from the " ..
                           "AH or another player - for example an Alchemy elixir when you are " ..
                           "not an Alchemist. Allowed: items you own, vendor-sold reagents, " ..
                           "gathered materials, and anything you can craft with a profession " ..
                           "you have.\n\n" ..
                           "Such a character cannot be sent anything: stock of your other " ..
                           "characters and of the guild bank is not counted for it. A " ..
                           "character the game itself marks Self-Found is treated this way " ..
                           "for stock even with this setting off.\n\n" ..
                           "This setting is per character.",
                    type = "toggle",
                    order = 6,
                    width = "full",
                    get = function() return LazyProf.db.char.selfFoundMode end,
                    set = function(_, v)
                        LazyProf.db.char.selfFoundMode = v
                        LazyProf:Recalculate("setting changed")
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
                    hidden = function() return LazyProf.ClientFamily == "forever" end,
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
                openWithProfession = {
                    name = "Open with the profession window",
                    desc = "Show the LazyProf window (Path and Shopping) beside the " ..
                           "profession window whenever you open a profession.\n\n" ..
                           "When off, the arrow still points at the next recipe, and the " ..
                           "window can be opened from the minimap button or /lp browse.",
                    type = "toggle",
                    order = 2,
                    width = "full",
                    get = function() return LazyProf.db.profile.openWithProfession end,
                    set = function(_, v)
                        LazyProf.db.profile.openWithProfession = v
                        LazyProf:UpdateDisplay()
                    end,
                },
                resetPanelPositions = {
                    name = "Reset panel positions",
                    desc = "Move the LazyProf window and its side panels back next to the " ..
                           "profession window, at their default size.\n\n" ..
                           "Same as /lp resetpanels",
                    type = "execute",
                    order = 4.5,
                    func = function()
                        LazyProf.PanelShell:ResetPositions()
                    end,
                },
                shoppingListHeader = {
                    name = "Your stock",
                    type = "header",
                    order = 5,
                },
                includeBankItems = {
                    name = "Include bank items",
                    desc = function()
                        return "When enabled, items in your bank count as owned: the shopping " ..
                               "list shows only what you still need to buy, and the Cheapest " ..
                               "strategy plans the path around them when that is cheaper for you.\n\n" ..
                               "The bank is read from the Syndicator addon, as it was when you " ..
                               "last opened it.\n\n" ..
                               SyndicatorNote() ..
                               "Example: You need 20 Thorium Bars but have 8 in your bank. " ..
                               "The shopping list shows 12 to buy from the AH."
                    end,
                    type = "toggle",
                    order = 6,
                    width = "full",
                    disabled = NeedsSyndicator,
                    get = function() return LazyProf.db.profile.includeBankItems end,
                    set = function(_, v)
                        LazyProf.db.profile.includeBankItems = v
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                includeAltCharacters = {
                    name = "Include alt characters",
                    desc = function()
                        return "When enabled, materials on your other characters count as " ..
                               "owned: they are subtracted from the shopping list, and the " ..
                               "Cheapest strategy plans the path around them when that is " ..
                               "cheaper for you.\n\n" ..
                               "Their bags, banks, mail and AH listings are read from the " ..
                               "Syndicator addon, as it last saw them.\n\n" ..
                               SyndicatorNote() ..
                               "A character in Self-Found mode cannot be sent anything, so no " ..
                               "alt stock is counted for it.\n\n" ..
                               "Example: Your alt has 200 Silk Cloth. The shopping list " ..
                               "will show 200 fewer Silk Cloth to buy from the AH.\n\n" ..
                               "Note: You'll need to transfer materials to your crafter " ..
                               "before crafting - the addon just helps you plan."
                    end,
                    type = "toggle",
                    order = 7,
                    width = "full",
                    disabled = NeedsSyndicator,
                    get = function() return LazyProf.db.profile.includeAltCharacters end,
                    set = function(_, v)
                        LazyProf.db.profile.includeAltCharacters = v
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                includeGuildBank = {
                    name = "Include guild bank",
                    desc = "When enabled, materials in your guild bank count as owned: " ..
                           "they are subtracted from the shopping list, and the Cheapest " ..
                           "strategy plans the path around them when that is cheaper for you.\n\n" ..
                           "Requires: Syndicator addon installed.\n\n" ..
                           "Guild bank data is cached from your last visit. Only " ..
                           "tabs you have permission to view are included.\n\n" ..
                           "A character in Self-Found mode cannot be handed anything, " ..
                           "so the guild bank is not counted for it.\n\n" ..
                           "Example: Your guild bank has 50 Thorium Bars. The " ..
                           "shopping list shows 50 fewer to buy from the AH.\n\n" ..
                           "Note: This is a shared resource - other guild members " ..
                           "may also need these materials.",
                    type = "toggle",
                    order = 8,
                    width = "full",
                    disabled = NeedsSyndicator,
                    get = function() return LazyProf.db.profile.includeGuildBank end,
                    set = function(_, v)
                        LazyProf.db.profile.includeGuildBank = v
                        LazyProf:Recalculate("setting changed")
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
                    name = "Vendor prices are always used first when known: from TSM/Auctionator merchant data, from merchants you have visited with LazyProf, or from the built-in vendor list. An Auctionator price from a scan you made this session (since login or /reload) comes next. Otherwise market sources are checked in order (TSM, then Auctionator).",
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
                useVendorSellFallback = {
                    name = "Estimate from vendor sell value when no AH price",
                    desc = "When enabled, any material with no TSM/Auctionator price is valued at its vendor sell price (the gray 'sell to vendor' value, read from the game itself). This lets the Cheapest strategy still rank recipes correctly when you have no auction house data - a 1-leather recipe will beat a 2-leather recipe.\n\nWhen disabled, materials with no market price are treated as unpriced, which makes every recipe tie and the picked recipe effectively arbitrary. Leave enabled unless you only ever play with full TSM/Auctionator data.",
                    type = "toggle",
                    width = "full",
                    order = 1.7,
                    get = function() return LazyProf.db.profile.useVendorSellFallback ~= false end,
                    set = function(_, v)
                        LazyProf.db.profile.useVendorSellFallback = v
                        if LazyProf.PriceManager then
                            LazyProf.PriceManager:ClearCache()
                        end
                        LazyProf:Recalculate("setting changed")
                    end,
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
                        [Constants.TSM_PRICE_SOURCE.MIN_BUYOUT] = "Min Buyout (cheapest listing)",
                        [Constants.TSM_PRICE_SOURCE.RECENT] = "Recent Value (current prices, cleaned)",
                        [Constants.TSM_PRICE_SOURCE.MARKET] = "Market Value (14-day average)",
                        [Constants.TSM_PRICE_SOURCE.REGION_AVG] = "Region Average (cross-realm)",
                    },
                    get = function() return LazyProf.db.profile.tsmPriceSource end,
                    set = function(_, v)
                        LazyProf.db.profile.tsmPriceSource = v
                        if LazyProf.PriceManager then
                            LazyProf.PriceManager:ClearCache()
                        end
                        LazyProf:Recalculate("setting changed")
                    end,
                },
                tsmPriceDesc = {
                    name = "|cFF888888Min Buyout = cheapest single listing on AH\nRecent Value = current prices with outliers removed\nMarket Value = 14-day weighted average on your realm\nRegion Average = average across all realms (stable but may differ from local)|r",
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
                    desc = "LazyProf window and panel state changes.\n\n" ..
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
                    desc = "Reset all settings to defaults. This also clears the vendor " ..
                           "prices and trainers LazyProf has seen and every character's " ..
                           "targets and craft-or-buy choices.\n\n" ..
                           "Same as /lp reset",
                    type = "execute",
                    order = 91,
                    confirm = true,
                    confirmText = "Reset all settings to their defaults? This also clears the vendor " ..
                                  "prices and trainers LazyProf has seen and every character's " ..
                                  "targets and craft-or-buy choices.",
                    func = function()
                        LazyProf:ResetSettings()
                        LazyProf:Print(LazyProf.RESET_MESSAGE)
                    end,
                },
            },
        },
    },
}

-- Settings an older version saved under names that are gone. `sv` is the raw
-- saved table (LazyProfDB), which holds only values that differ from the
-- defaults of the version that wrote them.
--   Show milestone breakdown / Show missing materials (both on by default)
--     became "Open with the profession window": off only when both were off,
--     so nobody's window appears or vanishes by itself.
--   The saved spots of the two old panels and the retired "calculate from
--     current skill" setting are dropped.
function LazyProf.MigrateSettings(sv)
    if type(sv) ~= "table" or type(sv.profiles) ~= "table" then return end
    for _, profile in pairs(sv.profiles) do
        if type(profile) == "table" then
            if profile.showMilestonePanel == false and profile.showMissingMaterials == false
                    and profile.openWithProfession == nil then
                profile.openWithProfession = false
            end
            profile.showMilestonePanel = nil
            profile.showMissingMaterials = nil
            profile.calculateFromCurrentSkill = nil
            if type(profile.panelPositions) == "table" then
                profile.panelPositions.milestone = nil
                profile.panelPositions.shoppingList = nil
            end
        end
    end
end

-- Register config with Ace
function LazyProf:SetupConfig()
    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable("LazyProf", self.options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions("LazyProf", "LazyProf")
    self.configRegistered = true
end
