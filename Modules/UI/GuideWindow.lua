-- Modules/UI/GuideWindow.lua
-- The LazyProf window: one framed, tabbed window. A shared header (status,
-- target, strategy, margin, range, path bar) sits above the tab's list and a
-- footer with the totals.
--
-- There is one window. It has two modes:
--   live      docked beside the open profession window, showing its path
--   planning  undocked, for any profession picked from the minimap button, the
--             addon compartment or /lp browse; a profession dropdown and, for
--             a profession the character has, a "plan from skill 1" what-if
--             appear in the header; Escape closes it
-- A profession window that opens docks the window and shows that profession;
-- when it closes the window goes back to the planning view it had, or hides.
-- Planning opened while a profession window is open stays until it is closed.
--
-- This file only places widgets and passes clicks on. What each tab shows is
-- built as plain data by Modules/Guide/Views.lua from the stages of the path
-- (Modules/Guide/Stages.lua) and drawn by Widgets/RowList.lua. Position,
-- closed state and combat hide/restore belong to Widgets/PanelShell.lua.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

local GuideWindow = {}
LazyProf.GuideWindow = GuideWindow

local DEFAULT_WIDTH = 420
local MIN_WIDTH, MAX_WIDTH = 380, 640
local MIN_HEIGHT, MAX_HEIGHT = 360, 900
local FALLBACK_HEIGHT = 480
local PLANNING_HEIGHT = 540
local CONTROLS_TOP = 48       -- below the title and the status line
local CONTROLS_HEIGHT = 92    -- target row, range row, path bar
local PLAN_ROW_TOP = 62       -- where the path bar sits (and planning's extra row)
local PLAN_ROW_HEIGHT = 30
local FOOTER_HEIGHT = 40      -- two lines of totals
local SEARCH_HEIGHT = 26
local NAV_HEIGHT = 28

-- Tabs in display order. key names the tab in saved data.
GuideWindow.TABS = {
    { key = "guide", label = "Guide" },
    { key = "steps", label = "Steps" },
    { key = "shopping", label = "Shopping" },
}

GuideWindow.frame = nil
GuideWindow.mode = nil        -- "live" | "planning"
GuideWindow.path = nil        -- the path shown (the live one, or planning's)
GuideWindow.livePath = nil    -- the open profession's path, also while planning is shown
GuideWindow.liveNotice = nil  -- its "no recipe data" text
GuideWindow.planning = nil    -- { profKey, path, notice } while a planning view exists
GuideWindow.shoppingPath = nil   -- the last path shown, kept after the window closes (merchant panel)
GuideWindow.returnToPlanning = false   -- planning was set aside for a profession window
GuideWindow.profKey = nil
GuideWindow.rangeSel = nil    -- nil: current range; a bracket index; "all"
GuideWindow.expanded = {}     -- [stage.key] = true, rows opened on the Steps tab
GuideWindow.search = ""
GuideWindow.notice = nil      -- text shown instead of a path (no recipe data)
GuideWindow.tab = "guide"
GuideWindow.selection = nil   -- the stage opened on the Guide tab: { key, from }; nil follows the current one
GuideWindow.showAllAlts = false

function GuideWindow:Initialize()
    -- Frames are built the first time the window is shown.
end

-- State ------------------------------------------------------------------------

-- Take a new path. Another profession starts with a clean view; the same one
-- keeps the chosen range, the opened rows and the search.
function GuideWindow:SetPath(path)
    local key = path and path.professionKey or nil
    if key ~= self.profKey then
        self.profKey = key
        self.rangeSel = nil
        self.expanded = {}
        self.search = ""
        self.selection = nil
        self.showAllAlts = false
        if self.frame then
            self.searchBox:SetText("")
        end
    end
    self.path = path
    if path then
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

-- plain: leave out what belongs to the window's own state (chosen range,
-- selected step, opened rows, shopping list).
function GuideWindow:BuildView(path, mode, plain)
    local view = { path = path, expanded = plain and {} or self.expanded, marginPercent = MarginPercent() }
    if not path then return view end
    local rangeSel = (not plain) and self.rangeSel or nil

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
    local brackets = Utils.BuildSkillBrackets(path.milestones or {})
    local Range = LazyProf.GuideRange
    view.stages, view.summary = stages, summary
    view.brackets = brackets
    view.skill = path.actualSkill
    view.bracket = Range.Effective(rangeSel, brackets, path.actualSkill)
    view.rangeLabel = Range.Label(rangeSel, brackets, path.actualSkill)
    view.rangeStages = Range.FilterStages(stages, view.bracket)
    view.rangeTotals = LazyProf.Stages.Totals(view.rangeStages)
    view.selectedStage = LazyProf.GuideViews.SelectedStage(stages, summary, (not plain) and self.selection or nil)
    view.showAllAlts = (not plain) and self.showAllAlts or false
    view.hideOwned = LazyProf.CharStore:Get().hideOwned and true or false
    view.planning = (mode == "planning") or nil
    -- The shopping list of the chosen range, from the stages' quantities (so
    -- the margin is in it). Only worked out for the tab that shows it.
    if self.tab == "shopping" and not plain then
        view.missing = self:Missing(view)
    end

    local pm = LazyProf.PriceManager
    if pm and pm.PathSummary then
        view.priceSummary = pm:PathSummary(path)
        view.priceLines = pm.SummaryLines(view.priceSummary)
    end

    -- The next recipe is unlearned and the profession window hides unlearned
    -- recipes, so the arrow has no row to point at: its learn step says so.
    if mode == "live" then
        local step = LazyProf.Pathfinder:GetArrowStep(path)
        local recipe = step and step.recipe
        if recipe and not recipe.learned and LazyProf.Client:UnlearnedHiddenByFilter() then
            view.hiddenRecipeId = recipe.id
        end
    end
    return view
end

-- The shopping list of a view's range (Pathfinder:CalculateMissingMaterials).
function GuideWindow:Missing(view)
    local path = view.path
    return LazyProf.Pathfinder:CalculateMissingMaterials(
        LazyProf.Stages.ShoppingSteps(view.rangeStages or {}),
        path.inventory or {}, path.sourceBreakdown or {}, path.prices or {})
end

-- What the shopping list of the chosen range is computed from, and the
-- range's name (nil for the full path). nil without a path.
function GuideWindow:ShoppingSteps()
    if not self.path then return nil end
    local view = self:ComputeView()
    return LazyProf.Stages.ShoppingSteps(view.rangeStages or {}), view.bracket and view.bracket.name or nil
end

-- For the merchant panel: the shopping rows of the path the window showed
-- last (its chosen range while the window still shows that path, else the
-- current range), worked out from the stock as it is now. Returns the rows
-- and a name for the list ("Tailoring 75-150"); nil when no path was shown
-- this session.
function GuideWindow:MerchantRows()
    local path = self.shoppingPath
    if not path then return nil end
    path.inventory, path.sourceBreakdown = LazyProf.Inventory:ScanAll()
    local view = self:BuildView(path, path.planning and "planning" or "closed", path ~= self.path)
    local name = tostring(path.profession) .. (view.bracket and (" " .. view.bracket.name) or "")
    return self:Missing(view).rows, name
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
    -- Escape (planning only, see SetEscapeCloses) hides the frame directly:
    -- treat it as closing planning. Not when combat or this file hid it, and
    -- not when the frame is merely out of sight because the whole interface
    -- is hidden (it is then still "shown").
    frame:HookScript("OnHide", function(f)
        if self.mode == "planning" and not self.hidingSelf and not f._wasShownBeforeCombat and not f:IsShown() then
            self:ClosePlanning()
        end
    end)

    -- Status line: skill and cap on the left, where prices come from on the right
    self.status = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.status:SetPoint("TOPLEFT", 12, -32)
    self.status:SetJustifyH("LEFT")

    self.pricesBtn = CreateFrame("Button", nil, body)
    self.pricesBtn:SetSize(210, 14)
    self.pricesBtn:SetPoint("TOPRIGHT", -12, -31)
    self.prices = self.pricesBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.prices:SetPoint("RIGHT", 0, 0)
    self.prices:SetJustifyH("RIGHT")
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

    -- Controls (hidden while there is no path)
    local controls = CreateFrame("Frame", nil, body)
    self.controls = controls
    controls:SetPoint("TOPLEFT", 0, -CONTROLS_TOP)
    controls:SetPoint("TOPRIGHT", 0, -CONTROLS_TOP)
    controls:SetHeight(CONTROLS_HEIGHT)

    self.targetLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.targetLabel:SetPoint("TOPLEFT", 12, -8)
    self.targetLabel:SetText("Target")

    self.targetInput = Widgets.CreateNumericInput(controls, "LazyProfGuideTarget", 36, 3, function(value)
        return self:OnTargetCommit(value)
    end)
    self.targetInput:SetPoint("LEFT", self.targetLabel, "RIGHT", 10, 0)

    self.strategyGroup = Widgets.CreateButtonGroup(controls, {
        { text = "Cheapest", value = "cheapest", width = 72, tooltip = "The path that costs the least gold." },
        { text = "Fastest", value = "fastest", width = 66,
          tooltip = "The path with the fewest crafts. It can cost much more than Cheapest." },
    }, function(value) self:OnStrategy(value) end)
    self.strategyGroup:SetPoint("LEFT", self.targetInput.frame, "RIGHT", 10, 0)

    self.marginBox = Widgets.CreateCheckbox(controls, "LazyProfGuideMargin", "With margin", function(checked)
        self:OnMargin(checked)
    end, "Plan extra crafts and reagents for bad luck with skill-ups. The percentage is set in the options.")
    self.marginBox:SetPoint("LEFT", self.strategyGroup.frame, "RIGHT", 6, 0)

    self.rangeLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.rangeLabel:SetPoint("TOPLEFT", 12, -36)
    self.rangeLabel:SetText("Range")

    self.rangeDropdown = Widgets.CreateDropdown(controls, "LazyProfGuideRange", 130)
    self.rangeDropdown:SetPoint("TOPLEFT", 36, -27)
    self.rangeDropdown:SetOptions(function()
        local view = self.view or {}
        return LazyProf.GuideRange.Options(self.rangeSel, view.brackets or {})
    end, function(value)
        self:OnRange(value)
    end)

    -- Planning only: which profession, and the "from skill 1" what-if
    local planRow = CreateFrame("Frame", nil, controls)
    self.planRow = planRow
    planRow:SetPoint("TOPLEFT", 0, -PLAN_ROW_TOP)
    planRow:SetPoint("TOPRIGHT", 0, -PLAN_ROW_TOP)
    planRow:SetHeight(PLAN_ROW_HEIGHT)
    self.professionLabel = planRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.professionLabel:SetPoint("LEFT", 12, 0)
    self.professionLabel:SetText("Profession")
    self.professionDropdown = Widgets.CreateDropdown(planRow, "LazyProfGuideProfession", 110)
    self.professionDropdown:SetPoint("LEFT", planRow, "LEFT", 58, 0)
    self.professionDropdown:SetOptions(function()
        return self:ProfessionOptions()
    end, function(profKey)
        self:OpenPlanning(profKey)
    end)
    self.fromOneBox = Widgets.CreateCheckbox(planRow, "LazyProfGuideFromOne", "Plan from skill 1", function(checked)
        self:OnPlanFromOne(checked)
    end, "Show the whole path from skill 1 as a what-if. The bar marks what you have already done.")
    self.fromOneBox:SetPoint("LEFT", self.professionDropdown.frame, "RIGHT", -8, 0)

    -- The path bar: the whole journey, one segment per stage
    self.bar = LazyProf.PathBar.Create(controls)

    -- Guide tab: step navigation under the card
    local nav = CreateFrame("Frame", nil, body)
    self.nav = nav
    nav:SetPoint("BOTTOMLEFT", 10, FOOTER_HEIGHT + 2)
    nav:SetPoint("BOTTOMRIGHT", -10, FOOTER_HEIGHT + 2)
    nav:SetHeight(NAV_HEIGHT - 4)
    local function navButton(text, width, onClick)
        local button = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
        button:SetSize(width, 22)
        button:SetText(text)
        button:SetScript("OnClick", onClick)
        return button
    end
    self.prevBtn = navButton("< Prev", 62, function() self:Step(-1) end)
    self.prevBtn:SetPoint("LEFT", 0, 0)
    self.currentBtn = navButton("Current step", 92, function() self:Step(0) end)
    self.currentBtn:SetPoint("LEFT", self.prevBtn, "RIGHT", 4, 0)
    self.nextBtn = navButton("Next >", 62, function() self:Step(1) end)
    self.nextBtn:SetPoint("LEFT", self.currentBtn, "RIGHT", 4, 0)
    self.recipeBtn = navButton("Recipe details", 104, function()
        local stage = self.view and self.view.selectedStage
        if stage and stage.recipe and LazyProf.RecipeDetails then
            LazyProf.RecipeDetails:Toggle(stage.recipe, stage.fromDisplay)
        end
    end)
    self.recipeBtn:SetPoint("RIGHT", 0, 0)

    -- Shopping tab: the total and "Hide what I have" under the table
    local shop = CreateFrame("Frame", nil, body)
    self.shopStrip = shop
    shop:SetPoint("BOTTOMLEFT", 10, FOOTER_HEIGHT + 2)
    shop:SetPoint("BOTTOMRIGHT", -10, FOOTER_HEIGHT + 2)
    shop:SetHeight(NAV_HEIGHT - 4)
    self.shopTotal = shop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.shopTotal:SetPoint("LEFT", 4, 0)
    self.shopTotal:SetTextColor(1, 1, 1)
    self.hideOwnedBox = Widgets.CreateCheckbox(shop, "LazyProfGuideHideOwned", "Hide what I have", function(checked)
        LazyProf.CharStore:Get().hideOwned = checked or nil
        self:Render()
    end, "Show only the reagents you still have to buy or craft.")
    self.hideOwnedBox:SetPoint("RIGHT", shop, "RIGHT", -110, 0)

    -- Steps tab: recipe search above the list
    self.searchBox = Widgets.CreateSearchBox(body, "LazyProfGuideSearch", "Search recipes...", function(text)
        self:OnSearch(text)
    end)

    -- The tab's list
    self.list = Widgets.CreateRowList(body, "LazyProfGuideList")

    -- Footer: totals
    self.footer1 = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.footer1:SetPoint("BOTTOMLEFT", 12, 22)
    self.footer1:SetPoint("BOTTOMRIGHT", -30, 22)
    self.footer1:SetJustifyH("LEFT")
    self.footer1:SetWordWrap(false)
    self.footer2 = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.footer2:SetPoint("BOTTOMLEFT", 12, 8)
    self.footer2:SetPoint("BOTTOMRIGHT", -30, 8)
    self.footer2:SetJustifyH("LEFT")
    self.footer2:SetWordWrap(false)
    self.footer2:SetTextColor(0.7, 0.7, 0.7)

    self.resizeGrip = Widgets.CreateResizeGrip(frame, function()
        PanelShell:SaveSize(frame)
        self:Layout()
        self:RenderTab()
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
                self:RenderTab()
            end
        end,
    })

    -- Open on the tab this character used last
    self:SelectTab(LazyProf.CharStore:Get().lastTab or self.tab)
end

-- Default size: docked, as tall as the profession window, within sensible
-- limits; undocked, a fixed height. The size the player dragged it to wins.
function GuideWindow:ApplySize()
    local height = PLANNING_HEIGHT
    if self.mode ~= "planning" then
        local anchor = LazyProf.Client:AnchorFrame()
        height = anchor and anchor.GetHeight and anchor:GetHeight() or 0
        if not height or height <= 0 then height = FALLBACK_HEIGHT end
        height = math.max(MIN_HEIGHT + 60, math.min(700, height))
    end
    LazyProf.PanelShell:ApplySize(self.frame, DEFAULT_WIDTH, height)
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

-- Place the list for the selected tab and tell it how wide its rows are.
function GuideWindow:Layout()
    local frame = self.frame
    -- Planning adds a row (profession, what-if) above the path bar.
    local planning = self.mode == "planning"
    local controlsHeight = CONTROLS_HEIGHT + (planning and PLAN_ROW_HEIGHT or 0)
    local barTop = PLAN_ROW_TOP + (planning and PLAN_ROW_HEIGHT or 0)
    self.controls:SetHeight(controlsHeight)
    self.planRow:SetShown(planning)
    self.bar.frame:ClearAllPoints()
    self.bar.frame:SetPoint("TOPLEFT", self.controls, "TOPLEFT", 14, -barTop)
    self.bar.frame:SetPoint("TOPRIGHT", self.controls, "TOPRIGHT", -14, -barTop)
    local headerHeight = CONTROLS_TOP + controlsHeight
    self.searchBox.frame:ClearAllPoints()
    self.searchBox.frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 16, -headerHeight - 2)
    self.searchBox.frame:SetPoint("TOPRIGHT", self.body, "TOPRIGHT", -30, -headerHeight - 2)

    local top, bottom = headerHeight + 4, FOOTER_HEIGHT + 2
    if self.tab == "steps" then
        top = top + SEARCH_HEIGHT
    elseif self.tab == "guide" or self.tab == "shopping" then
        bottom = bottom + NAV_HEIGHT
    end
    self.searchBox.frame:SetShown(self.tab == "steps" and self.path ~= nil)
    self.nav:SetShown(self.tab == "guide" and self.path ~= nil)
    self.shopStrip:SetShown(self.tab == "shopping" and self.path ~= nil)
    self.list.frame:ClearAllPoints()
    self.list.frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 10, -top)
    self.list.frame:SetPoint("BOTTOMRIGHT", self.body, "BOTTOMRIGHT", -30, bottom)
    self.list:SetWidth(math.max(100, frame:GetWidth() - 44))
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

-- A live path arrived (the profession window is open). While planning is
-- shown it is only kept: planning stays until the player closes it.
function GuideWindow:Update(path)
    self.livePath, self.liveNotice = path, nil
    if self.mode == "planning" then return end
    self:DisplayLive()
end

-- The open profession has no recipe data: say so instead of showing a path.
function GuideWindow:ShowNotice(text)
    self.livePath, self.liveNotice = nil, text
    if self.mode == "planning" then return end
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
-- (its path arrives through Update). A planning view is set aside and comes
-- back when the profession window closes.
function GuideWindow:OnProfessionOpened()
    if self.mode == "planning" and self.planning and LazyProf.db.profile.openWithProfession then
        self.returnToPlanning = true
        self.mode = "live"
    end
end

-- The profession window closed: back to the planning view that was set
-- aside, else hide. Planning opened on top of the profession window stays.
function GuideWindow:OnProfessionClosed()
    self.livePath, self.liveNotice = nil, nil
    if self.mode == "planning" then return end
    if self.returnToPlanning and self.planning then
        self.returnToPlanning = false
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

-- Redraw from the stored path (stock changed, a setting changed).
function GuideWindow:Refresh()
    if self.frame and self.frame:IsShown() then
        self:Render()
    end
end

-- Drawing ------------------------------------------------------------------------

function GuideWindow:Render()
    if not self.frame then return end
    local Views = LazyProf.GuideViews
    local view = self:ComputeView()
    self.view = view
    local path = view.path

    local header = Views.Header(view)
    self.frame.title:SetText(header.title)
    self.status:SetText(header.status)
    self.prices:SetText(header.priceText)
    self.prices:SetTextColor(header.priceColor[1], header.priceColor[2], header.priceColor[3])

    -- Without a path only the profession picker (planning) is left of the controls
    self.controls:SetShown(path ~= nil or self.mode == "planning")
    for _, widget in ipairs({ self.targetInput.frame, self.strategyGroup.frame, self.marginBox.frame,
                              self.rangeDropdown.frame, self.bar.frame }) do
        widget:SetShown(path ~= nil)
    end
    self.targetLabel:SetShown(path ~= nil)
    self.rangeLabel:SetShown(path ~= nil)
    if path then
        self.targetInput:SetValue(path.targetSkill)
        self.strategyGroup:SetSelected(LazyProf.db.profile.strategy)
        self.marginBox:SetChecked(LazyProf.db.profile.useMargin)
        self.rangeDropdown:SetText(view.rangeLabel)
        self.bar:Render(Views.PathBar(view), math.max(50, self.frame:GetWidth() - 28), function(stage)
            self:OpenStage(stage)
        end)
        local nav = Views.GuideNav(view)
        self.prevBtn:SetEnabled(nav.prev)
        self.nextBtn:SetEnabled(nav.next)
        self.currentBtn:SetEnabled(nav.current)
        self.recipeBtn:SetEnabled(nav.recipe)
        self.shopTotal:SetText(Views.ShoppingTotal(view))
        self.hideOwnedBox:SetChecked(view.hideOwned)
        -- The what-if only makes sense for a profession the character has
        self.fromOneBox:SetShown(path.hasProfession ~= false)
        self.fromOneBox:SetChecked(path.planFromOne)
    end
    if self.mode == "planning" then
        local info = LazyProf.Constants.PROFESSIONS[self.profKey or ""]
        self.professionDropdown:SetText(info and info.name or "Profession")
    end

    local line1, line2 = Views.Footer(view)
    self.footer1:SetText(line1 or "")
    self.footer2:SetText(line2 or "")

    self:Layout()
    self:RenderTab()
end

-- Callbacks the rows use.
function GuideWindow:Context()
    if self.ctx then return self.ctx end
    self.ctx = {
        onToggleExpand = function(stage)
            self.expanded[stage.key] = not self.expanded[stage.key] or nil
            self:RenderTab()
        end,
        onShowRecipe = function(recipe, skill)
            if LazyProf.RecipeDetails then
                LazyProf.RecipeDetails:Show(recipe, skill)
            end
        end,
        onOpenStage = function(stage) self:OpenStage(stage) end,
        onShowAllAlts = function(on)
            self.showAllAlts = on and true or false
            self:Render()
        end,
        -- "Use this": pin the recipe over the stage's range and plan again at
        -- once. The stage stays selected under its new recipe.
        onUseAlternative = function(stage, alt)
            local key = self.path.professionKey
            LazyProf.Pathfinder:PinRange(key, stage.from, stage.to, alt.recipe.id)
            self.selection = { key = "craft:" .. tostring(alt.recipe.id) .. ":" .. tostring(stage.fromDisplay), from = stage.from }
            self.showAllAlts = false
            self:Recalculate("recipe pinned")
        end,
        -- "I craft it" / "I buy it": a choice per character and item. It
        -- changes the shopping list only, never the path.
        onCraftChoice = function(row, choice)
            LazyProf.CharStore:Get().craftChoices[row.itemId] = choice
            self:Render()
        end,
        onResetPin = function(stage)
            LazyProf.Pathfinder:UnpinAt(self.path.professionKey, stage.from)
            self.selection = { key = stage.key, from = stage.from }
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
    local rows
    if self.tab == "guide" then
        rows = Views.GuideCard(view, ctx)
    elseif self.tab == "shopping" then
        rows = Views.Shopping(view, ctx)
    elseif self.search ~= "" then
        local prof = LazyProf.Professions:Get(view.path.professionKey)
        return Views.SearchResults(Views.SearchRecipes(prof and prof.recipes or {}, self.search), ctx)
    else
        rows = Views.Steps(view, ctx)
    end
    return rows
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

-- Open a stage on the Guide tab.
function GuideWindow:OpenStage(stage)
    self.selection = { key = stage.key, from = stage.from }
    self.showAllAlts = false
    if self.tab ~= "guide" then
        self.tab = "guide"
        self.tabs:Select(TabIndex("guide"))
    end
    self:Render()
    self.list.frame:SetVerticalScroll(0)
end

-- Prev / Next (-1 / 1) from the shown stage; 0 goes back to following the
-- current step.
function GuideWindow:Step(direction)
    local view = self.view
    local stage = view and view.selectedStage
    if direction == 0 or not stage then
        self.selection = nil
    else
        local target = view.stages[stage.index + direction]
        if not target then return end
        self.selection = { key = target.key, from = target.from }
    end
    self.showAllAlts = false
    self:Render()
    self.list.frame:SetVerticalScroll(0)
end

-- Header controls -----------------------------------------------------------------

-- A new path is needed. The live path is the planner's (LazyProf:Recalculate
-- brings it back through Update); planning calculates its own.
function GuideWindow:Recalculate(reason)
    if self.mode == "planning" then
        if self.planning then
            self:LoadPlanning(self.planning.profKey, reason)
        end
        return
    end
    LazyProf:Recalculate(reason)
end

-- The target box: store the value (clamped) and plan again. Returns the value
-- in force so the box shows the correction.
function GuideWindow:OnTargetCommit(value)
    local path = self.path
    if not path then return nil end
    local target = LazyProf.Pathfinder:SetTargetSkill(path.professionKey, value, path.actualSkill, path.milestones)
    if target ~= path.targetSkill then
        self:Recalculate("target changed")
    end
    return target
end

-- The strategy is one setting for every path: the shown one is planned
-- again, and so is the open profession's when planning is shown.
function GuideWindow:OnStrategy(value)
    if LazyProf.db.profile.strategy == value then return end
    LazyProf.db.profile.strategy = value
    if self.mode == "planning" and LazyProf.Client:IsOpen() then
        LazyProf:Recalculate("strategy change")
        return   -- LazyProf:Recalculate refreshes planning too
    end
    self:Recalculate("strategy change")
end

-- The margin changes counts and costs, never the recipes: no new path needed.
function GuideWindow:OnMargin(checked)
    LazyProf.db.profile.useMargin = checked and true or false
    self:Render()
end

function GuideWindow:OnRange(value)
    self.rangeSel = LazyProf.GuideRange.FromValue(value)
    self:Render()
    self.list.frame:SetVerticalScroll(0)
end

function GuideWindow:OnSearch(text)
    self.search = text or ""
    self:RenderTab(true)
end
