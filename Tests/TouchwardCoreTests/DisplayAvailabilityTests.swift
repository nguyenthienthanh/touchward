import XCTest
@testable import TouchwardCore

/// A panel whose monitor is switched off keeps its USB side powered on plenty of hardware,
/// so "the cable is in" says nothing about whether touching it should do anything.
final class DisplayAvailabilityTests: XCTestCase {

    private func signals(inList: Bool = true, active: Bool = true,
                         asleep: Bool = false, online: Bool = true) -> DisplayAvailability.Signals {
        DisplayAvailability.Signals(isInActiveList: inList, isActive: active,
                                    isAsleep: asleep, isOnline: online)
    }

    func testAConnectedAwakeDisplayIsUsable() {
        XCTAssertTrue(DisplayAvailability.isUsable(signals()))
    }

    func testAMonitorSwitchedOffIsNotUsable() {
        XCTAssertFalse(DisplayAvailability.isUsable(signals(asleep: true)),
                       "the cable is still in, and that is exactly the case this exists for")
    }

    func testADisconnectedDisplayIsNotUsable() {
        XCTAssertFalse(DisplayAvailability.isUsable(signals(inList: false)))
        XCTAssertFalse(DisplayAvailability.isUsable(signals(online: false)))
    }

    func testAConnectedButUndrawableDisplayIsNotUsable() {
        XCTAssertFalse(DisplayAvailability.isUsable(signals(active: false)))
    }

    /// No optimism. One signal saying no outranks the rest saying yes, because acting on a
    /// screen that is not there moves the cursor somewhere the user cannot follow it.
    func testAnySingleRefusalIsEnough() {
        XCTAssertFalse(DisplayAvailability.isUsable(signals(inList: false, active: true, asleep: false, online: true)))
        XCTAssertFalse(DisplayAvailability.isUsable(signals(inList: true, active: true, asleep: true, online: true)))
    }
}
