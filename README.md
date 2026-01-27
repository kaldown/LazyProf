# LazyProf

[![CurseForge](https://img.shields.io/badge/CurseForge-LazyProf-orange)](https://www.curseforge.com/wow/addons/lazyprof)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Calculate the cheapest path to level your professions in World of Warcraft.

**Requires [CraftLib](https://github.com/kaldown/CraftLib)** - Install both addons together.

## Supported Professions

See [CraftLib's profession coverage](https://github.com/kaldown/CraftLib#profession-coverage) for the current list of supported professions.

## Features

- Calculates optimal leveling path based on current AH prices
- Two strategies: Cheapest (minimize gold) or Fastest (minimize crafts)
- Material Resolution: Automatically suggests crafting intermediates (e.g., smelt ore into bars) when cheaper
- **Owned Materials Optimization**: Treats materials you already own as free, prioritizing recipes that use your existing inventory
- **Recipe Availability Filtering**: Only suggests recipes you can actually obtain - checks inventory, trainers, vendors, and Auction House listings
- Shows missing materials with cost breakdown, "From Bank", "From Alts", and "To Craft" sections
- Tracks progress with milestone breakdowns
- Bank and alt character inventory integration (with optional addon)

## Price Sources

- **TradeSkillMaster** - Uses TSM pricing data
- **Auctionator** - Uses Auctionator scan prices
- **Vendor prices** - Works standalone without either

## Optional Dependencies

| Addon | Feature |
|-------|---------|
| [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) | TSM pricing integration |
| [Auctionator](https://www.curseforge.com/wow/addons/auctionator) | Auctionator pricing + shift-click search |
| [Syndicator](https://www.curseforge.com/wow/addons/baganator) | Bank + alt character inventory scanning |

## Usage

1. **Minimap button** - Click to browse all professions
   - Left-click: Open profession browser
   - Right-click: Open settings
2. **Open any profession window** - LazyProf shows optimal path
3. **Shopping List** - Shows materials needed

Commands:
- `/lazyprof` or `/lp` - Open settings
- `/lp browse` - Open profession browser

## Settings

Access via `/lp` or the Interface Options panel:

- **Include bank items** - Count bank contents when calculating missing materials (requires Syndicator)
- **Use owned materials as free** - Treat materials in bags/bank as free when calculating path costs
- **Include alt characters** - Include materials on all your characters (requires Syndicator)
- **Suggest unlearned recipes** - Include recipes you haven't learned yet
- **Calculate from current skill** - Show materials from current skill instead of full bracket

## Supported Game Versions

- Classic Era
- Season of Discovery
- Anniversary
- Hardcore

## License

MIT - See [LICENSE](LICENSE) for details.
