-- Modules/UI/PlanningWindow.lua
-- Standalone planning window for viewing any profession's leveling path
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils
local Constants = LazyProf.Constants

LazyProf.PlanningWindow = {}
local PlanningWindow = LazyProf.PlanningWindow

PlanningWindow.frame = nil
PlanningWindow.currentProfession = nil
PlanningWindow.currentPath = nil
PlanningWindow.milestonePanel = nil  -- Embedded MilestonePanel instance

local DEFAULT_WIDTH = 420
local DEFAULT_HEIGHT = 500

function PlanningWindow:Initialize()
    self.frame = CreateFrame("Frame", "LazyProfPlanningWindow", UIParent, "BackdropTemplate")
    self.frame:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
    self.frame:SetPoint("CENTER")
    self.frame:SetFrameStrata("HIGH")
    self.frame:SetFrameLevel(100)

    -- Solid dark background
    self.frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    self.frame:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
    self.frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    self.frame:EnableMouse(true)
    self.frame:SetMovable(true)
    self.frame:SetResizable(true)
    self.frame:SetClampedToScreen(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    self.frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)

    if self.frame.SetResizeBounds then
        self.frame:SetResizeBounds(380, 300, 600, 800)
    else
        self.frame:SetMinResize(380, 300)
        self.frame:SetMaxResize(600, 800)
    end

    self.frame:Hide()

    -- Title bar
    self.frame.titleBg = self.frame:CreateTexture(nil, "ARTWORK")
    self.frame.titleBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.titleBg:SetVertexColor(0.2, 0.2, 0.2, 1)
    self.frame.titleBg:SetPoint("TOPLEFT", 4, -4)
    self.frame.titleBg:SetPoint("TOPRIGHT", -4, -4)
    self.frame.titleBg:SetHeight(28)

    -- Title text
    self.frame.title = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.frame.title:SetPoint("LEFT", self.frame.titleBg, "LEFT", 10, 0)
    self.frame.title:SetText("Planning Mode")
    self.frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    self.frame.closeBtn = CreateFrame("Button", nil, self.frame, "UIPanelCloseButton")
    self.frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    self.frame.closeBtn:SetSize(24, 24)
    self.frame.closeBtn:SetScript("OnClick", function() self:Hide() end)

    -- Status banner
    self.frame.statusBg = self.frame:CreateTexture(nil, "ARTWORK")
    self.frame.statusBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.statusBg:SetVertexColor(0.15, 0.15, 0.15, 1)
    self.frame.statusBg:SetPoint("TOPLEFT", 4, -36)
    self.frame.statusBg:SetPoint("TOPRIGHT", -4, -36)
    self.frame.statusBg:SetHeight(22)

    self.frame.status = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.frame.status:SetPoint("LEFT", self.frame.statusBg, "LEFT", 8, 0)
    self.frame.status:SetTextColor(0.7, 0.7, 0.7)

    -- Search box
    self.frame.searchBox = CreateFrame("EditBox", nil, self.frame, "InputBoxTemplate")
    self.frame.searchBox:SetSize(DEFAULT_WIDTH - 52, 22)
    self.frame.searchBox:SetPoint("TOPLEFT", 12, -64)
    self.frame.searchBox:SetPoint("RIGHT", self.frame, "RIGHT", -40, 0)
    self.frame.searchBox:SetAutoFocus(false)
    self.frame.searchBox:SetFontObject("GameFontHighlightSmall")
    self.frame.searchBox:SetMaxLetters(50)

    -- Placeholder text
    self.frame.searchBox.placeholder = self.frame.searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.frame.searchBox.placeholder:SetPoint("LEFT", self.frame.searchBox, "LEFT", 6, 0)
    self.frame.searchBox.placeholder:SetText("Search recipes...")
    self.frame.searchBox.placeholder:SetTextColor(0.5, 0.5, 0.5)

    -- Clear button
    self.frame.clearBtn = CreateFrame("Button", nil, self.frame)
    self.frame.clearBtn:SetSize(20, 20)
    self.frame.clearBtn:SetPoint("LEFT", self.frame.searchBox, "RIGHT", 4, 0)
    self.frame.clearBtn.text = self.frame.clearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.frame.clearBtn.text:SetPoint("CENTER")
    self.frame.clearBtn.text:SetText("x")
    self.frame.clearBtn.text:SetTextColor(0.7, 0.7, 0.7)
    self.frame.clearBtn:Hide()

    self.frame.clearBtn:SetScript("OnClick", function()
        self.frame.searchBox:SetText("")
        self.frame.searchBox:ClearFocus()
    end)

    -- Search box scripts
    self.frame.searchBox:SetScript("OnTextChanged", function(editBox, userInput)
        local text = editBox:GetText()
        local hasText = text and text ~= ""
        self.frame.searchBox.placeholder:SetShown(not hasText)
        self.frame.clearBtn:SetShown(hasText)
        if userInput then
            self:UpdateSearchResults(text)
        end
    end)

    self.frame.searchBox:SetScript("OnEscapePressed", function(editBox)
        if editBox:GetText() ~= "" then
            editBox:SetText("")
        end
        editBox:ClearFocus()
    end)

    -- Search results container (sibling to contentContainer, same anchoring)
    self.frame.searchContainer = CreateFrame("Frame", nil, self.frame)
    self.frame.searchContainer:SetPoint("TOPLEFT", 4, -90)
    self.frame.searchContainer:SetPoint("BOTTOMRIGHT", -4, 4)
    self.frame.searchContainer:Hide()

    -- Search results scroll frame
    self.frame.searchScroll = CreateFrame("ScrollFrame", "LazyProfPlanningSearchScroll", self.frame.searchContainer, "UIPanelScrollFrameTemplate")
    self.frame.searchScroll:SetPoint("TOPLEFT", 4, -4)
    self.frame.searchScroll:SetPoint("BOTTOMRIGHT", -24, 28)

    -- Search results content frame
    self.frame.searchContent = CreateFrame("Frame", nil, self.frame.searchScroll)
    self.frame.searchContent:SetSize(DEFAULT_WIDTH - 40, 400)
    self.frame.searchScroll:SetScrollChild(self.frame.searchContent)

    -- Footer bar for result count
    self.frame.searchFooterBg = self.frame.searchContainer:CreateTexture(nil, "ARTWORK")
    self.frame.searchFooterBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.searchFooterBg:SetVertexColor(0.15, 0.15, 0.15, 1)
    self.frame.searchFooterBg:SetPoint("BOTTOMLEFT", 4, 4)
    self.frame.searchFooterBg:SetPoint("BOTTOMRIGHT", -4, 4)
    self.frame.searchFooterBg:SetHeight(24)

    self.frame.searchFooter = self.frame.searchContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.frame.searchFooter:SetPoint("BOTTOMRIGHT", -12, 12)
    self.frame.searchFooter:SetTextColor(0.5, 0.5, 0.5)

    -- "No results" message
    self.frame.searchEmpty = self.frame.searchContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.frame.searchEmpty:SetPoint("CENTER", self.frame.searchContainer, "CENTER", 0, 20)
    self.frame.searchEmpty:SetText("No recipes found")
    self.frame.searchEmpty:SetTextColor(0.5, 0.5, 0.5)
    self.frame.searchEmpty:Hide()

    -- Row pool for search results
    self.searchRows = {}

    -- Container frame for embedded MilestonePanel
    self.frame.contentContainer = CreateFrame("Frame", nil, self.frame)
    self.frame.contentContainer:SetPoint("TOPLEFT", 4, -90)
    self.frame.contentContainer:SetPoint("BOTTOMRIGHT", -4, 4)

    -- Create embedded MilestonePanel instance (with bracket dropdown and mode toggle)
    self.milestonePanel = LazyProf.MilestonePanelClass:New({
        name = "Planning",
        embedded = true,
        showBracketDropdown = true,
        showModeToggle = true,
        parent = self.frame.contentContainer
    })
    self.milestonePanel:Initialize()

    -- Resize handle
    self.frame.resizeBtn = CreateFrame("Button", nil, self.frame)
    self.frame.resizeBtn:SetSize(32, 32)
    self.frame.resizeBtn:SetPoint("BOTTOMRIGHT", 0, 0)
    self.frame.resizeBtn:SetFrameStrata("DIALOG")
    self.frame.resizeBtn:SetNormalTexture("Interface\\Buttons\\WHITE8x8")
    self.frame.resizeBtn:GetNormalTexture():SetVertexColor(0, 0, 0, 0.01)
    self.frame.resizeBtn.icon = self.frame.resizeBtn:CreateTexture(nil, "OVERLAY")
    self.frame.resizeBtn.icon:SetPoint("BOTTOMRIGHT", 0, 0)
    self.frame.resizeBtn.icon:SetSize(16, 16)
    self.frame.resizeBtn.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    self.frame.resizeBtn:SetScript("OnMouseDown", function(btn, button)
        if button == "LeftButton" then
            self.frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    self.frame.resizeBtn:SetScript("OnMouseUp", function()
        self.frame:StopMovingOrSizing()
        -- Refresh the embedded panel after resize
        if self.milestonePanel then
            self.milestonePanel:Refresh()
        end
        -- Update search content width on resize
        if self.frame.searchContent then
            self.frame.searchContent:SetWidth(self.frame:GetWidth() - 40)
        end
    end)

    -- Make closable with Escape
    tinsert(UISpecialFrames, "LazyProfPlanningWindow")

    -- Combat lockdown: auto-hide during combat, restore after
    Utils.AddCombatLockdown(self.frame)
end

function PlanningWindow:Open(profKey)
    if InCombatLockdown() then return end

    if not self.frame then
        self:Initialize()
    end

    -- Show the main frame FIRST so child frames can become visible
    self.frame:Show()
    -- Then load the profession (which updates the embedded MilestonePanel)
    self:LoadProfession(profKey)
end

function PlanningWindow:LoadProfession(profKey)
    self.currentProfession = profKey

    -- Clear any active search
    if self.frame and self.frame.searchBox then
        self.frame.searchBox:SetText("")
        self.frame.searchBox:ClearFocus()
    end

    local profInfo = Constants.PROFESSIONS[profKey]
    if not profInfo then
        LazyProf:Print("Unknown profession: " .. tostring(profKey))
        return
    end

    -- Update title
    self.frame.title:SetText("Planning: " .. profInfo.name)

    -- Check if player has this profession
    local actualSkillLevel = self:GetPlayerSkillLevel(profKey)

    -- Determine starting skill based on calculateFromCurrentSkill setting
    local startSkill
    if LazyProf.db.profile.calculateFromCurrentSkill then
        startSkill = actualSkillLevel
    else
        startSkill = 0  -- CalculateForProfession will use max(1, skillLevel)
    end

    -- Check for racial bonus
    local racialBonus = Utils.GetRacialProfessionBonus(profKey)
    local racialText = ""
    if racialBonus > 0 then
        local race = Utils.GetPlayerRace()
        racialText = string.format(" |cFFFFD700(+%d %s)|r", racialBonus, race)
    end

    -- Update status bar with mode indicator and racial bonus
    if actualSkillLevel > 0 then
        if LazyProf.db.profile.calculateFromCurrentSkill then
            self.frame.status:SetText(string.format("Path from current skill: %d%s", actualSkillLevel, racialText))
        else
            self.frame.status:SetText(string.format("Current skill: %d%s |cFF888888(showing full path)|r", actualSkillLevel, racialText))
        end
        self.frame.status:SetTextColor(0.4, 1, 0.4)
    else
        if racialBonus > 0 then
            self.frame.status:SetText(string.format("You have not learned this profession%s |cFF888888(showing full path)|r", racialText))
        else
            self.frame.status:SetText("You have not learned this profession |cFF888888(showing full path)|r")
        end
        self.frame.status:SetTextColor(0.7, 0.7, 0.7)
    end

    -- Calculate path
    LazyProf:Debug("ui", "=== PlanningWindow:LoadProfession ===")
    LazyProf:Debug("ui", "  profKey: " .. tostring(profKey))
    LazyProf:Debug("ui", "  startSkill: " .. tostring(startSkill))

    self.currentPath = LazyProf.Pathfinder:CalculateForProfession(profKey, startSkill)

    LazyProf:Debug("ui", "  currentPath: " .. (self.currentPath and "exists" or "NIL"))
    if self.currentPath then
        LazyProf:Debug("ui", "  currentPath.milestoneBreakdown: " .. (self.currentPath.milestoneBreakdown and ("#" .. #self.currentPath.milestoneBreakdown .. " steps") or "NIL"))
    end
    LazyProf:Debug("ui", "  milestonePanel: " .. (self.milestonePanel and "exists" or "NIL"))
    if self.milestonePanel then
        LazyProf:Debug("ui", "  milestonePanel.frame: " .. (self.milestonePanel.frame and "exists" or "NIL"))
    end

    -- Update the embedded MilestonePanel
    if self.currentPath and self.milestonePanel then
        LazyProf:Debug("ui", "  Calling milestonePanel:Update()")
        self.milestonePanel:Update(self.currentPath)
        LazyProf:Debug("ui", "  After Update - frame visible: " .. tostring(self.milestonePanel.frame and self.milestonePanel.frame:IsVisible()))
    else
        LazyProf:Debug("ui", "  SKIPPED Update - missing path or panel")
    end
end

function PlanningWindow:GetPlayerSkillLevel(profKey)
    local profInfo = Constants.PROFESSIONS[profKey]
    if not profInfo then return 0 end

    local targetName = profInfo.name:lower()

    -- Classic/TBC uses GetSkillLineInfo instead of GetProfessions
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank = GetSkillLineInfo(i)
        if not isHeader and skillName and skillName:lower() == targetName then
            return skillRank or 0
        end
    end

    return 0
end

function PlanningWindow:Hide()
    if InCombatLockdown() then return end

    if self.frame then
        self.frame:Hide()
    end
    if self.milestonePanel then
        self.milestonePanel:Hide()
    end
end

function PlanningWindow:IsVisible()
    return self.frame and self.frame:IsVisible()
end

local SEARCH_ROW_HEIGHT = 20

-- Create or reuse a search result row
function PlanningWindow:GetSearchRow(index)
    if self.searchRows[index] then
        self.searchRows[index]:SetWidth(self.frame.searchContent:GetWidth())
        return self.searchRows[index]
    end

    local row = CreateFrame("Button", nil, self.frame.searchContent)
    row:SetSize(self.frame.searchContent:GetWidth(), SEARCH_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * SEARCH_ROW_HEIGHT)

    -- Hover highlight
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.highlight:SetVertexColor(0.3, 0.3, 0.3, 0.5)
    row.highlight:Hide()

    -- Recipe name (left)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -100, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Skill requirement (right)
    row.skill = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.skill:SetPoint("RIGHT", -8, 0)
    row.skill:SetJustifyH("RIGHT")
    row.skill:SetTextColor(0.6, 0.6, 0.6)

    row:SetScript("OnEnter", function(self)
        self.highlight:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self.highlight:Hide()
    end)

    row:SetScript("OnClick", function(self)
        if self.recipe and LazyProf.RecipeDetails then
            LazyProf.RecipeDetails:Show(self.recipe)
        end
    end)

    self.searchRows[index] = row
    return row
end

function PlanningWindow:UpdateSearchResults(query)
    if not query or query == "" then
        -- Clear search: show milestones, hide results
        self.frame.searchContainer:Hide()
        self.frame.contentContainer:Show()
        if self.milestonePanel and self.milestonePanel.frame then
            self.milestonePanel.frame:Show()
        end
        return
    end

    -- Query CraftLib
    local profKey = self.currentProfession
    if not profKey then return end

    local CraftLib = _G.CraftLib
    if not CraftLib then return end

    -- Hide milestones, show search (after validation so we don't blank the screen)
    self.frame.contentContainer:Hide()
    self.frame.searchContainer:Show()

    local allRecipes = CraftLib:GetRecipes(profKey)
    local queryLower = query:lower()

    -- Filter and sort
    local matches = {}
    for _, recipe in ipairs(allRecipes) do
        if recipe.name and string.find(recipe.name:lower(), queryLower, 1, true) then
            table.insert(matches, recipe)
        end
    end

    table.sort(matches, function(a, b)
        return (a.skillRequired or 0) < (b.skillRequired or 0)
    end)

    -- Hide all existing rows
    for _, row in ipairs(self.searchRows) do
        row:Hide()
    end

    -- Show "no results" or populate rows
    if #matches == 0 then
        self.frame.searchEmpty:Show()
        self.frame.searchScroll:Hide()
        self.frame.searchFooter:SetText("")
    else
        self.frame.searchEmpty:Hide()
        self.frame.searchScroll:Show()

        for i, recipe in ipairs(matches) do
            local row = self:GetSearchRow(i)
            row.recipe = recipe
            row.name:SetText(recipe.name)
            row.skill:SetText("Requires " .. (recipe.skillRequired or "?"))
            row:Show()
        end

        -- Update content height for scrolling
        self.frame.searchContent:SetHeight(#matches * SEARCH_ROW_HEIGHT)

        -- Footer
        self.frame.searchFooter:SetText(#matches .. " result" .. (#matches ~= 1 and "s" or ""))
    end
end
