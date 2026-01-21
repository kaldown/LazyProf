# Changelog

All notable changes to LazyProf will be documented in this file.

## [Unreleased]

### Added
- Material Resolution system for intermediate crafting (smelt ore into bars, etc.)
- "To Craft" section in Shopping List showing intermediate materials to craft
- Config option: Material Resolution (None / Cost-compare / Always craft)
- Material flow annotations showing where resources come from (bank vs AH)
- CraftLib `GetRecipeByProduct` integration for reverse recipe lookups

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
