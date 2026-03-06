#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${ROOT_DIR}/scripts/install_bar.sh"
APP_BUNDLE="${HOME}/Applications/ANEBar.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/ANEBar"

FORCE_REBUILD=0
PASSTHROUGH_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --force-rebuild)
      FORCE_REBUILD=1
      ;;
    *)
      PASSTHROUGH_ARGS+=("$arg")
      ;;
  esac
done

latest_source_mtime() {
  find \
    "${ROOT_DIR}/apps/ANEBar/Sources" \
    "${ROOT_DIR}/apps/ANEBar/Package.swift" \
    "${ROOT_DIR}/scripts/install_bar.sh" \
    -type f -exec stat -f "%m" {} \; 2>/dev/null \
    | sort -nr \
    | head -1
}

installed_binary_mtime() {
  if [[ -x "${APP_BINARY}" ]]; then
    stat -f "%m" "${APP_BINARY}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

SRC_MTIME="$(latest_source_mtime || echo 0)"
BIN_MTIME="$(installed_binary_mtime)"

if [[ "${FORCE_REBUILD}" == "1" ]] || [[ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]] || [[ ! -d "${APP_BUNDLE}" ]] || [[ "${SRC_MTIME}" -gt "${BIN_MTIME}" ]]; then
  echo "Building/installing ANEBar..."
  "${INSTALL_SCRIPT}" "${PASSTHROUGH_ARGS[@]}"
  exit 0
fi

echo "ANEBar is up to date. Opening installed app..."
open "${APP_BUNDLE}"
