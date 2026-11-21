-- Modules/Shopping/VendorMemory.lua
-- Vendor prices LazyProf has seen itself. When a merchant window is open,
-- every reagent it sells for gold without a stock limit is remembered with
-- its price per item, account-wide (LazyProfDB.global.vendorPrices).
--
-- A vendor price is a fixed fact of the game, not a market price, so this is
-- not an auction scan: market prices still come only from TSM / Auctionator.
-- It matters most where no shipped vendor list exists and no price addon is
-- installed: without it nothing there is ever known to be a vendor item.
--
-- Not remembered: limited-stock items (the price is real but the supply is
-- not), items priced in something other than gold, and items that are not a
-- reagent of any profession of this client.
local ADDON_NAME, LazyProf = ...

local VendorMemory = {}
LazyProf.VendorMemory = VendorMemory

local reagentSet = nil   -- [itemId] = true for every reagent of the registered professions

local function Reagents()
    if reagentSet then return reagentSet end
    local professions = LazyProf.Professions
    if not (professions and professions.GetAllReagentIds) then return {} end
    local ids = professions:GetAllReagentIds()
    if #ids == 0 then return {} end   -- professions not registered yet: try again later
    reagentSet = {}
    for _, itemId in ipairs(ids) do
        reagentSet[itemId] = true
    end
    return reagentSet
end

local function Store()
    local global = LazyProf.db and LazyProf.db.global
    if not global then return nil end
    global.vendorPrices = global.vendorPrices or {}
    return global.vendorPrices
end

-- Remember what a merchant sells (items: Client:MerchantItems()). Returns the
-- item ids whose remembered price is new or changed.
function VendorMemory:Record(items)
    local changed = {}
    local store = Store()
    if not store then return changed end
    local reagents = Reagents()
    for _, item in ipairs(items or {}) do
        local unlimited = type(item.stock) == "number" and item.stock < 0
        local forGold = not item.extendedCost and type(item.price) == "number" and item.price > 0
        if item.itemId and reagents[item.itemId] and unlimited and forGold then
            local bundle = (item.bundle and item.bundle > 0) and item.bundle or 1
            local unitPrice = math.max(1, math.floor(item.price / bundle + 0.5))
            if store[item.itemId] ~= unitPrice then
                store[item.itemId] = unitPrice
                changed[#changed + 1] = item.itemId
            end
        end
    end
    return changed
end

-- Remembered price per item (copper), nil when the item was never seen.
function VendorMemory:Get(itemId)
    local store = Store()
    return store and store[itemId] or nil
end

function VendorMemory:Count()
    local n = 0
    for _ in pairs(Store() or {}) do n = n + 1 end
    return n
end
