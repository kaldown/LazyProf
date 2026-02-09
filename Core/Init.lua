-- Core/Init.lua
local ADDON_NAME, LazyProf = ...

LazyProf = LibStub("AceAddon-3.0"):NewAddon(
    LazyProf,
    ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceHook-3.0"
)

_G.LazyProf = LazyProf

function LazyProf:OnInitialize()
    -- Skip initialization if CraftLib dependency is missing
    if self.dependencyCheckFailed then
        return
    end

    self.db = LibStub("AceDB-3.0"):New("LazyProfDB", self.defaults, true)
    self:RegisterChatCommand("lazyprof", "SlashCommand")
    self:RegisterChatCommand("lp", "SlashCommand")
    if self.SetupConfig then
        self:SetupConfig()
    end
    local version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
    self:Print("v" .. version .. " loaded. Type /lp for options.")
end

function LazyProf:OnEnable()
    -- Skip enabling if CraftLib dependency is missing
    if self.dependencyCheckFailed then
        return
    end

    -- Initialize professions from CraftLib (must happen after all addons loaded)
    if self.Professions then
        self.Professions:Initialize()
    end

    -- Initialize modules
    if self.PriceManager then
        self.PriceManager:Initialize()
    end
    if self.ArrowManager then
        self.ArrowManager:Initialize()
    end
    if self.MilestonePanel then
        self.MilestonePanel:Initialize()
    end
    if self.MissingMaterialsPanel then
        self.MissingMaterialsPanel:Initialize()
    end
    if self.RecipeDetails then
        self.RecipeDetails:Initialize()
    end
    if self.PlanningWindow then
        self.PlanningWindow:Initialize()
    end
    if self.ProfessionBrowser then
        self.ProfessionBrowser:Initialize()
    end
    if self.MinimapButton then
        self.MinimapButton:Initialize()
    end

    -- Register events
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("TRADE_SKILL_UPDATE", "OnTradeSkillUpdate")
    self:RegisterEvent("TRADE_SKILL_CLOSE", "OnTradeSkillClose")
    self:RegisterEvent("BAG_UPDATE", "OnBagUpdate")
end

function LazyProf:SlashCommand(input)
    local cmd = strlower(input or "")

    if cmd == "browse" then
        if self.ProfessionBrowser then
            self.ProfessionBrowser:Toggle()
        end
    elseif cmd == "scan" then
        self:Print("AH scanning not yet implemented.")
    elseif cmd == "reset" then
        self.db:ResetDB()
        self:Print("Database reset.")
    elseif cmd == "log" then
        self:ShowDebugLog()
    elseif self.configRegistered then
        LibStub("AceConfigDialog-3.0"):Open("LazyProf")
    else
        self:Print("Commands: /lp | /lp browse | /lp reset | /lp log")
    end
end

function LazyProf:OnTradeSkillShow()
    self:ScheduleRecalculation()
    self:HookTradeSkillScroll()
end

-- Hook scroll frame to update arrow position when scrolling
function LazyProf:HookTradeSkillScroll()
    if self.scrollHooked then return end

    -- Hook the scroll frame's OnVerticalScroll to reposition arrow (debounced)
    if TradeSkillListScrollFrame then
        local origScript = TradeSkillListScrollFrame:GetScript("OnVerticalScroll")
        local scrollTimer = nil
        TradeSkillListScrollFrame:SetScript("OnVerticalScroll", function(self, offset, ...)
            if origScript then
                origScript(self, offset, ...)
            end
            -- Debounce: only refresh after scrolling stops
            if scrollTimer then scrollTimer:Cancel() end
            scrollTimer = C_Timer.After(0.05, function()
                if LazyProf.ArrowManager then
                    LazyProf.ArrowManager:RefreshPosition()
                end
            end)
        end)
        self.scrollHooked = true
    end
end

function LazyProf:OnTradeSkillUpdate()
    -- PERFORMANCE FIX (GitHub Issue #3): Only recalculate when skill actually changes.
    -- TRADE_SKILL_UPDATE fires for many reasons (scrolling, UI refresh, etc).
    -- Full path recalculation is expensive - only do it when the path might change.
    -- DO NOT REVERT THIS to unconditional ScheduleRecalculation() - it causes FPS hitches.
    local _, currentSkill = GetTradeSkillLine()
    if currentSkill and currentSkill ~= self.lastCalculatedSkill then
        self:ScheduleRecalculation()
    end
end

function LazyProf:OnTradeSkillClose()
    if self.ArrowManager then
        self.ArrowManager:Hide()
    end
    if self.MilestonePanel then
        self.MilestonePanel:Hide()
    end
    if self.MissingMaterialsPanel then
        self.MissingMaterialsPanel:Hide()
    end
    if self.RecipeDetails then
        self.RecipeDetails:Hide()
    end
end

function LazyProf:OnBagUpdate()
    -- PERFORMANCE FIX (GitHub Issue #3): Don't trigger full recalculation on bag changes.
    -- Bag changes during crafting don't affect the optimal PATH - only the shopping list
    -- quantities change. Use lightweight RefreshShoppingList() instead of full recalc.
    -- DO NOT REVERT THIS to ScheduleRecalculation() - it causes severe FPS hitches
    -- during batch crafting as reported by users with both old and high-end hardware.
    if TradeSkillFrame and TradeSkillFrame:IsVisible() then
        self:ScheduleShoppingListRefresh()
    end
end

-- Debounced recalculation
local recalcTimer = nil
function LazyProf:ScheduleRecalculation()
    if recalcTimer then return end
    recalcTimer = C_Timer.After(0.5, function()
        recalcTimer = nil
        LazyProf:Recalculate()
    end)
end

-- PERFORMANCE FIX (GitHub Issue #3): Debounced lightweight shopping list refresh.
-- This is separate from full recalculation and only updates material quantities.
local shoppingListTimer = nil
function LazyProf:ScheduleShoppingListRefresh()
    if shoppingListTimer then return end
    shoppingListTimer = C_Timer.After(0.3, function()
        shoppingListTimer = nil
        LazyProf:RefreshShoppingList()
    end)
end

-- PERFORMANCE FIX (GitHub Issue #3): Lightweight refresh that only updates shopping list.
-- This reuses the cached path and only recalculates missing materials based on
-- current inventory. Much cheaper than full Recalculate() which re-runs the
-- entire pathfinding algorithm with recipe scoring.
-- Called on BAG_UPDATE instead of full recalculation.
function LazyProf:RefreshShoppingList()
    local path = self.Pathfinder.currentPath
    if not path or not path.steps or #path.steps == 0 then
        return
    end

    -- Rescan inventory
    local inventory, bankInventory, altInventory, altItemsByCharacter = self.Inventory:ScanAll()

    -- Extract prices from cache (avoid re-querying price providers)
    local prices = {}
    for itemId, cached in pairs(self.PriceManager.cache) do
        prices[itemId] = cached.price
    end

    -- Recalculate only the missing materials using cached path
    path.missingMaterials = self.Pathfinder:CalculateMissingMaterials(
        path.steps, inventory, bankInventory, altInventory, altItemsByCharacter, prices
    )

    -- Update only the shopping list panel (skip arrow and milestone panels)
    if self.MissingMaterialsPanel then
        self.MissingMaterialsPanel:Update(path.missingMaterials)
    end
end

function LazyProf:Recalculate()
    -- Track skill level for OnTradeSkillUpdate optimization (Issue #3)
    local _, currentSkill = GetTradeSkillLine()
    self.lastCalculatedSkill = currentSkill

    -- Invalidate arrow cache before recalculating (recipe may change)
    if self.ArrowManager then
        self.ArrowManager:InvalidateCache()
    end

    local path = self.Pathfinder:Calculate()
    if path then
        self:UpdateDisplay()
    else
        -- No matching profession data - hide panels
        self:HideDisplay()
    end

    -- Also refresh PlanningWindow if visible (it calculates independently)
    if self.PlanningWindow and self.PlanningWindow:IsVisible() then
        self.PlanningWindow:LoadProfession(self.PlanningWindow.currentProfession)
    end
end

function LazyProf:HideDisplay()
    if self.ArrowManager then
        self.ArrowManager:Hide()
    end
    if self.MilestonePanel then
        self.MilestonePanel:Hide()
    end
    if self.MissingMaterialsPanel then
        self.MissingMaterialsPanel:Hide()
    end
end

function LazyProf:UpdateDisplay()
    local path = self.Pathfinder.currentPath
    if path then
        if self.ArrowManager then
            self.ArrowManager:Update(path)
        end
        if self.MilestonePanel then
            self.MilestonePanel:Update(path)
        end
        if self.MissingMaterialsPanel then
            self.MissingMaterialsPanel:Update(path.missingMaterials)
        end
    end
end

-- Debug log buffer
LazyProf.debugLog = {}
LazyProf.debugLogMax = 500
LazyProf.debugFilter = nil  -- nil = show all, or category name

-- Category display names for UI
LazyProf.debugCategoryNames = {
    scoring = "Pathfinder Scoring",
    pathfinder = "Pathfinder Core",
    ui = "UI Updates",
    professions = "Professions",
    pricing = "Pricing",
    arrow = "Arrow",
}

LazyProf.debugScoringBracket = nil  -- nil = show all, or bracket index
LazyProf.skillBrackets = {
    {min = 1, max = 75, name = "1-75 (Apprentice)"},
    {min = 75, max = 150, name = "75-150 (Journeyman)"},
    {min = 150, max = 225, name = "150-225 (Expert)"},
    {min = 225, max = 300, name = "225-300 (Artisan)"},
    {min = 300, max = 375, name = "300-375 (Master)"},
}

function LazyProf:Debug(category, msg)
    -- Backwards compatibility: single arg = message with "pathfinder" category
    if msg == nil then
        msg = category
        category = "pathfinder"
    end

    if not self.db or not self.db.profile.debug then
        return
    end

    -- Check if this category is enabled
    if not self.db.profile.debugCategories[category] then
        return
    end

    local timestamp = date("%H:%M:%S")

    -- Store with category for filtering
    table.insert(self.debugLog, {
        timestamp = timestamp,
        category = category,
        message = msg,
    })
    if #self.debugLog > self.debugLogMax then
        table.remove(self.debugLog, 1)
    end

    -- Auto-update debug window if visible
    if self.debugFrame and self.debugFrame:IsShown() then
        self:UpdateDebugWindowContent()
    end
    -- No chat output - use /lp log to view logs
end

-- Get filtered debug log entries
function LazyProf:GetFilteredDebugLog()
    local filtered = {}
    local currentSkill = nil
    for _, entry in ipairs(self.debugLog) do
        if not self.debugFilter or entry.category == self.debugFilter then
            -- Apply scoring bracket filter if active
            if self.debugFilter == "scoring" and self.debugScoringBracket then
                local bracket = self.skillBrackets[self.debugScoringBracket]
                if bracket then
                    local skill = tonumber(entry.message:match("Scoring candidates at skill (%d+%.?%d*)"))
                        or tonumber(entry.message:match("No candidates at skill (%d+%.?%d*)"))
                    if skill then
                        currentSkill = math.floor(skill)
                    end
                    if currentSkill and currentSkill >= bracket.min and currentSkill <= bracket.max then
                        table.insert(filtered, entry)
                    end
                end
            else
                table.insert(filtered, entry)
            end
        end
    end
    return filtered
end

-- Format debug log entries as text
function LazyProf:FormatDebugLog(entries)
    local lines = {}
    for _, entry in ipairs(entries) do
        local catDisplay = self.debugCategoryNames[entry.category] or entry.category
        table.insert(lines, string.format("[%s] [%s] %s", entry.timestamp, catDisplay, entry.message))
    end
    return table.concat(lines, "\n")
end

-- Update debug window content (respects filter)
function LazyProf:UpdateDebugWindowContent()
    if not self.debugFrame then return end

    local filtered = self:GetFilteredDebugLog()
    local text = self:FormatDebugLog(filtered)

    if text == "" then
        if self.debugFilter then
            local catName = self.debugCategoryNames[self.debugFilter] or self.debugFilter
            if self.debugScoringBracket and self.skillBrackets[self.debugScoringBracket] then
                text = "(No messages in " .. catName .. " for skill " .. self.skillBrackets[self.debugScoringBracket].name .. ")"
            else
                text = "(No messages in category: " .. catName .. ")"
            end
        else
            text = "(No debug messages yet. Enable debug mode and perform actions.)"
        end
    end

    self.debugFrame.editBox:SetText(text)

    -- Update count display
    if self.debugFrame.countText then
        if self.debugFilter then
            self.debugFrame.countText:SetText(string.format("Showing %d of %d", #filtered, #self.debugLog))
        else
            self.debugFrame.countText:SetText(string.format("%d messages", #self.debugLog))
        end
    end

    -- Scroll to bottom
    C_Timer.After(0.01, function()
        if self.debugFrame and self.debugFrame.scrollFrame then
            self.debugFrame.scrollFrame:SetVerticalScroll(self.debugFrame.scrollFrame:GetVerticalScrollRange())
        end
    end)
end

function LazyProf:ClearDebugLog()
    wipe(self.debugLog)
    if self.debugFrame and self.debugFrame:IsShown() then
        self:UpdateDebugWindowContent()
    end
    self:Print("Debug log cleared.")
end

function LazyProf:ShowDebugLog()
    if not self.debugFrame then
        self:CreateDebugFrame()
    end

    -- Update content
    self:UpdateDebugWindowContent()
    self.debugFrame:Show()
end

function LazyProf:CreateDebugFrame()
    local frame = CreateFrame("Frame", "LazyProfDebugFrame", UIParent, "BackdropTemplate")
    frame:SetSize(700, 450)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    -- Title
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 10, -10)
    frame.title:SetText("LazyProf Debug Log")
    frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    frame.closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Filter dropdown
    frame.filterDropdown = CreateFrame("Frame", "LazyProfDebugFilterDropdown", frame, "UIDropDownMenuTemplate")
    frame.filterDropdown:SetPoint("TOPLEFT", 100, -3)
    UIDropDownMenu_SetWidth(frame.filterDropdown, 150)

    local function FilterDropdown_Initialize(dropdown, level)
        local info = UIDropDownMenu_CreateInfo()

        -- "All Categories" option
        info.text = "All Categories"
        info.value = nil
        info.checked = (LazyProf.debugFilter == nil)
        info.func = function()
            LazyProf.debugFilter = nil
            UIDropDownMenu_SetText(dropdown, "All Categories")
            LazyProf.debugScoringBracket = nil
            if frame.bracketDropdown then
                frame.bracketDropdown:Hide()
                UIDropDownMenu_SetText(frame.bracketDropdown, "All Skill Levels")
            end
            LazyProf:UpdateDebugWindowContent()
        end
        UIDropDownMenu_AddButton(info, level)

        -- Separator
        info = UIDropDownMenu_CreateInfo()
        info.disabled = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Category options
        local categories = {"scoring", "pathfinder", "ui", "professions", "pricing", "arrow"}
        for _, cat in ipairs(categories) do
            info = UIDropDownMenu_CreateInfo()
            info.text = LazyProf.debugCategoryNames[cat]
            info.value = cat
            info.checked = (LazyProf.debugFilter == cat)
            info.func = function()
                LazyProf.debugFilter = cat
                UIDropDownMenu_SetText(dropdown, LazyProf.debugCategoryNames[cat])
                if frame.bracketDropdown then
                    if cat == "scoring" then
                        frame.bracketDropdown:Show()
                    else
                        frame.bracketDropdown:Hide()
                        LazyProf.debugScoringBracket = nil
                        UIDropDownMenu_SetText(frame.bracketDropdown, "All Skill Levels")
                    end
                end
                LazyProf:UpdateDebugWindowContent()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(frame.filterDropdown, FilterDropdown_Initialize)
    UIDropDownMenu_SetText(frame.filterDropdown, "All Categories")

    -- Skill bracket dropdown (visible only when Pathfinder Scoring filter is active)
    frame.bracketDropdown = CreateFrame("Frame", "LazyProfDebugBracketDropdown", frame, "UIDropDownMenuTemplate")
    frame.bracketDropdown:SetPoint("LEFT", frame.filterDropdown, "RIGHT", -15, 0)
    UIDropDownMenu_SetWidth(frame.bracketDropdown, 150)

    local function BracketDropdown_Initialize(dropdown, level)
        local info = UIDropDownMenu_CreateInfo()

        info.text = "All Skill Levels"
        info.value = nil
        info.checked = (LazyProf.debugScoringBracket == nil)
        info.func = function()
            LazyProf.debugScoringBracket = nil
            UIDropDownMenu_SetText(dropdown, "All Skill Levels")
            LazyProf:UpdateDebugWindowContent()
        end
        UIDropDownMenu_AddButton(info, level)

        for i, bracket in ipairs(LazyProf.skillBrackets) do
            info = UIDropDownMenu_CreateInfo()
            info.text = bracket.name
            info.value = i
            info.checked = (LazyProf.debugScoringBracket == i)
            info.func = function()
                LazyProf.debugScoringBracket = i
                UIDropDownMenu_SetText(dropdown, bracket.name)
                LazyProf:UpdateDebugWindowContent()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(frame.bracketDropdown, BracketDropdown_Initialize)
    UIDropDownMenu_SetText(frame.bracketDropdown, "All Skill Levels")
    frame.bracketDropdown:Hide()

    -- Message count display
    frame.countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.countText:SetPoint("TOPRIGHT", frame.closeBtn, "TOPLEFT", -10, -8)
    frame.countText:SetTextColor(0.7, 0.7, 0.7)

    -- Bottom buttons
    -- Clear button
    frame.clearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.clearBtn:SetSize(60, 22)
    frame.clearBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    frame.clearBtn:SetText("Clear")
    frame.clearBtn:SetScript("OnClick", function()
        LazyProf:ClearDebugLog()
    end)

    -- Copy Filtered button
    frame.copyFilteredBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.copyFilteredBtn:SetSize(100, 22)
    frame.copyFilteredBtn:SetPoint("RIGHT", frame.clearBtn, "LEFT", -5, 0)
    frame.copyFilteredBtn:SetText("Copy Filtered")
    frame.copyFilteredBtn:SetScript("OnClick", function()
        -- Get only filtered content
        local filtered = LazyProf:GetFilteredDebugLog()
        local text = LazyProf:FormatDebugLog(filtered)
        frame.editBox:SetText(text)
        frame.editBox:SetFocus()
        frame.editBox:HighlightText()
        LazyProf:Print("Filtered text selected (" .. #filtered .. " messages) - press Ctrl+C to copy")
    end)

    -- Copy All button
    frame.copyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.copyBtn:SetSize(80, 22)
    frame.copyBtn:SetPoint("RIGHT", frame.copyFilteredBtn, "LEFT", -5, 0)
    frame.copyBtn:SetText("Copy All")
    frame.copyBtn:SetScript("OnClick", function()
        -- Show all content temporarily for copying
        local text = LazyProf:FormatDebugLog(LazyProf.debugLog)
        frame.editBox:SetText(text)
        frame.editBox:SetFocus()
        frame.editBox:HighlightText()
        LazyProf:Print("All text selected (" .. #LazyProf.debugLog .. " messages) - press Ctrl+C to copy")
        -- Restore filtered view after a moment
        C_Timer.After(0.1, function()
            if not frame.editBox:HasFocus() then
                LazyProf:UpdateDebugWindowContent()
            end
        end)
    end)

    -- Scroll frame
    frame.scrollFrame = CreateFrame("ScrollFrame", "LazyProfDebugScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", 10, -35)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)

    -- EditBox for text (selectable, copyable)
    frame.editBox = CreateFrame("EditBox", nil, frame.scrollFrame)
    frame.editBox:SetMultiLine(true)
    frame.editBox:SetFontObject(GameFontHighlightSmall)
    frame.editBox:SetWidth(frame.scrollFrame:GetWidth())
    frame.editBox:SetAutoFocus(false)
    frame.editBox:EnableMouse(true)
    frame.editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.scrollFrame:SetScrollChild(frame.editBox)

    tinsert(UISpecialFrames, "LazyProfDebugFrame")
    self.debugFrame = frame
end
