# Development Setup

## Prerequisites

- World of Warcraft (TBC Classic or appropriate version)
- Git
- CraftLib addon installed
- Text editor with Lua support

## Clone Repository

```bash
git clone https://github.com/kaldown/LazyProf.git ~/Projects/LazyProf
```

## Symlink to AddOns Folder

### macOS

```bash
ln -s ~/Projects/LazyProf "/Applications/World of Warcraft/_classic_/Interface/AddOns/LazyProf"
```

### Windows

```cmd
mklink /D "C:\Program Files (x86)\World of Warcraft\_classic_\Interface\AddOns\LazyProf" "C:\Users\YOU\Projects\LazyProf"
```

## Install Dependencies

1. **CraftLib** (required): Symlink or copy from `~/Projects/CraftLib/`
2. **Ace3** (bundled): Already in `Libs/Ace3/`

## Verify Installation

1. Launch WoW
2. Character select: Click "AddOns"
3. Confirm both "CraftLib" and "LazyProf" appear
4. Log into game
5. Open any profession window
6. LazyProf panels should appear

## Recommended Addons for Development

| Addon | Purpose |
|-------|---------|
| [BugSack](https://www.curseforge.com/wow/addons/bugsack) | Captures Lua errors |
| [BugGrabber](https://www.curseforge.com/wow/addons/bug-grabber) | Required by BugSack |
| [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) | Test TSM pricing |
| [Auctionator](https://www.curseforge.com/wow/addons/auctionator) | Test Auctionator pricing |

## Making Changes

1. Edit files in `~/Projects/LazyProf/`
2. In-game: `/reload` to reload UI
3. Open profession window to test
4. Use `/lp` or `/lazyprof` for commands
