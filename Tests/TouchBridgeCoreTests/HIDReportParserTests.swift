import CoreGraphics
import XCTest
@testable import TouchBridgeCore

/// Builds a digitizer report body (report ID already stripped) the way the
/// SiS controller lays it out: 5 × 10-byte contacts, then contact count.
private func digitizerReport(_ contacts: [(tip: Bool, confident: Bool, id: UInt8, x: Int, y: Int, w: Int, h: Int)]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 53)
    for (slot, c) in contacts.prefix(5).enumerated() {
        let o = slot * 10
        bytes[o] = (c.tip ? 0x01 : 0) | (c.confident ? 0x02 : 0)
        bytes[o + 1] = c.id
        bytes[o + 2] = UInt8(c.x & 0xFF)
        bytes[o + 3] = UInt8((c.x >> 8) & 0xFF)
        bytes[o + 4] = UInt8(c.y & 0xFF)
        bytes[o + 5] = UInt8((c.y >> 8) & 0xFF)
        bytes[o + 6] = UInt8(c.w & 0xFF)
        bytes[o + 7] = UInt8((c.w >> 8) & 0xFF)
        bytes[o + 8] = UInt8(c.h & 0xFF)
        bytes[o + 9] = UInt8((c.h >> 8) & 0xFF)
    }
    bytes[50] = UInt8(contacts.count)
    return bytes
}

private func mouseReport(buttons: UInt8, x: Int, y: Int) -> [UInt8] {
    [buttons,
     UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF),
     UInt8(y & 0xFF), UInt8((y >> 8) & 0xFF)]
}

final class HIDReportParserTests: XCTestCase {

    func testParsesSingleDigitizerContact() throws {
        let body = digitizerReport([(tip: true, confident: true, id: 7, x: 2048, y: 1024, w: 40, h: 40)])
        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: body, time: 1.0))

        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].id, 7)
        XCTAssertEqual(frame.contacts[0].x, 2048)
        XCTAssertEqual(frame.contacts[0].y, 1024)
        XCTAssertEqual(frame.time, 1.0)
    }

    func testParsesTwoContactsAndPreservesOrder() throws {
        let body = digitizerReport([
            (tip: true, confident: true, id: 1, x: 100, y: 200, w: 30, h: 30),
            (tip: true, confident: true, id: 2, x: 3000, y: 3500, w: 30, h: 30),
        ])
        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: body, time: 0))

        XCTAssertEqual(frame.contacts.map(\.id), [1, 2])
        XCTAssertEqual(frame.contacts[1].x, 3000)
        XCTAssertEqual(frame.contacts[1].y, 3500)
    }

    /// Slots whose tip switch is clear are stale data, not lifted fingers held at zero.
    func testDropsContactsThatAreNotTouching() throws {
        let body = digitizerReport([
            (tip: true, confident: true, id: 1, x: 100, y: 100, w: 30, h: 30),
            (tip: false, confident: true, id: 2, x: 900, y: 900, w: 30, h: 30),
        ])
        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: body, time: 0))

        XCTAssertEqual(frame.contacts.map(\.id), [1])
    }

    func testDropsContactsTheControllerMarksUnconfident() throws {
        let body = digitizerReport([
            (tip: true, confident: false, id: 1, x: 100, y: 100, w: 30, h: 30),
        ])
        let frame = try XCTUnwrap(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: body, time: 0))

        XCTAssertTrue(frame.contacts.isEmpty)
    }

    /// The device may never leave mouse mode; report 0x03 must still yield a usable touch.
    func testParsesMouseFallbackReportAsSingleContact() throws {
        let frame = try XCTUnwrap(
            HIDReportParser.parse(reportID: ReportID.mouse, bytes: mouseReport(buttons: 0x01, x: 4095, y: 0), time: 2.0)
        )

        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].x, 4095)
        XCTAssertEqual(frame.contacts[0].y, 0)
        XCTAssertTrue(frame.contacts[0].isTouching)
    }

    func testMouseReportWithNoButtonHeldIsAnEmptyFrame() throws {
        let frame = try XCTUnwrap(
            HIDReportParser.parse(reportID: ReportID.mouse, bytes: mouseReport(buttons: 0x00, x: 500, y: 500), time: 0)
        )

        XCTAssertTrue(frame.contacts.isEmpty, "button released means no active contact")
    }

    /// A palm resting on the glass reports a huge contact patch. Rejecting by size is
    /// the cheap half of palm rejection; the confidence bit is the other half.
    func testRejectsPalmSizedContacts() throws {
        let body = digitizerReport([
            (tip: true, confident: true, id: 1, x: 100, y: 100, w: 1500, h: 1500),
            (tip: true, confident: true, id: 2, x: 900, y: 900, w: 40, h: 40),
        ])
        let frame = try XCTUnwrap(
            HIDReportParser.parse(reportID: ReportID.digitizer, bytes: body, time: 0, maxContactSize: 900)
        )

        XCTAssertEqual(frame.contacts.map(\.id), [2])
    }

    func testRejectsUnknownReportID() {
        XCTAssertNil(HIDReportParser.parse(reportID: 0x42, bytes: [0, 0, 0, 0, 0], time: 0))
    }

    /// A short read must not trap — USB can hand back a truncated buffer.
    func testRejectsTruncatedBuffer() {
        XCTAssertNil(HIDReportParser.parse(reportID: ReportID.digitizer, bytes: [1, 2, 3], time: 0))
        XCTAssertNil(HIDReportParser.parse(reportID: ReportID.mouse, bytes: [1], time: 0))
    }
}
