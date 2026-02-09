# Changelog

All notable changes to LazyProf will be documented in this file.

## [Unreleased]

### Changed
- **Alternatives now show all recipes regardless of availability**: Drop, reputation, and quest recipes that were previously hidden when not on the Auction House now appear in the alternatives list
  - Unavailable recipes are visually dimmed and sorted to the bottom
  - Tooltip shows source info (e.g., "Cenarion Expedition (Honored)") with "Not currently obtainable" note
  - Users can pin unavailable recipes they plan to obtain
  - Auto-selected path is unchanged - only available recipes are auto-picked
- **Alternative row click now opens Recipe Details**: Click a row to see full recipe info before deciding; use the `[>]` pin indicator to toggle pins
- Removed unused `includeDropRecipes` config setting

## [0.4.0] - 2026-02-08

### Added
- **Alternative recipes with pinning** ([#5](https://github.com/kaldown/LazyProf/issues/5)): Expand any step in the milestone breakdown to browse all scored recipe candidates at that skill level
  - Each alternative shows difficulty color, skillup chance, cost per craft, and unlearned status
  - Hover tooltip shows full material list and source info for unlearned recipes
  - Alternatives grouped into collapsible packs of 5 under a dedicated "Alternatives" section, keeping the UI clean
  - Click any alternative to pin it as an override for that skill level
  - Pinned steps show a blue `[*]` indicator in the skill range
  - "Recalculate with N pins" button appears when pins differ from the optimizer's choices
  - Recalculate reruns the pathfinder respecting all pinned overrides, updating the full path, shopping list, and arrow
  - Pins are session-only (reset on /reload) - designed for exploring "what if" scenarios
  - Score and delta details shown in tooltip only when debug mode is enabled

## [0.3.10] - 2026-01-30

### Fixed
- **Recipe acquisition costs now properly amortized**: One-time costs (vendor recipes, AH recipe items) are spread over expected crafts instead of being added to every scoring evaluation. This fixes recipes usable for many crafts being unfairly penalized (e.g., Filet of Redgill score: 16000 -> ~220).
- **CraftLib v0.2.12**: Fixed incorrect difficulty data causing wrong recipe suggestions
  - Steam Tonk Controller showed as orange when actually green at skill 280
  - Thorium Shells showed as red when actually yellow at skill 295+
  - Large Prismatic Shard and other Enchanting conversion recipes no longer appear at low skill levels

## [0.3.9] - 2026-01-29

### Added
- **Racial profession bonus support**: Pathfinder now accounts for racial skill bonuses that extend recipe color ranges
  - Gnome: +15 Engineering (recipes stay orange/yellow/green 15 skill points longer)
  - Blood Elf: +10 Enchanting
  - Draenei: +5 Jewelcrafting
  - UI shows racial bonus in planning window status bar (e.g., "Current skill: 198 (+15 Gnome)")
  - Recipe colors in milestone breakdown now correctly reflect racial bonus

## [0.3.8] - 2026-01-28

### Fixed
- **Jewelcrafting and Mining paths now work**: Fixed empty leveling paths for professions where first recipe requires skill > 1
- Pathfinder now skips to next available recipe when no candidates exist at current skill level
- **Arrow not showing in Anniversary Edition**: Arrow assumed 8 visible recipe slots (Classic), but Anniversary/TBC shows 20+. Now dynamically detects visible slots

### Changed
- Debug log command shortened from `/lp debuglog` to `/lp log`
- Arrow scroll handling debounced for better performance

### Added
- Recipe availability filtering: Unlearned recipes are now filtered from leveling paths unless they can actually be obtained
  - Checks player inventory (bags, bank, alts) for recipe items
  - Verifies trainer recipes meet faction requirements
  - Vendor recipes always available (player can travel)
  - Drop/quest/reputation recipes checked against Auction House listings (TSM/Auctionator)
- Recipe acquisition cost included in path calculations: Trainer, vendor, and AH costs are now factored into recipe scoring (recipes you already own are free)
- Enhanced tooltip shows acquisition details for unlearned recipes:
  - Location if in inventory ("In your bags", "In your bank", "On alt: Name")
  - Trainer name and cost
  - Vendor name, location, and cost
  - Auction House price with source (TSM/Auctionator)
  - Wowhead link to recipe item

## [0.3.7] - 2026-01-27

### Fixed
- **FPS hitches during batch crafting** (GitHub Issue #3): Separated expensive path recalculation from lightweight shopping list updates. Now only recalculates the full path when skill level changes, while bag changes trigger a cheap inventory refresh only.

## [0.3.6] - 2026-01-27

### Fixed
- **"Calculate from current skill" checkbox now works**: Setting was defined but never used by the pathfinder
- **Planning window empty content**: Embedded MilestonePanel was rendered behind the window due to frame strata conflict
- **Planning window not refreshing on settings change**: Now updates when toggling "Calculate from current skill"

### Changed
- MilestonePanel refactored to reusable class pattern (`MilestonePanelClass`)
- PlanningWindow uses embedded MilestonePanel instance (removed ~280 lines of duplicate code)
- Improved UI debug logging with scroll frame and row positioning diagnostics

## [0.3.5] - 2026-01-27

### Added
- **Owned Materials Optimization**: New pathfinding mode that treats materials you own as free
  - Enable "Use owned materials as free" in Display settings to minimize actual gold spent
  - Optionally include alt characters' bags and banks (requires Syndicator/Baganator)
  - Shopping list now shows "From Alts" section with character names
- **Copy All button in debug window**: Click to select all text, then Ctrl+C to copy

### Changed
- Welcome message no longer shows redundant addon name (Ace3 Print already adds prefix)

## [0.3.2] - 2026-01-26

### Fixed

- **Pathfinder now re-evaluates at breakpoints**: Previously, the pathfinder would commit to a recipe until it went gray, potentially skipping cheaper recipes that became available at intermediate skill levels. Now it stops and re-evaluates when:
  - A new recipe becomes learnable (skillRequired boundary)
  - The current recipe changes color (orange→yellow, yellow→green)

## [0.3.1] - 2026-01-26

### Fixed

- Updated CraftLib to v0.2.7: removes 46 invalid/placeholder recipes (e.g., Crystal Infused Bandage)

## [0.3.0] - 2026-01-25

### Added
- **TSM Price Source Selection**: Choose which TSM price to use for calculations
  - Min Buyout (current AH prices - what you can buy NOW)
  - Market Value (realm average)
  - Region Average (cross-realm, stable but may differ from local)
- Settings recommendation when TSM is not installed, showing which fallback is active
- Debug window auto-updates in real-time when open (no more chat spam during debugging)
- Detailed pathfinder debug logging showing candidate scores, colors, and costs

### Changed
- Default TSM price source changed from Region Average to Min Buyout for more accurate local pricing
- TSM provider now properly returns nil for items with no price data (0 = no data, not free)
- Debug messages only print to chat when debug window is closed

### Fixed
- Items with no AH data no longer appear as "free" (0 cost) in path calculations
- Removed non-functional "Scan AH Now" button and "Auto-scan AH" toggle

### Technical
- TSM price source configurable via `/lp` → Pricing settings
- Price fallback chain: selected source → other TSM sources → Auctionator → Vendor

## [0.2.10] - 2026-01-25

### Added
- Debug log popup: `/lp debuglog` opens copyable log window (Ctrl+A, Ctrl+C)

### Fixed
- PlanningWindow now standalone (no longer hijacks MilestoneBreakdown)
- Skill detection uses Classic-compatible API (GetSkillLineInfo)
- Planner correctly shows current skill level for learned professions

## [0.2.8] - 2026-01-25

### Added
- Profession Browser: Browse and plan any profession's leveling path
- Minimap button for quick access to profession browser
- Planning mode: See full leveling path and costs for any profession

### Fixed
- Planning mode now correctly calculates paths (skill level starts at 1, not 0)
- Professions now load reliably from CraftLib on startup
- Resize PlanningWindow properly refreshes content layout

## [0.2.7] - 2026-01-25

### Changed
- Milestone Breakdown now shows step-by-step format like wow-professions.com guides
  - Each recipe displays as its own row: "184-197: 30x Bronze Tube - materials"
  - Click to expand and see detailed material list with have/need counts
  - Trainer milestone separators (75, 150, 225, 300) appear between relevant steps
  - Hover tooltip shows full material breakdown

## [0.2.6] - 2026-01-24

### Fixed
- CraftLib v0.2.4: All 10 professions now have Wowhead-verified difficulty values (97.7% coverage)

## [0.2.5] - 2026-01-24

### Fixed
- Removed invalid interface version (38000) from TOC

## [0.2.4] - 2026-01-24

### Added
- Automated releases via GitHub Actions (CurseForge, Wago.io, GitHub Releases)

### Changed
- Milestone breakdown now shows missing count (e.g., "178x Silk Cloth") instead of confusing have/need format (e.g., "22/200")

## [0.2.3] - 2026-01-24

### Fixed
- CraftLib v0.2.2: Corrected skillRequired values for First Aid and Cooking (e.g., Runecloth Bandage now correctly requires 260 to learn, not 200)

## [0.2.2] - 2026-01-23

### Added
- Friendly error dialog when CraftLib dependency is missing
- Graceful addon disable instead of silent failure

## [0.2.1] - 2026-01-23

### Added
- Material Resolution system for intermediate crafting (smelt ore into bars, etc.)
- "To Craft" section in Shopping List showing intermediate materials to craft
- Config option: Material Resolution (None / Cost-compare / Always craft)
- Material flow annotations showing where resources come from (bank vs AH)
- CraftLib `GetRecipeByProduct` integration for reverse recipe lookups

### Changed
- Updated CraftLib to v0.2.0 with verified recipe sources for Cooking and First Aid

## [0.2.0] - 2025-01-21

First public release with CraftLib integration.

### Added
- External CraftLib addon integration for recipe data (required dependency)
- TSM Regional prices (DBRegionMarketAvg) for manipulation-resistant pricing
- Fastest strategy - minimize number of crafts instead of gold
- Recipe Details panel - shows materials, skill-ups, and costs for selected recipes
- "Calculate from current skill" option in settings
- Bank integration via Syndicator for inventory scanning

### Fixed
- Arrow indicator now visible with scroll support and skill-based colors
- Panels hide when profession has no registered data
- AceGUI widgets load correctly for config panel

## [0.1.0] - 2025-01-20

Initial implementation (internal).

### Added
- Core pathfinding algorithm for optimal profession leveling
- Cheapest strategy - minimize gold spent
- Milestone breakdown panel showing progress through skill brackets
- Missing materials panel with shopping list and total cost
- Arrow indicators pointing to optimal recipes
- TSM pricing support (Regional, Realm, Local)
- Auctionator pricing support
- Vendor price fallback
- Configuration via `/lazyprof` or `/lp` commands
- Support for Retail, Classic Era, Cataclysm, SoD, and Hardcore
