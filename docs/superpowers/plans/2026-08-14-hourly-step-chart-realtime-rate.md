# 每小时阶梯流量图与实时网速 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保留每小时流量增量，用阶梯线准确表达每个小时的值，并在首页显示实时下载/上传速度。

**Architecture:** 历史数据继续由 `DashboardViewModel` 查询并以小时/天增量提供给 `TrafficLineChart`；图表只改变插值方式，不把增量转换为累计值。首页从共享的 `RealtimeRateStore` 读取最新 bytes/s 样本，新增独立速率卡片，不改变数据库和采集链路。

**Tech Stack:** Swift 5, SwiftUI, Swift Charts, XCTest, macOS 14+

## Global Constraints

- 保留数据库返回的每小时/每日增量口径。
- 使用 Swift Charts 阶梯插值，避免跨时间桶斜线。
- 实时网速复用已有 `RealtimeRateStore`，无新增数据库字段。
- 没有实时样本时显示 `0 KB/s`。

---

### Task 1: Lock down hourly increment data behavior

**Files:**
- Modify: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift`
- Reference: `ITrafficMonitorForMac/Dashboard/DashboardViewModel.swift`

**Interfaces:**
- Consumes: `hourlySeriesPoints(points:start:calendar:)`
- Produces: XCTest coverage proving a full Today series remains 24 hourly increment points, including zero-filled hours.

- [ ] **Step 1: Write the failing test**

Add a test that passes traffic in hours 1 and 3, calls `hourlySeriesPoints`, and asserts 24 points, exact hour starts, preserved per-hour values, and zeroes in hour 0/2. The test must also assert hour 3 is its own increment rather than a cumulative sum.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -destination 'platform=macOS' test -only-testing:ITrafficMonitorForMacTests/TrafficBarHoverTests/testHourlySeriesKeepsPerHourIncrements`

Expected: FAIL because the new test is not yet present or the exact behavior is not covered; fix only test setup errors until the assertion fails for the intended missing behavior.

- [ ] **Step 3: Keep the minimal existing implementation**

Do not change production data aggregation if the test confirms the existing 24-point increment behavior. If needed, make only the smallest correction to `hourlySeriesPoints` so each normalized hour maps to the original bucket totals without accumulating values.

- [ ] **Step 4: Run the focused test to verify it passes**

Run the same `xcodebuild ... -only-testing` command and expect PASS.

- [ ] **Step 5: Commit when Git metadata is writable**

Run: `git add ITrafficMonitorForMacTests/TrafficBarHoverTests.swift ITrafficMonitorForMac/Dashboard/DashboardViewModel.swift && git commit -m "test: cover hourly traffic increments"`

If the environment still rejects `.git/index.lock`, leave the working tree intact and report the limitation.

### Task 2: Render time buckets as a step line

**Files:**
- Modify: `ITrafficMonitorForMac/Dashboard/TrafficLineChart.swift`
- Test: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift` (compile/runtime coverage through chart data tests)

**Interfaces:**
- Consumes: `[TrafficSeriesPoint]` increments and existing hover tooltip lookup.
- Produces: both `LineMark` series rendered with `.interpolationMethod(.stepStart)` so each point's value is held from its bucket start until the next boundary.

- [ ] **Step 1: Add a failing chart behavior regression test**

Add a small pure assertion documenting the intended bucket sequence `[10, 30]` as two distinct increments and not `[10, 40]`; this guards against accidentally reintroducing cumulative conversion while the visual modifier is verified by build.

- [ ] **Step 2: Run the focused test and confirm the regression test is meaningful**

Run the focused `TrafficBarHoverTests` test target and confirm it fails before the new assertion/helper is implemented.

- [ ] **Step 3: Apply the minimal chart change**

Add `.interpolationMethod(.stepStart)` to both download and upload `LineMark`s. Leave y-axis scaling, hover selection, tooltip values, and chart domains unchanged.

- [ ] **Step 4: Build and run focused tests**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -destination 'platform=macOS' test -only-testing:ITrafficMonitorForMacTests/TrafficBarHoverTests`

Expected: PASS with the Swift Charts API available under the macOS 14 deployment target.

- [ ] **Step 5: Commit when Git metadata is writable**

Run: `git add ITrafficMonitorForMac/Dashboard/TrafficLineChart.swift ITrafficMonitorForMacTests/TrafficBarHoverTests.swift && git commit -m "fix: render traffic history as step lines"`

### Task 3: Add live rate cards to the dashboard

**Files:**
- Modify: `ITrafficMonitorForMac/Dashboard/UnifiedDashboardView.swift`
- Modify: `ITrafficMonitorForMac/Utils.swift` only if a reusable rate formatter is needed
- Modify: `ITrafficMonitorForMacTests/TrafficBarHoverTests.swift` or `ITrafficMonitorForMacTests/TrafficFilterTests.swift` for formatter coverage

**Interfaces:**
- Consumes: `@EnvironmentObject var realtimeRateStore: RealtimeRateStore`, `RateSample.inRate`, and `RateSample.outRate`.
- Produces: top-level stat-card row with current download and upload rates, updated automatically when the shared store publishes a new sample.

- [ ] **Step 1: Write the failing formatter test**

Add a test for the selected rate display format: zero bytes returns `0 KB/s`, a sub-megabyte value returns one-decimal KB/s, and a megabyte value returns one-decimal MB/s using `formatBytes(bytes:)`.

- [ ] **Step 2: Run the formatter test to verify it fails**

Run the focused XCTest command and confirm the new expected behavior is not already fully covered by the existing formatter.

- [ ] **Step 3: Implement the dashboard cards**

Inject `@EnvironmentObject private var realtimeRateStore: RealtimeRateStore` into `UnifiedDashboardView`, derive `latestRateSample` from `samples.last`, and add two `StatCard`s labeled with existing localization keys (`Download Speed` and `Upload Speed`) using `formatBytes(bytes: Int(rate))`. Fall back to `0` when there is no sample. Keep the existing historical Download/Upload/Total cards unchanged and use a four-card layout that remains horizontally scroll-safe at the existing minimum window width.

- [ ] **Step 4: Add localization entries if missing**

Add only the missing English/Chinese strings to `LocalizationManager` for the two speed-card labels; reuse existing rate formatting and theme colors.

- [ ] **Step 5: Build and run tests**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -destination 'platform=macOS' test`

Expected: all tests pass and the app target compiles with the shared environment object.

- [ ] **Step 6: Commit when Git metadata is writable**

Run: `git add ITrafficMonitorForMac/Dashboard/UnifiedDashboardView.swift ITrafficMonitorForMac/Model/LocalizationManager.swift ITrafficMonitorForMacTests && git commit -m "feat: show realtime network speed on dashboard"`

### Task 4: Final verification

**Files:**
- No additional source changes expected.

- [ ] **Step 1: Run the complete test suite**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -destination 'platform=macOS' test`

- [ ] **Step 2: Run a Debug build**

Run: `xcodebuild -project ITrafficMonitorForMac.xcodeproj -scheme ITrafficMonitorForMac -configuration Debug -destination 'platform=macOS' build`

- [ ] **Step 3: Inspect the diff**

Run: `git diff --check && git status --short`; verify only the design/plan docs and requested chart/dashboard/test files changed, with no generated artifacts.
