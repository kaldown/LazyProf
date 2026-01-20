# LazyProf

Calculate the cheapest path to level your professions in World of Warcraft.

## Features

- Calculates optimal leveling path based on current AH prices
- Two strategies: Cheapest (minimize gold) or Fastest (minimize crafts)
- Shows missing materials with cost breakdown
- Tracks progress with milestone breakdowns
- Bank inventory integration (with optional addon)

## Price Sources

- **TradeSkillMaster** - Uses TSM pricing data
- **Auctionator** - Uses Auctionator scan prices
- **Vendor prices** - Works standalone without either

## Optional Dependencies

| Addon | Feature |
|-------|---------|
| [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) | TSM pricing integration |
| [Auctionator](https://www.curseforge.com/wow/addons/auctionator) | Auctionator pricing + shift-click search |
| [Baganator](https://www.curseforge.com/wow/addons/baganator) | Bank inventory scanning |

## Usage

1. Open any profession window
2. LazyProf shows the optimal path in the Milestone Breakdown panel
3. Shopping List shows materials needed

Commands: `/lazyprof` or `/lp`

## Settings

Access via `/lp` or the Interface Options panel:

- **Include bank items** - Count bank contents when calculating missing materials (requires Baganator)
- **Suggest unlearned recipes** - Include recipes you haven't learned yet
- **Calculate from current skill** - Show materials from current skill instead of full bracket
