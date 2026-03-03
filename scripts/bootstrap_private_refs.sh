#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_DIR="${ROOT_DIR}/.private"
SHALLOW=1

CODEXBAR_URL="https://github.com/steipete/CodexBar.git"
ANE_MIRROR_URL="https://github.com/maderix/ANE.git"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --full-history            Clone full history (default is --depth 1)
  --codexbar-url <url>      Override CodexBar source URL
  --ane-url <url>           Override ANE mirror source URL
  -h, --help                Show this help
USAGE
}

clone_or_update() {
  local label="$1"
  local url="$2"
  local target="$3"

  if [[ -d "${target}/.git" ]]; then
    echo "Updating ${label} -> ${target}"
    git -C "${target}" fetch --all --prune
    git -C "${target}" pull --ff-only || true
  else
    echo "Cloning ${label} -> ${target}"
    if [[ "${SHALLOW}" == "1" ]]; then
      git clone --depth 1 "${url}" "${target}"
    else
      git clone "${url}" "${target}"
    fi
  fi

  echo "  $(git -C "${target}" rev-parse --short HEAD)  $(git -C "${target}" remote get-url origin)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-history)
      SHALLOW=0
      ;;
    --codexbar-url)
      CODEXBAR_URL="$2"
      shift
      ;;
    --ane-url)
      ANE_MIRROR_URL="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

mkdir -p "${PRIVATE_DIR}"

clone_or_update "CodexBar" "${CODEXBAR_URL}" "${PRIVATE_DIR}/CodexBar"
clone_or_update "ANE-mirror" "${ANE_MIRROR_URL}" "${PRIVATE_DIR}/ANE"

echo
echo "Private refs are ready under ${PRIVATE_DIR}."
echo "These paths are gitignored and will not be pushed."
