import CoreGraphics
import XCTest
@testable import TouchwardCore

/// Contracts that exist because the stream is hardware: reports arrive late, stop without
/// warning, and contact identities are not stable.
final class RobustnessTests: XCTestCase {

    // MARK: contact count

    /// Slots past the reported contact count hold stale data — tip bit included. Trusting
    /// per-slot flags alone invents a second finger and silently kills taps and drags.
    // MARK: report ID prefix

    /// IOKit hands some devices the body with the report ID still at byte 0. Parsing that
    /// as flags shifts every field by one and produces garbage coordinates.
    // MARK: mixed report streams

    /// The controller may emit both collections. Feeding both into one state machine makes
    /// a single-contact mouse report look like a finger lift mid-scroll.
    // MARK: the stream stopping

    /// Unplug, sleep, or a dropped final report must not leave the left button held down.
    func testStaleStreamReleasesAHeldDrag() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: .zero)], time: 0))
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: CGPoint(x: 100, y: 0))], time: 0.1))

        // Well past staleDragTimeout: the stream is gone, the button must not stay down.
        let events = r.tick(at: 5.0)
        XCTAssertEqual(events, [.dragEnded(at: CGPoint(x: 100, y: 0))])
    }

    /// Quit and unplug both route here; neither may leave a button logically pressed.
    func testForceReleaseClosesOutAHeldDrag() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: .zero)], time: 0))
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: CGPoint(x: 100, y: 0))], time: 0.05))

        XCTAssertEqual(r.forceRelease(), [.dragEnded(at: CGPoint(x: 100, y: 0)), .sessionEnded])
        XCTAssertEqual(r.forceRelease(), [], "releasing twice must be harmless")
        XCTAssertFalse(r.hasActiveGesture)
    }

    func testTickWhileIdleEmitsNothing() {
        var r = GestureRecognizer()
        XCTAssertEqual(r.tick(at: 99), [])
    }

    /// A finger held perfectly still generates no new reports on a change-driven device,
    /// so the long press has to be driven by the clock instead.
    func testLongPressFiresFromTickWithoutAnyNewFrames() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: CGPoint(x: 50, y: 60))], time: 0))

        XCTAssertEqual(r.tick(at: 0.65), [.rightClick(at: CGPoint(x: 50, y: 60))])
        XCTAssertEqual(r.tick(at: 0.70), [], "must not repeat while the finger is still down")
    }

    /// A tick must never end a session that is merely young — only one that has gone quiet.
    func testTickDoesNotAbandonAFreshTouch() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: .zero)], time: 0))

        XCTAssertEqual(r.tick(at: 0.1), [])
    }

    // MARK: contact identity

    /// If the tracked finger vanishes and a different one is present, continuing the drag
    /// would teleport the pointer and drop it on the wrong target.
    func testDragEndsWhenTheTrackedFingerIsReplaced() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: .zero)], time: 0))
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: CGPoint(x: 100, y: 0))], time: 0.05))

        let events = r.handle(MappedFrame(contacts: [MappedContact(id: 7, point: CGPoint(x: 900, y: 500))], time: 0.1))
        XCTAssertEqual(events, [.dragEnded(at: CGPoint(x: 100, y: 0))],
                       "the drag closes where it was, but the session lives on — a finger "
                       + "is still down, and ending it would warp the cursor away")
    }

    func testTapIsAbandonedWhenTheTrackedFingerIsReplaced() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: .zero)], time: 0))

        let events = r.handle(MappedFrame(contacts: [MappedContact(id: 2, point: CGPoint(x: 800, y: 400))], time: 0.05))
        XCTAssertFalse(events.contains { if case .leftClick = $0 { return true } else { return false } })
    }

    /// Contacts do not have to occupy the first N slots; a controller may use 0 and 3.
    /// The buttons byte can legitimately be 0x03 (both buttons). A 5-byte report is a body,
    /// not a prefixed one, and eating byte 0 would read X and Y from the wrong offsets.
    /// A palm is huge in one axis; checking only width would let a forearm through.
    /// Pins the shipped default rather than only ever testing an explicit argument.
    // MARK: calibration sanity

    func testDegenerateYRangeFallsBackIndependentlyOfX() {
        let mapper = CoordinateMapper(
            logicalMaxX: 4095, logicalMaxY: 4095, displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            calibration: Calibration(xMin: 0.25, xMax: 0.75, yMin: 0.5, yMax: 0.5)
        )

        // X keeps its calibration, Y falls back to the full range.
        XCTAssertEqual(mapper.globalPoint(x: 4095, y: 4095), CGPoint(x: 1000, y: 1000))
        XCTAssertEqual(mapper.globalPoint(x: 2047, y: 0).y, 0, accuracy: 0.5)
    }

    func testCalibrationOutsideZeroToOneFallsBack() {
        let mapper = CoordinateMapper(
            logicalMaxX: 4095, logicalMaxY: 4095, displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            calibration: Calibration(xMin: 2, xMax: 3, yMin: 0, yMax: 1)
        )

        XCTAssertEqual(mapper.globalPoint(x: 0, y: 0), .zero)
        XCTAssertEqual(mapper.globalPoint(x: 4095, y: 4095), CGPoint(x: 1000, y: 1000))
    }

    func testDegenerateCalibrationFallsBackToIdentityInsteadOfPinningToTheEdge() {
        let mapper = CoordinateMapper(
            logicalMaxX: 4095, logicalMaxY: 4095, displayBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            calibration: Calibration(xMin: 0.8, xMax: 0.2, yMin: 0, yMax: 1)
        )

        XCTAssertEqual(mapper.globalPoint(x: 4095, y: 4095), CGPoint(x: 0, y: 1080))
    }
}
