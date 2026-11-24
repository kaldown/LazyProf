-- Core/Init.lua
local ADDON_NAME, LazyProf = ...

LazyProf = LibStub("AceAddon-3.0"):NewAddon(
    LazyProf,
    ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceHook-3.0"
)

_G.LazyProf = LazyProf

function LazyProf:OnInitialize()
    -- Skip initialization if CraftLib dependency is missing
    if self.dependencyCheckFailed then
        return
    end

    self.db = LibStub("AceDB-3.0"):New("LazyProfDB", self.defaults, true)
    -- Settings an older version saved under names that no longer exist
    if self.MigrateSettings then
        self.MigrateSettings(self.db.sv)
    end
    -- At logout the database tidies the saved tables. Its shutdown notice
    -- comes before that: the moment for a last write that is sure to be kept.
    -- (The client's own logout event is heard as well, through the adapter;
    -- which of the two comes first is not defined.)
    if self.db.RegisterCallback then
        self.db.RegisterCallback(self, "OnDatabaseShutdown", "OnDatabaseShutdown")
    end
    self:RegisterChatCommand("lazyprof", "SlashCommand")
    self:RegisterChatCommand("lp", "SlashCommand")
    if self.SetupConfig then
        self:SetupConfig()
    end
    local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON_NAME, "Version") or "?"
    self:Print("v" .. version .. " loaded. Type /lp for options.")
end

function LazyProf:OnEnable()
    -- Skip enabling if CraftLib dependency is missing
    if self.dependencyCheckFailed then
        return
    end

    -- Initialize professions from CraftLib (must happen after all addons loaded)
    if self.Professions then
        self.Professions:Initialize()
    end

    -- Initialize modules
    if self.PriceManager then
        self.PriceManager:Initialize()
    end
    if self.ArrowManager then
        self.ArrowManager:Initialize()
    end
    if self.GuideWindow then
        self.GuideWindow:Initialize()
    end
    if self.RecipeDetails then
        self.RecipeDetails:Initialize()
    end
    if self.MerchantPanel then
        self.MerchantPanel:Initialize()
    end
    if self.TrainerMemory then
        self.TrainerMemory:Initialize()
    end
    if self.ProfessionBrowser then
        self.ProfessionBrowser:Initialize()
    end
    if self.MinimapButton then
        self.MinimapButton:Initialize()
    end
    -- Profession-window events and hooks belong to the client adapter (the
    -- event names differ between client families).
    self.Client:Start({
        onOpen = function() LazyProf:OnTradeSkillShow() end,
        onClose = function() LazyProf:OnTradeSkillClose() end,
        onUpdate = function() LazyProf:OnTradeSkillUpdate() end,
        onScroll = function()
            if LazyProf.ArrowManager then
                LazyProf.ArrowManager:RefreshPosition()
            end
        end,
    })

    -- Register events
    self:RegisterEvent("BAG_UPDATE", "OnBagUpdate")
    -- The client's notice that a batch of bag updates is complete. Only the
    -- reading of the open bank uses it, and the bank is read on WoW Forever
    -- only, where the event is known to exist: BAG_UPDATE_DELAYED, without a
    -- payload (Blizzard_APIDocumentationGenerated/ContainerDocumentation.lua:674-679;
    -- in the client's event list, Ketho BlizzardInterfaceResources, forever
    -- branch, Resources/Events.lua:520; Blizzard listens to it beside
    -- BAG_UPDATE in Blizzard_Professions/Blizzard_ProfessionsCrafting.lua:62, 314).
    -- Asking a client for an event it does not have is an error, so the
    -- other clients are not asked.
    if self.ClientFamily == "forever" then
        self:RegisterEvent("BAG_UPDATE_DELAYED", "OnBagUpdateDelayed")
    end
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", "OnItemInfoReceived")
    self:RegisterEvent("AUCTION_HOUSE_CLOSED", "OnAuctionHouseClosed")

    -- Last, so that nothing above depends on it: the bank and logout events,
    -- and remembering this character's bags (it protects itself)
    if self.Inventory then
        self.Inventory:Initialize()
    end
end

-- Leaving the auction house: a scan may just have run there, so fresh
-- auction prices now win and the cached prices (5-minute cache) are expired
-- for the next calculation. The event can fire twice per close; the
-- recalculation debounce coalesces that. Planning is not recalculated here
-- (that would reset its view while shopping); it uses the new prices the
-- next time a profession is loaded into it.
function LazyProf:OnAuctionHouseClosed()
    if self.PriceManager then
        self.PriceManager:OnAuctionHouseVisited()
    end
    if self.Client and self.Client:IsOpen() then
        self:ScheduleRecalculation("auction house closed")
    end
end

-- When a reagent we could only price with the absolute floor (because its
-- GetItemInfo data had not arrived yet) finishes caching, drop the floor and
-- recalculate so the path reflects the real vendor sell value.
-- The same goes for a crafted item whose sale value was waiting for its data;
-- there a failed load counts too, because the "still loading" note has to go.
function LazyProf:OnItemInfoReceived(event, itemId, success)
    local changed = false
    if self.SaleValue and self.SaleValue:OnItemInfo(itemId, success) then
        changed = true
    end
    local pm = self.PriceManager
    if success and pm and pm.flooredItems and pm.flooredItems[itemId] then
        pm.flooredItems[itemId] = nil
        pm.cache[itemId] = nil
        changed = true
    end
    if changed then
        self:ScheduleItemInfoRecalc()
    end
end

function LazyProf:SlashCommand(input)
    local cmd = strlower(input or "")

    if cmd == "browse" then
        if self.ProfessionBrowser then
            self.ProfessionBrowser:Toggle()
        end
    elseif cmd == "scan" then
        self:Print("AH scanning not yet implemented.")
    elseif cmd == "reset" then
        self:ResetSettings()
        self:Print("Database reset.")
    elseif cmd == "resetpanels" then
        if self.PanelShell then
            self.PanelShell:ResetPositions()
        end
        self:Print("Panel positions reset.")
    elseif cmd == "log" then
        self:ShowDebugLog()
    elseif cmd == "diag" then
        if self.ClientFamily == "forever" then
            self:Print("Diagnostics: /lp diag forever - dumps client facts and adapter results to a copyable window.")
        else
            self:Print("Diagnostics: /lp diag learned - dumps learned-recipe detection state to a copyable window.")
        end
        self:Print("Diagnostics: /lp diag prices - lists every reagent price of the path and where it came from.")
        self:Print("Diagnostics: /lp diag merchant - at a merchant: what it sells as LazyProf reads it, and what would be bought.")
        self:Print("Diagnostics: /lp diag trainer - at a profession trainer: what it lists as LazyProf reads it, and what is remembered.")
        self:Print("Diagnostics: /lp diag stock - which bags and banks are remembered for your characters, and what the bank reads as (run it at an open bank).")
    elseif cmd == "diag stock" then
        self:RunStockDiagnostic()
    elseif cmd == "diag prices" then
        self:RunPriceDiagnostic()
    elseif cmd == "diag merchant" then
        self:RunMerchantDiagnostic()
    elseif cmd == "diag trainer" then
        self:RunTrainerDiagnostic()
    elseif cmd == "diag learned" and self.ClientFamily ~= "forever" then
        self:RunLearnedDiagnostic()
    elseif cmd == "diag forever" and self.ClientFamily == "forever" then
        self:RunLearnedDiagnostic("forever")
    elseif cmd == "diag learned" or cmd == "diag forever" then
        self:Print(cmd .. " is not available on this client")
    elseif self.configRegistered then
        LibStub("AceConfigDialog-3.0"):Open("LazyProf")
    else
        self:Print("Commands: /lp | /lp browse | /lp reset | /lp resetpanels | /lp log | /lp diag")
    end
end

-- /lp reset and "Reset All Settings": every setting goes back to its default,
-- and with the settings the rest of what the database holds. What LazyProf
-- remembers of the characters' bags and banks is not a setting - it cannot be
-- had again without playing every character and opening every bank - and has
-- a button of its own ("Forget remembered characters"). So it is taken out
-- before the reset and put back after it; a saved value that is not a table
-- is not put back. Then nothing a scan kept may answer any more, and what is
-- shown is planned and drawn again.
function LazyProf:ResetSettings()
    local stock = self.db.global.stock
    self.db:ResetDB()
    if type(stock) == "table" then
        self.db.global.stock = stock
    end
    if self.Inventory then
        self.Inventory:OnSettingsReset()
    end
    self:Recalculate("settings reset")
end

-- Profession window opened (the client adapter also hooks list scrolling).
function LazyProf:OnTradeSkillShow()
    -- Panels the user closed may show again once the window is reopened.
    if self.PanelShell then
        self.PanelShell:ResetClosed()
    end
    -- The LazyProf window docks to the profession window (a planning view is
    -- set aside until it closes).
    if self.GuideWindow then
        self.GuideWindow:OnProfessionOpened()
    end
    self:ScheduleRecalculation("trade skill opened")
end

function LazyProf:OnTradeSkillUpdate()
    -- PERFORMANCE FIX (GitHub Issue #3): Only recalculate when skill actually changes.
    -- The profession-window update event fires for many reasons (scrolling, UI
    -- refresh, etc). Full path recalculation is expensive - only do it when the
    -- path might change.
    -- DO NOT REVERT THIS to unconditional ScheduleRecalculation() - it causes FPS hitches.
    -- A different profession at the same skill (switched while the window
    -- stays open) needs a new path too.
    local profKey, currentSkill = self.Client:GetLine()
    if not currentSkill then return end
    if currentSkill ~= self.lastCalculatedSkill then
        self:ScheduleRecalculation("skill changed")
    elseif profKey ~= self.lastCalculatedProfKey then
        self:ScheduleRecalculation("profession changed")
    end
end

function LazyProf:OnTradeSkillClose()
    if self.ArrowManager then
        self.ArrowManager:Hide()
    end
    -- Before the window: it may go back to a planning view, which keeps its
    -- own recipe details.
    if self.RecipeDetails then
        self.RecipeDetails:Hide()
    end
    if self.GuideWindow then
        self.GuideWindow:OnProfessionClosed()
    end
end

-- The database is about to be saved (logout or reload).
function LazyProf:OnDatabaseShutdown()
    if self.Inventory then
        self.Inventory:OnLogout()
    end
end

function LazyProf:OnBagUpdate(event, bagId)
    -- PERFORMANCE FIX (GitHub Issue #3): Don't trigger full recalculation on bag changes.
    -- A change of stock never plans again by itself: the shown route stays and only its
    -- counts and the shopping list are redrawn (lightweight RefreshShoppingList()). The
    -- route is planned again on the events that always did: profession window opened,
    -- skill changed, target / strategy / pin / setting changed, item info, auction house.
    -- DO NOT REVERT THIS to ScheduleRecalculation() - it causes severe FPS hitches
    -- during batch crafting as reported by users with both old and high-end hardware.
    if self.Client:IsOpen() or (self.GuideWindow and self.GuideWindow:PlanningPath()) then
        self:ScheduleShoppingListRefresh()
    end
    -- At a merchant: a purchase may have arrived
    if self.MerchantPanel then
        self.MerchantPanel:OnInventoryChanged()
    end
    -- What the character carries is remembered for its other characters, and
    -- the bank is read again while its window is open. This is the one
    -- BAG_UPDATE handler of the addon, so the update is passed on from here.
    if self.Inventory then
        self.Inventory:OnBagUpdate(bagId)
    end
end

-- A batch of bag updates is complete. Like BAG_UPDATE this event has its one
-- handler here and is passed on; it plans nothing and redraws nothing itself.
function LazyProf:OnBagUpdateDelayed()
    if self.Inventory then
        self.Inventory:OnBagUpdateDelayed()
    end
end

-- Debounced recalculation: the first request in a 0.5s window schedules one
-- recalculation, later ones in that window are dropped. C_Timer.After returns
-- nothing, so a pending flag (not a timer handle) marks the scheduled one.
local recalcPending = false
function LazyProf:ScheduleRecalculation(reason)
    if recalcPending then return end
    recalcPending = true
    C_Timer.After(0.5, function()
        recalcPending = false
        LazyProf:Recalculate(reason)
    end)
end

-- Coalesced recalculation for streaming item-info.
-- On the first open of a profession, hundreds of reagents are not yet in the
-- client item cache, so GetItemInfo returns nil and PriceManager "floors" them.
-- As the data streams back, GET_ITEM_INFO_RECEIVED fires once per item; a plain
-- first-wins debounce re-arms on every arrival and produces a recalc storm
-- (many full Pathfinder:Calculate passes that hitch the game / trip the script
-- execution watchdog). This is a TRAILING debounce: it fires a single recalc
-- only after item-info has been quiet for ITEMINFO_QUIET seconds, with
-- ITEMINFO_MAX_WAIT as a hard cap so a slow stream cannot starve it.
local ITEMINFO_QUIET = 0.5
local ITEMINFO_MAX_WAIT = 3.0
local itemInfoToken = 0
local itemInfoDeadline = nil
function LazyProf:ScheduleItemInfoRecalc()
    local now = GetTime()
    if not itemInfoDeadline then
        itemInfoDeadline = now + ITEMINFO_MAX_WAIT
    end
    itemInfoToken = itemInfoToken + 1
    local myToken = itemInfoToken
    local delay = math.max(0, math.min(ITEMINFO_QUIET, itemInfoDeadline - now))
    C_Timer.After(delay, function()
        -- Only the most recently scheduled callback fires once the stream goes
        -- quiet; the max-wait deadline forces a fire even mid-stream.
        if myToken ~= itemInfoToken and (itemInfoDeadline == nil or GetTime() < itemInfoDeadline) then
            return
        end
        itemInfoToken = 0
        itemInfoDeadline = nil
        LazyProf:Recalculate("item info settled")
    end)
end

-- A crafted item whose data never arrives stops counting as "still loading"
-- after Constants.SALE_LOADING_TIMEOUT seconds. Nothing else happens at that
-- moment, so one redraw is scheduled for it (pending flag, as above): the
-- note goes away by itself. A redraw only, never a recalculation.
local saleLoadingPending = false
function LazyProf:ScheduleSaleLoadingRefresh()
    if saleLoadingPending then return end
    saleLoadingPending = true
    C_Timer.After(self.Constants.SALE_LOADING_TIMEOUT + 1, function()
        saleLoadingPending = false
        if LazyProf.GuideWindow then
            LazyProf.GuideWindow:Refresh()
        end
        -- Items asked for after the first ones have a later deadline: come
        -- back for them.
        if LazyProf.SaleValue and LazyProf.SaleValue.WaitingCount and LazyProf.SaleValue:WaitingCount() > 0 then
            LazyProf:ScheduleSaleLoadingRefresh()
        end
    end)
end

-- PERFORMANCE FIX (GitHub Issue #3): Debounced lightweight shopping list refresh.
-- This is separate from full recalculation and only updates material quantities.
-- Same pending flag as ScheduleRecalculation (C_Timer.After returns nothing).
local shoppingListPending = false
function LazyProf:ScheduleShoppingListRefresh()
    if shoppingListPending then return end
    shoppingListPending = true
    C_Timer.After(0.3, function()
        shoppingListPending = false
        LazyProf:RefreshShoppingList()
    end)
end

-- PERFORMANCE FIX (GitHub Issue #3): Lightweight refresh for stock changes.
-- This reuses the cached path: the bags are rescanned and the window redraws
-- its counts and shopping list from it. Much cheaper than full Recalculate()
-- which re-runs the entire pathfinding algorithm with recipe scoring.
-- Called on BAG_UPDATE instead of full recalculation.
function LazyProf:RefreshShoppingList()
    -- A refresh queued just before the window closed must not show anything.
    local window = self.GuideWindow
    local live = self.Client:IsOpen() and self.Pathfinder.currentPath or nil
    if live and not (live.steps and #live.steps > 0) then
        live = nil
    end
    local planning = window and window:PlanningPath() or nil
    if not (live or planning) then
        return
    end

    -- Rescan inventory; the stages and the shopping list are drawn from it
    -- (stockMeta: how old the remembered part of the stock is)
    local inventory, sourceBreakdown, stockMeta = self.Inventory:ScanAll()
    if live then
        live.inventory, live.sourceBreakdown, live.stockMeta = inventory, sourceBreakdown, stockMeta
    end
    if planning then
        planning.inventory, planning.sourceBreakdown, planning.stockMeta = inventory, sourceBreakdown, stockMeta
    end

    if window then
        window:Refresh()
    end
end

function LazyProf:Recalculate(reason)
    -- A setting that decides which stock counts may just have changed: this
    -- frame's earlier scan must not answer for the new plan.
    if self.Inventory then
        self.Inventory:InvalidateCache()
    end

    -- Track skill level and profession for OnTradeSkillUpdate optimization (Issue #3)
    local profKey, currentSkill = self.Client:GetLine()
    self.lastCalculatedSkill = currentSkill
    self.lastCalculatedProfKey = profKey

    -- Invalidate arrow cache before recalculating (recipe may change)
    if self.ArrowManager then
        self.ArrowManager:InvalidateCache()
    end

    local path = self.Pathfinder:Calculate(reason)
    if path then
        self:UpdateDisplay()
    else
        -- No matching profession data - drop the previous profession's path
        -- (so nothing redraws it later) and hide panels
        self.Pathfinder.currentPath = nil
        self:HideDisplay()
        self:ShowNoDataNotice()
    end

    -- A planning view calculates its own path: plan it again too
    if self.GuideWindow then
        self.GuideWindow:RefreshPlanning(reason)
    end
end

-- The open profession has no recipe data yet (e.g. professions CraftLib holds
-- back on a client): the window says so in one row instead of showing
-- nothing. No path, arrow or shopping list.
function LazyProf:ShowNoDataNotice()
    if not (self.GuideWindow and self.Client:IsOpen()) then return end
    local name = self.Client:NoDataProfessionName()
    if name then
        self.GuideWindow:ShowNotice("No recipe data for " .. name .. " yet.")
    end
end

function LazyProf:HideDisplay()
    if self.ArrowManager then
        self.ArrowManager:Hide()
    end
    if self.GuideWindow then
        self.GuideWindow:HideLive()
    end
end

function LazyProf:UpdateDisplay()
    -- A planning view only needs redrawing (a display setting changed).
    if self.GuideWindow and self.GuideWindow:PlanningPath() then
        self.GuideWindow:Refresh()
    end
    -- The live view belongs to the open profession window; settings changed
    -- with it closed must not bring it back with an old path.
    if not self.Client:IsOpen() then
        return
    end
    local path = self.Pathfinder.currentPath
    if path then
        if self.ArrowManager then
            self.ArrowManager:Update(path)
        end
        if self.GuideWindow then
            self.GuideWindow:Update(path)
        end
    end
end

-- Debug log buffer
-- Bounded in-memory trace. To keep insertion amortized O(1), the buffer is
-- allowed to overshoot debugLogMax by debugLogSlack, then the oldest entries
-- are dropped in a single batch shift -- instead of table.remove(t, 1) on every
-- line, which is O(n) once the buffer is full. The window renders only the last
-- debugRenderMax lines so a large buffer never forces a multi-thousand-line
-- EditBox:SetText layout pass on the UI thread. The buffer is NOT cleared
-- between recalculations and is runtime-only (never saved); use the Clear
-- button to start a fresh capture.
LazyProf.debugLog = {}
LazyProf.debugLogMax = 2000          -- newest entries retained in memory
LazyProf.debugLogSlack = 512         -- overshoot tolerated before one batch trim
LazyProf.debugRenderMax = 400        -- max lines drawn into the window per refresh
LazyProf.debugLogOverflowed = false  -- true once oldest lines have been dropped
LazyProf.debugFilter = nil  -- nil = show all, or category name

-- Category display names for UI
LazyProf.debugCategoryNames = {
    scoring = "Pathfinder Scoring",
    pathfinder = "Pathfinder Core",
    ui = "UI Updates",
    professions = "Professions",
    pricing = "Pricing",
    arrow = "Arrow",
}

LazyProf.debugScoringBracket = nil  -- nil = show all, or bracket index
-- Skill brackets are derived per active profession from its CraftLib milestones,
-- with neutral min-max labels (no TBC rank names) so phased SoD caps (150/225/300)
-- render correctly. Falls back to the profile's cap when no profession is
-- active: Vanilla/SoD/Forever 300, TBC 375, WotLK 450. No profile (unsupported
-- client, stopped by the dependency check) uses the 300 tiers, not a guess of a
-- later expansion.
local FALLBACK_MILESTONES = {
    VANILLA = {75, 150, 225, 300},
    SOD = {75, 150, 225, 300},
    FOREVER = {75, 150, 225, 300},
    TBC = {75, 150, 225, 300, 375},
    WOTLK = {75, 150, 225, 300, 375, 450},
}

function LazyProf:GetSkillBrackets()
    local milestones
    local active = self.Professions and self.Professions.active
    if active and self.Professions.registry[active] then
        milestones = self.Professions.registry[active].milestones
    end

    if not milestones or #milestones == 0 then
        local CraftLib = _G.CraftLib
        local profile = CraftLib and CraftLib.GetActiveProfile and CraftLib:GetActiveProfile() or nil
        milestones = FALLBACK_MILESTONES[profile] or FALLBACK_MILESTONES.VANILLA
    end

    return self.Utils.BuildSkillBrackets(milestones)
end

function LazyProf:Debug(category, msg)
    -- Backwards compatibility: single arg = message with "pathfinder" category
    if msg == nil then
        msg = category
        category = "pathfinder"
    end

    if not self.db or not self.db.profile.debug then
        return
    end

    -- Check if this category is enabled
    if not self.db.profile.debugCategories[category] then
        return
    end

    local timestamp = date("%H:%M:%S")

    -- Store with category for filtering
    local log = self.debugLog
    log[#log + 1] = {
        timestamp = timestamp,
        category = category,
        message = msg,
    }
    -- Amortized O(1) trim: only compact once the buffer overshoots by the slack
    -- margin, then drop the oldest entries in a single batch shift. This avoids
    -- table.remove(log, 1) (an O(n) front shift) running on every line once the
    -- buffer is full. Keeps the newest debugLogMax entries in chronological order.
    if #log > self.debugLogMax + self.debugLogSlack then
        local removeCount = #log - self.debugLogMax
        local n = #log
        for i = 1, n - removeCount do
            log[i] = log[i + removeCount]
        end
        for i = n - removeCount + 1, n do
            log[i] = nil
        end
        self.debugLogOverflowed = true
    end

    -- Auto-update debug window if visible (debounced: a verbose scoring run
    -- emits hundreds of lines, and rebuilding the full EditBox text on every
    -- one is O(n^2). Coalesce rapid updates into one refresh.)
    if self.debugFrame and self.debugFrame:IsShown() then
        self:ScheduleDebugWindowUpdate()
    end
    -- No chat output - use /lp log to view logs
end

-- Cheap predicate mirroring Debug()'s gate so hot code paths can skip building
-- expensive debug strings. Lua evaluates Debug()'s message argument eagerly, so
-- an unguarded LazyProf:Debug(cat, string.format(...)) pays the full format cost
-- even when debug is disabled; wrap such hot sites in this check.
function LazyProf:IsDebugEnabled(category)
    if not self.db or not self.db.profile.debug then
        return false
    end
    if category and not self.db.profile.debugCategories[category] then
        return false
    end
    return true
end

-- Debug pipeline: /lp diag learned. Dumps learned-recipe detection state to a
-- copyable popup so a "known recipe shows [!] Unlearned" report can be diagnosed
-- without game access (chat cannot be copied out of the client). The lines come
-- from the client adapter (Client:RunDiagnostic), which contrasts what each
-- id-resolution path sees. Read-only: no frame Show/Hide. On Classic the only state
-- touched is the same learnedRecipes cache the normal scan already writes; the
-- Forever diagnostic touches no state. Output lines
-- are documented in docs/development/TROUBLESHOOTING.md (Diagnostic Commands).
function LazyProf:RunLearnedDiagnostic(topic)
    topic = topic or "learned"
    if topic == "learned" and not self.Client:IsOpen() then
        self:Print("diag learned: open a profession window first.")
        return
    end

    -- Accumulate lines, then show them in a copyable popup (chat cannot be
    -- copied out of the client).
    local out = {}
    self.Client:RunDiagnostic(out)

    self:Print("diag " .. topic .. ": output ready - copy it from the window that opened.")
    self:ShowDiagnosticOutput(table.concat(out, "\n"))
end

-- /lp diag prices: every reagent price of the current path, where it came from
-- (vendor, TSM and which TSM value, Auctionator and its age in days, vendor
-- sell estimate, none yet) and what each source says. Read-only.
function LazyProf:RunPriceDiagnostic()
    local out = {}
    self.PriceManager:RunDiagnostic(out)
    self:Print("diag prices: output ready - copy it from the window that opened.")
    self:ShowDiagnosticOutput(table.concat(out, "\n"))
end

-- /lp diag merchant: the open merchant's raw values, what the adapter makes
-- of them, the vendor prices remembered so far and what the merchant panel
-- would buy. Read-only; run it with a merchant window open.
function LazyProf:RunMerchantDiagnostic()
    local out = {}
    local function add(text) out[#out + 1] = text end
    local version, build, _, interface = GetBuildInfo()
    add("diag merchant: build=" .. tostring(version) .. " (" .. tostring(build) .. ") interface=" .. tostring(interface)
        .. " family=" .. tostring(self.ClientFamily))
    if not self.Client:IsMerchantOpen() then
        add("NOTE: no merchant window is open - open one for the item lines.")
    end
    local ok, err = pcall(self.Client.RunMerchantDiagnostic, self.Client, out)
    if not ok then add("SECTION ERROR: adapter: " .. tostring(err)) end

    ok, err = pcall(function()
        add("remembered vendor prices: " .. tostring(self.VendorMemory:Count()))
        local panel = self.MerchantPanel
        local runner = panel and panel.runner
        add("purchases: onePerClick=" .. tostring(runner and runner:ClickOnly() or false)
            .. " running=" .. tostring(runner and runner:IsRunning() or false))
        local rows, listName = nil, nil
        if self.GuideWindow then rows, listName = self.GuideWindow:MerchantRows() end
        if not rows then
            add("shopping list: none yet this session (open a profession or the LazyProf window first)")
            return
        end
        local plan = self.PurchaseQueue.Plan(rows, self.Client:MerchantItems())
        add("shopping list: " .. tostring(listName) .. ", rows=" .. tostring(#rows) .. " toBuyHere=" .. tostring(#plan.entries)
            .. " skipped=" .. tostring(#plan.skipped) .. " total=" .. self.Utils.FormatMoney(plan.total))
        for _, entry in ipairs(plan.entries) do
            add("buy: " .. tostring(entry.quantity) .. "x " .. tostring(entry.name) .. " (id " .. tostring(entry.itemId)
                .. ") for " .. self.Utils.FormatMoney(entry.cost))
        end
        for _, skipped in ipairs(plan.skipped) do
            add("skip: " .. tostring(skipped.name) .. " (id " .. tostring(skipped.itemId) .. "): " .. tostring(skipped.reason))
        end
    end)
    if not ok then add("SECTION ERROR: plan: " .. tostring(err)) end

    self:Print("diag merchant: output ready - copy it from the window that opened.")
    self:ShowDiagnosticOutput(table.concat(out, "\n"))
end

-- /lp diag trainer: the open trainer's raw values, what the adapter makes of
-- them, and what is remembered of visited trainers. Read-only; run it with a
-- profession trainer's window open.
function LazyProf:RunTrainerDiagnostic()
    local out = {}
    local function add(text) out[#out + 1] = text end
    local version, build, _, interface = GetBuildInfo()
    add("diag trainer: build=" .. tostring(version) .. " (" .. tostring(build) .. ") interface=" .. tostring(interface)
        .. " family=" .. tostring(self.ClientFamily))
    local ok, err = pcall(self.Client.RunTrainerDiagnostic, self.Client, out)
    if not ok then add("SECTION ERROR: adapter: " .. tostring(err)) end

    ok, err = pcall(function()
        local memory = self.TrainerMemory
        local counts = memory:Counts()
        add("remembered: professions=" .. tostring(counts.professions) .. " trainers=" .. tostring(counts.trainers)
            .. " fees=" .. tostring(counts.fees))
        -- What this visit matched: the profession, and the listed recipes with a fee.
        local info = self.Client:TrainerInfo()
        if info then
            local services = self.Client:TrainerServices()
            local profKey = memory:Record(info, services)
            add("this trainer: profession=" .. tostring(profKey) .. " services=" .. tostring(#services))
            if profKey then
                for _, trainer in ipairs(memory:Trainers(profKey)) do
                    local listed = 0
                    for _ in pairs(trainer.teaches or {}) do listed = listed + 1 end
                    add("known " .. tostring(profKey) .. " trainer: " .. self.GuideText.TrainerLine(trainer)
                        .. " mapId=" .. tostring(trainer.mapId) .. " faction=" .. tostring(trainer.faction)
                        .. " recipesListed=" .. tostring(listed))
                end
            end
        end
    end)
    if not ok then add("SECTION ERROR: memory: " .. tostring(err)) end

    self:Print("diag trainer: output ready - copy it from the window that opened.")
    self:ShowDiagnosticOutput(table.concat(out, "\n"))
end

-- /lp diag stock: the bags and the bank as the client reports them and as the
-- adapter reads them, who the character is, and what is remembered of every
-- character's bags and bank. Read-only; run it with the bank window open for
-- the bank lines.
function LazyProf:RunStockDiagnostic()
    local out = {}
    local function add(text) out[#out + 1] = text end
    local version, build, _, interface = GetBuildInfo()
    add("diag stock: build=" .. tostring(version) .. " (" .. tostring(build) .. ") interface=" .. tostring(interface)
        .. " family=" .. tostring(self.ClientFamily))
    local ok, err = pcall(self.Client.RunStockDiagnostic, self.Client, out)
    if not ok then add("SECTION ERROR: adapter: " .. tostring(err)) end
    ok, err = pcall(self.Inventory.RunDiagnostic, self.Inventory, out)
    if not ok then add("SECTION ERROR: memory: " .. tostring(err)) end

    self:Print("diag stock: output ready - copy it from the window that opened.")
    self:ShowDiagnosticOutput(table.concat(out, "\n"))
end

-- Debug pipeline primitive (used by /lp diag commands). A copyable popup modeled
-- on the debug-log window: lazily-built, reused, ESC-closable, combat-safe. Holds
-- any text in a selectable multi-line EditBox so a player or dev can Ctrl+C
-- diagnostic output out of the client (chat is not copyable). Reuse this for any
-- future /lp diag <topic> command - build a lines table and hand it the joined text.
function LazyProf:ShowDiagnosticOutput(text)
    if InCombatLockdown() then
        self:Print("diag: cannot open the output window in combat.")
        return
    end

    if not self.diagFrame then
        local frame = CreateFrame("Frame", "LazyProfDiagFrame", UIParent, "BackdropTemplate")
        frame:SetSize(700, 450)
        frame:SetPoint("CENTER")
        frame:SetFrameStrata("DIALOG")
        frame:SetMovable(true)
        frame:SetClampedToScreen(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        frame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

        frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        frame.title:SetPoint("TOPLEFT", 10, -10)
        frame.title:SetText("LazyProf Diagnostic")
        frame.title:SetTextColor(1, 0.82, 0)

        frame.closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)

        frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        frame.hint:SetPoint("TOPLEFT", 12, -32)
        frame.hint:SetText("Click Select All (or click in the box and Ctrl+A), then Ctrl+C to copy.")
        frame.hint:SetTextColor(0.7, 0.7, 0.7)

        frame.selectBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        frame.selectBtn:SetSize(90, 22)
        frame.selectBtn:SetPoint("BOTTOMRIGHT", -10, 10)
        frame.selectBtn:SetText("Select All")
        frame.selectBtn:SetScript("OnClick", function()
            frame.editBox:SetFocus()
            frame.editBox:HighlightText()
        end)

        frame.scrollFrame = CreateFrame("ScrollFrame", "LazyProfDiagScrollFrame", frame, "UIPanelScrollFrameTemplate")
        frame.scrollFrame:SetPoint("TOPLEFT", 10, -50)
        frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)

        -- Selectable, copyable multi-line text (same approach as the debug window).
        frame.editBox = CreateFrame("EditBox", nil, frame.scrollFrame)
        frame.editBox:SetMultiLine(true)
        frame.editBox:SetFontObject(GameFontHighlightSmall)
        frame.editBox:SetWidth(frame.scrollFrame:GetWidth())
        frame.editBox:SetAutoFocus(false)
        frame.editBox:EnableMouse(true)
        frame.editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        frame.scrollFrame:SetScrollChild(frame.editBox)

        tinsert(UISpecialFrames, "LazyProfDiagFrame")
        self.Utils.AddCombatLockdown(frame)
        self.diagFrame = frame
    end

    self.diagFrame.editBox:SetText(text or "")
    self.diagFrame:Show()
    self.diagFrame.scrollFrame:SetVerticalScroll(0)
    self.diagFrame.editBox:SetCursorPosition(0)
    self.diagFrame.editBox:SetFocus()
    self.diagFrame.editBox:HighlightText()
end

-- Debounced debug-window refresh (see Debug()); a pending flag, as in
-- ScheduleRecalculation (C_Timer.After returns nothing).
local debugWindowPending = false
function LazyProf:ScheduleDebugWindowUpdate()
    if debugWindowPending then return end
    debugWindowPending = true
    C_Timer.After(0.2, function()
        debugWindowPending = false
        if LazyProf.debugFrame and LazyProf.debugFrame:IsShown() then
            LazyProf:UpdateDebugWindowContent()
        end
    end)
end

-- Get filtered debug log entries
function LazyProf:GetFilteredDebugLog()
    local filtered = {}
    local currentSkill = nil
    -- Hoisted out of the loop: the selected bracket is identical for every entry,
    -- so derive it once instead of rebuilding the bracket table per entry.
    local scoringBracket = nil
    if self.debugFilter == "scoring" and self.debugScoringBracket then
        scoringBracket = self:GetSkillBrackets()[self.debugScoringBracket]
    end
    for _, entry in ipairs(self.debugLog) do
        if not self.debugFilter or entry.category == self.debugFilter then
            -- Apply scoring bracket filter if active
            if self.debugFilter == "scoring" and self.debugScoringBracket then
                if scoringBracket then
                    local skill = tonumber(entry.message:match("Scoring candidates at skill (%d+%.?%d*)"))
                        or tonumber(entry.message:match("No candidates at skill (%d+%.?%d*)"))
                    if skill then
                        currentSkill = math.floor(skill)
                    end
                    if currentSkill and currentSkill >= scoringBracket.min and currentSkill <= scoringBracket.max then
                        table.insert(filtered, entry)
                    end
                end
            else
                table.insert(filtered, entry)
            end
        end
    end
    return filtered
end

-- Format debug log entries as text (full set; used by the Copy buttons).
function LazyProf:FormatDebugLog(entries)
    return (self:FormatDebugLogTail(entries, nil))
end

-- Format only the last `maxLines` entries. Returns (text, truncated, total).
-- A huge EditBox:SetText forces a full FontString layout pass on the UI thread,
-- so the live window renders only the tail; the complete trace stays in
-- self.debugLog and is reachable via the category/bracket filters or Copy All.
function LazyProf:FormatDebugLogTail(entries, maxLines)
    local total = #entries
    local startIdx = 1
    if maxLines and total > maxLines then
        startIdx = total - maxLines + 1
    end
    local lines = {}
    for i = startIdx, total do
        local entry = entries[i]
        local catDisplay = self.debugCategoryNames[entry.category] or entry.category
        lines[#lines + 1] = string.format("[%s] [%s] %s", entry.timestamp, catDisplay, entry.message)
    end
    return table.concat(lines, "\n"), (startIdx > 1), total
end

-- Update debug window content (respects filter)
function LazyProf:UpdateDebugWindowContent()
    if not self.debugFrame then return end

    local filtered = self:GetFilteredDebugLog()
    local text, viewTruncated, total = self:FormatDebugLogTail(filtered, self.debugRenderMax)

    if text == "" then
        if self.debugFilter then
            local catName = self.debugCategoryNames[self.debugFilter] or self.debugFilter
            local brackets = self:GetSkillBrackets()
            if self.debugScoringBracket and brackets[self.debugScoringBracket] then
                text = "(No messages in " .. catName .. " for skill " .. brackets[self.debugScoringBracket].name .. ")"
            else
                text = "(No messages in category: " .. catName .. ")"
            end
        else
            text = "(No debug messages yet. Enable debug mode and perform actions.)"
        end
    end

    -- View cap: only the last debugRenderMax lines are drawn, so a large buffer
    -- never forces a multi-thousand-line EditBox layout pass. The full trace is
    -- still in memory - narrow the category/bracket filter to surface an earlier
    -- range, or use Copy All / Copy Filtered to export everything.
    if viewTruncated then
        local note = string.format(
            "|cFF888888[Showing last %d of %d lines. Use the category/bracket filter above to view earlier ranges.]|r",
            self.debugRenderMax, total)
        text = note .. "\n" .. text
    end

    -- Warn when the ring buffer dropped older lines so the start of a long run
    -- (e.g. a full 1-300 scoring pass) is no longer present. To capture an
    -- early range, narrow the scope: filter by category/bracket above, or
    -- calculate a smaller skill range, then re-run.
    if self.debugLogOverflowed then
        local hint = string.format(
            "|cFFFFCC00[Log full: oldest lines dropped - only the last %d are kept.]|r\n"
            .. "|cFFFFCC00[Not all logs are present. To see an earlier range, filter by category/bracket or calculate a smaller skill range, then re-run.]|r",
            self.debugLogMax)
        text = hint .. "\n" .. text
    end

    self.debugFrame.editBox:SetText(text)

    -- Update count display
    if self.debugFrame.countText then
        if self.debugFilter then
            self.debugFrame.countText:SetText(string.format("Showing %d of %d", #filtered, #self.debugLog))
        else
            self.debugFrame.countText:SetText(string.format("%d messages", #self.debugLog))
        end
    end

    -- Scroll to bottom
    C_Timer.After(0.01, function()
        if self.debugFrame and self.debugFrame.scrollFrame then
            self.debugFrame.scrollFrame:SetVerticalScroll(self.debugFrame.scrollFrame:GetVerticalScrollRange())
        end
    end)
end

function LazyProf:ClearDebugLog()
    wipe(self.debugLog)
    self.debugLogOverflowed = false
    if self.debugFrame and self.debugFrame:IsShown() then
        self:UpdateDebugWindowContent()
    end
    self:Print("Debug log cleared.")
end

function LazyProf:ShowDebugLog()
    if InCombatLockdown() then return end

    if not self.debugFrame then
        self:CreateDebugFrame()
    end

    -- Update content
    self:UpdateDebugWindowContent()
    self.debugFrame:Show()
end

function LazyProf:CreateDebugFrame()
    local frame = CreateFrame("Frame", "LazyProfDebugFrame", UIParent, "BackdropTemplate")
    frame:SetSize(700, 450)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    -- Title
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 10, -10)
    frame.title:SetText("LazyProf Debug Log")
    frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    frame.closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Filter dropdown
    local Widgets = self.Widgets
    frame.filterDropdown = Widgets.CreateDropdown(frame, "LazyProfDebugFilterDropdown", 150)
    frame.filterDropdown:SetPoint("TOPLEFT", 100, -3)

    local categories = {"scoring", "pathfinder", "ui", "professions", "pricing", "arrow"}
    frame.filterDropdown:SetOptions(function()
        -- "All Categories", a separator, then each category
        local options = {
            { text = "All Categories", value = nil, checked = (LazyProf.debugFilter == nil) },
            { separator = true },
        }
        for _, cat in ipairs(categories) do
            table.insert(options, {
                text = LazyProf.debugCategoryNames[cat],
                value = cat,
                checked = (LazyProf.debugFilter == cat),
            })
        end
        return options
    end, function(cat)
        LazyProf.debugFilter = cat
        if cat == nil then
            frame.filterDropdown:SetText("All Categories")
            LazyProf.debugScoringBracket = nil
            if frame.bracketDropdown then
                frame.bracketDropdown:Hide()
                frame.bracketDropdown:SetText("All Skill Levels")
            end
            LazyProf:UpdateDebugWindowContent()
            return
        end

        frame.filterDropdown:SetText(LazyProf.debugCategoryNames[cat])
        if frame.bracketDropdown then
            if cat == "scoring" then
                -- Auto-select bracket matching current skill level
                local autoIndex = nil
                local brackets = LazyProf:GetSkillBrackets()
                local path = LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath
                local pathSkill = path and (path.actualSkill or path.currentSkill)
                if pathSkill then
                    for i, bracket in ipairs(brackets) do
                        if pathSkill >= bracket.min and pathSkill < bracket.max then
                            autoIndex = i
                            break
                        end
                    end
                end
                LazyProf.debugScoringBracket = autoIndex
                if autoIndex then
                    frame.bracketDropdown:SetText(brackets[autoIndex].name)
                else
                    frame.bracketDropdown:SetText("All Skill Levels")
                end
                frame.bracketDropdown:Show()
            else
                frame.bracketDropdown:Hide()
                LazyProf.debugScoringBracket = nil
                frame.bracketDropdown:SetText("All Skill Levels")
            end
        end
        LazyProf:UpdateDebugWindowContent()
    end)
    frame.filterDropdown:SetText("All Categories")

    -- Skill bracket dropdown (visible only when Pathfinder Scoring filter is active)
    frame.bracketDropdown = Widgets.CreateDropdown(frame, "LazyProfDebugBracketDropdown", 150)
    frame.bracketDropdown:SetPoint("LEFT", frame.filterDropdown, "RIGHT", -15, 0)

    frame.bracketDropdown:SetOptions(function()
        local options = {
            { text = "All Skill Levels", value = nil, checked = (LazyProf.debugScoringBracket == nil) },
        }
        for i, bracket in ipairs(LazyProf:GetSkillBrackets()) do
            table.insert(options, {
                text = bracket.name,
                value = i,
                checked = (LazyProf.debugScoringBracket == i),
            })
        end
        return options
    end, function(index, option)
        LazyProf.debugScoringBracket = index
        frame.bracketDropdown:SetText(option.text)
        LazyProf:UpdateDebugWindowContent()
    end)
    frame.bracketDropdown:SetText("All Skill Levels")
    frame.bracketDropdown:Hide()

    -- Message count display
    frame.countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.countText:SetPoint("TOPRIGHT", frame.closeBtn, "TOPLEFT", -10, -8)
    frame.countText:SetTextColor(0.7, 0.7, 0.7)

    -- Bottom buttons
    -- Clear button
    frame.clearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.clearBtn:SetSize(60, 22)
    frame.clearBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    frame.clearBtn:SetText("Clear")
    frame.clearBtn:SetScript("OnClick", function()
        LazyProf:ClearDebugLog()
    end)

    -- Copy Filtered button
    frame.copyFilteredBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.copyFilteredBtn:SetSize(100, 22)
    frame.copyFilteredBtn:SetPoint("RIGHT", frame.clearBtn, "LEFT", -5, 0)
    frame.copyFilteredBtn:SetText("Copy Filtered")
    frame.copyFilteredBtn:SetScript("OnClick", function()
        -- Get only filtered content
        local filtered = LazyProf:GetFilteredDebugLog()
        local text = LazyProf:FormatDebugLog(filtered)
        frame.editBox:SetText(text)
        frame.editBox:SetFocus()
        frame.editBox:HighlightText()
        LazyProf:Print("Filtered text selected (" .. #filtered .. " messages) - press Ctrl+C to copy")
    end)

    -- Copy All button
    frame.copyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.copyBtn:SetSize(80, 22)
    frame.copyBtn:SetPoint("RIGHT", frame.copyFilteredBtn, "LEFT", -5, 0)
    frame.copyBtn:SetText("Copy All")
    frame.copyBtn:SetScript("OnClick", function()
        -- Show all content temporarily for copying
        local text = LazyProf:FormatDebugLog(LazyProf.debugLog)
        frame.editBox:SetText(text)
        frame.editBox:SetFocus()
        frame.editBox:HighlightText()
        LazyProf:Print("All text selected (" .. #LazyProf.debugLog .. " messages) - press Ctrl+C to copy")
        -- Restore filtered view after a moment
        C_Timer.After(0.1, function()
            if not frame.editBox:HasFocus() then
                LazyProf:UpdateDebugWindowContent()
            end
        end)
    end)

    -- Scroll frame
    frame.scrollFrame = CreateFrame("ScrollFrame", "LazyProfDebugScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", 10, -35)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)

    -- EditBox for text (selectable, copyable)
    frame.editBox = CreateFrame("EditBox", nil, frame.scrollFrame)
    frame.editBox:SetMultiLine(true)
    frame.editBox:SetFontObject(GameFontHighlightSmall)
    frame.editBox:SetWidth(frame.scrollFrame:GetWidth())
    frame.editBox:SetAutoFocus(false)
    frame.editBox:EnableMouse(true)
    frame.editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.scrollFrame:SetScrollChild(frame.editBox)

    tinsert(UISpecialFrames, "LazyProfDebugFrame")

    -- Combat lockdown: auto-hide during combat, restore after
    self.Utils.AddCombatLockdown(frame)

    self.debugFrame = frame
end
