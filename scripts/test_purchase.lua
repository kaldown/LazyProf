-- scripts/test_purchase.lua
--
-- Buying shopping-list reagents at a merchant: what to buy from what the
-- merchant sells (the plan), and buying it chunk by chunk (the runner), which
-- waits for each purchase to arrive before the next and stops on a closed
-- merchant, no money or full bags.
--
-- Run from the addon root:  lua5.1 scripts/test_purchase.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })
local LazyProf = harness.loadLazyProf({ "Core/Constants.lua", "Core/Utils.lua", "Modules/Shopping/PurchaseQueue.lua" })
local Queue = LazyProf.PurchaseQueue

local function row(itemId, name, toBuy, extra)
    local r = { itemId = itemId, name = name, toBuy = toBuy, need = toBuy, have = 0, crafted = false }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function item(index, itemId, name, price, extra)
    local i = { index = index, itemId = itemId, name = name, price = price, bundle = 1, stock = -1, maxStack = 20,
                extendedCost = false, purchasable = true }
    for k, v in pairs(extra or {}) do i[k] = v end
    return i
end

T.section("plan", function()
    local rows = {
        row(1, "Thread", 84), row(2, "Dye", 12), row(3, "Wool", 160), row(4, "Vial", 7), row(5, "Rare Salt", 3),
        row(6, "Token Ink", 2), row(7, "Gone", 5), row(8, "Owned", 0), row(9, "Bolt", 0, { crafted = true }),
        row(10, "Locked", 4),
    }
    local items = {
        item(1, 99, "Sword", 5000),
        item(2, 1, "Thread", 100),
        item(3, 2, "Dye", 350),
        item(4, 4, "Vial", 20, { bundle = 5, price = 100, maxStack = 20 }),
        item(5, 5, "Rare Salt", 500, { stock = 2 }),
        item(6, 6, "Token Ink", 0, { extendedCost = true }),
        item(7, 7, "Gone", 10, { stock = 0 }),
        item(8, 8, "Owned", 10),
        item(9, 9, "Bolt", 10),
        item(10, 10, "Locked", 10, { purchasable = false }),
    }
    -- A crafted reagent can still have a part to buy (what other crafted
    -- reagents are made from): that part is bought like any other.
    local partly = Queue.Plan({ row(11, "Bar", 6, { crafted = true }) }, { item(1, 11, "Bar", 300) })
    T.eq("a crafted row's part to buy is planned", #partly.entries, 1)
    T.eq("with its quantity", partly.entries[1].quantity, 6)
    T.eq("and cost", partly.total, 1800)

    local plan = Queue.Plan(rows, items)
    T.eq("entries: what this merchant sells for gold, without limit", #plan.entries, 3)
    local thread, dye, vial = plan.entries[1], plan.entries[2], plan.entries[3]
    T.eq("thread: quantity", thread.quantity, 84)
    T.eq("thread: cost", thread.cost, 8400)
    T.eq("thread: unit price", thread.unitPrice, 100)
    T.eq("dye: cost", dye.cost, 4200)
    T.eq("a bundle item is rounded up to whole bundles", vial.quantity, 10)
    T.eq("its unit price is the bundle price over its size", vial.unitPrice, 20)
    T.eq("its cost", vial.cost, 200)
    T.eq("total", plan.total, 8400 + 4200 + 200)

    local reasons = {}
    for _, s in ipairs(plan.skipped) do reasons[s.name] = s.reason end
    T.eq("limited stock is skipped and reported", reasons["Rare Salt"], "limited stock")
    T.eq("an item not sold for gold is skipped and reported", reasons["Token Ink"], "not sold for gold")
    T.eq("a sold-out item is skipped and reported", reasons["Gone"], "sold out")
    T.eq("an item this character cannot buy is skipped and reported", reasons["Locked"], "not available to you")
    T.check("an item not sold here is simply not listed", reasons["Wool"] == nil)
    T.check("nothing to buy of it: not listed", reasons["Owned"] == nil)
    T.check("a crafted reagent is not bought", reasons["Bolt"] == nil)
    T.eq("four skipped", #plan.skipped, 4)

    local empty = Queue.Plan({}, items)
    T.eq("no rows: nothing to do", #empty.entries + #empty.skipped, 0)
    T.eq("no rows: zero total", empty.total, 0)
    T.eq("no merchant items: nothing to do", #Queue.Plan(rows, {}).entries, 0)
    T.eq("nil lists do not error", #Queue.Plan(nil, nil).entries, 0)
end)

-- A fake merchant: buying puts items in the bags after the game "answers".
local function world(opts)
    opts = opts or {}
    local w = { open = true, money = opts.money or 1000000, slots = opts.slots or 10, bags = {}, bought = {}, timers = {},
                pending = {}, items = opts.items, reject = opts.reject }
    w.deps = {
        items = function() return w.items end,
        isOpen = function() return w.open end,
        money = function() return w.money end,
        freeSlots = function() return w.slots end,
        count = function(itemId) return w.bags[itemId] or 0 end,
        after = function(delay, fn) w.timers[#w.timers + 1] = fn end,
        buy = function(index, quantity)
            w.bought[#w.bought + 1] = { index = index, quantity = quantity }
            local it
            for _, i in ipairs(w.items) do if i.index == index then it = i end end
            -- reject(n): the game drops the n-th purchase (nothing arrives)
            if w.reject and w.reject(#w.bought) then return end
            w.pending[#w.pending + 1] = { itemId = it.itemId, quantity = quantity, cost = quantity * it.price / it.bundle }
        end,
    }
    -- The game answers: items arrive, money leaves, the bag event fires.
    function w.arrive(runner)
        local p = table.remove(w.pending, 1)
        if not p then return false end
        w.bags[p.itemId] = (w.bags[p.itemId] or 0) + p.quantity
        w.money = w.money - p.cost
        w.slots = w.slots - 1
        runner:OnInventoryChanged()
        return true
    end
    function w.fireTimers()
        local due = w.timers
        w.timers = {}
        for _, fn in ipairs(due) do fn() end
    end
    return w
end
local function boughtList(w)
    local out = {}
    for _, b in ipairs(w.bought) do out[#out + 1] = b.index .. "x" .. b.quantity end
    return table.concat(out, " ")
end

T.section("runner", function()
    local items = { item(1, 1, "Thread", 100), item(2, 2, "Dye", 350, { maxStack = 5 }) }
    local w = world({ items = items })
    local plan = Queue.Plan({ row(1, "Thread", 45), row(2, "Dye", 12) }, items)
    local done
    local runner = Queue.NewRunner(w.deps)
    runner:Start(plan.entries, function(result) done = result end)
    T.eq("the first purchase is made at once (inside the click)", boughtList(w), "1x20")
    T.check("still running", runner:IsRunning() and done == nil)
    runner:OnInventoryChanged()
    T.eq("an unrelated bag change buys nothing", #w.bought, 1)
    w.arrive(runner)
    T.eq("the next chunk follows the arrival of the previous", boughtList(w), "1x20 1x20")
    w.arrive(runner)
    T.eq("chunks are no larger than the item's stack", boughtList(w), "1x20 1x20 1x5")
    w.arrive(runner)
    w.arrive(runner)
    w.arrive(runner)
    T.eq("then the next item, in its own chunks", boughtList(w), "1x20 1x20 1x5 2x5 2x5 2x2")
    w.arrive(runner)
    T.check("finished", done ~= nil and not runner:IsRunning())
    T.eq("everything bought", done.bought[1].name .. ":" .. done.bought[1].quantity .. " " .. done.bought[2].name .. ":" .. done.bought[2].quantity,
        "Thread:45 Dye:12")
    T.check("no stop reason", done.stopped == nil)
    T.eq("report line", Queue.Report(done, plan.skipped), "Bought 45x Thread, 12x Dye.")
    w.fireTimers()
    T.eq("late timers buy nothing more", #w.bought, 6)
end)

T.section("runner: indices move", function()
    local items = { item(1, 1, "Thread", 100), item(2, 2, "Dye", 350) }
    local w = world({ items = items })
    local runner = Queue.NewRunner(w.deps)
    runner:Start(Queue.Plan({ row(2, "Dye", 30) }, items).entries, function() end)
    T.eq("bought by index", boughtList(w), "2x20")
    -- The merchant's list changes (a filter): the item is now at another index.
    w.items = { item(1, 2, "Dye", 350), item(2, 1, "Thread", 100) }
    w.arrive(runner)
    T.eq("the index is looked up again before each purchase", boughtList(w), "2x20 1x10")
end)

T.section("runner: stops", function()
    local items = { item(1, 1, "Thread", 100), item(2, 2, "Dye", 350) }
    local function start(opts, rows)
        opts.items = opts.items or items
        local w = world(opts)
        local result
        local runner = Queue.NewRunner(w.deps)
        local plan = Queue.Plan(rows or { row(1, "Thread", 45), row(2, "Dye", 12) }, opts.items)
        runner:Start(plan.entries, function(r) result = r end)
        return w, runner, function() return result end, plan
    end

    -- Merchant closed
    local w, runner, result = start({})
    w.open = false
    w.arrive(runner)
    T.eq("merchant closed: stops", result().stopped, "the merchant window closed")
    T.eq("merchant closed: nothing after the close", #w.bought, 1)
    T.eq("merchant closed: reports what arrived", result().bought[1].quantity, 20)
    T.eq("merchant closed: report line", Queue.Report(result(), {}), "Bought 20x Thread. Stopped: the merchant window closed.")

    -- Not enough money (before the first purchase, and in the middle)
    w, runner, result = start({ money = 50 })
    T.eq("no money at all: nothing bought", #w.bought, 0)
    T.eq("no money at all: says so", result().stopped, "not enough money")
    T.eq("nothing bought report", Queue.Report(result(), {}), "Nothing bought. Stopped: not enough money.")
    w, runner, result = start({ money = 2500 })
    w.arrive(runner)
    T.eq("money runs out: stops before the chunk it cannot pay", #w.bought, 1)
    T.eq("money runs out: says so", result().stopped, "not enough money")

    -- No free slot
    w, runner, result = start({ slots = 1 })
    w.arrive(runner)
    T.eq("bags full: stops", result().stopped, "no free bag slot")
    T.eq("bags full: one chunk bought", #w.bought, 1)

    -- The item disappears from the merchant
    w, runner, result = start({})
    w.items = { item(1, 2, "Dye", 350) }
    w.arrive(runner)
    w.arrive(runner)
    T.check("an item no longer sold is skipped, the rest is bought", result() ~= nil and result().stopped == nil)
    T.eq("what was bought of it is reported", result().bought[1].quantity, 20)
    T.eq("the other item is complete", result().bought[2].quantity, 12)

    -- Cancel
    w, runner, result = start({})
    runner:Cancel("stopped by you")
    w.arrive(runner)
    T.eq("cancel: no further purchases", #w.bought, 1)
    T.eq("cancel: reason kept", result().stopped, "stopped by you")
end)

T.section("runner: purchases outside the click are refused", function()
    local items = { item(1, 1, "Thread", 100) }
    -- The game accepts the first purchase (made in the click) and drops the second.
    local w = world({ items = items, reject = function(n) return n == 2 end })
    local result
    local runner = Queue.NewRunner(w.deps)
    runner:Start(Queue.Plan({ row(1, "Thread", 60) }, items).entries, function(r) result = r end)
    w.arrive(runner)
    T.eq("second purchase attempted after the first arrived", #w.bought, 2)
    w.fireTimers()
    T.check("nothing arrived for it: the run ends", result ~= nil)
    T.check("and the runner switches to one purchase per click", runner:ClickOnly())
    T.eq("what arrived is reported", result.bought[1].quantity, 20)
    T.eq("report says to click again", Queue.Report(result, {}),
        "Bought 20x Thread. The game allows one purchase per click here: click again to continue.")

    -- In that mode a click buys one chunk and stops.
    result = nil
    w.reject = nil
    runner:Start(Queue.Plan({ row(1, "Thread", 40) }, items).entries, function(r) result = r end)
    T.eq("click-only: one purchase per click", #w.bought, 3)
    w.arrive(runner)
    T.check("click-only: done after it arrives", result ~= nil and result.bought[1].quantity == 20)
    T.eq("click-only: nothing more bought by itself", #w.bought, 3)
    T.check("click-only: more is left", result.remaining == 20)

    -- The first purchase itself never arrives (e.g. the item cannot be carried).
    w = world({ items = items, reject = function() return true end })
    result = nil
    runner = Queue.NewRunner(w.deps)
    runner:Start(Queue.Plan({ row(1, "Thread", 10) }, items).entries, function(r) result = r end)
    w.fireTimers()
    T.eq("a first purchase that never arrives stops the run", result and result.stopped, "the purchase did not go through")
    T.check("and does not switch modes", not runner:ClickOnly())
end)

T.section("report", function()
    local skipped = { { name = "Rare Salt", reason = "limited stock" }, { name = "Token Ink", reason = "not sold for gold" } }
    T.eq("skipped items are named with their reason",
        Queue.Report({ bought = { { name = "Thread", quantity = 5 } } }, skipped),
        "Bought 5x Thread. Skipped Rare Salt (limited stock), Token Ink (not sold for gold).")
    T.eq("only skipped", Queue.Report({ bought = {} }, skipped),
        "Nothing bought. Skipped Rare Salt (limited stock), Token Ink (not sold for gold).")
    T.check("plain ASCII", not Queue.Report({ bought = { { name = "Thread", quantity = 5 } } }, skipped):find("[\128-\255]"))
end)

T.finish()
