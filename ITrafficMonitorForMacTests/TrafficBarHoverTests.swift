import XCTest
import CoreGraphics
@testable import ITraffic

final class TrafficBarHoverTests: XCTestCase {
    private enum TestError: Error {
        case registrationFailed
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

    func testUnixSocketCurlOutputParsesStatusAndBody() {
        let output = "{\"connections\":[]}\n__ITRAFFIC_STATUS__:200\n"

        let response = parseUnixSocketCurlOutput(output)

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.body, "{\"connections\":[]}")
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

    func testExpiredPendingCreditsAreRemovedBeforeAttribution() {
        let pending = [
            PendingProxyCredit(timestamp: 10, pid: 1, inBytes: 100, outBytes: 0),
            PendingProxyCredit(timestamp: 11, pid: 2, inBytes: 0, outBytes: 50)
        ]

        let result = expirePendingProxyCredits(pending, now: 21, ttl: 10)

        XCTAssertEqual(result.expired, [PendingProxyCredit(timestamp: 10, pid: 1, inBytes: 100, outBytes: 0)])
        XCTAssertEqual(result.active, [PendingProxyCredit(timestamp: 11, pid: 2, inBytes: 0, outBytes: 50)])
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
            trafficBucketRangeLabel(for: date, timeRange: .today, calendar: calendar),
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
            trafficBucketRangeLabel(for: rawDate, timeRange: .today, calendar: calendar),
            "19:00–20:00"
        )
    }

    // MARK: - Proxy attribution window budget

    func testProxyCumulativeAtReturnsZeroBeforeFirstSample() {
        let history = [
            ProxyCumulativePoint(timestamp: 100, inBytes: 1_000, outBytes: 200),
            ProxyCumulativePoint(timestamp: 102, inBytes: 3_000, outBytes: 400)
        ]

        let early = proxyCumulativeAt(history, time: 99)
        XCTAssertEqual(early.inBytes, 0)
        XCTAssertEqual(early.outBytes, 0)

        let inWindow = proxyCumulativeAt(history, time: 101)
        XCTAssertEqual(inWindow.inBytes, 1_000)
        XCTAssertEqual(inWindow.outBytes, 200)

        let latest = proxyCumulativeAt(history, time: 200)
        XCTAssertEqual(latest.inBytes, 3_000)
        XCTAssertEqual(latest.outBytes, 400)
    }

    func testProxyCumulativeDeltaMeasuresBytesSinceCreditCreated() {
        let history = [
            ProxyCumulativePoint(timestamp: 100, inBytes: 1_000, outBytes: 100),
            ProxyCumulativePoint(timestamp: 104, inBytes: 4_000, outBytes: 300)
        ]

        let delta = proxyCumulativeDelta(history: history, since: 101, now: 104)
        XCTAssertEqual(delta.inBytes, 3_000)
        XCTAssertEqual(delta.outBytes, 200)

        let beforeStart = proxyCumulativeDelta(history: history, since: 99, now: 104)
        XCTAssertEqual(beforeStart.inBytes, 4_000)
    }

    func testAppendProxyCumulativePointAccumulatesAndPrunesOldSamples() {
        var history: [ProxyCumulativePoint] = []
        history = appendProxyCumulativePoint(history, timestamp: 100, deltaIn: 1_000, deltaOut: 100, ttl: 60)
        history = appendProxyCumulativePoint(history, timestamp: 102, deltaIn: 2_000, deltaOut: 50, ttl: 60)
        // 162 - 100 = 62 > 60, so the t=100 sample is pruned; t=102 is kept.
        history = appendProxyCumulativePoint(history, timestamp: 162, deltaIn: 500, deltaOut: 0, ttl: 60)

        XCTAssertEqual(history.map(\.timestamp), [102, 162])
        XCTAssertEqual(history.last?.inBytes, 3_500)
        XCTAssertEqual(history.last?.outBytes, 150)
    }

    func testAppendProxyCumulativePointClampsNegativeDeltas() {
        var history: [ProxyCumulativePoint] = []
        history = appendProxyCumulativePoint(history, timestamp: 100, deltaIn: 1_000, deltaOut: 0, ttl: 60)
        // A counter reset / negative frame must not shrink the running total.
        history = appendProxyCumulativePoint(history, timestamp: 102, deltaIn: -500, deltaOut: 0, ttl: 60)

        XCTAssertEqual(history.last?.inBytes, 1_000)
    }

    func testWindowBudgetCoversBytesSinceOldestPendingCredit() {
        let credits = [
            PendingProxyCredit(timestamp: 100, pid: 1, inBytes: 900, outBytes: 0),
            PendingProxyCredit(timestamp: 104, pid: 2, inBytes: 900, outBytes: 0)
        ]
        let cumulative = [
            ProxyCumulativePoint(timestamp: 102, inBytes: 1_200, outBytes: 0),
            ProxyCumulativePoint(timestamp: 106, inBytes: 2_400, outBytes: 0)
        ]

        // Oldest credit at t=100 predates the first sample, so the whole
        // observed window counts.
        let budget = proxyCreditWindowBudget(credits: credits, cumulative: cumulative, now: 106)
        XCTAssertEqual(budget.inBytes, 2_400)
    }

    func testConsumePendingCreditsUsesWindowBudget() {
        let credits = [
            PendingProxyCredit(timestamp: 100, pid: 1, inBytes: 900, outBytes: 0),
            PendingProxyCredit(timestamp: 102, pid: 2, inBytes: 900, outBytes: 0)
        ]
        let cumulative = [ProxyCumulativePoint(timestamp: 106, inBytes: 1_000, outBytes: 0)]

        let result = consumePendingProxyCredits(credits, cumulative: cumulative, now: 106)

        XCTAssertEqual(result.credited[1]?.inBytes, 900)
        XCTAssertEqual(result.credited[2]?.inBytes, 100)
        XCTAssertEqual(result.remaining, [
            PendingProxyCredit(timestamp: 102, pid: 2, inBytes: 800, outBytes: 0)
        ])
    }

    // MARK: - Proxy redistribution

    func testRedistributionIsDisabledWhenProxyNotDetected() {
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 900, outBytes: 0)],
            proxyDetected: false,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000, outBytes: 0)],
            now: 101
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [:])

        XCTAssertEqual(outcome.entities.first?.inBytes, 1_000)
        XCTAssertTrue(outcome.consumed.isEmpty)
        XCTAssertEqual(outcome.remaining.count, 1)
    }

    func testRedistributionRunsWhenProxyDetectedButPIDUnresolved() {
        // Regression: the proxy core runs as root and is invisible to the
        // app's lsof, so proxyPIDs may be empty. Redistribution must still
        // credit apps via name matching instead of silently keeping traffic on
        // the proxy.
        let raw = [
            ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000_000, outBytes: 0),
            ProcessEntity(pid: 61013, name: "Google Chrome H", inBytes: 100, outBytes: 0)
        ]
        let snapshot = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 900_000, outBytes: 0)],
            proxyDetected: true,
            proxyPIDs: [],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000_000, outBytes: 0)],
            now: 101
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"])

        XCTAssertEqual(outcome.consumed[61013]?.inBytes, 900_000)
        let proxy = outcome.entities.first { $0.pid == 91681 }
        XCTAssertEqual(proxy?.inBytes, 100_000, "Proxy keeps only its own uncarried bytes")
        let chrome = outcome.entities.first { $0.pid == 61013 }
        XCTAssertEqual(chrome?.inBytes, 900_100)
    }

    func testRedistributionDefersCreditsWhenProxyRowAbsent() {
        let raw = [ProcessEntity(pid: 61013, name: "Google Chrome H", inBytes: 100, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 900, outBytes: 0)],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 900, outBytes: 0)],
            now: 101
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [:])

        XCTAssertTrue(outcome.consumed.isEmpty)
        XCTAssertEqual(outcome.remaining, snapshot.credits)
    }

    func testProxyRowSelectionPrefersMatchingRowCarryingBytes() {
        // Regression: user-level lsof can leave a garbage pid (e.g.
        // loginwindow) in proxyPIDs when the core runs as root. When that
        // process appears in a frame before the real proxy row, first-match
        // logic picked it (0 bytes) and the real Clash row was never drained —
        // the same bytes then counted on both Clash and the credited app.
        let raw = [
            ProcessEntity(pid: 166, name: "loginwindow", inBytes: 0, outBytes: 0),
            ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000_000, outBytes: 0)
        ]
        let snapshot = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 900_000, outBytes: 0)],
            proxyDetected: true,
            proxyPIDs: [166, 91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000_000, outBytes: 0)],
            now: 101
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"])

        let proxy = outcome.entities.first { $0.pid == 91681 }
        XCTAssertEqual(proxy?.inBytes, 100_000, "Real proxy row must be drained by the credited bytes")
        XCTAssertEqual(outcome.consumed[61013]?.inBytes, 900_000)
        // loginwindow must keep its (empty) row untouched.
        XCTAssertEqual(outcome.entities.first { $0.pid == 166 }?.inBytes, 0)
    }

    func testProxyDebtCarriesForwardSoLateProxyBytesStillDrained() {
        // Regression: nettop reports the proxy row in bursts that lag the
        // credit window. Frame 1 consumes credits while the proxy row shows no
        // bytes — the app is credited and the undrained amount becomes debt.
        let raw1 = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 0, outBytes: 0)]
        let snap1 = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 100, pid: 61013, inBytes: 900, outBytes: 0)],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000, outBytes: 0)],
            now: 101
        )
        let out1 = redistributeProxyTraffic(raw: raw1, snapshot: snap1, pidNames: [61013: "Google Chrome H"])
        XCTAssertEqual(out1.consumed[61013]?.inBytes, 900)
        XCTAssertEqual(out1.remainingDebtIn, 900, "Undrained credit must carry forward as debt")

        // Frame 2: the proxy row finally reports the bytes with no new
        // credits. The carried debt must drain the row — otherwise the same
        // bytes count on both the proxy and the credited app.
        let raw2 = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000, outBytes: 0)]
        let snap2 = ProxyAttributionSnapshot(
            credits: [],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 102, inBytes: 1_000, outBytes: 0)],
            now: 102,
            proxyDebtIn: out1.remainingDebtIn,
            proxyDebtOut: out1.remainingDebtOut
        )
        let out2 = redistributeProxyTraffic(raw: raw2, snapshot: snap2, pidNames: [:])
        XCTAssertEqual(out2.entities.first { $0.pid == 91681 }?.inBytes, 100, "Carried debt must drain the late proxy bytes")
        XCTAssertEqual(out2.remainingDebtIn, 0, "Debt is exhausted once the proxy bytes are drained")
    }

    func testRedistributionCreatesNewEntityForCreditedAppWithNoDirectTraffic() {
        // Chrome sits behind a system proxy and never touches the external
        // interface, so it has no nettop row; the credited bytes become a new
        // entity. A fake high pid keeps name resolution deterministic.
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 100, pid: 429_001, inBytes: 900, outBytes: 0)],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000, outBytes: 0)],
            now: 101
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [429_001: "Google Chrome H"])

        let chrome = outcome.entities.first { $0.pid == 429_001 }
        XCTAssertEqual(chrome?.inBytes, 900)
        XCTAssertEqual(chrome?.name, "Google Chrome H")
        XCTAssertEqual(outcome.entities.count, 2)
    }

    // MARK: - Recovery credits (expired credits whose process is still alive)

    func testRecoveryCreditsAreConsumedAndDrainProxyRow() {
        // A credit expired while the proxy row was absent (age 31 > TTL 30) but
        // its owning process is still alive, so it is re-queued in the recovery
        // list. Consumption must credit the specific app and drain the proxy row
        // exactly like a normal pending credit.
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000_000, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000_000, outBytes: 0)],
            now: 101,
            proxyDebtIn: 0,
            proxyDebtOut: 0,
            recoveryCredits: [PendingProxyCredit(timestamp: 70, pid: 61013, inBytes: 900_000, outBytes: 0)]
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"], creditTTL: 30)

        XCTAssertEqual(outcome.consumed[61013]?.inBytes, 900_000)
        let proxy = outcome.entities.first { $0.pid == 91681 }
        XCTAssertEqual(proxy?.inBytes, 100_000, "Recovered bytes must drain the proxy row")
        let chrome = outcome.entities.first { $0.pid == 61013 }
        XCTAssertEqual(chrome?.inBytes, 900_000)
        XCTAssertTrue(outcome.remainingRecovery.isEmpty)
    }

    func testRecoveryCreditsConsumeBeforePendingCredits() {
        // Recovery credits are older than fresh pending credits; consuming the
        // shared window budget oldest-first must credit the recovered pid first
        // so the older bytes are not stranded behind new ones.
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000_000, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 100, pid: 429_002, inBytes: 200_000, outBytes: 0)],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000_000, outBytes: 0)],
            now: 101,
            recoveryCredits: [PendingProxyCredit(timestamp: 70, pid: 61013, inBytes: 900_000, outBytes: 0)]
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H", 429_002: "Safari"], creditTTL: 30)

        XCTAssertEqual(outcome.consumed[61013]?.inBytes, 900_000, "Recovery consumes its full share first")
        XCTAssertEqual(outcome.consumed[429_002]?.inBytes, 100_000)
    }

    func testUnconsumedRecoveryCreditSplitsBackToRecoveryNotPending() {
        // When the budget cannot cover the whole recovery credit, the remainder
        // must return to the recovery list (it is older than the pending TTL and
        // must not be re-expired by the normal pending logic).
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000_000, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 100_000, outBytes: 0)],
            now: 101,
            recoveryCredits: [PendingProxyCredit(timestamp: 70, pid: 61013, inBytes: 900_000, outBytes: 0)]
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"], creditTTL: 30)

        XCTAssertEqual(outcome.consumed[61013]?.inBytes, 100_000)
        XCTAssertTrue(outcome.remaining.isEmpty)
        XCTAssertEqual(outcome.remainingRecovery, [
            PendingProxyCredit(timestamp: 70, pid: 61013, inBytes: 800_000, outBytes: 0)
        ])
    }

    func testFreshPendingCreditStaysPendingNotRecovery() {
        // A pending credit younger than the TTL must remain pending after an
        // unconsumed frame, never classified as recovery.
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000_000, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [PendingProxyCredit(timestamp: 90, pid: 61013, inBytes: 900_000, outBytes: 0)],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 100_000, outBytes: 0)],
            now: 101,
            recoveryCredits: []
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"], creditTTL: 30)

        XCTAssertEqual(outcome.consumed[61013]?.inBytes, 100_000)
        XCTAssertEqual(outcome.remaining, [PendingProxyCredit(timestamp: 90, pid: 61013, inBytes: 800_000, outBytes: 0)])
        XCTAssertTrue(outcome.remainingRecovery.isEmpty)
    }

    func testRedistributionCarriesRecoveryCreditsWhenProxyRowAbsent() {
        // No proxy row this frame: recovery credits must be preserved for a
        // later frame instead of being dropped.
        let raw = [ProcessEntity(pid: 61013, name: "Google Chrome H", inBytes: 100, outBytes: 0)]
        let snapshot = ProxyAttributionSnapshot(
            credits: [],
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 100_000, outBytes: 0)],
            now: 101,
            recoveryCredits: [PendingProxyCredit(timestamp: 70, pid: 61013, inBytes: 900_000, outBytes: 0)]
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [:], creditTTL: 30)

        XCTAssertTrue(outcome.consumed.isEmpty)
        XCTAssertEqual(outcome.remainingRecovery, snapshot.recoveryCredits)
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

    // MARK: - Proxy foreground fallback

    private func foregroundSnapshot(
        foregroundPID: Int?,
        activeProxyPIDs: Set<Int>,
        enabled: Bool,
        credits: [PendingProxyCredit] = []
    ) -> ProxyAttributionSnapshot {
        ProxyAttributionSnapshot(
            credits: credits,
            proxyDetected: true,
            proxyPIDs: [91681],
            isClashVergeProxy: true,
            cumulativeProxy: [ProxyCumulativePoint(timestamp: 101, inBytes: 1_000_000, outBytes: 0)],
            now: 101,
            foregroundPID: foregroundPID,
            activeProxyPIDs: activeProxyPIDs,
            foregroundAttributionEnabled: enabled
        )
    }

    func testForegroundFallbackMovesResidualFromProxyToForegroundApp() {
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 1_000_000, outBytes: 0)]
        let snapshot = foregroundSnapshot(
            foregroundPID: 429_002,
            activeProxyPIDs: [429_002],
            enabled: true,
            credits: [PendingProxyCredit(timestamp: 100, pid: 429_002, inBytes: 400_000, outBytes: 0)]
        )

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [429_002: "Google Chrome H"])

        let proxy = outcome.entities.first { $0.pid == 91681 }
        let chrome = outcome.entities.first { $0.pid == 429_002 }
        XCTAssertEqual(proxy?.inBytes, 0, "Residual must be drained from the proxy row")
        XCTAssertEqual(chrome?.inBytes, 1_000_000, "Consumed credit plus drained residual")
        XCTAssertEqual(chrome?.name, "Google Chrome H")
    }

    func testForegroundFallbackAddsToExistingForegroundEntity() {
        let raw = [
            ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 500_000, outBytes: 0),
            ProcessEntity(pid: 61013, name: "Google Chrome H", inBytes: 100, outBytes: 0)
        ]
        let snapshot = foregroundSnapshot(foregroundPID: 61013, activeProxyPIDs: [61013], enabled: true)

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"])

        let chrome = outcome.entities.first { $0.pid == 61013 }
        let proxy = outcome.entities.first { $0.pid == 91681 }
        XCTAssertEqual(chrome?.inBytes, 500_100)
        XCTAssertEqual(proxy?.inBytes, 0)
    }

    func testForegroundFallbackCreatesNewEntityForFrontmostAppWithNoRow() {
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 500_000, outBytes: 0)]
        let snapshot = foregroundSnapshot(foregroundPID: 429_003, activeProxyPIDs: [429_003], enabled: true)

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [:])

        let chrome = outcome.entities.first { $0.pid == 429_003 }
        XCTAssertEqual(chrome?.inBytes, 500_000)
        XCTAssertEqual(chrome?.name, "429003", "pidNames fallback is the numeric pid")
        XCTAssertEqual(outcome.entities.count, 2)
    }

    func testForegroundFallbackSkipsWhenForegroundIsProxyPID() {
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 500_000, outBytes: 0)]
        let snapshot = foregroundSnapshot(foregroundPID: 91681, activeProxyPIDs: [91681], enabled: true)

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [:])

        XCTAssertEqual(outcome.entities.first?.inBytes, 500_000, "Residual stays on the proxy")
        XCTAssertEqual(outcome.entities.count, 1)
    }

    func testForegroundFallbackSkipsWhenForegroundNotUsingProxy() {
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 500_000, outBytes: 0)]
        let snapshot = foregroundSnapshot(foregroundPID: 61013, activeProxyPIDs: [], enabled: true)

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"])

        XCTAssertEqual(outcome.entities.first?.inBytes, 500_000, "Guardrail: foreground app must actually use the proxy")
        XCTAssertEqual(outcome.entities.count, 1)
    }

    func testForegroundFallbackSkipsWhenDisabled() {
        let raw = [ProcessEntity(pid: 91681, name: "verge-mihomo", inBytes: 500_000, outBytes: 0)]
        let snapshot = foregroundSnapshot(foregroundPID: 61013, activeProxyPIDs: [61013], enabled: false)

        let outcome = redistributeProxyTraffic(raw: raw, snapshot: snapshot, pidNames: [61013: "Google Chrome H"])

        XCTAssertEqual(outcome.entities.first?.inBytes, 500_000)
        XCTAssertEqual(outcome.entities.count, 1)
    }
}
