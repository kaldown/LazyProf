-- scripts/test_profile.lua
--
-- Standalone Lua 5.1 unit tests for the profile-aware consumer branches added to
-- Core/Utils.lua and Core/Init.lua (WotLK expansion support):
--
--   1. Utils.GetWowheadUrl -> URL contains the correct branch segment per profile
--      (exercises the local WowheadBranch() function through the public API).
--   2. Utils.GetRacialProfessionBonus -> Draenei JC bonus under WOTLK vs VANILLA.
--   3. LazyProf:GetSkillBrackets -> fallback milestone list ends at 450 (WOTLK),
--      375 (TBC), 300 (VANILLA/SOD) when no active profession milestones are set.
--
-- Run from the addon root:  lua5.1 scripts/test_profile.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

-- ---------------------------------------------------------------------------
-- WoW global stubs (minimal - only what Utils.lua and Init.lua touch at
-- load time or during the tested functions)
-- ---------------------------------------------------------------------------

-- UnitRace: set per scenario below. Signature: UnitRace(unit) -> name, token
_G.UnitRace = function(_unit) return "Human", "Human" end

-- GetItemInfo: not exercised in these tests; stub to avoid a nil error in
-- Utils.GetItemInfo (it is loaded as part of the file but not called here)
_G.GetItemInfo = function(_id) return nil end

-- Ace3 stub: LibStub("AceAddon-3.0"):NewAddon returns the addon table itself.
-- Init.lua reassigns LazyProf = LibStub(...):NewAddon(LazyProf, ...) so the
-- stub must return a table with a NewAddon method that returns its first arg.
_G.LibStub = function(_name)
    return {
        NewAddon = function(_self, addon, ...) return addon end,
        New       = function(_self, name, ...)   return {} end,
    }
end

-- Init.lua calls C_AddOns.GetAddOnMetadata at end of OnInitialize; stub it.
_G.C_AddOns = { GetAddOnMetadata = function(_name, _key) return "test" end }

-- Init.lua calls self:Print in OnInitialize (via AceConsole mixin). Because
-- NewAddon just returns the raw table (no mixin applied), Print is never on
-- the object. Stub it so a stray call does not raise.
-- (OnInitialize is NOT called in these tests, but guard defensively.)
_G.print = print  -- already present in lua5.1; keep as-is

-- Other globals touched by Init.lua at module level
_G.date    = function(_fmt) return "00:00:00" end
_G.strlower = string.lower
_G.wipe    = function(t) for k in pairs(t) do t[k] = nil end return t end

-- C_Timer: not called by the paths under test, but Init.lua references it.
_G.C_Timer = { After = function(_d, _fn) end }

-- ---------------------------------------------------------------------------
-- Active profile: controlled per scenario
-- ---------------------------------------------------------------------------
local ACTIVE_PROFILE = "TBC"  -- default; overridden in each test block

_G.CraftLib = {
    GetActiveProfile = function(_self) return ACTIVE_PROFILE end,
}

-- ---------------------------------------------------------------------------
-- Load the addon files under test
-- ---------------------------------------------------------------------------
local addon = {}

-- Utils.lua uses local ADDON_NAME, LazyProf = ... syntax; pass addon table
-- as the second vararg (index 2 = LazyProf).
assert(loadfile("Core/Utils.lua"))("LazyProf", addon)
assert(addon.Utils, "Core/Utils.lua did not populate addon.Utils")

-- Init.lua: load to get GetSkillBrackets. Init.lua replaces the addon var with
-- LibStub():NewAddon() which returns the same table, so addon remains the same
-- object throughout.
assert(loadfile("Core/Init.lua"))("LazyProf", addon)

local LP = _G.LazyProf
assert(LP == addon, "Init.lua did not set _G.LazyProf to the shared addon table")

-- After Init.lua loads, addon.Utils is still set (Utils.lua loaded first and
-- stored Utils on the table; Init.lua does not reset it).
local Utils = addon.Utils

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
local failures, total = 0, 0
local function check(name, cond, detail)
    total = total + 1
    if cond then
        print("ok: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
    end
end

-- ===========================================================================
-- Section 1: Utils.GetWowheadUrl - Wowhead branch selection per profile
--
-- WowheadBranch() (a local inside Utils.lua) is not directly callable, but
-- GetWowheadUrl exposes it via the returned URL string. We assert the segment
-- that appears between ".com/" and "/spell=" in the URL.
-- ===========================================================================
local function urlBranch(url)
    -- Extract segment between wowhead.com/ and /spell=
    return url:match("wowhead%.com/([^/]+)/spell=")
end

ACTIVE_PROFILE = "VANILLA"
check("1.1 VANILLA -> /classic/ branch",
    urlBranch(Utils.GetWowheadUrl(12345)) == "classic",
    urlBranch(Utils.GetWowheadUrl(12345)))

ACTIVE_PROFILE = "SOD"
check("1.2 SOD -> /classic/ branch",
    urlBranch(Utils.GetWowheadUrl(12345)) == "classic",
    urlBranch(Utils.GetWowheadUrl(12345)))

ACTIVE_PROFILE = "TBC"
check("1.3 TBC -> /tbc/ branch",
    urlBranch(Utils.GetWowheadUrl(12345)) == "tbc",
    urlBranch(Utils.GetWowheadUrl(12345)))

ACTIVE_PROFILE = "WOTLK"
check("1.4 WOTLK -> /wotlk/ branch",
    urlBranch(Utils.GetWowheadUrl(12345)) == "wotlk",
    urlBranch(Utils.GetWowheadUrl(12345)))

-- Verify the full URL shape for one case (not just the branch segment)
ACTIVE_PROFILE = "WOTLK"
local wotlkUrl = Utils.GetWowheadUrl(99999)
check("1.5 WOTLK full URL shape",
    wotlkUrl == "https://www.wowhead.com/wotlk/spell=99999",
    wotlkUrl)

-- CraftLib absent fallback: no CraftLib -> branch should default to /tbc/
local savedCL = _G.CraftLib
_G.CraftLib = nil
check("1.6 nil CraftLib defaults to /tbc/ branch",
    urlBranch(Utils.GetWowheadUrl(1)) == "tbc",
    urlBranch(Utils.GetWowheadUrl(1)))
_G.CraftLib = savedCL

-- ===========================================================================
-- Section 2: Utils.GetRacialProfessionBonus - profile-gated racial tables
--
-- Draenei JC bonus: exists in WOTLK (and TBC) but NOT in VANILLA or SOD
-- (TBC/BC races simply did not exist pre-TBC). Also verify Gnome Engineering
-- bonus exists in VANILLA (it did).
-- ===========================================================================

-- Stub UnitRace to return Draenei
_G.UnitRace = function(_unit) return "Draenei", "Draenei" end

ACTIVE_PROFILE = "WOTLK"
local bonus_wotlk = Utils.GetRacialProfessionBonus("jewelcrafting")
check("2.1 Draenei JC bonus is 5 under WOTLK",
    bonus_wotlk == 5, bonus_wotlk)

ACTIVE_PROFILE = "TBC"
local bonus_tbc = Utils.GetRacialProfessionBonus("jewelcrafting")
check("2.2 Draenei JC bonus is 5 under TBC",
    bonus_tbc == 5, bonus_tbc)

ACTIVE_PROFILE = "VANILLA"
local bonus_vanilla = Utils.GetRacialProfessionBonus("jewelcrafting")
check("2.3 Draenei JC bonus is 0 under VANILLA (race not in Classic)",
    bonus_vanilla == 0, bonus_vanilla)

ACTIVE_PROFILE = "SOD"
local bonus_sod = Utils.GetRacialProfessionBonus("jewelcrafting")
check("2.4 Draenei JC bonus is 0 under SOD (race not in Classic)",
    bonus_sod == 0, bonus_sod)

-- Gnome Engineering exists in VANILLA (and all profiles)
_G.UnitRace = function(_unit) return "Gnome", "Gnome" end

ACTIVE_PROFILE = "VANILLA"
local gnome_vanilla = Utils.GetRacialProfessionBonus("engineering")
check("2.5 Gnome Engineering bonus is 15 under VANILLA",
    gnome_vanilla == 15, gnome_vanilla)

ACTIVE_PROFILE = "WOTLK"
local gnome_wotlk = Utils.GetRacialProfessionBonus("engineering")
check("2.6 Gnome Engineering bonus is 15 under WOTLK",
    gnome_wotlk == 15, gnome_wotlk)

-- Gnome does NOT get a JC bonus under any profile
ACTIVE_PROFILE = "WOTLK"
local gnome_jc = Utils.GetRacialProfessionBonus("jewelcrafting")
check("2.7 Gnome JC bonus is 0 (wrong profession for racial)",
    gnome_jc == 0, gnome_jc)

-- ===========================================================================
-- Section 3: LazyProf:GetSkillBrackets - profile-keyed fallback milestones
--
-- GetSkillBrackets falls back to a hardcoded profile-keyed milestone list when
-- no active profession with real milestones is set (Professions.active == nil
-- or registry entry absent). We force that path by leaving addon.Professions
-- nil (not loaded in this harness) so the early guard hits the fallback branch.
--
-- We then inspect the last bracket's max value, which equals the last milestone
-- in the list. Per the implementation:
--   VANILLA/SOD -> {75,150,225,300}    -> last bracket max = 300
--   TBC (default) -> {75,150,225,300,375} -> last bracket max = 375
--   WOTLK -> {75,150,225,300,375,450}  -> last bracket max = 450
-- ===========================================================================

-- Ensure Professions is nil so the fallback path is taken
addon.Professions = nil

local function lastBracketMax(brackets)
    if not brackets or #brackets == 0 then return nil end
    return brackets[#brackets].max
end

ACTIVE_PROFILE = "VANILLA"
local brackets_vanilla = LP:GetSkillBrackets()
check("3.1 VANILLA fallback brackets end at 300",
    lastBracketMax(brackets_vanilla) == 300,
    lastBracketMax(brackets_vanilla))

ACTIVE_PROFILE = "SOD"
local brackets_sod = LP:GetSkillBrackets()
check("3.2 SOD fallback brackets end at 300",
    lastBracketMax(brackets_sod) == 300,
    lastBracketMax(brackets_sod))

ACTIVE_PROFILE = "TBC"
local brackets_tbc = LP:GetSkillBrackets()
check("3.3 TBC fallback brackets end at 375",
    lastBracketMax(brackets_tbc) == 375,
    lastBracketMax(brackets_tbc))

ACTIVE_PROFILE = "WOTLK"
local brackets_wotlk = LP:GetSkillBrackets()
check("3.4 WOTLK fallback brackets end at 450",
    lastBracketMax(brackets_wotlk) == 450,
    lastBracketMax(brackets_wotlk))

-- Verify bracket count for WOTLK (6 milestones -> 6 brackets from 1..75, 75..150, etc.)
check("3.5 WOTLK fallback produces 6 brackets",
    #brackets_wotlk == 6,
    #brackets_wotlk)

-- Verify bracket count for VANILLA (4 milestones -> 4 brackets)
check("3.6 VANILLA fallback produces 4 brackets",
    #brackets_vanilla == 4,
    #brackets_vanilla)

-- Verify that a profession with real milestones bypasses the fallback.
-- Install a minimal Professions registry with a profession that has milestones.
addon.Professions = {
    active = "alchemy",
    registry = {
        alchemy = {
            milestones = {100, 200, 300},
        }
    }
}
ACTIVE_PROFILE = "WOTLK"  -- would give 450 from fallback, but real milestones win
local brackets_real = LP:GetSkillBrackets()
check("3.7 real milestones bypass fallback (last bracket max = 300, not 450)",
    lastBracketMax(brackets_real) == 300,
    lastBracketMax(brackets_real))

-- Clean up for safety
addon.Professions = nil

-- ===========================================================================
-- Summary
-- ===========================================================================
print(string.format("\n%d passed, %d failed", total - failures, failures))
os.exit(failures == 0 and 0 or 1)
