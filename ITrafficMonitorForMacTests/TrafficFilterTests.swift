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

    func testMenuBarRateTextPlacesUploadAboveDownloadInCompactRows() {
        let text = MenuBarRateText(downloadRate: 1_572_864, uploadRate: 327_680)

        XCTAssertEqual(text.rows, ["↑ 320K/s", "↓ 1.5M/s"])
    }

    func testMenuBarLayoutLeavesOnlyTightHorizontalPadding() {
        XCTAssertEqual(MenuBarLayout.statusItemHorizontalPadding, 4)
    }
}
