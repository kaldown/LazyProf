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
/lp diag prices        -- List every reagent price of the path and where it came from (copyable window)
/lp diag merchant      -- At a merchant: what it sells as LazyProf reads it, and what would be bought (copyable window)
/lp diag trainer       -- At a profession trainer: what it lists as LazyProf reads it, and what is remembered (copyable window)
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

**When to use:** recipes you have already learned are shown as "[!] Unlearned" in
the LazyProf window / alternatives / arrow tooltip, or the wrong recipes are
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
or you are not sure whether your auction data is current. Run it with a path calculated
(open a profession window first). Works on every client.

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
or a desktop-app sync (TSM). The arrow tooltip shows the same summary and warnings, and the
shopping list tooltip shows each item's price and source.

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
| `shopping list: <profession range>, rows=N toBuyHere=N skipped=N total=..` | The list the panel works from (the path last shown in the LazyProf window this session) and what this merchant covers. `none yet this session` = open a profession or the LazyProf window first. |
| `buy: Nx <name> (id ..) for ..` | One reagent "Buy all" would buy. |
| `skip: <name> (id ..): <reason>` | A reagent this merchant sells that is not bought automatically: `limited stock`, `sold out`, `not sold for gold`, `not available to you`. |

Reading it: an expected reagent with no `buy:` or `skip:` line is either not sold here (no
`raw` line with its id), already owned (the Shopping tab shows Buy "-"), crafted instead of
bought ("I craft it"), or outside the range chosen in the window. A wrong amount is the
Shopping tab's Buy figure rounded up to whole bundles.

### `/lp diag trainer` - what a trainer lists, and what is remembered

**When to use:** learn or rank steps do not list a trainer you have visited, or a recipe's
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
| `known <profession> trainer: Name - Zone (x, y) mapId=.. faction=.. recipesListed=N` | Each remembered trainer of that profession. A learn step names a trainer only when the trainer listed that recipe; a rank step names every remembered trainer of the profession. Only trainers visited by a character of your faction are shown. |

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
`/lp diag merchant` from `Client:RunMerchantDiagnostic(lines)` and `/lp diag trainer` from
`Client:RunTrainerDiagnostic(lines)`, so each client family reports what its own API sees.

---

## Capturing Debug Logs

### Step-by-Step

1. **Enable debug mode:**
   - Open `/lp` settings
   - Check "Enable Debug Mode"
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
   - Check which price provider is active in settings
   - Items with no AH data use vendor prices (may be 0)

### Nothing Left / Target Reached

**Symptoms:** The window says "Nothing left" or "Target reached" instead of a path

The path runs to the number in the **Target** box. "Target reached" means your skill is at
or past it: type a higher target. "Nothing left" means the skill is at the profession's last
cap.

### Alternatives Not Showing

**Symptoms:** The step's card on the Guide tab has no "Alternatives" section

**Check:**
1. Does the step have multiple candidates?
   - Enable "Pathfinder Scoring" debug category
   - Look for `=== Scoring candidates at skill X ===`
   - If only 1 recipe scored, no alternatives exist at that skill level

2. Are all other recipes gray?
   - Gray recipes are filtered from candidates

### "Use this" Did Not Change the Step

**Symptoms:** Click "Use this" on an alternative but the step keeps its recipe, or the
"Pinned" line is missing

**Check:**
1. Is the chosen recipe still usable in that skill range?
   - A recipe that has gone gray there, or that cannot be learned yet at that skill, cannot
     be used; the planner's own choice stays for those points.

2. Check pathfinder debug:
   - Enable "Pathfinder Scoring" category
   - Look for `>>> PINNED:` messages after the click
   - If missing, the pin did not match any candidate at that skill

3. Pins cover a skill range and are saved per character and profession. A pin is dropped
   by itself once your skill has passed its range; "Reset" on the pinned step removes it at
   once.

### Merchant Panel Not Showing

**Symptoms:** At a vendor that sells a reagent you need, no LazyProf panel appears

**Check:**
1. Was a path shown this play session? The panel works from the shopping list of the path
   the LazyProf window showed last; after a login or /reload, open the profession (or the
   LazyProf window) once.
2. Is the reagent in the chosen range and still to buy? The Shopping tab must show a Buy
   number for it; reagents you chose to craft are not bought.
3. Run `/lp diag merchant` with the merchant open (see above): it shows what the merchant
   sells as LazyProf reads it and why a reagent is skipped.

### Buy All Stops Early

**Symptoms:** "Buy all" buys one stack and stops, or reports a reason

The report line says why: `the merchant window closed`, `not enough money`, `no free bag
slot` (special-purpose bags are not counted), or `The game allows one purchase per click
here` (click again for each stack). `the purchase did not go through` means nothing arrived
for the first purchase; `/lp diag merchant` shows the stock, price and stack values involved.

### Trainers Not Listed on a Learn or Rank Step

**Symptoms:** A learn or rank step names no trainer

No trainer or vendor names are shipped: steps list only trainers **you have visited** with
LazyProf installed, on WoW Forever. A learn step lists a trainer only if that trainer's list
contained the recipe (the trainer window's filter must show it). Run `/lp diag trainer` at
the trainer to see what was matched.

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
   Look for "Show Minimap Button" option

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
- Calculate from current skill: yes/no
- Include bank/alts/guild bank: yes/no
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
