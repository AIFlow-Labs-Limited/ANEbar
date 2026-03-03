# ANEBar (Menu Bar Controller)

Minimal macOS menu bar app to control the ANE research workflow.

## Features

- Run fast pipeline (`--qos-runs 2 --skip-build`)
- Run full pipeline (`--qos-runs 3`)
- Open generated result folder and hero graphics
- Copy today's premium post draft to clipboard
- Choose repository root interactively

## Build

```bash
cd apps/ANEBar
swift build
```

## Run

```bash
cd apps/ANEBar
swift run ANEBar
```

Optional repo override:

```bash
ANE_REPO_PATH=/Users/yourname/path/to/ANE swift run ANEBar
```

## Notes

- App expects `uv` installed and available in `PATH`.
- Pipeline command executed from selected repo root.
