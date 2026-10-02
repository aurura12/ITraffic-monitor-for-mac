import XCTest
import CoreGraphics
import SwiftUI
@testable import ITraffic

final class TrafficBarHoverTests: XCTestCase {
    /// Hosted tests run inside the app process, so the app must recognise a test
    /// run and stay inert: no nettop, no attribution, and no production DB.
    func testAppEnvironmentDetectsTestHost() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }

    func testMenuBarStatusItemUsesStableIdentity() {
        XCTAssertEqual(
            MenuBarStatusItemConfiguration.autosaveName,
            "com.foamzou.ITrafficMonitorV2.menuBar"
        )
    }

    func testMenuBarPopoverKeepsItsConfiguredHeightAfterInstallingContent() {
        let controller = MenuBarController()
        let popover = Mirror(reflecting: controller).children
            .first { $0.label == "popover" }?.value as? NSPopover

        guard let popover else {
            XCTFail("MenuBarController should retain its popover")
            return
        }

        guard let view = popover.contentViewController?.view else {
            XCTFail("MenuBarController should install a content view")
            return
        }

        XCTAssertEqual(popover.contentSize.width, CGFloat(320), accuracy: 0.1)
        XCTAssertEqual(
            popover.contentSize.height,
            ceil(view.fittingSize.height),
            accuracy: 0.1
        )
    }

    func testMenuBarPopoverUsesTransientBehaviorAndHasAnAutoDismissFallback() {
        let controller = MenuBarController()
        let popover = Mirror(reflecting: controller).children
            .first { $0.label == "popover" }?.value as? NSPopover

        XCTAssertEqual(popover?.behavior, .transient)
        XCTAssertEqual(MenuBarPopoverConfiguration.autoDismissInterval, 5)
    }

    func testMenuBarRateOverlayLeavesStatusButtonInChargeOfClicks() {
        let controller = MenuBarController()
        let statusItem = Mirror(reflecting: controller).children
            .first { $0.label == "statusItem" }?.value as? NSStatusItem

        XCTAssertTrue(statusItem?.button?.target as AnyObject? === controller)
        XCTAssertEqual(statusItem?.button?.action.map(NSStringFromSelector), "handleStatusItemClick:")
    }

    func testMenuBarDisplayModeFallsBackToBothForUnknownValues() {
        XCTAssertEqual(MenuBarDisplayMode(rawValue: "nonsense"), nil)
        // `current` must never return nil for a missing/legacy stored value.
        let previous = UserDefaults.standard.string(forKey: MenuBarDisplayMode.defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: MenuBarDisplayMode.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MenuBarDisplayMode.defaultsKey)
            }
        }
        UserDefaults.standard.set("nonsense", forKey: MenuBarDisplayMode.defaultsKey)
        XCTAssertEqual(MenuBarDisplayMode.current, .both)
    }

    func testMenuBarRateViewShowsOnlyTheSelectedRows() {
        let view = MenuBarRateView(frame: .zero)
        let children = Mirror(reflecting: view).children
        let upload = children.first { $0.label == "uploadLabel" }?.value as? NSTextField
        let download = children.first { $0.label == "downloadLabel" }?.value as? NSTextField
        let icon = children.first { $0.label == "iconView" }?.value as? NSImageView

        view.apply(mode: .both)
        XCTAssertEqual(upload?.isHidden, false)
        XCTAssertEqual(download?.isHidden, false)
        XCTAssertEqual(icon?.isHidden, true)

        view.apply(mode: .downloadOnly)
        XCTAssertEqual(upload?.isHidden, true)
        XCTAssertEqual(download?.isHidden, false)
        XCTAssertEqual(icon?.isHidden, true)

        view.apply(mode: .uploadOnly)
        XCTAssertEqual(upload?.isHidden, false)
        XCTAssertEqual(download?.isHidden, true)
        XCTAssertEqual(icon?.isHidden, true)

        view.apply(mode: .iconOnly)
        XCTAssertEqual(upload?.isHidden, true)
        XCTAssertEqual(download?.isHidden, true)
        XCTAssertEqual(icon?.isHidden, false)
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

    func testUsageBarXAxisEdgeLabelsAreClampedInsideThePlotArea() {
        let labelWidth: CGFloat = 40
        let plotWidth: CGFloat = 300

        // Interior ticks keep their centred position.
        XCTAssertEqual(
            trafficBarXAxisTickLabelCenter(for: 0.5, plotWidth: plotWidth, labelWidth: labelWidth),
            plotWidth / 2,
            accuracy: 0.001
        )
        // The last label is pulled in by half its width instead of overflowing
        // the plot edge and being clipped by the scrolling container.
        XCTAssertEqual(
            trafficBarXAxisTickLabelCenter(for: 1, plotWidth: plotWidth, labelWidth: labelWidth),
            plotWidth - labelWidth / 2,
            accuracy: 0.001
        )
        // The first label is pushed in the same way.
        XCTAssertEqual(
            trafficBarXAxisTickLabelCenter(for: 0, plotWidth: plotWidth, labelWidth: labelWidth),
            labelWidth / 2,
            accuracy: 0.001
        )
    }

    func testUsageBarXAxisLabelCenterFallsBackWhenPlotIsNarrowerThanTheLabel() {
        XCTAssertEqual(
            trafficBarXAxisTickLabelCenter(for: 1, plotWidth: 20, labelWidth: 40),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            trafficBarXAxisTickLabelCenter(for: 1, plotWidth: 0, labelWidth: 40),
            0,
            accuracy: 0.001
        )
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
            [.series, .total]
        )
    }

    func testHeatmapRefreshLoadsHeatmapBeforeTotal() {
        XCTAssertEqual(
            DashboardRefreshPlan.operations(for: .heatmap),
            [.heatmap, .total]
        )
    }

    func testUsageRefreshLoadsUsageBeforeTotal() {
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

    func testHeatmapThresholdsAreQuartilesOfNonZeroDays() {
        let totals = [0, 0, 10, 20, 30, 40, 50, 60, 70, 80]

        let thresholds = heatmapThresholds(for: totals)

        // Non-zero days sorted: 10...80 (8 values); q25/50/75 are the 2nd,
        // 4th and 6th, so the four levels get two days each.
        XCTAssertEqual(thresholds, [20, 40, 60, 80])
        XCTAssertEqual(heatmapLevel(forBytes: 10, thresholds: thresholds), 1)
        XCTAssertEqual(heatmapLevel(forBytes: 30, thresholds: thresholds), 2)
        XCTAssertEqual(heatmapLevel(forBytes: 50, thresholds: thresholds), 3)
        XCTAssertEqual(heatmapLevel(forBytes: 80, thresholds: thresholds), 4)
    }

    func testHeatmapLevelKeepsContrastWhenOneDaySpikes() {
        // A single huge outlier must not flatten the ordinary days: each
        // quarter of the active days still lands in a distinct level.
        let totals = [100, 200, 300, 400, 500_000_000]
        let thresholds = heatmapThresholds(for: totals)

        // thresholds == [200, 300, 400, 500_000_000]
        XCTAssertEqual(heatmapLevel(forBytes: 100, thresholds: thresholds), 1)
        XCTAssertEqual(heatmapLevel(forBytes: 300, thresholds: thresholds), 2)
        XCTAssertEqual(heatmapLevel(forBytes: 400, thresholds: thresholds), 3)
        XCTAssertEqual(heatmapLevel(forBytes: 500_000_000, thresholds: thresholds), 4)
    }

    func testHeatmapLevelIsZeroForEmptyAndNoTraffic() {
        XCTAssertEqual(heatmapThresholds(for: [0, 0, 0]), [])
        XCTAssertEqual(heatmapLevel(forBytes: 0, thresholds: [1, 2, 3, 4]), 0)
        XCTAssertEqual(heatmapLevel(forBytes: 5, thresholds: []), 0)
    }

    func testHeatmapLegendMatchesCellLevelOpacities() {
        XCTAssertEqual(heatmapLevelOpacities.count, 5)
        for level in 1..<heatmapLevelOpacities.count {
            XCTAssertLessThan(heatmapLevelOpacities[level - 1], heatmapLevelOpacities[level])
        }
    }

    func testNettopParserHandlesQuotedCommaInProcessName() {
        let row = Network().parser(text: "\"My, Browser.42\",100,200")

        XCTAssertEqual(row?.inBytes, 100)
        XCTAssertEqual(row?.outBytes, 200)
    }

    func testNettopParserRejectsUnclosedQuotedField() {
        XCTAssertNil(Network().parser(text: "\"My, Browser.42,100,200"))
    }

    func testNettopParserRejectsNonNumericByteFields() {
        // A row whose byte fields are not numbers must be rejected so it is
        // counted as dropped, not kept with a zeroed field. The name field is
        // not inspected, so an odd name is still a valid byte row.
        XCTAssertNil(Network().parser(text: "Foo.123,abc,200,"))
        XCTAssertNil(Network().parser(text: "Foo.123,100,xyz,"))
        XCTAssertNotNil(Network().parser(text: "Foo.bar,100,200,"))
    }

    func testNettopParserClampsNegativeByteDeltaToZero() {
        let row = Network().parser(text: "Foo.123,-5,200,")

        XCTAssertEqual(row?.inBytes, 0)
        XCTAssertEqual(row?.outBytes, 200)
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
        let row = Network().parser(text: "Codex (Service).1084,6264839,0,")

        XCTAssertEqual(row?.inBytes, 6_264_839)
        XCTAssertEqual(row?.outBytes, 0)
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
        // deadline tied to stdout EOF would settle instantly; the deadline
        // must follow the process without blocking a permanent waiter.
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

    func testProcessHelperRejectsOversizedOutputAndReturnsPromptly() {
        let start = Date()
        let output = runProcessCollectingOutput(
            executable: "/usr/bin/yes",
            arguments: ["output"],
            timeout: 2,
            maximumOutputBytes: 4 * 1024
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(output)
        XCTAssertLessThan(elapsed, 10)
    }

    func testProcessHelperRepeatedNormalExitReturnsCompleteOutput() {
        for _ in 0..<100 {
            let output = runProcessCollectingOutput(
                executable: "/bin/echo",
                arguments: ["hello"],
                timeout: 2
            )
            XCTAssertEqual(
                output?.trimmingCharacters(in: .whitespacesAndNewlines),
                "hello"
            )
        }
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
            rawOutBytes: 50
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
