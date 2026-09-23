#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PATH="${ROOT_DIR}/.build/DerivedData/Build/Products/Debug/DevBar.app"
EXECUTABLE="${APP_PATH}/Contents/MacOS/DevBar"
MODE="${1:-run}"

cd "${ROOT_DIR}"

if /usr/bin/pgrep -x DevBar >/dev/null 2>&1; then
  /usr/bin/pkill -x DevBar
fi

/usr/bin/xcodebuild \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  build

case "${MODE}" in
  run)
    /usr/bin/open -n "${APP_PATH}"
    ;;
  --debug)
    /usr/bin/lldb -- "${EXECUTABLE}"
    ;;
  --logs)
    /usr/bin/open -n "${APP_PATH}"
    /usr/bin/log stream --style compact --predicate 'process == "DevBar"'
    ;;
  --telemetry)
    /usr/bin/open -n "${APP_PATH}"
    /usr/bin/log stream --style compact --predicate 'process == "DevBar" AND (eventMessage CONTAINS[c] "telemetry" OR subsystem CONTAINS[c] "devbar")'
    ;;
  --verify)
    /usr/bin/open -n "${APP_PATH}"
    for _ in {1..20}; do
      if /usr/bin/pgrep -x DevBar >/dev/null 2>&1; then
        echo "DevBar launched: ${APP_PATH}"
        exit 0
      fi
      /bin/sleep 0.25
    done
    echo "DevBar did not stay running after launch." >&2
    exit 1
    ;;
  *)
    echo "Usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
