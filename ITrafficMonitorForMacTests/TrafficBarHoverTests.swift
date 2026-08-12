import XCTest
import CoreGraphics
@testable import ITraffic

final class TrafficBarHoverTests: XCTestCase {
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
}
