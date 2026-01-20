# CurseForge Description

Copy this when uploading new versions.

---

## Short Description

```
Calculate the cheapest path to level your professions. Uses TSM regional prices for manipulation-resistant pricing.
```

---

## Main Description

```markdown
Tired of wasting gold leveling professions? LazyProf figures out the cheapest crafting path so you don't have to.

> **Requires [CraftDB](https://www.curseforge.com/wow/addons/craftdb)** - Install both addons together.

## Features

- **Optimal leveling path** - Calculates which recipes to craft based on current AH prices
- **Two strategies** - Cheapest (minimize gold) or Fastest (minimize crafts)
- **Missing materials list** - Shows what you need to buy and total cost
- **Milestone tracking** - See your progress through each skill bracket
- **Bank integration** - Counts bank items when calculating what you need (requires Syndicator)

## Price Sources (Priority Order)

1. **TSM Regional** - Uses `DBRegionMarketAvg` for manipulation-resistant pricing
2. **TSM Realm** - Falls back to `DBMarket` if regional unavailable
3. **TSM Local** - Falls back to `DBMinBuyout` from last AH scan
4. **Auctionator** - Uses Auctionator scan prices if TSM unavailable
5. **Vendor prices** - Works standalone without any AH addon

**Recommended:** Install [TSM](https://www.curseforge.com/wow/addons/tradeskill-master) + TSM Desktop App for the most accurate, manipulation-resistant prices.

## Usage

1. Open any profession window
2. LazyProf panels appear showing optimal path and shopping list
3. Type `/lazyprof` or `/lp` for settings

## Required Dependencies

| Addon | Purpose |
|-------|---------|
| [CraftDB](https://www.curseforge.com/wow/addons/craftdb) | Recipe database - **MUST INSTALL** |

**Important:** LazyProf requires CraftDB to function. Install both addons together.

## Optional Dependencies

| Addon | Feature |
|-------|---------|
| [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) | TSM pricing (recommended) |
| [Auctionator](https://www.curseforge.com/wow/addons/auctionator) | Auctionator pricing + shift-click AH search |
| [Syndicator](https://www.curseforge.com/wow/addons/syndicator) | Bank inventory scanning |

## Supported Game Versions

- Retail (The War Within)
- Classic Era
- Classic Cataclysm
- Season of Discovery
- Hardcore
```

---

## Changelog Template

```markdown
## v0.X.X

**Changes:**
- Item 1
- Item 2

**Fixes:**
- Fix 1
```

---

## Upload Checklist

1. Update version in `LazyProf.toc`
2. Update changelog above
3. Package: exclude `.git/`, `docs/`, `.idea/`
4. Upload to CurseForge
5. Tag release: `git tag v0.X.X && git push --tags`
