-- scripts/lib/window.lua
--
-- Loads the LazyProf window and what it is drawn from against the fake UI,
-- with the planner, prices and client adapter stubbed. Shared by the window
-- suites.
--
--   local W = require("scripts.lib.window")
--   local env = W.load("forever")     -- env.addon, env.ui, env.window (the GuideWindow module)
--   env.calls                          -- names of stubbed calls, in order
--   W.recipe(...), W.step(...), W.path(extra)
--   W.rowTexts(window), W.findRow(window, text), W.findButton(window, text)
--   W.receiptTexts(window)

local fakeui = require("scripts.lib.fakeui")

local M = {}

M.MILESTONES = { 75, 150, 225, 300 }
M.PRICES = { [101] = 100, [102] = 200, [103] = 300 }

function M.recipe(id, name, orange, yellow, green, gray, opts)
    opts = opts or {}
    return {
        id = id, name = name, learned = not opts.unlearned, skillRequired = opts.required or orange,
        skillRange = { orange = orange, yellow = yellow, green = green, gray = gray },
        reagents = opts.reagents or { { itemId = 100 + id, count = 1, name = "Mat" .. name } },
        source = opts.source or { type = "trainer", npcName = "Any Tailoring Trainer" },
        _sourceInfo = opts.sourceInfo,
        _isUnavailable = opts.unavailable,
        _unavailableReason = opts.reason,
    }
end

function M.step(r, from, to, quantity, cost, extra)
    local s = { recipe = r, skillStart = from, skillEnd = to, quantity = quantity, totalCost = cost, alternatives = {} }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

M.GLOVES = M.recipe(1, "Gloves", 100, 150, 160, 170)
M.SHIRT = M.recipe(2, "Shirt", 150, 200, 210, 220)
M.CAPE = M.recipe(3, "Cape", 100, 150, 160, 170)

-- Tailoring at 143: Gloves 143-160, Shirt 160-200, gap 200-300.
function M.path(extra)
    local path = {
        profession = "Tailoring", professionKey = "tailoring", hasProfession = true,
        currentSkill = 143, actualSkill = 143, targetSkill = 300, capSkill = 300, racialBonus = 0,
        milestones = M.MILESTONES, prices = M.PRICES, inventory = {}, sourceBreakdown = {}, complete = false,
        steps = {
            M.step(M.GLOVES, 143, 150, 7, 700), M.step(M.GLOVES, 150, 160, 12, 1200),
            M.step(M.SHIRT, 160, 200, 40, 8000),
        },
        gaps = { { from = 200, to = 300, reason = "no recipe" } },
        totalCost = 9900,
    }
    for k, v in pairs(extra or {}) do path[k] = v end
    return path
end

local FILES = {
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Core/CharStore.lua",
    "Modules/Pathfinder/Pins.lua",
    "Modules/Guide/Text.lua",
    "Modules/Guide/Stages.lua",
    "Modules/Guide/Views.lua",
    "Modules/UI/Widgets/PanelShell.lua",
    "Modules/UI/Widgets/RowPool.lua",
    "Modules/UI/Widgets/Dropdown.lua",
    "Modules/UI/Widgets/Controls.lua",
    "Modules/UI/Widgets/Slider.lua",
    "Modules/UI/Widgets/Tabs.lua",
    "Modules/UI/Widgets/RowList.lua",
    "Modules/UI/GuideWindow.lua",
}

-- extraFiles: more files to load after the window (optional).
function M.load(family, extraFiles)
    if not string.trim then
        function string.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    end
    local ui = fakeui.install({ family = family })
    local env = { ui = ui, calls = {}, open = true, cap = 300, hidden = false, recalcs = {}, planCalls = {},
        accountCalls = {}, savingCalls = {} }
    local function called(name) env.calls[#env.calls + 1] = name end

    _G.UnitGUID = function() return "Player-1-WINDOW01" end
    _G.UnitFactionGroup = function() return "Alliance" end
    _G.UnitRace = function() return "Human", "Human" end
    _G.CraftLib = nil
    _G.Syndicator = nil
    _G.TSM_API = nil
    _G.Auctionator = nil

    local addon = { ClientFamily = family }
    env.addon = addon
    addon.Debug = function() end
    addon.IsDebugEnabled = function() return false end
    addon.Print = function(_, msg) env.printed = msg end
    addon.db = { profile = {}, char = { learnedRecipes = {} }, global = { characters = {} } }

    env.anchor = ui.newFrame("Frame", "ProfessionWindow")
    env.anchor.height = 500
    addon.Client = {
        IsOpen = function() return env.open end,
        AnchorFrame = function() return env.anchor end,
        PanelOffsetX = function() return family == "forever" and 65 or 10 end,
        GetLine = function() return "tailoring", 143, env.cap end,
        UnlearnedHiddenByFilter = function() return env.hidden end,
        GetItemInfo = function() return nil end,
        PlayerSkill = function() return env.playerSkill or 0 end,
        ProfessionRank = function() return env.playerSkill or 0, env.playerCap end,
        Now = function() return env.now or 1 end,
    }
    addon.Pathfinder = {
        currentPath = nil,
        GetPins = function(_, key) return addon.CharStore:Profession(key).pins end,
        PinnedAt = function(self, key, skill) return addon.Pins.Find(self:GetPins(key), skill) end,
        PinRange = function(self, key, from, to, id) called("pin"); addon.Pins.Add(self:GetPins(key), from, to, id) end,
        UnpinAt = function(self, key, skill) called("unpin"); addon.Pins.RemoveAt(self:GetPins(key), skill) end,
        SetTargetSkill = function(_, key, value, actual, milestones)
            called("target")
            env.targetArgs = { key, value, actual, milestones }
            local cap = milestones[#milestones]
            value = math.max(actual + 1, math.min(cap, value))
            addon.CharStore:Profession(key).target = value < cap and value or nil
            return value
        end,
        GetArrowStep = function(_, path) return path.steps[1] end,
        CalculateMissingMaterials = function() return {} end,
        -- The account of the whole path (the receipt is built from it):
        -- env.account supplies it, else there is nothing to pay. env.stockSaves
        -- is what the owned stock saves.
        Account = function(_, steps, inventory, breakdown, prices, saleValues)
            env.accountCalls[#env.accountCalls + 1] = { steps = steps, inventory = inventory, breakdown = breakdown,
                prices = prices, saleValues = saleValues }
            local account = {}
            for k, v in pairs(env.account or { missing = { rows = {}, recipeRows = {}, buyTotal = 0, recipeCosts = 0 },
                    reagents = 0, recipes = 0, spend = 0, sale = 0, net = 0 }) do
                account[k] = v
            end
            return account
        end,
        StockSaving = function(_, steps, prices, spend)
            env.savingCalls[#env.savingCalls + 1] = { steps = steps, prices = prices, spend = spend }
            return env.stockSaves or 0
        end,
        -- Planning: env.planPath(profKey, opts) may supply the path; nil data for "mining".
        CalculateForProfession = function(_, key, opts)
            called("plan")
            env.planCalls[#env.planCalls + 1] = { key = key, opts = opts }
            if env.planPath then return env.planPath(key, opts) end
            if key == "mining" then return nil end
            local has = (env.playerSkill or 0) > 0
            return M.path({
                planning = true, professionKey = key, profession = addon.Constants.PROFESSIONS[key].name,
                hasProfession = has, planFromOne = (has and opts and opts.planFromOne) or nil,
                actualSkill = has and env.playerSkill or 1,
            })
        end,
    }
    addon.PriceManager = {
        cache = {},
        PathSummary = function() return env.priceSummary or { total = 2, tsm = 2, stale = 0, unpriced = 0, loading = 0 } end,
        SummaryLines = function() return env.priceLines or { { text = "Prices: TSM 2", r = 0.6, g = 0.6, b = 0.6 } } end,
        PeekPriceInfo = function(_, itemId) return (env.priceInfo or {})[itemId] or { price = M.PRICES[itemId], source = "TSM", detail = "DBRecent" } end,
        PriceLine = function(info) return "Price: " .. tostring(info and info.source) end,
    }
    -- Crafted items still waiting for their data, as counted right now.
    addon.SaleValue = { LoadingCount = function() return env.saleLoading or 0 end }
    addon.Professions = {
        active = "tailoring",
        Get = function(_, key)
            if key == "tailoring" then
                return { name = "Tailoring", milestones = M.MILESTONES, recipes = { M.GLOVES, M.SHIRT, M.CAPE } }
            elseif key == "alchemy" then
                return { name = "Alchemy", milestones = M.MILESTONES, recipes = {} }
            end
        end,
    }
    addon.Inventory = {
        ScanAll = function() return env.stock or {}, env.stockSources or {}, env.stockMeta end,
        ScanBags = function() return env.stock or {} end,
    }
    addon.RecipeDetails = {
        Show = function(_, recipe, skill) called("details"); env.details = { recipe = recipe, skill = skill } end,
        Toggle = function(_, recipe, skill) called("details"); env.details = { recipe = recipe, skill = skill } end,
        Hide = function() called("detailsHide") end,
    }
    addon.Recalculate = function(_, reason)
        called("recalc")
        env.recalcs[#env.recalcs + 1] = reason
    end
    addon.UpdateShoppingPanel = function() called("shopping") end
    addon.UpdateDisplay = function() called("display") end

    for _, path in ipairs(FILES) do
        assert(loadfile(path))("LazyProf", addon)
        if path == "Core/Config.lua" then
            for k, v in pairs(addon.defaults.profile) do
                if type(v) == "table" then
                    local copy = {}
                    for kk, vv in pairs(v) do copy[kk] = vv end
                    addon.db.profile[k] = copy
                else
                    addon.db.profile[k] = v
                end
            end
        end
    end
    for _, path in ipairs(extraFiles or {}) do
        assert(loadfile(path))("LazyProf", addon)
    end
    env.window = addon.GuideWindow
    env.shell = addon.PanelShell
    return env
end

-- Texts of the list's rows, one per line (lead, text and right text).
function M.rowTexts(window)
    local out = {}
    for _, row in ipairs(window.list.rows) do
        local d = row.desc
        local parts = {}
        if d.lead then parts[#parts + 1] = d.lead end
        parts[#parts + 1] = d.text or ""
        if d.cols then parts[#parts + 1] = table.concat(d.cols, ",") end
        if d.right and d.right ~= "" then parts[#parts + 1] = d.right end
        out[#out + 1] = table.concat(parts, " | ")
    end
    return out
end

-- The receipt's lines as shown, one per line: label, amount and note joined
-- with " | " (a line that is only a note is just the note).
function M.receiptTexts(window)
    local out = {}
    for _, row in ipairs(window.receiptRows or {}) do
        local parts = {}
        for _, key in ipairs({ "label", "amount", "note" }) do
            local region = row[key]
            if region.shown and region.text and region.text ~= "" then
                parts[#parts + 1] = region.text
            end
        end
        if #parts > 0 then
            out[#out + 1] = table.concat(parts, " | ")
        end
    end
    return out
end

-- The row that carries a button with this text.
function M.findButton(window, text)
    for _, row in ipairs(window.list.rows) do
        local button = row.desc.button
        if button and button.text == text then
            return row
        end
    end
end

-- The row whose descriptor text contains `needle` (plain text).
-- (A Shopping note - "for 2. Shirt, to make Bolt" - is about the row above
-- it and is never the row looked for.)
function M.findRow(window, needle)
    for _, row in ipairs(window.list.rows) do
        local d = row.desc
        if not d.note and ((d.text and d.text:find(needle, 1, true)) or (d.lead and d.lead:find(needle, 1, true))) then
            return row
        end
    end
end

return M
