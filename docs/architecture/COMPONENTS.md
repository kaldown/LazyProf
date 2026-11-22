# LazyProf Components

## Directory Structure

```
LazyProf/
├── LazyProf.toc               # Addon manifest (load order, dependencies, metadata)
├── Core/
│   ├── DependencyCheck.lua    # CraftLib validation on startup
│   ├── Constants.lua          # Profession keys, enums, tuning constants
│   ├── Utils.lua              # FormatMoney, GetSkillUpChance, GetRacialProfessionBonus
│   ├── Client/
│   │   ├── Family.lua         # Which client family is running ("classic" or "forever")
│   │   ├── Classic.lua        # Client adapter for the Classic clients
│   │   └── Forever.lua        # Client adapter for WoW Forever
│   ├── Config.lua             # AceConfig options table, default SavedVariables, settings migration
│   ├── CharStore.lua          # Per-character planner data, kept under the character's GUID
│   └── Init.lua               # Addon initialization, slash commands, events, diagnostics, debug system
├── Professions/
│   └── Registry.lua           # CraftLib integration, learned recipe tracking
├── Modules/
│   ├── Inventory/
│   │   └── Scanner.lua        # Multi-source inventory scanning (bags/bank/mail/AH/guild/alts)
│   ├── Pricing/
│   │   ├── PriceManager.lua   # Provider orchestration, caching, price provenance
│   │   └── Providers/         # TSM, Auctionator, Vendor (buy price), VendorSell (sell-value estimate)
│   ├── Recipes/
│   │   ├── Availability.lua   # Recipe source checking (trainer/vendor/drop/inventory/AH)
│   │   └── SelfFound.lua      # Self-Found mode: what is obtainable without the auction house
│   ├── Pathfinder/
│   │   ├── Pins.lua           # Pinned recipes as skill ranges
│   │   ├── StrategyCore.lua   # The simulation loop both strategies share (gaps, bridges, pins)
│   │   ├── Strategies/        # Cheapest.lua, Fastest.lua: scoring and step sizes
│   │   ├── MaterialResolver.lua # Craft-or-buy for intermediate reagents (one level)
│   │   └── Pathfinder.lua     # Path calculation, target skill, pin API, shopping list
│   ├── Guide/                 # Pure logic behind the window (no frames)
│   │   ├── Text.lua           # Wording shared by tabs, tooltip and tests
│   │   ├── Range.lua          # The range (skill bracket) filter
│   │   ├── Stages.lua         # Folds path steps into craft / learn / rank / gap stages, margin, totals
│   │   ├── TrainerMemory.lua  # Visited trainers and the fees they charged
│   │   └── Views.lua          # What each tab shows, as row descriptors
│   ├── Shopping/
│   │   ├── VendorMemory.lua   # Vendor prices seen at merchants
│   │   └── PurchaseQueue.lua  # What to buy at a merchant, and buying it chunk by chunk
│   └── UI/
│       ├── Widgets/           # PanelShell, RowPool, RowList, Dropdown, Tabs, Controls
│       ├── Arrow/             # ArrowManager.lua, Strategies/ArrowTooltip.lua
│       ├── PathBar.lua        # The coloured path bar
│       ├── GuideWindow.lua    # The LazyProf window: header, Guide / Steps / Shopping tabs, planning mode
│       ├── RecipeDetails.lua  # Recipe info panel (reagents, sources, difficulty bar)
│       ├── MerchantPanel.lua  # Panel beside the merchant window
│       ├── ProfessionBrowser.lua # Profession selection popup
│       └── MinimapButton.lua  # Minimap button / addon compartment entry
├── scripts/                   # Headless test suites (lua5.1), not shipped
└── Libs/                      # External dependencies (do not modify)
    ├── Ace3/                  # UI/Event framework
    ├── CraftLib/              # Recipe database (git submodule)
    ├── LibDBIcon-1.0/         # Minimap button positioning
    └── LibDataBroker-1.1/     # Data broker protocol
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
- Plan from the character's real skill to the target skill set for the profession (the last cap by default)
- Keep pinned recipes: a pin covers a skill range and is saved per character and profession (`PinRange`/`UnpinAt`/`ClearPins`)
- Calculate the shopping list: per-source lists and one row per item (need / have / buy / cost, craft-or-buy)
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

### GuideWindow.lua

**Purpose**: The LazyProf window - one framed, tabbed window beside the profession window.

A shared header (status line, target box, Cheapest / Fastest, "With margin", range dropdown, path bar) sits above three tabs:
- **Guide** - a card for one step (craft, learn, train, or gap) with its reagent table, the best alternatives with "Use this", and the next two steps
- **Steps** - one row per stage, expandable to its reagents, plus recipe search
- **Shopping** - "Collect first" (bank, mail, auctions, guild bank, alts) and a Need / Have / Buy / Cost table with a craft-or-buy button per craftable reagent

The window has two modes: docked to the profession window (live), and undocked for any profession picked from the minimap button or `/lp browse` (planning). The file only places widgets; what each tab shows is built as plain data by `Modules/Guide/Views.lua` from the stages of `Modules/Guide/Stages.lua`, and drawn by `Widgets/RowList.lua`.

### PathBar.lua

**Purpose**: The whole path as one strip - a coloured segment per stage, gaps in red, a tick per rank still to train, a marker at the real skill.

### MerchantPanel.lua

**Purpose**: Beside the merchant window, lists the shopping-list reagents the merchant sells, with Buy per row and "Buy all".

The plan and the chunk-by-chunk buying are pure code in `Modules/Shopping/PurchaseQueue.lua`; the merchant is reached only through the client adapter.

### RecipeDetails.lua

**Purpose**: Side panel showing recipe information.

Displays: reagent list with have/need counts, difficulty bar with four thresholds (orange/yellow/green/gray), racial bonus adjustments, vendor locations with faction filtering, and Wowhead link.

### ArrowManager.lua & ArrowTooltip.lua

**Purpose**: Visual arrow indicator pointing to the next recipe to craft.

Arrow manager handles positioning within the TradeSkill scroll frame, caching recipe indices for performance. Two tooltip strategies: full (shows path preview) and simple (recipe name only).

### ProfessionBrowser.lua

**Purpose**: Popup listing all available professions; a click opens the LazyProf window in planning mode on that profession.

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
