-- Modules/UI/GuideWindow.lua
-- The LazyProf window: one framed, tabbed window beside the profession window.
-- A shared header (status, target, strategy, margin, range) sits above the
-- tab's list and a footer with the totals.
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
local CONTROLS_TOP = 48       -- below the title and the status line
local CONTROLS_HEIGHT = 92    -- target row, range row, path bar
local HEADER_HEIGHT = CONTROLS_TOP + CONTROLS_HEIGHT
local FOOTER_HEIGHT = 40      -- two lines of totals
local SEARCH_HEIGHT = 26
local NAV_HEIGHT = 28

-- Tabs in display order. key names the tab in saved data.
GuideWindow.TABS = {
    { key = "guide", label = "Guide" },
    { key = "steps", label = "Steps" },
}

GuideWindow.frame = nil
GuideWindow.mode = nil        -- "live": follows the open profession window
GuideWindow.path = nil
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
    local path = self.path
    local view = { path = path, expanded = self.expanded, marginPercent = MarginPercent() }
    if not path then return view end

    local stages, summary = LazyProf.Stages.Build(path, {
        inventory = path.inventory,
        prices = path.prices,
        marginPercent = view.marginPercent,
        pins = LazyProf.Pathfinder:GetPins(path.professionKey),
    })
    local brackets = Utils.BuildSkillBrackets(path.milestones or {})
    local Range = LazyProf.GuideRange
    view.stages, view.summary = stages, summary
    view.brackets = brackets
    view.skill = path.actualSkill
    view.bracket = Range.Effective(self.rangeSel, brackets, path.actualSkill)
    view.rangeLabel = Range.Label(self.rangeSel, brackets, path.actualSkill)
    view.rangeStages = Range.FilterStages(stages, view.bracket)
    view.rangeTotals = LazyProf.Stages.Totals(view.rangeStages)
    view.selectedStage = LazyProf.GuideViews.SelectedStage(stages, summary, self.selection)
    view.showAllAlts = self.showAllAlts

    -- The open profession's cap, as its window reports it
    if self.mode == "live" then
        local _, _, cap = LazyProf.Client:GetLine()
        view.cap = cap
    end

    local pm = LazyProf.PriceManager
    if pm and pm.PathSummary then
        view.priceSummary = pm:PathSummary(path)
        view.priceLines = pm.SummaryLines(view.priceSummary)
    end

    -- The next recipe is unlearned and the profession window hides unlearned
    -- recipes, so the arrow has no row to point at: say where to learn it.
    if self.mode == "live" then
        local step = LazyProf.Pathfinder:GetArrowStep(path)
        local recipe = step and step.recipe
        if recipe and not recipe.learned and LazyProf.Client:UnlearnedHiddenByFilter() then
            view.hint = "Next recipe is not learned yet - learn it from " .. Utils.GetSourceDescription(recipe.source)
            view.hintStep = step
        end
    end
    return view
end

-- What the shopping list of the chosen range is computed from, and the
-- range's name (nil for the full path). nil without a path.
function GuideWindow:ShoppingSteps()
    if not self.path then return nil end
    local view = self:ComputeView()
    return LazyProf.Stages.ShoppingSteps(view.rangeStages or {}), view.bracket and view.bracket.name or nil
end

-- Should the window be showing right now? (Asked by the panel shell when
-- combat ends.)
function GuideWindow:WantsShown()
    if self.mode == "live" then
        return LazyProf.Client:IsOpen() and (self.path ~= nil or self.notice ~= nil)
    end
    return false
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
    -- Stays closed until the profession window is opened again
    frame.closeBtn:SetScript("OnClick", function()
        PanelShell:Close(frame)
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

    -- The path bar: the whole journey, one segment per stage
    self.bar = LazyProf.PathBar.Create(controls)
    self.bar.frame:SetPoint("TOPLEFT", 14, -62)
    self.bar.frame:SetPoint("TOPRIGHT", -14, -62)

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

    -- Steps tab: recipe search above the list
    self.searchBox = Widgets.CreateSearchBox(body, "LazyProfGuideSearch", "Search recipes...", function(text)
        self:OnSearch(text)
    end)
    self.searchBox.frame:SetPoint("TOPLEFT", 16, -HEADER_HEIGHT - 2)
    self.searchBox.frame:SetPoint("TOPRIGHT", -30, -HEADER_HEIGHT - 2)

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

    PanelShell:Attach(frame, "guide", {
        anchor = function()
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

-- Default size: as tall as the profession window, within sensible limits;
-- the size the player dragged it to wins.
function GuideWindow:ApplySize()
    local anchor = LazyProf.Client:AnchorFrame()
    local height = anchor and anchor.GetHeight and anchor:GetHeight() or 0
    if not height or height <= 0 then height = FALLBACK_HEIGHT end
    height = math.max(MIN_HEIGHT + 60, math.min(700, height))
    LazyProf.PanelShell:ApplySize(self.frame, DEFAULT_WIDTH, height)
    self.sized = true
    self:Layout()
end

-- Place the list for the selected tab and tell it how wide its rows are.
function GuideWindow:Layout()
    local frame = self.frame
    local top, bottom = HEADER_HEIGHT + 4, FOOTER_HEIGHT + 2
    if self.tab == "steps" then
        top = top + SEARCH_HEIGHT
    elseif self.tab == "guide" then
        bottom = bottom + NAV_HEIGHT
    end
    self.searchBox.frame:SetShown(self.tab == "steps" and self.path ~= nil)
    self.nav:SetShown(self.tab == "guide" and self.path ~= nil)
    self.list.frame:ClearAllPoints()
    self.list.frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 10, -top)
    self.list.frame:SetPoint("BOTTOMRIGHT", self.body, "BOTTOMRIGHT", -30, bottom)
    self.list:SetWidth(math.max(100, frame:GetWidth() - 44))
end

-- Showing and hiding -------------------------------------------------------------

-- A live path arrived (the profession window is open).
function GuideWindow:Update(path)
    self.mode = "live"
    self.notice = nil
    self:SetPath(path)
    if not LazyProf.db.profile.showMilestonePanel then
        self:Hide()
        return
    end
    self:Build()
    self.frame.showsNotice = nil
    self:Render()
    self:Show()
end

-- The open profession has no recipe data: say so instead of showing a path.
function GuideWindow:ShowNotice(text)
    self.mode = "live"
    self:SetPath(nil)
    self.notice = text
    if not LazyProf.db.profile.showMilestonePanel then
        self:Hide()
        return
    end
    self:Build()
    self.frame.showsNotice = true
    self:Render()
    self:Show()
end

function GuideWindow:Show()
    if not self.sized then
        self:ApplySize()
    end
    LazyProf.PanelShell:Show(self.frame)
end

function GuideWindow:Hide()
    if not self.frame then return end
    self.frame.showsNotice = nil
    LazyProf.PanelShell:Hide(self.frame)
end

function GuideWindow:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

-- The profession window closed.
function GuideWindow:OnProfessionClosed()
    self:Hide()
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

    self.controls:SetShown(path ~= nil)
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
    elseif self.search ~= "" then
        local prof = LazyProf.Professions:Get(view.path.professionKey)
        return Views.SearchResults(Views.SearchRecipes(prof and prof.recipes or {}, self.search), ctx)
    else
        rows = Views.Steps(view, ctx)
    end
    if view.hint then
        local step = view.hintStep
        table.insert(rows, 1, {
            kind = "line", text = view.hint, color = { 1, 0.53, 0 },
            bg = { 0.2, 0.15, 0, 0.3 }, hoverBg = { 0.3, 0.25, 0.1, 0.5 },
            tooltip = {
                { text = view.hint, r = 1, g = 0.53, b = 0 },
                { text = "The profession window hides unlearned recipes, so the arrow cannot point at it.", r = 0.7, g = 0.7, b = 0.7 },
                { text = "Click for details", r = 1, g = 1, b = 1 },
            },
            onClick = function()
                if LazyProf.RecipeDetails then
                    LazyProf.RecipeDetails:Toggle(step.recipe, math.floor(step.skillStart or 0))
                end
            end,
        })
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
    self:Layout()
    self:RenderTab(true)
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

-- A new path is needed. The live path is the planner's; LazyProf:Recalculate
-- brings it back through Update.
function GuideWindow:Recalculate(reason)
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

function GuideWindow:OnStrategy(value)
    if LazyProf.db.profile.strategy == value then return end
    LazyProf.db.profile.strategy = value
    self:Recalculate("strategy change")
end

-- The margin changes counts and costs, never the recipes: no new path needed.
function GuideWindow:OnMargin(checked)
    LazyProf.db.profile.useMargin = checked and true or false
    self:Render()
    LazyProf:UpdateShoppingPanel()
end

function GuideWindow:OnRange(value)
    self.rangeSel = LazyProf.GuideRange.FromValue(value)
    self:Render()
    self.list.frame:SetVerticalScroll(0)
    LazyProf:UpdateShoppingPanel()
end

function GuideWindow:OnSearch(text)
    self.search = text or ""
    self:RenderTab(true)
end
