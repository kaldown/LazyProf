# Testing Guide

LazyProf is tested in two ways: headless suites that run outside the game, and by hand in game with the steps below.

## Headless Suites

The pure logic (path, candidate routes, sale value, stages, shopping rows, purchase queue, what each tab shows) and the frames (against a fake UI) run under Lua 5.1 without the game:

```bash
bash scripts/run_tests.sh
```

The script runs every `scripts/test_*.lua` with `lua5.1`, then parse-checks every Lua file under `Core`, `Modules` and `Professions` with `luac5.1`. It must end with `OK: 38 suites passed, ...` before every commit; the same command runs on every push. A single suite runs from the repo root, for example `lua5.1 scripts/test_views.lua`.

| Suite | What it covers |
|-------|----------------|
| `test_paths.lua` | Snapshots of the paths both strategies compute from the bundled recipe data (16 files in `scripts/snapshots/`) |
| `test_stages.lua` | Path steps folded into craft runs, learn steps, rank steps and gaps; spare crafts, done / current marks, totals, alternatives over a run (one stage snapshot) |
| `test_routes.lua` | The route the planner keeps: ranking by cost after sale value, stock counted against whole runs, the candidate routes, the remembered route, range edges, the planner always finishing |
| `test_account.lua` | The one accounting of what the player pays (shopping list of a set of steps, less what the crafts sell for), and on real recipe data that the receipt's amounts are the shopping list's |
| `test_salevalue.lua` | What one craft sells for (vendor, auction after the cut, nothing), the loading wait, and which recipes may be ranked by it |
| `test_loop.lua` | The whole loop on real recipe data: plan with stock, buy the list, craft point by point while the path is calculated again at every skill; following the planner must not cost more than following the plan that was shopped for (within 1% of the list) |
| `test_pins.lua` | Recipes chosen over a skill range |
| `test_gaps.lua` | Skill gaps: bridging with a green recipe, or a reported gap |
| `test_target.lua` | The target skill, where a path starts, and the settings migration |
| `test_shopping.lua` | The shopping list as one row per item, where owned stock is collected, the craft-or-buy choice |
| `test_sources.lua` | Currency-only and unknown-source recipes |
| `test_selffound.lua` | Self-Found mode: what is obtainable without the auction house |
| `test_prices.lua` | Where each reagent price comes from, the path's price summary, `/lp diag prices` |
| `test_vendor.lua` | Remembered vendor prices and the order of the vendor price sources |
| `test_purchase.lua` | What to buy at a merchant and buying it chunk by chunk |
| `test_merchant.lua` | The merchant panel and `/lp diag merchant` |
| `test_trainers.lua` | Remembered trainers and fees |
| `test_stockmemory.lua` | Remembered bags and bank per character and the account bank per region (with the world and faction of its reader, and which characters have read it): saving, a saved value that is not what the addon wrote, a saved time that is damaged, alts of the same world and faction, soulbound items, the doubt mark, the note of the bags a session left at the bank, the 180-day limit, the age wording |
| `test_stockflow.lua` | Stock through whole sessions on the real WoW Forever adapter, scanner and memory together: saved stock that is not what the addon wrote, a client call that fails (shown once, counted, reported by the dump), a Self-Found alt (by the setting, and by the game's own flag), the newest record of a name, the world read again after login, and the bank - when it is read and how often, which read is kept, a move in the frame the window closes or reported after it, the last stack of one bank moved into the other, a bank the character may not view, a session that ends before the answer of a move, a session that ends without its saved data written, a lock a kept read saw, an opening notice that comes again while the bank is open, damaged times of a note and of a bank, a bank marked in doubt until the next visit and named for the other characters - with the rule that a scan never counts more of an item than is owned; two characters of one account |
| `test_stockfuzz.lua` | A seeded random walk through bank visits on the real WoW Forever adapter, scanner and memory, with up to four characters (of one world and faction, of the other faction, of another world), checked against a model of what they really own. The client's unknown behaviours are switches: whether the bank can be read inside the close notice; which of a move's two updates comes first and how they are spread over frames; how long the answer of a move takes (up to 2.5 s; its slots stay locked meanwhile); whether the client lets go of the bank before the close notice; whether the items are all there at the opening (late, partly, or later than two seconds); when the batch notice comes; bag updates that change nothing; whether a bank container reports the answer of a move once the window is closed; a bank locked now and then while open; bank container updates that change nothing (also at login); whether the game's account bank is one for the account, one per world or one per world and faction; and whether an opening notice comes again while the bank is open. A random player moves, sorts, loots, crafts (also from the closed bank), closes, logs out (also, now and then, while the answer of a bank move is on its way and a lock of it can be seen), crashes now and then (a session that ends without its saved data written) and plays the other characters. The checks: no scan counts more than is owned; no bank is left out or short without the scan and the Shopping tab saying so (and an account bank read on another faction or world is said to be so); on a well-behaved client an open bank is right and an unhurried visit leaves no doubt mark; no character marks a bank it may not view; nothing raises. By default it runs three samples drawn from a fixed seed - any player on well-behaved clients and on others, a careful player, and one who closes the bank while a move is on its way: the same walks on every machine, about ten seconds. What the bank's rules accept on purpose is named in the file and kept out of the default run by name, not by loosening a check: habits the default player does not have (a log out or reload while the answer of a bank move none of whose locks can be seen is on its way; completely empty bags at a logout before they were saved; leaving before a bank shown partly or late was read whole; on a client that does not report the bank's part of a move after the close, a close while a move none of whose locks can be seen is on its way; a craft from the closed bank in the first ten seconds of a session; a crash of a session that began with its last one's note), a client that shows its bank later than two seconds after the opening (what follows is counted, not checked), a client that sends bank updates that change nothing (not well-behaved: the no-doubt checks do not judge it), kinds that are no failure (a mark another character set on a bank this one may not view; a tab bought in a visit of under two seconds; a carried count that rises in the second after a close, or before the next session's comparison, for an item a bank holds), and classes filed under their own name: `crash:` (what a crash leaves that the rules cannot see, until the bank it concerns is read again) and `midBankMove:` (what another character counts of one that logged out with a bank move on its way, before that one plays again). `STOCKFUZZ_ALSO` switches those habits on to see what follows from them, `STOCKFUZZ_MODE=campaign` runs many more walks, `shrink` cuts a failing walk down to a script, and `STOCKFUZZ_MUTANT` loads another scanner in place of the real one to see that the checks notice (the header of the file says how). It is not the whole acceptance test for the bank's rules: see "The bank's rules" below |
| `test_stockreset.lua` | "Reset All Settings" and `/lp reset` against the real database library: the remembered stock is kept, counted by the next scan and still saved after logout; the question before the reset and the message after it say what it clears and what it keeps |
| `test_scanner.lua` | Which owned stock counts and how the stock memory is kept: Syndicator's stock unchanged, bank and alts from memory without it, a bank in doubt left out, bags saved a moment after a change and at logout, the bank's rules as the scanner applies them (spacing, the batch notice, a bank unsettled by its own containers' updates, the close, a lock a kept read saw, a second opening notice, what marks after it, the note a session leaves at the bank, the comparison with the bags' last save, the first moments after opening, a mark seen by a later scan of the same frame), a scan never reading the bank, every entry point with its client call failing, the frame cache and the alts' part kept between scans, Self-Found, the stock options, `/lp diag stock` (also with Syndicator installed and on a client that reads no bank) |
| `test_views.lua` | What the window shows, as data: header, receipt, target model, Path list, Shopping list (with the age of remembered bank and alt stock, and the lines for a bank of the character or of an alt that is not counted, and for an account bank read on another faction or world), recipe search, arrow tooltip |
| `test_window.lua` | The window's frames on both client families: header, More options, target box and slider, receipt, the two tabs, closed state, combat, planning mode |
| `test_controls.lua` | The widget layer: tabs, button group, number box, checkbox, search box, slider, resize bounds, the row list |
| `test_widgets.lua` | The row pool and the per-client dropdown |
| `test_panelshell.lua` | Panel position, size, closed state and combat hide / restore |
| `test_arrow.lua` | The recipe arrow and its tooltip |
| `test_client.lua`, `test_forever_client.lua` | The Classic and the WoW Forever client adapter |
| `test_boundaries.lua` | Client API calls stay inside `Core/Client/` and `Modules/UI/Widgets/`, and the client's own item count and whether crafts may take reagents from the bank inside `Core/Client/` alone; the bank, logout and bag events are each registered in one place |
| `test_charstore.lua` | Per-character planner data kept under the character's GUID |
| `test_learned.lua` | Learned-recipe detection |
| `test_profile.lua` | Per-client branches: Wowhead links, racial bonuses, skill brackets |
| `test_brackets.lua` | A what-if path from skill 1: the arrow follows the real skill |
| `test_perf.lua` | Debounced recalculation, the item-info trailing debounce, the availability memo, a burst of bag updates (one light refresh, one remembered snapshot, no recalculation), no debug lines built by a stock scan while debugging is off |
| `test_debuglog.lua` | The debug-log buffer and its rendering |
| `test_utils.lua` | The pure helpers in `Core/Utils.lua` |

Shared helpers live in `scripts/lib/`: `harness.lua` (stubs the game's globals, loads the recipe data of a chosen client and the addon's modules), `check.lua` (pass / fail bookkeeping), `fakeui.lua` (a fake frame API), `window.lua` (loads the window against the fake UI), `stockworld.lua` (a WoW Forever client small enough to follow stock through: bags, bank, characters, a clock; sessions load the real adapter, scanner and memory) and `shown.lua` (reads the amounts a view shows back into numbers, so a suite can check that what a player sees adds up).

Path and stage snapshots are rewritten with `UPDATE_SNAPSHOTS=1 lua5.1 scripts/test_paths.lua` (and `scripts/test_stages.lua`). Read the diff before committing it: with no sale values and no owned stock a snapshot only changes when the planner's choices or the recipe data changed.

New content of the window is tested as data in `test_views.lua`, not through frames.

### The bank's rules

The rules that decide when a remembered bank counts (at the top of `Modules/Inventory/Scanner.lua`) are accepted only by the whole suite: `test_scanner.lua` (each rule on a stand-in adapter), `test_stockflow.lua` (whole sessions on the real adapter) and `test_stockfuzz.lua` (the random walk) together. Taking a rule out of the scanner one at a time shows what each guards. Every such scanner fails the suite, but the random walk alone passes with about half of them, which only the other two suites notice:

- the read taken when the client says a batch of bag updates is complete;
- an empty read of a bank remembered as empty, while the bank is unsettled, kept only on a second look;
- an opening notice that comes again while the bank is open unsettling both banks;
- at the close: the read taken again for an unsettled bank, kept only with the visit's slot count; the second a bank is held after its close, its end when the timer runs, and the mark when the session ends inside it; a lock a kept read saw, and its end with an update of that bank's own containers;
- the quiet first ten seconds of a session for updates of a closed bank;
- after the close: the three-second watch for a bank whose locks could not be seen; without a note of the bags, the mark of a carried update within each bank's own watch; the mark of a comparison that is given up; the note lowered to the counts that fell;
- the note of a session that ends at the bank, also within ten seconds after a close; its comparison at the bank's opening and at a logout; the exception for an account bank read after the note, and none for the character's own bank; a note whose time is damaged;
- the comparison with the bags' last save marking only the account bank the character counts and has read;
- every mark, and every end of a bank being left out, seen by a later scan of the same frame; marks and leaving-outs after the close only for a bank usable in the visit; a bank whose saved time is damaged not counted.

The scanners with a rule taken out are not part of the repository; `STOCKFUZZ_MUTANT=<file>` runs the random walk against such a file.

## In-Game Testing

### Basic Verification

After making changes, run `/reload` and verify:

1. Open any profession window (Cooking, First Aid, etc.)
2. The LazyProf window should appear beside it with two tabs under it, Path and Shopping (it opens on the tab used last)
3. The header shows the skill line, "Level to" with a number box and a slider, and the receipt ("You spend", ...)
4. Arrow should point to recommended recipe

### Testing Commands

```
/lp          - Open settings
/lazyprof    - Same as /lp
```

### Testing Path Calculation

1. Open profession at various skill levels
2. Verify the Path tab lists the path: one row per recipe with its skill range, crafts and cost; the row you are on is marked with `>`, highlighted and open
3. Check that costs are reasonable (not 0, not astronomical)
4. Verify the Shopping tab matches what the rows need
5. Verify the receipt adds up: "You spend" equals "Reagents to buy" plus "Recipes" on the Shopping tab, and "Net cost" equals "You spend" minus "Back from selling"

### Testing the Target ("Level to")

1. Drag the slider: the number in the box follows, the path does not change while dragging
2. Let go: the path, the receipt and the shopping list are planned to the new target, once
3. Type a number and press Enter: same result; a number outside the range is corrected (lowest: your skill + 1, highest: the last cap)
4. Type a number and click elsewhere, or press Escape: the planned target comes back
5. Set the target to your current bracket's end: the Shopping tab lists only what that part needs
6. /reload - the target is still there (it is kept per character and profession)

### Testing Sale Value and the Receipt

1. Click "More options": Cheapest / Fastest, "Spare crafts", "Selling" and the price line appear; click "Fewer options" and they go. The state survives /reload
2. Set "Selling" to "Vendor": "Back from selling" and "Net cost" appear when the crafts sell for something; an opened row says "Sells for ... each (vendor)"
3. Set "Selling" to "Auction house" (with TSM or Auctionator): the note says the crafts are sold at auction after the 5% cut, or to a vendor where that pays more
4. Set "Selling" to "Do not count": only "You spend" is left
5. Tick "Spare crafts": the craft counts and costs go up and the receipt says "Includes 15% spare crafts"; the recipes do not change
6. Run `/lp diag prices`: the `route:` line names the kept route and each `candidate` line its amounts

### Testing Pricing Providers

**With TSM installed:**
- Prices should use TSM market values
- Check items with known prices

**With Auctionator only:**
- Disable TSM, enable Auctionator
- Prices should use Auctionator scan data

**Standalone (no pricing addons):**
- Disable both TSM and Auctionator
- Vendor-sold reagents LazyProf knows (seen at a merchant, or on the built-in vendor list) keep their vendor price; everything else is estimated from its vendor sell value
- The price line (More options) counts those as "estimate"; its tooltip and the arrow tooltip say the cost uses the vendor sell value

### Testing Inventory Integration

1. Put materials in bags
2. Open profession
3. On the Shopping tab the Have column counts them and Buy goes down; fully owned reagents sit at the end of the table, dimmed
4. The receipt says "your own stock saves ..."

**With Syndicator** ("Include bank items" and "Include alt characters" are on by default):
1. Put materials in bank
2. The Shopping tab shows a "Collect first" block with a "From bank" row for them
3. `/lp diag stock` at the open bank says `bank: not followed (Syndicator is installed)` and prints no `bank visit` line

**Extended inventory sources (all require Syndicator):**
- Mail items on current character always scanned - verify a "Check mail" row appears
- Active AH listings always scanned - verify a "Cancel from AH" row in orange
- Enable "Include guild bank" - verify a "From guild bank" row appears
- "Include alt characters" - verify a "From alts" row with character names

**Without Syndicator** (LazyProf's own memory; WoW Forever for the bank):
1. "Include bank items" and "Include alt characters" are usable; "Include guild bank" is greyed out and "Forget remembered characters" is shown
2. Put materials in the bank, keep the bank window open, open a profession: a "From bank" row lists them
3. Close the bank and `/reload`: the "From bank" row is still there
4. Withdraw them: the row goes and the Have column still counts them (now in the bags)
5. Withdraw or deposit a stack and press Escape at once. The stack must not be counted twice; which outcome you see depends on when the game reports the move, and `/lp diag stock` says which it was:
   - Have is unchanged, the "From bank" row is right, and the dump says `after the close: bankUpdates=0 bagUpdates=0 compared=0 marked=none`: the move was reported before the window closed and the bank was read with it.
   - The Shopping tab starts with "Your bank is not counted: it may have changed after LazyProf last read it. Open the bank to count it again.", Have counts the bags only, and the dump names the bank and the reason - `bank visit close: ... markedInDoubt=character` (the bank's update came before the close and no read of it could be kept), `after the close: ... marked=character (bank container updated)` (it came after the close) or `... (carried count rose: <itemId>)` (only the bag's update came after the close). Open the bank again: the line goes and the bank counts.
   Paste the `bank visit`, `after the close` and `bank updates while closed` lines of the dump either way: they settle what the client does at a close.
   - Do nothing at the bank for ten seconds, close it and wait ten seconds more: `bank updates while closed` must not have grown and no bank may be marked. If it did grow, the client reports the bank's containers when it lets go of them and every visit ends in doubt: paste the lines.
   - Drag a stack from your bank into the account bank and press Escape at once: afterwards the stack is counted once, or both banks are named as not counted.
   - Close the bank and `/reload` (or log out) within ten seconds, then log in again: for the first two seconds the "From bank" row may be missing, then the dump says `bags at the bank (from the last session): compared, equal` and the bank counts. Paste the line if it says anything else although you moved nothing.
   - Log out later than ten seconds after a close and log in again: the dump says `bags as last saved (no note from the last session): compared, equal`. Paste the line if it says anything else although you moved nothing.
   - Withdraw a stack at the bank, close the bank, and close the game by force at once (Force Quit), so that nothing of the session is saved. Log in again: the Shopping tab names the bank as not counted, and the dump says `compared, different: character marked in doubt` - on the `bags as last saved (no note from the last session)` line, or on the `bags at the bank (from the last session)` line when the session before the lost one ended at the bank. Open the bank: the line goes.
   - With the bank open, click the banker again and run the dump: the `bank visit:` line ends `openedAgain=1` when the game reports the bank opening a second time. Paste the line either way.
6. Open the bank on a character of the other faction (same world), close it, and log in on the first character: the Shopping tab says "The account bank is not counted: LazyProf last read it on a character of another faction or world. It counts again once a character of this faction and world reads it at the bank.", and the dump's `account bank:` line ends `not counted (read in another world or by the other faction)`. Open the bank there: the line goes. Paste both characters' `account bank:` lines: the same items on both sides say that the game shares the account bank across factions
7. Log in an alt of the same world and faction that carries materials, log back: a "From alts" row names it
   (hover it: "<name>: N - bags as seen less than an hour ago"; hover the "From bank" row: "Bank as seen less than an hour ago")
8. `/lp diag stock` lists both characters with `less than an hour ago` as the age of their bags
9. Tick Self-Found mode: the "From alts" row goes, "From bank" stays; on the alt, the ticked character is no longer listed under "From alts"
   - On a character that is Self-Found in the game, with the setting unticked: the same, and `/lp diag stock` says `selfFound=false gameSelfFound=true` (on any other character `gameSelfFound=false`)
10. "Forget remembered characters": the "From alts" row goes until the alt is played again
11. "Reset All Settings" (or `/lp reset`): the question before it and the message after it say that the vendor prices, trainers, targets and craft-or-buy choices are cleared and the remembered bags and banks kept; the settings are back at their defaults, the "From bank" and "From alts" rows are still there
12. Stand at the open bank and craft, or sort the bank: no stutter; `/lp diag stock` shows `bank visit: ... reads=N` growing by a few per second at most
13. After a bank visit, walk away from the bank and run `/lp diag stock`: paste the `client count` lines. `withBank - carried` equal to `bank=` means the game counts the bank while its window is closed (then the remembered bank could be checked against the game at any time); `withBank` equal to `carried` means it does not
14. Paste the `crafting from the bank: reagentsFromBankAllowed=.. restrictedRule=..` line of the dump. With `reagentsFromBankAllowed=true`, close the bank, craft with a reagent that is only in the bank and run the dump again: `bank updates while closed` should have grown and the Shopping tab name the bank as not counted (if neither, the game does not report such a craft, and the remembered bank is too high until the next visit)

**Stock and the route (Cheapest):**
1. Own enough reagents for a whole run of a recipe that is not on the path
2. Open the profession: when using them is cheaper for you, the path uses that recipe and `/lp diag prices` shows `kept=stock`
3. Buy the shopping list, craft a few points: the path should keep its recipes (`/lp diag prices` shows `kept=previous` while the plan in hand is kept)

### Testing Alternative Recipes

1. Open profession with multiple recipe choices at same skill level
2. On the Path tab, click a row to open it: "Other recipes for N-M" lists the best three, then "Show all N"
3. Hover an alternative: the tooltip shows materials and, for unlearned recipes (`[!]`), the source
4. Click "Use" - verify the path is planned again at once and the opened row shows "Your choice" with a "Reset" button
5. /reload - verify the choice is still there
6. Click "Reset" - verify the planner's own recipe is back
7. Close the rows: where the closest alternative costs less or at most 10% more, an "or: <recipe>" line with a Use button sits under the row

### Testing Planning Mode

1. Left-click the minimap button (addon compartment on WoW Forever) or type `/lp browse`, pick a profession
2. The window opens undocked with a profession dropdown; Escape closes it
3. With More options on, a profession the character has offers "Plan from skill 1"; finished runs are listed dimmed

## Debugging

### BugSack/BugGrabber Setup

Install both BugSack + !BugGrabber to capture Lua errors.

**In-game commands:**
```
/bugsack       - Open BugSack UI to view errors
/bugsack show  - Show most recent error
```

### Reading Errors from SavedVariables

BugGrabber stores captured errors in SavedVariables. To read errors programmatically:

**Error file location (user-specific path):**
```
/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/!BugGrabber.lua
```

**Generic path structure:**
```
<WoW Install>/WTF/Account/<ACCOUNT>/SavedVariables/!BugGrabber.lua
```

**Error data structure:**
```lua
BugGrabberDB = {
    errors = {
        {
            message = "Error text here",
            stack = "Stack trace with file:line",
            time = "2026/01/25 15:49:53",
            locals = "Local variables at error time",
            session = 115,  -- Game session number
            counter = 1,    -- How many times this error occurred
        },
        -- ... more errors
    }
}
```

**Important:** Errors are only captured after the user:
1. Triggers the bug in-game
2. The error gets caught by BugGrabber
3. Logs out or `/reload` to save the data

### WoW Log Files

Additional logs are in the Logs directory:
```
/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/Logs/
```

Key files:
- `FrameXML.log` - Addon loading errors
- `Client.log` - General client issues

### Common Issues

**"CraftLib is nil"**
- CraftLib addon not installed or not loaded
- Check addon list in character select

**Path shows 0 cost**
- Everything the path needs is already owned (the receipt says what your stock saves), or
- No price is known and "Estimate from vendor sell value when no AH price" is off: cost cells show "?" and the receipt says how many reagents have no price. With the option on (the default), missing auction prices are estimated, not 0

**UI not appearing**
- Check for Lua errors in BugSack
- Verify both addons enabled

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the diagnostic commands (`/lp diag ...`).

## Test Checklist for PRs

- [ ] `bash scripts/run_tests.sh` ends with `OK: 38 suites passed`
- [ ] Opens without errors on each supported profession
- [ ] Path and Shopping tabs display correctly
- [ ] The receipt adds up to the Shopping tab
- [ ] Shopping list is accurate
- [ ] Works with TSM pricing
- [ ] Works with Auctionator pricing
- [ ] Works standalone (vendor prices)
- [ ] Existing features still work
