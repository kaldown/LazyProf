-- Modules/Pricing/Providers/VendorSell.lua
-- Last-resort price floor using the item's VENDOR SELL value (the gray
-- "sell to a vendor" price), read straight from the game client via
-- GetItemInfo. This is always available offline with no AH, no TSM and no
-- Auctionator, so it lets the Cheapest strategy rank recipes even when the
-- player has no market data at all.
--
-- This is NOT the same as Providers/Vendor.lua: that one reports vendor BUY
-- prices for vendor-stocked goods (thread, dye) recorded by TSM/Auctionator.
-- VendorSell reports the sell value that EVERY tradeable item carries.
--
-- Returns nil when the item is not yet cached client-side (GetItemInfo returns
-- nil until a server round-trip completes) or is genuinely non-sellable
-- (sellPrice == 0). PriceManager applies the absolute MIN_REAGENT_PRICE floor
-- in those cases and refreshes once GET_ITEM_INFO_RECEIVED fires.
local ADDON_NAME, LazyProf = ...

LazyProf.PriceProviders = LazyProf.PriceProviders or {}

LazyProf.PriceProviders.vendorsell = {
    name = "VendorSell",

    -- GetItemInfo is a base API present on every supported client.
    IsAvailable = function(self)
        return true
    end,

    GetPrice = function(self, itemId)
        -- 11th return of GetItemInfo is the vendor sell price (copper).
        local sellPrice = select(11, GetItemInfo(itemId))
        if sellPrice and sellPrice > 0 then
            return sellPrice
        end
        return nil
    end,
}
