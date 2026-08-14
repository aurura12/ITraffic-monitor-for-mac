# 免费 VPN Attribution Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve free VPN per-App attribution by combining existing proxy attribution with conservative `utun` total calibration.

**Architecture:** Add pure parsers and reconciliation functions, then run a lightweight `netstat -ib` sampler on its own queue. Feed only safe positive gaps into an unattributed bucket; preserve the current fallback whenever calibration is unavailable or inconsistent.

**Tech Stack:** Swift, Foundation, XCTest, macOS `/usr/sbin/netstat`.

## Global Constraints

- No Apple Developer Program, Network Extension entitlement, or privileged helper is required.
- Do not block the nettop runner on `netstat` or file/process I/O.
- Never distribute an unexplained total to a specific App.
- Preserve the existing `nettop + Mihomo` behavior when calibration is unavailable.
- Follow TDD: each new production behavior starts with a failing XCTest.

---

### Task 1: Add tested utun counter parsing

**Files:**
- Create: `ITrafficMonitorForMac/Service/UTunTrafficSampler.swift`
- Test: `ITrafficMonitorForMacTests/TrafficFilterTests.swift`

**Interfaces:**
- Produces `UTunInterfaceCounters`, `parseUTunInterfaceCounters(_:)`, and `utunDelta(previous:current:)`.

- [ ] **Step 1: Write failing tests** for multiple `utun` rows, unrelated interfaces, whitespace, and counter rollback.
- [ ] **Step 2: Run the focused tests** and confirm they fail because the parser/types do not exist.
- [ ] **Step 3: Implement the parser and monotonic delta calculation.**
- [ ] **Step 4: Run the focused tests** and confirm they pass.
- [ ] **Step 5: Keep the parser independent of the process sampler.**

### Task 2: Add conservative attribution reconciliation

**Files:**
- Create: `ITrafficMonitorForMac/Service/FreeAttributionCalibrator.swift`
- Test: `ITrafficMonitorForMacTests/TrafficFilterTests.swift`

**Interfaces:**
- Produces `FreeAttributionCalibration`, `calibrateFreeAttribution(entities:reference:)`, and `FreeAttributionConfidence`.

- [ ] **Step 1: Write failing tests** for positive gap, matched total, negative mismatch, and empty reference.
- [ ] **Step 2: Run focused tests** and confirm the expected failures.
- [ ] **Step 3: Implement positive-gap-only unattributed reconciliation.**
- [ ] **Step 4: Run focused tests** and confirm all calibration tests pass.
- [ ] **Step 5: Ensure output never contains negative byte counts.**

### Task 3: Integrate the sampler without blocking nettop

**Files:**
- Modify: `ITrafficMonitorForMac/Service/UTunTrafficSampler.swift`
- Modify: `ITrafficMonitorForMac/Network.swift`
- Modify: `ITrafficMonitorForMac/Store.swift`
- Modify: `ITrafficMonitorForMac/AppDelegate.swift`

**Interfaces:**
- `UTunTrafficSampler.start()` publishes the latest valid delta through a callback.
- `Network` consumes the latest snapshot without synchronous process launches.

- [ ] **Step 1: Add integration-focused tests for snapshot freshness and unavailable samples.**
- [ ] **Step 2: Run them red.**
- [ ] **Step 3: Add a timer-backed sampler using `/usr/sbin/netstat -ib` on a utility queue.**
- [ ] **Step 4: Start and stop the sampler with the app lifecycle.**
- [ ] **Step 5: Pass the latest snapshot through `Network.handleFrame` and preserve the old path when absent.**

### Task 4: Expose calibration diagnostics

**Files:**
- Modify: `ITrafficMonitorForMac/Service/FreeAttributionCalibrator.swift`
- Modify: `ITrafficMonitorForMac/Network.swift`
- Modify: `ITrafficMonitorForMac/Dashboard/SettingsView.swift`

- [ ] **Step 1: Add tests for human-readable confidence/status text.**
- [ ] **Step 2: Run them red.**
- [ ] **Step 3: Show source and calibration status in Settings without changing the existing dashboard layout.**
- [ ] **Step 4: Log mismatch and positive-gap totals to the existing diagnostic log.**
- [ ] **Step 5: Run the focused tests and verify the UI target compiles.**

### Task 5: Verify and document

**Files:**
- Modify: `CURRENT_PROGRESS.md`

- [ ] **Step 1: Run full XCTest.**
- [ ] **Step 2: Run unsigned build-for-testing and plist/entitlement checks.**
- [ ] **Step 3: Run `git diff --check`.**
- [ ] **Step 4: Record exact verification results and remaining accuracy limits.**
