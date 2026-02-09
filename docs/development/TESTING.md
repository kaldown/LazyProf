# Testing Guide

## In-Game Testing

LazyProf is tested manually in-game.

### Basic Verification

After making changes, run `/reload` and verify:

1. Open any profession window (Cooking, First Aid, etc.)
2. LazyProf panels should appear:
   - Milestone Breakdown panel
   - Missing Materials panel (shopping list)
3. Arrow should point to recommended recipe

### Testing Commands

```
/lp          - Show help/options
/lazyprof    - Same as /lp
```

### Testing Path Calculation

1. Open profession at various skill levels
2. Verify milestones show correct path
3. Check that costs are reasonable (not 0, not astronomical)
4. Verify shopping list matches milestone requirements

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
2. Use bracket filter dropdown on milestone panel (1-75, 75-150, etc.)
3. Verify milestone breakdown shows only steps in selected bracket
4. Verify shopping list updates to show only materials for filtered brackets
5. Select "Full Path" to restore complete view

### Testing Alternative Recipes & Pinning

1. Open profession with multiple recipe choices at same skill level
2. Expand a step in milestone breakdown
3. Verify ingredients show first, then collapsible "Alternatives (N)" section
4. Expand alternatives, verify groups of 5
5. Hover tooltip shows materials and source info for unlearned recipes (`[!]`)
6. Click alternative to pin it - verify `[*]` indicator on skill range
7. Verify "Recalculate with N pins" button appears (green, full-width)
8. Click recalculate - verify path updates respecting pinned recipes
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
- [ ] Milestones display correctly
- [ ] Shopping list is accurate
- [ ] Works with TSM pricing
- [ ] Works with Auctionator pricing
- [ ] Works standalone (vendor prices)
- [ ] Existing features still work
