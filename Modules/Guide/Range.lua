-- Modules/Guide/Range.lua
-- The range filter shared by the window's tabs: the current skill bracket,
-- one chosen bracket, or the full path. Pure.
--
-- A selection is nil (the bracket the real skill is in), a bracket index, or
-- "all". Brackets come from LazyProf:GetSkillBrackets(): { min, max, name }.
local ADDON_NAME, LazyProf = ...

local Range = {}
LazyProf.GuideRange = Range

-- The bracket a selection stands for; nil means no filtering (full path, or
-- the skill is past every bracket).
function Range.Effective(selected, brackets, actualSkill)
    if selected == "all" then return nil end
    if type(selected) == "number" then return brackets[selected] end
    if actualSkill then
        for _, bracket in ipairs(brackets) do
            if actualSkill >= bracket.min and actualSkill < bracket.max then
                return bracket
            end
        end
    end
    return nil
end

function Range.Label(selected, brackets, actualSkill)
    local bracket = Range.Effective(selected, brackets, actualSkill)
    if not bracket then return "Full path" end
    if selected == nil then return "Current (" .. bracket.name .. ")" end
    return bracket.name
end

-- Dropdown options: { text, value, checked }. Values: "current", a bracket
-- index, "all".
function Range.Options(selected, brackets)
    local options = { { text = "Current range", value = "current", checked = (selected == nil) } }
    for i, bracket in ipairs(brackets) do
        options[#options + 1] = { text = bracket.name, value = i, checked = (selected == i) }
    end
    options[#options + 1] = { text = "Full path", value = "all", checked = (selected == "all") }
    return options
end

-- Selection for a picked option value.
function Range.FromValue(value)
    if value == "current" then return nil end
    return value
end

-- Stages of one bracket. A stage belongs, whole, to the bracket its start is
-- in (a learn step starts where its craft stage does); a rank step belongs to
-- the bracket it caps.
function Range.FilterStages(stages, bracket)
    if not bracket then return stages end
    local out = {}
    for _, stage in ipairs(stages) do
        local inside
        if stage.kind == "rank" then
            inside = stage.cap > bracket.min and stage.cap <= bracket.max
        else
            inside = stage.from >= bracket.min and stage.from < bracket.max
        end
        if inside then out[#out + 1] = stage end
    end
    return out
end
