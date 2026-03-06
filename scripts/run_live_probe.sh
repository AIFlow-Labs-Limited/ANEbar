#!/usr/bin/env bash
set -u
set -o pipefail

REPO_ROOT="${1:-}"
EXPERIMENT_ID="${2:-}"
ITERATIONS="${3:-20}"
PEAK_TFLOPS="${ANE_PEAK_TFLOPS:-15.8}"

if [[ -z "${REPO_ROOT}" || -z "${EXPERIMENT_ID}" ]]; then
  echo "usage: $0 /absolute/path/to/ANE experiment_id [iterations]" >&2
  exit 2
fi

cd "${REPO_ROOT}"

build_cmd=""
run_cmd=""
parser=""

case "${EXPERIMENT_ID}" in
  inmem_peak)
    build_cmd="xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o inmem_peak inmem_peak.m"
    run_cmd="./inmem_peak"
    parser="table"
    ;;
  inmem_bench)
    build_cmd="xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework IOSurface -ldl -o inmem_bench inmem_bench.m"
    run_cmd="./inmem_bench"
    parser="table"
    ;;
  sram_bench)
    build_cmd="xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o sram_bench sram_bench.m"
    run_cmd="./sram_bench"
    parser="table"
    ;;
  sram_probe)
    build_cmd="xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework IOSurface -ldl -o sram_probe sram_probe.m"
    run_cmd="./sram_probe"
    parser="sram_probe"
    ;;
  test_qos_sweep)
    build_cmd="make -C training test_qos_sweep"
    run_cmd="./training/test_qos_sweep"
    parser="qos"
    ;;
  *)
    echo "Unsupported live probe: ${EXPERIMENT_ID}" >&2
    exit 2
    ;;
esac

extract_table_tflops() {
  awk '
    /FAIL\(/ { next }
    {
      n = split($0, fields, /[[:space:]]+/)
      if (n >= 2) {
        value = fields[n-1] + 0
        if (value > best) best = value
      }
    }
    END {
      if (best > 0) printf "%.6f\n", best
    }
  '
}

extract_sram_probe_tflops() {
  awk '
    /^[[:space:]]*[0-9]+[[:space:]]+ch/ {
      value = $(NF-1) + 0
      if (value > best) best = value
    }
    END {
      if (best >= 0) printf "%.6f\n", best
    }
  '
}

extract_qos_metrics() {
  awk '
    /Kernel:/ {
      if (match($0, /\(([0-9.]+)[[:space:]]+MFLOPS\)/, m)) kernel = m[1] + 0
    }
    /OK$/ {
      gsub(/ms/, "", $0)
      n = split($0, fields, /[[:space:]]+/)
      if (n >= 6) {
        eval_avg = fields[n-1] + 0
        if (best == 0 || eval_avg < best) best = eval_avg
      }
    }
    END {
      if (kernel > 0 && best > 0) printf "%.6f %.6f\n", kernel / best / 1000.0, best
    }
  '
}

/bin/bash -lc "${build_cmd}"

for ((i = 1; i <= ITERATIONS; i++)); do
  echo "=== ${EXPERIMENT_ID} iteration ${i}/${ITERATIONS} ==="
  OUTPUT="$(${run_cmd} 2>&1 || true)"
  printf '%s\n' "${OUTPUT}"

  case "${parser}" in
    table)
      TFLOPS="$(printf '%s\n' "${OUTPUT}" | extract_table_tflops || true)"
      if [[ -n "${TFLOPS}" ]]; then
        UTIL="$(awk -v t="${TFLOPS}" -v p="${PEAK_TFLOPS}" 'BEGIN { if (p > 0) printf "%.2f", (t / p) * 100.0; }')"
        echo "ANE TFLOPS: ${TFLOPS}"
        echo "ANE utilization: ${UTIL}%"
      fi
      ;;
    sram_probe)
      TFLOPS="$(printf '%s\n' "${OUTPUT}" | extract_sram_probe_tflops || true)"
      if [[ -n "${TFLOPS}" ]]; then
        UTIL="$(awk -v t="${TFLOPS}" -v p="${PEAK_TFLOPS}" 'BEGIN { if (p > 0) printf "%.2f", (t / p) * 100.0; }')"
        echo "ANE TFLOPS: ${TFLOPS}"
        echo "ANE utilization: ${UTIL}%"
      fi
      ;;
    qos)
      METRICS="$(printf '%s\n' "${OUTPUT}" | extract_qos_metrics || true)"
      if [[ -n "${METRICS}" ]]; then
        TFLOPS="$(printf '%s' "${METRICS}" | awk '{print $1}')"
        AVG_MS="$(printf '%s' "${METRICS}" | awk '{print $2}')"
        UTIL="$(awk -v t="${TFLOPS}" -v p="${PEAK_TFLOPS}" 'BEGIN { if (p > 0) printf "%.2f", (t / p) * 100.0; }')"
        echo "ANE TFLOPS: ${TFLOPS}"
        echo "ANE utilization: ${UTIL}%"
        echo "Avg train: ${AVG_MS} ms/step"
      fi
      ;;
  esac

  if [[ "${i}" -lt "${ITERATIONS}" ]]; then
    sleep 0.6
  fi
done
