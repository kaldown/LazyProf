-- Modules/Recipes/Availability.lua
-- Checks recipe availability based on possession, source type, and AH listings
local ADDON_NAME, LazyProf = ...

LazyProf.RecipeAvailability = {}
local Availability = LazyProf.RecipeAvailability

-- Per-calculation availability memo. IsRecipeAvailable is called for every
-- unlearned candidate at every simulated step of a path calculation (60-100
-- steps), and its source/AH lookups (GetAHPrice -> TSM/Auctionator) are not
-- otherwise cached. Availability is invariant within one synchronous
-- calculation, so we memoize by recipe id and reset between calculations.
Availability._memo = nil  -- nil = disabled (active only between Begin/EndRecalc)
Availability._spells = nil  -- spell id -> known, for the same span

function Availability:BeginRecalc()
    self._memo = {}
    self._spells = {}
end

function Availability:EndRecalc()
    self._memo = nil
    self._spells = nil
end

-- Does the character know the spell (a profession specialization)? Asked of
-- the client adapter once per spell per calculation, so a specialization
-- learned meanwhile counts from the next calculation (opening the profession
-- window recalculates). No adapter, or a partial one in headless suites: not
-- known - the side that leaves a recipe out (P125).
function Availability:KnowsSpell(spellId)
    local cache = self._spells
    if cache and cache[spellId] ~= nil then
        return cache[spellId]
    end
    local client = LazyProf.Client
    local known = (client and client.KnowsSpell and client:KnowsSpell(spellId)) and true or false
    if cache then cache[spellId] = known end
    return known
end

-- What keeps the character from learning the recipe, as far as profession
-- specializations go (ruling P121): nil when nothing does - the recipe is
-- learned, the data names no specialization, or the character knows the one
-- it names - else the recipe's own `specialization` table: { spellId, name },
-- or { unknown = true } when the data could not say. Unknown is never "none":
-- buying a pattern the character cannot learn is the money lost.
function Availability:SpecializationBlocks(recipe)
    if recipe.learned then return nil end
    local spec = recipe.specialization
    if not spec then return nil end
    if not spec.unknown and spec.spellId and self:KnowsSpell(spec.spellId) then
        return nil
    end
    return spec
end

-- Memoizing front for IsRecipeAvailableUncached (see BeginRecalc/EndRecalc).
-- Returns: isAvailable (boolean), sourceInfo (table or nil)
function Availability:IsRecipeAvailable(recipe)
    local memo = self._memo
    local key = recipe and recipe.id
    if memo and key ~= nil then
        local cached = memo[key]
        if cached ~= nil then
            return cached.isAvailable, cached.sourceInfo
        end
    end
    local isAvailable, sourceInfo = self:IsRecipeAvailableUncached(recipe)
    if memo and key ~= nil then
        memo[key] = { isAvailable = isAvailable, sourceInfo = sourceInfo }
    end
    return isAvailable, sourceInfo
end

-- Check if a recipe is available to obtain
-- Returns: isAvailable (boolean), sourceInfo (table or nil)
-- sourceInfo contains details for tooltip display
function Availability:IsRecipeAvailableUncached(recipe)
    -- 1. Already learned - always available
    if recipe.learned then
        return true, { type = "learned" }
    end

    -- 1b. A specialization the character does not know: never available, not
    -- even from a pattern in the bags (that pattern cannot be learned). The
    -- strategies already leave such recipes out of their candidates; this is
    -- the second line for any other caller.
    local blocked = self:SpecializationBlocks(recipe)
    if blocked then
        return false, { type = "specialization", specialization = blocked }
    end

    -- 2. Check if we have the recipe item in inventory
    local recipeItemId = self:GetRecipeItemId(recipe)
    if recipeItemId then
        local location = self:FindRecipeInInventory(recipeItemId)
        if location then
            return true, {
                type = "inventory",
                location = location,
                itemId = recipeItemId
            }
        end
    end

    -- 3. Check source-based availability
    local source = recipe.source
    if not source then
        -- No source data - can't determine availability
        return false, nil
    end

    -- Trainer recipes - always available if requirements met
    if source.type == "trainer" then
        if self:MeetsTrainerRequirements(source) then
            -- The fee from the recipe data; where it has none, the fee a
            -- trainer the player visited charged for this recipe.
            local cost = source.trainingCost or source.cost
            local costSeen = nil
            if not cost and LazyProf.TrainerMemory then
                cost = LazyProf.TrainerMemory:Fee(recipe.id)
                costSeen = cost and true or nil
            end
            return true, {
                type = "trainer",
                cost = cost,
                costSeen = costSeen,
                npcName = source.npcName
            }
        end
        -- Doesn't meet requirements, fall through to check AH
    end

    -- Currency-only recipes (no gold cost, bought with e.g. Merchant's Favor):
    -- never free. Available only when learned (handled above) or opted in.
    if (source.type == "vendor" or source.type == "reputation")
            and source.cost == nil and source.currency ~= nil then
        local profile = LazyProf.db and LazyProf.db.profile
        if profile and profile.includeCurrencyRecipes then
            return true, {
                type = "vendor",
                cost = 0,
                currency = source.currency,
                itemId = source.itemId
            }
        end
        return false, nil
    end

    -- Vendor recipes - always available (player can travel)
    if source.type == "vendor" then
        return true, {
            type = "vendor",
            cost = source.cost,
            vendors = source.vendors,
            itemId = source.itemId,
            currency = source.currency
        }
    end

    -- 4. Quest/Rep/Drop/World Drop/Unknown - check AH
    if recipeItemId then
        local ahPrice, ahSource = self:GetAHPrice(recipeItemId)
        if ahPrice then
            return true, {
                type = "ah",
                price = ahPrice,
                source = ahSource,
                itemId = recipeItemId
            }
        end
    end

    -- 5. Not available
    return false, nil
end

-- Get the recipe item ID from source data
-- For vendor/drop sources, this is the physical recipe item that teaches the spell
-- Returns: itemId (number or nil)
function Availability:GetRecipeItemId(recipe)
    if not recipe.source then
        return nil
    end

    -- Vendor and drop sources have itemId for the recipe item
    if recipe.source.itemId then
        return recipe.source.itemId
    end

    return nil
end

-- Find a recipe item in player's inventory (bags, bank, mail, alts, etc.)
-- Returns: location info table or nil
-- location = { type = "bags|bank|mail|alt", count = N, character = "Name" (for alts) }
function Availability:FindRecipeInInventory(itemId)
    if not itemId then
        return nil
    end

    -- Use ScanAll to check all enabled sources at once
    local combined, sourceBreakdown = LazyProf.Inventory:ScanAll()

    if not combined[itemId] or combined[itemId] <= 0 then
        return nil
    end

    -- Check sourceBreakdown to find WHERE the item is
    local bd = sourceBreakdown[itemId]
    if not bd then
        return nil
    end

    -- Return the first source that has the item (priority order)
    if (bd.bags or 0) > 0 then
        return { type = "bags", count = bd.bags }
    end
    if (bd.bank or 0) > 0 then
        return { type = "bank", count = bd.bank }
    end
    if (bd.mail or 0) > 0 then
        return { type = "mail", count = bd.mail }
    end
    if bd.alts then
        for charName, charSources in pairs(bd.alts) do
            local charTotal = 0
            for _, count in pairs(charSources) do
                charTotal = charTotal + count
            end
            if charTotal > 0 then
                return { type = "alt", count = charTotal, character = charName }
            end
        end
    end

    return nil
end

-- Check if an item is listed on the Auction House
-- Returns: price (copper), source ("TSM"|"Auctionator") or nil, nil if not listed
function Availability:GetAHPrice(itemId)
    if not itemId then
        return nil, nil
    end

    -- A fresh Auctionator price (seen today, auction house visited this
    -- session) is newer than TSM's snapshot (same rule as PriceManager:GetPriceInfo).
    local auctionator = Auctionator and Auctionator.API and Auctionator.API.v1
    if auctionator and auctionator.GetAuctionAgeByItemID then
        local age = auctionator.GetAuctionAgeByItemID("LazyProf", itemId)
        if LazyProf.PriceManager:IsFreshAge(age) then
            local price = auctionator.GetAuctionPriceByItemID("LazyProf", itemId)
            if price and price > 0 then
                return price, "Auctionator"
            end
        end
    end

    -- Then TSM (uses DBMinBuyout - nil means no listings)
    if TSM_API then
        local itemString = "i:" .. itemId
        local price = TSM_API.GetCustomPriceValue("DBMinBuyout", itemString)
        if price and price > 0 then
            return price, "TSM"
        end
    end

    -- Fallback to Auctionator
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local price = Auctionator.API.v1.GetAuctionPriceByItemID("LazyProf", itemId)
        if price and price > 0 then
            return price, "Auctionator"
        end
    end

    return nil, nil
end

-- Check if player meets trainer requirements (faction, honor, reputation)
-- Currently simplified: returns true for basic trainers
-- Returns: boolean
function Availability:MeetsTrainerRequirements(source)
    if not source then
        return false
    end

    -- Check faction requirement
    if source.faction then
        local playerFaction = UnitFactionGroup("player")
        if source.faction ~= playerFaction and source.faction ~= "Neutral" then
            return false
        end
    end

    -- Future: Check honor requirements
    -- Future: Check reputation requirements

    -- Basic trainer with no special requirements
    return true
end
