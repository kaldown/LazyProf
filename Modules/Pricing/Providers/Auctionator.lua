-- Modules/Pricing/Providers/Auctionator.lua
local ADDON_NAME, LazyProf = ...

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

LazyProf.PriceProviders.auctionator = {
    name = "Auctionator",

    IsAvailable = function(self)
        return Auctionator and Auctionator.API and Auctionator.API.v1
    end,

    GetPrice = function(self, itemId)
        if not self:IsAvailable() then return nil end

        local price = Auctionator.API.v1.GetAuctionPriceByItemID("LazyProf", itemId)
        return price
    end,
}
