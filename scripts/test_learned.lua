-- scripts/test_learned.lua
--
-- Standalone Lua 5.1 regression test for learned-recipe detection in
-- Professions/Registry.lua (the "[!] Unlearned on already-known recipes" bug).
--
-- Loads the REAL module against a stubbed trade-skill API. The in-game diagnostic
-- (/lp diag learned) confirmed the live cause on a Season of Discovery client:
-- GetTradeSkillRecipeLink(i) is present but returns nil for EVERY row, so the
-- old scan (which only read the recipe link) produced an empty knownSpellIds and
-- flagged all recipes unlearned. GetTradeSkillItemLink(i) works and yields the
-- crafted-item id; CraftLib stores that id per recipe (recipe.itemId) alongside
-- the spell id (recipe.id). The fix resolves each visible row to its spell id by
-- a layered fallback: recipe link -> crafted-item id -> recipe name.
--
-- Run from the addon root:  lua5.1 scripts/test_learned.lua
-- Not shipped: scripts/ is excluded from the package via .pkgmeta.

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end

local addon = {}
addon.dependencyCheckFailed = true   -- skip the load-time CraftLib Initialize()
addon.db = { char = {} }
addon.Utils = { DeepCopy = deepcopy }
function addon:Debug() end           -- no-op (not exercised by the function under test)

-- Fixture trade-skill list. Each row:
--   { kind = "header"|"recipe", name, spellId, itemId, visible }
-- spellId/itemId model what the WoW API would return for that row; visible models
-- the player's filter/collapse state (only visible rows are enumerated).
local fixture = {}            -- set per scenario
-- recipeLinkEnabled models whether GetTradeSkillRecipeLink is functional on the
-- client. On the affected SoD client it is NOT (returns nil for every row).
local recipeLinkEnabled = true

local function visibleRows()
    local rows = {}
    for _, row in ipairs(fixture) do
        if row.visible then rows[#rows + 1] = row end
    end
    return rows
end

_G.GetNumTradeSkills = function() return #visibleRows() end
_G.GetTradeSkillInfo = function(i)
    local row = visibleRows()[i]
    if not row then return nil end
    -- real signature: name, type, numAvailable, isExpanded, ...
    return row.name, (row.kind == "header") and "header" or "optimal"
end
_G.GetTradeSkillRecipeLink = function(i)
    if not recipeLinkEnabled then return nil end
    local row = visibleRows()[i]
    if not row or row.kind == "header" or not row.spellId then return nil end
    -- Classic trade-skill recipe links carry the spell id under the `enchant:` token.
    return string.format("|cffffd000|Henchant:%d|h[%s]|h|r", row.spellId, row.name)
end
_G.GetTradeSkillItemLink = function(i)
    local row = visibleRows()[i]
    if not row or row.kind == "header" or not row.itemId then return nil end
    -- Crafted-item link: |cFF..|Hitem:<itemId>:...:|h[name]|h|r
    return string.format("|cffffffff|Hitem:%d::::::::28:::::1:3524:::::|h[%s]|h|r", row.itemId, row.name)
end

-- ---------------------------------------------------------------------------
-- Load the real module
-- ---------------------------------------------------------------------------
assert(loadfile("Professions/Registry.lua"))("LazyProf", addon)
local Professions = addon.Professions
assert(Professions, "Registry.lua did not create LazyProf.Professions")

-- CraftLib-shaped recipes. spell id (id) and crafted-item id (itemId) are distinct
-- numbers, exactly as in the real data (Light Armor Kit: id=2152, itemId=2304).
-- itemId is nil for enchant-on-gear recipes (e.g. Enchanting), which have no
-- crafted item link -> they must resolve by name.
local function craftlibRecipe(id, name, itemId)
    return {
        id = id, name = name, itemId = itemId,
        reagents = { { itemId = (itemId or id) * 10, count = 1, name = "Mat" } },
        skillRange = { orange = 1, yellow = 20, green = 40, gray = 60 },
        source = { type = "trainer" },
    }
end
local function installProfession()
    Professions.registry["leatherworking"] = {
        id = 165, name = "Leatherworking",
        milestones = {},
        recipes = {
            craftlibRecipe(2152, "Light Armor Kit",          2304),
            craftlibRecipe(7953, "Deviate Scale Cloak",      6466),
            craftlibRecipe(2149, "Handstitched Leather Boots", 4231),
            craftlibRecipe(9058, "Handstitched Leather Cloak", 7276),
            craftlibRecipe(900,  "Enchant Bracer - Minor Health", nil),  -- enchant: no itemId
            craftlibRecipe(7700, "Major Armor Kit",          70000),     -- NOT learned
            craftlibRecipe(8800, "Mooncloth Bag",            80000),     -- NOT learned
        },
    }
end

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
local failures, total = 0, 0
local function check(name, cond, detail)
    total = total + 1
    if cond then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
    end
end
local function byId(recipes)
    local m = {}
    for _, r in ipairs(recipes) do m[r.id] = r end
    return m
end

-- ===========================================================================
-- Scenario 1 (control): recipe-link API works -> the (a) recipe-link path
-- resolves known recipes. Passes pre- and post-fix; guards the link path so the
-- fix does not regress clients where GetTradeSkillRecipeLink is functional.
-- ===========================================================================
recipeLinkEnabled = true
installProfession()
addon.db.char.learnedRecipes = {}
fixture = {
    { kind = "header", name = "Leatherworking", visible = true },
    { kind = "recipe", name = "Light Armor Kit",     spellId = 2152, itemId = 2304, visible = true },
    { kind = "recipe", name = "Deviate Scale Cloak", spellId = 7953, itemId = 6466, visible = true },
}
local r1 = byId(Professions:GetRecipesWithLearnedStatus("leatherworking"))
check("S1 link path: known 2152 -> learned", r1[2152].learned == true)
check("S1 link path: known 7953 -> learned", r1[7953].learned == true)
check("S1 link path: unknown 7700 -> not learned", r1[7700].learned == false)

-- ===========================================================================
-- Scenario 2 (THE CLIENT BUG): GetTradeSkillRecipeLink returns nil for every
-- row; only the crafted-item link is available. Known recipes must still be
-- learned=true, resolved via (b) crafted-item id -> recipe.id. Pre-fix the scan
-- only reads the recipe link, so knownSpellIds is empty and these FAIL.
-- ===========================================================================
recipeLinkEnabled = false
installProfession()
addon.db.char.learnedRecipes = {}
fixture = {
    { kind = "header", name = "Leatherworking", visible = true },
    { kind = "recipe", name = "Light Armor Kit",           spellId = 2152, itemId = 2304, visible = true },
    { kind = "recipe", name = "Deviate Scale Cloak",       spellId = 7953, itemId = 6466, visible = true },
    { kind = "recipe", name = "Handstitched Leather Boots", spellId = 2149, itemId = 4231, visible = true },
    { kind = "recipe", name = "Handstitched Leather Cloak", spellId = 9058, itemId = 7276, visible = true },
}
local r2 = byId(Professions:GetRecipesWithLearnedStatus("leatherworking"))
check("S2 item path: known 2152 (item 2304) -> learned", r2[2152].learned == true,
      "recipeLink nil; must resolve via crafted-item id")
check("S2 item path: known 7953 (item 6466) -> learned", r2[7953].learned == true,
      "recipeLink nil; must resolve via crafted-item id")
check("S2 item path: known 9058 (item 7276) -> learned", r2[9058].learned == true,
      "recipeLink nil; must resolve via crafted-item id")
check("S2 item path: unknown 7700 -> not learned", r2[7700].learned == false)
check("S2 item path: unknown 8800 -> not learned", r2[8800].learned == false)

-- ===========================================================================
-- Scenario 3 (name fallback): an enchant-on-gear recipe has no crafted item
-- (recipe.itemId nil, no item link) and recipeLink is nil too. It must resolve
-- via (c) recipe name. Pre-fix: FAIL.
-- ===========================================================================
recipeLinkEnabled = false
installProfession()
addon.db.char.learnedRecipes = {}
fixture = {
    { kind = "header", name = "Leatherworking", visible = true },
    { kind = "recipe", name = "Enchant Bracer - Minor Health", spellId = 900, itemId = nil, visible = true },
}
local r3 = byId(Professions:GetRecipesWithLearnedStatus("leatherworking"))
check("S3 name path: enchant 900 (no itemId) -> learned", r3[900].learned == true,
      "no recipeLink and no item link; must resolve via name")

-- ===========================================================================
-- Scenario 4 (planning-mode bleed-through, fixed by the same change): the item-
-- path scan above writes a populated knownSpellIds into the cache. Planning mode
-- reads that cache (mirrors Pathfinder.lua:196-198), so known recipes are learned
-- in Planning too. Pre-fix the cache was never written (empty scan) -> FAIL.
-- ===========================================================================
recipeLinkEnabled = false
installProfession()
addon.db.char.learnedRecipes = {}
fixture = {
    { kind = "header", name = "Leatherworking", visible = true },
    { kind = "recipe", name = "Light Armor Kit",     spellId = 2152, itemId = 2304, visible = true },
    { kind = "recipe", name = "Deviate Scale Cloak", spellId = 7953, itemId = 6466, visible = true },
}
Professions:GetRecipesWithLearnedStatus("leatherworking")   -- active scan populates cache
local cached = addon.db.char.learnedRecipes["leatherworking"] or {}
local planningRecipes = deepcopy(Professions:Get("leatherworking").recipes)
for _, recipe in ipairs(planningRecipes) do
    recipe.learned = cached[recipe.id] or false
end
local r4 = byId(planningRecipes)
check("S4 planning: known 2152 -> learned (cache populated)", r4[2152].learned == true,
      "active scan must write a populated learnedRecipes cache")

-- NOTE (deliberate scope): collapsed-header / "Have Materials" filter hiding
-- known recipes from the list (hypothesis H1) is NOT addressed here - the live
-- diagnostic showed it is not the cause (no filter active, all rows enumerated),
-- and the chosen fix does not toggle filters. That latent gap is tracked
-- separately (recipe-availability audit on the roadmap).

print(string.format("\n%d/%d checks passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
