import XCTest
@testable import TouchBridgeCore

/// The assembler exists so nothing in this project has to know a report's byte layout.
/// These tests feed it the (usage, value) stream IOKit produces from the device's own
/// descriptor — the same shape regardless of how many fingers a panel supports.
final class TouchValueAssemblerTests: XCTestCase {

    private func sendFinger(
        _ a: inout TouchValueAssembler,
        id: Int, x: Int, y: Int, tip: Bool = true,
        confidence: Int? = 1, width: Int? = nil, height: Int? = nil,
        at time: TimeInterval
    ) -> [TouchFrame] {
        var out: [TouchFrame] = []
        func push(_ page: Int, _ usage: Int, _ value: Int) {
            if let frame = a.accept(usagePage: page, usage: usage, value: value, time: time) {
                out.append(frame)
            }
        }
        push(Usage.Page.digitizer, Usage.tipSwitch, tip ? 1 : 0)
        if let confidence { push(Usage.Page.digitizer, Usage.confidence, confidence) }
        push(Usage.Page.digitizer, Usage.contactIdentifier, id)
        push(Usage.Page.genericDesktop, Usage.x, x)
        push(Usage.Page.genericDesktop, Usage.y, y)
        if let width { push(Usage.Page.digitizer, Usage.width, width) }
        if let height { push(Usage.Page.digitizer, Usage.height, height) }
        return out
    }

    private func endReport(_ a: inout TouchValueAssembler, count: Int, at time: TimeInterval) -> TouchFrame? {
        a.accept(usagePage: Usage.Page.digitizer, usage: Usage.contactCount, value: count, time: time)
    }

    func testAssemblesASingleContact() throws {
        var a = TouchValueAssembler()
        _ = sendFinger(&a, id: 3, x: 1000, y: 2000, at: 1.0)

        let frame = try XCTUnwrap(endReport(&a, count: 1, at: 1.0))
        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].id, 3)
        XCTAssertEqual(frame.contacts[0].x, 1000)
        XCTAssertEqual(frame.contacts[0].y, 2000)
        XCTAssertEqual(frame.time, 1.0)
    }

    /// A repeated usage is what marks the start of the next finger — the rule that lets
    /// this work without knowing how many collections the descriptor declares.
    func testRepeatedUsageStartsTheNextContact() throws {
        var a = TouchValueAssembler()
        _ = sendFinger(&a, id: 1, x: 100, y: 200, at: 2.0)
        _ = sendFinger(&a, id: 2, x: 300, y: 400, at: 2.0)

        let frame = try XCTUnwrap(endReport(&a, count: 2, at: 2.0))
        XCTAssertEqual(frame.contacts.map(\.id), [1, 2])
        XCTAssertEqual(frame.contacts[1].x, 300)
    }

    /// Panels vary from 2 to 10 contacts; nothing may cap this at a number read off one
    /// machine's descriptor.
    func testAssemblesAsManyContactsAsTheDeviceSends() throws {
        var a = TouchValueAssembler()
        for i in 1...10 {
            _ = sendFinger(&a, id: i, x: i * 100, y: i * 10, at: 3.0)
        }

        let frame = try XCTUnwrap(endReport(&a, count: 10, at: 3.0))
        XCTAssertEqual(frame.contacts.count, 10)
        XCTAssertEqual(frame.contacts.last?.x, 1000)
    }

    func testContactsWithTipSwitchClearAreDropped() throws {
        var a = TouchValueAssembler()
        _ = sendFinger(&a, id: 1, x: 100, y: 100, at: 4.0)
        _ = sendFinger(&a, id: 2, x: 200, y: 200, tip: false, at: 4.0)

        let frame = try XCTUnwrap(endReport(&a, count: 2, at: 4.0))
        XCTAssertEqual(frame.contacts.map(\.id), [1])
    }

    func testExplicitlyUnconfidentContactsAreDropped() throws {
        var a = TouchValueAssembler()
        _ = sendFinger(&a, id: 1, x: 100, y: 100, confidence: 0, at: 5.0)

        let frame = try XCTUnwrap(endReport(&a, count: 1, at: 5.0))
        XCTAssertTrue(frame.contacts.isEmpty)
    }

    /// Some controllers never report confidence at all. Requiring it would make the driver
    /// silently see zero fingers forever on those panels.
    func testMissingConfidenceIsTreatedAsConfident() throws {
        var a = TouchValueAssembler()
        _ = sendFinger(&a, id: 7, x: 10, y: 20, confidence: nil, at: 6.0)

        let frame = try XCTUnwrap(endReport(&a, count: 1, at: 6.0))
        XCTAssertEqual(frame.contacts.map(\.id), [7])
    }

    /// A device that omits the contact-count usage must still produce frames.
    func testTimestampChangeClosesAReportWithoutAContactCount() throws {
        var a = TouchValueAssembler()
        _ = sendFinger(&a, id: 1, x: 50, y: 60, at: 7.0)

        let frames = sendFinger(&a, id: 1, x: 55, y: 65, at: 7.1)
        let first = try XCTUnwrap(frames.first)
        XCTAssertEqual(first.time, 7.0)
        XCTAssertEqual(first.contacts.first?.x, 50)
    }

    func testAllFingersLiftedProducesAnEmptyFrameNotNil() throws {
        var a = TouchValueAssembler()
        _ = sendFinger(&a, id: 1, x: 100, y: 100, tip: false, at: 8.0)

        let frame = try XCTUnwrap(endReport(&a, count: 0, at: 8.0))
        XCTAssertTrue(frame.contacts.isEmpty, "an empty frame is how a lift is signalled")
    }

    func testContactsWithoutCoordinatesAreIgnored() throws {
        var a = TouchValueAssembler()
        _ = a.accept(usagePage: Usage.Page.digitizer, usage: Usage.tipSwitch, value: 1, time: 9.0)
        _ = a.accept(usagePage: Usage.Page.digitizer, usage: Usage.contactIdentifier, value: 1, time: 9.0)

        let frame = try XCTUnwrap(endReport(&a, count: 1, at: 9.0))
        XCTAssertTrue(frame.contacts.isEmpty)
    }

    func testUnrelatedUsagesAreIgnored() throws {
        var a = TouchValueAssembler()
        _ = a.accept(usagePage: Usage.Page.digitizer, usage: Usage.contactCountMaximum, value: 10, time: 10.0)
        _ = sendFinger(&a, id: 4, x: 1, y: 2, at: 10.0)

        let frame = try XCTUnwrap(endReport(&a, count: 1, at: 10.0))
        XCTAssertEqual(frame.contacts.map(\.id), [4])
    }
}

final class PalmFilterTests: XCTestCase {

    /// The threshold scales with whatever range the device declares, instead of a constant
    /// copied from one panel's descriptor.
    func testRejectsContactsLargerThanAFractionOfTheDeviceRange() {
        let filter = PalmFilter(logicalMax: 4095)
        let frame = TouchFrame(contacts: [
            Contact(id: 1, x: 10, y: 10, width: 40, height: 40, isTouching: true),
            Contact(id: 2, x: 20, y: 20, width: 1500, height: 40, isTouching: true),
            Contact(id: 3, x: 30, y: 30, width: 40, height: 1500, isTouching: true),
        ], time: 0)

        XCTAssertEqual(filter.reject(frame).contacts.map(\.id), [1],
                       "both axes are checked — a forearm is huge in only one")
    }

    func testScalesWithADifferentDeviceRange() {
        let small = PalmFilter(logicalMax: 1023)
        let frame = TouchFrame(contacts: [
            Contact(id: 1, x: 0, y: 0, width: 300, height: 300, isTouching: true),
        ], time: 0)

        XCTAssertTrue(small.reject(frame).contacts.isEmpty,
                      "300 of 1023 is a palm even though it would pass on a 4095 panel")
    }

    /// Devices that do not report contact area send zeroes; that must not reject every touch.
    func testContactsWithNoReportedSizeArePassedThrough() {
        let filter = PalmFilter(logicalMax: 4095)
        let frame = TouchFrame(contacts: [
            Contact(id: 1, x: 10, y: 10, width: 0, height: 0, isTouching: true),
        ], time: 0)

        XCTAssertEqual(filter.reject(frame).contacts.count, 1)
    }
}
