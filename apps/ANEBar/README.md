# ANEBar (Menu Bar Controller)

Minimal macOS menu bar app to control the ANE research workflow.

## Features

- Run fast pipeline (`--qos-runs 2 --skip-build`)
- Run full pipeline (`--qos-runs 3`)
- Queue and schedule runs (including delayed benchmark queue)
- Live silicon telemetry panel with rolling graph (P-cores, E-cores, memory, ANE live metrics)
- Truthful telemetry split:
  - live graph only shows ANE values from live streams
  - artifact summaries are used for history/benchmark reporting instead of fake live load
  - optional `powermetrics` power line for ANE/CPU/GPU rails when superuser access is available
- Model intelligence panel (family counts, size buckets, new-in-24h/7d, missing tokenizer/config hints)
- Guardrails for heavy runs (thermal + battery state)
- Verified benchmark window backed by local sweep evidence and stored run history
- Verified benchmark actions:
  - run the full verification sweep from the app
  - copy a benchmark topline for X/social posts
  - open raw evidence logs
- Dedicated history window for recent runs and quick comparison
- ANE chat window with model selector and streaming output (configurable ANE runtime command)
- Keep-menu-open toggle for persistent in-menu control clicks
- Repro bundle export + benchmark summary generation
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
- When those lines are missing, ANEbar keeps the live ANE row empty and stores artifact summaries under history/benchmark reporting instead.
- Chat uses a configurable ANE runtime command template (`{model}`, `{prompt}`, `{repo}` placeholders).
- Queue state and benchmark summary are persisted in `~/Library/Application Support/ANEBar/`.
