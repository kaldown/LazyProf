-- Modules/Pricing/Providers/Vendor.lua
local ADDON_NAME, LazyProf = ...

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

-- Vendor-sold items with their prices (in copper)
local VendorPrices = {
    -- Thread/dyes used by Tailoring (not First Aid, but for future)
    [2320] = 10,      -- Coarse Thread
    [2321] = 100,     -- Fine Thread
    [4291] = 500,     -- Silken Thread
    [8343] = 2500,    -- Heavy Silken Thread
    [14341] = 5000,   -- Rune Thread

    -- Note: Cloth is not vendor-sold, so First Aid materials
    -- will rely on AH prices or show as "no price data"
}

LazyProf.PriceProviders.vendor = {
    name = "Vendor",

    IsAvailable = function(self)
        return true -- Always available as fallback
    end,

    GetPrice = function(self, itemId)
        return VendorPrices[itemId]
    end,
}
