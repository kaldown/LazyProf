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
    self.db = LibStub("AceDB-3.0"):New("LazyProfDB", self.defaults, true)
    self:RegisterChatCommand("lazyprof", "SlashCommand")
    self:RegisterChatCommand("lp", "SlashCommand")
    if self.SetupConfig then
        self:SetupConfig()
    end
    self:Print("LazyProf v0.1.0 loaded. Type /lp for options.")
end

function LazyProf:OnEnable()
    -- Initialize modules
    if self.PriceManager then
        self.PriceManager:Initialize()
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
    elseif self.configRegistered then
        LibStub("AceConfigDialog-3.0"):Open("LazyProf")
    else
        self:Print("Commands: /lp scan | /lp reset | /lp debug")
    end
end

function LazyProf:OnTradeSkillShow()
    self:ScheduleRecalculation()
end

function LazyProf:OnTradeSkillUpdate()
    self:ScheduleRecalculation()
end

function LazyProf:OnTradeSkillClose()
    if self.ArrowManager then
        self.ArrowManager:Hide()
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
    -- Will be implemented in later tasks
    self:Debug("Recalculate triggered")
end

function LazyProf:Debug(msg)
    if self.db and self.db.profile.debug then
        self:Print("[Debug] " .. msg)
    end
end
