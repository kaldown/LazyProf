# Changelog

All notable changes to LazyProf will be documented in this file.

## [Unreleased]

Plan, then shop: open a profession, see the cheapest path from your real skill, choose how far to level, get one total of what to buy.

### Added

- A receipt at the top of the window: "You spend" (reagents still to buy plus recipes to buy or learn), "Back from selling" (what the crafted items sell for) and "Net cost" (or "Net gain" when the crafts sell for more). "You spend" is exactly the Shopping tab added up, to the copper. Further lines say what your own stock saves, what making reagents yourself saves or costs, that spare crafts are included, and when a price is missing, still loading or too old.
- "Level to": a number box and a slider from your skill to the last cap. Dragging shows the number; the path is planned again when you let go, or when you press Enter in the box.
- Sale value: every total now counts what the crafted items sell for, and the Cheapest strategy counts it when it compares recipes - sold to a vendor by default (money you always get), at auction after the 5% cut (never less than the vendor's price; an auction price three or more days old is not counted, the vendor's is), or not at all ("Count what crafts sell for" in the options, "Selling" under More options). Two recipes that need the same reagents are no longer equal when one sells for more. A recipe with a reagent that has no real price (only an estimate, or none) is ranked as before.
- Your stock shapes the path: under Cheapest, reagents you own are counted when the path is chosen, against whole runs of a recipe, and only when that really costs you less. The planner works out up to four routes (market prices only; ranked with sale value; with your stock; the plan you already follow) and keeps the one you pay least for, so the path never costs you more than the market-price path would, by the addon's own count.
- The plan you shopped for stays: under Cheapest the route is remembered per character and profession and carried on from your current skill, so after buying the list the path does not wander to other recipes and ask for more. It gives way when it would cost more than the market-price path, or when another route is clearly cheaper (by more than 5% of what the market-price path costs with nothing owned). Choosing or resetting a recipe yourself plans that range again.
- Path tab: one list of the path - a row per recipe with its skill range, crafts and what its reagents still cost you. What has to be learned first is a line under its recipe ("Learn first: trainer, 4s"). The closest alternative is offered under a row when it costs you less or at most 10% more ("or: Dark Leather Pants" with the difference, such as "+14s", and a Use button). Click a row to open it in place: its reagents (Need / Have / Buy / Cost), what a craft sells for, how to learn the recipe and, on WoW Forever, the trainers you visited that teach it, the other recipes for that skill range with Use, and a Recipe details button. The row you are on is marked and stays open until you close it.
- "More options" (remembered) holds the rest: Cheapest / Fastest, "Spare crafts", the "Selling" mode, where the prices come from, the recipe search, "Hide what I have", the "I craft it / I buy it" buttons and, in planning mode, "Plan from skill 1". With it on, an opened row also says where the recipe changes colour, what a craft costs and, when your stock lowers the cost, what the run costs at market prices.
- Shopping tab: under the table, "Reagents to buy" with the sum of the Cost column, and "Recipes to learn": a row per recipe that costs something, with where it comes from and its price, and their sum. A recipe bought with a currency is listed with the currency amount; it is not part of the gold totals.
- While the game is still loading the data of crafted items, "Back from selling" shows what is known so far and says "still loading"; the path is planned again by itself when the data arrives.
- `/lp diag prices` prints which route was kept, what each candidate would cost you, how long planning took and how the sale values stand.
- Without the Syndicator addon the Shopping tab says so when bank or alt stock is switched on: "Only the bags of this character are counted. Install Syndicator to count your bank and alts too."
- `/lp diag stock`: where your stock is counted from (Syndicator, or the bags only), your bags as LazyProf reads them, the stock settings, and, with Syndicator, a line for each character it knows with the values of its record (on WoW Forever this shows whether it keeps one character twice under two realm names).

### Changed

- The window has two tabs, Path and Shopping, instead of Guide, Steps and Shopping. What the Guide card showed is now an opened row of the Path list.
- "Include bank items" and "Include alt characters" are now on by default, also if you had left them off (the old setting was never saved when it matched the default). Bank and alt stock are counted through the Syndicator addon, as before: without it the options are greyed out, say that they need it, and only the bags of the character you play are counted. The guild bank stays off. Turn the two off in the options, under "Your stock", if you do not want bank or alt stock counted.
- WoW Forever: the reagent bag now counts as part of your bags. Before, reagents kept in it were not seen.
- A character in Self-Found mode no longer counts the stock of your other characters or of the guild bank: it cannot be sent anything. A character the game itself marks Self-Found is treated the same for stock, also with the "Self-Found mode" setting off; which recipes the path may use still follows the setting alone.
- Shopping list order: what is still to buy first, the dearest on top; reagents you make yourself next; what you already own last, dimmed. The Buy number is no longer red.
- A reagent the list has you craft now uses what you own of it first, wherever it is; only the rest is crafted. Before, stock outside the bags was ignored and its raw materials were bought.
- Craft-or-buy no longer counts the same stock twice (once for the path and once for making another reagent), which could make the list dearer with stock than without.
- A path that makes something a later run uses (Bolts of Linen Cloth in Tailoring, for example) no longer has you buy it again: the later run uses what the path made, and those crafts are not counted as sold. An opened run on the Path tab says how many of its crafts go into later runs.
- Alternatives are compared over the whole run, craft by craft, after what the crafts sell for and with spare crafts on both sides. Before, an alternative that changes colour during the run, or any alternative while "With margin" was on, looked cheaper than it is. An alternative that cannot cover the whole run says how far it gets ("only up to 140") instead of a difference.
- A recipe you chose with "Use" is held exactly over its skill range; it no longer runs a few points past it.
- Amounts in the receipt and in the cost columns are shown to the copper, so they add up. The merchant panel's rows add up to its "Buy all" total.
- The merchant panel works from the shopping list of the whole path (there is no range any more), and also buys what still has to be bought of a reagent you otherwise craft. It never shops for a "Plan from skill 1" path: that one is only a look at the cost from skill 1.
- The arrow tooltip shows the receipt's amounts instead of the old totals.
- "Reset All Settings" and `/lp reset` say what goes with the settings - the vendor prices and trainers LazyProf has seen; every character's targets, chosen recipes, remembered routes, craft-or-buy choices and Self-Found mode; window positions; and the known recipes, which are read again when you open each profession - in the question before the reset and in the message after it.
- "With margin" is now called "Spare crafts", "Use this" is "Use" (a recipe you chose says "Your choice"), and the "Target" box is "Level to". A number typed into it counts when you press Enter; clicking elsewhere or pressing Escape puts the planned target back.

### Removed

- The coloured path bar, the Range dropdown, the footer with its totals (and the stray "|r" it showed beside the range total), and Prev / Current step / Next. To shop for the next bracket only, set "Level to" to its end.

### Fixed

- With Syndicator, an alt counts only when it is on the same realm as the character you play and of the same faction, and its soulbound items are left out; a character Syndicator has no realm or faction for does not count. Before, every character Syndicator knew counted, of every realm and faction, soulbound items included, so the list could ask for less than you can really get. `/lp diag stock` says which alts count and why the others do not.
- Right-click on "I craft it" / "I buy it" now goes back to the automatic choice, as its tooltip says; it never reached the button before. A choice you made shows its button even without More options, so it can be seen and undone.
- The scroll bar and its buttons were drawn when there was nothing to scroll.
- The selected strategy button (Cheapest / Fastest) could hardly be told from the other.
- A recipe you chose with "Use" could keep the planner from ever finishing: with "Include green recipes" on, when its range reached the skill where the recipe turns grey, or when the recipe's yellow and grey skill are the same.
- The "I craft it" button could read "I buy it" when your stock already covered the need.
- What has to be bought of a reagent that another crafted reagent is made from was missing from the list and the total.

### Known limits

- Sale value and owned stock change which recipes are chosen under Cheapest only. Fastest still plans for the fewest crafts; its totals count both.
- One crafted item per craft is assumed, so recipes that make several are undervalued when selling is counted.
- A run that makes fewer crafts than expected (bad luck with skill-ups) leaves a later run that uses them short; once the path is calculated again the list asks for the missing ones.
- After buying everything, the list can show a craft or two of top-up again while you follow the path: every calculation rounds the crafts still expected.

## [0.10.1] - 2026-11-22

### Added

- WoW Forever: Engineering and Mining can now be planned (bundled recipe data: 233 Engineering recipes and the 7 smelting recipes that give skill-ups). Mining's path ends where smelting stops giving skill-ups; the rest is leveled by mining.

### Changed

- WoW Forever recipe data refresh (bundled CraftLib): more recipes carry a known source, 19 recipes the game teaches automatically are available from skill 1, and 82 recipes left over from Season of Discovery are no longer offered.
- WoW Forever: 209 recipes sold for Merchant's Favor now show that price instead of a gold price. As before, a recipe bought with a currency is planned only when you already know it, unless "Include recipes bought with currency" is on, so some paths now pick other recipes.

### Known limits

- WoW Forever: 113 recipes that exist in game are still missing from the bundled data because their learn skill or source could not be established, and 327 of the bundled recipes have an unknown source. Learn skills and sources taken from guide tables are not confirmed in game yet.

## [0.10.0] - 2026-11-22

### Added

- One window with Guide, Steps and Shopping tabs replaces the milestone panel, the shopping list panel and the Planning window. It opens beside the profession window, can be moved and resized, and keeps its place and size.
- Guide tab: the step to do now, shown large - the recipe and how many to craft, the skill range and where its colour changes, a reagent table (Need / Have / Buy / Cost) and the step's cost. Prev, Next and "Current step" move through the path.
- A path bar across the top of the window: one coloured segment per step (orange, yellow, green), gaps in red, a tick at each rank still to train and a marker at your skill. Hover a segment to see the step, click to open it.
- Steps: consecutive crafts of one recipe are shown as one step instead of many five-craft rows, with whole skill numbers.
- Learning a recipe and training the next rank are steps of their own. A learn step says where the recipe comes from (trainer, vendor, your bags, bank or an alt, or the auction house with its price), the fee when it is known, and the skill it needs. A rank step sits at the skill cap it lifts ("train before 150").
- Target skill: type the skill you want to reach in the window; the path, costs and shopping list end there. Remembered per character and profession.
- "With margin": plans extra crafts and reagents for bad luck with skill-ups, rounded up once per step. The percentage is an option (5-30, default 15). The margin never changes which recipes are chosen; totals show both the expected and the with-margin figure.
- Alternatives on the step itself: the best three other recipes with how many crafts and how much gold they would change, "Show all" for the rest, and "Use this" to switch, which replans at once. A switched step says so and has "Reset".
- Shopping tab: one table per reagent with Need, Have, Buy and Cost, a "vendor" mark on vendor-sold reagents, the "Collect first" block (bank, mail, your auctions, guild bank, alts) and a "Hide what I have" box.
- Craft or buy per reagent: reagents you can make yourself get an "I craft it" / "I buy it" button (right-click for automatic). The choice is per character, works under both strategies and changes the shopping list only.
- Buying at a vendor: when the open merchant sells reagents on your list, a panel beside the merchant window lists them with a Buy button each and "Buy all" with the total. Purchases go out one stack at a time and stop when the merchant closes, the money runs out or the bags are full; limited-stock items and items not sold for gold are listed with the reason and never bought automatically. One line afterwards says what was bought and what was skipped.
- LazyProf remembers vendor prices it sees at merchants (reagents sold for gold without a stock limit), so vendor reagents are priced and marked without TSM or Auctionator. The built-in vendor list is now used for prices too.
- WoW Forever only: profession trainers you visit are remembered (name, zone, where you stood) together with the fees they charge. Learn and rank steps list the trainers you have visited, and a remembered fee is used where the recipe data has none. Other clients do not record trainers.
- `/lp diag merchant` and `/lp diag trainer` report what LazyProf reads from an open merchant or trainer window in a copyable window.
- WoW Forever (1.60) support from the same addon. LazyProf adapts to the Forever profession window, uses native dropdowns and panel frames, and opens from an addon compartment entry instead of a minimap button. The bundled CraftLib ships Forever recipe data for 7 professions: Alchemy (169 recipes), Blacksmithing (387), Enchanting (221), Leatherworking (467), Tailoring (373), Cooking (122) and First Aid (28). Engineering and Mining are not included yet while their data is being confirmed in game.
- Recipes with an unknown source are only suggested once you have learned them, own them, or can buy them. They are labelled "Unknown source".
- New option "Include recipes bought with currency" (off by default). Recipes bought with a currency such as Merchant's Favor are otherwise only suggested when already learned.
- `/lp diag forever` reports the Forever client state (profession window, recipe data, CraftLib version) in a copyable window.
- `/lp resetpanels` and a "Reset panel positions" option move the panels back to their default places.
- When the open profession has no recipe data yet, the window says so ("No recipe data for Engineering yet.") instead of showing nothing.
- Where each price comes from: the arrow tooltip lists how the path's reagents were priced (TSM, Auctionator, vendor, sell-value estimate) and warns when some have no price yet or none at all, when Auctionator prices are 3 or more days old, or when only the sell-value estimate was available. The shopping list tooltip shows each item's price and source.
- `/lp diag prices` lists every reagent price of the path with what TSM, Auctionator, vendor and sell value each say, the age of Auctionator prices, and flags prices that are stale or where the sources disagree.
- On WoW Forever, `/lp diag forever` checks the recipe data for the open profession against the game: difficulty at your skill, gray level, reagents and crafted item.

### Fixed

- Opening a profession, crafting or a busy debug log no longer runs several full recalculations or refreshes in a row; bursts are combined into one as intended.
- Switching to another profession at the same skill with the window open now updates the path.
- The recipe arrow no longer reappears after combat over a closed profession window, and an arrow due during combat now appears when combat ends.
- The arrow tooltip says "(excluding gaps)" on its totals when the path has gaps, like the window.
- "Can I craft this reagent myself" now means the recipe is in your learned recipes (First Aid and non-trainer recipes were judged wrongly before); it falls back to the old guess only for a profession whose window was never opened on this character.
- The arrow tooltip no longer says "Prices may be stale" on every path; the warning now appears only when prices really are old.

### Changed

- Paths no longer stop silently at a skill gap. A gap is bridged with a green recipe while its skill-up chance is at least 10%; otherwise it is shown as a gap in the path.
- Panel positions are kept, and a panel you closed stays closed until the profession window is reopened. Panels are restored correctly after combat.
- A profession you have is always planned from your real skill: every count, cost and shopping figure covers only what is left. The "Calculate from current skill" option is gone; the full path from skill 1 is a "Plan from skill 1" box in planning mode, and the path bar shows what you have already done.
- Planning any profession now happens in the same window: open it from the minimap button, the addon compartment or `/lp browse`, pick the profession in its header, close it with Escape. A profession window that opens docks the window; when it closes, the planning view comes back.
- Pinned recipes cover a skill range, take effect at once (the Recalculate button is gone) and are kept between sessions, per character and profession, until your skill has passed them.
- The arrow tooltip shows the current step, the next two, the totals and the price sources instead of every step; the Steps tab has the full list.
- "You pay" totals include recipe fees.
- The two options "Show milestone breakdown" and "Show missing materials" became one, "Open with the profession window". It is off only if both were off.
- The milestone panel and the shopping list can no longer be shown side by side; they are tabs of one window.
- Target, pins, craft-or-buy choices and the last tab are stored per character under the character's id rather than its name and realm.
- Panel rows are reused, so long crafting sessions no longer build up frames.
- A price from an Auctionator scan you made this session (since login or /reload) is now used before TSM, for reagents and for recipes bought at the auction house. TSM's prices only reach the game at login or /reload, so a scan made just before planning is newer. Vendor prices still come first. Closing the auction house refreshes the path's prices when the profession window is open; a planning view picks them up the next time it is planned.

### Known limits

- Racial profession bonuses on Forever are treated as 0 until confirmed.
- Required tools (for example enchanting rods) are not taken into account when planning paths yet.
- The skill cap on Forever is assumed to be 300 until confirmed.
- Rank steps say only "train the next rank before N": the rank's name, fee and level requirement are not shown because they are not confirmed for any client.
- On Classic Era (not Season of Discovery) a learn step says only "Learn the recipe": that client's recipe data lists every recipe as trainer-taught, so no source is named.
- The merchant panel uses the shopping list of the path you last looked at in the current play session; before any profession or the LazyProf window was opened in a session it stays away.
- Vendor buying, trainer memory and the new window were built for WoW Forever and are tested there. They use the same code on the Classic clients, where vendor buying stays inactive if a client lacks the calls it needs and trainers are not recorded.

## [0.9.0] - 2026-06-30

### Added

- Self-Found mode: a new per-character toggle (in General settings) that makes the leveling path recommend only recipes you can complete without the Auction House or trading with other players. A recipe is set aside when one of its reagents can only come from the AH or another player - for example an Alchemy elixir when you are not an Alchemist. Items you already own, vendor-sold reagents, gathered materials, and anything you can craft with a profession you have all count as obtainable. Set-aside recipes stay visible but dimmed in the alternatives list, with a short reason such as "Needs Alchemy". As a side effect, when you have no auction-house addon installed, drop, reputation, and quest recipes you can farm yourself are no longer hidden from the path.

## [0.8.2] - 2026-06-30

### Fixed
- Corrected the WotLK 3.3.5a client interface from 30305 to 30300, so LazyProf is no longer flagged out of date on 3.3.5a realms.

## [0.8.1] - 2026-06-30

### Added

- Interface support for additional Wrath of the Lich King clients: the WotLK 3.4.5 client and the Titan (3.80) WotLK seasonal client now load LazyProf without an out-of-date warning (uses the WotLK recipe data via CraftLib 0.10.1).

## [0.8.0] - 2026-06-30

### Added

- Wrath of the Lich King Classic support: LazyProf now plans leveling paths on WotLK Classic clients (interface 30403), capping each profession at 450 and including Inscription. Wowhead links open on the WotLK site, and racial profession bonuses apply correctly per client.
- One install now serves every live Classic-family client - Classic Era / Vanilla, Season of Discovery, TBC, and WotLK Classic - each using recipe data built from its own game version (via the bundled CraftLib).

## [0.7.6] - 2026-06-29

### Fixed

- Recipes you have already learned are no longer shown as "[!] Unlearned" in the milestone breakdown, the alternatives list, and the arrow tooltip. On some clients (including Season of Discovery and Classic Anniversary) the game does not expose recipe spell links, so the learned-status scan saw nothing and treated every recipe as unlearned. LazyProf now identifies learned recipes by their crafted item, falling back to the recipe name for enchants - both in the live profession view and in Planning mode.

### Added

- New `/lp diag learned` command that reports learned-recipe detection details (scan counts, active filters, and how many recipes were matched) in a copyable window, to help diagnose recipe-status issues. Type `/lp diag` to list available diagnostics.

## [0.7.5] - 2026-06-27

### Fixed

- Bundled CraftLib 0.9.0: nine Season of Discovery Phase-8 recipes that were previously missing now appear with their real source - five quest-taught (the Specklefin Feast and Grand Lobster Banquet feasts, and the Teleport / Nitro Boosts / Magnetic Displacement tinkers) and four learned by discovery (the Grand Crusader, Grand Arcanist, Grand Sorceror, and Grand Inquisitor weapon enchants). Classic/TBC behavior is unchanged.

## [0.7.4] - 2026-06-26

### Fixed

- Bundled CraftLib 0.8.1: more Season of Discovery recipes that were wrongly shown as trainer-taught now display their real source - chiefly reputation recipes (with faction and standing), plus quest rewards, vendor plans, and world drops. Classic/TBC behavior is unchanged.

## [0.7.3] - 2026-06-26

### Fixed

- Bundled CraftLib 0.8.0: Season of Discovery recipe sources previously shown as trainer-taught (drop, vendor, and quest patterns) now display their real source. Classic/TBC behavior is unchanged.

## [0.7.2] - 2026-06-25

### Fixed

- Opening a profession for the first time in a session no longer hitches the game. Cold reagents whose item data had not yet downloaded were re-triggering a full path recalculation for each one as the data streamed in (up to ~20 recalculations in a couple of seconds). Those are now coalesced into a single recalculation once the item data settles.
- Recipe availability is now cached for the duration of a single path calculation instead of being re-checked (including live auction-house lookups) for every candidate at every step.
- Verbose debug log lines are no longer built when debug logging is turned off (the cost was previously paid on every recalculation regardless), which also removes the freeze and "script execution limit" warnings when leveling a profession with the debug window open.
- Debug log window no longer stalls the game for a few seconds during verbose scoring runs (affects users who enable debug mode and keep the log window open). The log buffer now trims in amortized O(1) batches instead of shifting the entire buffer on every line, the window draws only the most recent lines (the full trace stays in memory and is reachable via the category/bracket filters or Copy All), and the skill-bracket lookup is no longer rebuilt per line. The in-memory buffer cap was right-sized from 5000 to 2000 entries.

## [0.7.1] - 2026-06-25

### Changed

- Updated bundled CraftLib to v0.7.0, which adds Season of Discovery Mining (smelting) recipes. SoD profession coverage is now complete.

## [0.7.0] - 2026-06-24

### Fixed

- **Recipe selection was arbitrary with no auction house data**: With no TSM/Auctionator prices (e.g. no AH access), gathered materials like leather had no price, so the Cheapest strategy scored every recipe as infinite cost and picked one effectively at random - suggesting a 2-leather recipe over a 1-leather one even when both were orange. Materials with no market price now fall back to their vendor sell value (read from the game, no AH needed), so the cheapest-by-materials recipe is chosen correctly. New "Estimate from vendor sell value when no AH price" toggle (Pricing settings, on by default) controls this.

### Changed

- Season of Discovery support: racial profession bonuses, skill brackets, and Wowhead links now adapt to the running client via `CraftLib:GetActiveFlavor()`. On a SoD/Classic Era client, TBC-only races are excluded, skill brackets follow the profession's actual milestone caps with neutral labels, and Wowhead links point at `/classic/`.
- Debug log buffer raised from 500 to 5000 entries so a full single-profession scoring trace (1-300) fits without dropping the early skill ranges. The window now shows a notice at the top when older lines are still dropped (e.g. after several recalculations), and the per-line window refresh is debounced to stay responsive during verbose scoring runs. To capture one clean run, use Clear, then trigger a single recalculation.

## [0.6.0] - 2026-02-24

### Added
- Recipe search in Planning Window - type to filter all profession recipes by name, click to view details

## [0.5.0] - 2026-02-19

### Changed
- License changed from MIT to All Rights Reserved
## [0.4.7] - 2026-02-13

### Fixed
- **Alternatives column overlap**: Skillup % column overlapped with cost column in narrow panels. Commented out % display (still visible in tooltip on hover) and widened recipe name column.
- **Recipe Details layout overlap**: Long recipe names that wrap to two lines no longer overlap with skill requirement and difficulty bar. Panel now dynamically repositions all elements based on actual text height.
- **Confusing "ea" abbreviation in costs**: Replaced unclear "5g ea (25g)" format with "5g (25g for 5)" showing total cost and craft count.

### Added
- **Shift-click item linking in Recipe Details**: Shift-clicking the crafted item icon, reagent icons, or recipe source item now pastes the item link into chat or AH search.

## [0.4.6] - 2026-02-12

### Fixed
- **Vendor-sold reagents priced from AH instead of vendor**: Items like Blue Dye, vials, and flux were priced at AH market value because the vendor provider was checked last in the priority chain. Vendor prices are now checked first using TSM and Auctionator's recorded merchant data, so reagents sold by NPCs always use their fixed vendor price.

## [0.4.5] - 2026-02-11

### Added
- **Interactive item tooltips in Recipe Details**: Hovering the crafted product icon, reagent icons, or the recipe source item now shows the full GameTooltip with addon overlays (TSM/Auctionator pricing, etc.). Reagents and recipe source items display 16x16 item icons.
- **Training cost display**: Trainer-sourced recipes now show the training cost inline in the Recipe Details source section (e.g., "Any Alchemy Trainer (5g)").

### Changed
- Updated CraftLib to v0.3.0 (adds training cost data for trainer recipes)

## [0.4.4] - 2026-02-10

### Added
- **Exclude green recipes setting**: Green recipes are now excluded from pathfinder suggestions by default. No proven formula exists for green skillup probability - the commonly cited linear formula significantly overestimates actual rates. Users can opt in via "Include green recipes" in settings at their own risk.
- **Extended debug logging**: Pathfinder debug now logs owned materials inventory, active settings (including green recipe filter), and out-of-pocket cost comparisons showing when alternatives are cheaper due to owned materials.

### Removed
- **Dead "Calculate intermediate crafts" setting**: This toggle was visible in settings but had no effect on any code path. The working material resolution feature uses the separate "Material Resolution" dropdown instead.

## [0.4.3] - 2026-02-10

### Added
- **Bracket filter for milestone panel and shopping list**: Dropdown on milestone panel filters steps by skill bracket (Apprentice 1-75 through Master 300-375). Defaults to current skill bracket and auto-advances on recalculate. Shopping list shows only materials for the selected bracket range.
- **Extended inventory scanning**: Shopping list now checks mailbox, active AH listings, and guild bank for materials via Syndicator
  - Mail items are always scanned (current character + alts when enabled)
  - Active AH listings are always scanned, shown as "Cancel from AH" with distinct orange styling
  - Guild bank scanning available via new "Include guild bank" toggle (disabled by default)
  - New shopping list sections: "Check Mail", "Cancel from AH", "From Guild Bank"
- **TSM Recent Value price source**: Added DBRecent (72-hour rolling average) as a pricing option alongside DBMarket. Useful when DBMarket lags behind current prices.

### Fixed
- **Milestone breakdown no longer double-counts inventory**: Previously, each step independently subtracted owned materials (e.g., 3 Essence of Fire deducted from every step instead of only the first). Now simulates inventory consumption step-by-step so materials are allocated once.
- **Recipe acquisition cost no longer inflated across steps**: Unlearned recipes spanning multiple steps (e.g., Lifelike Mechanical Toad across 4 steps) previously charged the recipe purchase cost on every step. Now charges once on the first step only. Scoring was already correct; only displayed totals were affected.

### Changed
- **Milestone breakdown shows out-of-pocket cost**: Step rows and totals now show inventory-adjusted cost (green) alongside dimmed market price when you own materials. Helps identify which steps save money.
- **Alternative recipes sorted by out-of-pocket cost**: Alternatives list now sorts cheapest-for-you first instead of by market price score. Recipes you have materials for rise to the top.
- **Arrow tooltip shows inventory-adjusted total**: Hover tooltip displays out-of-pocket total when inventory savings exist.
- **Scanner refactored to registry pattern**: Inventory sources are now modular - adding future sources requires only a new scan function and registry entry
- **CalculateMissingMaterials simplified**: Source categorization uses waterfall pattern (bags, bank, mail, auctions, guild bank, alts, AH) with unified sourceBreakdown data
- **Pathfinder debug logging improved**: `Calculate()` and `Recalculate()` now log what triggered them (e.g., "trade skill opened", "setting changed", "recalculate button (2 dirty pins)"). Active pins are logged before path calculation starts.

## [0.4.2] - 2026-02-09

### Changed
- **Removed "Use owned materials as free" setting**: Pathfinder now always scores recipes at market price, producing consistently optimal paths. Owned materials (bags, bank, alts) are subtracted in the shopping list instead, so you still see what you actually need to buy. The "Include bank items" and "Include alt characters" settings now work independently under a new "Shopping List" section.

### Fixed
- **Planning window pin+recalculate now works**: Pinning an alternative recipe in the Planning Window and clicking Recalculate had no effect because the recalculate button was reading the active profession's path instead of the planning window's own path. Both dirty pin detection and recalculation now correctly use the panel's own stored path.
- **Skill-up probability now uses accurate continuous formula** ([#6](https://github.com/kaldown/LazyProf/issues/6)): Replaced flat per-color probabilities (yellow=50%, green=25%) with the actual WoW formula: `(gray - skill) / (gray - yellow)`. Deep green recipes near gray previously showed 25% when real chance was 1-5%, causing massively underestimated craft counts. Early yellow recipes were undervalued at 50% when real chance was ~100%.
- **Dynamic step size cap prevents over-committing to low-probability recipes**: The pathfinder now limits step size proportionally to skillup chance (e.g., 25 crafts at 20% instead of 100), forcing re-evaluation sooner so cheaper alternatives can win after owned materials are depleted.
- **Bank scanning now works**: `ScanBank()` was calling `Syndicator.API.GetCurrentCharacter()` and treating the returned character name as a data object. Bank items were silently ignored since the feature was introduced. Now correctly fetches character data via `GetByCharacterFullName()`.
- **Shopping list no longer double-subtracts bag items**: Materials in your bags were subtracted twice (once during aggregation, once during categorization), causing the shopping list to under-report quantities you actually need to buy.

## [0.4.1] - 2026-02-09

### Fixed
- **Recipe Details difficulty bar now accounts for racial profession bonus**: Previously showed incorrect color (e.g., gray instead of green for gnomes with +15 Engineering)
- **Recipe Details difficulty matches milestone context**: When opened from milestone breakdown, shows difficulty at the step's skill level rather than current skill

### Added
- **Difficulty thresholds in Recipe Details**: Shows all four difficulty levels (orange, yellow, green, gray) with their skill values, active level marked with `>`, and racial-adjusted thresholds in square brackets (e.g., `Green: 270 [285]`)

### Changed
- **Alternatives now show all recipes regardless of availability**: Drop, reputation, and quest recipes that were previously hidden when not on the Auction House now appear in the alternatives list
  - Unavailable recipes are visually dimmed and sorted to the bottom
  - Tooltip shows source info (e.g., "Cenarion Expedition (Honored)") with "Not currently obtainable" note
  - Users can pin unavailable recipes they plan to obtain
  - Auto-selected path is unchanged - only available recipes are auto-picked
- **Alternative row click now opens Recipe Details**: Click a row to see full recipe info before deciding; use the `[>]` pin indicator to toggle pins
- Removed unused `includeDropRecipes` config setting

## [0.4.0] - 2026-02-08

### Added
- **Alternative recipes with pinning** ([#5](https://github.com/kaldown/LazyProf/issues/5)): Expand any step in the milestone breakdown to browse all scored recipe candidates at that skill level
  - Each alternative shows difficulty color, skillup chance, cost per craft, and unlearned status
  - Hover tooltip shows full material list and source info for unlearned recipes
  - Alternatives grouped into collapsible packs of 5 under a dedicated "Alternatives" section, keeping the UI clean
  - Click any alternative to pin it as an override for that skill level
  - Pinned steps show a blue `[*]` indicator in the skill range
  - "Recalculate with N pins" button appears when pins differ from the optimizer's choices
  - Recalculate reruns the pathfinder respecting all pinned overrides, updating the full path, shopping list, and arrow
  - Pins are session-only (reset on /reload) - designed for exploring "what if" scenarios
  - Score and delta details shown in tooltip only when debug mode is enabled

## [0.3.10] - 2026-01-30

### Fixed
- **Recipe acquisition costs now properly amortized**: One-time costs (vendor recipes, AH recipe items) are spread over expected crafts instead of being added to every scoring evaluation. This fixes recipes usable for many crafts being unfairly penalized (e.g., Filet of Redgill score: 16000 -> ~220).
- **CraftLib v0.2.12**: Fixed incorrect difficulty data causing wrong recipe suggestions
  - Steam Tonk Controller showed as orange when actually green at skill 280
  - Thorium Shells showed as red when actually yellow at skill 295+
  - Large Prismatic Shard and other Enchanting conversion recipes no longer appear at low skill levels

## [0.3.9] - 2026-01-29

### Added
- **Racial profession bonus support**: Pathfinder now accounts for racial skill bonuses that extend recipe color ranges
  - Gnome: +15 Engineering (recipes stay orange/yellow/green 15 skill points longer)
  - Blood Elf: +10 Enchanting
  - Draenei: +5 Jewelcrafting
  - UI shows racial bonus in planning window status bar (e.g., "Current skill: 198 (+15 Gnome)")
  - Recipe colors in milestone breakdown now correctly reflect racial bonus

## [0.3.8] - 2026-01-28

### Fixed
- **Jewelcrafting and Mining paths now work**: Fixed empty leveling paths for professions where first recipe requires skill > 1
- Pathfinder now skips to next available recipe when no candidates exist at current skill level
- **Arrow not showing in Anniversary Edition**: Arrow assumed 8 visible recipe slots (Classic), but Anniversary/TBC shows 20+. Now dynamically detects visible slots

### Changed
- Debug log command shortened from `/lp debuglog` to `/lp log`
- Arrow scroll handling debounced for better performance

### Added
- Recipe availability filtering: Unlearned recipes are now filtered from leveling paths unless they can actually be obtained
  - Checks player inventory (bags, bank, alts) for recipe items
  - Verifies trainer recipes meet faction requirements
  - Vendor recipes always available (player can travel)
  - Drop/quest/reputation recipes checked against Auction House listings (TSM/Auctionator)
- Recipe acquisition cost included in path calculations: Trainer, vendor, and AH costs are now factored into recipe scoring (recipes you already own are free)
- Enhanced tooltip shows acquisition details for unlearned recipes:
  - Location if in inventory ("In your bags", "In your bank", "On alt: Name")
  - Trainer name and cost
  - Vendor name, location, and cost
  - Auction House price with source (TSM/Auctionator)
  - Wowhead link to recipe item

## [0.3.7] - 2026-01-27

### Fixed
- **FPS hitches during batch crafting** (GitHub Issue #3): Separated expensive path recalculation from lightweight shopping list updates. Now only recalculates the full path when skill level changes, while bag changes trigger a cheap inventory refresh only.

## [0.3.6] - 2026-01-27

### Fixed
- **"Calculate from current skill" checkbox now works**: Setting was defined but never used by the pathfinder
- **Planning window empty content**: Embedded MilestonePanel was rendered behind the window due to frame strata conflict
- **Planning window not refreshing on settings change**: Now updates when toggling "Calculate from current skill"

### Changed
- MilestonePanel refactored to reusable class pattern (`MilestonePanelClass`)
- PlanningWindow uses embedded MilestonePanel instance (removed ~280 lines of duplicate code)
- Improved UI debug logging with scroll frame and row positioning diagnostics

## [0.3.5] - 2026-01-27

### Added
- **Owned Materials Optimization**: New pathfinding mode that treats materials you own as free
  - Enable "Use owned materials as free" in Display settings to minimize actual gold spent
  - Optionally include alt characters' bags and banks (requires Syndicator/Baganator)
  - Shopping list now shows "From Alts" section with character names
- **Copy All button in debug window**: Click to select all text, then Ctrl+C to copy

### Changed
- Welcome message no longer shows redundant addon name (Ace3 Print already adds prefix)

## [0.3.2] - 2026-01-26

### Fixed

- **Pathfinder now re-evaluates at breakpoints**: Previously, the pathfinder would commit to a recipe until it went gray, potentially skipping cheaper recipes that became available at intermediate skill levels. Now it stops and re-evaluates when:
  - A new recipe becomes learnable (skillRequired boundary)
  - The current recipe changes color (orange→yellow, yellow→green)

## [0.3.1] - 2026-01-26

### Fixed

- Updated CraftLib to v0.2.7: removes 46 invalid/placeholder recipes (e.g., Crystal Infused Bandage)

## [0.3.0] - 2026-01-25

### Added
- **TSM Price Source Selection**: Choose which TSM price to use for calculations
  - Min Buyout (current AH prices - what you can buy NOW)
  - Market Value (realm average)
  - Region Average (cross-realm, stable but may differ from local)
- Settings recommendation when TSM is not installed, showing which fallback is active
- Debug window auto-updates in real-time when open (no more chat spam during debugging)
- Detailed pathfinder debug logging showing candidate scores, colors, and costs

### Changed
- Default TSM price source changed from Region Average to Min Buyout for more accurate local pricing
- TSM provider now properly returns nil for items with no price data (0 = no data, not free)
- Debug messages only print to chat when debug window is closed

### Fixed
- Items with no AH data no longer appear as "free" (0 cost) in path calculations
- Removed non-functional "Scan AH Now" button and "Auto-scan AH" toggle

### Technical
- TSM price source configurable via `/lp` → Pricing settings
- Price fallback chain: selected source → other TSM sources → Auctionator → Vendor

## [0.2.10] - 2026-01-25

### Added
- Debug log popup: `/lp debuglog` opens copyable log window (Ctrl+A, Ctrl+C)

### Fixed
- PlanningWindow now standalone (no longer hijacks MilestoneBreakdown)
- Skill detection uses Classic-compatible API (GetSkillLineInfo)
- Planner correctly shows current skill level for learned professions

## [0.2.8] - 2026-01-25

### Added
- Profession Browser: Browse and plan any profession's leveling path
- Minimap button for quick access to profession browser
- Planning mode: See full leveling path and costs for any profession

### Fixed
- Planning mode now correctly calculates paths (skill level starts at 1, not 0)
- Professions now load reliably from CraftLib on startup
- Resize PlanningWindow properly refreshes content layout

## [0.2.7] - 2026-01-25

### Changed
- Milestone Breakdown now shows step-by-step format like wow-professions.com guides
  - Each recipe displays as its own row: "184-197: 30x Bronze Tube - materials"
  - Click to expand and see detailed material list with have/need counts
  - Trainer milestone separators (75, 150, 225, 300) appear between relevant steps
  - Hover tooltip shows full material breakdown

## [0.2.6] - 2026-01-24

### Fixed
- CraftLib v0.2.4: All 10 professions now have Wowhead-verified difficulty values (97.7% coverage)

## [0.2.5] - 2026-01-24

### Fixed
- Removed invalid interface version (38000) from TOC

## [0.2.4] - 2026-01-24

### Added
- Automated releases via GitHub Actions (CurseForge, Wago.io, GitHub Releases)

### Changed
- Milestone breakdown now shows missing count (e.g., "178x Silk Cloth") instead of confusing have/need format (e.g., "22/200")

## [0.2.3] - 2026-01-24

### Fixed
- CraftLib v0.2.2: Corrected skillRequired values for First Aid and Cooking (e.g., Runecloth Bandage now correctly requires 260 to learn, not 200)

## [0.2.2] - 2026-01-23

### Added
- Friendly error dialog when CraftLib dependency is missing
- Graceful addon disable instead of silent failure

## [0.2.1] - 2026-01-23

### Added
- Material Resolution system for intermediate crafting (smelt ore into bars, etc.)
- "To Craft" section in Shopping List showing intermediate materials to craft
- Config option: Material Resolution (None / Cost-compare / Always craft)
- Material flow annotations showing where resources come from (bank vs AH)
- CraftLib `GetRecipeByProduct` integration for reverse recipe lookups

### Changed
- Updated CraftLib to v0.2.0 with verified recipe sources for Cooking and First Aid

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
