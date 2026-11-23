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
│   │   ├── StockMemory.lua    # Each character's bags and bank as last seen, the account bank per world
│   │   └── Scanner.lua        # Multi-source inventory scanning (bags/bank/mail/AH/guild/alts)
│   ├── Pricing/
│   │   ├── PriceManager.lua   # Provider orchestration, caching, price provenance, /lp diag prices
│   │   ├── SaleValue.lua      # What one craft of a recipe sells for (vendor, auction, nothing)
│   │   └── Providers/         # TSM, Auctionator, Vendor (buy price), VendorSell (sell-value estimate)
│   ├── Recipes/
│   │   ├── Availability.lua   # Recipe source checking (trainer/vendor/drop/inventory/AH)
│   │   └── SelfFound.lua      # Self-Found mode: what is obtainable without the auction house
│   ├── Pathfinder/
│   │   ├── Pins.lua           # Pinned recipes as skill ranges
│   │   ├── StrategyCore.lua   # The simulation loop both strategies share (gaps, bridges, pins,
│   │   │                      # carrying on a remembered route, stock counted against whole runs)
│   │   ├── Strategies/        # Cheapest.lua, Fastest.lua: scoring and step sizes
│   │   ├── MaterialResolver.lua # Craft-or-buy for intermediate reagents (one level)
│   │   └── Pathfinder.lua     # Path calculation, candidate routes, the one accounting of what
│   │                          # the player pays, target skill, pin API, shopping list
│   ├── Guide/                 # Pure logic behind the window (no frames)
│   │   ├── Text.lua           # Wording shared by tabs, tooltip and tests
│   │   ├── Stages.lua         # Folds path steps into craft / learn / rank / gap stages, margin, totals
│   │   ├── TrainerMemory.lua  # Visited trainers and the fees they charged
│   │   └── Views.lua          # What the window shows, as data: receipt, target, both tabs, tooltips
│   ├── Shopping/
│   │   ├── VendorMemory.lua   # Vendor prices seen at merchants
│   │   └── PurchaseQueue.lua  # What to buy at a merchant, and buying it chunk by chunk
│   └── UI/
│       ├── Widgets/           # PanelShell, RowPool, RowList, Dropdown, Tabs, Controls, Slider
│       ├── Arrow/             # ArrowManager.lua, Strategies/ArrowTooltip.lua
│       ├── GuideWindow.lua    # The LazyProf window: header (target, receipt, More options), Path / Shopping tabs, planning mode
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

**Purpose**: Shared enums, tuning constants, and profession display data.

Defines `STRATEGY`, `DISPLAY_MODE`, `PRICE_SOURCE`, `TSM_PRICE_SOURCE`, `MATERIAL_RESOLUTION`, `SALE_MODE`, `SOURCE_TYPE` and the `PROFESSIONS` lookup table, plus tuning values such as `AUCTION_CUT` (the auction house's share of a sale), `SALE_LOADING_TIMEOUT`, `PRICE_CACHE_TTL`, `PRICE_STALE_DAYS` and `BRIDGE_MIN_CHANCE`. Skill caps are not defined here: they come with each profession's recipe data.

### Init.lua

**Purpose**: Addon lifecycle, event handling, slash commands, and debug system.

**Profession window** (the event names differ per client, so the client adapter listens and calls back):
- opened - schedule a path recalculation, dock the LazyProf window
- updated - recalculate only when the skill or the profession actually changed (performance)
- closed - hide the arrow and the recipe details; the window hides or goes back to a planning view

**Events registered here**:
- `BAG_UPDATE` - lightweight refresh: the stock is rescanned into the shown path and the window redrawn. A change of stock never plans the route again by itself. The update is also passed to the inventory scanner, which remembers the bags (and the bank while its window is open); the addon has this one handler for the event
- `GET_ITEM_INFO_RECEIVED` - item data arrived for a reagent priced by the floor, or for a crafted item whose sale value was waiting: one recalculation once the stream has gone quiet
- `AUCTION_HOUSE_CLOSED` - cached prices are expired and, with a profession window open, the path is planned again

**Debug system**: Category-based logging with real-time window, category/bracket filtering, copy filtered/all. The `/lp diag ...` dumps open in a copyable window.

### Registry.lua

**Purpose**: Bridge between LazyProf and CraftLib.

**Responsibilities**:
- Load profession data from CraftLib
- Detect currently open profession window
- Track and cache player's learned recipes
- Merge learned status into recipe data

## Pathfinder Components

### Pathfinder.lua

**Purpose**: Main path calculation orchestrator, the accounting of what a path costs, and pin management.

**Responsibilities**:
- Dispatch to selected strategy (Cheapest or Fastest)
- Plan from the character's real skill to the target skill set for the profession (the last cap by default)
- Plan the candidate routes (`PlanRoutes`). Under Cheapest up to four: `market` (market prices, nothing owned, always), `sale` (ranked with sale values), `stock` (as `sale`, with the owned stock) and `previous` (the route kept last, carried on from the current skill). The one the player pays least for is kept; the plan in hand is kept over small differences and never above the market route. Fastest plans one route
- Remember the kept route per character and profession as recipe-per-skill-range (`RouteRanges`, `ExtendRanges`, `ForgetRoute`)
- Define what the player pays, once (`Account`): the shopping list of a set of craft steps, less what the crafts sell for. Route comparisons and every total shown use it
- Keep pinned recipes: a pin covers a skill range and is saved per character and profession (`PinRange`/`UnpinAt`/`ClearPins`); pinning or unpinning forgets the remembered route over that range
- Calculate the shopping list (`CalculateMissingMaterials`): per-source lists, one row per item (need / have / buy / cost, craft-or-buy) and the recipes still to buy or learn. It works only from the stock it is handed, so it can be asked "what if nothing were owned"
- Log calculation triggers, active pins and the kept route for debugging

See ADR-017 in [DECISIONS.md](DECISIONS.md) for why the routes are chosen this way.

### StrategyCore.lua

**Purpose**: The one simulation loop both strategies run.

At each simulated skill it scores the candidates, picks the best (a pin overrides the choice; a remembered range is followed when the planner could choose that recipe itself), sizes the run and moves on. A range with no usable recipe is bridged with a green recipe while its skill-up chance is at least 10%, otherwise recorded as a gap. A run that follows a pin or a remembered range ends with that range. `ReagentCostPerCraft` counts owned stock against the whole run a recipe would get, not against one craft; with nothing owned it gives the plain market cost.

### Strategies/Cheapest.lua & Fastest.lua

**Purpose**: Pluggable pathfinding strategies sharing a common interface.

Both implement `Calculate()`, `ScoreRecipe()`, and `GetCandidates()`. Cheapest minimizes gold spent per skillup; Fastest minimizes total number of crafts. Both support:
- Pin overrides from Pathfinder
- Racial profession bonus adjustments
- Continuous skill-up probability formula
- Dynamic step size caps

Cheapest also amortizes the cost of getting an unlearned recipe over its expected crafts and, when sale values are passed for ranking, takes what a craft sells for off its cost (never below zero).

### MaterialResolver.lua

**Purpose**: Resolve intermediate materials (e.g., smelt ore into bars) when cheaper than buying.

Three modes configured via settings: None, Cost-compare (default), Always craft. A per-item choice of the player ("I craft it" / "I buy it") overrides the mode. Resolution is one level deep.

### Availability.lua

**Purpose**: Determine if an unlearned recipe can be obtained.

Checks: player inventory (bags/bank/alts), trainer requirements (faction), vendor availability, AH listings (TSM/Auctionator price as proxy). Filters unavailable recipes from auto-selection but allows them in alternatives.

## Inventory & Pricing

### Scanner.lua

**Purpose**: What the character owns, from every enabled source.

The bags are read live through the client adapter. Stock outside them comes from the Syndicator addon when it is installed, otherwise from LazyProf's own memory (`StockMemory.lua`).

**Sources** (in the order the shopping list draws on them):
1. Bags (always scanned)
2. Bank (when "Include bank items" is on - the default). From memory: the character's bank and the account bank of its world, as last seen with the bank window open
3. Mail (always scanned with Syndicator; not known without it)
4. Active AH listings (always scanned with Syndicator; not known without it)
5. Guild bank (when "Include guild bank" is on - off by default; Syndicator only)
6. Alt characters (when "Include alt characters" is on - the default): with Syndicator their bags, bank, mail and listings; from memory the bags and banks of the remembered characters of the same world and faction, without soulbound items

A character in Self-Found mode cannot be sent anything, so nothing that belongs to other characters is counted for it, from either place. It cannot send anything either: every save of its stock stores that, and the memory does not offer it to the other characters as an alt.

Returns the `combined` inventory, a `sourceBreakdown` that says where each item is and, when the stock outside the bags is remembered, a `meta` table with how old each part is (it travels on the path as `path.stockMeta`, and the "Collect first" tooltips of the Shopping tab are worded from it). The same stock is used for the route (Cheapest), every total and the shopping list.

The scanner also keeps the memory up to date, and does nothing of it while Syndicator is installed. The bags are saved two seconds after a bag update (one save for a burst) and, when a save is still waiting, at logout; bags that report no backpack slots are not saved, and bags that read as completely empty only when a bag update came before the read (at login and at logout nothing says their contents are loaded). The bank is read only while its window is open - when it opens and on the frame after any bag update or tab change - and a bank the adapter cannot read leaves what is remembered untouched. In the first half second after the window opened a read without a single item is not taken for an empty bank; it is looked at again when that time is over. Nothing is read when the window closes. None of this plans the path again.

### StockMemory.lua

**Purpose**: What each character had in its bags and bank when it was last seen, and the account bank per world. Pure: the character, the items and the time are passed in.

One record per character GUID in `LazyProfDB.global.stock`, replaced on every save, with the character's name, world and faction. The saved table is read defensively - whatever is not what the module writes (a record that is not a table, a count that is not a positive whole number) is skipped and replaced by the next save - and the scanner runs everything that touches the memory protected: a failure leaves a scan with the live bags and is shown by `/lp diag stock`, it never stops the addon. The world is region and ruleset on WoW Forever (there are no realms) and the realm name elsewhere; the client adapter supplies it. Alts are the other records of the same world and faction; a second record under one name is counted once, and soulbound counts are taken off what an alt can supply. Records not seen for 180 days are dropped at login (never the character being played). The table carries a format number that is written by the module, not by the database defaults; a table in another format is left alone.

### PriceManager.lua

**Purpose**: Abstract pricing across multiple providers with caching, and remember where each price came from.

**Reagent price chain**: a vendor buy price first; then an Auctionator price seen today, once the auction house was visited this session; then the market providers in the configured order (TSM, Auctionator); then, with the estimate option on (the default), the vendor sell value and after it a 1-copper floor (item data still loading, or the item has no sell value); with the option off, no price. Prices are cached for 5 minutes; leaving the auction house expires the cache.

`MarketPrice` gives what the auction addons say an item goes for (never a vendor price, an estimate or the floor); the sale value of a crafted item is built on it. `PathSummary` / `SummaryLines` count a path's prices by source and word the warnings; `RunDiagnostic` is `/lp diag prices`.

### SaleValue.lua

**Purpose**: What one craft of a recipe sells for, in copper, by the "Count what crafts sell for" setting.

- `vendor` (default): the vendor's price for the crafted item, from the game's item data
- `auction`: the item's market price after the 5% cut, never below the vendor value; without a market price, the vendor value
- `none`: nothing

One item per craft is assumed, and a recipe without a crafted item (an enchant) sells for nothing. `Build` returns the values of the recipes that can be on the path, their sources, and a `rank` table holding only the recipes whose every reagent has a real price (a vendor's or an auction addon's): only those may be ranked by sale value. Crafted items whose data the client has not delivered count as loading for 20 seconds; when the data arrives the path is planned again.

### Providers (TSM.lua, Auctionator.lua, Vendor.lua, VendorSell.lua)

Each implements `IsAvailable()` and `GetPrice(itemId)`. TSM supports a configurable price source (Recent/MinBuyout/Market/RegionAvg) and falls back to the others when it has no value. Vendor gives vendor buy prices: from TSM or Auctionator's merchant data, from merchants LazyProf saw itself (`Modules/Shopping/VendorMemory.lua`), then from the vendor list shipped with the recipe data. VendorSell gives an item's vendor sell value, used as the last-resort estimate.

## UI Components

### GuideWindow.lua

**Purpose**: The LazyProf window - one framed window with two tabs beside the profession window.

A shared header answers how far and what it costs, and sits above the tabs. It is a stack of blocks, laid out top down from what is shown:
- the status line ("Skill 117 / 150") with the "More options" / "Fewer options" switch
- with More options: Cheapest / Fastest, "Spare crafts", the "Selling" dropdown and the price line (in planning, for a profession the character has, also "Plan from skill 1")
- in planning: the profession dropdown
- **the target**: "Level to", a number box and a slider from the real skill to the last cap. Moving the handle only rewrites the number; letting go (or Enter in the box) stores the target and plans again, once
- **the receipt**: "You spend", "Back from selling", "Net cost" and its notes (`Views.Receipt`)
- with More options: the recipe search (Path tab) or "Hide what I have" (Shopping tab)

The tabs:
- **Path** - one row per recipe run (skill range, crafts, cost), with "Learn first" and the closest alternative as sub-lines, thin rows for rank steps and gaps. A click opens a run in place: reagent table, what a craft sells for, how to learn the recipe, the other recipes for the range with "Use"
- **Shopping** - "Collect first" (bank, mail, auctions, guild bank, alts), a Need / Have / Buy / Cost table (to buy first, then crafted, then owned) with "Reagents to buy", and "Recipes to learn". With More options a craft-or-buy button per craftable reagent

The window has two modes: docked to the profession window (live), and undocked for any profession picked from the minimap button, the addon compartment or `/lp browse` (planning). The file only places widgets and passes clicks on; what the header and each tab show is built as plain data by `Modules/Guide/Views.lua` from the stages of `Modules/Guide/Stages.lua` and the path's account (`Pathfinder:Account`), and drawn by `Widgets/RowList.lua`.

### Views.lua, Stages.lua, Text.lua (Modules/Guide)

**Purpose**: Everything the window says, as data, without a frame.

`Stages.Build` folds the planner's steps into stages and costs each run against the stock left by the runs before it; it also projects every alternative over the whole run, craft by craft. `Views` turns a view (path, stages, account, window state) into the receipt's lines (`Receipt`), the slider's model (`Target`), the rows of each tab (`Path`, `Shopping`), the arrow tooltip (`ArrowTooltip`) and the merchant panel's rows (`Merchant`). `Text` holds the shared wording. Amounts that are added up are written to the copper, so what is shown adds up; new content is tested here, in `scripts/test_views.lua`.

### Widgets (Modules/UI/Widgets)

**Purpose**: The frame building blocks: the frame code that differs per client (the minimap button / addon compartment entry aside).

`PanelShell` (saved position and size, closed state, combat hide and restore), `RowPool` and `RowList` (a scrolling list drawn from row descriptors with reused rows; its scroll bar shows only while something scrolls), `Dropdown` and `Tabs` (one implementation per client family), `Controls` (button group, number box, checkbox, search box, resize grip) and `Slider` (a whole-number slider that tells moving the handle from letting it go).

### MerchantPanel.lua

**Purpose**: Beside the merchant window, lists the shopping-list reagents the merchant sells, with Buy per row and "Buy all".

The list is the whole shopping list of the path the window showed last, worked out again from the current stock. The plan and the chunk-by-chunk buying are pure code in `Modules/Shopping/PurchaseQueue.lua`; the merchant is reached only through the client adapter.

### RecipeDetails.lua

**Purpose**: Side panel showing recipe information.

Displays: reagent list with have/need counts, difficulty bar with four thresholds (orange/yellow/green/gray), racial bonus adjustments, vendor locations with faction filtering, and Wowhead link.

### ArrowManager.lua & ArrowTooltip.lua

**Purpose**: Visual arrow indicator pointing to the next recipe to craft.

The arrow manager positions the arrow at the recipe's row in the profession window's list (through the client adapter) and handles combat. Two styles: with a tooltip (the current step, the next two, the receipt's amounts and where the prices came from, built by `Views.ArrowTooltip`) and a simple arrow without one.

### ProfessionBrowser.lua

**Purpose**: Popup listing all available professions; a click opens the LazyProf window in planning mode on that profession.

Accessible via minimap button left-click (the addon compartment entry on WoW Forever) or `/lp browse`.

### MinimapButton.lua

**Purpose**: LibDBIcon minimap button for quick access; on WoW Forever the addon compartment entry instead.

Left-click opens profession browser, right-click opens settings.

## CraftLib Integration

LazyProf reads from CraftLib via `_G.CraftLib`:

```lua
-- Every profession with its caps (milestones) and recipes, for the active client
local professions = CraftLib:GetProfessions()

-- Check if item can be crafted (for material resolution)
local producers = CraftLib:GetRecipeByProduct(itemId)

-- The fixed vendor price of a vendor-stocked reagent, where the data has one
local copper = CraftLib:GetVendorBuyPrice(itemId)

-- Which client's data is active ("VANILLA", "TBC", "WOTLK", "SOD", "FOREVER")
local profile = CraftLib:GetActiveProfile()
```
