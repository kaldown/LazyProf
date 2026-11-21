-- Modules/Pricing/Providers/Auctionator.lua
local ADDON_NAME, LazyProf = ...

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

LazyProf.PriceProviders.auctionator = {
    name = "Auctionator",

    IsAvailable = function(self)
        return Auctionator and Auctionator.API and Auctionator.API.v1
    end,

    -- Returns the price, no detail, and the number of days since Auctionator
    -- last saw a price for the item (its public API's GetAuctionAgeByItemID;
    -- nil when that call is missing or has no data).
    GetPrice = function(self, itemId)
        if not self:IsAvailable() then return nil end

        local api = Auctionator.API.v1
        local price = api.GetAuctionPriceByItemID("LazyProf", itemId)
        if not price then return nil end
        local ageDays
        if api.GetAuctionAgeByItemID then
            ageDays = api.GetAuctionAgeByItemID("LazyProf", itemId)
        end
        return price, nil, ageDays
    end,
}
