-- Modules/Pathfinder/Pins.lua
-- Pinned recipes: the player's "use this recipe here" overrides of the
-- planner's choice. A pin covers a skill range, { from, to, recipeId }, with
-- from inclusive and to exclusive, so it still matches when the steps before
-- it change and start at a slightly different fractional skill.
--
-- A pin list is a plain array sorted by `from`; pins never overlap (a new pin
-- replaces every pin it overlaps). Lists are saved per character and
-- profession (Core/CharStore.lua). Everything here is pure.
local ADDON_NAME, LazyProf = ...

local Pins = {}
LazyProf.Pins = Pins

-- Recipe id pinned at `skill`, nil when no pin covers it.
function Pins.Find(pins, skill)
    if not pins then return nil end
    for _, pin in ipairs(pins) do
        if skill >= pin.from and skill < pin.to then
            return pin.recipeId
        end
    end
    return nil
end

-- Pin recipeId over [from, to). Pins it overlaps are removed.
function Pins.Add(pins, from, to, recipeId)
    if not (recipeId and from and to and to > from) then return end
    for i = #pins, 1, -1 do
        local pin = pins[i]
        if pin.from < to and pin.to > from then
            table.remove(pins, i)
        end
    end
    local at = #pins + 1
    for i, pin in ipairs(pins) do
        if pin.from > from then
            at = i
            break
        end
    end
    table.insert(pins, at, { from = from, to = to, recipeId = recipeId })
end

-- Remove the pin covering `skill`. Returns whether one was removed.
function Pins.RemoveAt(pins, skill)
    for i, pin in ipairs(pins) do
        if skill >= pin.from and skill < pin.to then
            table.remove(pins, i)
            return true
        end
    end
    return false
end

-- Drop the pins whose range the real skill has passed. Returns how many.
function Pins.Prune(pins, actualSkill)
    local removed = 0
    for i = #pins, 1, -1 do
        if pins[i].to <= actualSkill then
            table.remove(pins, i)
            removed = removed + 1
        end
    end
    return removed
end
