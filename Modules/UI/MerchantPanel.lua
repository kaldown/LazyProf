-- Modules/UI/MerchantPanel.lua
-- A small panel beside the merchant window. When the open merchant sells
-- reagents that are on the shopping list, it lists them (name, how many to
-- buy, cost) with a Buy button each and "Buy all - total"; afterwards it says
-- in one line what was bought and what was skipped and why.
--
-- The list is the shopping list of the path the LazyProf window showed last
-- (the whole path's), worked out again from the current stock. What to buy
-- and the buying itself are pure code (Modules/Shopping/PurchaseQueue.lua);
-- the merchant is reached only through the client adapter. Merchant visits
-- also teach LazyProf vendor prices (Modules/Shopping/VendorMemory.lua).
--
-- Not bought automatically, and listed with the reason instead: limited-stock
-- items and items not sold for gold. There is no confirmation: the amount is
-- on the button.
local ADDON_NAME, LazyProf = ...

local MerchantPanel = {}
LazyProf.MerchantPanel = MerchantPanel

local WIDTH = 300
local ROW_HEIGHT = 20
local CHROME_HEIGHT = 74    -- title, Buy all button, margins
local MAX_ROWS = 10

MerchantPanel.frame = nil
MerchantPanel.plan = nil
MerchantPanel.report = nil
MerchantPanel.runner = nil

function MerchantPanel:Initialize()
    local Client = LazyProf.Client
    self.runner = LazyProf.PurchaseQueue.NewRunner({
        items = function() return Client:MerchantItems() end,
        isOpen = function() return Client:IsMerchantOpen() end,
        money = function() return Client:Money() end,
        freeSlots = function() return Client:FreeBagSlots() end,
        count = function(itemId) return LazyProf.Inventory:ScanBags()[itemId] or 0 end,
        buy = function(index, quantity) Client:BuyFromMerchant(index, quantity) end,
        after = function(seconds, fn) C_Timer.After(seconds, fn) end,
    })
    Client:StartMerchant({
        onShow = function() self:OnMerchantShow() end,
        onUpdate = function() self:OnInventoryChanged() end,
        onClose = function() self:OnMerchantClose() end,
    })
end

function MerchantPanel:Build()
    if self.frame then return end
    local Widgets, PanelShell = LazyProf.Widgets, LazyProf.PanelShell
    local frame = CreateFrame("Frame", "LazyProfMerchantPanel", UIParent, "BackdropTemplate")
    self.frame = frame
    frame:SetSize(WIDTH, CHROME_HEIGHT + ROW_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    frame.titleBg = frame:CreateTexture(nil, "ARTWORK")
    frame.titleBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.titleBg:SetVertexColor(0.2, 0.2, 0.2, 1)
    frame.titleBg:SetPoint("TOPLEFT", 4, -4)
    frame.titleBg:SetPoint("TOPRIGHT", -4, -4)
    frame.titleBg:SetHeight(22)
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 12, -9)
    frame.title:SetText("LazyProf: on your list")
    frame.title:SetTextColor(1, 0.82, 0)
    PanelShell:ApplyChrome(frame, { bg = { 0.1, 0.1, 0.1, 0.95 }, border = { 0.6, 0.6, 0.6, 1 } })

    local body = CreateFrame("Frame", nil, frame)
    self.body = body
    body:SetAllPoints(frame)
    PanelShell:RaiseControl(frame, body)

    frame.closeBtn = CreateFrame("Button", nil, body, "UIPanelCloseButton")
    frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    frame.closeBtn:SetSize(20, 20)
    -- Stays closed until the next merchant visit
    frame.closeBtn:SetScript("OnClick", function() PanelShell:Close(frame) end)

    self.list = Widgets.CreateRowList(body, "LazyProfMerchantList")
    self.list.frame:SetPoint("TOPLEFT", 10, -32)
    self.list.frame:SetPoint("BOTTOMRIGHT", -30, 38)
    self.list:SetWidth(WIDTH - 44)

    self.buyAllBtn = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    self.buyAllBtn:SetSize(WIDTH - 24, 22)
    self.buyAllBtn:SetPoint("BOTTOM", 0, 10)
    self.buyAllBtn:SetScript("OnClick", function() self:Buy(self.plan and self.plan.entries) end)

    PanelShell:Attach(frame, "merchant", {
        anchor = function()
            local anchor = LazyProf.Client:MerchantAnchorFrame()
            if anchor then
                return anchor, "TOPLEFT", "TOPRIGHT", 10, 0
            end
        end,
        owner = function() return self:HasContent() and LazyProf.Client:IsMerchantOpen() end,
    })
end

-- Something to show: reagents to buy, skipped ones, or a report.
function MerchantPanel:HasContent()
    local plan = self.plan
    return (plan ~= nil and (#plan.entries > 0 or #plan.skipped > 0)) or self.report ~= nil
end

function MerchantPanel:OnMerchantShow()
    self.report = nil
    if self.frame then
        self.frame.userClosed = nil
    end
    self:Refresh()
end

function MerchantPanel:OnMerchantClose()
    if self.runner:IsRunning() then
        self.runner:Cancel("the merchant window closed")
    end
    self.plan = nil
    self.report = nil
    if self.frame then
        LazyProf.PanelShell:Hide(self.frame)
    end
end

-- A merchant or bag update: a purchase may have arrived; the list may have changed.
function MerchantPanel:OnInventoryChanged()
    if not LazyProf.Client:IsMerchantOpen() then return end
    if self.runner:IsRunning() then
        self.runner:OnInventoryChanged()
        return
    end
    self:ScheduleRefresh()
end

-- Bag updates come in bursts: one refresh per burst.
function MerchantPanel:ScheduleRefresh()
    if self.refreshPending then return end
    self.refreshPending = true
    C_Timer.After(0.3, function()
        self.refreshPending = false
        if LazyProf.Client:IsMerchantOpen() and not self.runner:IsRunning() then
            self:Refresh()
        end
    end)
end

-- Work out what this merchant sells of the shopping list and show it.
function MerchantPanel:Refresh()
    local Client = LazyProf.Client
    if not Client:IsMerchantOpen() then return end
    local items = Client:MerchantItems()

    -- Vendor prices seen here are remembered; a price that is new replaces
    -- whatever the last calculation used for that item.
    local changed = LazyProf.VendorMemory:Record(items)
    if #changed > 0 then
        local pm = LazyProf.PriceManager
        for _, itemId in ipairs(changed) do
            if pm and pm.cache then pm.cache[itemId] = nil end
        end
        if Client:IsOpen() then
            LazyProf:ScheduleRecalculation("vendor price seen")
        end
    end

    local rows, listName = nil, nil
    if LazyProf.GuideWindow then
        rows, listName = LazyProf.GuideWindow:MerchantRows()
    end
    self.plan = LazyProf.PurchaseQueue.Plan(rows, items)
    self.listName = listName
    if not self:HasContent() then
        if self.frame then LazyProf.PanelShell:Hide(self.frame) end
        return
    end
    self:Build()
    self:Render()
    LazyProf.PanelShell:Show(self.frame)
end

function MerchantPanel:Render()
    local Views = LazyProf.GuideViews
    local state = { busy = self.runner:IsRunning(), report = self.report }
    local rows = Views.Merchant(self.plan, state, { onBuy = function(entry) self:Buy({ entry }) end })
    self.frame.title:SetText("LazyProf: on your list" .. (self.listName and (" - " .. self.listName) or ""))
    self.list:Render(rows)
    local height = 0
    for _, row in ipairs(self.list.rows) do height = height + row:GetHeight() end
    self.frame:SetHeight(CHROME_HEIGHT + math.max(ROW_HEIGHT, math.min(height, MAX_ROWS * ROW_HEIGHT)))
    self.buyAllBtn:SetText(Views.MerchantBuyAll(self.plan, state))
    self.buyAllBtn:SetEnabled(not state.busy and #self.plan.entries > 0)
end

-- Buy entries of the plan. Called from a button's click, so the first
-- purchase goes out inside the click.
function MerchantPanel:Buy(entries)
    if not entries or #entries == 0 or self.runner:IsRunning() then return end
    local skipped = self.plan and self.plan.skipped or {}
    self.report = nil
    self.runner:Start(entries, function(result)
        self.report = LazyProf.PurchaseQueue.Report(result, skipped)
        LazyProf:Print(self.report)
        if LazyProf.Client:IsMerchantOpen() then
            self:Refresh()
        end
    end)
    if self.runner:IsRunning() and self.frame then
        self:Render()
    end
end
