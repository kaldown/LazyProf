# Testing Guide

LazyProf is tested in two ways: headless suites that run outside the game, and by hand in game with the steps below.

## Headless Suites

The pure logic (path, candidate routes, sale value, stages, shopping rows, purchase queue, what each tab shows) and the frames (against a fake UI) run under Lua 5.1 without the game:

```bash
bash scripts/run_tests.sh
```

The script runs every `scripts/test_*.lua` with `lua5.1`, then parse-checks every Lua file under `Core`, `Modules` and `Professions` with `luac5.1`. It must end with `OK: 36 suites passed, ...` before every commit; the same command runs on every push. A single suite runs from the repo root, for example `lua5.1 scripts/test_views.lua`.

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
| `test_stockmemory.lua` | Remembered bags and bank per character and the account bank per world: saving, alts of the same world and faction, soulbound items, the 180-day limit, the age wording |
| `test_stockflow.lua` | Stock through whole sessions on the real WoW Forever adapter, scanner and memory together: saved stock that is not what the addon wrote, a client call that fails, a Self-Found alt, a bank change in the frame the window closes, what a bank visit starts with, two characters of one account |
| `test_scanner.lua` | Which owned stock counts and how the stock memory is kept: Syndicator's stock unchanged, bank and alts from memory without it, bags saved a moment after a change and at logout, the bank read with each change while its window is open, at the close and in the first moments after opening, the alts' part kept between scans, Self-Found, the stock options, `/lp diag stock` |
| `test_views.lua` | What the window shows, as data: header, receipt, target model, Path list, Shopping list (with the age of remembered bank and alt stock), recipe search, arrow tooltip |
| `test_window.lua` | The window's frames on both client families: header, More options, target box and slider, receipt, the two tabs, closed state, combat, planning mode |
| `test_controls.lua` | The widget layer: tabs, button group, number box, checkbox, search box, slider, resize bounds, the row list |
| `test_widgets.lua` | The row pool and the per-client dropdown |
| `test_panelshell.lua` | Panel position, size, closed state and combat hide / restore |
| `test_arrow.lua` | The recipe arrow and its tooltip |
| `test_client.lua`, `test_forever_client.lua` | The Classic and the WoW Forever client adapter |
| `test_boundaries.lua` | Client API calls stay inside `Core/Client/` and `Modules/UI/Widgets/` |
| `test_charstore.lua` | Per-character planner data kept under the character's GUID |
| `test_learned.lua` | Learned-recipe detection |
| `test_profile.lua` | Per-client branches: Wowhead links, racial bonuses, skill brackets |
| `test_brackets.lua` | A what-if path from skill 1: the arrow follows the real skill |
| `test_perf.lua` | Debounced recalculation, the item-info trailing debounce, the availability memo, a burst of bag updates (one light refresh, one remembered snapshot, no recalculation) |
| `test_debuglog.lua` | The debug-log buffer and its rendering |
| `test_utils.lua` | The pure helpers in `Core/Utils.lua` |

Shared helpers live in `scripts/lib/`: `harness.lua` (stubs the game's globals, loads the recipe data of a chosen client and the addon's modules), `check.lua` (pass / fail bookkeeping), `fakeui.lua` (a fake frame API), `window.lua` (loads the window against the fake UI), `stockworld.lua` (a WoW Forever client small enough to follow stock through: bags, bank, characters, a clock; sessions load the real adapter, scanner and memory) and `shown.lua` (reads the amounts a view shows back into numbers, so a suite can check that what a player sees adds up).

Path and stage snapshots are rewritten with `UPDATE_SNAPSHOTS=1 lua5.1 scripts/test_paths.lua` (and `scripts/test_stages.lua`). Read the diff before committing it: with no sale values and no owned stock a snapshot only changes when the planner's choices or the recipe data changed.

New content of the window is tested as data in `test_views.lua`, not through frames.

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
5. Withdraw or deposit a stack and press Escape at once: Have is unchanged (the stack is counted once), and `/lp diag stock` says `bank updates while closed: 0`
6. Log in an alt of the same world and faction that carries materials, log back: a "From alts" row names it
   (hover it: "<name>: N - bags as seen less than an hour ago"; hover the "From bank" row: "Bank as seen less than an hour ago")
7. `/lp diag stock` lists both characters with `less than an hour ago` as the age of their bags
8. Tick Self-Found mode: the "From alts" row goes, "From bank" stays; on the alt, the ticked character is no longer listed under "From alts"
9. "Forget remembered characters": the "From alts" row goes until the alt is played again

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

- [ ] `bash scripts/run_tests.sh` ends with `OK: 36 suites passed`
- [ ] Opens without errors on each supported profession
- [ ] Path and Shopping tabs display correctly
- [ ] The receipt adds up to the Shopping tab
- [ ] Shopping list is accurate
- [ ] Works with TSM pricing
- [ ] Works with Auctionator pricing
- [ ] Works standalone (vendor prices)
- [ ] Existing features still work
