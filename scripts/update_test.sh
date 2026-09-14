#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/update.sh"
SETTINGS="$ROOT_DIR/ITrafficMonitorForMac/Dashboard/SettingsView.swift"

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
grep -q '已更新并启动' "$SCRIPT"
grep -q 'CURRENT_PROJECT_VERSION=' "$SCRIPT"
grep -q 'ITRAFFIC_VERSION_COUNTER_FILE' "$SCRIPT"
grep -q 'NEXT_BUILD_VERSION' "$SCRIPT"
grep -q 'CFBundleVersion' "$SETTINGS"
if grep -q 'GeneratedBuildInfo.buildNumber' "$SETTINGS"; then
  echo "SettingsView 必须显示 bundle 的 build 版本" >&2
  exit 1
fi

if grep -q 'DERIVED_DATA_DIR="$DIST_DIR/DerivedData"' "$SCRIPT"; then
  echo "update.sh 必须把 Xcode 的 app 产物放在 dist/ 之外" >&2
  exit 1
fi

echo "update.sh 静态检查通过"
