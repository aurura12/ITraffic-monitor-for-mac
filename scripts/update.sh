#!/usr/bin/env bash
set -euo pipefail

# Build and launch iTraffic without opening Xcode. The project remains the
# source of truth for the bundle identifier, version, entitlements, and icon.

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_CACHE_DIR="${TMPDIR:-/tmp}/ITrafficMonitorForMac"
DERIVED_DATA_DIR="$BUILD_CACHE_DIR/DerivedData"
APP_BUNDLE="$DIST_DIR/ITraffic.app"
INSTALL_APP="/Applications/ITraffic.app"
APP_BINARY="$INSTALL_APP/Contents/MacOS/ITraffic"
PROJECT="$ROOT_DIR/ITrafficMonitorForMac.xcodeproj"
SCHEME="ITrafficMonitorForMac"
MIN_SYSTEM_VERSION="14.0"

usage() {
  cat >&2 <<'USAGE'
usage: ./scripts/update.sh [run|--debug|--logs|--telemetry|--verify|--clean]

  run          Build the Release app and launch it (default)
  --debug      Build Debug and attach LLDB
  --logs       Build Release, launch, and stream app logs
  --telemetry  Build Release, launch, and stream iTraffic subsystem logs
  --verify     Build Release, launch, and verify the process is running
  --clean      Remove this script's build/output directories, then run
USAGE
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--clean|clean)
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ "$MODE" == "clean" || "$MODE" == "--clean" ]]; then
  rm -rf "$DERIVED_DATA_DIR" "$APP_BUNDLE" "$INSTALL_APP"
  MODE="run"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  current_version="$(sw_vers -productVersion)"
  if ! awk -v current="$current_version" -v minimum="$MIN_SYSTEM_VERSION" '
    function version(value, parts, count, i) {
      count = split(value, parts, ".")
      for (i = 1; i <= 3; i++) parts[i] = (i <= count ? parts[i] + 0 : 0)
      return parts[1] * 10000 + parts[2] * 100 + parts[3]
    }
    BEGIN { exit(version(current) >= version(minimum) ? 0 : 1) }
  '; then
    echo "This app requires macOS $MIN_SYSTEM_VERSION or newer (found $current_version)." >&2
    exit 1
  fi
fi

command -v xcodebuild >/dev/null 2>&1 || {
  echo "xcodebuild was not found. Install Xcode command line tools first." >&2
  exit 1
}

case "$MODE" in
  --debug|debug)
    CONFIGURATION="Debug"
    ;;
  *)
    CONFIGURATION="Release"
    ;;
esac

mkdir -p "$DIST_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -quiet \
  build

PRODUCT_APP="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/ITraffic.app"
if [[ ! -d "$PRODUCT_APP" ]]; then
  echo "Build succeeded but the app bundle was not found: $PRODUCT_APP" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
ditto "$PRODUCT_APP" "$APP_BUNDLE"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"
fi

# Install the app into /Applications so Finder's Applications folder shows
# the freshly built version, then launch that copy.
rm -rf "$INSTALL_APP"
ditto "$APP_BUNDLE" "$INSTALL_APP"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --timestamp=none "$INSTALL_APP"
fi

open_app() {
  pkill -x "ITraffic" >/dev/null 2>&1 || true
  /usr/bin/open -n "$INSTALL_APP" --args --open-dashboard
}

case "$MODE" in
  run)
    open_app
    echo "ITraffic updated and launched (installed to $INSTALL_APP)"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "ITraffic"'
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.foamzou.ITrafficMonitorForMac"'
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "ITraffic" >/dev/null
    echo "ITraffic is running from $INSTALL_APP"
    ;;
esac
