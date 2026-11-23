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

-- Sale value ----------------------------------------------------------------------

local function CutPercent()
    return math.floor(LazyProf.Constants.AUCTION_CUT * 100 + 0.5)
end

-- How the crafts are counted as sold (the sale mode), for the receipt's note.
function Text.SoldNote(mode)
    if mode == LazyProf.Constants.SALE_MODE.AUCTION then
        return string.format("crafts sold at auction, after the %d%% cut", CutPercent())
    end
    return "crafts sold to a vendor"
end

-- Learn and rank steps -----------------------------------------------------------

-- On the VANILLA profile the recipe data types every recipe as trainer-taught,
-- so a learn step there never names where the recipe comes from.
local function SourceKnown(profile)
    return profile ~= "VANILLA"
end

local function InventoryPlace(location)
    if not location then return "you already own the recipe" end
    if location.type == "bags" then return "in your bags" end
    if location.type == "bank" then return "in your bank" end
    if location.type == "mail" then return "in your mail" end
    if location.type == "alt" then return "on your alt " .. tostring(location.character) end
    return "you already own the recipe"
end

-- A few words on where an unlearned recipe comes from, for list rows; nil
-- when nothing may be said (VANILLA profile).
function Text.LearnShort(stage, profile)
    if not SourceKnown(profile) then return nil end
    local info = stage.sourceInfo
    if not info then return "not currently obtainable" end
    if info.type == "inventory" then return InventoryPlace(info.location) end
    if info.type == "trainer" then return "trainer" end
    if info.type == "vendor" then
        local currency = LazyProf.Utils.FormatCurrency(info.currency)
        return currency and ("vendor, " .. currency) or "vendor"
    end
    if info.type == "ah" then return "auction house" end
    return nil
end

-- The body of a learn step's card: { { text, color = "plain" | "good" | "warn" | "cost" }, ... }.
-- Only what the resolved source says; a fee only when it is known.
function Text.LearnLines(stage, profile, professionName)
    local Utils = LazyProf.Utils
    local lines = {}
    local function add(text, color) lines[#lines + 1] = { text = text, color = color or "plain" } end
    local info = stage.sourceInfo
    if not SourceKnown(profile) then
        add("Learn the recipe. The recipe details show what is known about it.")
    elseif not info then
        add("Not currently obtainable from a trainer, a vendor or the auction house.", "warn")
        add("You chose this recipe yourself; you will need to obtain it.")
    elseif info.type == "inventory" then
        add("The recipe is " .. InventoryPlace(info.location) .. ". Use it to learn the recipe.", "good")
    elseif info.type == "trainer" then
        local who = info.npcName
        if not who or who:find("^Any ") then
            who = "any " .. tostring(professionName) .. " trainer"
        end
        add("Learn from: " .. who)
        if info.cost and info.cost > 0 then
            add("Cost: " .. Utils.FormatMoney(info.cost)
                .. (info.costSeen and " (as charged at a trainer you visited)" or ""), "cost")
        end
    elseif info.type == "vendor" then
        local vendor = info.vendors and info.vendors[1]
        if vendor and vendor.npcName then
            add("Buy from: " .. vendor.npcName .. (vendor.location and (" (" .. vendor.location .. ")") or ""))
        else
            add("Sold by a vendor.")
        end
        if info.cost and info.cost > 0 then
            add("Cost: " .. Utils.FormatMoney(info.cost), "cost")
        end
        local currency = Utils.FormatCurrency(info.currency)
        if currency then
            add("Price: " .. currency, "cost")
        end
    elseif info.type == "ah" then
        add("Listed on the auction house.", "good")
        add("Price: " .. Utils.FormatMoney(info.price or 0) .. " (" .. tostring(info.source) .. ")", "cost")
    end
    local required = stage.recipe and stage.recipe.skillRequired
    if required then
        add("Requires skill " .. tostring(required))
    end
    return lines
end

-- The sentence of a rank step's card. "Your cap" is only said of the cap the
-- client reports for this character; later caps come from the profession data.
function Text.RankLine(stage, liveCap, professionName, hasProfession)
    local cap = stage.cap
    local trainer = "a " .. tostring(professionName) .. " trainer"
    if hasProfession ~= false and liveCap == cap then
        return string.format("Your cap is %d. Train the next rank at %s before you reach %d.", cap, trainer, cap)
    end
    return string.format("Skill cap %d: train the next rank at %s before you reach %d.", cap, trainer, cap)
end

-- One visited trainer: "Name - Zone (53, 81)". The coordinates are where the
-- player stood while talking to the trainer.
function Text.TrainerLine(trainer)
    local text = trainer.name or "Unknown"
    if trainer.zone and trainer.zone ~= "" then
        text = text .. " - " .. trainer.zone
    end
    if type(trainer.x) == "number" and type(trainer.y) == "number" then
        text = text .. string.format(" (%d, %d)", math.floor(trainer.x * 100 + 0.5), math.floor(trainer.y * 100 + 0.5))
    end
    return text
end

function Text.RankShort(stage)
    return string.format("Train the next rank before %d", stage.cap)
end
