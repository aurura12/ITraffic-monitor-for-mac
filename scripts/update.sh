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
VERSION_COUNTER_FILE="${ITRAFFIC_VERSION_COUNTER_FILE:-$ROOT_DIR/.itraffic-build-number}"
XCODEBUILD_TIMEOUT_SECONDS="${ITRAFFIC_XCODEBUILD_TIMEOUT_SECONDS:-900}"

usage() {
  cat >&2 <<'USAGE'
usage: ./scripts/update.sh [run|--debug|--logs|--telemetry|--verify|--clean]

  run          Build the Release app and launch it (default)
  --debug      Build Debug and attach LLDB
  --logs       Build Release, launch, and stream app logs
  --telemetry  Build Release, launch, and stream iTraffic subsystem logs
  --verify     Build Release, launch, and verify the process is running
  --clean      Remove this script's build/output directories, then run

environment:
  ITRAFFIC_XCODEBUILD_TIMEOUT_SECONDS
               Maximum build time in seconds (default: 900)
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

if ! [[ "$XCODEBUILD_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ITRAFFIC_XCODEBUILD_TIMEOUT_SECONDS must be a positive integer (seconds)." >&2
  exit 2
fi

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

DEFAULT_BUILD_VERSION="$(awk '$1 == "CURRENT_PROJECT_VERSION" && $3 ~ /^[0-9]+;$/ { sub(/;.*/, "", $3); print $3; exit }' "$PROJECT")"
DEFAULT_BUILD_VERSION="${DEFAULT_BUILD_VERSION:-1}"

read_numeric_version() {
  local file="$1"
  local value

  [[ -f "$file" ]] || return 1
  value="$(tr -d '[:space:]' < "$file")"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  return 1
}

last_build_version="$DEFAULT_BUILD_VERSION"
if counter_version="$(read_numeric_version "$VERSION_COUNTER_FILE")"; then
  last_build_version="$counter_version"
fi

# Pick up a version installed by an earlier checkout if the local counter file
# does not exist yet (or is behind that installed copy).
if command -v plutil >/dev/null 2>&1 && [[ -f "$INSTALL_APP/Contents/Info.plist" ]]; then
  installed_build_version="$(plutil -extract CFBundleVersion raw -o - "$INSTALL_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$installed_build_version" =~ ^[0-9]+$ ]] && (( installed_build_version > last_build_version )); then
    last_build_version="$installed_build_version"
  fi
fi

NEXT_BUILD_VERSION=$((last_build_version + 1))

log_step() {
  printf '\n==> %s\n' "$1"
}

BUILD_PID=""
PROCESS_TREE_PIDS=()

collect_process_tree() {
  local pid="$1"
  local child_pid

  PROCESS_TREE_PIDS+=("$pid")
  if command -v pgrep >/dev/null 2>&1; then
    while read -r child_pid; do
      [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
      collect_process_tree "$child_pid"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  fi
}

terminate_process_tree() {
  local root_pid="$1"
  local pid

  PROCESS_TREE_PIDS=()
  collect_process_tree "$root_pid"
  for pid in "${PROCESS_TREE_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${PROCESS_TREE_PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

cleanup_build_process() {
  if [[ -n "$BUILD_PID" ]] && kill -0 "$BUILD_PID" 2>/dev/null; then
    echo "Stopping the interrupted xcodebuild process (pid $BUILD_PID)..." >&2
    terminate_process_tree "$BUILD_PID"
  fi
  BUILD_PID=""
}

mkdir -p "$DIST_DIR"
log_step "Building $CONFIGURATION app (build $NEXT_BUILD_VERSION; timeout ${XCODEBUILD_TIMEOUT_SECONDS}s)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CURRENT_PROJECT_VERSION="$NEXT_BUILD_VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build &
BUILD_PID=$!
trap 'exit_status=$?; cleanup_build_process; exit "$exit_status"' INT TERM

BUILD_STARTED_SECONDS=$SECONDS
LAST_PROGRESS_SECONDS=0
while kill -0 "$BUILD_PID" 2>/dev/null; do
  elapsed_seconds=$((SECONDS - BUILD_STARTED_SECONDS))
  if (( elapsed_seconds >= XCODEBUILD_TIMEOUT_SECONDS )); then
    echo "xcodebuild timed out after ${XCODEBUILD_TIMEOUT_SECONDS}s; stopping its process tree." >&2
    terminate_process_tree "$BUILD_PID"
    wait "$BUILD_PID" 2>/dev/null || true
    BUILD_PID=""
    trap - INT TERM
    exit 124
  fi

  if (( elapsed_seconds > 0 && elapsed_seconds % 10 == 0 && elapsed_seconds != LAST_PROGRESS_SECONDS )); then
    echo "    xcodebuild still running (${elapsed_seconds}s elapsed)" >&2
    LAST_PROGRESS_SECONDS="$elapsed_seconds"
  fi
  sleep 1
done

build_status=0
if wait "$BUILD_PID"; then
  build_status=0
else
  build_status=$?
fi
BUILD_PID=""
trap - INT TERM
if (( build_status != 0 )); then
  echo "xcodebuild failed with exit code $build_status." >&2
  exit "$build_status"
fi
echo "    xcodebuild completed successfully."

PRODUCT_APP="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/ITraffic.app"
if [[ ! -d "$PRODUCT_APP" ]]; then
  echo "Build succeeded but the app bundle was not found: $PRODUCT_APP" >&2
  exit 1
fi

log_step "Copying the built app to dist/"
rm -rf "$APP_BUNDLE"
ditto "$PRODUCT_APP" "$APP_BUNDLE"

if command -v codesign >/dev/null 2>&1; then
  echo "    Applying an ad hoc signature to the dist bundle."
  codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"
fi

# Install the app into /Applications so Finder's Applications folder shows
# the freshly built version, then launch that copy.
log_step "Installing the app to $INSTALL_APP"
rm -rf "$INSTALL_APP"
ditto "$APP_BUNDLE" "$INSTALL_APP"

if command -v codesign >/dev/null 2>&1; then
  echo "    Applying an ad hoc signature to the installed bundle."
  codesign --force --deep --sign - --timestamp=none "$INSTALL_APP"
fi

mkdir -p "$(dirname "$VERSION_COUNTER_FILE")"
printf '%s\n' "$NEXT_BUILD_VERSION" > "$VERSION_COUNTER_FILE"

open_app() {
  pkill -x "ITraffic" >/dev/null 2>&1 || true
  /usr/bin/open -n "$INSTALL_APP" --args --open-dashboard
}

case "$MODE" in
  run)
    log_step "Launching the installed app"
    open_app
    echo "ITraffic updated and launched (build $NEXT_BUILD_VERSION; installed to $INSTALL_APP)"
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
    echo "ITraffic is running from $INSTALL_APP (build $NEXT_BUILD_VERSION)"
    ;;
esac
