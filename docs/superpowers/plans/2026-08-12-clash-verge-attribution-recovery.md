# Clash Verge Attribution Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover reliable Clash Verge detection and safe per-application attribution without guessing TUN ownership.

**Architecture:** Keep the two-second `ProxyAttributor` poll and `nettop` reconciliation. Add pure endpoint/result helpers for testable detection semantics, then update the runtime fetch path and diagnostics while preserving the existing PID retention and byte caps.

**Tech Stack:** Swift 5, Foundation, AppKit, XCTest, macOS 14.

## Global Constraints

- Do not use Network Extension or modify VPN configuration.
- Do not infer an app from destination, recency, or fuzzy process-name matching.
- Unresolved TUN traffic remains on Clash Verge.
- Preserve unrelated user changes in AppDelegate, storyboard, Info.plist, and SQLite files.

---

### Task 1: Lock down endpoint/result semantics

**Files:**
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift`
- Test: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift`

**Interfaces:**
- Produce `proxyFetchOutcome(statusCode:hasBody:hasConnections:) -> ProxyFetchOutcome`.
- Produce `proxyEndpointLabel(_:) -> String` for stable diagnostics.

- [x] **Step 1: Add failing tests** for empty connection tables being detected and non-200/transport failures being distinguishable.
- [x] **Step 2: Run the focused test and confirm the new symbols fail to compile.**
- [x] **Step 3: Implement the pure enum/helper behavior.**
- [x] **Step 4: Run the focused test and confirm it passes.**

### Task 2: Make Clash Verge detection resilient

**Files:**
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift`

**Interfaces:**
- Consume `ProxyFetchOutcome`.
- Preserve `ProxyStatus.detected(name:)` for existing UI compatibility.

- [x] **Step 1: Change fetch results so HTTP 200 with an empty `connections` array returns success.**
- [x] **Step 2: Keep trying all configured candidates after a failed Unix socket and retain the most useful failure classification.**
- [x] **Step 3: Keep the core PID JSON fallback independent from `lsof` permissions.**
- [x] **Step 4: Read Clash Verge's local controller, socket, and secret configuration without logging the secret.**
- [x] **Step 5: Run focused tests and a Debug build.**

### Task 3: Preserve safe attribution behavior

**Files:**
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift`
- Test: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift`

**Interfaces:**
- Reuse `attributedPID`, `capProxyCredit`, and `proxyDisplayName`.

- [x] **Step 1: Add tests for a detected empty table, preserved PID, and unresolved PID remaining zero.**
- [x] **Step 2: Ensure `applyDetection` resets connection history only on a real detection reset, not on an empty but valid API response.**
- [x] **Step 3: Ensure proxy name normalization still applies when no app credits are available.**
- [x] **Step 4: Run the complete test target.**

### Task 4: Verify and review

**Files:**
- No production file changes.

- [x] **Step 1: Run the focused XCTest target.**
- [x] **Step 2: Run all XCTest targets.**
- [x] **Step 3: Run the macOS Debug build.**
- [x] **Step 4: Inspect `git diff` and confirm unrelated user files remain untouched.**
