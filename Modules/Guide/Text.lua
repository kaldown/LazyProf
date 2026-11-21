-- Modules/Guide/Text.lua
-- Wording shared by the window's tabs, the arrow tooltip and the tests. Pure:
-- no frames, plain ASCII only (no arrows or symbols in UI strings).
local ADDON_NAME, LazyProf = ...

local Text = {}
LazyProf.GuideText = Text

-- Row text for a skill range the path could not cover (a gap, or a gap stage).
function Text.GapText(gap)
    return string.format("No recipe for %d-%d: train elsewhere or missing data",
        math.floor(gap.from), math.floor(gap.to))
end

-- "<qty>x <recipe>", with a suffix when a green recipe bridges a gap. Works
-- for a path step and for a craft stage.
function Text.StepRecipeText(step)
    local name = step.recipe and step.recipe.name or "Unknown"
    local text = string.format("%dx %s", step.quantity, name)
    if step.bridge then
        text = text .. " (green: no better recipe)"
    end
    return text
end
Text.StageTitle = Text.StepRecipeText

-- Prefix of a total-cost label ("Total: " / "Total (excluding gaps): ").
function Text.TotalLabel(path, word)
    if path and path.complete == false then
        return word .. " (excluding gaps): "
    end
    return word .. ": "
end

-- "143-165" for a craft or gap stage, "150" for a learn or rank step.
function Text.StageRange(stage)
    if stage.kind == "learn" or stage.kind == "rank" then
        return tostring(stage.at)
    end
    return string.format("%d-%d", stage.fromDisplay, stage.toDisplay)
end

-- Where a craft stage changes colour: "orange until 150, yellow until 162,
-- then green", or "orange all the way".
function Text.ColorChanges(stage)
    local changes = stage.colorChanges or {}
    if #changes == 0 then
        return (stage.color or "gray") .. " all the way"
    end
    local parts = {}
    local color = stage.color
    for _, change in ipairs(changes) do
        parts[#parts + 1] = string.format("%s until %d", color, change.skill)
        color = change.color
    end
    return table.concat(parts, ", ") .. ", then " .. color
end
