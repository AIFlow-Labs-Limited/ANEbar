# ANEbar

ANEbar is a macOS menu bar app for tracking and operating the [maderix/ANE](https://github.com/maderix/ANE) research stack in real time.

It is built for daily research + social publishing workflows: run experiments, monitor silicon behavior, track model growth in the repo, and jump directly to generated media assets.

## Why ANEbar

- Real-time silicon telemetry in the menu bar
- One-click ANE research pipeline controls
- Auto model tracker as upstream adds more model assets
- Fast path from experiment output to social-ready graphics and post drafts

## Key Features

- Live metrics panel with rolling graph:
  - P-core usage
  - E-core usage
  - memory usage
  - ANE utilization and TFLOPS (when emitted by the pipeline)
  - fallback extraction from research result files when stdout metrics are absent
- Queue + scheduler controls for fast/full/benchmark run presets
- Guardrails for heavier runs (battery + thermal checks)
- Local chat panel:
  - model selector
  - streaming responses
  - built around local `ollama` runtime
- Repro bundle export + benchmark summary markdown for repeatable reporting
- Model tracker:
  - continuously scans the selected ANE repo
  - tracks common model artifact types (`.safetensors`, `.gguf`, `.onnx`, `.mlmodel`, `.mlpackage`, `.pt`, `.pth`, `.bin`)
- Workflow controls:
  - run fast pipeline (`--qos-runs 2 --skip-build`)
  - run full pipeline (`--qos-runs 3`)
  - stop running job
- Content shortcuts:
  - open results folder
  - open hero/spotlight graphics
  - copy today's post draft to clipboard
- Repo management:
  - persistent repo selector in app
  - ANE upstream tracked via submodule

## Repository Layout

- `apps/ANEBar` - Swift/AppKit menu bar application
- `upstream/ANE` - ANE upstream as a git submodule
- `scripts/install_bar.sh` - package and install `ANEBar.app`
- `scripts/sync_ane.sh` - update ANE submodule to latest `main`
- `scripts/bootstrap_private_refs.sh` - optional hidden local clones for private references
- `scripts/sync_private_refs.sh` - update hidden local clones

## Requirements

- macOS 14+
- Apple Silicon Mac
- Swift toolchain (SwiftPM)
- `uv` installed and available in `PATH` (used by pipeline execution)
- Git

## Quick Start

```bash
git clone --recurse-submodules https://github.com/AIFlow-Labs-Limited/ANEbar.git
cd ANEbar

# Build and run directly
cd apps/ANEBar
swift build
swift run ANEBar
```

## Install as a Real App (Recommended)

From repository root:

```bash
./scripts/install_bar.sh --start-at-login
```

What this does:

- builds `ANEBar`
- creates an app bundle
- installs to `~/Applications/ANEBar.app`
- optionally configures start-at-login via LaunchAgent

Common install commands:

```bash
./scripts/install_bar.sh --debug
./scripts/install_bar.sh --remove-login
./scripts/install_bar.sh --no-launch
```

## Pointing ANEbar to the Right Repo

ANEbar defaults to:

- saved repo path from previous runs
- or `ANE_REPO_PATH`
- or `~/Development/AIFLOWLABS/deep_learning/ANE`

You can also set/change it from the app menu (`Choose Repo Root...`).

For terminal launch override:

```bash
ANE_REPO_PATH=/absolute/path/to/ANE swift run ANEBar
```

## Keep Upstream ANE Fresh

```bash
./scripts/sync_ane.sh
git add upstream/ANE
git commit -m "chore: bump upstream ANE submodule"
git push
```

## Hidden Local References (Not Pushed)

For private local references that should never ship publicly:

```bash
./scripts/bootstrap_private_refs.sh
./scripts/sync_private_refs.sh
```

This uses `.private/` (gitignored) for local-only mirrors such as CodexBar and ANE mirror clones.

## Daily Workflow

1. Sync upstream ANE.
2. Run fast pipeline while iterating.
3. Run full pipeline when validating a milestone.
4. Open generated graphics and copy post draft directly from ANEbar.
5. Post updates with graph + model tracker deltas.

## Privacy and Security

- ANEbar runs locally on your machine.
- The app does not require cloud credentials to function.
- Network activity comes from explicit git operations (`sync_ane.sh`, private ref scripts) and whatever your ANE pipeline executes.
- Upstream ANE uses private Apple APIs; read upstream caveats before production or distribution use.

## Troubleshooting

- `ANEbar` icon not visible:
  - run `open ~/Applications/ANEBar.app`
  - or restart: `pkill -x ANEBar || true`
- Pipeline fails from menu:
  - verify `uv --version`
  - verify ANE repo path in app menu
- ANE metrics show `n/a`:
  - ANE values are parsed from pipeline output (`ANE utilization` / `ANE TFLOPS`)
- Model tracker count looks wrong:
  - use `Refresh Model Index` in the menu

## Roadmap

- richer ANE-specific counters in the bar
- model family breakdown and change feed
- benchmark session history and export
- share-ready chart presets for X/social posts

## Contributing

1. Fork the repo.
2. Create a branch with `codex/` prefix.
3. Keep changes focused and test with `swift build`.
4. Open a PR with screenshots or short recordings for UI changes.

## License

License has not been declared in this repository yet. Set a license before public distribution.
