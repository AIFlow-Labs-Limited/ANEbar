#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/apps/ANEBar"
APP_NAME="ANEBar"
BUNDLE_ID="com.aiflowlabs.anebar"
BUILD_CONF="release"
ENABLE_LOGIN=0
DISABLE_LOGIN=0
AUTO_LAUNCH=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --debug            Build debug binary instead of release
  --start-at-login   Install and enable a LaunchAgent for auto-start
  --remove-login     Disable and remove LaunchAgent
  --no-launch        Do not open app after install
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      BUILD_CONF="debug"
      ;;
    --start-at-login)
      ENABLE_LOGIN=1
      ;;
    --remove-login)
      DISABLE_LOGIN=1
      ;;
    --no-launch)
      AUTO_LAUNCH=0
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

resolve_binary() {
  local arch
  arch="$(uname -m)"
  local candidates=(
    "${APP_DIR}/.build/${BUILD_CONF}/${APP_NAME}"
    "${APP_DIR}/.build/${arch}-apple-macosx/${BUILD_CONF}/${APP_NAME}"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  return 1
}

create_bundle() {
  local executable="$1"
  local staging_bundle="$2"

  rm -rf "${staging_bundle}"
  mkdir -p "${staging_bundle}/Contents/MacOS"

  cp "${executable}" "${staging_bundle}/Contents/MacOS/${APP_NAME}"

  cat > "${staging_bundle}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

  codesign --force --deep --sign - "${staging_bundle}" >/dev/null 2>&1 || true
}

enable_login_agent() {
  local installed_bundle="$1"
  local launch_agents_dir="${HOME}/Library/LaunchAgents"
  local launch_agent="${launch_agents_dir}/${BUNDLE_ID}.plist"
  local label="${BUNDLE_ID}"
  local binary_path="${installed_bundle}/Contents/MacOS/${APP_NAME}"
  local ane_repo_path="${ROOT_DIR}/upstream/ANE"

  mkdir -p "${launch_agents_dir}"

  cat > "${launch_agent}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${binary_path}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ANE_REPO_PATH</key>
    <string>${ane_repo_path}</string>
  </dict>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$(id -u)" "${launch_agent}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "${launch_agent}"
  launchctl kickstart -k "gui/$(id -u)/${label}" >/dev/null 2>&1 || true

  echo "Start-at-login enabled (${launch_agent})"
}

disable_login_agent() {
  local launch_agent="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
  launchctl bootout "gui/$(id -u)" "${launch_agent}" >/dev/null 2>&1 || true
  rm -f "${launch_agent}"
  echo "Start-at-login removed (${launch_agent})"
}

cd "${APP_DIR}"
swift build -c "${BUILD_CONF}"

if ! BIN_PATH="$(resolve_binary)"; then
  echo "Could not locate built ${APP_NAME} binary." >&2
  exit 1
fi

STAGING_DIR="${APP_DIR}/.artifacts"
STAGING_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL_BUNDLE="${INSTALL_DIR}/${APP_NAME}.app"

mkdir -p "${STAGING_DIR}" "${INSTALL_DIR}"
create_bundle "${BIN_PATH}" "${STAGING_BUNDLE}"

rm -rf "${INSTALL_BUNDLE}"
cp -R "${STAGING_BUNDLE}" "${INSTALL_BUNDLE}"

echo "Installed: ${INSTALL_BUNDLE}"

if [[ "${DISABLE_LOGIN}" == "1" ]]; then
  disable_login_agent
fi
if [[ "${ENABLE_LOGIN}" == "1" ]]; then
  enable_login_agent "${INSTALL_BUNDLE}"
fi

if [[ "${AUTO_LAUNCH}" == "1" ]]; then
  open "${INSTALL_BUNDLE}"
  echo "Launched ${APP_NAME}."
fi
