# Clash Verge Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attribute confirmed Clash Verge/Mihomo connections to real apps and display remaining proxy traffic as Clash Verge.

**Architecture:** Keep the current two-second Mihomo connection poll and `nettop` reconciliation. Extract pure attribution and proxy-name helpers so unit tests demonstrate the rules; `ProxyAttributor` retains an already confirmed PID per connection and uses the helpers when distributing each frame.

**Tech Stack:** Swift 5, Foundation, AppKit, XCTest, Xcode project.

## Global Constraints

- Target macOS 13.0 and use only existing Apple frameworks.
- Do not use Network Extension, content filters, additional entitlement, or VPN configuration changes.
- Do not infer an app from domain, recent activity, or a fuzzy process-name match.
- A connection without a verified PID remains proxy traffic and is shown as `Clash Verge`.
- Do not include pre-existing changes in `AppDelegate.swift`, `Main.storyboard`, `Info.plist`, or SQLite files in commits.

---

### Task 1: Test and add pure proxy attribution helpers

**Files:**
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift`
- Modify: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift`

**Interfaces:**
- Produces: `proxyDisplayName(rawName:isClashVerge:) -> String`
- Produces: `attributedPID(previousPID:resolvedPID:) -> Int`

- [ ] **Step 1: Write failing tests**

```swift
func testClashVergeCoreUsesClashVergeDisplayName() {
    XCTAssertEqual(proxyDisplayName(rawName: "verge-mihomo", isClashVerge: true), "Clash Verge")
}

func testExistingConnectionRetainsConfirmedPIDWhenLookupLaterFails() {
    XCTAssertEqual(attributedPID(previousPID: 456, resolvedPID: 0), 456)
}

func testMissingNewConnectionPIDRemainsUnassigned() {
    XCTAssertEqual(attributedPID(previousPID: 0, resolvedPID: 0), 0)
}
```

- [ ] **Step 2: Run the focused test target and verify the tests fail because the helper functions do not exist**

```bash
xcodebuild test -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -destination 'platform=macOS' -only-testing:ITrafficMonitorForMacTests/TrafficBarHoverTests
```

- [ ] **Step 3: Implement the minimal helpers**

```swift
func proxyDisplayName(rawName: String, isClashVerge: Bool) -> String {
    isClashVerge ? "Clash Verge" : rawName
}

func attributedPID(previousPID: Int, resolvedPID: Int) -> Int {
    previousPID > 0 ? previousPID : resolvedPID
}
```

- [ ] **Step 4: Run the same focused test target and verify it passes**

- [ ] **Step 5: Commit only the helper implementation and tests**

```bash
git add ITrafficMonitorForMac/Service/ProxyAttributor.swift ITrafficMonitorForMacTests/TrafficBarHoverTests.swift
git commit -m "test: cover Clash Verge attribution helpers"
```

### Task 2: Preserve confirmed ownership and normalize the proxy entity

**Files:**
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift:186-262`
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift:294-335`
- Modify: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift`

**Interfaces:**
- Consumes: `proxyDisplayName(rawName:isClashVerge:) -> String`
- Consumes: `attributedPID(previousPID:resolvedPID:) -> Int`
- Produces: `ProxyAttributor.attributedEntities(_:)` which leaves unassigned byte deltas on a proxy entity named `Clash Verge`.

- [ ] **Step 1: Use `attributedPID` while rebuilding each tracked connection**

When a connection ID had a prior positive PID, store that PID in `newPrevious`; otherwise resolve the new connection through source port and Mihomo metadata. Do not replace a confirmed PID with a later port lookup, which prevents port reuse from producing a false owner.

- [ ] **Step 2: Normalize the detected Clash Verge proxy entity name**

Store whether the detected candidate is Clash Verge alongside its proxy PID. In `attributedEntities(_:)`, set that raw proxy entity's name through `proxyDisplayName`. Remove the TUN-only label replacement: byte deltas with no confirmed PID remain on the normalized proxy entity.

- [ ] **Step 3: Run focused and full verification**

```bash
xcodebuild test -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -destination 'platform=macOS' -only-testing:ITrafficMonitorForMacTests/TrafficBarHoverTests
xcodebuild test -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -destination 'platform=macOS'
xcodebuild build -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -configuration Debug
```

- [ ] **Step 4: Commit only attribution code and tests**

```bash
git add ITrafficMonitorForMac/Service/ProxyAttributor.swift ITrafficMonitorForMacTests/TrafficBarHoverTests.swift
git commit -m "fix: attribute unresolved Mihomo traffic to Clash Verge"
```
