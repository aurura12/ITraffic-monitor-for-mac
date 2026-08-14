# Network Extension 逐 App VPN 流量统计实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 macOS 14+ 上新增一个只允许、不拦截的 Network Content Filter，用系统提供的源 App 标识和流量报告统计 Clash Verge 系统代理/TUN 场景下的逐 App 上下行字节。

**Architecture:** 主 App 通过 `NEFilterManager` 管理 Content Filter。Filter Data Provider 读取 `NEFilterFlow.sourceAppIdentifier` 并返回 allow，Control Provider 接收带有上下行字节的 `NEFilterReport`，按稳定 App Key 聚合到 App Group 共享容器；主 App 消费幂等序列并写入现有流量数据库。现有 `ProxyAttributor` 保留为 fallback 和 nettop 总量校验来源。

**Tech Stack:** Swift 5, macOS 14.0, NetworkExtension, System Extension, App Group container, XcodeGen, XCTest, SQLite。

## Global Constraints

- 第一阶段只观察和统计，不拦截、不修改 Clash Verge、VPN、TUN 或系统代理配置。
- 不读取或上传原始网络内容。
- Data Provider 对新 flow 和后续数据必须返回 allow。
- 主归属键使用源 App Bundle ID/稳定 App 标识，不使用 PID 或 source port 推断 App。
- 未提供源 App 标识的流量进入 `Unattributed VPN`，不得随机分配给其他 App。
- 主 App 和扩展共享同一个 App Group entitlement；扩展不得直接写主 App SQLite 数据库。
- 部署目标保持 macOS 14.0；不引入第三方网络库。
- Filter 不可用时继续使用当前 `ProxyAttributor`，并在诊断状态中标记 fallback。
- 只有验证通过后才把 Filter 统计接入正式历史写入。

## 文件结构

- Modify: `project.yml` — 增加 Data Provider、Control Provider、共享 App Group 和扩展嵌入配置。
- Modify: `ITrafficMonitorForMac/ITrafficMonitorForMac.entitlements` — 添加 Network Extension 管理权限和 App Group。
- Create: `ITrafficMonitorForMac/Service/TrafficFilterManager.swift` — 主 App 的 Filter 生命周期、授权状态和共享统计消费。
- Create: `ITrafficMonitorForMac/Service/TrafficFilterStatsStore.swift` — 共享记录的编码、读取、sequence 幂等消费。
- Create: `ITrafficMonitorForMac/NetworkFilter/DataProvider/TrafficFilterDataProvider.swift` — flow 识别、allow verdict 和统计报告配置。
- Create: `ITrafficMonitorForMac/NetworkFilter/ControlProvider/TrafficFilterControlProvider.swift` — report 聚合和 App Group 输出。
- Create: `ITrafficMonitorForMac/NetworkFilter/Shared/TrafficFilterRecord.swift` — 主 App 与扩展共用的 Codable 数据模型；该文件必须同时加入两个 target。
- Create: `ITrafficMonitorForMac/NetworkFilter/DataProvider/Info.plist` — `com.apple.networkextension.filter-data` 配置。
- Create: `ITrafficMonitorForMac/NetworkFilter/ControlProvider/Info.plist` — `com.apple.networkextension.filter-control` 配置。
- Create: `ITrafficMonitorForMac/NetworkFilter/DataProvider/TrafficFilterDataProvider.entitlements` — Data Provider 的 Network Extension 和 App Group entitlement。
- Create: `ITrafficMonitorForMac/NetworkFilter/ControlProvider/TrafficFilterControlProvider.entitlements` — Control Provider 的 Network Extension 和 App Group entitlement。
- Modify: `ITrafficMonitorForMac/AppDelegate.swift` — 启动和停止 `TrafficFilterManager`，不改变现有 nettop 启动顺序。
- Modify: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift` — 增加共享记录、sequence 幂等和字节聚合测试。
- Create: `ITrafficMonitorForMacTests/TrafficFilterTests.swift` — 增加 Filter 纯逻辑测试，避免在 XCTest 中启用真实系统 Filter。

---

### Task 1: 建立共享记录模型和纯聚合逻辑

**Files:**
- Create: `ITrafficMonitorForMac/NetworkFilter/Shared/TrafficFilterRecord.swift`
- Create: `ITrafficMonitorForMac/NetworkFilter/Shared/TrafficFilterAggregation.swift`
- Test: `ITrafficMonitorForMacTests/TrafficFilterTests.swift`
- Modify: `project.yml` — 先把共享文件加入主 App 和测试 target；扩展 target 在 Task 2 加入。

**Interfaces:**
- Produces `TrafficFilterRecord: Codable, Equatable` with `schemaVersion`, `sequence`, `timestamp`, `appKey`, `displayName`, `inBytes`, `outBytes`, `flowCount`.
- Produces `TrafficFilterAggregate` with `add(appKey:displayName:inBytes:outBytes:)` and `flush(timestamp:startingSequence:) -> [TrafficFilterRecord]`.
- Produces `TrafficFilterSequenceConsumer.consume(_:) -> [TrafficFilterRecord]`, which only returns records with a sequence greater than the last consumed sequence.

- [ ] **Step 1: Write failing tests for record round-trip and aggregation**

```swift
func testTrafficFilterRecordRoundTripsThroughJSON() throws {
    let record = TrafficFilterRecord(
        schemaVersion: 1, sequence: 7, timestamp: 100,
        appKey: "com.google.Chrome", displayName: "Google Chrome",
        inBytes: 120, outBytes: 30, flowCount: 2
    )
    let data = try JSONEncoder().encode(record)
    XCTAssertEqual(try JSONDecoder().decode(TrafficFilterRecord.self, from: data), record)
}

func testAggregateCombinesBytesByApp() {
    var aggregate = TrafficFilterAggregate()
    aggregate.add(appKey: "com.google.Chrome", displayName: "Google Chrome", inBytes: 100, outBytes: 20)
    aggregate.add(appKey: "com.google.Chrome", displayName: "Google Chrome", inBytes: 50, outBytes: 5)
    let records = aggregate.flush(timestamp: 100, startingSequence: 10)
    XCTAssertEqual(records, [TrafficFilterRecord(
        schemaVersion: 1, sequence: 10, timestamp: 100,
        appKey: "com.google.Chrome", displayName: "Google Chrome",
        inBytes: 150, outBytes: 25, flowCount: 2
    )])
}

func testSequenceConsumerDoesNotReturnDuplicateRecords() {
    let records = [TrafficFilterRecord(
        schemaVersion: 1, sequence: 3, timestamp: 100,
        appKey: "com.apple.Safari", displayName: "Safari",
        inBytes: 4, outBytes: 2, flowCount: 1
    )]
    var consumer = TrafficFilterSequenceConsumer(lastSequence: 3)
    XCTAssertTrue(consumer.consume(records).isEmpty)
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail because the types do not exist**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -sdk macosx -derivedDataPath /private/tmp/itraffic-filter-derived test -only-testing:ITrafficMonitorForMacTests/TrafficFilterTests CODE_SIGNING_ALLOWED=NO`

Expected: compilation failure naming the missing shared types.

- [ ] **Step 3: Implement the shared Codable types and deterministic aggregation**

Use `Int64` for byte counts and sequence numbers. Sort flushed records by `appKey` before assigning sequence values so tests and file output are deterministic. Ignore zero-byte additions but retain flow count only for flows with at least one byte.

- [ ] **Step 4: Implement sequence consumption**

Persist the last consumed sequence in the App Group metadata file. When records are read, sort by sequence, discard records at or below the stored sequence, return the rest, and advance the stored sequence only after the caller has accepted the records.

- [ ] **Step 5: Run the focused tests and confirm they pass**

Run the command from Step 2. Expected: all focused tests pass.

- [ ] **Step 6: Commit the isolated shared-model change**

```bash
git add project.yml ITrafficMonitorForMac/NetworkFilter/Shared ITrafficMonitorForMacTests/TrafficFilterTests.swift
git commit -m "feat: add traffic filter shared records"
```

---

### Task 2: Add Network Extension targets and entitlements

**Files:**
- Modify: `project.yml`
- Modify: `ITrafficMonitorForMac/ITrafficMonitorForMac.entitlements`
- Create: `ITrafficMonitorForMac/NetworkFilter/DataProvider/TrafficFilterDataProvider.entitlements`
- Create: `ITrafficMonitorForMac/NetworkFilter/ControlProvider/TrafficFilterControlProvider.entitlements`
- Create: `ITrafficMonitorForMac/NetworkFilter/DataProvider/Info.plist`
- Create: `ITrafficMonitorForMac/NetworkFilter/ControlProvider/Info.plist`
- Create: `ITrafficMonitorForMac/NetworkFilter/DataProvider/TrafficFilterDataProvider.swift` — placeholder provider lifecycle only.
- Create: `ITrafficMonitorForMac/NetworkFilter/ControlProvider/TrafficFilterControlProvider.swift` — placeholder provider lifecycle only.

**Interfaces:**
- Produces two buildable extension targets named `TrafficFilterDataProvider` and `TrafficFilterControlProvider`.
- Produces embedded extension bundles inside `ITraffic.app`.
- Consumes the shared records from Task 1.

- [ ] **Step 1: Add the target definitions to `project.yml`**

Define both targets with platform macOS, deployment target 14.0, Swift 5, explicit product bundle identifiers under `com.foamzou.ITrafficMonitorForMac`, the correct extension point Info.plist, entitlements paths, and the shared source path. Add both targets as dependencies of the main application so Xcode embeds them.

- [ ] **Step 2: Add entitlements and verify identifiers**

Use one exact App Group identifier, `group.com.foamzou.ITrafficMonitorForMac`, in the main App and both providers. Add the Network Extension capability appropriate to each provider. Do not add packet tunnel or app proxy capabilities.

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen generate --spec project.yml`

Expected: the generated project contains the main App, test target, Data Provider target, and Control Provider target without removing existing source files.

- [ ] **Step 4: Build all targets without installing the filter**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -sdk macosx -derivedDataPath /private/tmp/itraffic-filter-derived build CODE_SIGNING_ALLOWED=NO`

Expected: all Swift sources compile; no Filter preference is changed by the build.

- [ ] **Step 5: Commit the target and entitlement change**

```bash
git add project.yml ITrafficMonitorForMac.xcodeproj ITrafficMonitorForMac/ITrafficMonitorForMac.entitlements ITrafficMonitorForMac/NetworkFilter
git commit -m "build: add traffic content filter targets"
```

---

### Task 3: Implement the Data Provider as an allow-only observer

**Files:**
- Modify: `ITrafficMonitorForMac/NetworkFilter/DataProvider/TrafficFilterDataProvider.swift`
- Modify: `ITrafficMonitorForMac/NetworkFilter/Shared/TrafficFilterAggregation.swift`
- Test: `ITrafficMonitorForMacTests/TrafficFilterTests.swift`

**Interfaces:**
- Produces `TrafficFilterFlowMetadata` keyed by `flow.identifier` with `appKey`, display name, and creation timestamp.
- Produces an allow-only `NEFilterNewFlowVerdict` with reporting enabled.
- Consumes `NEFilterFlow.sourceAppIdentifier` and never falls back to a PID or port.

- [ ] **Step 1: Add pure tests for source-App normalization**

```swift
func testMissingSourceAppUsesUnattributedKey() {
    XCTAssertEqual(normalizedTrafficAppKey(sourceAppIdentifier: nil), "Unattributed VPN")
}

func testBundleIDIsUsedAsStableAppKey() {
    XCTAssertEqual(normalizedTrafficAppKey(sourceAppIdentifier: "com.apple.Safari"), "com.apple.Safari")
}
```

- [ ] **Step 2: Run the focused tests and confirm the normalization helper is missing**

Run the Task 1 focused test command. Expected: compilation failure for `normalizedTrafficAppKey`.

- [ ] **Step 3: Implement flow handling**

In `handleNewFlow`, normalize the optional source App identifier, store metadata by flow identifier, create `NEFilterNewFlowVerdict.allow()`, set `shouldReport = true`, and set `statisticsReportFrequency = .high`. Return allow for every flow. Do not inspect or persist payload bytes.

- [ ] **Step 4: Implement flow cleanup and provider lifecycle**

Remove metadata on inbound/outbound completion and on provider stop. On provider start, clear only in-memory flow metadata; do not delete the shared output file or the main App’s last sequence.

- [ ] **Step 5: Run the focused tests and build the Data Provider target**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -sdk macosx -derivedDataPath /private/tmp/itraffic-filter-derived test -only-testing:ITrafficMonitorForMacTests/TrafficFilterTests CODE_SIGNING_ALLOWED=NO`

Expected: tests pass and the Data Provider compiles.

- [ ] **Step 6: Commit the allow-only provider**

```bash
git add ITrafficMonitorForMac/NetworkFilter/DataProvider ITrafficMonitorForMac/NetworkFilter/Shared ITrafficMonitorForMacTests/TrafficFilterTests.swift
git commit -m "feat: add allow-only traffic filter provider"
```

---

### Task 4: Implement Control Provider reports and shared output

**Files:**
- Modify: `ITrafficMonitorForMac/NetworkFilter/ControlProvider/TrafficFilterControlProvider.swift`
- Modify: `ITrafficMonitorForMac/NetworkFilter/Shared/TrafficFilterAggregation.swift`
- Test: `ITrafficMonitorForMacTests/TrafficFilterTests.swift`

**Interfaces:**
- Produces `TrafficFilterReportAccumulator.consume(_ report: NEFilterReport)` and `flush(timestamp:) -> [TrafficFilterRecord]`.
- Produces newline-delimited JSON records in the App Group shared container.
- Consumes report flow metadata and `bytesInboundCount` / `bytesOutboundCount`.

- [ ] **Step 1: Write tests for report aggregation and unattributed traffic**

Use a pure input struct mirroring the report fields so XCTest does not require constructing framework-owned `NEFilterReport` instances:

```swift
func testReportAccumulatorSeparatesAppsAndDirections() {
    var accumulator = TrafficFilterReportAccumulator()
    accumulator.consume(ReportInput(appKey: "com.google.Chrome", displayName: "Google Chrome", inBytes: 100, outBytes: 20))
    accumulator.consume(ReportInput(appKey: "com.google.Chrome", displayName: "Google Chrome", inBytes: 50, outBytes: 5))
    let records = accumulator.flush(timestamp: 200, startingSequence: 1)
    XCTAssertEqual(records[0].inBytes, 150)
    XCTAssertEqual(records[0].outBytes, 25)
    XCTAssertEqual(records[0].flowCount, 2)
}

func testReportAccumulatorKeepsMissingAppUnattributed() {
    var accumulator = TrafficFilterReportAccumulator()
    accumulator.consume(ReportInput(appKey: "Unattributed VPN", displayName: "Unattributed VPN", inBytes: 8, outBytes: 3))
    XCTAssertEqual(accumulator.flush(timestamp: 200, startingSequence: 1).first?.appKey, "Unattributed VPN")
}
```

- [ ] **Step 2: Run the focused tests and verify the accumulator test fails**

Run the Task 1 focused test command. Expected: compilation failure for the report accumulator types.

- [ ] **Step 3: Implement report conversion and aggregation**

On `handle(_ report:)`, resolve the source App from the report flow, convert negative/unavailable counts to zero, ignore reports with zero bytes, and pass a `ReportInput` to the accumulator. Use a serial queue for accumulator state.

- [ ] **Step 4: Implement atomic shared-file writes**

Write a complete flushed batch to a temporary file in the App Group directory, then replace the published JSONL file atomically. Store the sequence counter in the same shared container. Never expose a partially written record batch to the main App.

- [ ] **Step 5: Configure provider lifecycle flushes**

Flush on the configured interval, on flow statistics reports, and before provider stop when possible. If the provider is terminated without a final flush, the next report batch remains valid and sequence monotonic.

- [ ] **Step 6: Run tests and build all extension targets**

Run the focused test command and the full build command from Task 2. Expected: all tests pass and both providers compile.

- [ ] **Step 7: Commit report aggregation**

```bash
git add ITrafficMonitorForMac/NetworkFilter/ControlProvider ITrafficMonitorForMac/NetworkFilter/Shared ITrafficMonitorForMacTests/TrafficFilterTests.swift
git commit -m "feat: aggregate traffic filter reports"
```

---

### Task 5: Manage Filter preferences and consume statistics in the main App

**Files:**
- Create: `ITrafficMonitorForMac/Service/TrafficFilterManager.swift`
- Create: `ITrafficMonitorForMac/Service/TrafficFilterStatsStore.swift`
- Modify: `ITrafficMonitorForMac/AppDelegate.swift`
- Modify: `ITrafficMonitorForMac/Service/TrafficDatabase.swift`
- Test: `ITrafficMonitorForMacTests/TrafficFilterTests.swift`

**Interfaces:**
- Produces `TrafficFilterManager.start()`, `stop()`, `reloadStatus()`, and a published filter state.
- Produces `TrafficFilterStatsStore.readNewRecords() -> [TrafficFilterRecord]` and `markConsumedThrough(sequence:)`.
- Consumes the Control Provider’s App Group output and existing database recorder APIs.

- [ ] **Step 1: Write tests for stats-store sequence consumption**

```swift
func testStatsStoreConsumesEachSequenceOnce() throws {
    let store = try TrafficFilterStatsStore(directory: temporaryDirectory())
    try store.write(records: [sampleRecord(sequence: 1), sampleRecord(sequence: 2)])
    XCTAssertEqual(try store.readNewRecords().map(\.sequence), [1, 2])
    try store.markConsumedThrough(sequence: 2)
    XCTAssertTrue(try store.readNewRecords().isEmpty)
}
```

- [ ] **Step 2: Run the focused test and confirm the manager/store types are missing**

Run the Task 1 focused test command. Expected: compilation failure for `TrafficFilterStatsStore`.

- [ ] **Step 3: Implement App Group store and atomic reads**

Resolve the App Group URL from the shared container. Read only complete JSONL lines, decode and sort by sequence, and leave malformed trailing data for the next read while logging a diagnostic. Advance the consumed sequence only after database insertion succeeds.

- [ ] **Step 4: Implement `TrafficFilterManager`**

Load `NEFilterManager.shared`, set `filterSockets = true`, leave `filterPackets = false`, set the provider bundle identifiers, save preferences, and expose states `disabled`, `authorizing`, `enabled`, `fallback`, and `error`. macOS does not support `filterBrowsers`, so browser coverage is verified through socket filtering. Do not silently enable a filter if the user has explicitly disabled attribution.

- [ ] **Step 5: Integrate startup and shutdown**

Start the manager from `AppDelegate` alongside existing monitoring. On shutdown, stop the consumer timer but do not disable a user-enabled system filter automatically. Keep existing `Network.startListenNetwork()` behavior unchanged.

- [ ] **Step 6: Add a separate Network Extension recording path**

Convert consumed `TrafficFilterRecord` values into the existing minute-bucket database format. Do not pass the same bytes through both `TrafficFilterManager` and `ProxyAttributor` in the same history write. Add a source marker so fallback and Network Extension samples can be diagnosed separately.

- [ ] **Step 7: Run tests and the full build**

Run the focused test command and the full test command:

`xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -sdk macosx -derivedDataPath /private/tmp/itraffic-filter-derived test CODE_SIGNING_ALLOWED=NO`

Expected: all tests pass. Installation and authorization are not exercised by this command.

- [ ] **Step 8: Commit main-App integration**

```bash
git add ITrafficMonitorForMac/AppDelegate.swift ITrafficMonitorForMac/Service/TrafficFilterManager.swift ITrafficMonitorForMac/Service/TrafficFilterStatsStore.swift ITrafficMonitorForMac/Service/TrafficDatabase.swift ITrafficMonitorForMacTests/TrafficFilterTests.swift
git commit -m "feat: consume traffic filter statistics"
```

---

### Task 6: Add installation status UI and diagnostic totals

**Files:**
- Modify: `ITrafficMonitorForMac/Dashboard/SettingsView.swift`
- Modify: `ITrafficMonitorForMac/Service/TrafficFilterManager.swift`
- Modify: `ITrafficMonitorForMac/Service/ProxyAttributor.swift`
- Test: `ITrafficMonitorForMacTests/TrafficFilterTests.swift`

**Interfaces:**
- Produces visible status for filter authorization, enabled/fallback/error state, last report timestamp, identified App count, and total-byte delta.
- Consumes existing diagnostic log and `ProxyAttributor` raw total samples.

- [ ] **Step 1: Add pure tests for total reconciliation**

```swift
func testTrafficTotalsReportSmallExpectedDifference() {
    let result = reconcileTrafficTotals(filterTotal: 1_000, attributedTotal: 990, unattributedTotal: 5)
    XCTAssertEqual(result.status, .withinTolerance)
}

func testTrafficTotalsReportLargeDifference() {
    let result = reconcileTrafficTotals(filterTotal: 1_000, attributedTotal: 700, unattributedTotal: 5)
    XCTAssertEqual(result.status, .mismatch)
}
```

- [ ] **Step 2: Implement reconciliation with explicit tolerance**

Use an absolute tolerance of 64 KiB plus 2% of the larger total. Return `withinTolerance`, `mismatch`, or `insufficientData`; never move the difference to a random App.

- [ ] **Step 3: Add settings status and user explanation**

Show that enabling the filter permits network-flow statistics but does not block traffic. Show a clear fallback message if the entitlement, provider, authorization, or App Group is unavailable.

- [ ] **Step 4: Run tests and inspect the UI build**

Run the full test command and build the Debug App. Expected: tests pass and the settings view compiles.

- [ ] **Step 5: Commit diagnostics and status UI**

```bash
git add ITrafficMonitorForMac/Dashboard/SettingsView.swift ITrafficMonitorForMac/Service/TrafficFilterManager.swift ITrafficMonitorForMac/Service/ProxyAttributor.swift ITrafficMonitorForMacTests/TrafficFilterTests.swift
git commit -m "feat: show traffic filter diagnostics"
```

---

### Task 7: Perform signed-device validation before enabling historical writes

**Files:**
- Modify: `ITrafficMonitorForMac/Service/TrafficFilterManager.swift` only if provider authorization requires a documented runtime adjustment.
- Modify: `docs/superpowers/specs/2026-08-14-network-extension-traffic-attribution-design.md` with measured results and limitations.

- [ ] **Step 1: Build and install the signed Debug App**

Use an Apple Development signing identity with the Network Extension entitlement and install the app in `/Applications` or the configured local test location. Do not use `CODE_SIGNING_ALLOWED=NO` for this step.

- [ ] **Step 2: Enable the Filter from the App UI**

Confirm the system authorization prompt appears, then verify the Filter state reaches `enabled`. If authorization fails, record the exact error domain/code and stop before enabling history writes.

- [ ] **Step 3: Test system proxy mode**

Generate Chrome, Safari, and VS Code traffic through Clash Verge system proxy mode. Record per-App Filter totals, nettop totals, and any `Unattributed VPN` bytes.

- [ ] **Step 4: Test TUN mode**

Switch Clash Verge to TUN mode without changing iTraffic settings. Repeat the same traffic matrix and verify source App IDs remain stable.

- [ ] **Step 5: Test UDP/QUIC and lifecycle edges**

Exercise a QUIC-capable browser request, close an active App, restart Clash Verge, and restart the Filter. Confirm no sequence is consumed twice and no stale record is attributed to a later App.

- [ ] **Step 6: Compare totals and decide rollout**

Enable formal database writes only if both proxy modes produce explainable reconciliation results. Otherwise keep the feature in diagnostic mode and preserve `ProxyAttributor` fallback.

- [ ] **Step 7: Run final verification**

Run `git diff --check`, the full XCTest command, and a signed Debug build. Record exact command output and manual observations in the design document.

---

## Final Verification Commands

```bash
xcodegen generate --spec project.yml
xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -sdk macosx -derivedDataPath /private/tmp/itraffic-filter-derived test CODE_SIGNING_ALLOWED=NO
git diff --check
```

The signed-device validation in Task 7 is mandatory before claiming exact per-App VPN accounting. A successful unsigned build only proves compilation; it does not prove entitlement, provider installation, user authorization, or TUN-mode coverage.
