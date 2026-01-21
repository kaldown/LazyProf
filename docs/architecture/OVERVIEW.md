# LazyProf Architecture Overview

## Purpose

LazyProf calculates the optimal (cheapest) path to level professions in World of Warcraft. It integrates with CraftLib for recipe data and pricing addons (TSM, Auctionator) for cost calculations.

## System Design

```
┌─────────────────────────────────────────────────────────┐
│                     LazyProf UI                          │
│         (Arrow, Milestones, Shopping List)              │
│                         │                                │
│                         ▼                                │
│              ┌─────────────────────┐                    │
│              │    Pathfinder       │                    │
│              │   (Strategies)      │                    │
│              └─────────────────────┘                    │
│                    │         │                          │
│         ┌──────────┘         └──────────┐              │
│         ▼                               ▼              │
│   ┌──────────┐                   ┌──────────┐         │
│   │ Registry │                   │ Pricing  │         │
│   │(CraftLib)│                   │ Manager  │         │
│   └──────────┘                   └──────────┘         │
│         │                               │              │
│         ▼                               ▼              │
│   ┌──────────┐        ┌──────────┬──────────┐        │
│   │ CraftLib │        │   TSM    │Auctionator│        │
│   │  Addon   │        │ Pricing  │ Pricing  │        │
│   └──────────┘        └──────────┴──────────┘        │
└─────────────────────────────────────────────────────────┘
```

## External Dependencies

| Dependency | Required | Purpose |
|------------|----------|---------|
| CraftLib | Yes | Recipe database |
| TradeSkillMaster | No | TSM pricing data |
| Auctionator | No | Auctionator pricing data |
| Syndicator | No | Bank inventory scanning |

## Data Flow

1. **Load**: Registry loads profession data from CraftLib
2. **Detect**: Registry detects which profession is open
3. **Price**: PriceManager queries TSM/Auctionator/Vendor for material costs
4. **Calculate**: Pathfinder computes optimal leveling path
5. **Display**: UI shows milestones, shopping list, and next-craft arrow

## Key Modules

| Module | Responsibility |
|--------|----------------|
| `Core/` | Init, Config, Utils, Constants |
| `Modules/Inventory/` | Bag and bank scanning |
| `Modules/Pricing/` | Price provider abstraction |
| `Modules/Pathfinder/` | Path calculation strategies |
| `Modules/UI/` | User interface components |
| `Professions/` | CraftLib integration |
