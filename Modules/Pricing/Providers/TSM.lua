-- Modules/Pricing/Providers/TSM.lua
local ADDON_NAME, LazyProf = ...

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

LazyProf.PriceProviders.tsm = {
    name = "TSM",

    IsAvailable = function(self)
        return TSM_API ~= nil
    end,

    GetPrice = function(self, itemId)
        if not self:IsAvailable() then return nil end

        local itemString = "i:" .. itemId
        -- Try DBMarket first, fall back to DBMinBuyout
        local price = TSM_API.GetCustomPriceValue("DBMarket", itemString)
        if not price or price == 0 then
            price = TSM_API.GetCustomPriceValue("DBMinBuyout", itemString)
        end
        return price
    end,
}
