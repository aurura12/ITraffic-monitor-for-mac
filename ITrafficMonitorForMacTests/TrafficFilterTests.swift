import XCTest
@testable import ITraffic

final class TrafficFilterTests: XCTestCase {
    func testNettopSamplingStatusMarksRestartAndRecoversOnFrame() {
        XCTAssertEqual(
            nextNettopSamplingStatus(.active, event: .restart),
            .restarting
        )
        XCTAssertEqual(
            nextNettopSamplingStatus(.restarting, event: .frame),
            .active
        )
    }

    func testNettopSamplingStatusReportsFailureUntilAFrameArrives() {
        XCTAssertEqual(
            nextNettopSamplingStatus(.restarting, event: .failure),
            .failed
        )
        XCTAssertEqual(
            nextNettopSamplingStatus(.failed, event: .restart),
            .restarting
        )
        XCTAssertEqual(
            nextNettopSamplingStatus(.failed, event: .frame),
            .active
        )
    }

    func testNettopRestartBackoffDoublesUpToTheCap() {
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: 0), 0.5)
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: 1), 1)
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: 2), 2)
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: 3), 4)
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: 4), 8)
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: 6), 30)
        // A long-running failure stays at the cap instead of overflowing.
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: 10_000), 30)
        XCTAssertEqual(nettopRestartDelay(consecutiveFailures: -3), 0.5)
        // The threshold is reachable well before the cap makes retries cheap.
        XCTAssertLessThan(
            nettopRestartDelay(consecutiveFailures: nettopRestartFailureThreshold),
            nettopRestartMaximumDelay
        )
    }

    func testMenuBarRateTextPlacesUploadAboveDownloadInCompactRows() {
        let text = MenuBarRateText(downloadRate: 1_572_864, uploadRate: 327_680)

        XCTAssertEqual(text.rows, ["↑ 320K/s", "↓ 1.5M/s"])
    }

    func testMenuBarLayoutLeavesOnlyTightHorizontalPadding() {
        XCTAssertEqual(MenuBarLayout.statusItemHorizontalPadding, 4)
    }
}
