-- Modules/Pricing/Providers/TSM.lua
local ADDON_NAME, LazyProf = ...
local Constants = LazyProf.Constants

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

LazyProf.PriceProviders.tsm = {
    name = "TSM",

    IsAvailable = function(self)
        return TSM_API ~= nil
    end,

    GetPrice = function(self, itemId)
        if not self:IsAvailable() then return nil end

        local itemString = "i:" .. itemId

        -- Use the user-selected price source
        local selectedSource = LazyProf.db and LazyProf.db.profile.tsmPriceSource
            or Constants.TSM_PRICE_SOURCE.MIN_BUYOUT

        local price = TSM_API.GetCustomPriceValue(selectedSource, itemString)

        -- Fallback chain if primary source returns nothing
        -- Note: TSM returns 0 when there's no data (can't list items for 0 copper)
        if not price or price == 0 then
            -- Try other sources as fallback
            local fallbacks = {
                Constants.TSM_PRICE_SOURCE.MIN_BUYOUT,
                Constants.TSM_PRICE_SOURCE.MARKET,
                Constants.TSM_PRICE_SOURCE.REGION_AVG,
            }
            for _, source in ipairs(fallbacks) do
                if source ~= selectedSource then
                    price = TSM_API.GetCustomPriceValue(source, itemString)
                    if price and price > 0 then
                        break
                    end
                end
            end
        end

        -- Return nil if no valid price found (0 means no data in TSM)
        if not price or price == 0 then
            return nil
        end

        return price
    end,
}
