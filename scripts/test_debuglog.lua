-- scripts/test_debuglog.lua
--
-- Standalone Lua 5.1 unit tests for the LazyProf debug-log buffer/render logic.
-- Loads Core/Init.lua with a stubbed WoW environment (the file's only load-time
-- statement is the AceAddon NewAddon wiring) and exercises the pure functions.
--
-- Run from the addon root:  lua5.1 scripts/test_debuglog.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

-- ---------------------------------------------------------------------------
-- Minimal WoW environment stubs (load-time + the functions under test)
-- ---------------------------------------------------------------------------
LibStub = function(_name)
    return { NewAddon = function(_self, addon, ...) return addon end }
end
date = function(_fmt) return "12:00:00" end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
C_Timer = { After = function(_delay, _fn) end }  -- no-op; we never need the deferred callback

-- ---------------------------------------------------------------------------
-- Load the addon file
-- ---------------------------------------------------------------------------
local chunk = assert(loadfile("Core/Init.lua"))
chunk("LazyProf", {})           -- ADDON_NAME, LazyProf = ...
local LP = _G.LazyProf
assert(LP, "Init.lua did not expose _G.LazyProf")

-- Give it a fake AceDB profile with debug fully enabled.
LP.db = { profile = { debug = true, debugCategories = {
    scoring = true, pathfinder = true, ui = true,
    professions = true, pricing = true, arrow = true,
} } }

-- ---------------------------------------------------------------------------
-- Tiny test harness
-- ---------------------------------------------------------------------------
local failures, total = 0, 0
local function check(name, cond, detail)
    total = total + 1
    if cond then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
    end
end
local function countLines(text)
    if text == "" then return 0 end
    local n = 1
    for _ in text:gmatch("\n") do n = n + 1 end
    return n
end
local function logLineCount(text)
    -- count only real log lines (they start with the timestamp marker)
    local n = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line:find("%[12:00:00%]") then n = n + 1 end
    end
    return n
end
local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then check(name .. " executed without error", false, err) end
end

-- ===========================================================================
-- T1: FormatDebugLogTail renders only the last N lines + truncated flag + total
-- ===========================================================================
section("T1", function()
    local entries = {}
    for i = 1, 10 do
        entries[i] = { timestamp = "12:00:00", category = "pathfinder", message = "m" .. i }
    end

    local text, truncated, n = LP:FormatDebugLogTail(entries, 3)
    check("T1 FormatDebugLogTail exists", type(LP.FormatDebugLogTail) == "function")
    check("T1 total reported", n == 10, n)
    check("T1 truncated flag true when capped", truncated == true)
    check("T1 renders exactly maxLines", countLines(text) == 3, countLines(text))
    check("T1 keeps the NEWEST lines", text:find("m10", 1, true) ~= nil and text:find("m8", 1, true) ~= nil)
    check("T1 drops the OLDEST line", text:find("m7", 1, true) == nil)

    local allText, allTrunc = LP:FormatDebugLogTail(entries, nil)
    check("T1 nil maxLines renders all", countLines(allText) == 10, countLines(allText))
    check("T1 nil maxLines not truncated", allTrunc == false)
end)

-- ===========================================================================
-- T2: GetFilteredDebugLog hoists GetSkillBrackets (called at most once)
-- ===========================================================================
section("T2", function()
    LP.debugLog = {}
    for i = 1, 50 do
        LP.debugLog[i] = { timestamp = "12:00:00", category = "scoring",
                           message = "Scoring candidates at skill 50" }
    end
    LP.debugFilter = "scoring"
    LP.debugScoringBracket = 1

    local calls = 0
    LP.GetSkillBrackets = function(_self)
        calls = calls + 1
        return { { name = "1-100", min = 1, max = 100 } }
    end

    local filtered = LP:GetFilteredDebugLog()
    check("T2 all matching entries kept", #filtered == 50, #filtered)
    check("T2 GetSkillBrackets hoisted (<=1 call)", calls <= 1, calls)

    LP.debugFilter = nil
    LP.debugScoringBracket = nil
end)

-- ===========================================================================
-- T3: Bounded buffer tolerates a slack overshoot before a single batch trim
--     (encodes amortized O(1) insertion -- no per-line O(n) front shift)
-- ===========================================================================
section("T3", function()
    LP.debugLog = {}
    LP.debugLogOverflowed = false
    LP.debugLogMax = 10
    LP.debugLogSlack = 4
    LP.debugFrame = nil  -- ensure Debug() does not try to refresh a window

    -- Insert max+1 (=11). With a slack buffer this must NOT drop anything yet.
    for i = 1, 11 do LP:Debug("pathfinder", "m" .. i) end
    check("T3 slack overshoot retained (no per-line trim)", #LP.debugLog == 11, #LP.debugLog)
    check("T3 no overflow flag before slack exceeded", LP.debugLogOverflowed == false)
    check("T3 oldest still present within slack", LP.debugLog[1].message == "m1", LP.debugLog[1].message)

    -- Cross max+slack (=14): inserting the 15th triggers one batch trim back to max.
    for i = 12, 15 do LP:Debug("pathfinder", "m" .. i) end
    check("T3 batch-trimmed to debugLogMax", #LP.debugLog == 10, #LP.debugLog)
    check("T3 overflow flag set after trim", LP.debugLogOverflowed == true)
    check("T3 keeps the NEWEST debugLogMax", LP.debugLog[1].message == "m6"
        and LP.debugLog[10].message == "m15",
        (LP.debugLog[1].message .. ".." .. LP.debugLog[10].message))
end)

-- ===========================================================================
-- T4: UpdateDebugWindowContent caps rendered lines and shows a view-cap note
-- ===========================================================================
section("T4", function()
    LP.debugLog = {}
    LP.debugLogOverflowed = false
    LP.debugLogMax = 1000
    LP.debugLogSlack = 512
    LP.debugRenderMax = 5
    LP.debugFilter = nil
    LP.debugScoringBracket = nil
    for i = 1, 20 do
        LP.debugLog[i] = { timestamp = "12:00:00", category = "pathfinder", message = "line" .. i }
    end

    local captured = {}
    LP.debugFrame = {
        editBox = { SetText = function(_self, t) captured.text = t end },
        countText = { SetText = function(_self, t) captured.count = t end },
        scrollFrame = { GetVerticalScrollRange = function() return 0 end,
                        SetVerticalScroll = function() end },
        IsShown = function() return true end,
    }

    LP:UpdateDebugWindowContent()
    check("T4 produced text", type(captured.text) == "string" and captured.text ~= "")
    check("T4 caps rendered log lines to debugRenderMax",
        logLineCount(captured.text) <= LP.debugRenderMax, logLineCount(captured.text))
    check("T4 shows view-cap note", captured.text:find("Showing last", 1, true) ~= nil)
    check("T4 note ASCII only (no arrows/emoji)",
        captured.text:find("[\128-\255]") == nil)
    check("T4 still shows newest line", captured.text:find("line20", 1, true) ~= nil)
    check("T4 drops oldest from view", captured.text:find("line1 ", 1, true) == nil
        and captured.text:find("line1$") == nil)

    LP.debugFrame = nil
end)

-- ---------------------------------------------------------------------------
print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
