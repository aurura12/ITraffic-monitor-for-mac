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

    func testUnattributedTunnelLabelIsExplicit() {
        XCTAssertEqual(unattributedTunnelProcessLabel, "VPN/TUN 未识别流量")
    }

    func testProxyCreditsAreDiscardedWhenProxyEntityIsNotVisible() {
        XCTAssertEqual(capProxyCredit(requested: 500, observedByNettop: 0, proxyVisible: false), 0)
    }

    func testProxyCreditsAreCappedByObservedProxyBytes() {
        XCTAssertEqual(capProxyCredit(requested: 500, observedByNettop: 300, proxyVisible: true), 300)
    }

    func testUnattributedTunnelUsesDedicatedAppKey() {
        let entity = ProcessEntity(
            pid: 123,
            name: unattributedTunnelProcessLabel,
            inBytes: 10,
            outBytes: 20
        )

        XCTAssertEqual(entity.appKey, unattributedTunnelAppKey)
        XCTAssertEqual(entity.displayName, unattributedTunnelProcessLabel)
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
}
