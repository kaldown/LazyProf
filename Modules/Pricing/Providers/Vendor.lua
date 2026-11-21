-- Modules/Pricing/Providers/Vendor.lua
-- Vendor BUY prices: what a reagent costs at a merchant. Looked up before any
-- market price (a vendor is a guaranteed supply at a fixed price). Sources,
-- in order:
--   1. TSM / Auctionator, which record merchant prices as the player visits
--      merchants;
--   2. prices LazyProf saw at merchants itself (Modules/Shopping/VendorMemory.lua);
--   3. the vendor-reagent list shipped with the recipe data, where the client
--      has one.
-- GetPrice returns the price and where it came from ("TSM", "Auctionator",
-- "seen", "list"); every one of them is reported as a vendor price.
local ADDON_NAME, LazyProf = ...

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

LazyProf.PriceProviders.vendor = {
    name = "Vendor",

    IsAvailable = function(self)
        return true
    end,

    GetPrice = function(self, itemId)
        -- TSM tracks vendor buy prices when players visit merchants
        if TSM_API then
            local price = TSM_API.GetCustomPriceValue("vendorbuy", "i:" .. itemId)
            if price and price > 0 then
                return price, "TSM"
            end
        end

        -- Auctionator also tracks vendor prices from merchant visits
        if Auctionator and Auctionator.API and Auctionator.API.v1
                and Auctionator.API.v1.GetVendorPriceByItemID then
            local price = Auctionator.API.v1.GetVendorPriceByItemID("LazyProf", itemId)
            if price and price > 0 then
                return price, "Auctionator"
            end
        end

        -- Seen at a merchant by LazyProf
        local memory = LazyProf.VendorMemory
        local seen = memory and memory:Get(itemId)
        if seen and seen > 0 then
            return seen, "seen"
        end

        -- The shipped list of vendor-stocked reagents
        local CraftLib = _G.CraftLib
        local listed = CraftLib and CraftLib.GetVendorBuyPrice and CraftLib:GetVendorBuyPrice(itemId)
        if listed and listed > 0 then
            return listed, "list"
        end

        return nil
    end,
}
