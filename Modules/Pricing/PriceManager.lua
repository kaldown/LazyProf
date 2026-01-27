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

    -- Load providers in priority order
    local priority = LazyProf.db.profile.priceSourcePriority
    for _, name in ipairs(priority) do
        local provider = LazyProf.PriceProviders and LazyProf.PriceProviders[name]
        if provider and provider:IsAvailable() then
            table.insert(self.providers, provider)
            LazyProf:Debug("pricing", "Price provider enabled: " .. name)
        end
    end
end

-- Get price for an item
function PriceManager:GetPrice(itemId)
    -- Check cache first
    local cached = self.cache[itemId]
    if cached and (time() - cached.timestamp) < Constants.PRICE_CACHE_TTL then
        return cached.price, cached.source
    end

    -- Query providers in order
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
    LazyProf:Print("Price cache cleared.")
end

-- Check if prices are stale
function PriceManager:ArePricesStale()
    local lastScan = LazyProf.db.char.lastAHScan or 0
    return (time() - lastScan) > Constants.PRICE_STALE_THRESHOLD
end
