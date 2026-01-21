# Contributing to LazyProf

## Getting Started

1. **Setup**: See [docs/development/SETUP.md](docs/development/SETUP.md)
2. **Architecture**: See [docs/architecture/OVERVIEW.md](docs/architecture/OVERVIEW.md)
3. **UX Philosophy**: See [docs/architecture/DECISIONS.md](docs/architecture/DECISIONS.md) (ADR-002)

## Types of Contributions

### Bug Fixes

1. Verify the bug exists (test in-game)
2. Fix the issue
3. Test thoroughly (see [docs/development/TESTING.md](docs/development/TESTING.md))
4. Update CHANGELOG.md
5. Submit PR

### New Features

1. Discuss the feature first (open an issue)
2. Follow UX philosophy: "Think Less, Trust the Addon"
3. Update documentation with new features
4. Test with all pricing providers

### UI Changes

Must follow UX principles:
- Maximum information, no guessing
- Clear labels over colors
- Full context in every element

See [docs/architecture/DECISIONS.md](docs/architecture/DECISIONS.md) ADR-002.

## Coding Standards

### Lua Style

- Use `local` for all variables
- Constants in `UPPER_CASE`
- Functions in `camelCase`
- Use Ace3 conventions for UI

### Dependencies

- CraftLib is required - verify integration works
- Pricing providers are optional - handle gracefully

## Documentation Requirements

**Every PR must update documentation:**

- [ ] `CHANGELOG.md` - Entry under `[Unreleased]`
- [ ] `README.md` - If features changed
- [ ] `CURSEFORGE.md` - Keep in sync with README

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

See [docs/development/WORKFLOW.md](docs/development/WORKFLOW.md) for details.

## Questions?

Open an issue for questions about contributing.
