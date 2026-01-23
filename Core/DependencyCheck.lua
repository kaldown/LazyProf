-- Core/DependencyCheck.lua
-- Early dependency check before addon initialization
local ADDON_NAME, LazyProf = ...

-- Flag to indicate if dependency check failed
LazyProf.dependencyCheckFailed = false

-- Check if CraftLib addon is loaded
local function CheckCraftLib()
    local CraftLib = _G.CraftLib

    -- Check if CraftLib global exists and is ready
    if CraftLib and type(CraftLib.IsReady) == "function" and CraftLib:IsReady() then
        return true
    end

    return false
end

-- Define the static popup dialog
StaticPopupDialogs["LAZYPROF_MISSING_CRAFTLIB"] = {
    text = "LazyProf requires the CraftLib addon to function.\n\nPlease install CraftLib from CurseForge and reload your UI.",
    button1 = "Okay",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Run the check
if not CheckCraftLib() then
    LazyProf.dependencyCheckFailed = true

    -- Show popup after a short delay to ensure UI is ready
    C_Timer.After(1, function()
        StaticPopup_Show("LAZYPROF_MISSING_CRAFTLIB")
    end)
end
