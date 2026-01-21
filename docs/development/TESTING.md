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
1. Enable Syndicator
2. Put materials in bank
3. Shopping list should show "From Bank" for bank materials

## Debugging

### BugSack Errors

Install BugSack + BugGrabber to capture Lua errors.

**Reading errors:**
```
/bugsack       - Open BugSack UI
```

**Error log location:**
```
WTF/Account/<account>/SavedVariables/BugSack.lua
```

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
