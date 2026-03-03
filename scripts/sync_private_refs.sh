#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_DIR="${ROOT_DIR}/.private"

sync_repo() {
  local label="$1"
  local path="$2"

  if [[ ! -d "${path}/.git" ]]; then
    echo "Skipping ${label}: ${path} is missing"
    return 0
  fi

  echo "Syncing ${label}"
  git -C "${path}" fetch --all --prune
  git -C "${path}" pull --ff-only || true
  echo "  $(git -C "${path}" rev-parse --short HEAD)"
}

sync_repo "CodexBar" "${PRIVATE_DIR}/CodexBar"
sync_repo "ANE-mirror" "${PRIVATE_DIR}/ANE"
