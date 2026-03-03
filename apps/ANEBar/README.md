# ANEBar (Menu Bar Controller)

Minimal macOS menu bar app to control the ANE research workflow.

## Features

- Run fast pipeline (`--qos-runs 2 --skip-build`)
- Run full pipeline (`--qos-runs 3`)
- Live silicon telemetry panel with rolling graph (P-cores, E-cores, memory, ANE run metrics)
- Auto model tracker (counts and lists model artifacts from the selected ANE repo)
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

Install as app bundle (from repo root):

```bash
./scripts/install_bar.sh --start-at-login
```

Optional repo override:

```bash
ANE_REPO_PATH=/Users/yourname/path/to/ANE swift run ANEBar
```

## Notes

- App expects `uv` installed and available in `PATH`.
- Pipeline command executed from selected repo root.
- ANE run metrics appear when the pipeline emits `ANE utilization` / `ANE TFLOPS` lines.
