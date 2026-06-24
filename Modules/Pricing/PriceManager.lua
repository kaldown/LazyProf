-- Modules/Pricing/PriceManager.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

LazyProf.PriceManager = {}
local PriceManager = LazyProf.PriceManager

PriceManager.providers = {}
PriceManager.cache = {}

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

-- Get price for an item
function PriceManager:GetPrice(itemId)
    -- Check cache first
    local cached = self.cache[itemId]
    if cached and (time() - cached.timestamp) < Constants.PRICE_CACHE_TTL then
        return cached.price, cached.source
    end

    -- Vendor prices are authoritative: guaranteed supply at fixed price.
    -- Always check before market prices so AH listings don't override them.
    local vendor = LazyProf.PriceProviders and LazyProf.PriceProviders.vendor
    if vendor then
        local price = vendor:GetPrice(itemId)
        if price and price > 0 then
            self.cache[itemId] = {
                price = price,
                source = vendor.name,
                timestamp = time(),
            }
            return price, vendor.name
        end
    end

    -- Query market providers in priority order
    for _, provider in ipairs(self.providers) do
        local price = provider:GetPrice(itemId)
        if price and price > 0 then
            self.cache[itemId] = {
                price = price,
                source = provider.name,
                timestamp = time(),
            }
            return price, provider.name
        end
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
                self.cache[itemId] = {
                    price = price,
                    source = sellProvider.name,
                    timestamp = time(),
                }
                return price, sellProvider.name
            end
        end

        -- Item not cached yet (GetItemInfo pending) or non-sellable. Return the
        -- absolute floor WITHOUT caching, and remember it so the addon can
        -- refine the value once GET_ITEM_INFO_RECEIVED delivers the real price.
        self.flooredItems = self.flooredItems or {}
        self.flooredItems[itemId] = true
        return Constants.MIN_REAGENT_PRICE, "floor"
    end

    return nil, "none"
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
    self.flooredItems = {}
    LazyProf:Print("Price cache cleared.")
end

-- Check if prices are stale
function PriceManager:ArePricesStale()
    local lastScan = LazyProf.db.char.lastAHScan or 0
    return (time() - lastScan) > Constants.PRICE_STALE_THRESHOLD
end
