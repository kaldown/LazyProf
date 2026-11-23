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

**Status**: Superseded by ADR-017 (implemented in v0.4.2)

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

## ADR-013: Client Adapter Chosen Once at Load

**Date**: 2026-11-21

**Status**: Accepted

### Context

LazyProf must run on the Classic clients (TradeSkill API, `UIDropDownMenu`) and on WoW Forever (`C_TradeSkillUI`, `ProfessionsFrame`, native menus). Calls to the profession window, item info and similar APIs were spread across the code.

### Decision

All client-specific calls live behind one adapter (`LazyProf.Client`) in `Core/Client/`, and widgets that differ per client (dropdowns, panel frames) live in `Modules/UI/Widgets/`. `Core/Client/Family.lua` selects the family once at load: `forever` when `WOW_PROJECT_ID` and `WOW_PROJECT_CAMELOT` are both set and equal, or the interface is 16000-19999; otherwise `classic`. Both adapter files are listed in the TOC and load everywhere; each returns at its top unless its family is active. Code outside those folders never names client APIs, which a test enforces.

### Alternatives Considered

- Per-file TOC conditions to load only the matching adapter: rejected because they cannot be verified on the Classic clients, and a client that does not understand the syntax would skip the Classic adapter.
- Checking the client at each call site: rejected, it scatters the branching and is easy to miss.

### Trade-offs Accepted

- Both adapters are parsed on every client, and each file needs an early-return guard.

### Consequences

- Adding a client means adding one adapter file and, if needed, widget variants.
- Pathfinder, pricing and UI logic stay client-independent and testable headless.

---

## ADR-014: Shared Panel Shell

**Date**: 2026-11-21

**Status**: Accepted

### Context

The milestone, shopping list and recipe details panels each handled position, visibility and combat on their own. Positions were lost, a panel closed by the user could reappear, and a panel hidden by combat lockdown could stay hidden or return when the profession window was no longer open.

### Decision

A panel shell owns frame creation (native frame style per client), saved position, drag, the user-closed state and combat handling. A panel restores after combat only if the profession window is still open, a path is valid and the user did not close it; the Planning window counts as an owner as well. A user-closed panel stays closed until the profession window is reopened or the user acts in Planning. Rows are pooled and reused instead of re-created on each update. Panels keep scroll-frame rows; a ScrollBox rewrite is left for later.

### Alternatives Considered

- Leave each panel with its own handling: rejected, the bugs were the same in every panel.
- Rewrite lists on ScrollBox now: rejected as out of scope for the port.

### Trade-offs Accepted

- Combat auto-hide stays, so panels disappear in combat and return afterwards.

### Consequences

- New panels get position, closed-state and combat behavior by using the shell.
- `/lp resetpanels` has one place to reset.

---

## ADR-015: One Strategy Loop With Gap Handling

**Date**: 2026-11-21

**Status**: Accepted

### Context

The Cheapest and Fastest strategies each had their own copy of the leveling loop. When no recipe was available at the current skill, the loop ended silently, so paths stopped short with no explanation. Forever data has recipes with unknown sources and currency-only costs, which makes such gaps more likely.

### Decision

Both strategies share one core loop and differ only in how they score candidates. When no candidate fits at a skill level, the loop bridges the gap with a green recipe as long as its skill-up chance is at least 10%; otherwise it records a gap step and the path and UI report it. Availability also handles two new cases: unknown-source recipes (usable only when learned, owned or priced) and currency-only recipes (usable when learned or when "Include recipes bought with currency" is on, costed at 0 copper). Snapshot tests pin the resulting paths.

### Alternatives Considered

- Keep two loops and patch both: rejected, the fixes would drift apart.
- Bridge with any recipe: rejected, below 10% the cost and time are misleading.

### Trade-offs Accepted

- A gap in the path can make later steps depend on a skill the player may not reach by that route.

### Consequences

- Only the `cheapest` and `fastest` strategies exist; new scoring is a new candidate scorer, not a new loop.

---

## ADR-016: One tabbed window, drawn from stages

**Date:** 2026-11-22
**Status:** Accepted

### Context

The path was shown as 60-100 five-craft rows spread over a milestone panel, a shopping list panel and a separate Planning window. Nothing answered "what do I do now", progress and the expensive part of the path were invisible, alternatives were three clicks deep, and state (expanded rows, the chosen bracket, pins) was lost on every recalculation. Training a rank and learning a recipe were a grey separator and a tooltip.

### Decision

- One native window with Guide / Steps / Shopping tabs replaces the two panels and the Planning window. Docked beside the profession window it shows the open profession; undocked, with a profession picker, it is planning mode. There is one instance.
- The window is drawn from **stages**: the planner's steps folded into craft runs of one recipe, learn-the-recipe steps, train-the-next-rank steps and gaps (`Modules/Guide/Stages.lua`). The planner's own steps are not re-cut, so its output and its snapshots are unchanged.
- Each tab's content is built as plain row descriptors by pure code (`Modules/Guide/Views.lua`) and drawn by one pooled row list (`Modules/UI/Widgets/RowList.lua`). Frame code places widgets and passes clicks on.
- A profession the character has is always planned from the real skill, to a target the player may set. Pins cover a skill range and are saved. The margin scales stage quantities and never changes the recipes.
- Per-character planner data (target, pins, craft-or-buy choices, last tab) is stored under the character's GUID.
- Nothing is shown that is not known: no trainer or vendor is named unless the player visited it, rank steps carry no rank name, fee or level, and on the Vanilla data a learn step names no source.

### Alternatives Considered

- **A standalone custom-skinned window**: needs a full control kit and a second visual language beside the native panels and the settings.
- **Evolving the three panels in place**: delivers the features but keeps the panel sprawl, the duplicated Planning chrome and the shared shopping list.

### Trade-offs Accepted

- The steps and the shopping list can no longer be seen side by side.
- Native art differs per client, so the window looks different on Classic clients and on WoW Forever.
- A stage after a rank step may begin a few points below the cap, because steps are not re-cut.
- The merchant panel works from the path shown last in the session; there is none before a profession was opened.

### Consequences

- New window content is a change to a pure function with a headless test, not to frame code.
- Client calls for merchants, trainers and the map exist only in the client adapters; the boundary test enforces it.
- The Classic clients run the same code but are not tested in game; where a client call could not be confirmed (merchant calls, the skill line's cap, trainer lists) the feature checks first and stays inactive otherwise.

### Amended 2026-11-23

The window was rearranged around two questions - how far, and what does it cost - without changing how it is built:

- Two tabs, Path and Shopping, replace Guide / Steps / Shopping. The Path tab is one list with a row per recipe run; what the Guide card showed is the content of an opened row, and the learn step and the closest alternative are sub-lines under their run's row. Stages still carry learn steps as stages (the arrow tooltip uses them); only the list folds them.
- The target is a number box and a slider ("Level to") from the real skill to the last cap, in the shared header. Moving the handle only rewrites the number; the path is planned again once, when the handle is let go. It replaces the range filter: to see and shop for one bracket, the target is set to its end. The path bar and the Prev / Current step / Next buttons are gone.
- A receipt in the header replaces the footer: "You spend", "Back from selling" and "Net cost", built from the one accounting of ADR-017, with amounts exact to the copper so that they add up to the Shopping tab.
- "More options" (a remembered setting, off by default) holds what the default view does not need: the strategy, spare crafts (the margin), the selling mode, the price line, the recipe search, "Hide what I have", the craft-or-buy buttons and "Plan from skill 1".

The decision stands: frames are thin and content is built as data. The receipt, the slider's model and both tabs are pure functions in `Modules/Guide/Views.lua` with headless tests; `Modules/UI/GuideWindow.lua` places widgets and passes clicks on. `Modules/Guide/Range.lua` and `Modules/UI/PathBar.lua` were removed. The trade-off that the steps and the shopping list cannot be seen side by side still holds.

---

## ADR-017: Candidate Routes: Sale Value and Owned Stock, Never Dearer Than the Market Route

**Date:** 2026-11-23

**Status:** Accepted (supersedes ADR-008)

### Context

The addon is for one loop: open a profession, see the cheapest path from the real skill counting the materials already owned, auction prices and what the crafted items sell for, choose how far to level, get one total of what to buy. Two parts of that were not true in the planner. Owned stock was only subtracted from the shopping list afterwards: ADR-008 had removed it from scoring because free materials lured the greedy planner into dearer paths. And what a crafted item sells for was counted nowhere, so two recipes with the same reagents ranked the same even when one sells for far more.

ADR-008's trap had a concrete cause: stock was compared with the reagents of one craft, so owning enough for a single craft scored a run of up to fifty crafts as free.

### Decision

- One accounting. What the player pays is defined once: the shopping computation over a set of craft steps (owned stock taken off across the enabled sources, craft-or-buy applied, recipe costs added), minus what the crafts sell for (`Pathfinder:Account`). Totals and route comparisons use it.
- Sale value. One craft of a recipe sells for the vendor price of its crafted item by default; the auction price after the cut, or nothing, are settings. The Cheapest strategy takes it off a recipe's cost per craft when ranking, floored at zero (with a negative cost the cost per skill-up would improve as the skill-up chance falls), and only for recipes whose every reagent has a real price.
- Stock scoring against the run. A reagent the character owns costs, per craft, what the whole run still has to buy divided by its crafts. With nothing owned every score is what it was.
- Candidate routes. Under Cheapest the planner builds up to four routes, each costed by the one accounting: the market-price route as before (always), a route ranked with sale values (when any may be used), a route that also gets the owned stock (when the character owns a usable reagent), and the plan in hand: the route kept by the last calculation, carried on from the current skill (when one is remembered and usable stock is owned). Of the first three the cheapest for the player wins, a tie keeping the earlier one. The plan in hand is kept instead when it costs no more than the market route and no more than that winner plus a small margin (5% of what the market route costs with nothing owned). A candidate that leaves more of the skill range uncovered cannot win.
- The kept route is remembered per character and profession as recipe-per-skill-range, with the skill it was planned at. Carried on from that very skill, the same steps come out, however often it is calculated; from a later skill its bounds are read as whole skills, each recipe is held to the end of its range, and a recipe the planner could not choose any more (not obtainable, or without a known cost) is not forced. While the plan in hand is kept its remembered ranges stay as they are; what is planned where nothing is remembered (beyond a raised target, or where a pin was reset) is added. A pin or a reset forgets the remembered range it covers. Fastest and the what-if from skill 1 neither use nor replace the memory.

Because the market-price route is always a candidate and the plan in hand is never kept above it, the kept route never costs the player more than the route before this decision, by the addon's own accounting.

Why the plan in hand has to be a candidate, and has to be favoured: once the player holds the shopping list of a route, most routes cost next to nothing, and the greedy planner has no reason left to prefer the one it chose. Planned from scratch at every skill-up it wandered between them - using the long-lived recipe first and letting short-lived stock go grey - and the reagents bought for the abandoned route were stranded. Simulated on the bundled recipe data (buy the list, craft point by point with average luck, plan again at every skill), a player following the planner without the remembered route bought up to another 39% of the list later (9% on average with a little stock owned, 26% with a lot); with it, about the same as a player who simply followed the plan that was shopped for (under 1% of the list on average either way).

### Alternatives Considered

- Scoring with stock and no guard: rejected, it is the behaviour ADR-008 removed.
- Opportunity-cost pricing of owned stock (what it would sell for) inside the scoring: deferred, it needs sale prices for raw materials the addon does not trust yet.
- A dynamic-programming planner that allocates stock globally: not built; the guard gives the "never dearer" property without it.
- Auction resale as the default sale value: rejected, a listing may never sell and the total would show uncertain money as certain.

### Trade-offs Accepted

- Up to four planner runs per calculation instead of one (measured headless on the bundled recipe data: 4-10 ms for a plain run, about 30-45 ms for four candidates). Bag changes still do not plan again.
- Within the margin the plan in hand is kept although another candidate is a little cheaper: stability is worth more than a saving smaller than the rounding of the estimate. In rare states (heavy stock, bad luck) the margin holds on to a plan that a fresh calculation would have beaten by a few percent of the list.
- A run that follows a pin or a remembered range ends with that range, and no run carries on into one that begins further on; a recipe that cannot move the skill any more (at its grey point) gives way to the planner's own choice.
- Each new calculation rounds the crafts still expected, so the shopping list of a plan whose reagents were all bought can show a craft or two of top-up again while the plan is followed.
- The planner is still greedy: the kept route is the best of the candidates, not the optimum.
- Crafts that later steps of the same path use as reagents are still counted as sold, and the shopping list still has the player get them again; the shown net is an upper bound for a player who keeps them.
- One item per craft is assumed (the recipe data has no yield), so multi-yield recipes are understated.
- Among recipes that pay for themselves the zero floor makes the ranking blind to how much they pay; the comparison of whole routes catches the cases where that would cost the player.

### Consequences

- Routes can change with what the player owns and with what crafts sell for; `/lp diag prices` prints which candidate was kept and each candidate's amounts.
- After shopping, the player holds the reagents of the plan; the remembered route keeps that plan in place unless another route is clearly cheaper.
- New planner ideas can be added as further candidates without risk to the "never dearer" property.

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
