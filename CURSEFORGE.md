Tired of wasting gold leveling professions? LazyProf figures out the cheapest crafting path so you don't have to.

**Requires [CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Install both addons together.

## Supported Professions

See [CraftLib's profession coverage](https://github.com/kaldown/CraftLib#profession-coverage) for the current list of supported professions.

## Features

- **Optimal leveling path** - Calculates which recipes to craft based on current AH prices
- **Two strategies** - Cheapest (minimize gold) or Fastest (minimize crafts)
- **Material Resolution** - Automatically suggests crafting intermediates (e.g., smelt ore into bars) when cheaper than buying
- **Owned Materials Optimization** - Treats materials you already own as free, prioritizing recipes that use your existing inventory
- **Recipe Availability Filtering** - Only suggests recipes you can actually obtain - checks inventory, trainers, vendors, and Auction House listings
- **Missing materials list** - Shows what you need from bank, from alts, what to craft, and total cost
- **Milestone tracking** - See your progress through each skill bracket
- **Alternative recipes & pinning** - Browse all candidates at each step, pin overrides, and recalculate custom paths
- **Bank + alt inventory integration** - Counts items on all characters when calculating what you need (requires Syndicator)

## Price Sources (Priority Order)

1. **TSM Regional** - Uses DBRegionMarketAvg for manipulation-resistant pricing
2. **TSM Realm** - Falls back to DBMarket if regional unavailable
3. **TSM Local** - Falls back to DBMinBuyout from last AH scan
4. **Auctionator** - Uses Auctionator scan prices if TSM unavailable
5. **Vendor prices** - Works standalone without any AH addon

**Recommended:** Install [TSM](https://www.curseforge.com/wow/addons/tradeskill-master) + TSM Desktop App for the most accurate, manipulation-resistant prices.

## Usage

1. **Minimap button** - Click to browse all professions
   - Left-click: Open profession browser
   - Right-click: Open settings
2. **Open any profession window** - LazyProf shows optimal path
3. **Shopping List** - Shows materials needed

Commands:
- `/lazyprof` or `/lp` - Open settings
- `/lp browse` - Open profession browser

## Required Addon

**[CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Recipe database (MUST INSTALL)

LazyProf requires CraftLib to function. Install both addons together.

## Optional Addons

- **[TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)** - TSM pricing (recommended)
- **[Auctionator](https://www.curseforge.com/wow/addons/auctionator)** - Auctionator pricing + shift-click AH search
- **[Syndicator](https://www.curseforge.com/wow/addons/syndicator)** - Bank + alt character inventory scanning

## Supported Game Versions

- Classic Era
- Season of Discovery
- Anniversary
- Hardcore
