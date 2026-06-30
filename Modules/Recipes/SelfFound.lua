-- Modules/Recipes/SelfFound.lua
-- Self-found obtainability: decides whether a recipe can be crafted without the
-- Auction House or player-to-player trade, from the character's professions,
-- vendor-stocked reagents, gathered raws, and owned inventory. Marks blocked
-- recipes with the existing _isUnavailable flag (dimmed + never auto-selected)
-- plus a _unavailableReason string for the tooltip.
local ADDON_NAME, LazyProf = ...

LazyProf.SelfFound = {}
local SelfFound = LazyProf.SelfFound

-- "Smelting" (Apprentice). Anyone with the Mining profession knows this spell.
-- WHY a spell check: the in-game Smelting window's trade-skill line name may not
-- match CraftLib's "mining" profession key, so opening it does not always populate
-- db.char.learnedRecipes.mining for a real miner. This narrow fallback keeps bar
-- recipes available for actual miners without ever allowing them for non-miners.
-- (Verify the id in-game; it is only a fallback when the cache misses.)
local SMELTING_SPELL_ID = 2575

-- Per-calculation snapshot + memo, mirroring RecipeAvailability's Begin/EndRecalc.
-- IsRecipeObtainable runs for every candidate at every simulated step; the
-- inventory scan, known-profession set, and product lookups are invariant within
-- one synchronous calculation, so snapshot once and memoize by id.
SelfFound._inv = nil
SelfFound._knownProfs = nil
SelfFound._reagentMemo = nil
SelfFound._recipeMemo = nil

function SelfFound:BeginRecalc(inventory)
    -- Accept the already-scanned inventory to avoid a second ScanAll; fall back
    -- to scanning if a caller does not pass one.
    self._inv = inventory or (LazyProf.Inventory and LazyProf.Inventory:ScanAll()) or {}
    self._knownProfs = self:BuildKnownProfessions()
    self._reagentMemo = {}
    self._recipeMemo = {}
end

function SelfFound:EndRecalc()
    self._inv = nil
    self._knownProfs = nil
    self._reagentMemo = nil
    self._recipeMemo = nil
end

-- Set of profession keys the player can craft with: the active profession, any
-- profession with cached learned recipes, plus Mining when the smelting ability
-- is known. Keys match CraftLib's lowercase profession keys (e.g. "leatherworking",
-- "mining"), so they compare directly with GetRecipeByProduct's professionKey.
function SelfFound:BuildKnownProfessions()
    local known = {}

    local active = LazyProf.Professions and LazyProf.Professions.active
    if active then known[active] = true end

    local cache = LazyProf.db and LazyProf.db.char and LazyProf.db.char.learnedRecipes
    if cache then
        for profKey, recipeMap in pairs(cache) do
            if type(recipeMap) == "table" and next(recipeMap) then
                known[profKey] = true
            end
        end
    end

    if not known["mining"] and IsSpellKnown and IsSpellKnown(SMELTING_SPELL_ID) then
        known["mining"] = true
    end

    return known
end

-- Display name for a reason string ("Needs Alchemy"); falls back to the raw key.
local function professionName(profKey)
    local CraftLib = _G.CraftLib
    if CraftLib and CraftLib.GetProfession then
        local prof = CraftLib:GetProfession(profKey)
        if prof and prof.name then return prof.name end
    end
    return tostring(profKey)
end

-- Is a single reagent obtainable without AH/trade?
-- Returns: ok(boolean), reason(string|nil)
function SelfFound:IsReagentObtainableUncached(itemId)
    local inv = self._inv or {}
    -- 1. Owned (bags/bank/alts per the player's include settings).
    if (inv[itemId] or 0) > 0 then
        return true
    end

    local CraftLib = _G.CraftLib

    -- 2. Vendor-stocked reagent (authoritative curated allowlist; no AH needed).
    if CraftLib and CraftLib.GetVendorBuyPrice and CraftLib:GetVendorBuyPrice(itemId) ~= nil then
        return true
    end

    -- 3. Crafted product? Who makes it?
    local producers = CraftLib and CraftLib.GetRecipeByProduct and CraftLib:GetRecipeByProduct(itemId)
    if not producers or #producers == 0 then
        -- Not craftable in the data -> a gathered/looted raw (leather, ore, herb,
        -- cloth). WHY allow: self-found players farm these directly.
        return true
    end

    -- 4. Craftable by a profession the player has?
    local known = self._knownProfs or {}
    for _, entry in ipairs(producers) do
        if entry.professionKey and known[entry.professionKey] then
            return true
        end
    end

    -- 5. Crafted only by professions the player lacks -> not self-obtainable.
    return false, "Needs " .. professionName(producers[1].professionKey)
end

function SelfFound:IsReagentObtainable(itemId)
    local memo = self._reagentMemo
    if memo and memo[itemId] ~= nil then
        return memo[itemId].ok, memo[itemId].reason
    end
    local ok, reason = self:IsReagentObtainableUncached(itemId)
    if memo then memo[itemId] = { ok = ok, reason = reason } end
    return ok, reason
end

-- Build the sourceInfo table (cost/labels) from a recipe's real source, mirroring
-- RecipeAvailability so recipe-acquisition cost and the "[!] Unlearned" tooltip
-- keep working. In self-found we trust the real source type instead of the AH.
local function sourceInfoFor(recipe)
    local source = recipe.source
    if not source then return nil end
    local t = source.type
    if t == "trainer" then
        return { type = "trainer", cost = source.trainingCost or source.cost, npcName = source.npcName }
    elseif t == "vendor" then
        return { type = "vendor", cost = source.cost, vendors = source.vendors, itemId = source.itemId }
    end
    -- drop/quest/reputation/discovery: self-obtainable scroll, no gold cost to model.
    return { type = t }
end

-- Is a whole recipe craftable self-found?
-- Returns: ok(boolean), reason(string|nil), sourceInfo(table|nil)
function SelfFound:IsRecipeObtainableUncached(recipe)
    local sourceInfo
    if not recipe.learned then
        -- Trust the real source type: trainer/vendor/drop/quest/reputation/
        -- discovery are all self-obtainable scrolls. A recipe with no usable
        -- source (or an unmet trainer faction) is not self-obtainable.
        local source = recipe.source
        if not source or not source.type then
            return false, "Recipe not self-obtainable", nil
        end
        if source.type == "trainer" and LazyProf.RecipeAvailability
                and not LazyProf.RecipeAvailability:MeetsTrainerRequirements(source) then
            return false, "Recipe not self-obtainable", nil
        end
        sourceInfo = sourceInfoFor(recipe)
    end

    for _, reagent in ipairs(recipe.reagents) do
        local ok, reason = self:IsReagentObtainable(reagent.itemId)
        if not ok then
            local name = reagent.name or ("item " .. tostring(reagent.itemId))
            return false, (reason or "Needs material") .. ": " .. name, sourceInfo
        end
    end

    return true, nil, sourceInfo
end

function SelfFound:IsRecipeObtainable(recipe)
    local memo = self._recipeMemo
    local key = recipe and recipe.id
    if memo and key ~= nil and memo[key] ~= nil then
        local m = memo[key]
        return m.ok, m.reason, m.sourceInfo
    end
    local ok, reason, sourceInfo = self:IsRecipeObtainableUncached(recipe)
    if memo and key ~= nil then
        memo[key] = { ok = ok, reason = reason, sourceInfo = sourceInfo }
    end
    return ok, reason, sourceInfo
end

-- Apply the self-found availability decision to a candidate recipe that already
-- has its base learned/availability flags set by GetCandidates. Self-found only
-- ADDS restrictions: it never makes an unlearned recipe available when "suggest
-- unlearned recipes" is off. _unavailableReason is always written (or cleared) so
-- no stale reason survives a toggle or skill change.
function SelfFound:MarkRecipe(recipe)
    if not (LazyProf.db and LazyProf.db.char and LazyProf.db.char.selfFoundMode) then
        recipe._unavailableReason = nil
        return
    end
    -- Don't expand beyond the suggest-unlearned setting.
    if not recipe.learned
            and not (LazyProf.db.profile and LazyProf.db.profile.suggestUnlearnedRecipes) then
        recipe._unavailableReason = nil
        return
    end

    local obtainable, reason, sourceInfo = self:IsRecipeObtainable(recipe)
    if obtainable then
        recipe._isUnavailable = nil
        recipe._unavailableReason = nil
        -- Prefer the real (non-AH) source so cost accounting matches self-found.
        if sourceInfo then recipe._sourceInfo = sourceInfo end
    else
        recipe._isUnavailable = true
        recipe._unavailableReason = reason
    end
end
