# CODEBUDDY.md

This file provides guidance to CodeBuddy Code when working with code in this repository.

## Project overview

iTraffic for macOS is a lightweight, open-source **network usage monitor**. It records total upload/download traffic over time and shows live total rates in the menu bar plus a dashboard. It is a native macOS 14+ app (SwiftUI + AppKit + Charts, raw `sqlite3` C API). There are **no Swift Package Manager dependencies**; the Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen).

Scope note: the app used to also break traffic down per App (with VPN/proxy attribution and a Network Extension). That entire subsystem was removed; **only totals are collected and shown**. Do not reintroduce per-App identity or attribution without an explicit request.

## Common commands

Prerequisites: Xcode (with command line tools), `brew install xcodegen`. macOS 14+ is required (the repo targets macOS 14.0).

Regenerate the Xcode project (required whenever `project.yml`, source files, or targets change):

```bash
xcodegen generate
```

The generated `ITrafficMonitorForMac.xcodeproj` is committed, so commit it together with the changes that required regeneration. `project.yml` is the source of truth.

Build and launch without opening Xcode (builds Release, ad-hoc signs it, installs the app to `/Applications/ITraffic.app`, and launches that copy so Finder's Applications folder shows the current build):

```bash
./scripts/update.sh
```

Useful modes (see the script header):

```bash
./scripts/update.sh --debug      # Debug build + LLDB attach
./scripts/update.sh --logs       # launch + stream app logs (`log stream`)
./scripts/update.sh --telemetry  # launch + stream iTraffic subsystem logs
./scripts/update.sh --verify     # build, launch, verify process is running
./scripts/update.sh --clean      # wipe build output (/Applications copy + dist), then build+launch
```

Sanity check for `update.sh` itself (static greps, no build):

```bash
./scripts/update_test.sh
```

The app is menu-bar-first and normally opens no window. Pass `--open-dashboard` to launch it straight into the dashboard (`update.sh` does this for you); the flag is read by `shouldOpenDashboardAtLaunch(arguments:)`.

Run the full test suite:

```bash
xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath dist/DerivedData \
  test CODE_SIGNING_ALLOWED=NO
```

Run a whole test class (the usual choice when working on the DB layer):

```bash
xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath dist/DerivedData \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:ITrafficMonitorForMacTests/TrafficRollupTests
```

Run a single test:

```bash
xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath dist/DerivedData \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:ITrafficMonitorForMacTests/TrafficRollupTests/testRollupPreservesTotalsOverRange
```

Derived data is intentionally **not** shared between the two paths: the test commands above use `dist/DerivedData`, while `update.sh` builds in `${TMPDIR}/ITrafficMonitorForMac/DerivedData` so the app product never lands inside the gitignored `dist/`. `scripts/update_test.sh` asserts that `update.sh` keeps using the `TMPDIR` path — do not "unify" these two.

Notes on signing: this repo has **no Apple Developer Team configured**. `xcodebuild` runs with `CODE_SIGNING_ALLOWED=NO`, and `update.sh` then ad-hoc signs the bundle (`codesign --force --deep --sign -`) and copies it to `/Applications/ITraffic.app`. In Xcode you run with "Sign to Run Locally". Do not require real signing for normal build/test/dev work. Only a signed Network Extension would need a team — and that subsystem no longer exists.

`update.sh` also auto-increments the build number: it reads `.itraffic-build-number` (or `ITRAFFIC_VERSION_COUNTER_FILE`), passes `CURRENT_PROJECT_VERSION=<n+1>` to `xcodebuild`, and writes the new value back. `MARKETING_VERSION` is bumped manually in `project.yml`. Other knobs: `ITRAFFIC_XCODEBUILD_TIMEOUT_SECONDS` (default 900) caps the `xcodebuild` run, and `ITRAFFIC_BUILD_COUNTER_DIR` relocates the pre-build script's counter (see Pitfalls) — it is the only way to make that counter survive a clean.

There is no linter or CI configuration in the repo.

## Code layout

- `ITrafficMonitorForMac/` — app target (module name `ITraffic`, bundle id `com.foamzou.ITrafficMonitorV2`)
  - Root: `AppDelegate.swift` (entry point; under tests it stops after the `AppEnvironment.isRunningTests` guard and starts nothing), `Network.swift` (nettop frame → totals pipeline; the quote-aware CSV parser is kept as pure top-level functions), `Store.swift` (`SharedStore` singleton registry + SwiftUI environment objects), `MenuBar.swift`, `Utils.swift` (`AppEnvironment`, byte formatters, the bounded subprocess runner, local day-index helpers), `GeneratedBuildInfo.swift` (auto-generated by a build script phase; do not edit)
  - `Model/` — `StatusDataModel.swift` (live totals + `TrafficSamplingDiagnostics`, `NettopSamplingStatus`, `TrafficCounters`), `RealtimeRateStore.swift` (2s ring buffer), `LocalizationManager.swift`
  - `Dashboard/` — `DashboardView.swift` (the window root that owns the view model and locale injection), `UnifiedDashboardView.swift`, `DashboardViewModel.swift`, `Theme.swift`, `SettingsView.swift`, `ExportView.swift`, and the three chart files `TrafficLineChart.swift` / `TrafficBarChartView.swift` / `TrafficCalendarHeatmap.swift` (each carries the extracted geometry helpers described under Pitfalls)
  - `Service/` — `NettopRunner.swift`, `TrafficRecorder.swift`, `TrafficDatabase.swift`
  - `Base.lproj/Main.storyboard` + `Info.plist` — `NSMainStoryboardFile=Main` and `LSUIElement=true`; the **app menu** (About, Preferences… ⌘,, Hide, Quit) lives in the storyboard, not in Swift, and `AppDelegate.swift` rewires the Preferences item's target at runtime. The status item's own right-click context menu is the opposite case — it is built in Swift in `MenuBarController.makeContextMenu()`.
- `ITrafficMonitorForMacTests/` — unit test target, hosted inside the app (`@testable import ITraffic`), 80 cases in three classes:
  - `TrafficBarHoverTests` (61) — mostly the **chart geometry/format pure functions** (axis ticks, label widths and offsets, bar positions, tooltip placement, heatmap thresholds/levels, hover selection), plus the menu-bar value types, nettop CSV parsing, process-helper timing, launch-at-login, and the dashboard refresh plan.
  - `TrafficFilterTests` (3) — nettop sampling status transitions and menu-bar rate text.
  - `TrafficRollupTests` (16) — DB-level minute rollup, chunked backfill, the per-App-removal migration, and the guard that keeps a test run out of the production database.
- `scripts/update.sh` — build/run script described above; `scripts/update_test.sh` is a static-grep self-check of that script (no build), asserting the flags/bounds the script is expected to keep.
- Docs: `CURRENT_PROGRESS.md` (current state, Chinese), `FEATURES.md` (feature list, Chinese), `README.md` (English, user-facing), `TROUBLESHOOTING.md` (Chinese post-mortem of the macOS 26 menu-bar incident — the primary evidence behind the bundle-ID pitfall below), `docs/superpowers/{plans,specs}/` (dated specs, mostly the **removed** per-App/VPN work, kept as history). **`PLAN.md` is stale** — it still describes a deleted `TrafficHeatmap.swift` and a per-App `heatmap(start:end:)` API; the file is now `TrafficCalendarHeatmap.swift` with a different API. Do not treat it as current.

## Runtime data flow

1. `AppDelegate.applicationDidFinishLaunching` sets an `.accessory` activation policy, creates `MenuBarController` + `Network()`, and calls `Network.startListenNetwork()`. Under a test host it returns immediately (see Pitfalls).
2. `NettopRunner` (Service/NettopRunner.swift) spawns the system `nettop` wrapped in `/usr/bin/script -q /dev/null` for a pseudo-TTY (both the TTY wrapper and keeping stdin open are deliberate anti-CPU-spin mitigations — do not remove). Command: `/usr/bin/nettop -P -d -L 0 -J bytes_in,bytes_out -t external -s 2 -c`. It drops the first cumulative frame after each spawn (only delta frames are real) and detects frame boundaries with a 0.35 s read-idle debounce.
3. `Network.handleFrame` parses each CSV line into its two byte columns (`Network.parser`), skips the reprinted header, and **sums the frame's download/upload bytes**. Rows that fail to parse are counted in `TrafficSamplingDiagnostics.droppedNettopRows` (their bytes are missing from the totals).
4. `TrafficRecorder.record(sampleID:capturedAt:rawInBytes:rawOutBytes:)` persists one sample on a serial queue and triggers a rollup when the minute changes.
5. Live UI: total rates → `StatusDataModel` and rate history → `RealtimeRateStore`, both on the main thread.

There is no per-process/per-app identity work anywhere in this path.

## Data model / persistence

`TrafficRecorder` → `TrafficDatabase` (thin, serialized wrapper over the raw sqlite3 C API; all DB access happens on a dedicated queue). Key schema invariants:

- `traffic_samples` (`sample_id` PK = idempotency key, `captured_at_ms`, `bucket_start`, `day`, `hour`, `raw_in_bytes`, `raw_out_bytes`, `finalized`) is the **live frame ledger** and the **only byte source**. Replaying a frame is a no-op.
- `finalized` is a **two-phase write, not a plain flag**: `commitSample` runs `INSERT ... finalized=0`, re-reads the row to confirm the stored bytes match, then `UPDATE ... finalized=1`, all inside one transaction. Nothing that sees `finalized = 1` can ever observe a half-written sample. Preserve this if you touch `commitSampleLocked`.
- `traffic_totals` (`bucket_start` PK = rowid alias, `day`, `hour`, `in_bytes`, `out_bytes`, `sample_count`) holds completed minute buckets.
- `TrafficRecorder` sweeps completed buckets via `TrafficDatabase.rollupCompletedBuckets(before:)`, which in one transaction aggregates `traffic_samples.raw_*` into `traffic_totals`, tombstones the swept `sample_id`s in `archived_samples` (so a replayed frame stays a no-op), prunes tombstones older than 7 days, then deletes the samples. The current minute stays live in the ledger.
- **There are two independent rollup paths.** The per-minute trigger is `rollUpIfNeeded`, which fires from `record` on the recorder's serial queue. Separately, `TrafficRecorder.init` starts `startBackfill`, which sweeps whatever a *previous* run left in the ledger in 60-bucket transactions on its own queue, retrying transient `SQLITE_BUSY`/I/O errors. Don't conflate them when reasoning about when a bucket becomes queryable.
- All dashboard/history reads go through the `accounted_traffic` view = `traffic_totals UNION ALL` the still-live finalized `traffic_samples.raw_*`. A rollup must be **query-transparent** — that is what `TrafficRollupTests` asserts.
- Dates are stored as local-day indices (`day`, local days since 1970-01-01) computed in Utils.swift via Calendar — don't replace with naive `timeInterval / 86400` math (off-by-one in negative-offset timezones).
- SQLite has no `start of hour` modifier, so the hourly series groups by a local calendar-hour key (`hourSeriesSQL`): `GROUP BY strftime('%Y-%m-%d %H', bucket_start, 'unixepoch', 'localtime')` and takes `MIN(bucket_start)` as the chart point's date. Follow the same "local calendar key + earliest bucket as anchor" pattern for any new time granularity.

### Schema migration

`TrafficDatabase.migrate()` runs `createCoreTables()`, then `migrateArchivedSamplesTimestamp()`, then `migratePerAppRemovalIfNeeded()` — gated by `PRAGMA user_version` (`currentSchemaVersion = 2`). A legacy database (has `app_traffic`, version < 2) folds `app_traffic` per bucket into `traffic_totals` (`SUM(MAX(0, in_bytes))`, so the retired negative clamp is absorbed; a per-bucket `NOT EXISTS` guard makes the fold idempotent), drops `app_traffic`/`apps`/`sample_allocations`, rebuilds the `accounted_traffic` view, and bumps the version — all in **one transaction**, with a one-time `VACUUM INTO` backup first. A failure rolls everything back and retries next launch, leaving the legacy schema *and its app-keyed view* readable. New installs start on the total-only schema at version 2.

**The view rebuild must stay inside that transaction, after the fold.** Replacing the legacy app-keyed view with the total-only definition *before* `traffic_totals` has been filled makes every history read return zero — while the data on disk is intact and `user_version` is unchanged, so it looks like "the migration never ran" and keeps returning zero across restarts. This was a real bug; `testFailedPerAppRemovalKeepsLegacyHistoryReadable` is the regression test (it aborts the fold with a trigger and asserts history is still readable). The already-migrated path re-asserts the view definition idempotently, which is safe because it has no pending fold.

## UI

- Menu-bar status item (`MenuBar.swift`) embeds live ↑/↓ **total** rate text; the popover shows today's download/upload/total and menu items (open dashboard/settings, pause, quit). The small value type `MenuBarRateText` is extracted and unit-tested.
- Dashboard (`Dashboard/`) is a single window rendering `UnifiedDashboardView` (no tab bar, no ranking table): a `ChartMode` picker (Line / Heatmap / Usage) plus a `TimeRange` picker (Today / 7 Days / 30 Days, hidden outside Line mode) drive stat cards and the chart. Line mode adds `TimeRange`-scoped cards; Heatmap shows 365 days; Usage is an all-history bar chart with `BarGranularity`. Settings and CSV/JSON `ExportView` are separate windows/sheets. Queries are async passthroughs on `TrafficRecorder`; `DashboardViewModel` maps each `ChartMode` to a prioritized `DashboardRefreshPlan` and uses sequence tokens to discard stale async results.
- **Environment-object injection is a chain, and the middle link is easy to miss.** `AppDelegate.showDashboard()` builds `DashboardView().withGlobalEnvironmentObjects()`; the `withGlobalEnvironmentObjects()` helper in `Store.swift` injects the three `SharedStore` singletons plus `LocalizationManager.shared`; `DashboardView` then adds its own `@StateObject DashboardViewModel` and `.environment(\.locale, i18n.locale)`. So `UnifiedDashboardView` **cannot run on its own** — it reads `@EnvironmentObject` values (`viewModel`, `i18n`, `realtimeRateStore`) that only exist because `DashboardView` supplied them. Add new windows via the same `DashboardView().withGlobalEnvironmentObjects()` shape.
- Export is **total-only**: CSV `period,in_bytes,out_bytes,total_bytes`; JSON records with `period/inBytes/outBytes/totalBytes`.
- All user-facing strings go through `L()` / `LocalizationManager.text(_:)`, keyed by the English string with a zh-Hans dictionary in `LocalizationManager.swift`. Add new strings there (English key + Chinese value); missing keys fall back to English. App language and appearance persist in `UserDefaults`.

## Pitfalls & conventions

- Versions and bundle settings live in `project.yml`; bump `MARKETING_VERSION` there and regenerate. `CURRENT_PROJECT_VERSION` is normally driven by `update.sh`'s `.itraffic-build-number` counter, while the Xcode pre-build script writes a separate `GeneratedBuildInfo.buildNumber` from its own counter. That second counter is monotonic **only within one DerivedData directory** (it defaults to `${ITRAFFIC_BUILD_COUNTER_DIR:-${DERIVED_FILE_DIR:-…}}`), so `update.sh --clean` resets it; set `ITRAFFIC_BUILD_COUNTER_DIR` if you need it to survive cleaning.
- **Testability comes from file-scope pure functions, not from view tests.** The chart and menu-bar files deliberately keep their geometry, formatting and hit-testing logic in free functions at file scope (`trafficXAxisStrideCount`, `trafficBarXAxisTickLabelWidth`, `heatmapThresholds`, `tooltipPosition`, `nearestTrafficBarIndex`, …) instead of inside the `View` structs. That is what lets 61 cases run with no view, no `SharedStore` and no nettop. When you add chart or menu-bar behavior, extract a pure function in the same file and test that — do not reach for view inspection.
- `ITrafficMonitorForMac.entitlements` still exists on disk and still lists the retired `com.apple.developer.networking.networkextension` (content-filter-provider) entitlement plus the app group, but `project.yml` excludes it from sources and the target sets **no** `CODE_SIGN_ENTITLEMENTS`. It is inert. Do not wire it back up: the app is ad-hoc signed, and a Network Extension entitlement would require a real Apple Developer team.
- `GeneratedBuildInfo.swift` is overwritten by a pre-build script phase every build — never edit or commit manual changes to it (it is gitignored).
- The app bundle ID (`PRODUCT_BUNDLE_IDENTIFIER: com.foamzou.ITrafficMonitorV2` in `project.yml`) is **load-bearing — do not change it**. macOS 26's Control Center put the old `com.foamzou.ITrafficMonitorForMac` ID on its internal blocked list and stopped rendering the status item regardless of the in-app toggle or app code; moving to a fresh ID was the fix. `TROUBLESHOOTING.md` holds the full post-mortem and the log signatures that identify this failure. Status persistence (App Group `group.com.foamzou.ITrafficMonitorForMac`, DB dir `~/Library/Application Support/ITraffic`) intentionally kept the old strings and must stay put.
- `backupBeforePerAppRemoval()` writes a `VACUUM INTO` snapshot next to the database and prunes older `*.pre-perapp-removal-*.bak` files, keeping only the newest — a repeatedly failing fold would otherwise accumulate a ~40 MB snapshot per launch. Other `.bak` files in that directory are historical and are **not** touched; do not delete the user's backups without asking.
- `archived_samples` tombstones are pruned after 7 days while the frame ledger is swept continuously, so the one-shot migration backup is the only snapshot of pre-migration history — and since per-App removal, `traffic_totals` is the only history source. Copies the user made by hand (`traffic.sqlite3.bak-*`) are not managed by any code.
- **Tests run inside the app process.** The unit-test bundle is hosted by the real app, so `applicationDidFinishLaunching` runs on every `xcodebuild test`. `AppEnvironment.isRunningTests` makes the app return before starting nettop/UI, and `TrafficDatabase.open()` falls back to a per-process temp database for the no-URL default under tests — so a test run cannot touch `~/Library/Application Support/ITraffic/traffic.sqlite3`. Any new startup code (services, timers, subprocesses, DB access, notifications) must sit behind that guard or use an injected URL.
- Do not describe the app as per-App: only total byte conservation is guaranteed, and `nettop -t external` includes LAN/multicast traffic (it is "all non-loopback interfaces", not "WAN only").
- Version history is in English-commit-message form on `main`; single-developer project, docs are a mix of English (code comments, README, CODEBUDDY) and Chinese (CURRENT_PROGRESS, FEATURES).
