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
    self:Print("LazyProf v" .. version .. " loaded. Type /lp for options.")
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
    elseif cmd == "debuglog" then
        self:ShowDebugLog()
    elseif self.configRegistered then
        LibStub("AceConfigDialog-3.0"):Open("LazyProf")
    else
        self:Print("Commands: /lp | /lp browse | /lp reset | /lp debuglog")
    end
end

function LazyProf:OnTradeSkillShow()
    self:ScheduleRecalculation()
    self:HookTradeSkillScroll()
end

-- Hook scroll frame to update arrow position when scrolling
function LazyProf:HookTradeSkillScroll()
    if self.scrollHooked then return end

    -- Hook the scroll frame's OnVerticalScroll to reposition arrow
    if TradeSkillListScrollFrame then
        local origScript = TradeSkillListScrollFrame:GetScript("OnVerticalScroll")
        TradeSkillListScrollFrame:SetScript("OnVerticalScroll", function(self, offset, ...)
            if origScript then
                origScript(self, offset, ...)
            end
            -- Update arrow position after scroll (without full recalculation)
            if LazyProf.ArrowManager and LazyProf.Pathfinder.currentPath then
                LazyProf.ArrowManager:Update(LazyProf.Pathfinder.currentPath)
            end
        end)
        self.scrollHooked = true
    end
end

function LazyProf:OnTradeSkillUpdate()
    self:ScheduleRecalculation()
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
    if TradeSkillFrame and TradeSkillFrame:IsVisible() then
        self:ScheduleRecalculation()
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

function LazyProf:Recalculate()
    local path = self.Pathfinder:Calculate()
    if path then
        self:UpdateDisplay()
    else
        -- No matching profession data - hide panels
        self:HideDisplay()
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
            self.MilestonePanel:Update(path.milestoneBreakdown, path.totalCost)
        end
        if self.MissingMaterialsPanel then
            self.MissingMaterialsPanel:Update(path.missingMaterials)
        end
    end
end

-- Debug log buffer
LazyProf.debugLog = {}
LazyProf.debugLogMax = 500

function LazyProf:Debug(msg)
    if self.db and self.db.profile.debug then
        local timestamp = date("%H:%M:%S")
        local entry = string.format("[%s] %s", timestamp, msg)

        -- Store in buffer
        table.insert(self.debugLog, entry)
        if #self.debugLog > self.debugLogMax then
            table.remove(self.debugLog, 1)
        end

        -- Auto-update debug window if visible (don't spam chat)
        if self.debugFrame and self.debugFrame:IsShown() then
            local text = table.concat(self.debugLog, "\n")
            self.debugFrame.editBox:SetText(text)
            -- Scroll to bottom
            C_Timer.After(0.01, function()
                if self.debugFrame and self.debugFrame.scrollFrame then
                    self.debugFrame.scrollFrame:SetVerticalScroll(self.debugFrame.scrollFrame:GetVerticalScrollRange())
                end
            end)
        else
            -- Only print to chat if debug window is not open
            self:Print("[Debug] " .. msg)
        end
    end
end

function LazyProf:ClearDebugLog()
    wipe(self.debugLog)
    self:Print("Debug log cleared.")
end

function LazyProf:ShowDebugLog()
    if not self.debugFrame then
        self:CreateDebugFrame()
    end

    -- Update content
    local text = table.concat(self.debugLog, "\n")
    if text == "" then
        text = "(No debug messages yet. Enable debug mode and perform actions.)"
    end
    self.debugFrame.editBox:SetText(text)
    self.debugFrame.editBox:SetCursorPosition(#text) -- Scroll to bottom
    self.debugFrame:Show()
end

function LazyProf:CreateDebugFrame()
    local frame = CreateFrame("Frame", "LazyProfDebugFrame", UIParent, "BackdropTemplate")
    frame:SetSize(600, 400)
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
    frame.title:SetPoint("TOP", 0, -10)
    frame.title:SetText("LazyProf Debug Log (Ctrl+A to select all, Ctrl+C to copy)")
    frame.title:SetTextColor(1, 0.82, 0)

    -- Close button
    frame.closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Clear button
    frame.clearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.clearBtn:SetSize(60, 22)
    frame.clearBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    frame.clearBtn:SetText("Clear")
    frame.clearBtn:SetScript("OnClick", function()
        LazyProf:ClearDebugLog()
        frame.editBox:SetText("(Log cleared)")
    end)

    -- Scroll frame
    frame.scrollFrame = CreateFrame("ScrollFrame", "LazyProfDebugScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", 10, -30)
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
