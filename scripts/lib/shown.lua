-- scripts/lib/shown.lua
-- Reads what the window SHOWS back into numbers, so a suite can check that
-- the amounts a player sees add up (and not only the numbers behind them).
--   local Shown = require("scripts.lib.shown")
--   Shown.copper(text)            "1g 2s 3c" -> 10203
--   Shown.amounts(Views, view)    the receipt, the Shopping tab and the Path tab of a view
local M = {}

-- "1g 2s 3c", "45s" or "-5s 70c" as copper; nil when the text is not an
-- amount ("?", "-", "", "done").
function M.copper(text)
    if type(text) ~= "string" then return nil end
    local sign, rest = text:match("^(%-?)(.*)$")
    local leftover = rest:gsub("%d+[gsc]", "")
    if not rest:find("%d+[gsc]") or leftover:gsub("%s", "") ~= "" then return nil end
    local worth = { g = 10000, s = 100, c = 1 }
    local total = 0
    for amount, unit in rest:gmatch("(%d+)([gsc])") do
        total = total + tonumber(amount) * worth[unit]
    end
    return sign == "-" and -total or total
end

-- The amounts a view shows, as copper:
--   spend, noteReagents, noteRecipes   "You spend" and the two parts of its note
--   back (negative), net (negative for a gain), stock
--   making            what the making line says is saved (negative: costs more); 0 without the line
--   cells, reagentsTotal               the Shopping table's Cost cells added up, and "Reagents to buy"
--   recipeRows, recipesTotal           the recipe rows added up, and "Recipes"
--   column, fees      the Path tab's cost column added up, and the fees of its "Learn first" sub-lines
--   unknown           how many cost cells of the Path tab are not amounts ("?")
function M.amounts(Views, view)
    local copper = M.copper
    local out = { cells = 0, recipeRows = 0, column = 0, fees = 0, making = 0, unknown = 0 }
    for _, line in ipairs(Views.Receipt(view)) do
        if line.key == "spend" then
            out.spend = copper(line.amount)
            if line.note then
                local reagents, recipes = line.note:match("^reagents (.+) %+ recipes (.+)$")
                out.noteReagents, out.noteRecipes = copper(reagents), copper(recipes)
            end
        elseif line.key == "back" then
            out.back = copper(line.amount)
        elseif line.key == "net" then
            out.net = copper(line.amount) * (line.label == "Net gain" and -1 or 1)
            out.stock = line.note and copper(line.note:match("saves (.+)$"))
        elseif line.key == "stock" then
            out.stock = copper(line.note:match("saves (.+)$"))
        elseif line.key == "making" then
            local saves, costs = line.note:match("saves (.+)$"), line.note:match("costs (.+) more than buying$")
            out.making = saves and copper(saves) or -copper(costs)
        end
    end
    for _, row in ipairs(Views.Shopping(view, {})) do
        if row.item then
            out.cells = out.cells + (copper(row.cols[4]) or 0)
        elseif row.recipe then
            out.recipeRows = out.recipeRows + (copper(row.cols[4]) or 0)
        elseif row.total and row.text == "Reagents to buy" then
            out.reagentsTotal = copper(row.cols[4])
        elseif row.total and row.text == "Recipes" then
            out.recipesTotal = copper(row.cols[4])
        end
    end
    for _, row in ipairs(Views.Path(view, {})) do
        if row.layout == "path" and row.stage then
            local cost = copper(row.cols[3])
            if cost then out.column = out.column + cost else out.unknown = out.unknown + 1 end
        elseif row.sub and row.stage and row.stage.kind == "learn" then
            out.fees = out.fees + (copper(row.text:match(", ([%dgsc ]+)$")) or 0)
        end
    end
    return out
end

return M
