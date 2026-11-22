-- scripts/test_merchant.lua
--
-- The merchant panel: appears beside the merchant window when the merchant
-- sells reagents of the shopping list, buys them (one row, or all) through
-- the purchase queue, reports the outcome, remembers vendor prices, and the
-- /lp diag merchant dump.
--
-- Run from the addon root:  lua5.1 scripts/test_merchant.lua

package.path = "./?.lua;" .. package.path
local W = require("scripts.lib.window")
local T = require("scripts.lib.check").new()

local THREAD, DYE, SALT, SWORD = 201, 202, 203, 204

local function setup()
    local env = W.load("forever", {
        "Modules/Shopping/PurchaseQueue.lua",
        "Modules/Shopping/VendorMemory.lua",
        "Modules/Guide/TrainerMemory.lua",
        "Modules/UI/MerchantPanel.lua",
    })
    local addon, ui = env.addon, env.ui
    env.merchant = { open = false, money = 1000000, slots = 20, bags = {}, bought = {} }
    local m = env.merchant
    m.items = {
        { index = 1, itemId = SWORD, name = "Sword", price = 5000, bundle = 1, stock = -1, maxStack = 1, extendedCost = false, purchasable = true },
        { index = 2, itemId = THREAD, name = "Thread", price = 100, bundle = 1, stock = -1, maxStack = 20, extendedCost = false, purchasable = true },
        { index = 3, itemId = DYE, name = "Dye", price = 350, bundle = 1, stock = -1, maxStack = 5, extendedCost = false, purchasable = true },
        { index = 4, itemId = SALT, name = "Salt", price = 500, bundle = 1, stock = 2, maxStack = 5, extendedCost = false, purchasable = true },
    }
    env.merchantFrame = ui.newFrame("Frame", "MerchantWindow")
    local Client = addon.Client
    Client.StartMerchant = function(_, callbacks) env.merchantCallbacks = callbacks end
    Client.IsMerchantOpen = function() return m.open end
    Client.MerchantAnchorFrame = function() return env.merchantFrame end
    Client.MerchantItems = function() return m.items end
    Client.Money = function() return m.money end
    Client.FreeBagSlots = function() return m.slots end
    Client.BuyFromMerchant = function(_, index, quantity)
        m.bought[#m.bought + 1] = index .. "x" .. quantity
        m.pending = { index = index, quantity = quantity }
    end
    Client.RunMerchantDiagnostic = function(_, lines) lines[#lines + 1] = "adapter items=" .. #m.items end
    addon.Inventory = {
        ScanAll = function() return {}, {} end,
        ScanBags = function() return m.bags end,
    }
    addon.Professions.GetAllReagentIds = function() return { THREAD, DYE, SALT } end
    addon.ScheduleRecalculation = function(_, reason) env.scheduled = reason end
    -- The shopping list the window works out for its path.
    env.rows = {
        { itemId = THREAD, name = "Thread", toBuy = 45, need = 45, have = 0, crafted = false },
        { itemId = DYE, name = "Dye", toBuy = 12, need = 12, have = 0, crafted = false },
        { itemId = SALT, name = "Salt", toBuy = 3, need = 3, have = 0, crafted = false },
        { itemId = 999, name = "Wool", toBuy = 100, need = 100, have = 0, crafted = false },
    }
    addon.Pathfinder.CalculateMissingMaterials = function() return { rows = env.rows } end
    env.panel = addon.MerchantPanel
    env.panel:Initialize()
    -- The game answers the last purchase: items arrive and the bags change.
    function env.arrive()
        local p = m.pending
        if not p then return false end
        m.pending = nil
        local itemId
        for _, item in ipairs(m.items) do if item.index == p.index then itemId = item.itemId end end
        m.bags[itemId] = (m.bags[itemId] or 0) + p.quantity
        for _, row in ipairs(env.rows) do
            if row.itemId == itemId then row.toBuy = math.max(0, row.toBuy - p.quantity) end
        end
        env.panel:OnInventoryChanged()
        return true
    end
    function env.openMerchant()
        m.open = true
        env.merchantCallbacks.onShow()
    end
    function env.closeMerchant()
        m.open = false
        env.merchantCallbacks.onClose()
    end
    function env.rowTexts()
        local out = {}
        for _, row in ipairs(env.panel.list.rows) do
            local d = row.desc
            out[#out + 1] = (d.text or "") .. ((d.right and d.right ~= "") and (" | " .. d.right) or "")
                .. (d.button and (" [" .. d.button.text .. "]") or "")
        end
        return out
    end
    return env
end

T.section("panel", function()
    local env = setup()
    local panel, ui, addon, m = env.panel, env.ui, env.addon, env.merchant

    -- No shopping list yet this session: nothing to show, prices still learned.
    env.openMerchant()
    T.check("no path shown yet: no panel", panel.frame == nil or not panel.frame.shown)
    T.eq("vendor prices are remembered on a merchant visit", addon.VendorMemory:Get(THREAD), 100)
    T.check("limited stock is not remembered", addon.VendorMemory:Get(SALT) == nil)
    T.check("an item that is no reagent is not remembered", addon.VendorMemory:Get(SWORD) == nil)
    env.closeMerchant()

    -- A path was shown: its shopping list is matched against the merchant.
    env.window:Update(W.path())
    env.window:OnProfessionClosed()
    env.open = false
    env.openMerchant()
    local frame = panel.frame
    T.check("panel shown", frame ~= nil and frame.shown)
    local pt = frame.points[#frame.points]
    T.check("docked to the right of the merchant window", pt[1] == "TOPLEFT" and pt[2] == env.merchantFrame and pt[3] == "TOPRIGHT")
    T.eq("title names the list", frame.title.text, "LazyProf: on your list - Tailoring 75-150")
    local rows = env.rowTexts()
    T.eq("a row per reagent this merchant sells", rows[1], "Thread | 45   45s [Buy]")
    T.eq("second row", rows[2], "Dye | 12   42s [Buy]")
    T.eq("a limited-stock reagent is listed with the reason, without a button", rows[3], "Salt | limited stock")
    T.eq("nothing else (the merchant does not sell wool)", #rows, 3)
    T.eq("Buy all carries the total", panel.buyAllBtn.text, "Buy all - 87s")
    T.check("Buy all enabled", panel.buyAllBtn.enabled)

    -- Buy all: the first purchase in the click, the rest as each one arrives.
    ui.fire(panel.buyAllBtn, "OnClick")
    T.eq("first purchase made in the click", table.concat(m.bought, " "), "2x20")
    T.eq("button shows it is working", panel.buyAllBtn.text, "Buying...")
    T.check("buttons are off while buying", not panel.buyAllBtn.enabled and panel.list.rows[1].button.enabled == false)
    ui.fire(panel.buyAllBtn, "OnClick")
    T.eq("a second click while buying does nothing", #m.bought, 1)
    while env.arrive() do end
    T.eq("chunks follow each arrival, per item", table.concat(m.bought, " "), "2x20 2x20 2x5 3x5 3x5 3x2")
    T.eq("report printed in one line", env.printed, "Bought 45x Thread, 12x Dye. Skipped Salt (limited stock).")
    rows = env.rowTexts()
    T.eq("bought rows are gone, the skipped one stays", rows[1], "Salt | limited stock")
    T.eq("the report stays in the panel", rows[2], "Bought 45x Thread, 12x Dye. Skipped Salt (limited stock).")
    T.check("Buy all is off with nothing left", not panel.buyAllBtn.enabled)
    T.check("the panel stays for the report", frame.shown)

    -- Closing the merchant hides the panel and forgets the report.
    env.closeMerchant()
    T.check("merchant closed: hidden", not frame.shown and panel.plan == nil and panel.report == nil)

    -- One row's Buy button buys only that reagent.
    env.rows[1].toBuy, env.rows[2].toBuy = 10, 4
    m.bought, m.bags = {}, {}
    env.openMerchant()
    ui.fire(panel.list.rows[2].button, "OnClick", "LeftButton")
    while env.arrive() do end
    T.eq("row Buy: only that item", table.concat(m.bought, " "), "3x4")
    T.eq("row Buy: report", env.printed, "Bought 4x Dye. Skipped Salt (limited stock).")
    T.eq("the other reagent is still listed", env.rowTexts()[1], "Thread | 10   10s [Buy]")

    -- The close button keeps it closed until the next visit.
    ui.fire(frame.closeBtn, "OnClick")
    panel:Refresh()
    T.check("closed by the player: stays closed for this visit", not frame.shown)
    env.closeMerchant()
    env.openMerchant()
    T.check("next visit: shown again", frame.shown)

    -- A merchant that sells nothing on the list.
    env.closeMerchant()
    m.items = { m.items[1] }
    env.openMerchant()
    T.check("nothing on the list here: hidden", not frame.shown)
    env.closeMerchant()
end)

T.section("stops and combat", function()
    local env = setup()
    local panel, ui, m = env.panel, env.ui, env.merchant
    env.window:Update(W.path())
    env.openMerchant()
    local frame = panel.frame

    -- The merchant window closes in the middle.
    ui.fire(panel.buyAllBtn, "OnClick")
    env.closeMerchant()
    T.eq("closed mid-way: report says what arrived and why it stopped", env.printed,
        "Nothing bought. Stopped: the merchant window closed. Skipped Salt (limited stock).")
    T.check("closed mid-way: nothing more is bought", #m.bought == 1 and not panel.runner:IsRunning())

    -- Not enough money.
    m.money = 150
    m.bought = {}
    env.openMerchant()
    ui.fire(panel.buyAllBtn, "OnClick")
    T.eq("no money: nothing bought", #m.bought, 0)
    T.check("no money: says so", env.printed:find("Stopped: not enough money", 1, true) ~= nil, env.printed)
    T.check("no money: the report shows in the panel", env.rowTexts()[#env.rowTexts()]:find("not enough money", 1, true) ~= nil)
    m.money = 1000000

    -- Combat hides the panel; it comes back while the merchant is still open.
    ui.event("PLAYER_REGEN_DISABLED")
    ui.combat = true
    T.check("combat: hidden", not frame.shown)
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("combat over, merchant open: shown again", frame.shown)
    ui.event("PLAYER_REGEN_DISABLED")
    ui.combat = true
    env.closeMerchant()
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("combat over, merchant gone: stays hidden", not frame.shown)

    -- A vendor price that is new drops the cached price and asks for a new path.
    env.addon.PriceManager.cache[THREAD] = { price = 999, source = "TSM" }
    m.items[2].price = 120
    env.open = true
    env.openMerchant()
    T.check("a new vendor price drops the cached one", env.addon.PriceManager.cache[THREAD] == nil)
    T.eq("and plans the open profession again", env.scheduled, "vendor price seen")
    T.eq("the new price is remembered", env.addon.VendorMemory:Get(THREAD), 120)
end)

T.section("diag merchant", function()
    local env = setup()
    local addon = env.addon
    env.window:Update(W.path())
    env.openMerchant()
    -- The slash command's function lives in Core/Init.lua.
    _G.LibStub = function() return { NewAddon = function(_, a) return a end } end
    _G.GetBuildInfo = function() return "1.60.1", "70938", "", 16001 end
    _G.strlower = string.lower
    assert(loadfile("Core/Init.lua"))("LazyProf", addon)
    local shown
    addon.ShowDiagnosticOutput = function(_, text) shown = text end
    addon.Print = function() end
    addon:SlashCommand("diag merchant")
    T.check("the dump opens in the copyable window", type(shown) == "string")
    T.check("build line", shown:find("diag merchant: build=1.60.1 (70938) interface=16001 family=forever", 1, true) ~= nil, shown)
    T.check("adapter lines included", shown:find("adapter items=4", 1, true) ~= nil)
    T.check("remembered prices counted", shown:find("remembered vendor prices: 2", 1, true) ~= nil, shown)
    T.check("purchase mode shown", shown:find("onePerClick=false", 1, true) ~= nil)
    T.check("what would be bought", shown:find("buy: 45x Thread (id 201) for 45s", 1, true) ~= nil, shown)
    T.check("what is skipped and why", shown:find("skip: Salt (id 203): limited stock", 1, true) ~= nil, shown)
    T.check("the list is named", shown:find("shopping list: Tailoring 75-150", 1, true) ~= nil, shown)

    env.closeMerchant()
    addon:SlashCommand("diag merchant")
    T.check("no merchant open: says so, still dumps", shown:find("no merchant window is open", 1, true) ~= nil)
    local printed = {}
    addon.Print = function(_, msg) printed[#printed + 1] = msg end
    addon:SlashCommand("diag")
    T.check("/lp diag lists the merchant dump", table.concat(printed, "\n"):find("/lp diag merchant", 1, true) ~= nil)
end)

T.section("diag trainer", function()
    local env = setup()
    local addon = env.addon
    _G.CraftLib = { GetActiveProfile = function() return "FOREVER" end }
    _G.GetServerTime = function() return 1 end
    addon.Professions.registry = { tailoring = { name = "Tailoring", recipes = { W.GLOVES, W.SHIRT } } }
    local open = true
    addon.Client.StartTrainer = function() end
    addon.Client.TrainerInfo = function()
        if not open then return nil end
        return { name = "Georgio Bolero", npcId = 1346, zone = "Stormwind City", mapId = 84, x = 0.53, y = 0.81, faction = "Alliance" }
    end
    addon.Client.TrainerServices = function()
        return open and { { name = "Gloves", cost = 50, state = "available" }, { name = "Shirt", cost = 300, state = "available" } } or {}
    end
    addon.Client.RunTrainerDiagnostic = function(_, lines) lines[#lines + 1] = "trainer: open=" .. tostring(open) end

    _G.LibStub = function() return { NewAddon = function(_, a) return a end } end
    _G.GetBuildInfo = function() return "1.60.1", "70938", "", 16001 end
    _G.strlower = string.lower
    assert(loadfile("Core/Init.lua"))("LazyProf", addon)
    local shown
    addon.ShowDiagnosticOutput = function(_, text) shown = text end
    addon.Print = function() end
    addon:SlashCommand("diag trainer")
    T.check("the dump opens in the copyable window", type(shown) == "string")
    T.check("build line", shown:find("diag trainer: build=1.60.1 (70938) interface=16001 family=forever", 1, true) ~= nil, shown)
    T.check("adapter lines included", shown:find("trainer: open=true", 1, true) ~= nil)
    T.check("the visit is matched to its profession", shown:find("this trainer: profession=tailoring services=2", 1, true) ~= nil, shown)
    T.check("the remembered trainer is listed", shown:find(
        "known tailoring trainer: Georgio Bolero - Stormwind City (53, 81) mapId=84 faction=Alliance recipesListed=2", 1, true) ~= nil, shown)
    T.eq("running the dump at a trainer records the visit", addon.TrainerMemory:Fee(1), 50)

    open = false
    addon:SlashCommand("diag trainer")
    T.check("no trainer open: counts only", shown:find("remembered: professions=1 trainers=1 fees=2", 1, true) ~= nil
        and shown:find("this trainer:", 1, true) == nil, shown)
    local printed = {}
    addon.Print = function(_, msg) printed[#printed + 1] = msg end
    addon:SlashCommand("diag")
    T.check("/lp diag lists the trainer dump", table.concat(printed, "\n"):find("/lp diag trainer", 1, true) ~= nil)
    _G.CraftLib = nil
end)

T.finish()
