-- scripts/lib/harness.lua
--
-- Headless test harness: stubs the WoW globals the addon modules touch, loads
-- CraftLib data for a chosen client, and loads LazyProf modules in TOC order.
-- Run from the addon root (all paths are relative to it).
--
-- Fidelity limits: no auction prices exist for recipe items (recipe-item
-- availability via AH is never satisfied), PriceManager is not loaded (prices
-- come from harness.priceTable), and the inventory is always empty.

local harness = {}

local function loadChunk(path, ...)
    local fn, err = loadfile(path)
    assert(fn, err)
    return fn(...)
end

local function shallowCopy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    return r
end

-- Install the WoW globals the modules need. opts: race, interface, sod, camelot.
function harness.stubWow(opts)
    opts = opts or {}
    _G.LibStub = function(_name)
        return {
            NewAddon = function(_self, addon) return addon end,
            New = function() return {} end,
        }
    end
    _G.C_Timer = { After = function() end }
    _G.GetTime = function() return 0 end
    _G.UnitRace = function() return opts.race or "Human", opts.race or "Human" end
    _G.GetBuildInfo = function()
        return "0.0.0", "0", "Jan 1 2000", opts.interface or 20505
    end
    _G.GetItemInfo = function() return nil end
    _G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
    _G.date = function() return "00:00:00" end
    _G.strlower = string.lower
    -- WoW adds string:trim(); stock Lua 5.1 does not.
    if not string.trim then
        function string.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    end
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.IsSpellKnown = function() return false end
    _G.InCombatLockdown = function() return false end
    _G.UnitFactionGroup = function() return "Alliance", "Alliance" end

    if opts.sod then
        _G.Enum = { SeasonID = { SeasonOfDiscovery = 2 } }
        _G.C_Seasons = { GetActiveSeason = function() return 2 end }
    else
        _G.Enum = nil
        _G.C_Seasons = nil
    end
    if opts.camelot then
        _G.WOW_PROJECT_ID = 99
        _G.WOW_PROJECT_CAMELOT = 99
    else
        _G.WOW_PROJECT_ID = nil
        _G.WOW_PROJECT_CAMELOT = nil
    end
    _G.CreateFrame = function()
        return { RegisterEvent = function() end, SetScript = function() end }
    end
    _G.TSM_API = nil
    _G.Auctionator = nil
    _G.Syndicator = nil
end

-- Load CraftLib Core + every Data line of CraftLib.toc, in order, for `interface`.
function harness.loadCraftLib(interface, opts)
    opts = opts or {}
    opts.interface = interface
    harness.stubWow(opts)
    local CraftLib = {}
    _G.CraftLib = CraftLib
    loadChunk("Libs/CraftLib/Core/Constants.lua", "CraftLib", CraftLib)
    loadChunk("Libs/CraftLib/Core/Init.lua", "CraftLib", CraftLib)
    for line in io.lines("Libs/CraftLib/CraftLib.toc") do
        line = line:gsub("\r", "")
        if line:match("^Data[/\\].+%.lua$") then
            local rel = line:gsub("\\", "/")
            loadChunk("Libs/CraftLib/" .. rel, "CraftLib", CraftLib)
        end
    end
    return CraftLib
end

-- Load the given LazyProf files (in the order given) against a stub addon table.
-- db.profile is seeded from Core/Config.lua defaults once Config.lua is loaded.
function harness.loadLazyProf(files)
    local LazyProf = {}
    _G.LazyProf = LazyProf
    LazyProf.Debug = function() end
    LazyProf.IsDebugEnabled = function() return false end
    -- Nothing owned: snapshots pin pure market-price scoring.
    LazyProf.Inventory = { ScanAll = function() return {}, {} end }
    LazyProf.db = { profile = {}, char = { learnedRecipes = {}, priceCache = {} } }
    for _, path in ipairs(files) do
        loadChunk(path, "LazyProf", LazyProf)
        if path == "Core/Config.lua" then
            assert(LazyProf.defaults and LazyProf.defaults.profile,
                "Core/Config.lua did not define LazyProf.defaults.profile")
            local profile = {}
            for k, v in pairs(LazyProf.defaults.profile) do
                profile[k] = type(v) == "table" and shallowCopy(v) or v
            end
            LazyProf.db.profile = profile
        end
    end
    return LazyProf
end

-- Deterministic price per reagent item id.
function harness.priceTable(recipes)
    local prices = {}
    for _, recipe in ipairs(recipes) do
        for _, reagent in ipairs(recipe.reagents or {}) do
            prices[reagent.itemId] = 100 + (reagent.itemId * 37) % 5000
        end
    end
    return prices
end

-- One line per step ("bridge" marks a green recipe bridging a gap); each gap
-- from meta (optional) is a "gap <from>-<to> <reason>" line in skill order.
function harness.formatSteps(steps, meta)
    local out = {}
    local gaps = meta and meta.gaps or {}
    local gi = 1
    local function gapLine(g)
        return string.format("gap %.2f-%.2f %s", g.from, g.to, tostring(g.reason))
    end
    for _, s in ipairs(steps) do
        while gaps[gi] and gaps[gi].from < (s.skillStart or 0) do
            out[#out + 1] = gapLine(gaps[gi])
            gi = gi + 1
        end
        local rid = s.recipe and s.recipe.id
        out[#out + 1] = string.format("%.2f-%.2f %s x%s %s",
            s.skillStart or 0, s.skillEnd or 0, tostring(rid),
            tostring(s.quantity), tostring(s.totalCost)) .. (s.bridge and " bridge" or "")
    end
    for i = gi, #gaps do
        out[#out + 1] = gapLine(gaps[i])
    end
    return table.concat(out, "\n") .. "\n"
end

return harness
