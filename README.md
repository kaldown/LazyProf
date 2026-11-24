# LazyProf

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

Calculate the cheapest path to level your professions in World of Warcraft.

**Requires [CraftLib](https://github.com/kaldown/CraftLib)** - Install both addons together.

## Supported Professions

See [CraftLib's profession coverage](https://github.com/kaldown/CraftLib#profession-coverage) for the current list of supported professions.

## Features

- **Plan, then shop** - Open a profession and see the cheapest path from your real skill, counting what you already own, current prices and what the crafted items sell for. Choose how far to level and get one total of what to buy
- **One window: Path and Shopping** - A window beside the profession window with two tabs under a shared header. The header answers how far ("Level to") and what it costs (the receipt); Path lists the recipes to craft; Shopping says what to collect and what to buy
- **Level to** - A number box and a slider from your skill to the last cap. Drag the slider, or type a skill and press Enter: the path, the costs and the shopping list end there. To shop for the next bracket only, set it to that bracket's end
- **The receipt** - "You spend" (reagents still to buy plus recipes to buy or learn), "Back from selling" (what the crafts sell for) and "Net cost". Amounts are exact to the copper, and "You spend" is the Shopping tab added up. Further lines say what your own stock saves and what making reagents yourself saves or costs
- **Sale value** - What the crafted items sell for is counted: sold to a vendor by default, at auction after the 5% cut, or not at all. Under Cheapest, two recipes that need the same reagents are no longer equal when one sells for more
- **Your stock shapes the path** - Under Cheapest, reagents you own are counted when the path is chosen, against whole runs of a recipe. The planner compares up to four routes and keeps the one you pay least for, so the path never costs you more than the market-price path would, by the addon's own count
- **The plan you shopped for stays** - Under Cheapest the route is remembered per character and profession, so after buying the list the path does not wander to other recipes. It gives way when it would cost more than the market-price path or another route is clearly cheaper; choosing a recipe yourself plans that range again
- **Path tab** - One row per recipe with its skill range, crafts and cost. What has to be learned first is a line under its recipe, training the next rank is a row of its own, and the closest alternative is offered right under a row with a Use button. Click a row to open it: its reagents, what a craft sells for, how to learn the recipe and the other recipes for that skill range
- **Alternative recipes** - "Use" swaps the recipe over that skill range and plans again at once; "Reset" gives the choice back to the planner. Your choices are kept between sessions
- **Two strategies** - Cheapest (minimize gold) or Fastest (minimize crafts)
- **Spare crafts** - Plan extra crafts and reagents for bad luck with skill-ups (5 to 30 percent, 15 by default)
- **More options** - One switch in the window shows the rest: Cheapest / Fastest, "Spare crafts", the selling mode, where the prices come from, the recipe search, "Hide what I have" and the craft-or-buy buttons
- **Need / Have / Buy** - The shopping list is one table per reagent: what is still to buy first, the dearest on top, then what you make yourself, then what you already own. What is in your bags is taken off, and so is what is in your bank and on your other characters: read from Syndicator when it is installed (then also mail, your auctions and, if you turn it on, the guild bank), otherwise remembered by LazyProf itself, which then says how old that memory is and, when the bank may have changed since it was last read, leaves it out and says so rather than count a stack twice. Vendor-sold reagents carry a "vendor" mark, and the recipes still to buy or learn are listed with their price
- **Craft or buy per reagent** - LazyProf crafts intermediates (e.g., smelt ore into bars) when that is cheaper; under More options you can choose "I craft it" or "I buy it" per item instead
- **Buy vendor reagents in one click** - At a merchant that sells reagents on your list, a small panel offers a Buy button per reagent and "Buy all" with the total on the button. Limited-stock items and items not sold for gold are listed but never bought automatically
- **Skill gaps** - Paths bridge a gap with a green recipe while its skill-up chance is at least 10%, otherwise the gap is shown
- **Recipe Availability Filtering** - Only suggests recipes you can actually obtain - checks inventory, trainers, vendors, and Auction House listings
- **Recipe details panel** - View ingredients, difficulty thresholds, sources, and Wowhead links
- **Planning mode** - The same window, opened from the minimap button or `/lp browse`, plans any profession without opening it - or without having learned it
- **Every Classic expansion** - One install plans correctly on Classic Era / Vanilla, Season of Discovery, The Burning Crusade, and Wrath of the Lich King (including Inscription, skill cap 450) - it detects your client and uses the right recipes, caps, racial bonuses, and Wowhead links automatically
- **WoW Forever** - Runs on WoW Forever 1.60 from the same install, with native frames, tabs and dropdowns and an addon compartment entry instead of a minimap button. On Forever LazyProf also remembers the profession trainers you visit and the fees they charge, and names them where a recipe is still to learn or the next rank is to train. Forever recipe data covers all nine professions: Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, Tailoring, Cooking, First Aid and Mining (smelting). No race has a profession bonus on Forever, so none is applied there. Known limits: required tools are not used for paths yet, and the skill cap is assumed to be 300 until confirmed

## Pricing

**Vendor prices always come first** - reagents sold by NPCs (dyes, threads, vials, flux, etc.) use their fixed vendor price: from TSM or Auctionator's recorded merchant data, from merchants you have visited with LazyProf installed (it remembers what they sell for gold without a stock limit), or from the built-in vendor list. This prevents AH markup from inflating recipe costs.

For non-vendor items, market sources are checked in order:
1. **TSM** - Configurable pricing (Recent, MinBuyout, Market, or Regional)
2. **Auctionator** - Auctionator scan prices

An Auctionator price from a scan you made this session (since login or /reload) is used before TSM, because it is newer than the TSM data loaded at login. A reagent no source can price is estimated from its vendor sell value.

**What crafts sell for** - Sold to a vendor, a crafted item counts at the vendor's price the game reports for it. Sold at auction, it counts at its TSM or Auctionator price after the 5% cut, never less than the vendor's price. One item per craft is assumed.

**Recommended:** Install [TSM](https://www.curseforge.com/wow/addons/tradeskill-master) + TSM Desktop App for the most accurate pricing.

## Optional Dependencies

| Addon | Feature |
|-------|---------|
| [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) | TSM pricing integration |
| [Auctionator](https://www.curseforge.com/wow/addons/auctionator) | Auctionator pricing + shift-click search |
| [Syndicator](https://www.curseforge.com/wow/addons/syndicator) | Stock outside your bags read from it: bank, mail, your auctions, alts, guild bank. Without it LazyProf remembers bags and bank itself (see "Your stock" below) |

## Usage

1. **Open any profession window** - The LazyProf window opens beside it, and an arrow marks the next recipe in the profession's list
2. **Choose how far to level** - Drag the "Level to" slider, or type a skill and press Enter. The receipt under it says what that costs
3. **Shop** - The Shopping tab lists what to collect first (from your bank and your alts; with Syndicator also mail and your auctions) and what to buy
4. **Come back and craft** - The Path tab marks the recipe you are on and moves on by itself as your skill goes up
5. **Minimap button** (addon compartment on WoW Forever) - Plan any profession without opening it
   - Left-click: Open profession browser
   - Right-click: Open settings
6. **At a vendor** - If the vendor sells reagents on your list, the LazyProf panel next to the merchant window buys them

The merchant panel uses the shopping list of the path you last looked at in this play session, so open the profession (or the LazyProf window) once before shopping.

Commands:
- `/lazyprof` or `/lp` - Open settings
- `/lp browse` - Open profession browser
- `/lp resetpanels` - Move the window and panels back to their default place and size
- `/lp log` - Open debug log window
- `/lp diag` - List the diagnostic dumps (prices, merchant, trainer, stock, client)

## Settings

Access via `/lp` or the Interface Options panel:

- **Strategy** - Cheapest (minimize gold) or Fastest (minimize crafts); also in the window, under More options
- **Count what crafts sell for** - Sold to a vendor (default), sold at auction after the 5% cut, or do not count; also "Selling" in the window, under More options
- **Spare crafts (percent)** - How many extra crafts "Spare crafts" plans per step (5-30, default 15)
- **Material Resolution** - What reagents without a choice of their own do: never craft intermediates, craft when cheaper, or always craft
- **Suggest unlearned recipes** - Include recipes you haven't learned yet
- **Open with the profession window** - Show the LazyProf window whenever you open a profession (on by default)
- **Include bank items** - Count what is in your bank as owned, for the path and the shopping list (on by default)
- **Include alt characters** - Count materials on your other characters as owned (on by default)
- **Include guild bank** - Count guild bank materials as owned (off by default; requires Syndicator)
- **Forget remembered characters** - Forget the bags and banks LazyProf remembers for your characters (shown when Syndicator is not installed). "Reset All Settings" and `/lp reset` keep them
- **Include recipes bought with currency** - Suggest recipes sold for a currency (such as Merchant's Favor) even before you learn them (off by default)
- **Reset panel positions** - Move the window and panels back to their default place and size (also `/lp resetpanels`)

### Your stock

With [Syndicator](https://www.curseforge.com/wow/addons/syndicator) installed, stock outside your bags is read from it: bank, mail, your auctions, alts and the guild bank.

Without it LazyProf remembers what it has seen itself: each character's bags when you play it and, on WoW Forever, its bank as it was when you last had the bank window open (with the account-wide bank, where the game has one). Your own bank counts as bank stock; the other characters of the same world and faction count as alts, without their soulbound items. So play each alt once, and open the bank once on every character whose bank should count. Under "Collect first" on the Shopping tab the tooltip of a row says how old the remembered stock is ("Bank as seen 2 days ago"). LazyProf stops counting a remembered bank as soon as it has reason to think the bank changed without being read - a last move that the game reported only after the window had closed, or a logout before the game had answered it - and says so on the Shopping tab ("Your bank is not counted: it may have changed after LazyProf last read it. Open the bank to count it again."; an alt's bank that is left out is named the same way). Opening the bank on that character counts it again. A character not played for 180 days is forgotten. Mail, auctions and the guild bank are only known with Syndicator, and on the other clients so is the bank ("Include bank items" is greyed out there without it).

A character in Self-Found mode cannot be sent anything and cannot send anything: no stock of other characters or of the guild bank is counted for it, and (without Syndicator) its own stock is not counted for them. A character the game itself marks Self-Found is treated the same for stock, also with the setting off.

The target skill, the recipes you chose, the route you follow, craft-or-buy choices and the last tab you used are remembered per character.

## Supported Game Versions

One install works on every live Classic-family client - it detects which one you are on (via CraftLib) and plans with the correct recipes and skill cap:

- Classic Era / Anniversary (Vanilla) - cap 300
- Season of Discovery - cap 300
- The Burning Crusade Classic - cap 375
- Wrath of the Lich King Classic - cap 450, includes Inscription (also loads on the Titan 3.80 seasonal client)
- Hardcore (Classic Era)
- WoW Forever 1.60 - cap 300 (assumed until confirmed); all 9 professions

## License

All Rights Reserved - See [LICENSE](LICENSE) for details.
