# Architecture Decision Records

## ADR-001: External CraftLib Dependency

**Date**: 2026-01-20

**Status**: Accepted

**Context**: LazyProf needs recipe data. Options: embed data, scrape in-game, or use external library.

**Decision**: Use CraftLib as required external dependency.

**Rationale**:
- Single source of truth for recipe data
- CraftLib handles data maintenance separately
- LazyProf focuses on path calculation and UX
- Users install both addons

**Consequences**:
- Users must install CraftLib
- Version compatibility must be managed
- CraftLib API changes affect LazyProf

---

## ADR-002: UX Philosophy - "Think Less, Trust the Addon"

**Date**: 2026-01-20

**Status**: Accepted

**Context**: Users should not need to figure out what to do next.

**Decision**: Maximize information density and explicit guidance.

**Key Principles**:

1. **Maximum information, no guessing** - Show all relevant details
2. **Clear labels over colors** - Use explicit text, not just color coding
3. **Order matters, show it** - Present steps in sequence
4. **Full context in every element** - Show recipe AND materials consumed
5. **Visual guidance** - Use arrows to point to next action
6. **Trust through completeness** - Justify every decision with visible data

**Anti-patterns**:
- Abbreviated displays requiring interpretation
- Color-only distinctions without text
- Assuming users figure out order of operations
- Hiding information to "simplify"

**Consequences**:
- UI may appear information-dense
- More text/labels than typical minimalist addons
- Users can follow without second-guessing

---

## ADR-003: Multi-Provider Pricing

**Date**: 2026-01-20

**Status**: Accepted (updated 2026-02-11: vendor-first priority)

**Context**: Users have different pricing addons installed. Vendor-sold reagents (dyes, threads, vials, flux) were priced at AH market value because the vendor provider was checked last in the priority chain, causing inflated recipe costs.

**Decision**: Vendor prices are always checked first as an authoritative source. Market providers are checked in configurable priority order for non-vendor items.

**Pricing Order**:
1. Vendor prices (TSM `vendorbuy` / Auctionator merchant data) - checked first, always
2. TSM market prices (if available) - configurable source
3. Auctionator AH prices (if available)

**Rationale**:
- Vendor prices are fixed and guaranteed (unlimited NPC supply)
- No rational player would pay AH markup for vendor-sold items
- TSM and Auctionator automatically record vendor buy prices when visiting merchants
- Market source priority only matters for non-vendor items

**Consequences**:
- Vendor-sold reagents always priced correctly when TSM or Auctionator is installed
- Users must have visited a merchant selling the item for vendor data to be available
- Market provider priority is user-configurable; vendor priority is not (by design)

---

## ADR-004: Material Resolution (Craft vs Buy)

**Date**: 2026-01-21

**Status**: Accepted (implemented in v0.2.1)

**Context**: Some materials can be bought OR crafted (e.g., Fel Iron Bars from Fel Iron Ore via smelting).

**Decision**: Compare `cost(buy material)` vs `cost(craft from base materials)` and choose cheaper option. Implemented via `MaterialResolver.lua` with three configurable modes: None, Cost-compare (default), Always craft.

**Implementation**:
- `MaterialResolver:GetEffectivePrice()` checks if material is craftable via `CraftLib:GetRecipeByProduct()`
- Cost-compare mode chooses cheaper of buy vs craft
- Shopping list shows "To Craft" section for intermediate materials
- Currently single-depth resolution only (ore to bars, not recursive)

**Consequences**:
- More accurate cost calculations for smeltable/craftable intermediates
- Shopping list shows intermediate crafts with material breakdown
- Future: recursive full-depth resolution planned but not yet implemented

---

## ADR-005: Racial Profession Bonus Support

**Date**: 2026-01-29

**Status**: Accepted

**Context**: Some races have profession skill bonuses that extend how long recipes stay orange/yellow/green. For example, Gnomes have +15 Engineering skill for crafting purposes.

**Decision**: Track racial bonuses and adjust color calculations using "effective skill" = base skill - racial bonus.

**Supported Bonuses**:
- Gnome: +15 Engineering
- Blood Elf: +10 Enchanting
- Draenei: +5 Jewelcrafting

**Implementation**:
- `GetRacialBonus(profKey)` in Pathfinder detects player race and returns bonus
- All color calculations use `effectiveSkill = currentSkill - racialBonus`
- `skillRequired` checks use base skill (racial bonus doesn't let you learn recipes earlier)
- UI shows bonus in status bar: "Current skill: 198 (+15 Gnome)"

**Consequences**:
- More accurate paths for characters with racial bonuses
- Recipes stay useful longer, potentially changing optimal path
- Must track racial bonus through all scoring and quantity calculations

---

## ADR-006: Recipe Acquisition Cost Amortization

**Date**: 2026-01-29

**Status**: Accepted

**Context**: Recipe acquisition costs (vendor purchases, AH recipe items) were added to scoring in v0.3.8, but the full cost was added to every evaluation. This over-penalized recipes usable for many crafts. Example: Filet of Redgill (vendor 1g 60s, usable 225-275) scored 16000 when amortized cost should be ~220.

**Problem**: One-time costs treated as per-craft costs in scoring.

**Decision**: Amortize one-time recipe costs over expected remaining crafts.

**Formula**:
```
expected_crafts = sum of (1 / skillup_chance) for each skill point until gray or target
amortized_cost = recipe_cost / expected_crafts
score = (reagent_cost + amortized_cost) / expected_skillup
```

**Implementation**:
- `GetExpectedCraftsUntilGray(recipe, currentSkill, targetSkill, racialBonus)` calculates expected uses
- `purchasedRecipes` table tracks recipes "bought" in simulation (don't re-add cost)
- `ScoreRecipe` adds `recipeCost / expectedCrafts` instead of full `recipeCost`
- `CalculateTotalCostAndSkillups` still adds full cost once (for total display)

**Example Results**:
| Recipe | Uses | Old Score | New Score |
|--------|------|-----------|-----------|
| Filet of Redgill (1g 60s) | ~75 | 16009 | ~220 |
| Short-use vendor recipe (5g) | ~15 | 50050 | ~3400 |
| Trainer recipe (free) | any | 500 | 500 |

**Consequences**:
- Vendor recipes with low reagent cost can now compete fairly
- High-cost short-range recipes still penalized appropriately
- Total path cost unchanged (recipe paid once in totals)
- Debug output shows: `cost=9c (+2s 13c recipe)`

---

## ADR-007: Session-Only Pins for Alternative Recipe Selection

**Date**: 2026-02-08

**Status**: Accepted

**Context**: Users want to override the optimizer's recipe choices (avoiding expensive patterns, specialization preferences, preferring safer orange/yellow over risky green). Need to decide whether pins persist across sessions.

**Decision**: Pins are session-only and reset on `/reload` or logout.

**Implementation**:
- `Pathfinder.pinnedRecipes` table maps `skillLevel -> recipeId`
- Strategies check pins after scoring and override best pick if valid
- UI shows alternatives in collapsible groups, click to pin/unpin
- "Recalculate with N pins" button triggers re-run with pins applied
- `UpdateDisplay()` refreshes all panels after recalculation

**Rationale**:
- Pins are exploratory "what if" overrides, not permanent preferences
- Path optimization changes with price fluctuations - stale pins could become invalid
- Simpler implementation with no SavedVariables complexity

**Alternatives Considered**:
1. Persist pins in SavedVariables - rejected due to staleness risk
2. Auto-recalculate on pin - rejected to avoid jarring UI changes while browsing

**Consequences**:
- Users must re-pin after `/reload` if still desired
- No cross-character pin sharing
- Pins are clearly temporary/exploratory by design

---

## ADR-008: Owned Materials Excluded from Scoring

**Date**: 2026-02-09

**Status**: Accepted (implemented in v0.4.2)

**Context**: The "Use owned materials as free" setting caused the greedy pathfinder to produce worse paths. Free materials lured the algorithm into committing to low-value recipes, shifting skill level breakpoints and causing more expensive downstream choices. Testing confirmed that enabling the setting produced paths costing MORE gold than without it.

**Decision**: Remove the "Use owned materials as free" setting entirely. Strategies always receive empty inventory `{}` and score recipes at market price. Owned materials are only used in the shopping list to show what the player already has.

**Rationale**:
- Greedy algorithm cannot handle 0-cost materials without producing suboptimal paths
- Market price scoring produces consistently optimal paths regardless of inventory
- Shopping list subtraction gives users the same practical benefit (knowing what to buy)
- Proper fix requires Accounter integration with opportunity cost pricing (future work)

**Consequences**:
- Scoring is always based on market price, producing stable and optimal paths
- Shopping list still shows "From Bags", "From Bank", "From Alts" sections
- Bank/alt inclusion settings moved to a "Shopping List" section (independent of scoring)
- Future Accounter integration can reintroduce inventory-aware scoring with proper economics

---

## ADR-009: Continuous Skill-Up Probability Formula

**Date**: 2026-02-09

**Status**: Accepted (implemented in v0.4.2)

**Context**: LazyProf used flat per-color probabilities (yellow=50%, green=25%) which were inaccurate. The actual WoW formula is continuous: `chance = (gray - skill) / (gray - yellow)`. Deep green recipes near gray had 25% displayed when real chance was 1-5%, causing massively underestimated craft counts. Early yellow recipes showed 50% when real chance was near 100%.

**Decision**: Use the continuous formula `(gray - effectiveSkill) / (gray - yellow)` for all skill-up probability calculations.

**Implementation**:
- `Utils.GetSkillUpChance(effectiveSkill, recipe)` implements the formula
- Applied consistently in both Cheapest and Fastest strategies
- Racial bonus factored into `effectiveSkill`

**Consequences**:
- Much more accurate craft count estimates
- Green recipes near gray correctly show as requiring many crafts
- Yellow recipes near orange correctly show as near-guaranteed skillups
- Total path cost estimates significantly more accurate

---

## ADR-010: Bracket Filtering for Milestone Panel and Shopping List

**Date**: 2026-02-09

**Status**: Accepted (implemented in v0.4.2+)

**Context**: Full-path views (1-375) are overwhelming for users who only need to see their current skill bracket. The milestone panel and shopping list needed filtering without affecting the underlying path calculation.

**Decision**: Add bracket filter dropdowns to both milestone panel and shopping list. Filtering is display-only - the full path is always calculated.

**Implementation**:
- `MilestonePanelClass:GetEffectiveBracket()` returns current filter
- `FilterBreakdownByBracket()` filters steps to selected range
- Shopping list synchronizes with milestone panel's bracket filter
- Debug log scoring view also supports bracket filtering

**Consequences**:
- Users can focus on their current bracket while full path stays available
- Shopping list shows only materials needed for filtered brackets
- No re-calculation needed when changing bracket filter

---

## ADR-011: Extended Inventory Scanning

**Date**: 2026-02-09

**Status**: Accepted (implemented post-v0.4.2)

**Context**: The shopping list only checked bags, bank, and alts. Players often have materials in mailbox (from AH purchases), active AH listings (items they could cancel), and guild bank.

**Decision**: Extend Scanner to check all Syndicator-supported sources with a waterfall priority: bags > bank > mail > AH listings > guild bank > alts > buy from AH.

**Implementation**:
- Scanner refactored to registry pattern for modular source addition
- Mail and AH listings always scanned (no toggle needed)
- Guild bank gated behind "Include guild bank" toggle
- Shopping list shows distinct sections: "Check Mail", "Cancel from AH" (orange), "From Guild Bank"
- Source breakdown passed through `CalculateMissingMaterials()` for categorization

**Consequences**:
- Players see a complete picture of where their materials are
- AH listings shown with distinct orange "Cancel from AH" styling
- Adding future inventory sources requires only a new scan function and registry entry

---

## ADR-012: Inventory-Adjusted Cost Display (Display Only)

**Date**: 2026-02-10

**Status**: Accepted

**Context**: The milestone breakdown and alternatives list showed only market-price costs, ignoring what the player already owns. Pinning a recipe the player has materials for showed a higher cost (market price) even though their actual out-of-pocket cost was lower or zero. This made it hard to identify good pin candidates.

**Decision**: Fix the display layer only. Show out-of-pocket costs (accounting for owned materials) prominently in green, with dimmed market price for reference. Do not change the scoring algorithm.

**Implementation**:
- `CalculateMilestoneBreakdown` sums per-material `estimatedCost` (already inventory-adjusted) into `outOfPocketCost` per step
- Each alternative gets `outOfPocketCost` computed against `remainingInventory` at that step (read-only, no consumption)
- Alternatives sorted by out-of-pocket cost (cheapest-for-you first)
- UI shows green OOP cost + dimmed market price when different; normal white when identical
- Path objects carry `outOfPocketTotal` for totals display

**Alternatives Considered**:
- Modify scoring to use owned materials: Rejected per ADR-008 (greedy algorithm produces worse paths with owned=free)
- Badge system (owned/partial/none): Rejected as out-of-pocket cost encodes this information in a single number
- Wait for DP pathfinder: Rejected because display improvement is independent and immediately useful

**Trade-offs Accepted**:
- Alternative OOP costs are per-single-craft (don't account for quantity needed across the full step)
- Alternatives use read-only inventory check (don't simulate consumption), so two alternatives may both show "0g" even if inventory only covers one

**Consequences**:
- Players can identify money-saving pin candidates at a glance
- Scoring remains stable and consistent (market-price, empty inventory)
- DP pathfinder (future) will make this display even more accurate with globally optimal inventory allocation

---

## Template for New ADRs

```markdown
## ADR-XXX: Title

**Date:** YYYY-MM-DD
**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-XXX

### Context

What is the issue that we're seeing that is motivating this decision?

### Decision

What is the change that we're proposing and/or doing?

### Alternatives Considered

What other options were evaluated? Why were they rejected?

### Trade-offs Accepted

What are the downsides of this decision that we're accepting?

### Consequences

What becomes easier or more difficult because of this decision?
```
