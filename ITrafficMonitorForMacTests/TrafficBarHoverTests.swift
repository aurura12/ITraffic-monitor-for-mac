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
}
