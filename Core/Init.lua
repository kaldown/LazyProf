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

    -- Register events
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("TRADE_SKILL_UPDATE", "OnTradeSkillUpdate")
    self:RegisterEvent("TRADE_SKILL_CLOSE", "OnTradeSkillClose")
    self:RegisterEvent("BAG_UPDATE", "OnBagUpdate")
end

function LazyProf:SlashCommand(input)
    if input == "scan" then
        self:Print("AH scanning not yet implemented.")
    elseif input == "reset" then
        self.db:ResetDB()
        self:Print("Database reset.")
    elseif input == "plan" then
        if self.PlanningWindow then
            self.PlanningWindow:Open("engineering")
        end
    elseif input == "browse" then
        if self.ProfessionBrowser then
            self.ProfessionBrowser:Toggle()
        end
    elseif self.configRegistered then
        LibStub("AceConfigDialog-3.0"):Open("LazyProf")
    else
        self:Print("Commands: /lp scan | /lp reset | /lp plan | /lp browse | /lp debug")
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

function LazyProf:Debug(msg)
    if self.db and self.db.profile.debug then
        self:Print("[Debug] " .. msg)
    end
end
