# LazyProf Architecture Overview

## Purpose

LazyProf calculates the optimal path to level professions in World of Warcraft. It integrates with CraftLib for recipe data and pricing addons (TSM, Auctionator) for cost calculations. Users can choose between Cheapest (minimize gold) and Fastest (minimize crafts) strategies.

## System Design

```
+------------------------------------------------------------------+
|                        LazyProf UI                                |
|   (Arrow, Milestones, Shopping List, Recipe Details, Planning)    |
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
7. **Display**: UI shows milestone breakdown, shopping list (with source breakdown), and arrow
8. **Pin** (optional): User browses alternatives, pins overrides, recalculates path

## Key Modules

| Module | Responsibility |
|--------|----------------|
| `Core/` | Init, Config, Utils, Constants, DependencyCheck |
| `Professions/` | CraftLib integration, learned recipe tracking |
| `Modules/Inventory/` | Multi-source inventory scanning (bags/bank/mail/AH/guild/alts) |
| `Modules/Pricing/` | Price provider abstraction with fallback chain |
| `Modules/Recipes/` | Recipe availability checking |
| `Modules/Pathfinder/` | Path calculation strategies, material resolution, pin management |
| `Modules/UI/` | Arrow, milestones, shopping list, recipe details, planning window, minimap |
