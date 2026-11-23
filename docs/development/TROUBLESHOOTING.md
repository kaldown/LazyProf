# Troubleshooting Guide

This guide helps you diagnose issues and capture information for bug reports.

---

## Quick Diagnostic Commands

Run these in-game to check addon health:

```
/lp                    -- Open settings panel
/lp browse             -- Open profession browser
/lp log                -- Open debug log window
/lp diag               -- List available diagnostics
/lp diag learned       -- Dump learned-recipe detection state (copyable window; Classic-family clients)
/lp diag forever       -- Dump WoW Forever client facts and adapter results (copyable window)
/lp diag prices        -- List every reagent price of the path, where it came from and which route was kept (copyable window)
/lp diag merchant      -- At a merchant: what it sells as LazyProf reads it, and what would be bought (copyable window)
/lp diag trainer       -- At a profession trainer: what it lists as LazyProf reads it, and what is remembered (copyable window)
/lp diag stock         -- Which bags and banks are remembered for your characters; at an open bank, what the bank reads as (copyable window)
/lp resetpanels        -- Move the LazyProf window and its panels back to their default place and size
/lp reset              -- Reset database to defaults
```

Enable debug mode in LazyProf settings to see detailed logging.

---

## Diagnostic Commands (`/lp diag`)

`/lp diag <topic>` runs a focused, read-only inspection and prints the result to a
**copyable popup window** (the same selectable text box as `/lp log` - chat output
cannot be copied out of the WoW client, so diagnostics always open a window). Each
diagnostic only reads game/addon state; it never changes settings or moves frames.

Use a diagnostic when a behavior is *silently wrong* (no Lua error, but the addon
does the wrong thing) and you need to see what the addon actually sees in-game.
Run the command, click **Select All**, press Ctrl+C, and paste the output into the
bug report or dev chat.

### `/lp diag learned` - learned-recipe detection

**When to use:** recipes you have already learned are treated as still to learn (a
"Learn first: ..." line under a row of the Path tab (on Classic Era data: "Learn the recipe first"), "(to learn)" or "[!] Unlearned" on
an alternative, a learn step in the arrow tooltip), or the wrong recipes are
treated as known. Open the profession window first, then run it.

**What each line means:**

| Line | Meaning |
|------|---------|
| `diag learned: <Prof> (key=...) skill=cur/max` | Active profession LazyProf detected, and your current/max skill. `key=nil` means detection failed (LazyProf has no data for this profession). |
| `scan: GetNumTradeSkills=N headers=H recipeRows=R parsedIds=P unparsed=U` | The LEGACY recipe-link scan. `recipeRows` = non-header rows enumerated; `parsedIds` = rows that yielded a spell id from `GetTradeSkillRecipeLink`. `parsedIds=0` while `recipeRows>0` means the recipe-link API is non-functional on this client (see below). |
| `api: GetTradeSkillRecipeLink=.. GetTradeSkillItemLink=..` | Whether each link API exists as a function. |
| `row[i] <name> type=.. avail=..` + `recipeLink=..` + `itemLink=..` | Raw per-row data for the first 8 recipe rows. `recipeLink=nil` with a valid `itemLink=|Hitem:...` is the signature of the SoD/Anniversary client quirk. |
| `filter: nameFilter=".."` / `haveMaterials..` / `hasSubClassFilter..` | Active filter signals. A non-empty name filter, an enabled "Have Materials" toggle, or collapsed headers hide rows from the legacy scan. |
| `craftlib: recipes=T matchedLearned=M flaggedUnlearned=F` | Of CraftLib's `T` recipes for this profession, how many the legacy scan matched as learned. (`matchedLearned` reflects the legacy scan only - see `result:` for the real outcome.) |
| `craftlib: sample flagged-unlearned: <name>(id=..)` | A few recipes the legacy scan did not match, with their CraftLib spell id. |
| `craftlib: scannedIdsWithNoCraftLibMatch=N` | Scanned spell ids that match no CraftLib recipe id (high = a CraftLib data/id-mapping gap). |
| `result: GetRecipesWithLearnedStatus -> N/total learned` | **The real resolver's outcome.** This is what the UI uses. `N` should be roughly your known-recipe count; `0/total` means detection is fully broken. |
| `probe: C_TradeSkillUI=.. GetAllRecipeIDs=.. GetRecipeInfo=..` | Whether the modern filter-immune profession API is available (it is absent on Classic Era/Anniversary/TBC). |

**Reading the output:**

- `result:` shows a healthy count and the symptom is gone -> detection is working.
- `parsedIds=0` but `itemLink` lines are valid and `result:` is healthy -> the client
  has the recipe-link quirk (`GetTradeSkillRecipeLink` returns nil); LazyProf falls
  back to mapping the crafted-item id and recipe name, which is the expected path here.
- `result: 0/total` with a non-empty name filter or collapsed headers -> recipes are
  hidden from the scan; clear the search box, turn off "Have Materials", and expand all
  category headers, then re-run.
- `scannedIdsWithNoCraftLibMatch` is high -> the scan reads recipes CraftLib doesn't
  know by that id; likely a CraftLib data issue rather than a LazyProf one.

### `/lp diag forever` - WoW Forever client state

**When to use:** on WoW Forever, the arrow or panels are missing, recipes show as
unlearned/unknown, the wrong profession or skill is detected, or a path stops short.
Open the profession window (recipe list page) first, then run it. On Forever
`/lp diag` lists this command instead of `/lp diag learned`. If a section fails it
prints `SECTION ERROR: <section>: <message>` and the other sections still print.

| Line | Meaning |
|------|---------|
| `diag forever: build=.. interface=.. WOW_PROJECT_ID=.. WOW_PROJECT_CAMELOT=.. family=..` | Client build, interface number and project ids. `family` must be `forever`. |
| `craftlib: version=.. profile=.. ready=..` | Bundled CraftLib version, active profile (expect `FOREVER`) and whether it is ready. |
| `craftlib: professions=N recipes=T [key=n ...]` | Professions CraftLib provides and their recipe counts. |
| `window: IsOpen=.. ProfessionsFrame=.. CraftingPageShown=..` | What the adapter treats as "profession window open". `CraftingPageShown=false` is the profession-book page: guidance is hidden there. |
| `local crafting: linked=.. guild=.. guildMember=.. npc=.. showsOwnList=..` | The checks for whose list the window shows. Anything but `showsOwnList=true` means no path is built. |
| `child: ...` / `base: ...` | `professionID`, `parentProfessionID`, `skillLevel`, `maxSkillLevel`, `skillModifier` of the child and base profession lines. The adapter uses the child line unless its `professionID` is 0. |
| `adapter GetLine: key=.. skill=cur/max` | What LazyProf derived. `key=nil` means no registered profession matched. |
| `craftlib milestones: ...` | The profession's CraftLib milestones; the last one is the skill cap the path aims for. |
| `recipes=N learned=L craftlibMatched=M craftlibRecipes=C` | Recipe ids the client lists, how many are learned, how many of them CraftLib has, and CraftLib's total. `GetAllRecipeIDs returned nil` is reported instead when the API gives nothing. |
| `notInCraftLib=N sample=[...]` | Client recipe ids CraftLib lacks (first 10): a data gap. |
| `notInClient=N sample=[...]` | CraftLib recipe ids the client does not list (first 10): removed or other-profession recipes. |
| `filters: GetShowLearned=.. GetShowUnlearned=.. UnlearnedHiddenByFilter=..` | The list filters. With unlearned hidden the arrow cannot point at an unlearned next recipe. |
| `scrollbox: present visibleFrames=N firstFrameDataKeys=..` | Whether the recipe list ScrollBox was found, how many row frames are live, and the data keys of the first one (`recipeInfo` for a recipe, `categoryInfo` for a header). |
| `path: steps=N complete=.. gaps=G` | The current calculated path: step count, whether it reaches the cap, and the number of gaps (levels no available recipe covers). `path: none` means no path exists. |
| `NOTE: the profession window is closed ...` | Printed first when no profession window is open: the profession, recipe and check lines then describe nothing useful. Open a profession and run it again. |
| `recipes=N learned=L (no open profession to compare with CraftLib)` | Shown instead of the CraftLib counts when no profession is detected. |
| `check: <profession>, N recipes in both the client and CraftLib` | The data check below ran over these recipes (window open only). |
| `check: skipped - ...` | The window shows another player's, a guild or an NPC list, or a profession without recipe data: nothing to check. |
| `check difficulty at skill S (+M): agree=A differ=D sample(id:client/craftlib)=[...]` | For learned recipes: the difficulty the client shows at your skill (`S` includes the profession's skill modifier `M`) against the one CraftLib's thresholds give. `optimal` = orange, `medium` = yellow, `easy` = green, `trivial` = gray; `belowOrange` = you know the recipe but your skill is below CraftLib's orange level, so that level is too high. Differences mean a wrong threshold in the data. |
| `check gray (client maxTrivialLevel): agree=A differ=D noClientValue=N sample(...)` | The skill at which the client says the recipe turns gray against CraftLib's gray level. `noClientValue` counts recipes for which the client gives none. |
| `check reagents: agree=A differ=D errors=E sample(id)=[...]` | The client's reagent list (basic reagents and counts) against CraftLib's. `errors` counts recipes whose reagent list the client could not give. |
| `check product: agree=A differ=D sample(id:client/craftlib)=[...]` | The item the recipe crafts according to the client against CraftLib's item id (recipes without an item, like enchants, are left out). |

If the check lines show differences, paste the whole output: the sampled recipe ids
are what the data needs fixing for.

### `/lp diag prices` - where the prices come from

**When to use:** the path's cost looks wrong, a reagent seems too cheap or too expensive,
the path chose other recipes than you expected, or you are not sure whether your auction
data is current. Run it with a path calculated (open a profession window first). Works on
every client.

**Which price wins:** a vendor price first; then an Auctionator price `seen today`, once you
have been at the auction house since login or /reload (a scan made this session is newer
than the TSM data loaded at login; Auctionator only reports whole days, so "today" alone
could be this morning); then the market sources in `order` (TSM first by default, with its
own fallback values); then the vendor sell estimate. Closing the auction house expires the
5-minute price cache, so the next path reads a scan you just made.

| Line | Meaning |
|------|---------|
| `diag prices: tsm=.. auctionator=.. auctionatorAge=.. vendor=.. order=.. tsmSource=.. sellFallback=.. staleAfterDays=N` | Which price sources are installed, the market source order, the TSM value LazyProf asks for, whether the vendor sell estimate is used, and after how many days an Auctionator price counts as stale. `auctionatorAge=false` means Auctionator cannot tell the age of its prices. |
| `note: ...` | TSM does not tell other addons when its data was synced: check the TSM desktop app for its last sync. |
| `summary: reagents=N tsm=.. auctionator=.. vendor=.. estimate=.. loading=.. noPrice=.. stale=.. oldestAuctionatorDays=..` | How the path's reagents were priced, as the last calculation used them. `estimate` = only the vendor sell value was available; `loading` = no price yet because the item data is still loading; `noPrice` = no auction price and no sell value (or the sell estimate is off), so a scan is needed; `stale` = Auctionator prices `staleAfterDays` or more days old. |
| `route: kept=<name> candidates=N planned in <ms> ms keep margin=<money>` | Which candidate route the planner kept. Under Cheapest it plans up to four and keeps the one you pay least for: `market` (market prices, nothing owned: the route as it was before sale value and stock counted), `sale` (recipes ranked by cost after what the craft sells for), `stock` (as `sale`, with your stock counted against whole runs) and `previous` (the plan in hand: the route kept by the last calculation, carried on from your current skill; planned only while you own a reagent that some usable recipe takes). Of the first three the cheapest wins; `previous` is kept instead unless it is dearer than `market` or another route is clearly cheaper (by more than 5% of what the market route costs with nothing owned), so a plan you bought the reagents for does not change over small differences. `keep margin` is that amount (printed only when a plan in hand was planned). Pinning or resetting a recipe forgets the remembered recipe for that skill range. Fastest plans one route, named `fastest`. |
| `candidate <name>: net=.. spend=.. sale=..` | What that route costs you: `spend` = reagents still to buy with your stock taken off, plus recipes; `sale` = what its crafts sell for; `net` = spend minus sale (`gain` when the crafts sell for more). `(not eligible: ...)` marks a route that covers less of the skill range than the market route, so it cannot be kept. |
| `sale values: mode=.. counted=N ranked=N loading=N` | The "Count what crafts sell for" setting, how many recipes have a sale value, how many of those may be used for ranking (every reagent has a real price) and how many crafted items are still waiting for item data. |
| `<itemId> <name>: <price> <source> \| tsm=.. auctionator=.. vendor=.. sell=..` | One reagent: the price LazyProf uses and where it came from, then what each source says (`n/a` = source not installed, `-` = no value; `(DBMarket)` is the TSM value that answered, `(2d)` the Auctionator age in days). |
| `... DISAGREE` | TSM and Auctionator differ by more than half for this item: one of them is likely out of date. |
| `... STALE` | The price used is an Auctionator price at least `staleAfterDays` old: rescan the auction house. |

What to do: `loading` items fill in by themselves as the client loads item data (`/reload`
if they stay); `noPrice`, `stale` or `DISAGREE` items need a fresh auction scan (Auctionator)
or a desktop-app sync (TSM). The arrow tooltip shows the same summary and warnings, so does
the price line of the window (under More options; hover it), the receipt shows the first
warning in orange, and the tooltip of a reagent row shows that item's price and source.

### `/lp diag merchant` - what a merchant sells, and what would be bought

**When to use:** the panel beside the merchant window does not appear, lists the wrong
reagents or amounts, "Buy all" stops early, or a vendor reagent is not marked "vendor".
Run it **with the merchant window open**. Works on every client; the raw lines differ per
client family.

| Line | Meaning |
|------|---------|
| `diag merchant: build=.. interface=.. family=..` | Client build and which adapter is active. |
| `NOTE: no merchant window is open ...` | The item lines below will be empty: open a merchant and run it again. |
| `merchant: open=.. frameShown=.. numItems=N money=.. freeSlots=N` | Whether LazyProf saw the merchant open, how many items it lists, the character's copper and the free general-purpose bag slots (special bags are not counted). |
| `raw[i] id=.. name=.. price=.. stackCount=.. numAvailable=.. isPurchasable=.. hasExtendedCost=.. currencyID=.. maxStack=..` | What the client reports for list index `i` (first 12). `numAvailable` is the stock: above zero is a limited supply, zero is sold out, **below zero is treated as unlimited**. `stackCount` is how many one purchase unit holds; `maxStack` the most one purchase may ask for. |
| `adapter items=N` / `item[i] id=.. price=.. bundle=.. stock=.. maxStack=.. extendedCost=.. purchasable=..` | The same items as LazyProf uses them. |
| `remembered vendor prices: N` | How many vendor prices LazyProf has seen at merchants so far (account-wide). Only reagents sold for gold without a stock limit are remembered. |
| `purchases: onePerClick=.. running=..` | `onePerClick=true` means a purchase made after the click never arrived, so this session buys one stack per click ("click again to continue"). |
| `shopping list: <profession>, rows=N toBuyHere=N skipped=N total=..` | The list the panel works from (the whole shopping list of the path last shown in the LazyProf window this session) and what this merchant covers. `none yet this session` = open a profession or the LazyProf window first. |
| `buy: Nx <name> (id ..) for ..` | One reagent "Buy all" would buy. |
| `skip: <name> (id ..): <reason>` | A reagent this merchant sells that is not bought automatically: `limited stock`, `sold out`, `not sold for gold`, `not available to you`. |

Reading it: an expected reagent with no `buy:` or `skip:` line is either not sold here (no
`raw` line with its id), already owned (the Shopping tab shows Buy "-"), crafted instead of
bought (its row on the Shopping tab shows nothing to buy), or needed only beyond the "Level
to" target (the list ends where the path ends). A wrong amount is the Shopping tab's Buy
figure rounded up to whole bundles.

### `/lp diag trainer` - what a trainer lists, and what is remembered

**When to use:** an opened row of the Path tab (for a recipe still to learn) or the tooltip
of a "Train the next rank" row does not list a trainer you have visited, or a recipe's
fee is missing or wrong. Run it **with the trainer's window open**. Trainers are recorded on
WoW Forever only; on other clients the dump says so.

| Line | Meaning |
|------|---------|
| `trainer: open=.. IsTradeskillTrainer=.. services=N` | Whether a trainer window is open, whether the client calls it a profession trainer, and how many services it lists (the trainer window's own filter applies). |
| `npc: nameSecret=.. name=..` | The trainer's name. `nameSecret=true` means the client would not give the name out; such a trainer is not remembered (its fees are). |
| `trainer rank values: rank=.. maxRank=.. modifier=..` | Your rank and cap in the trainer's profession, as the client reports them. |
| `raw[i] name=.. type=.. reqLevel=.. subText=.. category=.. cost=.. isProfession=.. skillReq=.. skillLine=..` | What the client reports for service `i` (first 10). `type` is `available`, `unavailable` or `used`. |
| `adapter info: name=.. npcId=.. zone=.. subZone=.. mapId=.. x=.. y=.. faction=..` | The trainer as LazyProf would remember it. `x` / `y` are **your** position on the map (0-1), not the NPC's. |
| `remembered: professions=N trainers=N fees=N` | What is remembered for this client so far. |
| `this trainer: profession=.. services=N` | The profession LazyProf matched this trainer to: the one most of whose recipe names appear in its list. `nil` means no listed service is a recipe LazyProf knows (a class trainer, a filter hiding everything, or a client language whose recipe names differ from the recipe data). |
| `known <profession> trainer: Name - Zone (x, y) mapId=.. faction=.. recipesListed=N` | Each remembered trainer of that profession. A recipe still to learn names a trainer only when the trainer listed that recipe; a "Train the next rank" row names every remembered trainer of the profession. Only trainers visited by a character of your faction are shown. |

### `/lp diag stock` - remembered bags and banks, and what the bank reads as

**When to use:** reagents in your bank or on an alt are not counted (or are counted although
they are gone), a character is missing from "From alts", or the bank's contents look wrong.
Run it anywhere for what is remembered; run it **with the bank window open** for the bank
lines. Works on every client; the bank is read on WoW Forever only, and on the other clients
the dump says so.

| Line | Meaning |
|------|---------|
| `diag stock: build=.. interface=.. family=..` | Client build and which adapter is active. |
| `bag[i] slots=N used=N` | Each carried bag as the client reports it. On WoW Forever bags 0 to 5 are read; 5 is the reagent bag. |
| `adapter bags: items=N soulbound=N backpackSlots=N` | The bags as LazyProf reads them: distinct items, how many of those have a soulbound part, and the backpack's slot count. `backpackSlots=0` means the bags could not be read just now; such a read is never remembered. |
| `bank: open=.. usesPlayerBags=..` | Whether LazyProf saw the bank window open (the bank is only ever read while it is), and whether the client shows the bank's tabs as one page of bag slots. |
| `bank character: canView=.. lockedReason=.. tabs=N [id:slots/used ...]` | The character bank as the client reports it: whether it may be viewed, the lock reason (`nil` = not locked), and each purchased tab with its container id, slot count and used slots. The same line follows for `bank account` (the account-wide bank). |
| `adapter bank character: items=N soulbound=N` / `... not readable now` | What LazyProf reads from that bank. `not readable now` = the window is closed, the bank may not be viewed, it is locked, it has no tabs or none reports a slot. Then nothing is saved and what was remembered stays. `items=0` in the first half second after the window opened is not saved either (the items may not be there yet); it is read again when that time is over. |
| `api: C_Container=.. GetContainerItemInfo=.. GetServerTime=..` / `bank: not recorded on this client` | Classic clients only, in place of the bank lines: which container call is used for the bags, and that the bank is not read there. |
| `world: region=.. rp=.. pvp=.. hardcore=.. guidSecret=.. serverTime=..` | What the character's world is made of on WoW Forever (region and ruleset - there are no realms), whether the client withheld the character's id, and the server clock the ages are counted from. |
| `source: ...` | `LazyProf's own memory (no inventory addon)`, or `Syndicator (...)`: then the stock comes from Syndicator and the memory is neither used nor updated. |
| `settings: bank=.. alts=.. guildBank=.. selfFound=..` | The stock options. With `selfFound=true` nothing that belongs to other characters is counted. |
| `last error: <message> (in: <where>; N so far this session ...)` | Only when something went wrong while the memory was started, read or updated: the last error and how many there were. LazyProf carries on - while it lasts only the bags are counted - and the first one is also in the debug log. Paste this line with a bug report. |
| `identity: guid=.. name=.. world=.. faction=..` | Who LazyProf takes the character for. Without a `guid` nothing is remembered; without a `world` or a `faction` no other character counts as an alt. |
| `waiting: bagSave=.. bankRead=.. bankOpen=..` | Whether a save of the bags (two seconds after a bag change) or a read of the bank (the frame after a change while it is open, or the second look half a second after opening) is still to come. |
| `memory: format=1 characters=N accountBanks=N ...` | How much is remembered, account-wide. Any other `format` was written by a version this one does not understand: it is left alone and nothing is counted from it. |
| `memory: unreadable=N ...` | Only when the saved file holds entries that are not what LazyProf writes (edited by hand, or cut off by a crash). They are skipped; "Forget remembered characters" removes them. |
| `character: <name> [this character / alt / not counted] world=.. faction=.. bags=N items (<age>) bank=N items (<age>) guid=..` | One line per remembered character. `alt` = counted for the character you are on (same world and faction); `not counted` = another world or faction, or an older record under a name another character now has. `bank=never seen` = the bank was never open on that character. |
| `account bank: world=.. items=N (<age>)` | The account-wide bank remembered for a world. It counts as bank stock for every character of that world. |

Reading it: an alt with `not counted` cannot supply stock (check `world` and `faction`). An
age that never becomes `less than an hour ago` on the character you play means its bags
or bank are not being saved: look at `backpackSlots`, `identity` and, at the bank, the `canView` /
`lockedReason` / `tabs` values. A character you deleted stays listed until it has not been
seen for 180 days, or until "Forget remembered characters" (Settings, Display, "Your
stock") is used.

### Adding a new diagnostic

`/lp diag` is meant to grow. To add `/lp diag <topic>`: add an `elseif cmd == "diag <topic>"`
branch in `LazyProf:SlashCommand` (Core/Init.lua), write a `RunXxxDiagnostic` that
collects lines into a table, and finish with `self:ShowDiagnosticOutput(table.concat(out, "\n"))`
- `ShowDiagnosticOutput` is the shared copyable-popup primitive. Keep diagnostics
read-only (no `Show`/`Hide`/`SetAttribute`), so they are safe to run any time, including
in combat-adjacent situations. Document the new topic's output lines in this section.
Lines that read the profession window or other client APIs belong in the client
adapter (`Core/Client/Classic.lua` for Classic clients, `Core/Client/Forever.lua` for
WoW Forever): `/lp diag learned` gets its lines from `LazyProf.Client:RunDiagnostic(lines)`,
`/lp diag merchant` from `Client:RunMerchantDiagnostic(lines)`, `/lp diag trainer` from
`Client:RunTrainerDiagnostic(lines)` and `/lp diag stock` from
`Client:RunStockDiagnostic(lines)`, so each client family reports what its own API sees.

---

## Capturing Debug Logs

### Step-by-Step

1. **Enable debug mode:**
   - Open `/lp` settings, Debug page
   - Check "Enable debug messages"
   - Enable specific categories you want to capture

2. **Reproduce the issue** - do whatever triggers the problem

3. **Open log window:**
   ```
   /lp log
   ```

4. **Filter by category** (optional) - use the dropdown to show only relevant messages:
   - `Pathfinder Scoring` - recipe scoring loops, candidate comparisons (verbose)
   - `Pathfinder Core` - path calculation start/end, summaries
   - `UI Updates` - window/panel state, visibility changes
   - `Professions` - profession registration, detection
   - `Pricing` - price provider selection, lookups
   - `Arrow` - arrow positioning, strategy changes

5. **Copy logs:**
   - Click **"Copy Filtered"** - copies only messages matching current filter
   - Click **"Copy All"** - copies everything

6. **Include in bug report** - share the copied logs

### What to Include When Reporting Issues

```
1. LazyProf version (shown on /reload or in addon list)
2. What you expected to happen
3. What actually happened
4. Debug logs (filtered to relevant category)
5. Any error messages from BugGrabber
```

---

## Checking for Lua Errors

LazyProf uses BugGrabber to capture Lua errors. Errors don't always show in chat.

### In-Game

If you have BugSack installed:
```
/bugsack
```

### From SavedVariables File

```bash
cat "/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/!BugGrabber.lua"
```

Or search for LazyProf-specific errors:
```bash
grep -A 5 "LazyProf" "/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/!BugGrabber.lua"
```

---

## Extracting Debug Data

### SavedVariables (Database State)

View current LazyProf database:
```bash
cat "/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/LazyProf.lua"
```

### CraftLib Data Check

Verify CraftLib is loaded and has profession data:
```
/run print(CraftLib and "CraftLib loaded" or "CraftLib NOT loaded")
/run local p = CraftLib:GetProfessions(); for k in pairs(p) do print(k) end
```

---

## Common Issues

### Arrow Not Showing

**Symptoms:** Open profession window but no arrow appears

**Check:**
1. Is debug showing arrow messages?
   - Enable debug mode, enable "Arrow" category
   - Open profession window
   - Check `/lp log` for `[Arrow]` messages

2. Is a valid path calculated?
   ```
   /lp log
   ```
   Look for `[Pathfinder Core]` messages showing path steps

3. Is the profession supported?
   - LazyProf requires CraftLib to have data for the profession
   - Check CraftLib version matches LazyProf requirements

4. Is the next recipe still to learn?
   - When the profession window hides unlearned recipes, the arrow has no row to point at
     until you learn it; the recipe's opened row on the Path tab says so.

### LazyProf Window Not Showing

**Symptoms:** Open a profession window but no LazyProf window appears beside it

**Check:**
1. Is "Open with the profession window" on? (Settings, Display.) When off, the arrow still
   works and the window opens only from the minimap button, the addon compartment or
   `/lp browse`.
2. Did you close it? A closed window stays closed until the profession window is opened
   again.
3. Is it off screen or tiny? `/lp resetpanels` puts it back beside the profession window at
   its default size.
4. Are you in combat? The window hides in combat and returns afterwards.
5. Is a planning view open? Planning opened from the minimap button stays until you close it
   (close button or Escape); the docked view comes back the next time the profession window
   is opened.

### Empty Leveling Path

**Symptoms:** The window shows no steps, only a gap, or a "No recipe data" line

**Check:**
1. Is CraftLib loaded?
   ```
   /run print(CraftLib and "CraftLib: " .. (CraftLib.version or "?") or "NOT LOADED")
   ```

2. Does CraftLib have data for this profession?
   ```
   /run local r = CraftLib:GetRecipes("engineering"); print(r and #r .. " recipes" or "no data")
   ```
   Replace "engineering" with your profession key.

3. Check pathfinder debug:
   - Enable "Pathfinder Core" and "Pathfinder Scoring" categories
   - Open profession window
   - Review `/lp log` for why no candidates were found

### Wrong Recipe Recommended

**Symptoms:** Arrow points to a recipe that seems suboptimal

**Check:**
1. Enable "Pathfinder Scoring" debug category
2. Open profession window to trigger calculation
3. Review `/lp log` for scoring details:
   - Look for `=== Scoring candidates at skill X ===`
   - Compare costs and expected skillups
   - Check if recipe acquisition cost is a factor

4. Verify pricing:
   - `/lp diag prices` lists every reagent price of the path and where it came from
   - A reagent with no auction price is estimated from its vendor sell value (the
     "Estimate from vendor sell value when no AH price" option, on by default)

5. Under Cheapest the recipe is not chosen by reagent cost alone: what the craft sells
   for and what you own count too. See "My Path Changed Although Nothing Looks Different".

### My Path Changed Although Nothing Looks Different

**Symptoms:** The Path tab lists other recipes than before, with the same skill and target

Under the Cheapest strategy four things decide the route besides the reagent prices:

1. **What the crafts sell for.** Recipes whose reagents all have a real price (a vendor's
   or an auction addon's) are ranked by what a craft costs after what it sells for. The
   "Selling" mode (More options; "Count what crafts sell for" in the settings), a changed
   auction price of a crafted item, or sale values that arrived after the first calculation
   can move the route.
2. **Your stock.** Reagents you own count when the route is chosen, against whole runs of
   a recipe: your bags, your bank and your alts (with Syndicator also mail, your auctions
   and, if it is turned on, the guild bank). A bag change alone never plans again; the route is planned
   again when the profession window opens, your skill changes, you change the target, the
   strategy, a recipe or a setting, item data arrives, you close the auction house, or a
   merchant shows a vendor price LazyProf had not seen (with the profession window open).
3. **The candidate routes.** Each calculation plans up to four routes and keeps the one you
   pay least for: `market` (market prices, nothing owned), `sale` (ranked with sale value),
   `stock` (as `sale`, with your stock) and `previous` (the plan you already follow).
4. **The remembered route.** The route kept last is remembered per character and
   profession and carried on from your current skill, so a plan you bought the reagents
   for does not change over small differences. It is given up when it costs more than the
   `market` route, or when another route is cheaper by more than 5% of what the `market`
   route costs with nothing owned. It is only planned while you own a reagent that some
   usable recipe takes. "Use" and "Reset" on a recipe forget what was remembered for that
   skill range. Fastest and "Plan from skill 1" neither use nor change it.

**Check:** run `/lp diag prices` with the profession window open. The `route: kept=...`
line names the route that was kept, and each `candidate ...` line says what that route would
cost you (`spend`, `sale`, `net`). `sale values:` says how many recipes have a sale value
and how many are still waiting for item data. Paste the whole output into a bug report if
the kept route is not the one with the lowest `net` (within the `keep margin` for
`previous`; a candidate marked `not eligible` cannot be kept).

### "Back from selling" Says "still loading"

**Symptoms:** The receipt's "Back from selling" line ends with "still loading", or shows
`0c` at first

What a crafted item sells for to a vendor comes from the game's item data. Until the client
has delivered it for every crafted item the path could use, the line shows the amount known
so far and its note ends with "still loading". Nothing needs to be done:

1. When the data arrives, the path is planned again by itself and the note goes.
2. An item whose data does not arrive stops counting as loading 20 seconds after it was
   first asked for, and counts as selling for nothing unless its data arrives after all;
   the window is redrawn once for that.
3. `/lp diag prices` shows the count in `sale values: ... loading=N`.

With "Selling" set to "Do not count" the line is not shown at all.

### Where Did the Path Bar, Range, Prev / Next and the Guide and Steps Tabs Go

**Symptoms:** After an update the window has two tabs and no coloured bar

| Before | Now |
|--------|-----|
| Guide and Steps tabs | The **Path** tab: one row per recipe. Click a row to open it in place; the opened row shows what the Guide card showed (reagents, how to learn the recipe, the other recipes with "Use"). The row you are on is marked with `>`, highlighted and open until you close it. |
| The coloured path bar | No bar. The Path list shows every run with its skill range in skill order, a "Train the next rank before N" row at each rank still to train, and gaps as red rows. |
| Range dropdown | **"Level to"**: set the target to the end of a bracket and the path, the receipt and the shopping list cover only that part. |
| The footer with its totals | The **receipt** above the tabs: "You spend", "Back from selling", "Net cost". |
| Prev / Current step / Next | Click any row of the Path list to open it. |
| "Target" box | "Level to", with a slider under the number box. A typed number counts on Enter. |
| "With margin" | "Spare crafts", under More options. |
| Cheapest / Fastest, the price line, the recipe search, "Hide what I have", "I craft it / I buy it", "Plan from skill 1" | Under **More options** (the button on the right of the status line; it stays as you left it). |
| "Use this" / "Pinned" | "Use" / "Your choice" (with "Reset") in the opened row. |

A window that was last on the Guide or Steps tab opens on Path.

### The Amounts Show Copper Now

**Symptoms:** Costs read "1g 2s 3c" where they used to read "1g 2s"

Every amount that is part of a sum is written to the copper, so that what the window shows
adds up: the receipt, the cost columns of both tabs, "Learn first" fees, the recipe rows and
the totals, and the merchant panel. "You spend" equals "Reagents to buy" plus "Recipes" on
the Shopping tab, and the merchant panel's rows add up to "Buy all". The cost columns and
the merchant panel's rows used to show only the two largest units, and then they did not.
Only comparisons stay short: the difference shown for an alternative ("+14s") and the cost
per craft in an opened row (More options).

### Bank or Alt Stock Is Not Counted

**Symptoms:** Reagents in your bank or on an alt are still on the list to buy

"Include bank items" and "Include alt characters" are on by default (Settings, Display,
"Your stock"); "Include guild bank" is off by default. Stock that is counted but not in
your bags is listed under "Collect first" on the Shopping tab.

**With Syndicator** stock outside your bags (bank, mail, your auctions, alts, guild bank) is
read from it; check in Syndicator / Baganator that it knows the character.

**Without Syndicator** LazyProf counts what it has seen itself:

1. A character's bags are remembered while you play it (two seconds after a bag change and
   at logout). An alt you have not logged in since this was added is not known yet.
2. A bank is remembered only while its window is open, on WoW Forever. Open the bank once
   on every character whose bank should count, and again when the bank changed while
   LazyProf was not running (the addon switched off, or another computer). On other
   clients the bank is not remembered and "Include bank items" is greyed out.
3. Alts are the remembered characters of the **same world** (region and ruleset on WoW
   Forever, the realm elsewhere) **and faction**. Their soulbound items are left out.
4. An alt's bank needs both options on.
5. Mail, auctions and the guild bank are never known without Syndicator.
6. In Self-Found mode (Settings, General) nothing from other characters is counted.

How old the remembered stock is shows in the tooltips under "Collect first" on the
Shopping tab: a "From bank" row says "Bank as seen 2 days ago" (and "Account bank as seen
..." when an account-wide bank is remembered), a "From alts" row names each character with
the age of the bags or the bank its items are in. Ages are elapsed time on the server
clock: "less than an hour ago", then whole hours up to 23, then whole days of 24 hours.
`/lp diag stock` lists every remembered character, whether it counts for the character you
are on, and how old its bags and bank are.

### Stock of a Character That Is Gone Is Still Counted

**Symptoms:** "From alts" names a character you deleted, or reagents you no longer have

Without Syndicator the stock of other characters is a memory of when they were last
played (the tooltip of the "From alts" row says how long ago that was). A character is
forgotten when it has not been seen for 180 days. To forget
everything at once use "Forget remembered characters" (Settings, Display, "Your stock"): the
character you are on is remembered again right away, the others the next time you play
them.

### Nothing Left / Target Reached

**Symptoms:** The window says "Nothing left" or "Target reached" instead of a path

The path runs to the **"Level to"** target. "Target reached" means your skill is at or past
it: drag the slider to the right, or type a higher number and press Enter. "Nothing left"
means the skill is at the profession's last cap.

### Alternatives Not Showing

**Symptoms:** A row of the Path tab has no "or: ..." line under it, or an opened row has no
"Other recipes" section

**Check:**
1. The "or:" line is only an offer of the closest alternative. It appears when that
   alternative costs you less than the run, or at most 10% more. It is not shown on an
   opened row (the same recipe is listed inside), on a recipe you chose yourself, on a
   finished run, on a run with a reagent that has no price, or on a run that pays for
   itself.

2. Does the run have other candidates at all? Open the row: "Other recipes for N-M" lists
   the best three and "Show all N" the rest.
   - Enable "Pathfinder Scoring" debug category
   - Look for `=== Scoring candidates at skill X ===`
   - If only 1 recipe scored, no alternatives exist at that skill level

3. Are all other recipes gray?
   - Gray recipes are filtered from candidates

4. An alternative that says "only up to N" or "no skill-ups here" cannot cover the whole
   run, so no difference is shown for it.

### "Use" Did Not Change the Recipe

**Symptoms:** Click "Use" on an alternative but the row keeps its recipe, or the opened
row has no "Your choice" line

**Check:**
1. Is the chosen recipe still usable in that skill range?
   - A recipe that has gone gray there, or that cannot be learned yet at that skill, cannot
     be used; the planner's own choice stays for those points.

2. Check pathfinder debug:
   - Enable "Pathfinder Scoring" category
   - Look for `>>> PINNED:` messages after the click
   - If missing, the chosen recipe did not match any candidate at that skill

3. A choice covers a skill range and is saved per character and profession. It is dropped
   by itself once your skill has passed its range; "Reset" in the opened row removes it at
   once.

### Merchant Panel Not Showing

**Symptoms:** At a vendor that sells a reagent you need, no LazyProf panel appears

**Check:**
1. Was a path shown this play session? The panel works from the shopping list of the path
   the LazyProf window showed last; after a login or /reload, open the profession (or the
   LazyProf window) once.
2. Is the reagent still to buy? The Shopping tab must show a Buy number for it. The list
   covers the whole path up to the "Level to" target; reagents you craft yourself are not
   bought.
3. Run `/lp diag merchant` with the merchant open (see above): it shows what the merchant
   sells as LazyProf reads it and why a reagent is skipped.

### Buy All Stops Early

**Symptoms:** "Buy all" buys one stack and stops, or reports a reason

The report line says why: `the merchant window closed`, `not enough money`, `no free bag
slot` (special-purpose bags are not counted), or `The game allows one purchase per click
here` (click again for each stack). `the purchase did not go through` means nothing arrived
for the first purchase; `/lp diag merchant` shows the stock, price and stack values involved.

### Trainers Not Listed for a Recipe or a Rank

**Symptoms:** The opened row of a recipe still to learn names no trainer, or the tooltip of
a "Train the next rank" row lists none

No trainer or vendor names are shipped: the window lists only trainers **you have visited**
with LazyProf installed, on WoW Forever. A recipe lists a trainer only if that trainer's
list contained the recipe (the trainer window's filter must show it). Run `/lp diag trainer`
at the trainer to see what was matched.

### Settings Not Saving

**Symptoms:** Settings reset after `/reload`

**Check:**
1. Is SavedVariables being written?
   ```bash
   ls -la "/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/LazyProf.lua"
   ```

2. Check for write errors in BugGrabber

3. Verify settings structure:
   ```bash
   grep -A 10 "profile" "/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/LazyProf.lua"
   ```

### Minimap Button Missing

**Symptoms:** No LazyProf icon on minimap

On WoW Forever there is no separate minimap button: LazyProf is listed in the addon
compartment, the small button with a number (the count of addons in it) next to the
calendar at the top of the minimap. Click it and pick LazyProf (left click: profession
browser, right click: settings). On the other clients:

**Check:**
1. Is it hidden in settings?
   ```
   /lp
   ```
   Look for "Show minimap button" option

2. Is LibDBIcon loaded?
   ```
   /run print(LibStub and LibStub("LibDBIcon-1.0", true) and "LibDBIcon loaded" or "LibDBIcon NOT loaded")
   ```

---

## Sharing Debug Information

When reporting an issue, provide:

```markdown
## Issue
<What's broken>

## Expected
<What should happen>

## Actual
<What happens instead>

## Version
LazyProf: <version from addon list or /reload message>
CraftLib: <version>
WoW Client: <Retail/Classic/TBC/Anniversary>

## Debug Logs
```
<paste from /lp log>
```

## Errors (if any)
```
<paste from BugGrabber>
```

## Settings (if relevant)
- Strategy: Cheapest/Fastest
- Level to: <target>, Spare crafts: yes/no
- Selling: Vendor/Auction house/Do not count
- Include bank/alts/guild bank: yes/no, Syndicator installed: yes/no
- Price source: TSM/Auctionator/Vendor
```

---

## Reset to Defaults

If all else fails, reset LazyProf's database:

1. Exit WoW completely
2. Delete or rename SavedVariables:
   ```bash
   mv "/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/LazyProf.lua" \
      "/Volumes/kaldown/battlenet/world of warcraft/_anniversary_/WTF/Account/KALDOWN/SavedVariables/LazyProf.lua.backup"
   ```
3. Restart WoW - fresh database will be created
