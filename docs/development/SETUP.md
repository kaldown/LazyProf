# Development Setup

## Prerequisites

- World of Warcraft (Classic Era, Anniversary, or compatible version)
- Git (with submodule support)
- CraftLib addon installed
- Text editor with Lua support

## Clone Repository

```bash
git clone --recurse-submodules https://github.com/kaldown/LazyProf.git
```

If you already cloned without `--recurse-submodules`:
```bash
git submodule update --init --recursive
```

## Symlink to AddOns Folder

### macOS

```bash
ln -s /path/to/LazyProf "<WoW Install>/Interface/AddOns/LazyProf"
```

### Windows

```cmd
mklink /D "C:\Program Files (x86)\World of Warcraft\<version>\Interface\AddOns\LazyProf" "C:\Users\YOU\Projects\LazyProf"
```

Replace `<version>` with `_classic_`, `_anniversary_`, etc. as appropriate.

## Install Dependencies

1. **CraftLib** (required): Included as git submodule in `Libs/CraftLib/`
2. **Ace3** (bundled): Already in `Libs/Ace3/`
3. **LibDBIcon + LibDataBroker** (fetched at release): For local development:
   ```bash
   cd Libs
   svn checkout https://repos.curseforge.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0 LibDBIcon-1.0
   svn checkout https://repos.curseforge.com/wow/libdatabroker-1-1/trunk LibDataBroker-1.1
   ```

## Verify Installation

1. Launch WoW
2. Character select: Click "AddOns"
3. Confirm both "CraftLib" and "LazyProf" appear and are enabled
4. Log into game
5. Open any profession window
6. LazyProf panels should appear (milestone breakdown + shopping list)

## Recommended Addons for Development

| Addon | Purpose |
|-------|---------|
| [BugSack](https://www.curseforge.com/wow/addons/bugsack) | Captures Lua errors in a browseable UI |
| [BugGrabber](https://www.curseforge.com/wow/addons/bug-grabber) | Required by BugSack |
| [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) | Test TSM pricing integration |
| [Auctionator](https://www.curseforge.com/wow/addons/auctionator) | Test Auctionator pricing integration |
| [Syndicator](https://www.curseforge.com/wow/addons/syndicator) | Test extended inventory (bank, alts, mail, guild bank) |

## Making Changes

1. Edit files in the project directory
2. In-game: `/reload` to reload UI and pick up changes
3. Open profession window to test
4. Use `/lp log` for debug output
5. Use `/lp` for settings
