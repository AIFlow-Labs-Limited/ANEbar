# ANEBar (Menu Bar Controller)

Minimal macOS menu bar app to control the ANE research workflow.

## Features

- Run fast pipeline (`--qos-runs 2 --skip-build`)
- Run full pipeline (`--qos-runs 3`)
- Queue and schedule runs (including delayed benchmark queue)
- Live silicon telemetry panel with rolling graph (P-cores, E-cores, memory, ANE run metrics)
- Research-metrics fallback parser (`qos_summary.csv` / `probe_summary.json`) so ANE graph does not stay empty on research runs
- Model intelligence panel (family counts, size buckets, new-in-24h/7d, missing tokenizer/config hints)
- Guardrails for heavy runs (thermal + battery state)
- Local chat window with model selector and streaming output (Ollama runtime)
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
- When those lines are missing, ANEbar reads research summary files under `training/research/results/data`.
- Chat uses `ollama` (`ollama list`, `ollama run`) for local model selection and streaming.
- Queue state and benchmark summary are persisted in `~/Library/Application Support/ANEBar/`.
