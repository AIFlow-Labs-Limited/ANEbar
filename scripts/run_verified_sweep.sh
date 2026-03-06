#!/usr/bin/env bash
set -u
set -o pipefail

ANE_REPO_PATH="${1:-${ANE_REPO_PATH:-}}"
if [[ -z "${ANE_REPO_PATH}" ]]; then
  echo "usage: $0 /absolute/path/to/ANE" >&2
  exit 2
fi

if [[ ! -d "${ANE_REPO_PATH}" ]]; then
  echo "ANE repo not found: ${ANE_REPO_PATH}" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAMP="$(date +%F)"
OUT_DIR="${WORKSPACE_ROOT}/.private/research/${STAMP}/verification/local_sweep"
RAW_DIR="${OUT_DIR}/raw"
mkdir -p "${RAW_DIR}"

HEAD_SHA="$(git -C "${ANE_REPO_PATH}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GENERATED_AT="$(date -Iseconds)"

run_capture() {
  local name="$1"
  local workdir="$2"
  local build_cmd="$3"
  local run_cmd="$4"
  local build_log="${RAW_DIR}/${name}_build.log"
  local run_log="${RAW_DIR}/${name}_run.log"

  : > "${build_log}"
  : > "${run_log}"

  if [[ -n "${build_cmd}" ]]; then
    echo "==> ${name} build"
    (
      cd "${workdir}" &&
      /bin/bash -lc "${build_cmd}"
    ) > "${build_log}" 2>&1 || true
  fi

  if [[ -n "${run_cmd}" ]]; then
    echo "==> ${name} run"
    (
      cd "${workdir}" &&
      /bin/bash -lc "${run_cmd}"
    ) > "${run_log}" 2>&1 || true
  fi
}

run_capture \
  "inmem_basic" \
  "${ANE_REPO_PATH}" \
  "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o inmem_basic inmem_basic.m" \
  "./inmem_basic"

run_capture \
  "inmem_peak" \
  "${ANE_REPO_PATH}" \
  "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o inmem_peak inmem_peak.m" \
  "./inmem_peak"

run_capture \
  "inmem_bench" \
  "${ANE_REPO_PATH}" \
  "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework IOSurface -ldl -o inmem_bench inmem_bench.m" \
  "./inmem_bench"

run_capture \
  "sram_bench" \
  "${ANE_REPO_PATH}" \
  "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o sram_bench sram_bench.m" \
  "./sram_bench"

run_capture \
  "sram_probe" \
  "${ANE_REPO_PATH}" \
  "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework IOSurface -ldl -o sram_probe sram_probe.m" \
  "./sram_probe"

run_capture \
  "test_qos_sweep" \
  "${ANE_REPO_PATH}" \
  "make -C training test_qos_sweep" \
  "./training/test_qos_sweep"

run_capture \
  "test_weight_reload" \
  "${ANE_REPO_PATH}" \
  "make -C training test_weight_reload" \
  "./training/test_weight_reload"

run_capture \
  "test_perf_stats" \
  "${ANE_REPO_PATH}" \
  "make -C training test_perf_stats" \
  "./training/test_perf_stats"

run_capture \
  "test_ane_advanced" \
  "${ANE_REPO_PATH}" \
  "make -C training test_ane_advanced" \
  "./training/test_ane_advanced"

run_capture \
  "train_large" \
  "${ANE_REPO_PATH}" \
  "make -C training train_large" \
  "./training/train_large --steps 2 --lr 1e-4"

cat > "${OUT_DIR}/README.md" <<EOF
# Local ANE Sweep

Repo under test: \`${ANE_REPO_PATH}\`
HEAD: \`${HEAD_SHA}\`
Generated: \`${GENERATED_AT}\`

This directory is managed by \`scripts/run_verified_sweep.sh\`.

Raw logs:

- \`inmem_basic_build.log\`
- \`inmem_basic_run.log\`
- \`inmem_peak_build.log\`
- \`inmem_peak_run.log\`
- \`inmem_bench_build.log\`
- \`inmem_bench_run.log\`
- \`sram_bench_build.log\`
- \`sram_bench_run.log\`
- \`sram_probe_build.log\`
- \`sram_probe_run.log\`
- \`test_qos_sweep_build.log\`
- \`test_qos_sweep_run.log\`
- \`test_weight_reload_build.log\`
- \`test_weight_reload_run.log\`
- \`test_perf_stats_build.log\`
- \`test_perf_stats_run.log\`
- \`test_ane_advanced_build.log\`
- \`test_ane_advanced_run.log\`
- \`train_large_build.log\`
- \`train_large_run.log\`
EOF

echo
echo "Verified sweep logs written to:"
echo "${OUT_DIR}"
