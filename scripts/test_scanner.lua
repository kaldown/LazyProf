-- scripts/test_scanner.lua
--
-- Modules/Inventory/Scanner.lua: which owned stock counts. The bags are read
-- through the client adapter.
--
-- Run from the addon root:  lua5.1 scripts/test_scanner.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })
-- No container call may be made from the scanner itself.
_G.C_Container = setmetatable({}, { __index = function(_, name) error("C_Container." .. tostring(name) .. " used outside the adapter") end })
_G.GetContainerNumSlots = function() error("GetContainerNumSlots used outside the adapter") end
_G.GetContainerItemInfo = function() error("GetContainerItemInfo used outside the adapter") end

local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Modules/Inventory/StockMemory.lua",
    "Modules/Inventory/Scanner.lua",
})
local Inventory = LazyProf.Inventory

-- The client adapter, as the scanner sees it.
local client = { bags = {}, bagsBound = {}, backpackSlots = 16 }
LazyProf.Client = {
    BagContents = function() return client.bags, client.bagsBound, client.backpackSlots end,
}

T.section("bags", function()
    client.bags = { [2589] = 25, [765] = 11 }
    local items = Inventory:ScanBags()
    T.check("ScanBags is what the adapter reads", items[2589] == 25 and items[765] == 11)
    T.eq("GetItemCount counts the bags", Inventory:GetItemCount(2589), 25)
    T.eq("GetItemCount of something not carried", Inventory:GetItemCount(1), 0)
    local recipe = { reagents = { { itemId = 2589, count = 2 }, { itemId = 765, count = 12 } } }
    T.check("HasMaterials reads the bags", Inventory:HasMaterials(recipe) == false)
    local missing = Inventory:GetMissingMaterials(recipe, 1)
    T.check("GetMissingMaterials reads the bags", #missing == 1 and missing[1].itemId == 765 and missing[1].missing == 1)
end)

T.finish()
