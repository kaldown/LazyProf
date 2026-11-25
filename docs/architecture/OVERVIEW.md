# LazyProf Architecture Overview

## Purpose

LazyProf calculates the optimal path to level professions in World of Warcraft. It integrates with CraftLib for recipe data and pricing addons (TSM, Auctionator) for cost calculations. Users can choose between Cheapest (minimize gold) and Fastest (minimize crafts) strategies.

The addon is built around one loop: open a profession, see the cheapest path from the real skill - counting the stock already owned, current prices and what the crafted items sell for - choose how far to level, and get one total of what to buy. The default view answers only that (how far, what it costs, what to buy, which recipes); the rest sits behind "More options" or in the settings.

## System Design

```
+------------------------------------------------------------------+
|                        LazyProf UI                                |
|   (Arrow, LazyProf window, Recipe Details, Merchant panel)        |
|                           |                                       |
|                           v                                       |
|               +---------------------+                             |
|               |     Pathfinder      |                             |
|               | (Cheapest/Fastest)  |                             |
|               +---------------------+                             |
|                  |    |    |    |                                  |
|        +---------+    |    |    +---------+                       |
|        v              v    v              v                       |
|   +----------+  +----------+  +----------+  +--------------+     |
|   | Registry |  | Pricing  |  |Inventory |  | Availability |     |
|   |(CraftLib)|  | Manager  |  | Scanner  |  |   Checker    |     |
|   +----------+  +----------+  +----------+  +--------------+     |
|        |              |             |               |             |
|        v              v             v               v             |
|   +----------+  +----------+  +----------+  +--------------+     |
|   | CraftLib |  |TSM/Auc/  |  |Syndicator|  | TSM/Auc/     |     |
|   |  Addon   |  | Vendor   |  | (opt.)   |  | Inventory    |     |
|   +----------+  +----------+  +----------+  +--------------+     |
+------------------------------------------------------------------+
```

## External Dependencies

| Dependency | Required | Purpose |
|------------|----------|---------|
| CraftLib | Yes | Recipe database with skill-up data |
| TradeSkillMaster | No | AH pricing data (recommended) |
| Auctionator | No | Alternative AH pricing |
| Syndicator | No | Stock outside the bags: bank, mail, own auctions, alts, guild bank. Without it only the carried bags of the character played count, and the Shopping tab says so |

## Data Flow

1. **Load**: Registry loads profession data from CraftLib
2. **Detect**: Registry detects which profession window is open (through the client adapter, which also gives the skill and the learned recipes)
3. **Scan**: Inventory Scanner collects items from the bags and, with Syndicator, from bank, mail, AH listings, alts and guild bank
4. **Price**: PriceManager prices every reagent (vendor price first, then TSM / Auctionator, then the vendor sell value as an estimate) and records where each price came from
5. **Sale value**: SaleValue works out what one craft of each usable recipe sells for (to a vendor by default)
6. **Check**: Availability module filters recipes by obtainability
7. **Calculate**: the strategy scores all candidates per skill level, respecting pins and racial bonuses. Under Cheapest the planner builds up to four candidate routes (market prices only; ranked with sale value; with the owned stock; the route kept last, carried on) and keeps the one the player pays least for; a plan already followed is kept over small differences, never above the market route
8. **Account**: what the player pays is defined once - the shopping list of the path's crafts (stock taken off, craft-or-buy applied, recipes added), less what the crafts sell for. The route comparison and every total shown use it
9. **Stage**: path steps are folded into stages (craft runs, learn and rank steps, gaps)
10. **Display**: the LazyProf window shows the target ("Level to"), the receipt and the stages (Path / Shopping tabs), and the arrow marks the next recipe
11. **Choose** (optional): moving the target plans again to the new skill; "Use" on an alternative pins it over the run's skill range and the path is planned again at once

A change in the bags does not plan the route again: the stock is rescanned into the shown path and the window redrawn. The route is planned again when the profession window opens, the skill changes, the target, strategy, a pin or a setting changes, item data arrives, the auction house closes, or a merchant shows a vendor price not seen before (with the profession window open).

## Key Modules

| Module | Responsibility |
|--------|----------------|
| `Core/` | Init, Config, Utils, Constants, DependencyCheck, the client adapters (`Client/`), per-character planner data (`CharStore`) |
| `Professions/` | CraftLib integration, learned recipe tracking |
| `Modules/Inventory/` | Multi-source inventory scanning (bags/bank/mail/AH/guild/alts) |
| `Modules/Pricing/` | Price provider abstraction with fallback chain; what crafted items sell for |
| `Modules/Recipes/` | Recipe availability checking, Self-Found mode |
| `Modules/Pathfinder/` | Path calculation strategies, candidate routes, the accounting of what a path costs, material resolution, pin management |
| `Modules/Guide/` | Stages, the receipt and tab contents as data, remembered trainers |
| `Modules/Shopping/` | Remembered vendor prices, merchant purchase queue |
| `Modules/UI/` | Arrow, the LazyProf window and its widgets, recipe details, merchant panel, minimap |

See [COMPONENTS.md](COMPONENTS.md) for each file and [DECISIONS.md](DECISIONS.md) for why (ADR-016: the window; ADR-017: candidate routes, sale value and owned stock).
