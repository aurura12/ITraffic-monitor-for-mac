import XCTest
import AppKit
import CoreGraphics
import SwiftUI
@testable import ITraffic

final class TrafficBarHoverTests: XCTestCase {
    func testMenuBarStatusItemUsesStableIdentity() {
        XCTAssertEqual(
            MenuBarStatusItemConfiguration.autosaveName,
            "com.foamzou.ITrafficMonitorV2.menuBar"
        )
    }

    func testMenuBarPopoverOmitsCurrentAppsSection() {
        SharedStore.perAppRateStore.topApps = [
            LiveAppRow(
                id: "com.example.current-app",
                displayName: "Current App",
                inRate: 1,
                outRate: 1
            )
        ]
        defer { SharedStore.perAppRateStore.clear() }

        let controller = MenuBarController()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let popover = Mirror(reflecting: controller).children
            .compactMap { $0.value as? NSPopover }
            .first

        XCTAssertEqual(popover?.contentSize, NSSize(width: 320, height: 214))
    }

    func testDashboardLaunchFlagIsOptIn() {
        XCTAssertTrue(shouldOpenDashboardAtLaunch(arguments: ["ITraffic", "--open-dashboard"]))
        XCTAssertFalse(shouldOpenDashboardAtLaunch(arguments: ["ITraffic"]))
    }

    func testTrafficXAxisUsesFewerLabelsForThirtyDayRange() {
        XCTAssertEqual(trafficXAxisStrideCount(for: .today), 3)
        XCTAssertEqual(trafficXAxisStrideCount(for: .sevenDays), 1)
        XCTAssertEqual(trafficXAxisStrideCount(for: .thirtyDays), 5)
    }

    func testTrafficXAxisLabelsCenterDailyBucketsAndKeepHourlyTicks() {
        XCTAssertFalse(trafficXAxisLabelsUseIntervalCentering(for: .today))
        XCTAssertTrue(trafficXAxisLabelsUseIntervalCentering(for: .sevenDays))
        XCTAssertTrue(trafficXAxisLabelsUseIntervalCentering(for: .thirtyDays))
    }

    func testTrafficXAxisLabelOffsetUsesTheRenderedLabelWidth() {
        let hourlyOffset = trafficXAxisLabelOffset(for: "00")
        let wideDailyOffset = trafficXAxisLabelOffset(for: "Aug 31")
        let shortDailyOffset = trafficXAxisLabelOffset(for: "Sep 1")

        XCTAssertEqual(
            hourlyOffset,
            trafficXAxisLabelOffset(for: "03"),
            accuracy: 0.1
        )
        XCTAssertLessThan(wideDailyOffset, shortDailyOffset)
        XCTAssertLessThan(shortDailyOffset, hourlyOffset)
    }

    func testTrafficBarXAxisPositionsSpanTheEntirePlot() {
        XCTAssertEqual(
            trafficBarXAxisPosition(for: 0, maxValue: 100),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            trafficBarXAxisPosition(for: 25, maxValue: 100),
            0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            trafficBarXAxisPosition(for: 100, maxValue: 100),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            trafficBarXAxisPosition(for: 150, maxValue: 100),
            1,
            accuracy: 0.001
        )
    }

    func testLogBarXAxisUsesTheVisibleOrderOfMagnitudeRange() {
        let domain = trafficBarLogDomain(for: [
            log10(100_000_000),
            log10(3_110_000_000)
        ])

        XCTAssertEqual(domain.lowerBound, 8, accuracy: 0.001)
        XCTAssertEqual(domain.upperBound, 10, accuracy: 0.001)
        XCTAssertEqual(
            trafficBarXAxisPosition(for: domain.lowerBound, domain: domain),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            trafficBarXAxisPosition(for: 9, domain: domain),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            trafficBarXAxisPosition(for: domain.upperBound, domain: domain),
            1,
            accuracy: 0.001
        )
    }

    func testUsageBarChartPinsXAxisAtTheTopWhileRowsScroll() {
        XCTAssertEqual(trafficBarXAxisBehavior(), .topPinned)
    }

    func testUsageBarsShowNewestPeriodFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let older = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let newer = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let points = [
            BarPeriodPoint(period: older, label: "2026-08", totalBytes: 100),
            BarPeriodPoint(period: newer, label: "2026-09", totalBytes: 200)
        ]

        XCTAssertEqual(
            trafficBarPointsNewestFirst(points).map(\.label),
            ["2026-09", "2026-08"]
        )
    }

    func testOnlyUsageChartRemovesTheCardSurface() {
        XCTAssertFalse(chartSectionUsesCardBackground(for: .usage))
        XCTAssertTrue(chartSectionUsesCardBackground(for: .line))
        XCTAssertTrue(chartSectionUsesCardBackground(for: .heatmap))
    }

    func testUsageChartFillsWindowWhileOtherChartsKeepPageScrolling() {
        XCTAssertEqual(dashboardLayoutMode(for: .usage), .windowFillingChart)
        XCTAssertEqual(dashboardLayoutMode(for: .line), .scrollingPage)
        XCTAssertEqual(dashboardLayoutMode(for: .heatmap), .scrollingPage)
    }

    func testDashboardUsesOneOuterScrollViewAcrossChartTabs() {
        XCTAssertTrue(dashboardUsesSharedOuterScrollView(for: .usage))
        XCTAssertTrue(dashboardUsesSharedOuterScrollView(for: .line))
        XCTAssertTrue(dashboardUsesSharedOuterScrollView(for: .heatmap))
    }

    func testUsageDashboardKeepsTopSectionsAtIntrinsicHeight() {
        XCTAssertEqual(dashboardTopSectionHeight(for: .usage), .intrinsic)
        XCTAssertEqual(dashboardTopSectionHeight(for: .line), .flexible)
        XCTAssertEqual(dashboardTopSectionHeight(for: .heatmap), .flexible)
    }

    func testDashboardActionsStayAtInlineTrailing() {
        XCTAssertEqual(dashboardActionsPlacement(), .inlineTrailing)
    }

    func testTrafficXAxisLabelsUseStableCalendarFormatting() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 15))!

        XCTAssertEqual(
            trafficXAxisLabel(for: date, timeRange: .sevenDays, calendar: calendar),
            "Aug 30"
        )
        XCTAssertEqual(
            trafficXAxisLabel(for: date, timeRange: .today, calendar: calendar),
            "15"
        )
    }

    func testDailyAndHourlyBarPlotDatesUseBucketCenters() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 15, minute: 30))!

        let dailyStart = trafficBucketStart(for: date, timeRange: .sevenDays, calendar: calendar)
        let dailyEnd = trafficBucketEnd(for: date, timeRange: .sevenDays, calendar: calendar)
        XCTAssertEqual(
            trafficBucketPlotDate(for: date, timeRange: .sevenDays, calendar: calendar),
            dailyStart.addingTimeInterval(dailyEnd.timeIntervalSince(dailyStart) / 2)
        )

        let hourlyStart = trafficBucketStart(for: date, timeRange: .today, calendar: calendar)
        let hourlyEnd = trafficBucketEnd(for: date, timeRange: .today, calendar: calendar)
        XCTAssertEqual(
            trafficBucketPlotDate(for: date, timeRange: .today, calendar: calendar),
            hourlyStart.addingTimeInterval(hourlyEnd.timeIntervalSince(hourlyStart) / 2)
        )
    }

    func testLineRefreshPrioritizesSeriesBeforeSecondaryData() {
        XCTAssertEqual(
            DashboardRefreshPlan.operations(for: .line),
            [.series, .total, .topApps]
        )
    }

    func testHeatmapRefreshDoesNotLoadRangeAppRanking() {
        XCTAssertEqual(
            DashboardRefreshPlan.operations(for: .heatmap),
            [.heatmap, .total]
        )
    }

    func testUsageRefreshDoesNotLoadRangeAppRanking() {
        XCTAssertEqual(
            DashboardRefreshPlan.operations(for: .usage),
            [.usage, .total]
        )
    }

    func testRefreshTokenRejectsResultsFromAnOlderRequest() {
        let older = DashboardRefreshToken(
            sequence: 1,
            timeRange: .today,
            chartMode: .line
        )
        let newer = DashboardRefreshToken(
            sequence: 2,
            timeRange: .sevenDays,
            chartMode: .line
        )

        XCTAssertFalse(
            older.matches(
                sequence: newer.sequence,
                timeRange: newer.timeRange,
                chartMode: newer.chartMode
            )
        )
        XCTAssertTrue(
            newer.matches(
                sequence: newer.sequence,
                timeRange: newer.timeRange,
                chartMode: newer.chartMode
            )
        )
    }

    func testTotalAccentUsesReadableBluePurpleColor() {
        let components = Theme.total.cgColor?.components ?? []

        XCTAssertEqual(components.count, 4)
        XCTAssertEqual(components[0], 0.486, accuracy: 0.001)
        XCTAssertEqual(components[1], 0.514, accuracy: 0.001)
        XCTAssertEqual(components[2], 0.961, accuracy: 0.001)
    }

    private enum TestError: Error {
        case registrationFailed
    }

    func testUsageBarRefreshReplacesCachedTodayWithCommittedTotal() {
        let today = dayIndex(for: Date(), calendar: .current)
        var responses = [
            [DayTrafficRow(day: today, inBytes: 100, outBytes: 0)],
            [DayTrafficRow(day: today, inBytes: 250, outBytes: 0)]
        ]
        let viewModel = DashboardViewModel { _, _, completion in
            completion(responses.removeFirst())
        }
        viewModel.barGranularity = .day

        viewModel.refreshBarChart()
        XCTAssertEqual(viewModel.barPoints.last?.totalBytes, 100)

        viewModel.refreshBarChart()
        XCTAssertEqual(viewModel.barPoints.last?.totalBytes, 250)
    }

    func testStoppingNettopCancelsPendingRestart() {
        let firstSpawned = expectation(description: "initial nettop process spawned")
        firstSpawned.assertForOverFulfill = false
        var spawnCount = 0
        let runner = NettopRunner(interval: 1, processConfigurator: { task, _ in
            spawnCount += 1
            task.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            task.arguments = []
            firstSpawned.fulfill()
        })

        runner.start()
        wait(for: [firstSpawned], timeout: 1)
        Thread.sleep(forTimeInterval: 0.2)
        runner.stop()
        Thread.sleep(forTimeInterval: 0.8)

        XCTAssertEqual(spawnCount, 1)
    }

    func testHoveringAnotherRowReplacesThePreviouslyHoveredBar() {
        var selection = BarHoverSelection()

        selection.update(activeBarID: "2026-01")
        selection.update(activeBarID: "2026-02")

        XCTAssertEqual(selection.activeBarID, "2026-02")
    }

    func testEndingHoverClearsTheSelectedBar() {
        var selection = BarHoverSelection()

        selection.update(activeBarID: "2026-01")
        selection.update(activeBarID: nil)

        XCTAssertNil(selection.activeBarID)
    }

    func testTooltipIsOffsetFromPointerAndFlipsBelowAtTopEdge() {
        let normal = tooltipPosition(for: CGPoint(x: 200, y: 100), in: CGSize(width: 600, height: 300))
        let nearTop = tooltipPosition(for: CGPoint(x: 200, y: 10), in: CGSize(width: 600, height: 300))

        XCTAssertLessThan(normal.y, 100)
        XCTAssertGreaterThan(nearTop.y, 10)
        XCTAssertNotEqual(normal.x, 200)
    }

    func testDailyTooltipsUseTheCorrespondingCalendarDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 12))!

        XCTAssertEqual(
            trafficBucketLabel(for: date, timeRange: .thirtyDays, calendar: calendar),
            "2026-08-21"
        )
    }

    func testHeatmapTooltipIsOffsetFromPointerAndFlipsBelowAtTopEdge() {
        let normal = heatmapTooltipPosition(
            for: CGPoint(x: 200, y: 100),
            in: CGSize(width: 600, height: 300)
        )
        let nearTop = heatmapTooltipPosition(
            for: CGPoint(x: 200, y: 10),
            in: CGSize(width: 600, height: 300)
        )

        XCTAssertLessThan(normal.y, 100)
        XCTAssertGreaterThan(nearTop.y, 10)
        XCTAssertNotEqual(normal.x, 200)
    }

    func testUnixSocketCurlOutputParsesStatusAndBody() {
        let output = "{\"connections\":[]}\n__ITRAFFIC_STATUS__:200\n"

        let response = parseUnixSocketCurlOutput(output)

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.body, "{\"connections\":[]}")
    }

    func testNettopParserHandlesQuotedCommaInProcessName() {
        let network = Network()

        let entity = network.parser(text: "\"My, Browser.42\",100,200")

        XCTAssertEqual(entity?.name, "My, Browser")
        XCTAssertEqual(entity?.pid, 42)
        XCTAssertEqual(entity?.inBytes, 100)
        XCTAssertEqual(entity?.outBytes, 200)
    }

    func testNettopParserRejectsUnclosedQuotedField() {
        XCTAssertNil(Network().parser(text: "\"My, Browser.42,100,200"))
    }

    func testNettopParserRejectsNonNumericFieldsInsteadOfCoercingToZero() {
        // A row with a non-numeric byte field or PID must be rejected so it is
        // counted as dropped, not kept with a zeroed field.
        XCTAssertNil(Network().parser(text: "Foo.123,abc,200,"))
        XCTAssertNil(Network().parser(text: "Foo.123,100,xyz,"))
        XCTAssertNil(Network().parser(text: "Foo.bar,100,200,"))
    }

    func testNettopParserRejectsNegativePid() {
        XCTAssertNil(Network().parser(text: "Foo.-1,100,200,"))
    }

    func testNettopParserClampsNegativeByteDeltaToZero() {
        let entity = Network().parser(text: "Foo.123,-5,200,")

        XCTAssertEqual(entity?.inBytes, 0)
        XCTAssertEqual(entity?.outBytes, 200)
    }

    func testNettopHeaderLineIsRecognizedAndNotADataRow() {
        XCTAssertTrue(isNettopHeaderLine(",bytes_in,bytes_out,"))
        XCTAssertFalse(isNettopHeaderLine("Codex (Service).1084,6264839,0,"))
        XCTAssertNil(Network().parser(text: ",bytes_in,bytes_out,"))
    }

    func testNettopHeaderMatchIgnoresProcessNamesContainingFieldLabels() {
        // A process named "bytes_in" is a real row, not the header.
        XCTAssertFalse(isNettopHeaderLine("bytes_in.1234,100,200,"))
        XCTAssertNotNil(Network().parser(text: "bytes_in.1234,100,200,"))
    }

    func testNettopParserHandlesRealFrameRowWithSpacesAndTrailingComma() {
        let entity = Network().parser(text: "Codex (Service).1084,6264839,0,")

        XCTAssertEqual(entity?.name, "Codex (Service)")
        XCTAssertEqual(entity?.pid, 1084)
        XCTAssertEqual(entity?.inBytes, 6_264_839)
        XCTAssertEqual(entity?.outBytes, 0)
    }

    func testRateFormatterUsesFullUnitLadder() {
        XCTAssertEqual(formatRatePerSecond(0), "0 B/s")
        XCTAssertEqual(formatRatePerSecond(512), "512 B/s")
        XCTAssertEqual(formatRatePerSecond(1024), "1.0 KB/s")
        XCTAssertEqual(formatRatePerSecond(1024 * 1024), "1.0 MB/s")
        XCTAssertEqual(formatRatePerSecond(1024 * 1024 * 1024), "1.00 GB/s")
    }

    func testPerAppRateStoreRanksLiveAppsByCombinedRate() {
        let store = PerAppRateStore()
        store.update(
            entities: [
                ProcessEntity(pid: 4_000_001, name: "alpha", inBytes: 2048, outBytes: 0),
                ProcessEntity(pid: 4_000_002, name: "beta", inBytes: 4096, outBytes: 4096),
                ProcessEntity(pid: 4_000_003, name: "idle", inBytes: 0, outBytes: 0)
            ],
            interval: 2
        )

        XCTAssertEqual(store.topApps.map(\.displayName), ["beta", "alpha"])
        XCTAssertEqual(store.topApps.first?.inRate, 2048)
    }

    func testPerAppRateStoreClearDropsLiveValues() {
        let store = PerAppRateStore()
        store.update(
            entities: [ProcessEntity(pid: 4_000_001, name: "alpha", inBytes: 2048, outBytes: 0)],
            interval: 2
        )
        XCTAssertFalse(store.topApps.isEmpty)

        store.clear()

        XCTAssertTrue(store.topApps.isEmpty)
        XCTAssertTrue(store.latest.isEmpty)
    }

    func testListViewModelClearDropsRows() {
        let viewModel = ListViewModel()
        viewModel.updateData(newItems: [
            ProcessEntity(pid: 4_000_001, name: "alpha", inBytes: 1, outBytes: 0)
        ])
        XCTAssertFalse(viewModel.items.isEmpty)

        viewModel.clear()

        XCTAssertTrue(viewModel.items.isEmpty)
    }

    func testProcessHelperReturnsOutput() {
        let output = runProcessCollectingOutput(
            executable: "/bin/echo",
            arguments: ["hello"],
            timeout: 2
        )

        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testProcessHelperTimesOutWhenStdoutClosesButChildKeepsRunning() {
        // The child closes stdout immediately and then execs a long sleep. A
        // deadline tied to stdout EOF would settle instantly and then block
        // forever in waitUntilExit; the deadline must follow the process.
        let start = Date()
        let output = runProcessCollectingOutput(
            executable: "/bin/sh",
            arguments: ["-c", "exec 1>&-; exec sleep 30"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(output)
        XCTAssertLessThan(elapsed, 10)
    }

    func testHelperProcessUsesParentAppNameInsteadOfTruncatedProcessName() {
        let name = preferredDisplayName(
            applicationName: "WeChat",
            processName: "WeChatAppEx Hel",
            walkedToAncestor: true
        )

        XCTAssertEqual(name, "WeChat")
    }

    func testCommandLineChildUsesParentAppNameForCleanDisplay() {
        let name = preferredDisplayName(
            applicationName: "Visual Studio Code",
            processName: "node",
            walkedToAncestor: true
        )

        XCTAssertEqual(name, "Visual Studio Code")
    }

    func testUnresolvedProcessKeepsItsRawName() {
        let name = preferredDisplayName(
            applicationName: nil,
            processName: "nsurlsessiond",
            walkedToAncestor: false
        )

        XCTAssertEqual(name, "nsurlsessiond")
    }

    func testLaunchAtLoginManagerRegistersAndRefreshesState() {
        var registeredState = false
        let manager = LaunchAtLoginManager(
            statusProvider: { registeredState },
            setEnabled: { enabled in registeredState = enabled }
        )

        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.setEnabled(true))
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(registeredState)
    }

    func testLaunchAtLoginManagerRevertsWhenRegistrationFails() {
        let manager = LaunchAtLoginManager(
            statusProvider: { false },
            setEnabled: { _ in throw TestError.registrationFailed }
        )

        XCTAssertFalse(manager.setEnabled(true))
        XCTAssertFalse(manager.isEnabled)
    }

    func testClashVergeCoreUsesClashVergeDisplayName() {
        XCTAssertEqual(
            proxyDisplayName(rawName: "verge-mihomo", isClashVerge: true),
            "Clash Verge"
        )
    }

    func testMihomoUsesStableClashVergeDatabaseName() {
        XCTAssertEqual(canonicalProcessDisplayName("verge-mihomo"), "Clash Verge")
        XCTAssertEqual(canonicalProcessDisplayName("mihomo"), "Clash Verge")
        XCTAssertEqual(canonicalProcessDisplayName("clash-verge"), "Clash Verge")
        XCTAssertEqual(canonicalProcessDisplayName("Google Chrome"), "Google Chrome")
    }

    func testLiveListNormalizesMihomoName() {
        let viewModel = ListViewModel()
        viewModel.updateData(newItems: [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 10, outBytes: 2)])
        XCTAssertEqual(viewModel.items.first?.name, "Clash Verge")
    }

    func testExistingConnectionRetainsConfirmedPIDWhenLookupLaterFails() {
        XCTAssertEqual(attributedPID(previousPID: 456, resolvedPID: 0), 456)
    }

    func testMissingNewConnectionPIDRemainsUnassigned() {
        XCTAssertEqual(attributedPID(previousPID: 0, resolvedPID: 0), 0)
    }

    func testEmptyProxyConnectionTableIsStillDetected() {
        XCTAssertEqual(
            proxyFetchOutcome(statusCode: 200, hasBody: true, connectionCount: 0),
            .success(connectionCount: 0)
        )
    }

    func testProxyTransportFailureIsNotReportedAsAuthenticationFailure() {
        XCTAssertEqual(
            proxyFetchOutcome(statusCode: nil, hasBody: false, connectionCount: 0),
            .transportFailure
        )
    }

    func testProxyDiagnosticsDistinguishAPIFailureFromMissingNetTopProxyRow() {
        let apiFailure = proxyDiagnosticSummary(.apiUnavailable(endpoint: "unix:/tmp/verge/verge-mihomo.sock"))
        let missingRow = proxyDiagnosticSummary(.waitingForProxyRow(
            name: "Clash Verge",
            endpoint: "unix:/tmp/verge/verge-mihomo.sock",
            connectionCount: 86,
            mappedConnectionCount: 73,
            proxyPID: 91681
        ))

        XCTAssertTrue(apiFailure.contains("API unavailable"))
        XCTAssertTrue(missingRow.contains("proxy row missing"))
        XCTAssertTrue(missingRow.contains("connections=86"))
        XCTAssertTrue(missingRow.contains("mapped=73"))
        XCTAssertTrue(missingRow.contains("proxyPID=91681"))
    }

    func testClashProxyEntityMatchesAnyResolvedPIDOrCanonicalName() {
        XCTAssertTrue(proxyEntityMatches(
            pid: 91656,
            name: "verge-mihomo",
            proxyPIDs: [91681],
            isClashVerge: true
        ))
        XCTAssertTrue(proxyEntityMatches(
            pid: 91681,
            name: "mihomo",
            proxyPIDs: [91681],
            isClashVerge: true
        ))
        XCTAssertFalse(proxyEntityMatches(
            pid: 1234,
            name: "Google Chrome",
            proxyPIDs: [91681],
            isClashVerge: true
        ))
    }

    func testProxyCreditHelpersClampCountersAndIncludeUploadOnlyPIDs() {
        XCTAssertEqual(nonNegativeProxyDelta(current: 5, previous: 10), 0)
        XCTAssertEqual(proxyCreditPIDs(inBytes: [1: 20], outBytes: [2: 30]), [1, 2])
    }

    func testProxyCreditConsumptionSummaryIncludesCreditedAndPendingBytes() {
        let summary = proxyCreditConsumptionSummary(
            creditedIn: 120,
            creditedOut: 45,
            pendingIn: 30,
            pendingOut: 6,
            proxyIn: 150,
            proxyOut: 51
        )

        XCTAssertEqual(summary, "proxy credits consumed in=120 out=45 pendingIn=30 pendingOut=6 proxyIn=150 proxyOut=51")
    }

    func testShortLivedSocketUsesFreshCachedOwnerWhenLiveMapMisses() {
        let key = SocketKey(protocol: .tcp, port: 64068)
        let cached = [key: CachedSocketOwner(pid: 30944, name: "Code Helper", lastSeen: 100)]

        let merged = mergeSocketOwners(live: [:], cached: cached, now: 104, ttl: 10)

        XCTAssertEqual(merged[key], SocketOwner(pid: 30944, name: "Code Helper"))
    }

    func testExpiredSocketOwnerIsNotReusedAfterPortMayHaveBeenRecycled() {
        let key = SocketKey(protocol: .tcp, port: 64068)
        let cached = [key: CachedSocketOwner(pid: 30944, name: "Code Helper", lastSeen: 100)]

        let merged = mergeSocketOwners(live: [:], cached: cached, now: 111, ttl: 10)

        XCTAssertNil(merged[key])
    }

    func testCachedSocketOwnerIsNotReusedWhenPIDWasRecycled() {
        let key = SocketKey(protocol: .tcp, port: 64068)
        let cached = [key: CachedSocketOwner(
            pid: 30944,
            name: "Code Helper",
            lastSeen: 100,
            startTime: 10
        )]

        let merged = mergeSocketOwners(
            live: [:],
            cached: cached,
            now: 104,
            ttl: 10,
            ownerIsCurrent: { $0.startTime == 11 }
        )

        XCTAssertNil(merged[key])
    }

    func testUnknownProtocolUsesUniqueSocketOwner() {
        let ports = [SocketKey(protocol: .tcp, port: 64068): 30944]

        XCTAssertEqual(socketOwnerPID(sourcePort: 64068, transport: nil, ports: ports), 30944)
    }

    func testUnknownProtocolDoesNotChooseBetweenTCPAndUDPOwners() {
        let ports = [
            SocketKey(protocol: .tcp, port: 64068): 30944,
            SocketKey(protocol: .udp, port: 64068): 30945
        ]

        XCTAssertNil(socketOwnerPID(sourcePort: 64068, transport: nil, ports: ports))
    }

    func testReusedConnectionIDCannotRetainPIDWhenEndpointChanges() {
        XCTAssertFalse(shouldReuseTrackedProxyPID(
            previousSourcePort: 64068,
            previousTransport: .tcp,
            currentSourcePort: 64069,
            currentTransport: .tcp
        ))
        XCTAssertTrue(shouldReuseTrackedProxyPID(
            previousSourcePort: 64068,
            previousTransport: .tcp,
            currentSourcePort: 64068,
            currentTransport: .tcp
        ))
    }

    func testProxyDiagnosticReportsPartialMappingCoverage() {
        XCTAssertEqual(
            proxyMappingCoverage(.detected(
                name: "Clash Verge",
                endpoint: "unix:/tmp/verge.sock",
                connectionCount: 86,
                mappedConnectionCount: 73,
                proxyPID: 91681
            )) ?? -1,
            73.0 / 86.0,
            accuracy: 0.0001
        )
    }

    func testClashConfigLineParsesControllerAndSecret() {
        XCTAssertEqual(parseProxyConfigLine("external-controller: 127.0.0.1:9097"),
                       ProxyConfigEntry(key: "external-controller", value: "127.0.0.1:9097"))
        XCTAssertEqual(parseProxyConfigLine("secret: 'local-secret'"),
                       ProxyConfigEntry(key: "secret", value: "local-secret"))
    }

    func testProxyCreditsAccumulateAcrossAttributorTicks() {
        var existing: [Int: (inBytes: Int, outBytes: Int)] = [
            52391: (inBytes: 100, outBytes: 20)
        ]
        accumulateProxyCredits(&existing, [
            52391: (inBytes: 30, outBytes: 7),
            52392: (inBytes: 5, outBytes: 2)
        ])
        XCTAssertEqual(existing[52391]?.inBytes, 130)
        XCTAssertEqual(existing[52391]?.outBytes, 27)
        XCTAssertEqual(existing[52392]?.inBytes, 5)
    }

    func testPendingCreditsConsumeOldestBytesFirst() {
        let pending = [
            PendingProxyCredit(timestamp: 10, pid: 1, inBytes: 100, outBytes: 0),
            PendingProxyCredit(timestamp: 11, pid: 2, inBytes: 100, outBytes: 0)
        ]

        let result = consumePendingProxyCredits(pending, availableIn: 150, availableOut: 0)

        XCTAssertEqual(result.credited[1]?.inBytes, 100)
        XCTAssertEqual(result.credited[2]?.inBytes, 50)
        XCTAssertEqual(result.remaining, [
            PendingProxyCredit(timestamp: 11, pid: 2, inBytes: 50, outBytes: 0)
        ])
    }

    func testPendingCreditsRemainWhenNoProxyRowCanCarryThem() {
        let pending = [PendingProxyCredit(timestamp: 10, pid: 1, inBytes: 100, outBytes: 20)]

        let result = consumePendingProxyCredits(pending, availableIn: 0, availableOut: 0)

        XCTAssertTrue(result.credited.isEmpty)
        XCTAssertEqual(result.remaining, pending)
    }

    func testSocketKeysKeepTCPAndUDPSamePortSeparate() {
        let tcp = SocketKey(protocol: .tcp, port: 54000)
        let udp = SocketKey(protocol: .udp, port: 54000)

        XCTAssertNotEqual(tcp, udp)
    }

    func testDiagnosticLogRetentionKeepsNewestBytesWithinLimit() {
        let retained = retainingNewestDiagnosticLogBytes(
            Data("old\nnewest\n".utf8),
            maximumBytes: 7
        )

        XCTAssertEqual(String(decoding: retained, as: UTF8.self), "newest\n")
    }

    func testCustomProxyAPIOnlyAllowsLoopbackHosts() {
        XCTAssertTrue(isAllowedProxyAPIURL("http://127.0.0.1:9090"))
        XCTAssertTrue(isAllowedProxyAPIURL("http://localhost:9090"))
        XCTAssertTrue(isAllowedProxyAPIURL("http://[::1]:9090"))
        XCTAssertFalse(isAllowedProxyAPIURL("http://192.168.1.10:9090"))
        XCTAssertFalse(isAllowedProxyAPIURL("https://example.com/api"))
    }

    func testTodaySeriesContainsAll24HoursAndFillsMissingHoursWithZero() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let source = [
            TrafficSeriesPoint(
                date: calendar.date(byAdding: .hour, value: 3, to: start)!,
                inBytes: 100,
                outBytes: 40
            )
        ]

        let result = hourlySeriesPoints(points: source, start: start, calendar: calendar)

        XCTAssertEqual(result.count, 24)
        XCTAssertEqual(result[3].inBytes, 100)
        XCTAssertEqual(result[3].outBytes, 40)
        XCTAssertEqual(result[2].inBytes, 0)
        XCTAssertEqual(result[23].outBytes, 0)
    }

    func testHourSeriesSQLGroupsByValidLocalHourKey() {
        XCTAssertTrue(hourSeriesSQL.contains("strftime('%Y-%m-%d %H'"))
        XCTAssertFalse(hourSeriesSQL.contains("start of hour"))
    }

    func testLineChartHoverSelectsTheNearestHour() {
        let first = TrafficSeriesPoint(date: Date(timeIntervalSince1970: 0), inBytes: 10, outBytes: 2)
        let second = TrafficSeriesPoint(date: Date(timeIntervalSince1970: 3600), inBytes: 30, outBytes: 4)

        let selected = nearestTrafficSeriesPoint(
            to: Date(timeIntervalSince1970: 3200),
            points: [first, second]
        )

        XCTAssertEqual(selected?.date, second.date)
    }

    func testLineChartHoverSelectsTheNearestRenderedBar() {
        let selected = nearestTrafficBarIndex(
            to: 690,
            barCenters: [100, 300, 500, 700]
        )

        XCTAssertEqual(selected, 3)
    }

    func testHourlySeriesKeepsPerHourIncrementsAndFillsMissingHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 0)
        let points = [
            TrafficSeriesPoint(date: start.addingTimeInterval(3600 + 15 * 60), inBytes: 10, outBytes: 2),
            TrafficSeriesPoint(date: start.addingTimeInterval(3 * 3600 + 20 * 60), inBytes: 30, outBytes: 4)
        ]

        let result = hourlySeriesPoints(points: points, start: start, calendar: calendar)

        XCTAssertEqual(result.count, 24)
        XCTAssertEqual(result[0].inBytes, 0)
        XCTAssertEqual(result[1].inBytes, 10)
        XCTAssertEqual(result[2].inBytes, 0)
        XCTAssertEqual(result[3].inBytes, 30)
        XCTAssertEqual(result[3].inBytes, 30, "Each hour remains an increment; it must not include hour 1.")
    }

    func testRateFormatterUsesRateUnits() {
        XCTAssertEqual(formatBytes(bytes: 0), "0 KB/s")
        XCTAssertEqual(formatBytes(bytes: 1_024), "1.0 KB/s")
        XCTAssertEqual(formatBytes(bytes: 1_048_576), "1.0 MB/s")
    }

    func testTrafficBucketRangeLabelShowsStartAndEndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 14))!

        XCTAssertEqual(
            trafficBucketLabel(for: date, timeRange: .today, calendar: calendar),
            "14:00–15:00"
        )
    }

    func testTrafficBarValueCombinesDownloadAndUpload() {
        let point = TrafficSeriesPoint(date: Date(timeIntervalSince1970: 0), inBytes: 120, outBytes: 30)

        XCTAssertEqual(trafficBarValue(for: point), 150)
    }

    func testTrafficBucketRangeRoundsRawSampleToWholeHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rawDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 19, minute: 5))!

        XCTAssertEqual(
            trafficBucketLabel(for: rawDate, timeRange: .today, calendar: calendar),
            "19:00–20:00"
        )
    }

    // MARK: - Proxy row visibility diagnostic

    func testVisibilityTransitionIsNotConsumedWhileDetectionUnavailable() {
        // Regression: a frame racing a transient reset() (proxyDetected
        // momentarily false) must not consume the only visibility change. The
        // previous visibility stays nil so the next frame retries.
        let diagnostic = (name: "Clash Verge", endpoint: "unix:/tmp/verge/verge-mihomo.sock",
                          connectionCount: 10, mappedConnectionCount: 8, proxyPID: Int?(91681))

        let update = recordingProxyRowVisibility(
            visible: true,
            proxyDetected: false,
            lastProxyRowVisible: nil,
            diagnostic: diagnostic
        )

        XCTAssertFalse(update.changed)
        XCTAssertNil(update.newLastVisible, "Detection unavailable: keep nil so a later frame can fire")
        XCTAssertNil(update.diagnostic)
    }

    func testVisibilityTransitionEmitsDiagnosticOnFirstObservation() {
        let diagnostic = (name: "Clash Verge", endpoint: "unix:/tmp/verge/verge-mihomo.sock",
                          connectionCount: 10, mappedConnectionCount: 8, proxyPID: Int?(91681))

        let update = recordingProxyRowVisibility(
            visible: true,
            proxyDetected: true,
            lastProxyRowVisible: nil,
            diagnostic: diagnostic
        )

        XCTAssertTrue(update.changed)
        XCTAssertEqual(update.newLastVisible, true)
        XCTAssertEqual(update.diagnostic?.proxyPID, 91681)
    }

    func testVisibilityTransitionIsIdempotentForSameVisibility() {
        let diagnostic = (name: "Clash Verge", endpoint: "unix:/tmp/verge/verge-mihomo.sock",
                          connectionCount: 10, mappedConnectionCount: 8, proxyPID: Int?(91681))

        let update = recordingProxyRowVisibility(
            visible: true,
            proxyDetected: true,
            lastProxyRowVisible: true,
            diagnostic: diagnostic
        )

        XCTAssertFalse(update.changed)
        XCTAssertNil(update.diagnostic)
    }

    func testSameWindowSettlementClampsDeclarationsAndPreservesBothDirections() {
        let raw = [
            ProcessEntity(pid: 61013, name: "Google Chrome", inBytes: 100, outBytes: 50),
            ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000, outBytes: 500)
        ]
        let declarations = [
            PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 1_500, outBytes: 700)
        ]

        let result = settleProxyWindow(
            raw: raw,
            proxyPIDs: [91681],
            isClashVerge: true,
            declarations: declarations,
            pidNames: [61013: "Google Chrome"]
        )

        XCTAssertEqual(result.credited[61013]?.inBytes, 1_000)
        XCTAssertEqual(result.credited[61013]?.outBytes, 500)
        XCTAssertTrue(result.droppedDeclarations.isEmpty == false)
        XCTAssertEqual(result.droppedDeclarations.first?.inBytes, 500)
        XCTAssertEqual(result.droppedDeclarations.first?.outBytes, 200)

        let rawIn = raw.reduce(0) { $0 + $1.inBytes }
        let rawOut = raw.reduce(0) { $0 + $1.outBytes }
        let finalIn = result.entities.reduce(0) { $0 + $1.inBytes }
        let finalOut = result.entities.reduce(0) { $0 + $1.outBytes }
        XCTAssertEqual(finalIn, rawIn)
        XCTAssertEqual(finalOut, rawOut)
        XCTAssertEqual(result.entities.first(where: { $0.pid == 91681 })?.inBytes, 0)
        XCTAssertEqual(result.entities.first(where: { $0.pid == 91681 })?.outBytes, 0)
    }

    func testMissingProxyRowLeavesBytesOnRawEntitiesAndDoesNotCreateDebt() {
        let raw = [
            ProcessEntity(pid: 61013, name: "Google Chrome", inBytes: 100, outBytes: 25)
        ]
        let declarations = [
            PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 900, outBytes: 300)
        ]

        let result = settleProxyWindow(
            raw: raw,
            proxyPIDs: [91681],
            isClashVerge: true,
            declarations: declarations,
            pidNames: [61013: "Google Chrome"]
        )

        XCTAssertTrue(result.credited.isEmpty)
        XCTAssertEqual(result.entities.map(\.inBytes), raw.map(\.inBytes))
        XCTAssertEqual(result.entities.map(\.outBytes), raw.map(\.outBytes))
        XCTAssertEqual(result.droppedDeclarations, declarations)
    }

    func testUploadOnlyDeclarationCreatesAnAppRowWithoutChangingTotal() {
        let raw = [
            ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 0, outBytes: 500)
        ]
        let result = settleProxyWindow(
            raw: raw,
            proxyPIDs: [91681],
            isClashVerge: true,
            declarations: [PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 0, outBytes: 300)],
            pidNames: [61013: "Google Chrome"]
        )

        XCTAssertEqual(result.entities.first(where: { $0.pid == 61013 })?.inBytes, 0)
        XCTAssertEqual(result.entities.first(where: { $0.pid == 61013 })?.outBytes, 300)
        XCTAssertEqual(result.entities.reduce(0) { $0 + $1.inBytes }, 0)
        XCTAssertEqual(result.entities.reduce(0) { $0 + $1.outBytes }, 500)
    }

    func testDuplicateRawProcessRowsDoNotDuplicateASettlement() {
        let raw = [
            ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 800, outBytes: 0),
            ProcessEntity(pid: 61013, name: "Google Chrome", inBytes: 20, outBytes: 0),
            ProcessEntity(pid: 61013, name: "Google Chrome", inBytes: 30, outBytes: 0)
        ]
        let result = settleProxyWindow(
            raw: raw,
            proxyPIDs: [91681],
            isClashVerge: true,
            declarations: [PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 500, outBytes: 0)],
            pidNames: [61013: "Google Chrome"]
        )

        XCTAssertEqual(result.entities.reduce(0) { $0 + $1.inBytes }, 850)
        XCTAssertEqual(result.entities.filter { $0.pid == 61013 }.map(\.inBytes), [520, 30])
    }

    func testSampleLedgerCommitIsIdempotentAndIncludesCurrentMinute() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("itraffic-test-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        }

        let database = TrafficDatabase(databaseURL: url)
        let sample = TrafficSample(
            id: "sample-1",
            capturedAtMs: 1_700_000_012_345,
            bucketStart: 1_700_000_000,
            day: 19_675,
            hour: 1,
            rawInBytes: 100,
            rawOutBytes: 50,
            allocations: [
                TrafficSampleAllocation(appKey: "Google Chrome", displayName: "Google Chrome", inBytes: 75, outBytes: 40),
                TrafficSampleAllocation(appKey: "Clash Verge", displayName: "Clash Verge", inBytes: 25, outBytes: 10)
            ]
        )

        database.commitSample(sample)
        database.commitSample(sample)

        let expectation = expectation(description: "sample is queryable")
        database.totalTraffic(start: 1_700_000_000, end: 1_700_000_060) { total in
            XCTAssertEqual(total.inBytes, 100)
            XCTAssertEqual(total.outBytes, 50)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
