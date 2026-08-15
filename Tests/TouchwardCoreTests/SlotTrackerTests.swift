import XCTest
@testable import TouchwardCore

/// The scroll gesture lives or dies on these: two fingers must stay two fingers between
/// reports, even though the device only re-sends the values that changed.
final class SlotTrackerTests: XCTestCase {

    private func land(_ t: inout SlotTracker, slot: Int, id: Int, x: Int, y: Int) {
        t.update(slot: slot, field: .tip, value: 1)
        t.update(slot: slot, field: .id, value: id)
        t.update(slot: slot, field: .x, value: x)
        t.update(slot: slot, field: .y, value: y)
    }

    func testTwoFingersStayDownWhileOnlyOneMoves() {
        var tracker = SlotTracker()
        land(&tracker, slot: 0, id: 1, x: 100, y: 200)
        land(&tracker, slot: 1, id: 2, x: 300, y: 400)

        // The next report only carries slot 0's new X. Everything else is unchanged, so
        // IOKit never mentions it again.
        tracker.update(slot: 0, field: .x, value: 110)

        let frame = tracker.frame(at: 1.0)
        XCTAssertEqual(frame.contacts.count, 2, "the resting finger must not disappear")
        XCTAssertEqual(frame.contacts.map(\.id), [1, 2])
        XCTAssertEqual(frame.contacts.first?.x, 110)
        XCTAssertEqual(frame.contacts.last?.x, 300)
        XCTAssertEqual(frame.contacts.last?.y, 400)
    }

    func testLiftingOneFingerLeavesTheOther() {
        var tracker = SlotTracker()
        land(&tracker, slot: 0, id: 1, x: 100, y: 200)
        land(&tracker, slot: 1, id: 2, x: 300, y: 400)

        tracker.update(slot: 1, field: .tip, value: 0)

        XCTAssertEqual(tracker.frame(at: 2.0).contacts.map(\.id), [1])
    }

    func testContactsComeOutInSlotOrder() {
        var tracker = SlotTracker()
        land(&tracker, slot: 2, id: 9, x: 1, y: 1)
        land(&tracker, slot: 0, id: 4, x: 2, y: 2)

        // Order matters: the recognizer diffs centroids, and an unstable order would make
        // a still hand look like it jumped.
        XCTAssertEqual(tracker.frame(at: 3.0).contacts.map(\.id), [4, 9])
    }

    func testASlotWithNoCoordinatesIsNotAContact() {
        var tracker = SlotTracker()
        tracker.update(slot: 0, field: .tip, value: 1)

        XCTAssertTrue(tracker.frame(at: 4.0).contacts.isEmpty,
                      "a tip switch with no position yet is not somewhere the finger is")
    }

    func testPanelReportedPalmIsDropped() {
        var tracker = SlotTracker()
        land(&tracker, slot: 0, id: 1, x: 10, y: 10)
        tracker.update(slot: 0, field: .confidence, value: 0)

        XCTAssertTrue(tracker.frame(at: 5.0).contacts.isEmpty)
    }

    func testReleaseAllClearsEveryFinger() {
        var tracker = SlotTracker()
        land(&tracker, slot: 0, id: 1, x: 10, y: 10)
        tracker.releaseAll()

        XCTAssertTrue(tracker.frame(at: 6.0).contacts.isEmpty)
    }
}
