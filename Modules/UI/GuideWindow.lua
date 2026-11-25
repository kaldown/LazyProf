-- Modules/UI/GuideWindow.lua
-- The LazyProf window: one framed window with two tabs, Path and Shopping,
-- under a shared header that answers how far (the target: a number box and a
-- slider from the real skill to the last cap) and what it costs (the receipt).
-- Everything else in the header - strategy, spare crafts, what crafts are
-- counted as selling for, where prices come from, the recipe search, "Hide
-- what I have" - is behind the "More options" switch.
--
-- There is one window. It has two modes:
--   live      docked beside the open profession window, showing its path
--   planning  undocked, for any profession picked from the minimap button, the
--             addon compartment or /lp browse; a profession dropdown and, with
--             More options, for a profession the character has, a "plan from
--             skill 1" what-if appear in the header; Escape closes it
-- A profession window that opens docks the window and shows that profession;
-- when it closes the window goes back to the planning view it had, or hides.
-- Planning opened while a profession window is open stays until it is closed.
--
-- The header is a stack of blocks, placed top down by Layout() from what is
-- shown, so the list starts under whatever is there:
--   strip       More options: strategy, spare crafts, selling, the price line
--   planRow     planning: the profession dropdown
--   targetRow   "Level to", the number box, the slider and its end labels
--   receipt     the receipt's lines (Views.Receipt)
--   searchRow   More options, Path tab: the recipe search
--   shopRow     More options, Shopping tab: "Hide what I have"
--
-- The path is never planned again while the slider's handle is moved: moving
-- only rewrites the number in the box, letting go commits once.
--
-- This file only places widgets and passes clicks on. What each tab shows is
-- built as plain data by Modules/Guide/Views.lua from the stages of the path
-- (Modules/Guide/Stages.lua) and drawn by Widgets/RowList.lua. Position,
-- closed state and combat hide/restore belong to Widgets/PanelShell.lua.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils
local SALE_MODE = LazyProf.Constants.SALE_MODE

local GuideWindow = {}
LazyProf.GuideWindow = GuideWindow

local DEFAULT_WIDTH = 420
local MIN_WIDTH, MAX_WIDTH = 380, 640
-- (With every block of the header shown - More options in planning - the
-- list still has room for a handful of rows at the minimum height.)
local MIN_HEIGHT, MAX_HEIGHT = 440, 900
local FALLBACK_HEIGHT = 480
local PLANNING_HEIGHT = 540

-- Header geometry. The window's content keeps MARGIN from its left and right
-- edges; the status line sits under the title and the blocks start below it.
local MARGIN = 12
local STATUS_CENTER = 38          -- the status line and the options switch share this centre line
local HEADER_TOP = 52
local MORE_WIDTH, MORE_HEIGHT = 104, 20
local STRIP_HEIGHT = 76           -- strategy row, selling row, price line
local PLAN_ROW_HEIGHT = 30
local TARGET_HEIGHT = 62          -- label and box, slider, end labels
local SLIDER_TOP = 28
local RECEIPT_PAD = 5             -- above the first and below the last line
local RECEIPT_LINE = 14           -- a line of the receipt that does not wrap
local RECEIPT_SPACING = 2
local RECEIPT_GAP = 8             -- between the label, amount and note columns
local RECEIPT_AMOUNT_WIDTH = 84   -- an amount to the copper ("888g 88s 88c")
local RECEIPT_NOTE_MIN = 60
local RECEIPT_INDENT = 10          -- a note on its own line under its label
local SEARCH_HEIGHT = 26
local SHOP_ROW_HEIGHT = 26
local LIST_GAP = 4                -- between the header and the list
-- LIST_RIGHT leaves room for the scroll bar; LIST_BOTTOM ends the list above
-- the resize grip in the corner, which would otherwise sit on the bar's
-- scroll-down button.
local LIST_LEFT, LIST_RIGHT, LIST_BOTTOM = 10, 30, 20

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }

-- Tabs in display order. key names the tab in saved data. (A tab saved by an
-- older build as "guide" or "steps" is not in the list and opens the first.)
GuideWindow.TABS = {
    { key = "path", label = "Path" },
    { key = "shopping", label = "Shopping" },
}

-- What the crafts are counted as selling for, in the order of the dropdown.
local SELLING = {
    { value = SALE_MODE.VENDOR, text = "Vendor" },
    { value = SALE_MODE.AUCTION, text = "Auction house" },
    { value = SALE_MODE.NONE, text = "Do not count" },
}

GuideWindow.frame = nil
GuideWindow.mode = nil        -- "live" | "planning"
GuideWindow.path = nil        -- the path shown (the live one, or planning's)
GuideWindow.livePath = nil    -- the open profession's path, also while planning is shown
GuideWindow.liveNotice = nil  -- its "no recipe data" text
GuideWindow.planning = nil    -- { profKey, path, notice } while a planning view exists
GuideWindow.shoppingPath = nil   -- the last path shown that is not a what-if, kept after the window closes (merchant panel)
GuideWindow.returnToPlanning = false   -- planning was set aside for a profession window
GuideWindow.dockPending = false        -- a profession window opened over planning; its path has not arrived yet
GuideWindow.profKey = nil
GuideWindow.notice = nil      -- text shown instead of a path (no recipe data)
GuideWindow.tab = "path"
GuideWindow.target = nil      -- Views.Target of the view drawn last (the slider's model)
GuideWindow.receiptLines = {} -- Views.Receipt of the view drawn last
GuideWindow.receiptRows = {}  -- the receipt's font strings: [i] = { label, amount, note }
-- What the player opened and typed, kept per profession for the session:
--   expanded     [Views.RowKey(stage)] = true (opened) | false (closed); absent:
--                only the run the player is on is open
--   showAllAlts  [Views.RowKey(stage)] = true: every alternative of the run is listed
--   search       the recipe search text
GuideWindow.states = {}       -- [profKey] = { expanded, showAllAlts, search }
GuideWindow.state = { expanded = {}, showAllAlts = {}, search = "" }   -- the shown profession's
GuideWindow.expanded = GuideWindow.state.expanded
GuideWindow.showAllAlts = GuideWindow.state.showAllAlts
GuideWindow.search = GuideWindow.state.search

function GuideWindow:Initialize()
    -- Frames are built the first time the window is shown.
end

-- State ------------------------------------------------------------------------

-- Switch to a profession's opened rows and search (a path-less view gets
-- empty ones that are not kept).
local function UseState(self, profKey)
    local state = profKey and self.states[profKey]
    if not state then
        state = { expanded = {}, showAllAlts = {}, search = "" }
        if profKey then
            self.states[profKey] = state
        end
    end
    self.state = state
    self.expanded, self.showAllAlts, self.search = state.expanded, state.showAllAlts, state.search
    if self.frame then
        self.searchBox:SetText(self.search)
    end
end

-- Take a new path. Each profession has its own opened rows and search; they
-- are kept while another one is shown.
function GuideWindow:SetPath(path)
    -- A drag of the slider whose release was not heard belongs to the path
    -- shown so far: asking ends it and commits it there, before another
    -- path (maybe another profession's) takes its place.
    if self.path and self.slider then
        self.slider:IsHeld()
    end
    local key = path and path.professionKey or nil
    if key ~= self.profKey then
        self.profKey = key
        UseState(self, key)
    end
    self.path = path
    -- The merchant panel shops for the path shown last, but never for the
    -- "Plan from skill 1" what-if: its runs below the real skill are done and
    -- the rest is not the plan the character follows.
    if path and not path.planFromOne then
        self.shoppingPath = path
    end
end

-- Margin in force (nil when off).
local function MarginPercent()
    local profile = LazyProf.db.profile
    if profile.useMargin then
        return profile.marginPercent or 15
    end
    return nil
end

-- Everything the tabs are drawn from (see Modules/Guide/Views.lua). Works
-- without the frame, so the shopping list can be computed while it is hidden.
function GuideWindow:ComputeView()
    return self:BuildView(self.path, self.mode)
end

-- The view of the open profession's path whatever the window is showing (the
-- arrow tooltip reads it). nil without a live path.
function GuideWindow:LiveView()
    local path = LazyProf.Pathfinder.currentPath
    if not path then return nil end
    return self:BuildView(path, "live", true)
end

-- plain: leave out what belongs to the window's own state (the opened rows).
function GuideWindow:BuildView(path, mode, plain)
    local view = {
        path = path, marginPercent = MarginPercent(),
        expanded = plain and {} or self.expanded,
        showAllAlts = plain and {} or self.showAllAlts,
    }
    if not path then return view end

    -- The cap the character works under: the open profession's as its window
    -- reports it, else the one the client reports for the profession; the
    -- first cap for a profession not learned yet. Unknown: no rank steps.
    local liveCap
    if path.hasProfession == false then
        liveCap = LazyProf.Stages.LiveCap(nil, path.milestones)
    elseif mode == "live" then
        local _, _, cap = LazyProf.Client:GetLine()
        liveCap = cap
    else
        local _, cap = LazyProf.Client:ProfessionRank(path.professionKey)
        liveCap = cap
    end
    view.liveCap = liveCap
    view.cap = (path.hasProfession ~= false) and liveCap or nil
    view.profile = Utils.GetActiveProfile()

    local stages, summary = LazyProf.Stages.Build(path, {
        inventory = path.inventory,
        prices = path.prices,
        marginPercent = view.marginPercent,
        pins = LazyProf.Pathfinder:GetPins(path.professionKey),
        includeLearn = true,
        liveCap = liveCap,
    })
    view.stages, view.summary = stages, summary
    view.skill = path.actualSkill
    view.hideOwned = LazyProf.CharStore:Get().hideOwned and true or false
    view.advanced = LazyProf.db.profile.showAdvanced and true or false
    -- What the stock scan says of the stock it could count (Inventory:ScanAll)
    view.stockMeta = path.stockMeta

    -- The account of the whole path: its shopping list from the stages'
    -- quantities (so the margin is in it), less what the crafts sell for,
    -- and what the owned stock saves. The receipt and the Shopping tab are
    -- both drawn from it. Sale values still waiting for item data are counted
    -- now, not when the path was built.
    local shoppingSteps = LazyProf.Stages.ShoppingSteps(stages)
    view.sale = path.sale
    view.saleLoading = LazyProf.SaleValue and LazyProf.SaleValue:LoadingCount(path.sale) or 0
    view.account = LazyProf.Pathfinder:Account(shoppingSteps, path.inventory, path.sourceBreakdown,
        path.prices, path.sale and path.sale.values)
    view.account.stockSaves = LazyProf.Pathfinder:StockSaving(shoppingSteps, path.prices, view.account.spend)
    view.missing = view.account.missing

    local pm = LazyProf.PriceManager
    if pm and pm.PathSummary then
        view.priceSummary = pm:PathSummary(path)
        view.priceLines = pm.SummaryLines(view.priceSummary)
    end

    -- The next recipe is unlearned and the profession window hides unlearned
    -- recipes, so the arrow has no row to point at: its run says so.
    if mode == "live" then
        local step = LazyProf.Pathfinder:GetArrowStep(path)
        local recipe = step and step.recipe
        if recipe and not recipe.learned and LazyProf.Client:UnlearnedHiddenByFilter() then
            view.hiddenRecipeId = recipe.id
        end
    end
    return view
end

-- For the merchant panel: the shopping rows of the path the window showed
-- last (never the "Plan from skill 1" what-if) - the whole path's list -
-- worked out from the stock as it is now.
-- Returns the rows and a name for the list (the profession); nil when no
-- path was shown this session.
function GuideWindow:MerchantRows()
    local path = self.shoppingPath
    if not path then return nil end
    path.inventory, path.sourceBreakdown, path.stockMeta = LazyProf.Inventory:ScanAll()
    local view = self:BuildView(path, path.planning and "planning" or "closed", true)
    return view.missing and view.missing.rows or {}, tostring(path.profession)
end

-- Should the window be showing right now? (Asked by the panel shell when
-- combat ends.)
function GuideWindow:WantsShown()
    if self.mode == "live" then
        return LazyProf.Client:IsOpen() and (self.path ~= nil or self.notice ~= nil)
    elseif self.mode == "planning" then
        return self.planning ~= nil
    end
    return false
end

-- Planning is on screen, or will be again once combat ends.
function GuideWindow:IsPlanningShown()
    local frame = self.frame
    if not (frame and self.mode == "planning" and self.planning) then return false end
    return frame:IsShown() or frame._wasShownBeforeCombat == true
end

-- The path planning shows (nil when there is no planning view).
function GuideWindow:PlanningPath()
    return self.planning and self.planning.path or nil
end

-- Frames -----------------------------------------------------------------------

local function TabIndex(key)
    for i, tab in ipairs(GuideWindow.TABS) do
        if tab.key == key then return i end
    end
    return 1
end

local function SellingText(mode)
    for _, option in ipairs(SELLING) do
        if option.value == mode then return option.text end
    end
    return SELLING[1].text
end

-- A block of the header: a frame as wide as the window that Layout() places.
local function Block(body, height)
    local block = CreateFrame("Frame", nil, body)
    block:SetHeight(height)
    block:Hide()
    return block
end

function GuideWindow:Build()
    if self.frame then return end
    local Widgets, PanelShell = LazyProf.Widgets, LazyProf.PanelShell

    local frame = CreateFrame("Frame", "LazyProfGuideWindow", UIParent, "BackdropTemplate")
    self.frame = frame
    frame:SetSize(DEFAULT_WIDTH, FALLBACK_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetClampedToScreen(true)
    Widgets.SetResizeBounds(frame, MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
    frame:Hide()

    -- Title bar strip (Classic chrome; hidden by the native frame on Forever)
    frame.titleBg = frame:CreateTexture(nil, "ARTWORK")
    frame.titleBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.titleBg:SetVertexColor(0.2, 0.2, 0.2, 1)
    frame.titleBg:SetPoint("TOPLEFT", 4, -4)
    frame.titleBg:SetPoint("TOPRIGHT", -4, -4)
    frame.titleBg:SetHeight(22)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 12, -9)
    frame.title:SetJustifyH("LEFT")
    frame.title:SetText("LazyProf")
    frame.title:SetTextColor(1, 0.82, 0)

    PanelShell:ApplyChrome(frame, { bg = { 0.1, 0.1, 0.1, 0.95 }, border = { 0.6, 0.6, 0.6, 1 } })

    -- Everything else sits on a host frame above the border art (the native
    -- border is a child frame and would otherwise draw over the controls).
    local body = CreateFrame("Frame", nil, frame)
    self.body = body
    body:SetAllPoints(frame)
    PanelShell:RaiseControl(frame, body)

    frame.closeBtn = CreateFrame("Button", nil, body, "UIPanelCloseButton")
    frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    frame.closeBtn:SetSize(20, 20)
    -- Docked: stays closed until the profession window is opened again.
    -- Planning: closes the planning view.
    frame.closeBtn:SetScript("OnClick", function()
        if self.mode == "planning" then
            self:ClosePlanning()
        else
            PanelShell:Close(frame)
        end
    end)
    frame:HookScript("OnHide", function(f)
        -- A drag of the slider cut short by the window going away (combat,
        -- closing) leaves no trace: the handle and the box go back to the
        -- target the path was planned for.
        self:ShowTarget()
        -- Escape (planning only, see SetEscapeCloses) hides the frame
        -- directly: treat it as closing planning. Not when combat or this
        -- file hid it, and not when the frame is merely out of sight because
        -- the whole interface is hidden (it is then still "shown").
        if self.mode == "planning" and not self.hidingSelf and not f._wasShownBeforeCombat and not f:IsShown() then
            self:ClosePlanning()
        end
    end)
    -- Shown (again): wrapped lines are measured once more on a frame that is
    -- on screen, and the list follows. The handle and the box show the
    -- planned target, whatever a drag left there when the window went away.
    -- A redraw asked for while it was hidden is done now, in full.
    frame:HookScript("OnShow", function()
        if self.needsRender then
            self.needsRender = nil
            self:Render()
        elseif self.view then
            self:ShowTarget()
            self:Layout()
            self:RenderTab()
        end
    end)

    -- Status line: skill and cap on the left, the options switch on the right
    self.moreBtn = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    self.moreBtn:SetSize(MORE_WIDTH, MORE_HEIGHT)
    self.moreBtn:SetPoint("RIGHT", body, "TOPRIGHT", -MARGIN, -STATUS_CENTER)
    self.moreBtn:SetNormalFontObject(_G.GameFontNormalSmall or "GameFontNormalSmall")
    self.moreBtn:SetHighlightFontObject(_G.GameFontHighlightSmall or "GameFontHighlightSmall")
    self.moreBtn:SetText("More options")
    self.moreBtn:SetScript("OnClick", function() self:OnMoreOptions() end)

    -- (Bounded by the switch, so a long status is cut short, never drawn
    -- over it.)
    self.status = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.status:SetPoint("LEFT", body, "TOPLEFT", MARGIN, -STATUS_CENTER)
    self.status:SetPoint("RIGHT", self.moreBtn, "LEFT", -8, 0)
    self.status:SetJustifyH("LEFT")
    self.status:SetWordWrap(false)

    -- More options: strategy and spare crafts, selling, where prices come from
    local strip = Block(body, STRIP_HEIGHT)
    self.strip = strip
    self.strategyGroup = Widgets.CreateButtonGroup(strip, {
        { text = "Cheapest", value = "cheapest", width = 72, tooltip = "The path that costs the least gold." },
        { text = "Fastest", value = "fastest", width = 66,
          tooltip = "The path with the fewest crafts. It can cost much more than Cheapest." },
    }, function(value) self:OnStrategy(value) end)
    self.strategyGroup:SetPoint("TOPLEFT", strip, "TOPLEFT", MARGIN, -1)

    self.marginBox = Widgets.CreateCheckbox(strip, "LazyProfGuideMargin", "Spare crafts", function(checked)
        self:OnMargin(checked)
    end, "Plan extra crafts and reagents for bad luck with skill-ups. The percentage is set in the options.")
    self.marginBox:SetPoint("LEFT", self.strategyGroup.frame, "RIGHT", 8, 0)

    self.sellingLabel = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.sellingLabel:SetPoint("TOPLEFT", MARGIN, -34)
    self.sellingLabel:SetText("Selling")
    self.sellingDropdown = Widgets.CreateDropdown(strip, "LazyProfGuideSelling", 110)
    self.sellingDropdown:SetPoint("TOPLEFT", strip, "TOPLEFT", 40, -25)
    self.sellingDropdown:SetOptions(function()
        local mode = LazyProf.db.profile.saleValueMode
        local options = {}
        for i, option in ipairs(SELLING) do
            options[i] = { text = option.text, value = option.value, checked = (option.value == mode) }
        end
        return options
    end, function(value)
        self:OnSelling(value)
    end)

    -- Planning only: the "from skill 1" what-if
    self.fromOneBox = Widgets.CreateCheckbox(strip, "LazyProfGuideFromOne", "Plan from skill 1", function(checked)
        self:OnPlanFromOne(checked)
    end, "Show the whole path from skill 1 as a what-if. The target still starts at your real skill.")
    self.fromOneBox:SetPoint("LEFT", self.sellingDropdown.frame, "RIGHT", -8, 0)

    self.pricesBtn = CreateFrame("Button", nil, strip)
    self.pricesBtn:SetHeight(14)
    self.pricesBtn:SetPoint("TOPLEFT", MARGIN, -58)
    self.pricesBtn:SetPoint("TOPRIGHT", -MARGIN, -58)
    self.prices = self.pricesBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.prices:SetPoint("LEFT", 0, 0)
    self.prices:SetPoint("RIGHT", 0, 0)
    self.prices:SetJustifyH("LEFT")
    self.prices:SetWordWrap(false)
    self.pricesBtn:SetScript("OnEnter", function(btn)
        local lines = self.view and self.view.priceLines or {}
        if #lines == 0 then return end
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
        for _, line in ipairs(lines) do
            GameTooltip:AddLine(line.text, line.r, line.g, line.b, true)
        end
        GameTooltip:Show()
    end)
    self.pricesBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Planning only: which profession
    local planRow = Block(body, PLAN_ROW_HEIGHT)
    self.planRow = planRow
    self.professionLabel = planRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.professionLabel:SetPoint("LEFT", MARGIN, 0)
    self.professionLabel:SetText("Profession")
    self.professionDropdown = Widgets.CreateDropdown(planRow, "LazyProfGuideProfession", 110)
    self.professionDropdown:SetPoint("LEFT", planRow, "LEFT", 58, 0)
    self.professionDropdown:SetOptions(function()
        return self:ProfessionOptions()
    end, function(profKey)
        self:OpenPlanning(profKey)
    end)

    -- The target: "Level to", a number box, and a slider from the real skill
    -- to the last cap with its ends named underneath
    local targetRow = Block(body, TARGET_HEIGHT)
    self.targetRow = targetRow
    self.targetLabel = targetRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.targetLabel:SetPoint("TOPLEFT", MARGIN, -8)
    self.targetLabel:SetText("Level to")

    self.targetInput = Widgets.CreateNumericInput(targetRow, "LazyProfGuideTarget", 40, 3, function(value)
        -- A drag of the slider that ended unnoticed came first: asking ends
        -- it and commits it before the typed target, which then wins.
        self.slider:IsHeld()
        local target = self:OnTargetCommit(value)
        if target then
            self.slider:SetValue(target)
        end
        return target
    end)
    self.targetInput:SetPoint("LEFT", self.targetLabel, "RIGHT", 12, 0)

    self.slider = Widgets.CreateSlider(targetRow, "LazyProfGuideSlider", {
        -- Moving the handle only rewrites the number in the box...
        onChanging = function(value)
            self.targetInput:SetValue(value)
        end,
        -- ...letting it go stores the target and plans again, once.
        onReleased = function(value)
            self:OnSliderReleased(value)
        end,
    })
    self.slider:SetPoint("TOPLEFT", targetRow, "TOPLEFT", MARGIN + 2, -SLIDER_TOP)
    self.slider:SetPoint("TOPRIGHT", targetRow, "TOPRIGHT", -(MARGIN + 2), -SLIDER_TOP)
    self.sliderMin = targetRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.sliderMin:SetPoint("TOPLEFT", self.slider.frame, "BOTTOMLEFT", 0, -1)
    self.sliderMax = targetRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.sliderMax:SetPoint("TOPRIGHT", self.slider.frame, "BOTTOMRIGHT", 0, -1)

    -- The receipt: its lines are made as they are needed
    local receipt = Block(body, 2 * RECEIPT_PAD + RECEIPT_LINE)
    self.receipt = receipt
    self.receiptRows = {}
    receipt.bg = receipt:CreateTexture(nil, "BACKGROUND")
    receipt.bg:SetColorTexture(0, 0, 0, 0.25)
    receipt.bg:SetPoint("TOPLEFT", MARGIN - 6, 0)
    receipt.bg:SetPoint("BOTTOMRIGHT", -(MARGIN - 6), 0)

    -- Path tab, More options: recipe search above the list
    local searchRow = Block(body, SEARCH_HEIGHT)
    self.searchRow = searchRow
    self.searchBox = Widgets.CreateSearchBox(searchRow, "LazyProfGuideSearch", "Search recipes...", function(text)
        self:OnSearch(text)
    end)
    self.searchBox.frame:SetPoint("TOPLEFT", 16, -4)
    self.searchBox.frame:SetPoint("TOPRIGHT", -LIST_RIGHT, -4)
    self.searchBox:SetText(self.search)

    -- Shopping tab, More options: "Hide what I have" above the list
    local shopRow = Block(body, SHOP_ROW_HEIGHT)
    self.shopRow = shopRow
    self.hideOwnedBox = Widgets.CreateCheckbox(shopRow, "LazyProfGuideHideOwned", "Hide what I have", function(checked)
        LazyProf.CharStore:Get().hideOwned = checked or nil
        self:Render()
    end, "Show only the reagents you still have to buy or craft.")
    self.hideOwnedBox:SetPoint("LEFT", shopRow, "LEFT", MARGIN - 4, 0)

    -- The tab's list
    self.list = Widgets.CreateRowList(body, "LazyProfGuideList")

    -- Sizing re-anchors the frame, so its spot is saved with its size; the
    -- header is laid out for the new width, so everything is drawn again.
    self.resizeGrip = Widgets.CreateResizeGrip(frame, function()
        PanelShell:SaveSize(frame)
        PanelShell:SavePosition(frame)
        self:Render()
    end)
    self.resizeGrip:SetParent(body)

    -- Tabs hang under the window
    local labels = {}
    for i, tab in ipairs(self.TABS) do labels[i] = tab.label end
    self.tabs = Widgets.CreateTabs(frame, labels, function(index)
        self:SelectTab(self.TABS[index].key, true)
    end)

    -- Docked and undocked keep a saved spot and size each.
    PanelShell:Attach(frame, function()
        return self.mode == "planning" and "guidePlanning" or "guide"
    end, {
        anchor = function()
            if self.mode == "planning" then
                return UIParent, "CENTER", "CENTER", 0, 0
            end
            local anchor = LazyProf.Client:AnchorFrame()
            if anchor then
                return anchor, "TOPLEFT", "TOPRIGHT", LazyProf.Client:PanelOffsetX(), 0
            end
        end,
        owner = function() return self:WantsShown() end,
        onReset = function()
            self.sized = nil
            if frame:IsShown() then
                self:ApplySize()
                self:Render()
            end
        end,
    })

    -- Open on the tab this character used last
    self:SelectTab(LazyProf.CharStore:Get().lastTab or self.tab)
end

-- Default size: docked, as tall as the profession window, within sensible
-- limits; undocked, a fixed height. The size the player dragged it to wins,
-- raised to the minimum if it was saved when the window could be smaller.
function GuideWindow:ApplySize()
    local height = PLANNING_HEIGHT
    if self.mode ~= "planning" then
        local anchor = LazyProf.Client:AnchorFrame()
        height = anchor and anchor.GetHeight and anchor:GetHeight() or 0
        if not height or height <= 0 then height = FALLBACK_HEIGHT end
        height = math.max(MIN_HEIGHT, math.min(700, height))
    end
    LazyProf.PanelShell:ApplySize(self.frame, DEFAULT_WIDTH, height, MIN_WIDTH, MIN_HEIGHT)
    self.sized = self.mode
    self:Layout()
end

-- Escape closes the window only while it is undocked: docked it follows the
-- profession window. (UISpecialFrames is the client's list of frame names
-- that Escape hides.)
function GuideWindow:SetEscapeCloses(on)
    local name = self.frame:GetName()
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == name then
            if on then return end
            tremove(UISpecialFrames, i)
        end
    end
    if on then
        tinsert(UISpecialFrames, name)
    end
end

-- Professions that can be planned (those with recipe data), by name.
function GuideWindow:ProfessionOptions()
    local options = {}
    for key, info in pairs(LazyProf.Constants.PROFESSIONS) do
        if LazyProf.Professions:Get(key) then
            options[#options + 1] = { text = info.name, value = key, checked = (key == self.profKey) }
        end
    end
    table.sort(options, function(a, b) return a.text < b.text end)
    return options
end

-- One line of the receipt: its three font strings, made the first time a
-- receipt has that many lines.
local function ReceiptRow(self, index)
    local row = self.receiptRows[index]
    if not row then
        local receipt = self.receipt
        row = {
            label = receipt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
            amount = receipt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
            note = receipt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
        }
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.amount:SetJustifyH("RIGHT")
        row.amount:SetWordWrap(false)
        row.note:SetJustifyH("LEFT")
        row.note:SetJustifyV("TOP")
        row.note:SetWordWrap(true)
        self.receiptRows[index] = row
    end
    return row
end

local function SetColor(region, color)
    region:SetTextColor(color[1], color[2], color[3])
end

-- Put a view's receipt (Views.Receipt) into the font strings. LayoutReceipt
-- places them.
function GuideWindow:FillReceipt(lines)
    self.receiptLines = lines
    for i, line in ipairs(lines) do
        local row = ReceiptRow(self, i)
        if line.amount then
            row.label:SetText(line.label or "")
            SetColor(row.label, line.key == "net" and GOLD or WHITE)
            row.amount:SetText(line.amount)
            SetColor(row.amount, line.amountColor or WHITE)
            row.label:Show()
            row.amount:Show()
        else
            row.label:Hide()
            row.amount:Hide()
        end
        row.note:SetText(line.note or "")
        SetColor(row.note, line.color or WHITE)
        row.note:SetShown(line.note ~= nil)
    end
    for i = #lines + 1, #self.receiptRows do
        local row = self.receiptRows[i]
        row.label:Hide()
        row.amount:Hide()
        row.note:Hide()
    end
end

-- The width a font string's text takes on one line, whatever width the
-- string was given (WoW Forever: GetUnboundedStringWidth,
-- SimpleFontStringAPIDocumentation.lua:398; a client without it gives
-- GetStringWidth).
local function OneLineWidth(fontString)
    if fontString.GetUnboundedStringWidth then
        return fontString:GetUnboundedStringWidth() or 0
    end
    return fontString:GetStringWidth() or 0
end

-- Place the receipt's lines for a window `width` wide and return the height
-- they take. Three columns: the labels, as wide as the widest of them; the
-- amounts, right-aligned, wide enough for an amount to the copper; the notes
-- in what is left. A note longer than that room would break inside an
-- amount, so it goes whole on its own line under its label, a little in, and
-- wraps only if the window is too narrow even for that. A line that is only
-- a note spans the window and wraps. Nothing is cut.
-- (Text is measured with the font string's own GetStringWidth and, once a
-- width is set and wrapping is on, GetStringHeight: WoW Forever,
-- Blizzard_APIDocumentationGenerated/SimpleFontStringAPIDocumentation.lua:339,
-- 325, SetWordWrap :720. The row list measures its wrapped rows the same way.)
function GuideWindow:LayoutReceipt(width)
    local lines, receipt = self.receiptLines, self.receipt
    local labelWidth, amountWidth = 0, RECEIPT_AMOUNT_WIDTH
    for i, line in ipairs(lines) do
        if line.amount then
            local row = self.receiptRows[i]
            labelWidth = math.max(labelWidth, row.label:GetStringWidth() or 0)
            amountWidth = math.max(amountWidth, row.amount:GetStringWidth() or 0)
        end
    end
    local amountRight = MARGIN + labelWidth + RECEIPT_GAP + amountWidth
    local noteLeft = amountRight + RECEIPT_GAP
    local noteWidth = math.max(RECEIPT_NOTE_MIN, width - MARGIN - noteLeft)
    local fullWidth = math.max(RECEIPT_NOTE_MIN, width - 2 * MARGIN)

    local y = RECEIPT_PAD
    for i, line in ipairs(lines) do
        local row = self.receiptRows[i]
        local note = row.note
        note:ClearAllPoints()
        local noteTop = y
        if line.amount then
            row.label:ClearAllPoints()
            row.label:SetPoint("TOPLEFT", receipt, "TOPLEFT", MARGIN, -y)
            row.amount:ClearAllPoints()
            row.amount:SetPoint("TOPRIGHT", receipt, "TOPLEFT", amountRight, -y)
            if line.note and OneLineWidth(note) > noteWidth then
                noteTop = y + RECEIPT_LINE + RECEIPT_SPACING
                note:SetWidth(math.max(RECEIPT_NOTE_MIN, fullWidth - RECEIPT_INDENT))
                note:SetPoint("TOPLEFT", receipt, "TOPLEFT", MARGIN + RECEIPT_INDENT, -noteTop)
            else
                note:SetWidth(noteWidth)
                note:SetPoint("TOPLEFT", receipt, "TOPLEFT", noteLeft, -y)
            end
        else
            note:SetWidth(fullWidth)
            note:SetPoint("TOPLEFT", receipt, "TOPLEFT", MARGIN, -y)
        end
        local height = RECEIPT_LINE
        if line.note then
            height = math.max(height, note:GetStringHeight() or 0)
        end
        y = noteTop + height + RECEIPT_SPACING
    end
    return y - RECEIPT_SPACING + RECEIPT_PAD
end

-- Stack the header's blocks from what is shown and give the list the rest.
function GuideWindow:Layout()
    local frame, body = self.frame, self.body
    local width = frame:GetWidth()
    local path = self.path
    local advanced = path ~= nil and LazyProf.db.profile.showAdvanced and true or false
    local y = HEADER_TOP

    local function place(block, shown, height)
        if not shown then
            block:Hide()
            return
        end
        block:ClearAllPoints()
        block:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
        block:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
        if height then block:SetHeight(height) end
        block:Show()
        y = y + block:GetHeight()
    end

    self.moreBtn:SetShown(path ~= nil)
    place(self.strip, advanced)
    place(self.planRow, self.mode == "planning")
    place(self.targetRow, path ~= nil and self.target ~= nil)
    local hasReceipt = path ~= nil and #self.receiptLines > 0
    place(self.receipt, hasReceipt, hasReceipt and self:LayoutReceipt(width) or nil)
    place(self.searchRow, advanced and self.tab == "path")
    place(self.shopRow, advanced and self.tab == "shopping")

    self.list.frame:ClearAllPoints()
    self.list.frame:SetPoint("TOPLEFT", body, "TOPLEFT", LIST_LEFT, -(y + LIST_GAP))
    self.list.frame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -LIST_RIGHT, LIST_BOTTOM)
    self.list:SetWidth(math.max(100, width - LIST_LEFT - LIST_RIGHT - 4))
end

-- Showing and hiding -------------------------------------------------------------

-- Bring the built window in line with the mode it is in: Escape, size, layout.
function GuideWindow:ApplyMode()
    self:SetEscapeCloses(self.mode == "planning")
    if self.sized ~= self.mode then
        self:ApplySize()
    end
end

-- Show the open profession's path (or its "no data" notice), docked.
function GuideWindow:DisplayLive()
    self.mode = "live"
    self:SetPath(self.livePath)
    self.notice = self.liveNotice
    if not LazyProf.db.profile.openWithProfession then
        self:Hide()
        return
    end
    self:Build()
    self.frame.showsNotice = (self.notice ~= nil) or nil
    self:ApplyMode()
    self:Render()
    LazyProf.PanelShell:Show(self.frame)
end

-- Planning is shown and no profession window has just opened over it: what
-- the open profession has to show is kept, not shown. When one has just
-- opened (dockPending), planning is set aside now that there is something to
-- dock with.
local function PlanningKeepsTheWindow(self)
    if self.mode ~= "planning" then return false end
    if not self.dockPending then return true end
    self.dockPending = false
    self.returnToPlanning = true
    return false
end

-- A live path arrived (the profession window is open). While planning is
-- shown it is only kept: planning stays until the player closes it.
function GuideWindow:Update(path)
    self.livePath, self.liveNotice = path, nil
    if PlanningKeepsTheWindow(self) then return end
    self:DisplayLive()
end

-- The open profession has no recipe data: say so instead of showing a path.
function GuideWindow:ShowNotice(text)
    self.livePath, self.liveNotice = nil, text
    if PlanningKeepsTheWindow(self) then return end
    self:DisplayLive()
end

-- There is no path for the open profession (and no notice): the live view
-- goes; a planning view is not touched.
function GuideWindow:HideLive()
    self.livePath, self.liveNotice = nil, nil
    if self.mode == "planning" then return end
    self:SetPath(nil)
    self.notice = nil
    self:Hide()
end

function GuideWindow:Hide()
    if not self.frame then return end
    self.frame.showsNotice = nil
    self.hidingSelf = true
    LazyProf.PanelShell:Hide(self.frame)
    self.hidingSelf = nil
end

function GuideWindow:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

-- A profession window opened: the window docks and shows that profession
-- as soon as its path (or its "no data" notice) arrives through Update /
-- ShowNotice. A planning view is set aside then and comes back when the
-- profession window closes. Until then planning stays as it is.
function GuideWindow:OnProfessionOpened()
    if self.mode == "planning" and self.planning and LazyProf.db.profile.openWithProfession then
        self.dockPending = true
    end
end

-- The profession window closed: back to the planning view that was set
-- aside, else hide. Planning opened on top of the profession window stays.
function GuideWindow:OnProfessionClosed()
    self.livePath, self.liveNotice = nil, nil
    self.dockPending = false
    if self.mode == "planning" then return end
    if self.returnToPlanning and self.planning then
        self.returnToPlanning = false
        -- Closing the docked window (its close button) does not close the
        -- planning view that was set aside.
        if self.frame then self.frame.userClosed = nil end
        self:DisplayPlanning()
        return
    end
    self:SetPath(nil)
    self.notice = nil
    self:Hide()
end

-- Planning ---------------------------------------------------------------------

-- Open the window undocked on a profession (minimap button, addon
-- compartment, /lp browse, or the header's profession dropdown).
function GuideWindow:OpenPlanning(profKey)
    if InCombatLockdown() then return end
    self:Build()
    -- Opening planning is a user action: panels closed earlier may show again.
    self.frame.userClosed = nil
    LazyProf.PanelShell:ResetClosedForPlanning()
    self.returnToPlanning = false
    self.dockPending = false
    self.mode = "planning"
    self:LoadPlanning(profKey, "planning opened")
end

-- Calculate the planning path of a profession and show it.
function GuideWindow:LoadPlanning(profKey, reason)
    local planFromOne = LazyProf.CharStore:Get().planFromOne
    local path = LazyProf.Pathfinder:CalculateForProfession(profKey, {
        planFromOne = planFromOne and planFromOne[profKey] or false,
        reason = reason,
    })
    local info = LazyProf.Constants.PROFESSIONS[profKey]
    self.planning = {
        profKey = profKey,
        path = path,
        notice = (not path) and ("No recipe data for " .. (info and info.name or tostring(profKey)) .. " yet.") or nil,
    }
    if self.mode == "planning" then
        self:DisplayPlanning()
    end
end

function GuideWindow:DisplayPlanning()
    local planning = self.planning
    if not planning then return end
    self.mode = "planning"
    self:Build()
    self:SetPath(planning.path)
    self.profKey = planning.profKey
    self.notice = planning.notice
    self.frame.showsNotice = (self.notice ~= nil) or nil
    self:ApplyMode()
    self:Render()
    LazyProf.PanelShell:Show(self.frame)
end

-- Plan the shown profession again (a setting changed, a recipe was learned).
function GuideWindow:RefreshPlanning(reason)
    if not self.planning then return end
    self:LoadPlanning(self.planning.profKey, reason)
end

-- Close the planning view (its close button, or Escape). With a profession
-- window open the window goes back to being that window's, closed until it is
-- opened again.
function GuideWindow:ClosePlanning()
    if not self.frame then return end
    self.planning = nil
    self.returnToPlanning = false
    self.dockPending = false
    self:SetEscapeCloses(false)
    if LazyProf.Client:IsOpen() and (self.livePath or self.liveNotice) then
        self.mode = "live"
        self:SetPath(self.livePath)
        self.notice = self.liveNotice
        self.frame.userClosed = true
    else
        self.mode = nil
        self:SetPath(nil)
        self.notice = nil
    end
    self:Hide()
    if LazyProf.RecipeDetails then
        LazyProf.RecipeDetails:Hide()
    end
end

-- "Plan from skill 1": a what-if for a profession the character has.
function GuideWindow:OnPlanFromOne(checked)
    if not self.planning then return end
    local store = LazyProf.CharStore:Get()
    store.planFromOne = store.planFromOne or {}
    store.planFromOne[self.planning.profKey] = checked or nil
    self:LoadPlanning(self.planning.profKey, "plan from skill 1 changed")
end

-- Redraw from the stored path (stock changed, a setting changed). A hidden
-- window (combat hides it) is redrawn when it shows again.
function GuideWindow:Refresh()
    if not self.frame then return end
    if self.frame:IsShown() then
        self.needsRender = nil
        self:Render()
    else
        self.needsRender = true
    end
end

-- Drawing ------------------------------------------------------------------------

-- Put the target the shown path was planned for on the slider and in the
-- box. Not while the player has the handle (a bag update redraws the window
-- in the middle of a drag); in the box the digits the player is typing stay,
-- and the target is what the box goes back to when it is left. `value`: a
-- target in force that differs from the path's (a commit that needed no new
-- path).
function GuideWindow:ShowTarget(value)
    -- (Asking can end a hold and plan again: the target is read after it.)
    if not self.frame or self.slider:IsHeld() then return end
    local target = self.target
    if not target then return end
    self.slider:SetRange(target.min, target.max, value or target.value)
    self.slider:SetEnabled(target.enabled)
    self.sliderMin:SetText(target.leftLabel)
    self.sliderMax:SetText(target.rightLabel)
    self.targetInput:SetValue(self.slider:GetValue(), true)
end

function GuideWindow:Render()
    if not self.frame then return end
    -- Asked before anything is worked out: a drag of the slider whose release
    -- was not heard ends here and commits like a release, which plans and
    -- draws again. What follows then draws the path that brought, not the
    -- one this redraw started with.
    self.slider:IsHeld()
    local Views = LazyProf.GuideViews
    local profile = LazyProf.db.profile
    local view = self:ComputeView()
    self.view = view
    local path = view.path

    local header = Views.Header(view)
    self.frame.title:SetText(header.title)
    self.status:SetText(header.status)
    self.moreBtn:SetText((path and view.advanced) and "Fewer options" or "More options")

    if path then
        self.strategyGroup:SetSelected(profile.strategy)
        self.marginBox:SetChecked(profile.useMargin)
        self.marginBox:SetLabel(string.format("Spare crafts (%d%%)", profile.marginPercent or 15))
        self.sellingDropdown:SetText(SellingText(profile.saleValueMode))
        self.prices:SetText(header.priceText)
        self.prices:SetTextColor(header.priceColor[1], header.priceColor[2], header.priceColor[3])
        -- The what-if only makes sense in planning, for a profession the character has
        self.fromOneBox:SetShown(self.mode == "planning" and path.hasProfession ~= false)
        self.fromOneBox:SetChecked(path.planFromOne)
        self.hideOwnedBox:SetChecked(view.hideOwned)
    end
    if self.mode == "planning" then
        local info = LazyProf.Constants.PROFESSIONS[self.profKey or ""]
        self.professionDropdown:SetText(info and info.name or "Profession")
    end

    self.target = path and Views.Target(view) or nil
    self:ShowTarget()
    self:FillReceipt(path and Views.Receipt(view) or {})

    self:Layout()
    self:RenderTab()
end

-- Callbacks the rows use.
function GuideWindow:Context()
    if self.ctx then return self.ctx end
    local function rowKey(stage)
        return LazyProf.GuideViews.RowKey(stage)
    end
    self.ctx = {
        -- A click on a run: `open` is the state it asks for.
        onToggleExpand = function(stage, open)
            self.expanded[rowKey(stage)] = open and true or false
            self:RenderTab()
        end,
        onShowRecipe = function(recipe, skill)
            if LazyProf.RecipeDetails then
                LazyProf.RecipeDetails:Show(recipe, skill)
            end
        end,
        onShowAllAlts = function(stage, on)
            self.showAllAlts[rowKey(stage)] = on and true or nil
            self:RenderTab()
        end,
        -- "Use": pin the recipe over the run's range and plan again at once.
        -- The run keeps the state the player gave it (opened or closed) under
        -- its new recipe.
        onUseAlternative = function(stage, alt)
            local state = self.expanded[rowKey(stage)]
            if state ~= nil then
                self.expanded[rowKey({ kind = "craft", recipe = alt.recipe })] = state
            end
            LazyProf.Pathfinder:PinRange(self.path.professionKey, stage.from, stage.to, alt.recipe.id)
            self:Recalculate("recipe pinned")
        end,
        -- "I craft it" / "I buy it": a choice per character and item. It
        -- changes the shopping list (and with it the receipt), never the path.
        onCraftChoice = function(row, choice)
            LazyProf.CharStore:Get().craftChoices[row.itemId] = choice
            self:Render()
        end,
        onResetPin = function(stage)
            LazyProf.Pathfinder:UnpinAt(self.path.professionKey, stage.from)
            self:Recalculate("pin removed")
        end,
    }
    return self.ctx
end

-- Rows of the selected tab.
function GuideWindow:TabRows()
    local Views = LazyProf.GuideViews
    local view = self.view or {}
    if not view.path then
        return { { kind = "line", height = 26, text = self.notice or "", color = { 0.8, 0.8, 0.8 }, wrap = true } }
    end
    local ctx = self:Context()
    if self.tab == "shopping" then
        return Views.Shopping(view, ctx)
    end
    -- The search acts only while its box is there (More options).
    if view.advanced and self.search ~= "" then
        local prof = LazyProf.Professions:Get(view.path.professionKey)
        return Views.SearchResults(Views.SearchRecipes(prof and prof.recipes or {}, self.search), ctx)
    end
    return Views.Path(view, ctx)
end

function GuideWindow:RenderTab(toTop)
    if not self.frame then return end
    self.list:Render(self:TabRows(), toTop)
end

-- Select a tab. fromClick: the player chose it (remembered per character).
function GuideWindow:SelectTab(key, fromClick)
    self.tab = self.TABS[TabIndex(key)].key
    if fromClick then
        LazyProf.CharStore:Get().lastTab = self.tab
    end
    if not self.frame then return end
    self.tabs:Select(TabIndex(self.tab))
    self:Render()
    self.list.frame:SetVerticalScroll(0)
end

-- Header controls -----------------------------------------------------------------

-- A new path is needed. The live path is the planner's (LazyProf:Recalculate
-- brings it back through Update); planning calculates its own.
function GuideWindow:Recalculate(reason)
    if self.mode == "planning" then
        if not self.planning then return end
        -- The target and the pins are the profession's, whichever view set
        -- them: when the planned profession is the one whose window is open,
        -- its path and the arrow are planned again too (LazyProf:Recalculate
        -- refreshes planning as well).
        if LazyProf.Client:IsOpen() and self.planning.profKey == LazyProf.Professions.active then
            LazyProf:Recalculate(reason)
        else
            self:LoadPlanning(self.planning.profKey, reason)
        end
        return
    end
    LazyProf:Recalculate(reason)
end

-- A setting that is one for every path changed: the shown path is planned
-- again, and so is the open profession's when planning is shown.
local function PlanEverythingAgain(self, reason)
    if self.mode == "planning" and LazyProf.Client:IsOpen() then
        LazyProf:Recalculate(reason)
        return   -- LazyProf:Recalculate refreshes planning too
    end
    self:Recalculate(reason)
end

-- A target was committed (the box, or the slider let go): store the value
-- (clamped) and plan again when it changed. Returns the value in force so the
-- box and the slider show the correction.
function GuideWindow:OnTargetCommit(value)
    local path = self.path
    if not path then return nil end
    local target = LazyProf.Pathfinder:SetTargetSkill(path.professionKey, value, path.actualSkill, path.milestones)
    if target ~= path.targetSkill then
        self:Recalculate("target changed")
    end
    return target
end

-- The slider's handle was let go at a new value. A new path redraws the
-- header; without one (the value was corrected back to the target in force)
-- the handle and the box are put on the target here. The box shows it even
-- if it still has the keyboard: the slider was used last, and moving it
-- already replaced whatever was typed.
function GuideWindow:OnSliderReleased(value)
    local target = self:OnTargetCommit(value)
    if target then
        self:ShowTarget(target)
        self.targetInput:SetValue(self.slider:GetValue())
    end
end

-- "More options" / "Fewer options": remembered in the settings.
function GuideWindow:OnMoreOptions()
    local profile = LazyProf.db.profile
    profile.showAdvanced = not profile.showAdvanced
    self:Render()
end

function GuideWindow:OnStrategy(value)
    if LazyProf.db.profile.strategy == value then return end
    LazyProf.db.profile.strategy = value
    PlanEverythingAgain(self, "strategy change")
end

-- What crafts are counted as selling for changes which recipes are cheapest.
function GuideWindow:OnSelling(value)
    self.sellingDropdown:SetText(SellingText(value))
    if LazyProf.db.profile.saleValueMode == value then return end
    LazyProf.db.profile.saleValueMode = value
    PlanEverythingAgain(self, "sale value change")
end

-- The margin changes counts and costs, never the recipes: no new path needed.
function GuideWindow:OnMargin(checked)
    LazyProf.db.profile.useMargin = checked and true or false
    self:Render()
end

function GuideWindow:OnSearch(text)
    self.search = text or ""
    self.state.search = self.search
    self:RenderTab(true)
end
