# Development Workflow

## Git Workflow

### Branch Strategy

- `main` - Stable, release-ready code
- Feature branches for larger work (optional)

### Commit Message Format

```
<type>(<scope>): <description>

<optional body>
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation only
- `refactor` - Code change that doesn't fix bug or add feature
- `test` - Adding tests
- `chore` - Maintenance tasks

**Scopes:**
- `ui` - User interface changes
- `pathfinder` - Path calculation
- `pricing` - Pricing module
- `inventory` - Inventory scanning
- `core` - Core functionality

**Examples:**
```
feat(ui): add bank items to shopping list
fix(pathfinder): correct cost calculation for multi-yield recipes
refactor(pricing): simplify provider fallback logic
docs: update architecture overview
```

## Documentation Workflow (MANDATORY)

**Trigger:** Any commit that changes features or behavior.

### Before Committing Checklist

- [ ] `CHANGELOG.md` - Entry under `[Unreleased]` with Added/Changed/Fixed
- [ ] `README.md` - Updated if features or dependencies changed
- [ ] `CURSEFORGE.md` - Synced with README.md
- [ ] Architecture docs updated if design changed
- [ ] Completed plans moved to `docs/plans/completed/`

### Commit Commands

```bash
# Review changes
git status && git diff --stat

# Check recent commit style
git log --oneline -5

# Stage and commit
git add <files> && git commit -m "$(cat <<'EOF'
<type>(<scope>): <description>

<optional body>
EOF
)"

# Verify
git status && git log --oneline -1
```

## Plan Management

### Directory Structure

```
docs/plans/
├── active/              # Plans in progress
├── completed/           # Implemented plans
└── backlog/             # Future work ideas
```

### Plan Lifecycle

1. **Create**: Write plan in `docs/plans/active/` or root `docs/plans/`
2. **Implement**: Follow plan, update as needed
3. **Complete**: Move to `docs/plans/completed/` when done

## Release Process

1. Update `CHANGELOG.md`:
   - Move `[Unreleased]` items to new version section
   - Add release date

2. Update version in `LazyProf.toc`:
   ```
   ## Version: X.Y.Z
   ```

3. Verify docs are in sync:
   - README features match actual
   - CURSEFORGE matches README

4. Commit: `chore: release vX.Y.Z`

5. Tag: `git tag vX.Y.Z`

6. Push: `git push && git push --tags`

7. Upload to CurseForge

## Cross-Project Coordination

LazyProf depends on CraftLib. When CraftLib adds features:

1. Check `~/.claude/NOTES.md` in LazyProf for pending CraftLib features
2. Update LazyProf to use new CraftLib APIs when available
3. Mark feature as used in NOTES.md
