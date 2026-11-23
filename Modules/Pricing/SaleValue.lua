-- Modules/Pricing/SaleValue.lua
-- What one craft of a recipe sells for, in copper. The planner takes it off a
-- recipe's cost when ranking and every total takes it off what is spent.
--
-- Modes (the saleValueMode setting, Constants.SALE_MODE):
--   vendor   the vendor's price for the crafted item - money the player
--            always gets (the default)
--   auction  the item's auction price after the cut, never below the vendor
--            value; no auction price: the vendor value
--   none     nothing is counted
--
-- One item per craft is assumed (the recipe data has no yield), so a recipe
-- that makes several is understated, never overstated. A recipe without a
-- crafted item (an enchant) sells for nothing.
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

local SaleValue = {}
LazyProf.SaleValue = SaleValue

local MODE = Constants.SALE_MODE

-- Crafted items whose data the client has not delivered yet:
-- [itemId] = GetTime() of the first request. An item counts as loading for
-- SALE_LOADING_TIMEOUT seconds; a failed load ends the wait for the session.
SaleValue.waiting = {}
SaleValue.failed = {}

-- The value of one craft of `recipe`: value, source, loading.
--   value    copper, 0 when it sells for nothing (or nothing is known yet)
--   source   "vendor" | "auction" | nil
--   loading  the item's data has not arrived, so the vendor value is unknown
-- deps.sellPrice(itemId)   -> copper or nil, loaded (false while not loaded)
-- deps.marketPrice(itemId) -> copper or nil (auction addons only)
function SaleValue.Of(recipe, mode, deps)
    local itemId = recipe and recipe.itemId
    if mode == MODE.NONE or not itemId then
        return 0, nil, false
    end
    local sell, loaded = deps.sellPrice(itemId)
    local vendor = (loaded and sell and sell > 0) and sell or 0

    if mode == MODE.AUCTION then
        local market = deps.marketPrice(itemId)
        if market and market > 0 then
            local afterCut = math.floor(market * (1 - Constants.AUCTION_CUT))
            if afterCut > 0 and afterCut >= vendor then
                return afterCut, "auction", not loaded
            end
        end
    end
    if vendor > 0 then
        return vendor, "vendor", false
    end
    return 0, nil, not loaded
end

-- Is the wait for an item's data still on? `start` begins the wait for an
-- item not asked for before.
local function StillWaiting(self, itemId, start)
    if self.failed[itemId] then return false end
    local now = GetTime()
    local since = self.waiting[itemId]
    if not since then
        if not start then return false end
        self.waiting[itemId] = now
        return true
    end
    return (now - since) < Constants.SALE_LOADING_TIMEOUT
end

-- The lookups used in game: the vendor sell price is the 11th item-info
-- return (as Providers/VendorSell.lua reads it); asking for an item the
-- client has not cached also requests it.
local function ClientDeps(self)
    return {
        sellPrice = function(itemId)
            local name, _, _, _, _, _, _, _, _, _, sell = LazyProf.Client:GetItemInfo(itemId)
            if name == nil then
                return nil, not StillWaiting(self, itemId, true)
            end
            self.waiting[itemId] = nil
            return sell or 0, true
        end,
        marketPrice = function(itemId)
            local pm = LazyProf.PriceManager
            return pm and pm.MarketPrice and pm:MarketPrice(itemId) or nil
        end,
    }
end

local function ReagentPriceIsReal(itemId)
    local pm = LazyProf.PriceManager
    if not (pm and pm.PeekPriceInfo and pm.IsRealSource) then return false end
    return pm.IsRealSource(pm:PeekPriceInfo(itemId))
end

-- The sale values of one calculation.
-- opts: mode, from, to (the skill range planned), racialBonus,
--       deps (default: the client and the price manager),
--       isRealPrice(itemId) (default: the reagent's price comes from a
--       vendor or an auction addon)
-- Returns { mode, values, sources, rank, loading, loadingItems }:
--   values[recipeId]   copper per craft (only above zero)
--   sources[recipeId]  "vendor" | "auction"
--   rank[recipeId]     the value, only for recipes whose every reagent has a
--                      real price: taking a true sale value off a made-up
--                      cost would rank fiction
--   loading            how many crafted items were waiting for data when the
--                      table was built; loadingItems lists them, and
--                      LoadingCount says how many still are
-- Only recipes that can be on a path from `from` to `to` are looked up.
function SaleValue:Build(recipes, opts)
    opts = opts or {}
    local mode = opts.mode or MODE.VENDOR
    local sale = { mode = mode, values = {}, sources = {}, rank = {}, loading = 0, loadingItems = {} }
    if mode == MODE.NONE then
        return sale
    end
    local deps = opts.deps or ClientDeps(self)
    local isRealPrice = opts.isRealPrice or ReagentPriceIsReal
    local from, to = opts.from or 1, opts.to or math.huge
    local racialBonus = opts.racialBonus or 0
    local loadingItems = {}
    -- A reagent is shared by many recipes: its price is checked once.
    local realPrice = {}
    local function real(itemId)
        local known = realPrice[itemId]
        if known == nil then
            known = isRealPrice(itemId) and true or false
            realPrice[itemId] = known
        end
        return known
    end

    for _, recipe in ipairs(recipes or {}) do
        local range = recipe.skillRange
        local usable = (recipe.skillRequired or 0) <= to
            and (not range or (range.gray or math.huge) + racialBonus > from)
        if usable and recipe.itemId then
            local value, source, loading = SaleValue.Of(recipe, mode, deps)
            if loading and not loadingItems[recipe.itemId] then
                loadingItems[recipe.itemId] = true
                sale.loading = sale.loading + 1
                sale.loadingItems[#sale.loadingItems + 1] = recipe.itemId
            end
            if value > 0 then
                sale.values[recipe.id] = value
                sale.sources[recipe.id] = source
                local allReal = true
                for _, reagent in ipairs(recipe.reagents or {}) do
                    if not real(reagent.itemId) then
                        allReal = false
                        break
                    end
                end
                if allReal then
                    sale.rank[recipe.id] = value
                end
            end
        end
    end
    return sale
end

-- How many of a sale table's crafted items are still waiting for their data
-- right now (the table's own `loading` is the count when it was built). The
-- wait ends when the data arrives, the load fails or the timeout passes.
function SaleValue:LoadingCount(sale)
    local count = 0
    for _, itemId in ipairs(sale and sale.loadingItems or {}) do
        if self.waiting[itemId] ~= nil and StillWaiting(self, itemId, false) then
            count = count + 1
        end
    end
    return count
end

-- How many crafted items are being waited for right now, whichever
-- calculation asked for them (a wait is over when the data arrives, the load
-- fails or the timeout passes).
function SaleValue:WaitingCount()
    local count = 0
    for itemId in pairs(self.waiting) do
        if StillWaiting(self, itemId, false) then
            count = count + 1
        end
    end
    return count
end

-- Item data arrived (or failed to) for `itemId`. Returns true when a sale
-- value was waiting for it, so the caller plans again; a failed load stops
-- the item from counting as loading.
function SaleValue:OnItemInfo(itemId, success)
    if self.waiting[itemId] == nil then
        return false
    end
    self.waiting[itemId] = nil
    if not success then
        self.failed[itemId] = true
    end
    return true
end
