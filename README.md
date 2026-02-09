# LazyProf

[![CurseForge](https://img.shields.io/badge/CurseForge-LazyProf-orange)](https://www.curseforge.com/wow/addons/lazyprof)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Calculate the cheapest path to level your professions in World of Warcraft.

**Requires [CraftLib](https://github.com/kaldown/CraftLib)** - Install both addons together.

## Supported Professions

See [CraftLib's profession coverage](https://github.com/kaldown/CraftLib#profession-coverage) for the current list of supported professions.

## Features

- **Optimal leveling path** - Calculates which recipes to craft based on current AH prices
- **Two strategies** - Cheapest (minimize gold) or Fastest (minimize crafts)
- **Material Resolution** - Automatically suggests crafting intermediates (e.g., smelt ore into bars) when cheaper than buying
- **Recipe Availability Filtering** - Only suggests recipes you can actually obtain - checks inventory, trainers, vendors, and Auction House listings
- **Missing materials list** - Shows what you need from bank, mail, guild bank, alts, what to craft, and total cost
- **Milestone tracking** - See your progress through each skill bracket with bracket filtering
- **Alternative recipes & pinning** - Browse all candidates at each step, pin overrides, and recalculate custom paths
- **Recipe details panel** - View ingredients, difficulty thresholds, vendor locations, and Wowhead links
- **Planning mode** - Plan any profession's leveling path without learning it first
- **Extended inventory** - Checks bags, bank, mailbox, active AH listings, guild bank, and alt characters (with Syndicator)

## Price Sources (Priority Order)

1. **TSM** - Uses configurable TSM pricing (MinBuyout, Market, or Regional)
2. **Auctionator** - Falls back to Auctionator scan prices
3. **Vendor prices** - Works standalone without any AH addon

**Recommended:** Install [TSM](https://www.curseforge.com/wow/addons/tradeskill-master) + TSM Desktop App for the most accurate pricing.

## Optional Dependencies

| Addon | Feature |
|-------|---------|
| [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) | TSM pricing integration |
| [Auctionator](https://www.curseforge.com/wow/addons/auctionator) | Auctionator pricing + shift-click search |
| [Syndicator](https://www.curseforge.com/wow/addons/syndicator) | Bank, alt, mail, guild bank inventory scanning |

## Usage

1. **Minimap button** - Click to browse all professions
   - Left-click: Open profession browser
   - Right-click: Open settings
2. **Open any profession window** - LazyProf shows optimal path
3. **Shopping List** - Shows materials needed with source breakdown

Commands:
- `/lazyprof` or `/lp` - Open settings
- `/lp browse` - Open profession browser
- `/lp log` - Open debug log window

## Settings

Access via `/lp` or the Interface Options panel:

- **Strategy** - Cheapest (minimize gold) or Fastest (minimize crafts)
- **Suggest unlearned recipes** - Include recipes you haven't learned yet
- **Calculate from current skill** - Show materials from current skill instead of full bracket
- **Include bank items** - Count bank contents in shopping list (requires Syndicator)
- **Include alt characters** - Include materials on all your characters (requires Syndicator)
- **Include guild bank** - Include guild bank materials in shopping list (requires Syndicator)

## Supported Game Versions

- Classic Era
- Season of Discovery
- Anniversary
- Hardcore

## License

MIT - See [LICENSE](LICENSE) for details.
