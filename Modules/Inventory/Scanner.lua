-- Modules/Inventory/Scanner.lua
local ADDON_NAME, LazyProf = ...

LazyProf.Inventory = {}
local Inventory = LazyProf.Inventory

-- Scan bags and return item counts
function Inventory:ScanBags()
    local items = {}

    for bag = 0, 4 do
        local numSlots = C_Container and C_Container.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local itemId, count
            if C_Container then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info then
                    itemId = info.itemID
                    count = info.stackCount
                end
            else
                local _, itemCount, _, _, _, _, itemLink = GetContainerItemInfo(bag, slot)
                if itemLink then
                    itemId = tonumber(itemLink:match("item:(%d+)"))
                    count = itemCount
                end
            end

            if itemId and count then
                items[itemId] = (items[itemId] or 0) + count
            end
        end
    end

    return items
end

-- Get count of specific item in bags
function Inventory:GetItemCount(itemId)
    local items = self:ScanBags()
    return items[itemId] or 0
end

-- Check if we have enough materials for a recipe
function Inventory:HasMaterials(recipe, inventory)
    inventory = inventory or self:ScanBags()

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        if have < reagent.count then
            return false
        end
    end
    return true
end

-- Get missing materials for a recipe (quantity needed - quantity owned)
function Inventory:GetMissingMaterials(recipe, quantity, inventory)
    inventory = inventory or self:ScanBags()
    local missing = {}

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        local need = reagent.count * quantity
        local short = math.max(0, need - have)

        if short > 0 then
            table.insert(missing, {
                itemId = reagent.itemId,
                have = have,
                need = need,
                missing = short,
            })
        end
    end

    return missing
end
