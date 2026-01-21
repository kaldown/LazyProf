Tired of wasting gold leveling professions? LazyProf figures out the cheapest crafting path so you don't have to.

**Requires [CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Install both addons together.

## Features

- **Optimal leveling path** - Calculates which recipes to craft based on current AH prices
- **Two strategies** - Cheapest (minimize gold) or Fastest (minimize crafts)
- **Missing materials list** - Shows what you need to buy and total cost
- **Milestone tracking** - See your progress through each skill bracket
- **Bank integration** - Counts bank items when calculating what you need (requires Syndicator)

## Price Sources (Priority Order)

1. **TSM Regional** - Uses DBRegionMarketAvg for manipulation-resistant pricing
2. **TSM Realm** - Falls back to DBMarket if regional unavailable
3. **TSM Local** - Falls back to DBMinBuyout from last AH scan
4. **Auctionator** - Uses Auctionator scan prices if TSM unavailable
5. **Vendor prices** - Works standalone without any AH addon

**Recommended:** Install [TSM](https://www.curseforge.com/wow/addons/tradeskill-master) + TSM Desktop App for the most accurate, manipulation-resistant prices.

## Usage

1. Open any profession window
2. LazyProf panels appear showing optimal path and shopping list
3. Type `/lazyprof` or `/lp` for settings

## Required Addon

**[CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Recipe database (MUST INSTALL)

LazyProf requires CraftLib to function. Install both addons together.

## Optional Addons

- **[TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)** - TSM pricing (recommended)
- **[Auctionator](https://www.curseforge.com/wow/addons/auctionator)** - Auctionator pricing + shift-click AH search
- **[Syndicator](https://www.curseforge.com/wow/addons/syndicator)** - Bank inventory scanning

## Supported Game Versions

- Retail (The War Within)
- Classic Era
- Classic Cataclysm
- Season of Discovery
- Hardcore
