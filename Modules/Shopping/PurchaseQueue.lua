-- Modules/Shopping/PurchaseQueue.lua
-- Buying shopping-list reagents at a merchant. Pure: the merchant, the bags
-- and the money are reached only through the functions the runner is given,
-- so everything here runs headlessly.
--
--   Queue.Plan(rows, items) -> { entries, skipped, total }
--       rows: the shopping rows (Pathfinder:CalculateMissingMaterials().rows)
--       items: what the open merchant sells (Client:MerchantItems())
--       entries: { itemId, name, quantity, unitPrice, cost } to buy, in row order
--       skipped: { itemId, name, reason } rows the merchant sells but that are
--                not bought automatically (limited stock, not sold for gold, ...)
--   Queue.NewRunner(deps) -> runner
--       runner:Start(entries, onDone)   buys the first chunk at once (so it
--           happens inside the player's click); each later chunk goes out when
--           the previous one has arrived in the bags
--       runner:OnInventoryChanged()     call on merchant and bag updates
--       runner:Cancel(reason)
--       onDone(result): { bought = { { itemId, name, quantity } }, stopped =
--           reason or nil, remaining = items still to buy, clickOnly = bool }
--   Queue.Report(result, skipped) -> one line for the player
--
-- A merchant's list can change while it is open (filters), so an item's index
-- is looked up again before each purchase. A purchase is known to have worked
-- only by the items arriving; when a purchase made after the click never
-- arrives, the client is taken to allow one purchase per click and the runner
-- switches to that for good ("click again to continue").
local ADDON_NAME, LazyProf = ...

local Queue = {}
LazyProf.PurchaseQueue = Queue

-- How long to wait for a purchase to arrive before giving up on it.
Queue.ARRIVAL_TIMEOUT = 2.0

-- Stock as the merchant reports it: above zero is a limited supply, zero is
-- sold out, below zero is unlimited.
local function StockReason(stock)
    if type(stock) ~= "number" or stock < 0 then return nil end
    if stock == 0 then return "sold out" end
    return "limited stock"
end

function Queue.Plan(rows, items)
    local plan = { entries = {}, skipped = {}, total = 0 }
    local byItem = {}
    for _, item in ipairs(items or {}) do
        if item.itemId and not byItem[item.itemId] then
            byItem[item.itemId] = item
        end
    end
    for _, row in ipairs(rows or {}) do
        local item = byItem[row.itemId]
        if item and not row.crafted and (row.toBuy or 0) > 0 then
            local reason
            if item.extendedCost or not item.price or item.price <= 0 then
                reason = "not sold for gold"
            elseif item.purchasable == false then
                reason = "not available to you"
            else
                reason = StockReason(item.stock)
            end
            local name = row.name or item.name or "Unknown"
            if reason then
                plan.skipped[#plan.skipped + 1] = { itemId = row.itemId, name = name, reason = reason }
            else
                local bundle = (item.bundle and item.bundle > 0) and item.bundle or 1
                local quantity = math.ceil(row.toBuy / bundle) * bundle
                local unitPrice = item.price / bundle
                local cost = (quantity / bundle) * item.price   -- whole bundles: whole copper
                plan.entries[#plan.entries + 1] = {
                    itemId = row.itemId, name = name, quantity = quantity, unitPrice = unitPrice, cost = cost,
                }
                plan.total = plan.total + cost
            end
        end
    end
    return plan
end

-- Runner ------------------------------------------------------------------------

local Runner = {}
Runner.__index = Runner

-- deps: items() -> merchant items, isOpen(), money(), freeSlots(),
-- count(itemId) -> how many are in the bags, buy(index, quantity),
-- after(seconds, fn).
function Queue.NewRunner(deps)
    return setmetatable({ deps = deps, clickOnly = false, running = false }, Runner)
end

function Runner:IsRunning()
    return self.running
end

-- True once a purchase made outside a click never arrived.
function Runner:ClickOnly()
    return self.clickOnly
end

function Runner:Start(entries, onDone)
    if self.running then return end
    self.running = true
    self.onDone = onDone
    self.waiting = nil
    self.queue = {}
    self.result = { bought = {} }
    for _, entry in ipairs(entries or {}) do
        self.queue[#self.queue + 1] = { itemId = entry.itemId, name = entry.name, remaining = entry.quantity }
    end
    self:Next(true)
end

local function FindItem(items, itemId)
    for _, item in ipairs(items or {}) do
        if item.itemId == itemId then return item end
    end
end

function Runner:Finish(reason, clickOnly)
    if not self.running then return end
    self.running = false
    self.waiting = nil
    local result = self.result
    result.stopped = reason
    result.clickOnly = clickOnly or nil
    local remaining = 0
    for _, entry in ipairs(self.queue) do
        if not entry.dropped then remaining = remaining + entry.remaining end
    end
    result.remaining = remaining
    if self.onDone then self.onDone(result) end
end

function Runner:Cancel(reason)
    self:Finish(reason or "stopped")
end

-- Buy the next chunk. inClick: this call runs inside the player's click.
function Runner:Next(inClick)
    local deps = self.deps
    while true do
        local entry
        for _, candidate in ipairs(self.queue) do
            if candidate.remaining > 0 and not candidate.dropped then
                entry = candidate
                break
            end
        end
        if not entry then
            return self:Finish(nil)
        end
        if not deps.isOpen() then
            return self:Finish("the merchant window closed")
        end

        local item = FindItem(deps.items(), entry.itemId)
        if not item or item.extendedCost or StockReason(item.stock) then
            -- No longer sold here (or no longer freely): leave the rest of it.
            entry.dropped = true
        else
            local bundle = (item.bundle and item.bundle > 0) and item.bundle or 1
            local limit = math.max(item.maxStack or bundle, bundle)
            local chunk = math.floor(math.min(entry.remaining, limit) / bundle) * bundle
            if chunk <= 0 then chunk = bundle end
            local cost = chunk * (item.price / bundle)
            if deps.money() < cost then
                return self:Finish("not enough money")
            end
            if deps.freeSlots() < 1 then
                return self:Finish("no free bag slot")
            end

            local waiting = { entry = entry, chunk = chunk, before = deps.count(entry.itemId), inClick = inClick }
            self.waiting = waiting
            deps.buy(item.index, chunk)
            deps.after(Queue.ARRIVAL_TIMEOUT, function()
                self:OnTimeout(waiting)
            end)
            return
        end
    end
end

local function Arrived(self, waiting)
    return self.deps.count(waiting.entry.itemId) >= waiting.before + waiting.chunk
end

-- The purchase being waited for is in the bags: count it and go on.
function Runner:Advance()
    local waiting = self.waiting
    self.waiting = nil
    local entry = waiting.entry
    entry.remaining = math.max(0, entry.remaining - waiting.chunk)
    local bought = self.result.bought
    local last = bought[#bought]
    if last and last.itemId == entry.itemId then
        last.quantity = last.quantity + waiting.chunk
    else
        bought[#bought + 1] = { itemId = entry.itemId, name = entry.name, quantity = waiting.chunk }
    end
    if self.clickOnly then
        -- One purchase per click: the next one needs another click.
        return self:Finish(nil, true)
    end
    self:Next(false)
end

-- A merchant or bag update: has the purchase arrived?
function Runner:OnInventoryChanged()
    if not (self.running and self.waiting) then return end
    if Arrived(self, self.waiting) then
        self:Advance()
    end
end

-- Nothing arrived in time for a purchase.
function Runner:OnTimeout(waiting)
    if not self.running or self.waiting ~= waiting then return end
    if Arrived(self, waiting) then
        return self:Advance()
    end
    if waiting.inClick then
        return self:Finish("the purchase did not go through")
    end
    -- Made outside the click and dropped: from now on, one per click.
    self.clickOnly = true
    self:Finish(nil, true)
end

-- Report ------------------------------------------------------------------------

function Queue.Report(result, skipped)
    local parts = {}
    local bought = {}
    for _, b in ipairs(result and result.bought or {}) do
        bought[#bought + 1] = string.format("%dx %s", b.quantity, b.name)
    end
    parts[#parts + 1] = #bought > 0 and ("Bought " .. table.concat(bought, ", ") .. ".") or "Nothing bought."
    if result and result.stopped then
        parts[#parts + 1] = "Stopped: " .. result.stopped .. "."
    elseif result and result.clickOnly and (result.remaining or 0) > 0 then
        parts[#parts + 1] = "The game allows one purchase per click here: click again to continue."
    end
    local left = {}
    for _, s in ipairs(skipped or {}) do
        left[#left + 1] = string.format("%s (%s)", s.name, s.reason)
    end
    if #left > 0 then
        parts[#parts + 1] = "Skipped " .. table.concat(left, ", ") .. "."
    end
    return table.concat(parts, " ")
end
