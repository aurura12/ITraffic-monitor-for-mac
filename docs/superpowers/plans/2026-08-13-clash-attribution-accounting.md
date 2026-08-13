# Clash Attribution Accounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Clash Verge proxy attribution conservative and exactly-once: traffic is assigned to an application only when the corresponding proxy bytes are visible in the same `nettop` accounting window; otherwise it remains on Clash Verge without being duplicated.

**Architecture:** Keep the existing two-second Clash/Mihomo polling and `nettop` sampling, but separate connection discovery, PID resolution, and byte settlement. API byte deltas become pending candidates; they are consumed only after a matching proxy entity is observed and capped by that entity's raw bytes. Missing API data, PID mismatches, and sampling phase gaps become explicit diagnostic states rather than implicit application credits.

**Tech Stack:** Swift, AppKit, Foundation `Process`, macOS `nettop`, `lsof`, Clash/Mihomo HTTP/Unix-socket API, XCTest, SQLite history.

## Global Constraints

- Do not modify Clash Verge, VPN, TUN, system proxy, or network settings.
- Do not infer application ownership from domain, destination, recency, or fuzzy application names.
- Do not add API bytes to an application when the proxy entity is absent from the raw `nettop` frame.
- Preserve existing unrelated working-tree changes.
- Do not rewrite historical SQLite traffic automatically; old buckets may contain already-duplicated or unattributed data and must be labeled as pre-fix data during validation.

## Root-Cause Findings To Encode

1. `9097` is not listening because this Clash Verge instance is configured with `external-controller-unix`; lack of a TCP listener is not itself an error.
2. The implementation can resolve the core PID from `clash-verge-service.core.json`, while `nettop` may expose a different proxy-process PID. The current exact `proxyPid` comparison then treats the proxy entity as absent.
3. When `proxyVisible == false`, `capProxyCredit` returns the requested API delta, but no raw proxy row is reduced. This can create traffic from nothing and/or leave the original Clash bytes intact.
4. `consumedCredits` is built by reducing `creditedIn`; PIDs with upload-only credits are not consumed, allowing pending upload credits to be replayed.
5. Direction deltas are not clamped independently. A negative download delta can be added when upload is positive, corrupting the pending balance after connection resets or API counter changes.

## File Map

- Modify `ITrafficMonitorForMac/Service/ProxyAttributor.swift`: settlement state machine, diagnostics, safe PID/proxy-row matching, per-direction delta handling.
- Modify `ITrafficMonitorForMac/Network.swift`: pass raw-frame context only through the existing attribution boundary; keep total interface rates based on raw `nettop` bytes.
- Modify `ITrafficMonitorForMac/Dashboard/SettingsView.swift`: expose actionable attribution status (detected, waiting for proxy row, API/auth failure) without exposing the secret.
- Modify `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift` or add a focused attribution test file if the project target permits it: pure settlement and delta tests.
- Add `docs/superpowers/specs/2026-08-13-clash-attribution-accounting-design.md`: behavior contract and diagnostic meanings.

### Task 1: Specify and test the accounting invariant

**Files:**
- Create: `docs/superpowers/specs/2026-08-13-clash-attribution-accounting-design.md`
- Test: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift` or a new `ITrafficMonitorForMacTests/ProxyAttributionTests.swift`

**Interfaces:**
- Produce pure helpers for settlement decisions, with explicit inputs for raw proxy visibility, raw proxy bytes, pending application credits, and the resolved proxy identity.

- [ ] **Step 1: Write failing tests for the invariants.**

  Cover these cases:

  ```swift
  // No proxy row: no application credit is emitted.
  XCTAssertEqual(settleProxyCredits(pending: [42: (100, 20)], proxy: nil), .none)

  // Visible proxy row: each direction is capped independently.
  XCTAssertEqual(settleProxyCredits(pending: [42: (100, 20)], proxy: (30, 50)),
                 .credit(pid: 42, inBytes: 30, outBytes: 20, proxyInRemaining: 0, proxyOutRemaining: 30))

  // Upload-only credits are consumed.
  XCTAssertEqual(creditKeys(in: [:], out: [42: 20]), [42])

  // Counter reset cannot generate negative traffic.
  XCTAssertEqual(nonNegativeDelta(current: 5, previous: 10), 0)
  ```

- [ ] **Step 2: Run the focused tests and verify they fail for the current implementation.**

  Run:

  ```bash
  xcodebuild -project ITrafficMonitorForMac.xcodeproj \
    -scheme ITrafficMonitorForMac \
    -sdk macosx \
    -derivedDataPath /tmp/itraffic-attribution-tests \
    CODE_SIGNING_ALLOWED=NO test
  ```

  Expected: the new invariant tests fail before implementation.

- [ ] **Step 3: Document the accounting contract.**

  State that one raw proxy byte can have exactly one destination: either it remains on Clash Verge or it is transferred to a verified application. API byte counters are evidence for distribution, never an independent source of total traffic.

- [ ] **Step 4: Commit the test/spec checkpoint.**

  ```bash
  git add docs/superpowers/specs/2026-08-13-clash-attribution-accounting-design.md ITrafficMonitorForMacTests
  git commit -m "test: define exact proxy attribution settlement"
  ```

### Task 2: Make byte settlement safe and exactly-once

**Files:**
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift:29-415,785-817`
- Test: attribution invariant tests from Task 1

**Interfaces:**
- Consume: pure settlement helpers from Task 1.
- Produce: a settlement result that includes application credits, proxy bytes remaining, and consumed pending credits.

- [ ] **Step 1: Clamp connection deltas independently.**

  In `applyDetection`, calculate:

  ```swift
  let dIn = max(0, conn.download - prevConn.downloadTotal)
  let dOut = max(0, conn.upload - prevConn.uploadTotal)
  ```

  Only positive directions enter pending credits.

- [ ] **Step 2: Remove the unsafe absent-proxy fallback.**

  Change the settlement rule so `proxyIndex == nil` produces no application credits and does not consume pending credits. The raw frame is returned unchanged. Record a diagnostic reason such as `proxyRowMissing`.

- [ ] **Step 3: Consume the union of both credit maps.**

  Replace the `creditedIn.reduce`-only construction with the union of `creditedIn.keys` and `creditedOut.keys`, preserving both directions for every PID. Consume exactly the scaled amount actually emitted in this frame.

- [ ] **Step 4: Keep the proxy cap direction-specific.**

  For a visible proxy row, cap incoming application credits by `proxyIn` and outgoing credits by `proxyOut`; subtract exactly the emitted amount from the proxy entity. Do not subtract application credits from any other entity.

- [ ] **Step 5: Add a bounded pending-credit policy.**

  Store the poll/frame age for pending credits. If no proxy row is observed for a bounded number of sampling windows, retain the bytes on Clash Verge and discard the pending application candidate with a diagnostic event. This prevents unbounded memory growth and prevents a stale credit from being applied minutes later to unrelated traffic.

- [ ] **Step 6: Run focused tests and the macOS build.**

  ```bash
  xcodebuild -project ITrafficMonitorForMac.xcodeproj \
    -scheme ITrafficMonitorForMac \
    -sdk macosx \
    -derivedDataPath /tmp/itraffic-attribution-tests \
    CODE_SIGNING_ALLOWED=NO test
  ```

  Expected: all tests pass and the target builds successfully.

- [ ] **Step 7: Commit the settlement fix.**

  ```bash
  git add ITrafficMonitorForMac/Service/ProxyAttributor.swift ITrafficMonitorForMacTests
  git commit -m "fix: prevent duplicate proxy attribution"
  ```

### Task 3: Make proxy identity and failure modes observable

**Files:**
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift`
- Modify: `ITrafficMonitorForMac/Dashboard/SettingsView.swift`
- Modify: `ITrafficMonitorForMac/Model/LocalizationManager.swift`
- Test: attribution tests

**Interfaces:**
- Produce diagnostics containing endpoint type, last fetch outcome, connection count, mapped connection count, resolved core PID, raw proxy-row PID, and last settlement reason. Never include the secret.

- [ ] **Step 1: Add explicit diagnostic state.**

  Distinguish at least:

  ```swift
  .detected(name: String)
  .detectedWaitingForProxyRow(name: String)
  .apiUnavailable(endpoint: String)
  .authRequired(endpoint: String)
  .detectedNoMappedConnections(name: String, connectionCount: Int)
  ```

- [ ] **Step 2: Record identity mismatch separately from API failure.**

  When the API succeeds but the raw frame contains no matching proxy row, report `proxyRowMissing`; do not report `notDetected` or `apiUnavailable`.

- [ ] **Step 3: Show actionable status in Settings.**

  Keep the compact current status, but add a diagnostic line explaining whether Clash is detected, waiting for a matching nettop row, unauthorized, or unreachable.

- [ ] **Step 4: Test status transitions without secrets.**

  Add pure tests for HTTP 200 empty connections, 401/403, transport failure, and successful API + missing raw proxy row.

- [ ] **Step 5: Build and commit.**

  ```bash
  xcodebuild -project ITrafficMonitorForMac.xcodeproj \
    -scheme ITrafficMonitorForMac \
    -sdk macosx \
    -derivedDataPath /tmp/itraffic-attribution-tests \
    CODE_SIGNING_ALLOWED=NO test
  git add ITrafficMonitorForMac ITrafficMonitorForMacTests
  git commit -m "feat: expose proxy attribution diagnostics"
  ```

### Task 4: Validate against the real Clash Verge + Chrome scenario

**Files:**
- No source changes expected; use the running application and local SQLite database.

- [ ] **Step 1: Capture a clean baseline.**

  Record the current timestamp, Clash Verge download rate, Chrome proxy sockets, and the latest SQLite bucket totals. Do not reset or delete the existing database.

- [ ] **Step 2: Observe at least five consecutive sampling windows while Chrome is actively downloading.**

  Verify that each window satisfies:

  ```text
  raw_total_in >= sum(application_credits_in) + proxy_remaining_in
  raw_total_out >= sum(application_credits_out) + proxy_remaining_out
  ```

  Exact equality is expected when all relevant rows are visible; inequality is acceptable only for traffic excluded by the `nettop` filter.

- [ ] **Step 3: Force a harmless Clash core restart through the user’s normal Clash Verge UI.**

  Observe that the app transitions to a diagnostic waiting/detected state, re-discovers the new PID/socket, and does not duplicate bytes across the restart boundary.

- [ ] **Step 4: Test a non-browser proxied app.**

  Confirm that VSCode or another active proxy client is attributed separately from Chrome, while unresolved traffic remains on Clash Verge.

- [ ] **Step 5: Validate historical behavior separately.**

  Compare only buckets created after the fix. Do not use the existing multi-day Clash total as a correctness oracle because it predates the exact-once settlement rules.

- [ ] **Step 6: Record final evidence.**

  Save the command outputs and the observed status transitions in the design/spec notes; report any remaining limitation, especially TUN traffic without reliable process metadata.

## Self-Review Checklist

- The plan never credits an application when the proxy row is absent.
- Upload-only credits are consumed and cannot replay.
- Counter resets cannot create negative credits.
- API failure, PID mismatch, and unresolved ownership are distinguishable.
- Historical data is not silently rewritten.
- The real validation includes Chrome, another proxied application, and a Clash core restart.
