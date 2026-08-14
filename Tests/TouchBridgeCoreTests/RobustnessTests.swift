import CoreGraphics
import XCTest
@testable import TouchBridgeCore

/// Contracts that exist because the stream is hardware: reports arrive late, stop without
/// warning, come from two collections at once, or carry stale slots.
final class RobustnessTests: XCTestCase {

    // MARK: contact count

    /// Slots past the reported contact count hold stale data — tip bit included. Trusting
    /// per-slot flags alone invents a second finger and silently kills taps and drags.
    func testSlotsBeyondContactCountAreIgnored() throws {
        var bytes = [UInt8](repeating: 0, count: 53)
        // Slot 0: a genuine finger.
        bytes[0] = 0x03; bytes[1] = 1; bytes[2] = 0x10; bytes[4] = 0x20
        // Slot 1: stale leftovers that still look "touching".
        bytes[10] = 0x03; bytes[11] = 9; bytes[12] = 0xFF; bytes[14] = 0xFF
        bytes[50] = 1  // the controller says: one contact

        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: bytes, time: 0))
        XCTAssertEqual(frame.contacts.map(\.id), [1])
    }

    func testContactCountLargerThanTheSlotArrayIsClamped() throws {
        var bytes = [UInt8](repeating: 0, count: 53)
        bytes[0] = 0x03; bytes[1] = 1
        bytes[50] = 200  // nonsense value must not index out of bounds

        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: bytes, time: 0))
        XCTAssertEqual(frame.contacts.count, 1)
    }

    // MARK: report ID prefix

    /// IOKit hands some devices the body with the report ID still at byte 0. Parsing that
    /// as flags shifts every field by one and produces garbage coordinates.
    func testDigitizerReportWithLeadingReportIDByteIsHandled() throws {
        var body = [UInt8](repeating: 0, count: 53)
        body[0] = 0x03; body[1] = 5; body[2] = 0x00; body[3] = 0x08; body[4] = 0x00; body[5] = 0x04
        body[50] = 1

        let prefixed = [ReportID.digitizer] + body

        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: prefixed, time: 0))
        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].id, 5)
        XCTAssertEqual(frame.contacts[0].x, 0x0800)
        XCTAssertEqual(frame.contacts[0].y, 0x0400)
    }

    func testMouseReportWithLeadingReportIDByteIsHandled() throws {
        let prefixed: [UInt8] = [ReportID.mouse, 0x01, 0xFF, 0x0F, 0x00, 0x00]

        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.mouse, bytes: prefixed, time: 0))
        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].x, 4095)
        XCTAssertEqual(frame.contacts[0].y, 0)
    }

    // MARK: mixed report streams

    /// The controller may emit both collections. Feeding both into one state machine makes
    /// a single-contact mouse report look like a finger lift mid-scroll.
    func testLatchIgnoresTheOtherCollectionOnceOneIsProducingContacts() {
        var latch = ReportStreamLatch()

        XCTAssertTrue(latch.accepts(reportID: ReportID.digitizer, hasContacts: true))
        XCTAssertFalse(latch.accepts(reportID: ReportID.mouse, hasContacts: true))
        XCTAssertTrue(latch.accepts(reportID: ReportID.digitizer, hasContacts: false),
                      "empty frames from the latched stream must still pass — they end the session")
    }

    func testLatchStaysOpenUntilSomethingActuallyReportsAContact() {
        var latch = ReportStreamLatch()

        XCTAssertTrue(latch.accepts(reportID: ReportID.digitizer, hasContacts: false))
        XCTAssertTrue(latch.accepts(reportID: ReportID.mouse, hasContacts: true),
                      "if the digitizer never produces contacts, the mouse collection wins")
        XCTAssertFalse(latch.accepts(reportID: ReportID.digitizer, hasContacts: true))
    }

    // MARK: the stream stopping

    /// Unplug, sleep, or a dropped final report must not leave the left button held down.
    func testStaleStreamReleasesAHeldDrag() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: .zero)], time: 0))
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: CGPoint(x: 100, y: 0))], time: 0.1))

        // Well past staleDragTimeout: the stream is gone, the button must not stay down.
        let events = r.tick(at: 5.0)
        XCTAssertEqual(events, [.dragEnded(at: CGPoint(x: 100, y: 0)), .sessionEnded])
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
        XCTAssertEqual(events, [.dragEnded(at: CGPoint(x: 100, y: 0)), .sessionEnded])
    }

    func testTapIsAbandonedWhenTheTrackedFingerIsReplaced() {
        var r = GestureRecognizer()
        _ = r.handle(MappedFrame(contacts: [MappedContact(id: 1, point: .zero)], time: 0))

        let events = r.handle(MappedFrame(contacts: [MappedContact(id: 2, point: CGPoint(x: 800, y: 400))], time: 0.05))
        XCTAssertFalse(events.contains { if case .leftClick = $0 { return true } else { return false } })
    }

    // MARK: calibration sanity

    func testDegenerateCalibrationFallsBackToIdentityInsteadOfPinningToTheEdge() {
        let mapper = CoordinateMapper(
            displayBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            calibration: Calibration(xMin: 0.8, xMax: 0.2, yMin: 0, yMax: 1)
        )

        XCTAssertEqual(mapper.globalPoint(x: 4095, y: 4095), CGPoint(x: 0, y: 1080))
    }
}
