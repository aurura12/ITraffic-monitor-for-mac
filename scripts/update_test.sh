#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/update.sh"

test -f "$SCRIPT"
bash -n "$SCRIPT"

grep -q 'ITrafficMonitorForMac.xcodeproj' "$SCRIPT"
grep -q 'ITrafficMonitorForMac' "$SCRIPT"
grep -q 'CODE_SIGNING_ALLOWED=NO' "$SCRIPT"
grep -q 'ITraffic.app' "$SCRIPT"
grep -q -- '--verify' "$SCRIPT"
grep -q -- '--logs' "$SCRIPT"
grep -q -- '--telemetry' "$SCRIPT"
grep -q -- '--open-dashboard' "$SCRIPT"
grep -q -- '-destination' "$SCRIPT"
grep -q 'updated and launched' "$SCRIPT"

if grep -q 'DERIVED_DATA_DIR="$DIST_DIR/DerivedData"' "$SCRIPT"; then
  echo "update.sh must keep Xcode's app products outside dist/" >&2
  exit 1
fi

echo "update.sh static checks passed"
