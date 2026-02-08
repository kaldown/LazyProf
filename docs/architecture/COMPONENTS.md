# LazyProf Components

## Directory Structure

```
LazyProf/
├── LazyProf.toc           # Addon manifest
├── Core/
│   ├── Init.lua           # Addon initialization
│   ├── Config.lua         # Settings management
│   ├── Utils.lua          # Utility functions
│   └── Constants.lua      # Shared constants
├── Modules/
│   ├── Inventory/
│   │   └── BagScanner.lua # Bag inventory scanning
│   ├── Pricing/
│   │   ├── PriceManager.lua   # Price provider abstraction
│   │   ├── TSMProvider.lua    # TSM integration
│   │   ├── AuctionatorProvider.lua # Auctionator integration
│   │   └── VendorProvider.lua # Vendor price fallback
│   ├── Pathfinder/
│   │   ├── Pathfinder.lua     # Path calculation orchestrator
│   │   └── Cheapest.lua       # Minimize gold strategy
│   └── UI/
│       ├── Arrow.lua          # Next-craft indicator
│       ├── MilestoneBreakdown.lua # Path steps panel
│       ├── MissingMaterials.lua   # Shopping list
│       └── RecipeDetails.lua  # Recipe info panel
├── Professions/
│   └── Registry.lua       # CraftLib integration
└── Libs/
    └── Ace3/              # UI/Event framework
```

## Core Components

### Registry.lua

**Purpose**: Bridge between LazyProf and CraftLib.

**Responsibilities**:
- Load profession data from CraftLib
- Detect currently open profession
- Track player's learned recipes

### Pathfinder.lua

**Purpose**: Calculate optimal leveling path.

**Responsibilities**:
- Accept strategy (Cheapest, Fastest)
- Query pricing for all recipes
- Build path from current skill to target
- Store all scored alternatives per step
- Manage session-only recipe pins (user overrides via `PinRecipe`/`UnpinRecipe`)
- Return ordered list of recipes to craft

### PriceManager.lua

**Purpose**: Abstract pricing across multiple sources.

**Responsibilities**:
- Query TSM, Auctionator, or Vendor prices
- Handle missing prices gracefully
- Cache prices for performance

## UI Components

### MilestoneBreakdown.lua

Shows the calculated path broken into milestones (skill brackets).

**Alternative recipes**: Expanding a step shows ingredients, then a collapsible "Alternatives" section with all scored candidates grouped in packs of 5. Users can pin alternative recipes and recalculate the path. Pins are session-only.

### MissingMaterials.lua

Shopping list showing all materials needed, with sources:
- From Bags (already owned)
- From Bank (if Syndicator enabled)
- To Buy (from AH)

### Arrow.lua

Points to the next recipe the player should craft.

## CraftLib Integration

LazyProf reads from CraftLib via `_G.CraftLib`:

```lua
-- Get recipes for a profession
local recipes = CraftLib:GetRecipes("cooking")

-- Check if item can be crafted
local producers = CraftLib:GetRecipeByProduct(itemId)
```
