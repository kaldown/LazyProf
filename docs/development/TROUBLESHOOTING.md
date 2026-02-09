# Troubleshooting Guide

This guide helps you diagnose issues and capture information for bug reports.

---

## Quick Diagnostic Commands

Run these in-game to check addon health:

```
/lp                    -- Open settings panel
/lp browse             -- Open profession browser
/lp log                -- Open debug log window
/lp reset              -- Reset database to defaults
```

Enable debug mode in LazyProf settings to see detailed logging.

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

### Empty Leveling Path

**Symptoms:** Milestone panel shows no steps or "No path found"

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

### Alternatives Not Showing

**Symptoms:** Expand step but no "Alternatives" section appears

**Check:**
1. Does the step have multiple candidates?
   - Enable "Pathfinder Scoring" debug category
   - Look for `=== Scoring candidates at skill X ===`
   - If only 1 recipe scored, no alternatives exist at that skill level

2. Are all other recipes gray?
   - Gray recipes are filtered from candidates

### Pins Not Working After Recalculate

**Symptoms:** Click recalculate but pinned recipe not used

**Check:**
1. Is the pinned recipe still valid at that skill level?
   - If recipe went gray or lacks price data, pin is silently ignored

2. Check pathfinder debug:
   - Enable "Pathfinder Scoring" category
   - Look for `>>> PINNED:` messages after recalculate
   - If missing, the pin didn't match any candidate

3. Verify pin state:
   ```
   /run for k,v in pairs(LazyProf.Pathfinder.pinnedRecipes) do print("Skill "..k..": "..v) end
   ```

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
- Calculate from current skill: yes/no
- Use owned materials as free: yes/no
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
