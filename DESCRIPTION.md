[![CurseForge](https://img.shields.io/badge/CurseForge-LazyProf-orange)](https://www.curseforge.com/wow/addons/lazyprof)
[![Wago](https://img.shields.io/badge/Wago-LazyProf-c1272d)](https://addons.wago.io/addons/lazyprof)
[![License: All Rights Reserved](https://img.shields.io/badge/License-All_Rights_Reserved-red.svg)](LICENSE)
[![PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?logo=paypal&logoColor=white)](https://www.paypal.com/donate/?hosted_button_id=FG4KES3HNPLVG)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_A_Coffee-FFDD00?logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/kaldown)

If you find this useful, consider supporting development via [PayPal](https://www.paypal.com/donate/?hosted_button_id=FG4KES3HNPLVG) or [Buy Me a Coffee](https://buymeacoffee.com/kaldown).

Other addons:
- [VendorSniper](https://addons.wago.io/addons/vendorsniper) - Vendor restock sniper
- [Silencer](https://www.curseforge.com/wow/addons/silencer-whispers) - Whisper gatekeeper
- [CraftLib](https://www.curseforge.com/wow/addons/craftlib) - Recipe database

---

Tired of wasting gold leveling professions? LazyProf figures out the cheapest crafting path so you don't have to.

**Requires [CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Install both addons together.

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

## Pricing

**Vendor prices always come first** - reagents sold by NPCs (dyes, threads, vials, flux, etc.) use their fixed vendor price, sourced from TSM or Auctionator's recorded merchant data. This prevents AH markup from inflating recipe costs.

For non-vendor items, market sources are checked in order:
1. **TSM** - Configurable pricing (Recent, MinBuyout, Market, or Regional)
2. **Auctionator** - Auctionator scan prices

**Recommended:** Install [TSM](https://www.curseforge.com/wow/addons/tradeskill-master) + TSM Desktop App for the most accurate pricing.

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

## Required Addon

**[CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Recipe database (MUST INSTALL)

LazyProf requires CraftLib to function. Install both addons together.

## Optional Addons

- **[TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)** - TSM pricing (recommended)
- **[Auctionator](https://www.curseforge.com/wow/addons/auctionator)** - Auctionator pricing + shift-click AH search
- **[Syndicator](https://www.curseforge.com/wow/addons/syndicator)** - Bank, alt, mail, guild bank inventory scanning

## Supported Game Versions

- Classic Era
- Season of Discovery
- Anniversary
- Hardcore
