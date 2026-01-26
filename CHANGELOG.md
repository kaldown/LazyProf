# Changelog

All notable changes to LazyProf will be documented in this file.

## [Unreleased]

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
