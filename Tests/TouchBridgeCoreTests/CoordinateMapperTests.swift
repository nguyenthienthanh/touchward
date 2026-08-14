import CoreGraphics
import XCTest
@testable import TouchBridgeCore

/// The real geometry on this machine: the touchscreen sits to the LEFT of the main
/// display, so its global origin is negative. Every assertion here exists to stop a
/// regression back to the "assume origin is (0,0)" bug.
private let touchDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

final class CoordinateMapperTests: XCTestCase {

    func testOriginMapsToDisplayOriginNotScreenZero() {
        let mapper = CoordinateMapper(displayBounds: touchDisplay)
        XCTAssertEqual(mapper.globalPoint(x: 0, y: 0), CGPoint(x: -1920, y: 0))
    }

    func testFarCornerMapsToDisplayFarCorner() {
        let mapper = CoordinateMapper(displayBounds: touchDisplay)
        XCTAssertEqual(mapper.globalPoint(x: 4095, y: 4095), CGPoint(x: 0, y: 1080))
    }

    func testCentreOfPanelMapsToCentreOfDisplay() {
        let mapper = CoordinateMapper(displayBounds: touchDisplay)
        let p = mapper.globalPoint(x: 2047, y: 2047)

        XCTAssertEqual(p.x, -960, accuracy: 1.0)
        XCTAssertEqual(p.y, 540, accuracy: 1.0)
    }

    /// The X axis is independent of the Y axis even though both share a 0…4095 range
    /// while the display is 16:9 — a swapped-axis bug would pass a square-display test.
    func testAxesAreNotSwapped() {
        let mapper = CoordinateMapper(displayBounds: touchDisplay)
        let p = mapper.globalPoint(x: 4095, y: 0)

        XCTAssertEqual(p.x, 0, accuracy: 0.5)
        XCTAssertEqual(p.y, 0, accuracy: 0.5)
    }

    func testWorksForADisplayAtPositiveOrigin() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(mapper.globalPoint(x: 4095, y: 4095), CGPoint(x: 2560, y: 1440))
    }

    func testCalibrationTrimsTheActiveArea() {
        // Panel only reports usable data across the middle half of each axis.
        let calibration = Calibration(xMin: 0.25, xMax: 0.75, yMin: 0.25, yMax: 0.75)
        let mapper = CoordinateMapper(displayBounds: touchDisplay, calibration: calibration)

        // The lower calibration bound must now land on the display's left edge.
        let atLowerBound = mapper.globalPoint(x: Int(4095 * 0.25), y: Int(4095 * 0.25))
        XCTAssertEqual(atLowerBound.x, -1920, accuracy: 2.0)
        XCTAssertEqual(atLowerBound.y, 0, accuracy: 2.0)

        let atUpperBound = mapper.globalPoint(x: Int(4095 * 0.75), y: Int(4095 * 0.75))
        XCTAssertEqual(atUpperBound.x, 0, accuracy: 2.0)
        XCTAssertEqual(atUpperBound.y, 1080, accuracy: 2.0)
    }

    /// Touching outside the calibrated area must stay on the display, not fly onto
    /// the main screen and click something there.
    func testPointsOutsideCalibrationAreClampedToTheDisplay() {
        let calibration = Calibration(xMin: 0.25, xMax: 0.75, yMin: 0.25, yMax: 0.75)
        let mapper = CoordinateMapper(displayBounds: touchDisplay, calibration: calibration)

        let p = mapper.globalPoint(x: 4095, y: 4095)
        XCTAssertLessThanOrEqual(p.x, 0)
        XCTAssertGreaterThanOrEqual(p.x, -1920)
        XCTAssertLessThanOrEqual(p.y, 1080)
    }

    func testMapsAWholeFramePreservingContactIdentity() {
        let mapper = CoordinateMapper(displayBounds: touchDisplay)
        let frame = TouchFrame(contacts: [
            Contact(id: 3, x: 0, y: 0, isTouching: true),
            Contact(id: 9, x: 4095, y: 4095, isTouching: true),
        ], time: 5.0)

        let mapped = mapper.map(frame)

        XCTAssertEqual(mapped.time, 5.0)
        XCTAssertEqual(mapped.contacts.map(\.id), [3, 9])
        XCTAssertEqual(mapped.contacts[0].point, CGPoint(x: -1920, y: 0))
        XCTAssertEqual(mapped.contacts[1].point, CGPoint(x: 0, y: 1080))
    }
}
