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

**Status**: Accepted

**Context**: Users have different pricing addons installed.

**Decision**: Support TSM, Auctionator, and vendor prices with graceful fallback.

**Priority Order**:
1. TSM (if available)
2. Auctionator (if available)
3. Vendor prices (always available)

**Rationale**:
- TSM has most accurate market data
- Auctionator is common alternative
- Vendor prices ensure addon always works

**Consequences**:
- Must handle all three APIs
- Price accuracy varies by source
- Users without AH addons get vendor-only prices

---

## ADR-004: Craft vs Buy Optimization

**Date**: 2026-01-21

**Status**: Planned (pending CraftLib GetRecipeByProduct)

**Context**: Some materials can be bought OR crafted (e.g., Fel Iron Bars from Fel Iron Ore).

**Decision**: Compare `cost(buy material)` vs `cost(craft from base materials)` and choose cheaper option.

**Requires**: CraftLib `GetRecipeByProduct(itemId)` API (implemented 2026-01-21)

**Implementation**:
- When calculating material cost, check if craftable
- If craftable, compare buy price vs craft cost
- Include in shopping list with appropriate source label

**Consequences**:
- More accurate cost calculations
- Shopping list shows intermediate crafts
- Requires user to have relevant profession

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
