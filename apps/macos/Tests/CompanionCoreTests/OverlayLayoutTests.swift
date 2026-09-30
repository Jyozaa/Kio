import XCTest
@testable import CompanionCore

final class OverlayLayoutTests: XCTestCase {
    func testNotchOverlayConnectsToSafeAreaAndCentersAcrossDynamicWidth() {
        let screen = OverlayScreenGeometry(
            x: 0,
            y: 0,
            width: 2056,
            height: 1329,
            visibleTop: 1290,
            safeTop: 38,
            hasNotch: true
        )
        let frame = screen.overlayFrame(width: 360, height: 110)
        XCTAssertEqual(frame.maxY, 1291)
        XCTAssertEqual(frame.x + frame.width / 2, 1028)
        XCTAssertEqual(frame.width, 360)
    }

    func testNonNotchedDisplayUsesMenuBarSafeTopAndNegativeOrigin() {
        let screen = OverlayScreenGeometry(
            x: -1920,
            y: 0,
            width: 1920,
            height: 1080,
            visibleTop: 1056,
            safeTop: 0,
            hasNotch: false
        )
        let frame = screen.overlayFrame(width: 360, height: 90)
        XCTAssertEqual(frame.maxY, 1056)
        XCTAssertEqual(frame.x + frame.width / 2, -960)
    }

    func testOverlayWidthStaysInsideNarrowDisplay() {
        let screen = OverlayScreenGeometry(
            x: 0,
            y: 0,
            width: 300,
            height: 700,
            visibleTop: 676,
            safeTop: 0,
            hasNotch: false
        )
        let frame = screen.overlayFrame(width: 500, height: 100)
        XCTAssertLessThanOrEqual(frame.width, 268)
        XCTAssertGreaterThanOrEqual(frame.x, 16)
    }
}
