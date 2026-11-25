-- Modules/Pricing/PriceManager.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants
local Utils = LazyProf.Utils

LazyProf.PriceManager = {}
local PriceManager = LazyProf.PriceManager

PriceManager.providers = {}
-- itemId -> price info (see GetPriceInfo). Other modules read .price.
PriceManager.cache = {}
-- itemId -> { price = copper or false, ageDays, timestamp } (see MarketPrice)
PriceManager.marketCache = {}

-- Two auction sources whose prices for one item differ by more than this
-- factor are flagged in /lp diag prices.
local DISAGREE_RATIO = 1.5

-- Initialize providers based on config priority
function PriceManager:Initialize()
    self.providers = {}

    -- Load market providers in priority order (vendor handled separately)
    local priority = LazyProf.db.profile.priceSourcePriority
    for _, name in ipairs(priority) do
        if name ~= "vendor" then
            local provider = LazyProf.PriceProviders and LazyProf.PriceProviders[name]
            if provider and provider:IsAvailable() then
                table.insert(self.providers, provider)
                LazyProf:Debug("pricing", "Price provider enabled: " .. name)
            end
        end
    end

    -- Log vendor availability separately
    local vendor = LazyProf.PriceProviders and LazyProf.PriceProviders.vendor
    if vendor and vendor:IsAvailable() then
        LazyProf:Debug("pricing", "Vendor price provider enabled (checked first)")
    end
end

-- Price of an item and where it came from:
--   price     copper, or nil when nothing prices the item
--   source    "Vendor" | "TSM" | "Auctionator" | "VendorSell" | "floor" | "none"
--             ("floor": the 1-copper stand-in; "none": no price, sell estimate off)
--   detail    TSM: the price source key that answered (DBRecent, DBMarket, ...);
--             Vendor: who knows the merchant price - the addon that recorded
--             it, "seen" (LazyProf saw it at a merchant) or "list" (the
--             shipped vendor-reagent list);
--             floor: "loading" (item data not in the client yet) or
--             "unsellable" (item data loaded, no vendor sell value)
--   ageDays   Auctionator: days since it last saw a price for the item
--   timestamp when LazyProf read it (time())
function PriceManager:GetPriceInfo(itemId)
    -- Check cache first
    local cached = self.cache[itemId]
    if cached and (time() - cached.timestamp) < Constants.PRICE_CACHE_TTL then
        return cached
    end

    local function record(provider, price, detail, ageDays)
        local info = {
            price = price,
            source = provider.name,
            detail = detail,
            ageDays = ageDays,
            timestamp = time(),
        }
        self.cache[itemId] = info
        return info
    end

    -- Vendor prices are authoritative: guaranteed supply at fixed price.
    -- Always check before market prices so AH listings don't override them.
    local vendor = LazyProf.PriceProviders and LazyProf.PriceProviders.vendor
    if vendor then
        local price, detail = vendor:GetPrice(itemId)
        if price and price > 0 then
            return record(vendor, price, detail)
        end
    end

    -- Market providers: a fresh price (a provider that reports its age, see
    -- IsFreshAge) wins at once; otherwise the first price in the configured
    -- order.
    local first
    for _, provider in ipairs(self.providers) do
        local price, detail, ageDays = provider:GetPrice(itemId)
        if price and price > 0 then
            if self:IsFreshAge(ageDays) then
                return record(provider, price, detail, ageDays)
            end
            first = first or { provider = provider, price = price, detail = detail, ageDays = ageDays }
        end
    end
    if first then
        return record(first.provider, first.price, first.detail, first.ageDays)
    end

    -- Last-resort floor: vendor SELL value (always available offline, no AH).
    -- Without this, any reagent that no market source can price (e.g. gathered
    -- leather/ore/herbs with no AH) returns nil, which makes the Cheapest
    -- strategy score every recipe as math.huge and pick arbitrarily. The sell
    -- value scales with material quantity and tier, so it ranks fewer/cheaper
    -- materials correctly. Disable with useVendorSellFallback = false to keep
    -- strict market-only behavior.
    if LazyProf.db.profile.useVendorSellFallback ~= false then
        local sellProvider = LazyProf.PriceProviders and LazyProf.PriceProviders.vendorsell
        if sellProvider then
            local price = sellProvider:GetPrice(itemId)
            if price and price > 0 then
                return record(sellProvider, price)
            end
        end

        -- Item not cached yet (GetItemInfo pending) or non-sellable. Return the
        -- absolute floor WITHOUT caching, and remember it so the addon can
        -- refine the value once GET_ITEM_INFO_RECEIVED delivers the real price.
        self.flooredItems = self.flooredItems or {}
        self.flooredItems[itemId] = true
        local loaded = LazyProf.Client:GetItemInfo(itemId) ~= nil
        return { price = Constants.MIN_REAGENT_PRICE, source = "floor",
                 detail = loaded and "unsellable" or "loading", timestamp = time() }
    end

    return { price = nil, source = "none", timestamp = time() }
end

-- What the auction addons say an item goes for, or nil: market sources only
-- (a fresh price first, else the first in the configured order). Never a
-- vendor buy price, the sell-value estimate or the floor, and nil for an item
-- a vendor sells (nobody pays more at auction than the vendor asks). Used for
-- what a crafted item sells for. Kept as long as the reagent prices are, in a
-- cache of its own. Second return: the price's age in days when its source
-- says (Auctionator), else nil.
function PriceManager:MarketPrice(itemId)
    local cached = self.marketCache[itemId]
    if cached and (time() - cached.timestamp) < Constants.PRICE_CACHE_TTL then
        return cached.price or nil, cached.ageDays
    end

    local found, foundAge
    local vendor = LazyProf.PriceProviders and LazyProf.PriceProviders.vendor
    local vendorPrice = vendor and vendor:GetPrice(itemId)
    if not (vendorPrice and vendorPrice > 0) then
        for _, provider in ipairs(self.providers) do
            local price, _, ageDays = provider:GetPrice(itemId)
            if price and price > 0 then
                if self:IsFreshAge(ageDays) then
                    found, foundAge = price, ageDays
                    break
                end
                if not found then found, foundAge = price, ageDays end
            end
        end
    end
    self.marketCache[itemId] = { price = found or false, ageDays = foundAge, timestamp = time() }
    return found, foundAge
end

-- A price somebody really charges: a vendor's or an auction addon's. The
-- sell-value estimate and the floor are stand-ins, not prices.
function PriceManager.IsRealSource(info)
    local source = info and info.source
    return source == "Vendor" or source == "TSM" or source == "Auctionator"
end

-- The price info the last calculation used: the cached entry whatever its
-- age, so reports match the path's totals; looked up only when not cached.
function PriceManager:PeekPriceInfo(itemId)
    return self.cache[itemId] or self:GetPriceInfo(itemId)
end

-- Get price for an item: price, source (see GetPriceInfo).
function PriceManager:GetPrice(itemId)
    local info = self:GetPriceInfo(itemId)
    return info.price, info.source
end

-- Get prices for multiple items
function PriceManager:GetPrices(itemIds)
    local prices = {}
    for _, itemId in ipairs(itemIds) do
        prices[itemId] = self:GetPrice(itemId)
    end
    return prices
end

-- Clear price cache
function PriceManager:ClearCache()
    self.cache = {}
    self.marketCache = {}
    self.flooredItems = {}
    LazyProf:Print("Price cache cleared.")
end

-- True once the player has been at the auction house since login or /reload.
-- Runtime only: a reload also reloads TSM's snapshot, which may be newer.
PriceManager.auctionHouseVisited = false

-- An auction price of this age (days) counts as fresh: seen today, and the
-- auction house was visited this session, so the scan is newer than the TSM
-- snapshot loaded at login. Auctionator only reports whole days, so a scan
-- from this morning alone would not prove that.
function PriceManager:IsFreshAge(ageDays)
    return self.auctionHouseVisited and ageDays ~= nil and ageDays <= Constants.AUCTION_FRESH_DAYS
end

-- The player left the auction house: a scan may just have run. Fresh prices
-- now win (IsFreshAge), and every cached price is expired so the next lookup
-- re-reads the sources. Entries stay in the cache until then: the shopping
-- list, Planning and the price reports read the prices of the last
-- calculation from it. Items waiting for item data stay tracked.
function PriceManager:OnAuctionHouseVisited()
    self.auctionHouseVisited = true
    for _, info in pairs(self.cache) do
        info.timestamp = 0
    end
    for _, entry in pairs(self.marketCache) do
        entry.timestamp = 0
    end
end

local function IsStale(info)
    return info.source == "Auctionator" and info.ageDays ~= nil
        and info.ageDays >= Constants.PRICE_STALE_DAYS
end

local function DaysText(days)
    if days == 0 then return "seen today" end
    if days == 1 then return "seen 1 day ago" end
    return "seen " .. tostring(days) .. " days ago"
end

-- One price's source as text for tooltips: "TSM DBRecent",
-- "Auctionator, seen 2 days ago", "estimate from the vendor sell value", ...
function PriceManager.DescribeSource(info)
    local source = info and info.source
    if source == "TSM" then
        return "TSM " .. (info.detail or "price")
    elseif source == "Auctionator" then
        if info.ageDays then return "Auctionator, " .. DaysText(info.ageDays) end
        return "Auctionator"
    elseif source == "Vendor" then
        if info.detail == "seen" then return "vendor price (seen at a vendor)" end
        if info.detail == "list" then return "vendor price (known vendor item)" end
        if info.detail then return "vendor price (recorded by " .. info.detail .. ")" end
        return "vendor price"
    elseif source == "VendorSell" then
        return "estimate from the vendor sell value"
    elseif source == "floor" then
        if info.detail == "unsellable" then
            return "no price (no auction price, no vendor sell value)"
        end
        return "no price yet (item data still loading)"
    end
    return "no price (no auction price, vendor sell estimate off)"
end

-- Shopping-list tooltip line for one item's price.
function PriceManager.PriceLine(info)
    local each = ""
    if info and info.price and info.source ~= "floor" then
        each = Utils.FormatMoney(info.price) .. " each, "
    end
    return "Price: " .. each .. PriceManager.DescribeSource(info)
end

-- A reagent that will not get a price by itself (no auction price and no
-- sell value, or the sell estimate is off), as opposed to one still loading.
local function IsUnpriced(info)
    return info.source == "none" or (info.source == "floor" and info.detail == "unsellable")
end

-- Every distinct reagent item id of the path's steps, in first-seen order.
function PriceManager:PathReagentIds(path)
    local ids, seen = {}, {}
    for _, step in ipairs(path and path.steps or {}) do
        for _, reagent in ipairs(step.recipe and step.recipe.reagents or {}) do
            if reagent.itemId and not seen[reagent.itemId] then
                seen[reagent.itemId] = true
                ids[#ids + 1] = reagent.itemId
            end
        end
    end
    return ids
end

-- Counts the path's reagent prices by source: total, tsm, auctionator,
-- vendor, estimate (vendor sell value), loading (no price yet, item data
-- still loading), unpriced (no price and none coming: see IsUnpriced),
-- stale (Auctionator prices PRICE_STALE_DAYS or more old) and
-- oldestAuctionatorDays. Reads the prices the calculation used.
function PriceManager:PathSummary(path)
    local s = { total = 0, tsm = 0, auctionator = 0, vendor = 0, estimate = 0, loading = 0, unpriced = 0,
                stale = 0 }
    for _, itemId in ipairs(self:PathReagentIds(path)) do
        local info = self:PeekPriceInfo(itemId)
        s.total = s.total + 1
        if info.source == "TSM" then
            s.tsm = s.tsm + 1
        elseif info.source == "Auctionator" then
            s.auctionator = s.auctionator + 1
            if info.ageDays and (not s.oldestAuctionatorDays or info.ageDays > s.oldestAuctionatorDays) then
                s.oldestAuctionatorDays = info.ageDays
            end
            if IsStale(info) then s.stale = s.stale + 1 end
        elseif info.source == "Vendor" then
            s.vendor = s.vendor + 1
        elseif info.source == "VendorSell" then
            s.estimate = s.estimate + 1
        elseif IsUnpriced(info) then
            s.unpriced = s.unpriced + 1
        else
            s.loading = s.loading + 1
        end
    end
    return s
end

local function Reagents(n, singular, plural)
    return tostring(n) .. " " .. (n == 1 and singular or plural)
end

-- Tooltip lines for a path summary: { text, r, g, b } each. A breakdown of
-- where the prices came from, then a line for each problem (prices still
-- loading, reagents with no price at all, Auctionator prices too old), each
-- marked `problem = true`, then a note about reagents priced by the sell
-- estimate. The /lp diag prices hint is added only for problems the player
-- can act on.
function PriceManager.SummaryLines(s)
    local lines = {}
    if not s or s.total == 0 then return lines end

    local parts = {}
    if s.tsm > 0 then parts[#parts + 1] = "TSM " .. tostring(s.tsm) end
    if s.auctionator > 0 then parts[#parts + 1] = "Auctionator " .. tostring(s.auctionator) end
    if s.vendor > 0 then parts[#parts + 1] = "vendor " .. tostring(s.vendor) end
    if s.estimate > 0 then parts[#parts + 1] = "estimate " .. tostring(s.estimate) end
    local none = s.loading + s.unpriced
    if none > 0 then parts[#parts + 1] = "none " .. tostring(none) end
    lines[#lines + 1] = { text = "Prices: " .. table.concat(parts, ", "), r = 0.6, g = 0.6, b = 0.6 }

    local problem = false
    if s.loading > 0 then
        problem = true
        lines[#lines + 1] = { text = Reagents(s.loading, "reagent has", "reagents have")
            .. " no price yet - it updates by itself; /reload if it stays.", r = 1, g = 0.5, b = 0, problem = true }
    end
    if s.unpriced > 0 then
        problem = true
        lines[#lines + 1] = { text = Reagents(s.unpriced, "reagent has", "reagents have")
            .. " no price at all - scan the auction house (needs TSM or Auctionator).", r = 1, g = 0.5, b = 0, problem = true }
    end
    if s.stale > 0 then
        problem = true
        lines[#lines + 1] = { text = "Auctionator prices up to " .. tostring(s.oldestAuctionatorDays)
            .. " days old - rescan the auction house.", r = 1, g = 0.5, b = 0, problem = true }
    end
    if s.estimate > 0 then
        lines[#lines + 1] = { text = Reagents(s.estimate, "reagent has", "reagents have")
            .. " no auction price - cost uses the vendor sell value.", r = 0.7, g = 0.7, b = 0.7 }
    end
    if problem then
        lines[#lines + 1] = { text = "/lp diag prices lists every price and its source.", r = 0.5, g = 0.5, b = 0.5 }
    end
    return lines
end

-- One provider's value for the diagnostic's cross-check columns.
local function ProviderValue(name, itemId)
    local provider = LazyProf.PriceProviders and LazyProf.PriceProviders[name]
    if not provider or not provider:IsAvailable() then return "n/a" end
    local price, detail, ageDays = provider:GetPrice(itemId)
    if not price or price <= 0 then return "-", nil end
    local text = Utils.FormatMoney(price)
    if detail and name == "tsm" then text = text .. " (" .. detail .. ")" end
    if ageDays then text = text .. " (" .. tostring(ageDays) .. "d)" end
    return text, price
end

-- /lp diag prices: a read-only dump of every reagent price in the current path,
-- where it came from, what each price source says about the item, and which
-- candidate route the planner kept
-- (documented in docs/development/TROUBLESHOOTING.md).
function PriceManager:RunDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    -- Each part runs under pcall: a failing price source prints
    -- "SECTION ERROR" and the rest still prints.
    local function section(name, fn)
        local ok, err = pcall(fn)
        if not ok then add("SECTION ERROR: " .. name .. ": " .. tostring(err)) end
    end
    local providers = LazyProf.PriceProviders or {}
    local function available(name)
        local p = providers[name]
        return p ~= nil and p:IsAvailable() and true or false
    end
    local profile = LazyProf.db.profile

    section("sources", function()
        local ageCall = Auctionator and Auctionator.API and Auctionator.API.v1
            and Auctionator.API.v1.GetAuctionAgeByItemID ~= nil or false
        add("diag prices: tsm=" .. tostring(available("tsm")) .. " auctionator=" .. tostring(available("auctionator"))
            .. " auctionatorAge=" .. tostring(ageCall) .. " vendor=" .. tostring(available("vendor"))
            .. " order=" .. table.concat(profile.priceSourcePriority or {}, ",")
            .. " tsmSource=" .. tostring(profile.tsmPriceSource)
            .. " sellFallback=" .. tostring(profile.useVendorSellFallback ~= false)
            .. " staleAfterDays=" .. tostring(Constants.PRICE_STALE_DAYS))
        add("note: TSM does not tell other addons when its data was synced; the TSM desktop app shows its last sync."
            .. " Auctionator ages are days since it last saw the item.")
    end)

    local path = LazyProf.Pathfinder and LazyProf.Pathfinder.currentPath
    if not path or not path.steps or #path.steps == 0 then
        add("path: no path yet - open a profession window first")
        return
    end

    section("summary", function()
        local s = self:PathSummary(path)
        add("summary: reagents=" .. tostring(s.total) .. " tsm=" .. tostring(s.tsm)
            .. " auctionator=" .. tostring(s.auctionator) .. " vendor=" .. tostring(s.vendor)
            .. " estimate=" .. tostring(s.estimate) .. " loading=" .. tostring(s.loading)
            .. " noPrice=" .. tostring(s.unpriced) .. " stale=" .. tostring(s.stale)
            .. " oldestAuctionatorDays=" .. tostring(s.oldestAuctionatorDays))
    end)

    -- Which candidate route the planner kept, what each would cost the
    -- player, and how the sale values of the crafts stand.
    section("route", function()
        local route = path.route
        if not route then return end
        local function money(copper)
            return Utils.FormatMoney(math.floor((copper or 0) + 0.5))
        end
        add("route: kept=" .. tostring(route.kept) .. " candidates=" .. tostring(#route.candidates)
            .. (route.ms and string.format(" planned in %.0f ms", route.ms) or "")
            .. (route.keepMargin and (" keep margin=" .. money(route.keepMargin)) or ""))
        local first = route.candidates[1]
        for _, candidate in ipairs(route.candidates) do
            local net = candidate.net < 0 and ("gain " .. money(-candidate.net)) or money(candidate.net)
            local line = "candidate " .. tostring(candidate.key) .. ": net=" .. net
                .. " spend=" .. money(candidate.spend) .. " sale=" .. money(candidate.sale)
            if not candidate.eligible then
                line = line .. string.format(" (not eligible: leaves %.0f more skill points uncovered)",
                    (candidate.gapLength or 0) - (first.gapLength or 0))
            end
            add(line)
        end
        local sale = path.sale
        if sale then
            local counted, ranked = 0, 0
            for _ in pairs(sale.values or {}) do counted = counted + 1 end
            for _ in pairs(sale.rank or {}) do ranked = ranked + 1 end
            local loading = sale.loading or 0
            if LazyProf.SaleValue and LazyProf.SaleValue.LoadingCount then
                loading = LazyProf.SaleValue:LoadingCount(sale)
            end
            add("sale values: mode=" .. tostring(sale.mode) .. " counted=" .. tostring(counted)
                .. " ranked=" .. tostring(ranked) .. " loading=" .. tostring(loading))
        end
    end)

    local ids = self:PathReagentIds(path)
    table.sort(ids)
    for _, itemId in ipairs(ids) do
        section("item " .. tostring(itemId), function()
            local info = self:PeekPriceInfo(itemId)
            local name, _, _, _, _, _, _, _, _, _, sell = LazyProf.Client:GetItemInfo(itemId)
            local tsmText, tsmPrice = ProviderValue("tsm", itemId)
            local aucText, aucPrice = ProviderValue("auctionator", itemId)
            local vendorText = ProviderValue("vendor", itemId)
            local line = tostring(itemId) .. " " .. (name or ("item:" .. tostring(itemId))) .. ": "
                .. (info.price and Utils.FormatMoney(info.price) or "-") .. " " .. PriceManager.DescribeSource(info)
                .. " | tsm=" .. tsmText .. " auctionator=" .. aucText .. " vendor=" .. vendorText
                .. " sell=" .. ((sell and sell > 0) and Utils.FormatMoney(sell) or "-")
            if tsmPrice and aucPrice
                    and math.max(tsmPrice, aucPrice) > DISAGREE_RATIO * math.min(tsmPrice, aucPrice) then
                line = line .. " DISAGREE"
            end
            if IsStale(info) then line = line .. " STALE" end
            add(line)
        end)
    end
end
