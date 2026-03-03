# ANEbar

Workspace for building a macOS menu bar controller around ANE research workflows.

Current bar capabilities include:
- live silicon graph (P/E core + memory + ANE run telemetry)
- model artifact tracker (auto-detects models added to the ANE repo)
- one-click pipeline controls and social-asset shortcuts

## Contents

- `apps/ANEBar` — native macOS menu bar app (Swift, AppKit)
- `upstream/ANE` — git submodule tracking https://github.com/maderix/ANE
- `scripts/sync_ane.sh` — one-command submodule refresh
- `scripts/install_bar.sh` — package + install `ANEBar.app`
- `scripts/bootstrap_private_refs.sh` — hidden local clones for private reference repos
- `scripts/sync_private_refs.sh` — refresh hidden local clones

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

## Install Like CodexBar

```bash
./scripts/install_bar.sh --start-at-login
```

This builds `ANEBar`, creates a proper `.app`, installs it in `~/Applications/ANEBar.app`,
and optionally enables start-at-login via LaunchAgent.

Useful flags:

```bash
./scripts/install_bar.sh --debug
./scripts/install_bar.sh --remove-login
./scripts/install_bar.sh --no-launch
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

## Hidden Local References

You asked for CodexBar + ANE local references without pushing them.

```bash
./scripts/bootstrap_private_refs.sh
./scripts/sync_private_refs.sh
```

This creates and updates:

- `.private/CodexBar`
- `.private/ANE`

`.private/` is gitignored, so nothing under it is pushed.

Note: committed submodules are always tracked in git (`.gitmodules` + gitlink).
For hidden local references, regular git clones in a gitignored folder are the clean approach.

## Notes

- `ANEBar` runs the research pipeline via `uv` from an ANE repository path.
- Set `ANE_REPO_PATH` when launching, or pick the repo root from the app menu.
