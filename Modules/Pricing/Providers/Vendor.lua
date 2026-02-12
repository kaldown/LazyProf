-- Modules/Pricing/Providers/Vendor.lua
-- Queries vendor buy prices from TSM and Auctionator, which record
-- prices automatically when the player visits a merchant.
local ADDON_NAME, LazyProf = ...

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

LazyProf.PriceProviders.vendor = {
    name = "Vendor",

    IsAvailable = function(self)
        return TSM_API ~= nil
            or (Auctionator and Auctionator.API and Auctionator.API.v1
                and Auctionator.API.v1.GetVendorPriceByItemID)
    end,

    GetPrice = function(self, itemId)
        -- TSM tracks vendor buy prices when players visit merchants
        if TSM_API then
            local price = TSM_API.GetCustomPriceValue("vendorbuy", "i:" .. itemId)
            if price and price > 0 then
                return price
            end
        end

        -- Auctionator also tracks vendor prices from merchant visits
        if Auctionator and Auctionator.API and Auctionator.API.v1
                and Auctionator.API.v1.GetVendorPriceByItemID then
            local price = Auctionator.API.v1.GetVendorPriceByItemID("LazyProf", itemId)
            if price and price > 0 then
                return price
            end
        end

        return nil
    end,
}
