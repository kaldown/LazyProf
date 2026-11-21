-- Core/Client/Family.lua
-- Picks the client family once, at load, before any adapter file runs.
--   "forever" - WoW Forever (retail-engine client with the newer profession UI):
--               WOW_PROJECT_ID equals WOW_PROJECT_CAMELOT (both defined), or the
--               interface number is 16000-19999.
--   "classic" - every other supported client (Era/Anniversary, SoD, TBC, WotLK).
-- Each adapter in Core/Client/ returns at its top unless its family is active,
-- so exactly one of them installs LazyProf.Client.
-- Must not depend on CraftLib (it runs right after Core/Utils.lua).
local ADDON_NAME, LazyProf = ...

local function DetectClientFamily()
    if WOW_PROJECT_ID ~= nil and WOW_PROJECT_CAMELOT ~= nil
        and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then
        return "forever"
    end
    local interface = GetBuildInfo and select(4, GetBuildInfo())
    if type(interface) == "number" and interface >= 16000 and interface <= 19999 then
        return "forever"
    end
    return "classic"
end

LazyProf.ClientFamily = DetectClientFamily()
