# Testing Guide

## In-Game Testing

LazyProf is tested manually in-game.

### Basic Verification

After making changes, run `/reload` and verify:

1. Open any profession window (Cooking, First Aid, etc.)
2. The LazyProf window should appear beside it, on the Guide tab, with Steps and Shopping tabs below
3. Arrow should point to recommended recipe

The pure logic (path, stages, shopping rows, purchase queue, view contents) and the frames
(against a fake UI) also run headlessly: `bash scripts/run_tests.sh` must pass before every commit.

### Testing Commands

```
/lp          - Show help/options
/lazyprof    - Same as /lp
```

### Testing Path Calculation

1. Open profession at various skill levels
2. Verify the Steps tab shows the correct path and the Guide tab its current step
3. Check that costs are reasonable (not 0, not astronomical)
4. Verify the Shopping tab matches what the steps need

### Testing Pricing Providers

**With TSM installed:**
- Prices should use TSM market values
- Check items with known prices

**With Auctionator only:**
- Disable TSM, enable Auctionator
- Prices should use Auctionator scan data

**Standalone (no pricing addons):**
- Disable both TSM and Auctionator
- Should fall back to vendor prices
- Warning may appear about limited pricing

### Testing Inventory Integration

1. Put materials in bags
2. Open profession
3. Shopping list should show "From Bags" for owned materials

**With Syndicator:**
1. Enable "Include bank items" in settings
2. Put materials in bank
3. Shopping list should show "From Bank" for bank materials

**Extended inventory sources (all require Syndicator):**
- Mail items on current character always scanned - verify "Check Mail" section appears
- Active AH listings always scanned - verify "Cancel from AH" section with orange styling
- Enable "Include guild bank" - verify "From Guild Bank" section appears
- Enable "Include alt characters" - verify "From Alts" section with character names

### Testing Bracket Filter

1. Open profession with a calculated path spanning multiple brackets
2. Use the Range dropdown in the window's header (1-75, 75-150, etc.)
3. Verify the Steps tab shows only steps of the selected range
4. Verify the Shopping tab shows only materials for that range
5. Select "Full path" to restore the complete view

### Testing Alternative Recipes & Pinning

1. Open profession with multiple recipe choices at same skill level
2. On the Guide tab, verify the step's card lists "Alternatives" under its reagents: the best three, then "Show all N"
3. Hover an alternative: the tooltip shows materials and, for unlearned recipes (`[!]`), the source
4. Click "Use this" - verify the path is planned again at once and the step shows "Pinned" with a "Reset" button
5. /reload - verify the pin is still there
6. Click "Reset" - verify the planner's own recipe is back
9. Test unpin by clicking pinned recipe again
10. Test `/reload` clears all pins

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
- No pricing addon available
- Check TSM/Auctionator are loaded

**UI not appearing**
- Check for Lua errors in BugSack
- Verify both addons enabled

## Test Checklist for PRs

- [ ] Opens without errors on each supported profession
- [ ] Guide, Steps and Shopping tabs display correctly
- [ ] Shopping list is accurate
- [ ] Works with TSM pricing
- [ ] Works with Auctionator pricing
- [ ] Works standalone (vendor prices)
- [ ] Existing features still work
