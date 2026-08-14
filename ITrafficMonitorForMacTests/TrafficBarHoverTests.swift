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

    func testProxyCreditsRemainUsableWhenProxyEntityIsNotVisible() {
        XCTAssertEqual(capProxyCredit(requested: 500, observedByNettop: 0, proxyVisible: false), 0)
    }

    func testProxyCreditsAreCappedByObservedProxyBytes() {
        XCTAssertEqual(capProxyCredit(requested: 500, observedByNettop: 300, proxyVisible: true), 300)
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
}
