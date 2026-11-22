# LazyProf Architecture Overview

## Purpose

LazyProf calculates the optimal path to level professions in World of Warcraft. It integrates with CraftLib for recipe data and pricing addons (TSM, Auctionator) for cost calculations. Users can choose between Cheapest (minimize gold) and Fastest (minimize crafts) strategies.

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
| Syndicator | No | Extended inventory: bank, alts, mail, guild bank |

## Data Flow

1. **Load**: Registry loads profession data from CraftLib
2. **Detect**: Registry detects which profession window is open
3. **Price**: PriceManager queries TSM/Auctionator/Vendor for material costs
4. **Scan**: Inventory Scanner collects items from bags, bank, mail, AH listings, guild bank, alts
5. **Check**: Availability module filters recipes by obtainability
6. **Calculate**: Strategy scores all candidates per skill level, respecting pins and racial bonuses
7. **Stage**: path steps are folded into stages (craft runs, learn and rank steps, gaps)
8. **Display**: the LazyProf window shows the stages (Guide / Steps / Shopping tabs) and the arrow marks the next recipe
9. **Pin** (optional): "Use this" on an alternative pins it over the step's skill range and the path is planned again at once

## Key Modules

| Module | Responsibility |
|--------|----------------|
| `Core/` | Init, Config, Utils, Constants, DependencyCheck |
| `Professions/` | CraftLib integration, learned recipe tracking |
| `Modules/Inventory/` | Multi-source inventory scanning (bags/bank/mail/AH/guild/alts) |
| `Modules/Pricing/` | Price provider abstraction with fallback chain |
| `Modules/Recipes/` | Recipe availability checking |
| `Modules/Pathfinder/` | Path calculation strategies, material resolution, pin management |
| `Modules/Guide/` | Stages, range filter, tab contents as data, remembered trainers |
| `Modules/Shopping/` | Remembered vendor prices, merchant purchase queue |
| `Modules/UI/` | Arrow, the LazyProf window and its widgets, recipe details, merchant panel, minimap |
