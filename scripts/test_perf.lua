-- scripts/test_perf.lua
--
-- Standalone Lua 5.1 unit tests for the calc-performance fixes:
--   1. LazyProf:IsDebugEnabled(category)          (Core/Init.lua)
--   2. LazyProf:ScheduleItemInfoRecalc()          (Core/Init.lua) - trailing debounce
--   3. LazyProf:OnItemInfoReceived wiring          (Core/Init.lua)
--   4. RecipeAvailability per-recalc memo          (Modules/Recipes/Availability.lua)
--   5. LazyProf:ScheduleRecalculation() / ScheduleShoppingListRefresh() /
--      ScheduleDebugWindowUpdate() (Core/Init.lua) - first-wins debounces;
--      C_Timer.After returns nothing
--   6. LazyProf:OnBagUpdate (Core/Init.lua) with the stock memory behind it
--      (Modules/Inventory/Scanner.lua): a burst of bag updates is one light
--      refresh and one remembered snapshot, never a recalculation
--
-- Run from the addon root:  lua5.1 scripts/test_perf.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

-- ---------------------------------------------------------------------------
-- Controllable fake clock + C_Timer
-- ---------------------------------------------------------------------------
local fakeNow = 0
local pending = {}   -- { {due=, fn=}, ... }
_G.GetTime = function() return fakeNow end
-- Like the client's C_Timer.After, returns nothing (no handle to keep).
_G.C_Timer = { After = function(delay, fn)
    if delay < 0 then delay = 0 end
    table.insert(pending, { due = fakeNow + delay, fn = fn })
end }
local function advance(dt)
    fakeNow = fakeNow + dt
    local progressed = true
    while progressed do
        progressed = false
        for i, t in ipairs(pending) do
            if t.due <= fakeNow + 1e-9 then
                table.remove(pending, i)
                t.fn()
                progressed = true
                break
            end
        end
    end
end

-- Other load-time stubs
_G.LibStub = function(_name)
    return { NewAddon = function(_self, addon, ...) return addon end }
end
_G.date = function(_fmt) return "12:00:00" end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

-- ---------------------------------------------------------------------------
-- Load addon files into one shared addon table
-- ---------------------------------------------------------------------------
local addon = {}

-- Utils/Constants stubs the Cheapest strategy captures at load time.
local fmCalls = 0   -- shared with section E to count FormatMoney string-building
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end
addon.Constants = { SALE_LOADING_TIMEOUT = 20 }   -- as in Core/Constants.lua
addon.Utils = {
    DeepCopy = deepcopy,
    GetSkillColor = function(_skill, _range) return "orange" end,
    GetSkillUpChance = function(_eff, _range) return 0.5 end,
    FormatMoney = function(c) fmCalls = fmCalls + 1; return tostring(c) end,
    GetItemInfo = function(itemId) return "Item" .. tostring(itemId) end,
}

assert(loadfile("Core/Init.lua"))("LazyProf", addon)
assert(loadfile("Modules/Recipes/Availability.lua"))("LazyProf", addon)
assert(loadfile("Modules/Recipes/SelfFound.lua"))("LazyProf", addon)
assert(loadfile("Modules/Pathfinder/Pins.lua"))("LazyProf", addon)
assert(loadfile("Modules/Pathfinder/StrategyCore.lua"))("LazyProf", addon)
assert(loadfile("Modules/Pathfinder/Strategies/Cheapest.lua"))("LazyProf", addon)
local LP = _G.LazyProf
assert(LP == addon, "Init.lua did not expose the shared addon table as _G.LazyProf")

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
local failures, total = 0, 0
local function check(name, cond, detail)
    total = total + 1
    if cond then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
    end
end
local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then check(name .. " executed without error", false, err) end
end
local function flush()
    advance(10)        -- drain any pending timers to a settled state
    pending = {}
    fakeNow = fakeNow + 10
end

-- ===========================================================================
-- A: IsDebugEnabled
-- ===========================================================================
section("A", function()
    check("A IsDebugEnabled exists", type(LP.IsDebugEnabled) == "function")
    LP.db = { profile = { debug = false, debugCategories = { scoring = true, pathfinder = false } } }
    check("A off when master debug off", LP:IsDebugEnabled("scoring") == false)
    LP.db.profile.debug = true
    check("A on when master + category on", LP:IsDebugEnabled("scoring") == true)
    check("A off when category disabled", LP:IsDebugEnabled("pathfinder") == false)
    check("A nil category follows master", LP:IsDebugEnabled() == true)
    LP.db = nil
    check("A safe when db missing", LP:IsDebugEnabled("scoring") == false)
end)

-- ===========================================================================
-- B: ScheduleItemInfoRecalc trailing-debounce coalescing
-- ===========================================================================
section("B", function()
    check("B ScheduleItemInfoRecalc exists", type(LP.ScheduleItemInfoRecalc) == "function")

    local recalcCount = 0
    LP.Recalculate = function(_self, _reason) recalcCount = recalcCount + 1 end

    -- B1: single arrival -> exactly one recalc after the quiet window
    flush(); recalcCount = 0
    LP:ScheduleItemInfoRecalc()
    advance(0.6)
    check("B1 single arrival -> 1 recalc", recalcCount == 1, recalcCount)

    -- B2: a burst of 20 arrivals over ~2s collapses into ONE recalc
    flush(); recalcCount = 0
    for _ = 1, 20 do LP:ScheduleItemInfoRecalc(); advance(0.1) end
    advance(0.6)  -- let the quiet window elapse after the last arrival
    check("B2 burst of 20 -> 1 recalc (was ~20)", recalcCount == 1, recalcCount)

    -- B3: a never-quiet stream still recalcs by the max-wait cap (no starvation)
    flush(); recalcCount = 0
    for _ = 1, 45 do LP:ScheduleItemInfoRecalc(); advance(0.1) end  -- 4.5s continuous
    check("B3 continuous stream still recalcs (max-wait)", recalcCount >= 1, recalcCount)
end)

-- ===========================================================================
-- C: OnItemInfoReceived drives the coalescing path (not the per-event recalc)
-- ===========================================================================
section("C", function()
    LP.PriceManager = { flooredItems = { [123] = true, [456] = true }, cache = { [123] = {} } }
    local schedCount = 0
    local saved = LP.ScheduleItemInfoRecalc
    LP.ScheduleItemInfoRecalc = function(_self) schedCount = schedCount + 1 end

    LP:OnItemInfoReceived("e", 999, true)   -- not a floored item
    check("C unfloored item -> no schedule", schedCount == 0, schedCount)

    LP:OnItemInfoReceived("e", 123, true)   -- floored -> coalesced schedule + cleared
    check("C floored item -> one coalesced schedule", schedCount == 1, schedCount)
    check("C floored item cleared from flooredItems", LP.PriceManager.flooredItems[123] == nil)

    LP:OnItemInfoReceived("e", 456, false)  -- success == false -> ignored
    check("C failed item-info -> no schedule", schedCount == 1, schedCount)

    -- A crafted item a sale value is waiting for: its arrival plans again
    -- through the same coalescing path, and so does its failure (the "still
    -- loading" note has to go).
    local waited = { [700] = true, [701] = true }
    local told = {}
    LP.SaleValue = { OnItemInfo = function(_self, itemId, success)
        told[#told + 1] = tostring(itemId) .. ":" .. tostring(success)
        local was = waited[itemId] or false
        waited[itemId] = nil
        return was
    end }
    LP:OnItemInfoReceived("e", 700, true)
    check("C waited sale item -> one coalesced schedule", schedCount == 2, schedCount)
    LP:OnItemInfoReceived("e", 701, false)
    check("C waited sale item that failed -> scheduled too", schedCount == 3, schedCount)
    check("C the sale module is told the outcome", told[1] == "700:true" and told[2] == "701:false", table.concat(told, " "))
    LP:OnItemInfoReceived("e", 999, true)
    check("C unrelated item with sale values present -> no schedule", schedCount == 3, schedCount)
    LP.PriceManager.flooredItems[800] = true
    waited[800] = true
    LP:OnItemInfoReceived("e", 800, true)
    check("C floored reagent that is also a waited item -> one schedule, not two", schedCount == 4, schedCount)
    LP.SaleValue = nil

    LP.ScheduleItemInfoRecalc = saved
end)

-- ===========================================================================
-- C2: the "still loading" note goes away by itself: one redraw when the wait
-- for crafted-item data is over, never a recalculation
-- ===========================================================================
section("C2", function()
    check("C2 ScheduleSaleLoadingRefresh exists", type(LP.ScheduleSaleLoadingRefresh) == "function")
    advance(10)   -- let timers left by the sections above run out first
    local refreshes, recalcs = 0, 0
    local savedWindow, savedRecalc = LP.GuideWindow, LP.Recalculate
    LP.GuideWindow = { Refresh = function() refreshes = refreshes + 1 end }
    LP.Recalculate = function() recalcs = recalcs + 1 end
    for _ = 1, 5 do LP:ScheduleSaleLoadingRefresh() end
    advance(19)
    check("C2 nothing before the wait is over", refreshes == 0, refreshes)
    advance(3)
    check("C2 one redraw for many requests", refreshes == 1, refreshes)
    check("C2 no recalculation", recalcs == 0, recalcs)
    advance(60)
    check("C2 and no further redraw", refreshes == 1, refreshes)
    LP:ScheduleSaleLoadingRefresh()
    advance(22)
    check("C2 a later request redraws again", refreshes == 2, refreshes)

    -- Items asked for later than the first batch have a later deadline: while
    -- any is still waiting when the redraw runs, another redraw is scheduled.
    local waitingCount = 1
    LP.SaleValue = { WaitingCount = function() return waitingCount end, OnItemInfo = function() return false end }
    LP:ScheduleSaleLoadingRefresh()
    advance(22)
    check("C2 redraw with something still waiting", refreshes == 3, refreshes)
    waitingCount = 0
    advance(22)
    check("C2 it is followed by another one", refreshes == 4, refreshes)
    advance(60)
    check("C2 and that is the last once nothing waits", refreshes == 4, refreshes)
    check("C2 still no recalculation", recalcs == 0, recalcs)
    LP.SaleValue = nil
    LP.GuideWindow, LP.Recalculate = savedWindow, savedRecalc
end)

-- ===========================================================================
-- D: RecipeAvailability per-recalc memo
-- ===========================================================================
section("D", function()
    local Av = LP.RecipeAvailability
    check("D BeginRecalc exists", type(Av.BeginRecalc) == "function")
    check("D EndRecalc exists", type(Av.EndRecalc) == "function")
    check("D IsRecipeAvailableUncached exists", type(Av.IsRecipeAvailableUncached) == "function")

    local underlying = 0
    Av.IsRecipeAvailableUncached = function(_self, _recipe)
        underlying = underlying + 1
        return true, { type = "test" }
    end

    local r1 = { id = 111 }
    Av:BeginRecalc()
    local a1 = Av:IsRecipeAvailable(r1)
    local a2 = Av:IsRecipeAvailable(r1)  -- same id -> served from memo
    check("D memo: underlying called once per id", underlying == 1, underlying)
    check("D memo returns correct value", a1 == true and a2 == true)

    Av:EndRecalc()
    Av:IsRecipeAvailable(r1)             -- memo disabled outside a recalc
    check("D uncached outside recalc", underlying == 2, underlying)

    underlying = 0
    Av:BeginRecalc()
    Av:IsRecipeAvailable(r1)
    Av:IsRecipeAvailable({ id = 222 })
    Av:IsRecipeAvailable(r1)
    check("D per-recalc: 2 unique ids -> 2 underlying calls", underlying == 2, underlying)
    Av:EndRecalc()
end)

-- ===========================================================================
-- E: hot debug blocks build NO strings when debug is off (Fix 3b)
-- ===========================================================================
section("E", function()
    local cheapest = LP.PathfinderStrategies and LP.PathfinderStrategies.cheapest
    check("E cheapest strategy loaded", type(cheapest) == "table")

    local recipes = {}
    for i = 1, 3 do
        recipes[i] = {
            id = i, name = "R" .. i, learned = true,
            skillRequired = 1,
            skillRange = { orange = 1, yellow = 20, green = 40, gray = 60 },
            reagents = { { itemId = 1, count = 1, name = "Mat" } },
        }
    end
    local prices = { [1] = 100 }

    LP.db = { profile = { debug = false, strategy = "cheapest",
        includeGreenRecipes = true, suggestUnlearnedRecipes = false,
        debugCategories = { scoring = false, pathfinder = false } } }

    fmCalls = 0
    local pathOff = cheapest:Calculate(1, 5, recipes, {}, prices, 0, {})
    check("E debug OFF: a path is still produced", type(pathOff) == "table" and #pathOff > 0,
        pathOff and #pathOff)
    check("E debug OFF: zero FormatMoney from top-10 logging", fmCalls == 0, fmCalls)

    LP.db.profile.debug = true
    LP.db.profile.debugCategories.scoring = true
    fmCalls = 0
    cheapest:Calculate(1, 5, recipes, {}, prices, 0, {})
    check("E debug ON: top-10 logging builds FormatMoney strings", fmCalls > 0, fmCalls)
end)

-- ===========================================================================
-- F: ScheduleRecalculation coalesces a burst into one recalc
-- ===========================================================================
section("F", function()
    local recalcs = {}
    LP.Recalculate = function(_self, reason) recalcs[#recalcs + 1] = reason end

    flush(); recalcs = {}
    -- A Forever first open: show + data-source change + list updates.
    LP:ScheduleRecalculation("trade skill opened")
    LP:ScheduleRecalculation("skill changed")
    LP:ScheduleRecalculation("skill changed")
    advance(0.6)
    check("F1 three schedules within the delay -> 1 recalc", #recalcs == 1, #recalcs)
    check("F1 the first reason is kept", recalcs[1] == "trade skill opened", recalcs[1])

    LP:ScheduleRecalculation("later")
    advance(0.6)
    check("F2 a schedule after the recalc ran -> one more", #recalcs == 2 and recalcs[2] == "later", #recalcs)
end)

-- ===========================================================================
-- G: ScheduleShoppingListRefresh coalesces a burst into one refresh
-- ===========================================================================
section("G", function()
    local refreshes = 0
    LP.RefreshShoppingList = function(_self) refreshes = refreshes + 1 end

    flush(); refreshes = 0
    for _ = 1, 5 do LP:ScheduleShoppingListRefresh() end   -- BAG_UPDATE burst while crafting
    advance(0.4)
    check("G1 five schedules within the delay -> 1 refresh", refreshes == 1, refreshes)

    LP:ScheduleShoppingListRefresh()
    advance(0.4)
    check("G2 a schedule after the refresh ran -> one more", refreshes == 2, refreshes)
end)

-- ===========================================================================
-- H: ScheduleDebugWindowUpdate coalesces a burst of log lines into one redraw
-- ===========================================================================
section("H", function()
    local redraws = 0
    LP.debugFrame = { IsShown = function() return true end }
    LP.UpdateDebugWindowContent = function(_self) redraws = redraws + 1 end

    flush(); redraws = 0
    for _ = 1, 50 do LP:ScheduleDebugWindowUpdate() end   -- one recalculation's debug lines
    advance(0.3)
    check("H1 fifty schedules within the delay -> 1 redraw", redraws == 1, redraws)

    LP:ScheduleDebugWindowUpdate()
    advance(0.3)
    check("H2 a schedule after the redraw ran -> one more", redraws == 2, redraws)
    LP.debugFrame = nil
end)

-- ===========================================================================
-- I: closing the auction house drops the price cache (a scan just happened)
-- ===========================================================================
section("I", function()
    check("I handler exists", type(LP.OnAuctionHouseClosed) == "function")
    local clears, recalcs, open = {}, {}, true
    local savedPM, savedClient = LP.PriceManager, LP.Client
    LP.PriceManager = { OnAuctionHouseVisited = function() clears[#clears + 1] = true end }
    LP.Client = { IsOpen = function() return open end }
    LP.Recalculate = function(_self, reason) recalcs[#recalcs + 1] = reason end

    flush(); recalcs = {}
    -- The close event may fire twice per close.
    LP:OnAuctionHouseClosed()
    LP:OnAuctionHouseClosed()
    advance(0.6)
    check("I visit noted on each close", #clears == 2, #clears)
    check("I profession window open: one recalc", #recalcs == 1 and recalcs[1] == "auction house closed",
        #recalcs .. " " .. tostring(recalcs[1]))

    flush(); clears, recalcs, open = {}, {}, false
    LP:OnAuctionHouseClosed()
    advance(0.6)
    check("I window closed: visit noted, no recalc", #clears == 1 and #recalcs == 0, #recalcs)
    LP.PriceManager, LP.Client = savedPM, savedClient
end)

-- ===========================================================================
-- J: a burst of bag updates (batch crafting) with the stock memory wired in:
-- one light refresh, one bag snapshot, no recalculation
-- ===========================================================================
section("J", function()
    assert(loadfile("Modules/Inventory/StockMemory.lua"))("LazyProf", LP)
    assert(loadfile("Modules/Inventory/Scanner.lua"))("LazyProf", LP)
    local savedClient, savedDb = LP.Client, LP.db
    local bagReads, bankReads = 0, 0
    LP.db = { profile = { includeBankItems = true, includeAltCharacters = true }, char = {}, global = {} }
    LP.Client = {
        IsOpen = function() return true end,
        BagContents = function() bagReads = bagReads + 1; return { [1] = 1 }, {}, 16 end,
        IsBankOpen = function() return false end,
        BankContents = function() bankReads = bankReads + 1; return nil end,
        BankKindOfBag = function() return nil end,
        CharacterIdentity = function() return { guid = "Player-1-PERF", name = "Perf", world = "eu-pvp", faction = "Horde" } end,
        IsSelfFoundCharacter = function() return false end,
        Now = function() return 1763900000 end,
    }
    _G.Syndicator = nil
    local recalcs, refreshes = 0, 0
    LP.Recalculate = function() recalcs = recalcs + 1 end
    LP.RefreshShoppingList = function() refreshes = refreshes + 1 end
    LP.MerchantPanel = nil
    LP.GuideWindow = nil

    flush(); recalcs, refreshes, bagReads = 0, 0, 0
    for _ = 1, 40 do                      -- forty crafts' worth of bag updates within a second
        LP:OnBagUpdate("BAG_UPDATE", 0)
        LP:OnBagUpdate("BAG_UPDATE", 1)
        advance(0.02)
    end
    check("J no bag read inside the burst", bagReads == 0, bagReads)
    advance(3)
    check("J one bag snapshot for the burst", bagReads == 1, bagReads)
    check("J the bank is not read while it is closed", bankReads == 0, bankReads)
    check("J light refreshes only (debounced)", refreshes >= 1 and refreshes <= 4, refreshes)
    check("J no recalculation", recalcs == 0, recalcs)
    check("J the snapshot is in the saved table",
        LP.db.global.stock.characters["Player-1-PERF"].bags.items[1] == 1)
    flush()
    LP.Client, LP.db = savedClient, savedDb
end)

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
