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
