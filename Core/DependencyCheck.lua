-- Core/DependencyCheck.lua
-- Early dependency check before addon initialization
local ADDON_NAME, LazyProf = ...

-- Flag to indicate if dependency check failed
LazyProf.dependencyCheckFailed = false

-- Check CraftLib. Returns nil when it is loaded and ready, else the name of
-- the popup that explains why LazyProf cannot run:
--   LAZYPROF_UNSUPPORTED_CLIENT - CraftLib is installed but has no profile
--                                 (no recipe data) for this game client;
--   LAZYPROF_MISSING_CRAFTLIB   - CraftLib is not installed (or not ready).
local function CheckCraftLib()
    local CraftLib = _G.CraftLib

    if CraftLib and type(CraftLib.IsReady) == "function" then
        if type(CraftLib.GetActiveProfile) == "function" and CraftLib:GetActiveProfile() == nil then
            return "LAZYPROF_UNSUPPORTED_CLIENT"
        end
        if CraftLib:IsReady() then
            return nil
        end
    end

    return "LAZYPROF_MISSING_CRAFTLIB"
end

-- Define the static popup dialogs
StaticPopupDialogs["LAZYPROF_MISSING_CRAFTLIB"] = {
    text = "LazyProf requires the CraftLib addon to function.\n\nPlease install CraftLib from CurseForge and reload your UI.",
    button1 = "Okay",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["LAZYPROF_UNSUPPORTED_CLIENT"] = {
    text = "LazyProf: CraftLib has no recipe data for this game client.",
    button1 = "Okay",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Run the check
local failedPopup = CheckCraftLib()
if failedPopup then
    LazyProf.dependencyCheckFailed = true

    -- Show popup after a short delay to ensure UI is ready
    C_Timer.After(1, function()
        StaticPopup_Show(failedPopup)
    end)
end
