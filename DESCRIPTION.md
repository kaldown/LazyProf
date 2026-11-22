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
- [PickMe](https://www.curseforge.com/wow/addons/pickme) - LFG listing browser
- [EyesOnMe](https://www.curseforge.com/wow/addons/eyesonme) - PvP targeting awareness

---

Tired of wasting gold leveling professions? LazyProf figures out the cheapest crafting path so you don't have to.

**Requires [CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Install both addons together.

## Supported Professions

See [CraftLib's profession coverage](https://github.com/kaldown/CraftLib#profession-coverage) for the current list of supported professions.

## Features

- **Optimal leveling path** - Calculates which recipes to craft based on current AH prices
- **One window: Guide, Steps, Shopping** - A tabbed window beside the profession window. Guide shows the one step to do now, large, with its reagents and the alternatives; Steps lists the whole path; Shopping says what to collect and what to buy
- **Path bar** - The whole journey as one coloured strip: orange, yellow and green stretches, gaps in red, a tick at each rank still to train and a marker at your skill. Hover a stretch to see the step, click to open it
- **Steps a person follows** - Runs of one recipe are shown as one step ("41x Heavy Woolen Gloves, 143 to 165"), with learning a recipe and training the next rank as steps of their own
- **Target skill and margin** - Plan to any skill, not just the cap; tick "With margin" to plan extra crafts and reagents for bad luck (5 to 30 percent, 15 by default)
- **Two strategies** - Cheapest (minimize gold) or Fastest (minimize crafts), switched with one click
- **Alternative recipes & pinning** - Each step shows its best alternatives with how many crafts and how much gold they would change; "Use this" swaps the recipe and replans at once, "Reset" undoes it. Pins are kept between sessions
- **Need / Have / Buy** - The shopping list is one table per reagent, with what is in your bags, bank, mail, auctions, guild bank and on alts taken off (with Syndicator), and a "vendor" mark on vendor-sold reagents
- **Craft or buy per reagent** - For reagents you can make yourself, choose "I craft it" or "I buy it" per item; otherwise LazyProf crafts intermediates (e.g., smelt ore into bars) when that is cheaper
- **Buy vendor reagents in one click** - At a merchant that sells reagents on your list, a small panel offers a Buy button per reagent and "Buy all" with the total on the button. Limited-stock items and items not sold for gold are listed but never bought automatically
- **Skill gaps** - Paths bridge a gap with a green recipe while its skill-up chance is at least 10%, otherwise the gap is shown
- **Recipe Availability Filtering** - Only suggests recipes you can actually obtain - checks inventory, trainers, vendors, and Auction House listings
- **Recipe details panel** - View ingredients, difficulty thresholds, sources, and Wowhead links
- **Planning mode** - The same window, opened from the minimap button or `/lp browse`, plans any profession without opening it - or without having learned it
- **Every Classic expansion** - One install plans correctly on Classic Era / Vanilla, Season of Discovery, The Burning Crusade, and Wrath of the Lich King (including Inscription, skill cap 450)
- **WoW Forever** - Runs on WoW Forever 1.60 from the same install, with native frames, tabs and dropdowns and an addon compartment entry instead of a minimap button. On Forever LazyProf also remembers the profession trainers you visit and the fees they charge, and shows them on learn and rank steps. Forever recipe data covers Alchemy, Blacksmithing, Enchanting, Leatherworking, Tailoring, Cooking and First Aid (Engineering and Mining to follow). Known limits: racial bonuses are not applied, required tools are not used for paths yet, and the skill cap is assumed to be 300 until confirmed

## Pricing

**Vendor prices always come first** - reagents sold by NPCs (dyes, threads, vials, flux, etc.) use their fixed vendor price: from TSM or Auctionator's recorded merchant data, from merchants you have visited with LazyProf installed (it remembers what they sell for gold without a stock limit), or from the built-in vendor list. This prevents AH markup from inflating recipe costs.

For non-vendor items, market sources are checked in order:
1. **TSM** - Configurable pricing (Recent, MinBuyout, Market, or Regional)
2. **Auctionator** - Auctionator scan prices

**Recommended:** Install [TSM](https://www.curseforge.com/wow/addons/tradeskill-master) + TSM Desktop App for the most accurate pricing.

## Usage

1. **Open any profession window** - The LazyProf window opens beside it on the Guide tab, and an arrow marks the next recipe in the profession's list
2. **Follow the card** - Craft what it says; the card moves on by itself as your skill goes up. Steps and Shopping are the other two tabs
3. **Minimap button** (addon compartment on WoW Forever) - Plan any profession without opening it
   - Left-click: Open profession browser
   - Right-click: Open settings
4. **At a vendor** - If the vendor sells reagents on your list, the LazyProf panel next to the merchant window buys them

The merchant panel uses the shopping list of the path you last looked at in this play session, so open the profession (or the LazyProf window) once before shopping.

Commands:
- `/lazyprof` or `/lp` - Open settings
- `/lp browse` - Open profession browser
- `/lp resetpanels` - Move the window and panels back to their default place and size
- `/lp log` - Open debug log window
- `/lp diag` - List the diagnostic dumps (prices, merchant, trainer, client)

## Required Addon

**[CraftLib](https://www.curseforge.com/wow/addons/craftlib)** - Recipe database (MUST INSTALL)

LazyProf requires CraftLib to function. Install both addons together.

## Optional Addons

- **[TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)** - TSM pricing (recommended)
- **[Auctionator](https://www.curseforge.com/wow/addons/auctionator)** - Auctionator pricing + shift-click AH search
- **[Syndicator](https://www.curseforge.com/wow/addons/syndicator)** - Bank, alt, mail, guild bank inventory scanning

## Supported Game Versions

One install works on every live Classic-family client - it detects which one you are on and plans with the correct recipes and skill cap:

- Classic Era / Anniversary (Vanilla) - cap 300
- Season of Discovery - cap 300
- The Burning Crusade Classic - cap 375
- Wrath of the Lich King Classic - cap 450, includes Inscription (also loads on the Titan 3.80 seasonal client)
- Hardcore (Classic Era)
- WoW Forever 1.60 - cap 300 (assumed until confirmed); 7 professions so far, see CraftLib for the list
