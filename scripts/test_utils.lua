-- scripts/test_utils.lua
--
-- Pins today's behaviour of the pure helpers in Core/Utils.lua.
-- Run from the addon root:  lua5.1 scripts/test_utils.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")

-- WoW adds string:trim(); stock Lua 5.1 does not.
if not string.trim then
    function string.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
end

harness.stubWow({ interface = 20505 })
local LazyProf = harness.loadLazyProf({ "Core/Constants.lua", "Core/Utils.lua" })
local Utils = LazyProf.Utils

local failures, total = 0, 0
local function check(name, got, want)
    total = total + 1
    if got == want then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL: %s  -> got %s, want %s", name, tostring(got), tostring(want)))
    end
end

local range = { orange = 100, yellow = 150, green = 175, gray = 200 }

-- GetSkillUpChance: orange 1.0, yellow-to-gray linear, gray 0
check("chance orange (50)", Utils.GetSkillUpChance(50, range), 1.0)
check("chance at yellow (150)", Utils.GetSkillUpChance(150, range), 1.0)
check("chance at green (175)", Utils.GetSkillUpChance(175, range), 0.5)
check("chance mid (162.5)", Utils.GetSkillUpChance(162.5, range), 0.75)
check("chance at gray (200)", Utils.GetSkillUpChance(200, range), 0)
check("chance above gray (250)", Utils.GetSkillUpChance(250, range), 0)
check("chance degenerate range", Utils.GetSkillUpChance(10, { orange = 1, yellow = 50, green = 60, gray = 50 }), 0)

-- GetSkillColor
check("color below orange", Utils.GetSkillColor(50, range), "orange")
check("color orange band", Utils.GetSkillColor(120, range), "orange")
check("color yellow", Utils.GetSkillColor(150, range), "yellow")
check("color green", Utils.GetSkillColor(175, range), "green")
check("color gray", Utils.GetSkillColor(200, range), "gray")

-- BuildSkillBrackets
local brackets = Utils.BuildSkillBrackets({ 75, 150, 225, 300 })
check("brackets count", #brackets, 4)
check("bracket 1 name", brackets[1].name, "1-75")
check("bracket 2 name", brackets[2].name, "75-150")
check("bracket 3 name", brackets[3].name, "150-225")
check("bracket 4 name", brackets[4].name, "225-300")
check("bracket 2 min/max", brackets[2].min .. "/" .. brackets[2].max, "75/150")

-- FormatMoney
check("money 123456", Utils.FormatMoney(123456), "12g 34s 56c")
check("money 0", Utils.FormatMoney(0), "0c")
check("money gold only", Utils.FormatMoney(30000), "3g")

-- FormatMoneyShort: the two largest units, for narrow columns
check("short money gold and silver", Utils.FormatMoneyShort(123456), "12g 34s")
check("short money silver and copper", Utils.FormatMoneyShort(3405), "34s 5c")
check("short money copper", Utils.FormatMoneyShort(42), "42c")
check("short money round gold", Utils.FormatMoneyShort(30000), "3g")
check("short money round silver", Utils.FormatMoneyShort(8200), "82s")
check("short money large", Utils.FormatMoneyShort(1234567), "123g")
check("short money zero", Utils.FormatMoneyShort(0), "0c")
check("short money nil", Utils.FormatMoneyShort(nil), "0c")
check("short money fraction rounds", Utils.FormatMoneyShort(149.6), "1s 50c")

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
