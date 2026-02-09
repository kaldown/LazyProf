# LazyProf Components

## Directory Structure

```
LazyProf/
├── LazyProf.toc               # Addon manifest (load order, dependencies, metadata)
├── Core/
│   ├── DependencyCheck.lua    # CraftLib validation on startup
│   ├── Constants.lua          # Skill brackets, colors, profession keys, enums
│   ├── Utils.lua              # FormatMoney, GetSkillUpChance, GetRacialProfessionBonus
│   ├── Config.lua             # AceConfig options table, default SavedVariables
│   └── Init.lua               # Addon initialization, slash commands, events, debug system
├── Professions/
│   └── Registry.lua           # CraftLib integration, learned recipe tracking
├── Modules/
│   ├── Inventory/
│   │   └── Scanner.lua        # Multi-source inventory scanning (bags/bank/mail/AH/guild/alts)
│   ├── Pricing/
│   │   ├── PriceManager.lua   # Provider orchestration, caching, fallback chain
│   │   └── Providers/
│   │       ├── TSM.lua        # TSM API integration (DBMinBuyout/DBMarket/DBRegionMarketAvg)
│   │       ├── Auctionator.lua # Auctionator API integration
│   │       └── Vendor.lua     # Vendor price fallback
│   ├── Recipes/
│   │   └── Availability.lua   # Recipe source checking (trainer/vendor/drop/inventory/AH)
│   ├── Pathfinder/
│   │   ├── Pathfinder.lua     # Path calculation orchestrator, pin management API
│   │   ├── MaterialResolver.lua # Intermediate material crafting (smelt ore to bars)
│   │   └── Strategies/
│   │       ├── Cheapest.lua   # Minimize gold spent strategy
│   │       └── Fastest.lua    # Minimize crafts strategy
│   └── UI/
│       ├── Arrow/
│       │   ├── ArrowManager.lua          # Arrow positioning, scroll caching
│       │   └── Strategies/
│       │       └── ArrowTooltip.lua      # Tooltip display modes (full vs simple)
│       ├── MilestoneBreakdown.lua        # Step-by-step path panel, alternatives, pinning
│       ├── MissingMaterials.lua          # Shopping list with multi-source breakdown
│       ├── RecipeDetails.lua             # Recipe info panel (reagents, vendors, difficulty bar)
│       ├── PlanningWindow.lua            # Standalone profession planning window
│       ├── ProfessionBrowser.lua         # Profession selection dropdown
│       └── MinimapButton.lua             # LibDBIcon minimap button
└── Libs/                                  # External dependencies (do not modify)
    ├── Ace3/                              # UI/Event framework
    ├── CraftLib/                          # Recipe database (git submodule)
    ├── LibDBIcon-1.0/                     # Minimap button positioning
    └── LibDataBroker-1.1/                 # Data broker protocol
```

## Core Components

### DependencyCheck.lua

**Purpose**: Validates CraftLib is loaded before the addon initializes.

If CraftLib is missing, shows a friendly error dialog and disables the addon gracefully.

### Constants.lua

**Purpose**: Shared enums, skill bracket definitions, and profession display data.

Defines `MILESTONES` (trainer skill thresholds), `STRATEGY`, `DISPLAY_MODE`, `PRICE_SOURCE`, `TSM_PRICE_SOURCE`, `MATERIAL_RESOLUTION`, `SOURCE_TYPE`, and `PROFESSIONS` lookup tables.

### Init.lua

**Purpose**: Addon lifecycle, event handling, slash commands, and debug system.

**Event handlers**:
- `TRADE_SKILL_SHOW` - Schedule path recalculation on profession window open
- `TRADE_SKILL_UPDATE` - Recalculate only when skill level actually changes (performance)
- `TRADE_SKILL_CLOSE` - Hide all LazyProf panels
- `BAG_UPDATE` - Lightweight shopping list refresh (no full recalc)

**Debug system**: Category-based logging with real-time window, category/bracket filtering, copy filtered/all.

### Registry.lua

**Purpose**: Bridge between LazyProf and CraftLib.

**Responsibilities**:
- Load profession data from CraftLib
- Detect currently open profession window
- Track and cache player's learned recipes
- Merge learned status into recipe data

## Pathfinder Components

### Pathfinder.lua

**Purpose**: Main path calculation orchestrator and pin management.

**Responsibilities**:
- Dispatch to selected strategy (Cheapest or Fastest)
- Manage session-only recipe pins (`PinRecipe`/`UnpinRecipe`/`ClearPins`)
- Track dirty pins for recalculate UI
- Generate milestone breakdown with skill brackets
- Calculate missing materials with multi-source inventory breakdown
- Log calculation triggers and active pins for debugging

### Strategies/Cheapest.lua & Fastest.lua

**Purpose**: Pluggable pathfinding strategies sharing a common interface.

Both implement `Calculate()`, `ScoreRecipe()`, and `GetCandidates()`. Cheapest minimizes gold spent per skillup; Fastest minimizes total number of crafts. Both support:
- Pin overrides from Pathfinder
- Recipe acquisition cost amortization
- Racial profession bonus adjustments
- Continuous skill-up probability formula
- Dynamic step size caps

### MaterialResolver.lua

**Purpose**: Resolve intermediate materials (e.g., smelt ore into bars) when cheaper than buying.

Three modes configured via settings: None, Cost-compare (default), Always craft.

### Availability.lua

**Purpose**: Determine if an unlearned recipe can be obtained.

Checks: player inventory (bags/bank/alts), trainer requirements (faction), vendor availability, AH listings (TSM/Auctionator price as proxy). Filters unavailable recipes from auto-selection but allows them in alternatives.

## Inventory & Pricing

### Scanner.lua

**Purpose**: Multi-source inventory scanning via Syndicator.

**Sources** (waterfall priority):
1. Bags (always scanned)
2. Bank (when "Include bank items" enabled)
3. Mail (always scanned for current character; alts when enabled)
4. Active AH listings (always scanned)
5. Guild bank (when "Include guild bank" enabled)
6. Alt characters (when "Include alt characters" enabled)

Returns `combined` inventory and `sourceBreakdown` for shopping list display.

### PriceManager.lua

**Purpose**: Abstract pricing across multiple providers with caching.

**Fallback chain**: TSM > Auctionator > Vendor. Price cache has 5-minute TTL with staleness detection.

### Providers (TSM.lua, Auctionator.lua, Vendor.lua)

Each implements `IsAvailable()` and `GetPrice(itemId)`. TSM supports configurable price source (MinBuyout/Market/RegionAvg). Vendor provides hardcoded prices for common vendor reagents.

## UI Components

### MilestoneBreakdown.lua

**Purpose**: Step-by-step path display panel with alternatives and pinning.

Uses a class pattern (`MilestonePanelClass`) supporting standalone and embedded modes. Features:
- Skill bracket headers with cost totals
- Expandable steps showing ingredients
- Collapsible "Alternatives" section with all scored candidates in groups of 5
- Pin/unpin by clicking alternative rows
- "Recalculate with N pins" button when pins are dirty
- Bracket filter dropdown (1-75, 75-150, 150-225, 225-300, 300-375, Full Path)

### MissingMaterials.lua

**Purpose**: Shopping list showing all materials needed with source breakdown.

**Sections**:
- From Bags (already owned)
- From Bank (Syndicator)
- Check Mail (mailbox items)
- Cancel from AH (active auction listings, orange styling)
- From Guild Bank (when enabled)
- From Alts (with character names)
- To Craft (intermediate materials)
- To Buy (from AH, with cost)

Supports bracket filtering synchronized with milestone panel.

### RecipeDetails.lua

**Purpose**: Side panel showing recipe information.

Displays: reagent list with have/need counts, difficulty bar with four thresholds (orange/yellow/green/gray), racial bonus adjustments, vendor locations with faction filtering, and Wowhead link.

### ArrowManager.lua & ArrowTooltip.lua

**Purpose**: Visual arrow indicator pointing to the next recipe to craft.

Arrow manager handles positioning within the TradeSkill scroll frame, caching recipe indices for performance. Two tooltip strategies: full (shows path preview) and simple (recipe name only).

### PlanningWindow.lua

**Purpose**: Standalone window for planning any profession's leveling path.

Embeds a `MilestonePanelClass` instance. Shows skill level, strategy toggle, and full path preview without needing to learn the profession.

### ProfessionBrowser.lua

**Purpose**: Dropdown menu listing all available professions for planning.

Accessible via minimap button left-click or `/lp browse`.

### MinimapButton.lua

**Purpose**: LibDBIcon minimap button for quick access.

Left-click opens profession browser, right-click opens settings.

## CraftLib Integration

LazyProf reads from CraftLib via `_G.CraftLib`:

```lua
-- Get recipes for a profession
local recipes = CraftLib:GetRecipes("cooking")

-- Check if item can be crafted (for material resolution)
local producers = CraftLib:GetRecipeByProduct(itemId)
```
