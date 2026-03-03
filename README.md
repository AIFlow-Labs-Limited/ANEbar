# ANEbar

Workspace for building a macOS menu bar controller around ANE research workflows.

## Contents

- `apps/ANEBar` — native macOS menu bar app (Swift, AppKit)
- `upstream/ANE` — git submodule tracking https://github.com/maderix/ANE
- `scripts/sync_ane.sh` — one-command submodule refresh

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/AIFlow-Labs-Limited/ANEbar.git
cd ANEbar

# Build/run menubar app
cd apps/ANEBar
swift build
swift run ANEBar
```

## Keep ANE Fresh

```bash
./scripts/sync_ane.sh
```

Then commit the submodule pointer update:

```bash
git add upstream/ANE
git commit -m "chore: bump upstream ANE submodule"
git push
```

## Notes

- `ANEBar` runs the research pipeline via `uv` from an ANE repository path.
- Set `ANE_REPO_PATH` when launching, or pick the repo root from the app menu.
