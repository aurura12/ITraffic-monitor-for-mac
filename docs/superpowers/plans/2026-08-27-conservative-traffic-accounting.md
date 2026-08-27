# Conservative Traffic Accounting Implementation Plan
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current additive VPN attribution path with a conservative, idempotent sample ledger that preserves raw nettop totals exactly while moving only confirmed same-window Clash bytes to Apps.

**Architecture:** Keep nettop as the sole byte producer. Add a pure bounded settlement layer for raw App rows plus the raw Clash budget and current-window API declarations. Persist each finalized frame in `traffic_samples` and `sample_allocations`; retain legacy `app_traffic` as read-only history during cutover. Remove utun calibration, proportional free attribution, foreground fallback, and cross-window proxy debt from the formal path.

**Tech Stack:** Swift, SQLite3, XCTest, Xcode project generated from `project.yml`.

**Spec:** `docs/superpowers/specs/2026-08-27-conservative-traffic-accounting-design.md`

## Global constraints

- All byte arithmetic is non-negative and checked independently for download/upload.
- Attribution declarations can consume only the current raw Clash budget.
- Never persist an allocation whose per-direction total exceeds the raw sample total.
- Preserve unrelated user changes and the existing legacy database contents.
- Use `apply_patch` for source edits and run a fresh build/test verification before claiming completion.

## Task 1: Add failing pure accounting tests

**Files:** `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift` or a new focused test file, plus the production file only after the tests fail.

- Add a test with raw App rows and a Clash row proving final totals equal raw totals in both directions.
- Add a test proving an oversized API declaration is clamped to the same-window Clash budget and the remainder is not carried.
- Add tests proving missing process/port matches and inactive foreground state leave bytes in Clash.
- Run the focused test target and confirm the new assertions fail against the old additive/debt behavior.

## Task 2: Implement bounded same-window settlement

**Files:** `ITrafficMonitorForMac/Service/ProxyAttributor.swift`, `ITrafficMonitorForMac/Network.swift`, `ITrafficMonitorForMac/Service/FreeAttributionCalibrator.swift`, `ITrafficMonitorForMac/Service/UTunTrafficSampler.swift`.

- Refactor the pure redistribution function so it consumes only the current raw Clash row and the declarations presented for that frame.
- Remove use of cumulative API/nettop histories, proxy debt, recovery credits, utun difference, proportional distribution, and foreground fallback from the persisted result.
- Preserve unmatched bytes as the Clash row and discard unused declarations at finalization.
- Remove `consumeLatestDelta()` from the formal history path; leave the sampler only if another diagnostic surface still needs it, and make its pending delta additive rather than overwrite-based if retained.
- Update `Network.handleFrame` to persist the strict final result and to report raw nettop totals without calibration gaps.

## Task 3: Add the sample ledger and idempotent commit

**Files:** `ITrafficMonitorForMac/Service/TrafficDatabase.swift`, `ITrafficMonitorForMac/Service/TrafficRecorder.swift`, and focused database tests.

- Create `traffic_samples` with a stable sample identifier, capture timestamp, bucket metadata, raw download/upload totals, and finalized state.
- Create `sample_allocations` keyed by `(sample_id, app_key)` and store every final row, including Clash remainder.
- Implement one transaction that inserts/reuses a sample, replaces allocations, and marks it finalized; repeated finalized commits are no-ops.
- Change the recorder to commit every finalized frame rather than retaining the current minute only in memory.
- Keep `app_traffic` readable for legacy history and expose a read view/union that combines legacy rows and finalized ledger rows.

## Task 4: Make history and diagnostics use the new source

**Files:** `ITrafficMonitorForMac/Service/TrafficDatabase.swift`, `ITrafficMonitorForMac/Service/TrafficRecorder.swift`, `ITrafficMonitorForMac/Network.swift`, user-facing documentation as needed.

- Update total, daily, hourly, series, and app-detail queries to include finalized ledger samples and the current minute.
- Add a conservation diagnostic query/test that compares sample raw totals with allocation totals.
- Update labels/documentation to say “nettop 非回环接口流量” (or equivalent) rather than physical network usage.
- Ensure filter/Network Extension history does not silently mark a record consumed before durable commit; preserve the same finalized-sample rule where that path is enabled.

## Task 5: Verification and cleanup

- Run focused XCTest cases for settlement and database idempotence.
- Run `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -configuration Debug -sdk macosx build-for-testing CODE_SIGNING_ALLOWED=NO` with a fresh derived-data directory.
- Run the available test command; if the host sandbox prevents XCTest runner startup, record that limitation and retain compile/build evidence without claiming tests passed.
- Inspect the final diff for forbidden accounting paths (`FreeAttributionCalibrator`, `proxyDebt`, foreground fallback, utun gap) and check `git status`.
