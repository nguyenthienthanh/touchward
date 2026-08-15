import CoreGraphics
import XCTest
@testable import TouchwardCore

/// Tests written to kill specific mutations that the original suite let through.
/// A mutation audit found 22 of 25 deliberate faults survived — including deleting the
/// stale-drag backstop, deleting palm rejection, and hardcoding `hasActiveGesture` to
/// false (which silently disables the heartbeat in production). Each test below exists
/// because a real, shippable regression previously went unnoticed.
final class InvariantTests: XCTestCase {

    private func frame(_ points: [(UInt8, CGFloat, CGFloat)], at time: TimeInterval) -> MappedFrame {
        MappedFrame(contacts: points.map { MappedContact(id: $0.0, point: CGPoint(x: $0.1, y: $0.2)) },
                    time: time)
    }
    private func empty(at time: TimeInterval) -> MappedFrame {
        MappedFrame(contacts: [], time: time)
    }

    // MARK: hasActiveGesture — gates the production heartbeat

    /// If this property is wrong, `TouchPipeline` never calls `tick`, so neither the long
    /// press nor the stuck-button backstop ever runs — with every other test still green.
    func testHasActiveGestureTracksEveryState() {
        var r = GestureRecognizer()
        XCTAssertFalse(r.hasActiveGesture, "idle")

        _ = r.handle(frame([(1, 0, 0)], at: 0))
        XCTAssertTrue(r.hasActiveGesture, "one finger down")

        _ = r.handle(frame([(1, 100, 0)], at: 0.05))
        XCTAssertTrue(r.hasActiveGesture, "dragging")

        _ = r.handle(empty(at: 0.1))
        XCTAssertFalse(r.hasActiveGesture, "after the session ends")

        _ = r.handle(frame([(1, 0, 0), (2, 50, 0)], at: 1.0))
        XCTAssertTrue(r.hasActiveGesture, "two fingers down")

        _ = r.handle(frame([(1, 0, 0)], at: 1.05))
        XCTAssertTrue(r.hasActiveGesture, "settling — one finger still on the glass")

        _ = r.handle(empty(at: 1.1))
        XCTAssertFalse(r.hasActiveGesture)

        var longPress = GestureRecognizer()
        _ = longPress.handle(frame([(1, 5, 5)], at: 0))
        _ = longPress.tick(at: 0.7)
        XCTAssertTrue(longPress.hasActiveGesture, "long-pressed, finger still down")
    }

    // MARK: the stale-drag backstop must not fire on a live drag

    /// Deleting the staleness guard entirely used to pass: the only test ticked 5s after a
    /// 0.1s frame, a 50x margin that cannot distinguish a working timeout from none.
    func testTickDoesNotKillADragThatIsStillReceivingReports() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 0, 0)], at: 0))
        _ = r.handle(frame([(1, 100, 0)], at: 0.05))

        XCTAssertEqual(r.tick(at: 0.2), [], "a drag 0.15s into its life is not stale")
        XCTAssertTrue(r.hasActiveGesture)
    }

    /// The finger may just be resting. Releasing the button is right; ending the session is
    /// not, because that warps the cursor off the screen the user is still touching.
    func testStaleDragReleasesTheButtonWithoutEndingTheSession() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 0, 0)], at: 0))
        _ = r.handle(frame([(1, 100, 0)], at: 0.05))

        XCTAssertEqual(r.tick(at: 5.0), [.dragEnded(at: CGPoint(x: 100, y: 0))])
        XCTAssertEqual(r.handle(empty(at: 5.1)), [.sessionEnded])
    }

    // MARK: two fingers leaving one at a time — what hardware actually does

    /// Fingers essentially never lift on the same scan. The tap classification has to
    /// survive the 2 → 1 → 0 sequence, or two-finger right-click never works in practice.
    func testTwoFingerTapStillRightClicksWhenFingersLiftOneAtATime() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 100, 100), (2, 200, 100)], at: 0))
        XCTAssertEqual(r.handle(frame([(1, 100, 100)], at: 0.05)), [])

        XCTAssertEqual(r.handle(empty(at: 0.08)),
                       [.rightClick(at: CGPoint(x: 150, y: 100)), .sessionEnded])
    }

    /// A dropped contact for one frame must not strand the scroll until the whole hand
    /// leaves the glass.
    func testScrollResumesAfterAContactFlickersOut() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 100, 100), (2, 200, 100)], at: 0))
        _ = r.handle(frame([(1, 100, 120), (2, 200, 120)], at: 0.05))

        XCTAssertEqual(r.handle(frame([(1, 100, 120)], at: 0.10)), [], "settling")
        XCTAssertEqual(r.handle(frame([(1, 100, 120), (2, 200, 120)], at: 0.15)), [],
                       "re-seats the centroid, emits nothing")
        XCTAssertEqual(r.handle(frame([(1, 100, 140), (2, 200, 140)], at: 0.20)),
                       [.scroll(dx: 0, dy: 20, at: CGPoint(x: 150, y: 140))],
                       "scrolling works again")
    }

    /// Lifting one finger after a scroll must not leave the other one starting a fresh
    /// one-finger session that clicks on lift.
    func testOneFingerLingeringAfterAScrollDoesNotClick() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 100, 100), (2, 200, 100)], at: 0))
        _ = r.handle(frame([(1, 100, 140), (2, 200, 140)], at: 0.05))
        _ = r.handle(frame([(1, 100, 140)], at: 0.10))
        _ = r.handle(frame([(1, 160, 140)], at: 0.15))

        XCTAssertEqual(r.handle(empty(at: 0.20)), [.sessionEnded])
    }

    /// This sequence used to pop a context menu at a point the user never touched.
    func testDragThenSecondFingerThenLiftDoesNotRightClick() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 100, 100)], at: 0))
        _ = r.handle(frame([(1, 200, 100)], at: 0.05))
        XCTAssertEqual(r.handle(frame([(1, 200, 100), (2, 300, 100)], at: 0.10)),
                       [.dragEnded(at: CGPoint(x: 200, y: 100))])

        XCTAssertEqual(r.handle(empty(at: 0.15)), [.sessionEnded],
                       "a drag that grew a second finger is not a two-finger tap")
    }

    /// Landing a third finger must not emit one huge bogus scroll from the centroid jump.
    func testThirdFingerReseatsTheCentroidInsteadOfScrolling() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 100, 100), (2, 200, 100)], at: 0))

        XCTAssertEqual(r.handle(frame([(1, 100, 100), (2, 200, 100), (3, 900, 900)], at: 0.05)), [])
    }

    // MARK: session accounting

    /// sessionEnded arms a cursor warp. Two per session yanks the pointer twice; zero
    /// strands it on the touchscreen.
    func testSessionEndedFiresExactlyOncePerSession() {
        func count(_ steps: [MappedFrame]) -> Int {
            var r = GestureRecognizer()
            return steps.flatMap { r.handle($0) }.filter { $0 == .sessionEnded }.count
        }

        XCTAssertEqual(count([frame([(1, 0, 0)], at: 0), empty(at: 0.1)]), 1, "tap")
        XCTAssertEqual(count([frame([(1, 0, 0)], at: 0),
                              frame([(1, 200, 0)], at: 0.05),
                              empty(at: 0.1)]), 1, "drag")
        XCTAssertEqual(count([frame([(1, 0, 0), (2, 100, 0)], at: 0),
                              frame([(1, 0, 40), (2, 100, 40)], at: 0.05),
                              frame([(1, 0, 40)], at: 0.1),
                              empty(at: 0.15)]), 1, "scroll then lift one at a time")
        XCTAssertEqual(count([frame([(1, 0, 0)], at: 0),
                              frame([(9, 5, 5)], at: 0.05),
                              empty(at: 0.1)]), 1, "contact id swapped mid-touch")
    }

    /// A re-assigned contact ID mid-touch must not end the session — the finger is still
    /// down, and ending it warps the cursor away.
    func testContactIDSwapDoesNotEndTheSession() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 100, 100)], at: 0))

        XCTAssertEqual(r.handle(frame([(9, 105, 100)], at: 0.05)), [])
        XCTAssertTrue(r.hasActiveGesture)
    }

    // MARK: forceRelease covers every state, not just dragging

    func testForceReleaseFromEveryState() {
        var oneDown = GestureRecognizer()
        _ = oneDown.handle(frame([(1, 0, 0)], at: 0))
        XCTAssertEqual(oneDown.forceRelease(), [.sessionEnded])

        var twoDown = GestureRecognizer()
        _ = twoDown.handle(frame([(1, 0, 0), (2, 50, 0)], at: 0))
        XCTAssertEqual(twoDown.forceRelease(), [.sessionEnded])

        var longPressed = GestureRecognizer()
        _ = longPressed.handle(frame([(1, 0, 0)], at: 0))
        _ = longPressed.tick(at: 0.7)
        XCTAssertEqual(longPressed.forceRelease(), [.sessionEnded])

        var settling = GestureRecognizer()
        _ = settling.handle(frame([(1, 0, 0), (2, 50, 0)], at: 0))
        _ = settling.handle(frame([(1, 0, 0)], at: 0.05))
        XCTAssertEqual(settling.forceRelease(), [.sessionEnded])

        var dragging = GestureRecognizer()
        _ = dragging.handle(frame([(1, 0, 0)], at: 0))
        _ = dragging.handle(frame([(1, 100, 0)], at: 0.05))
        XCTAssertEqual(dragging.forceRelease(),
                       [.dragEnded(at: CGPoint(x: 100, y: 0)), .sessionEnded])

        var idle = GestureRecognizer()
        XCTAssertEqual(idle.forceRelease(), [])
    }

    // MARK: thresholds are actually read from config

    /// Nothing previously proved the config knobs were wired to anything: the defaults
    /// could be changed to almost any value and the suite stayed green.
    func testConfigThresholdsAreRespected() {
        var config = GestureConfig()
        config.moveThreshold = 50
        config.tapMaxDuration = 0.1
        config.longPressDuration = 0.2

        var r = GestureRecognizer(config: config)
        _ = r.handle(frame([(1, 0, 0)], at: 0))
        XCTAssertEqual(r.handle(frame([(1, 30, 0)], at: 0.02)), [],
                       "30pt is under the raised 50pt threshold")

        XCTAssertEqual(r.tick(at: 0.25), [.rightClick(at: .zero)],
                       "long press fires at the shortened 0.2s")

        var tap = GestureRecognizer(config: config)
        _ = tap.handle(frame([(1, 0, 0)], at: 0))
        XCTAssertEqual(tap.handle(empty(at: 0.15)), [.sessionEnded],
                       "0.15s exceeds the shortened 0.1s tap window")
    }

    func testBoundaryValuesResolveAsDocumented() {
        var atThreshold = GestureRecognizer()
        _ = atThreshold.handle(frame([(1, 0, 0)], at: 0))
        XCTAssertEqual(atThreshold.handle(frame([(1, 10, 0)], at: 0.02)), [],
                       "movement of exactly moveThreshold is not yet a drag")

        var atTapLimit = GestureRecognizer()
        _ = atTapLimit.handle(frame([(1, 0, 0)], at: 0))
        XCTAssertEqual(atTapLimit.handle(empty(at: 0.30)),
                       [.leftClick(at: .zero), .sessionEnded],
                       "a lift at exactly tapMaxDuration still clicks")

        var atLongPress = GestureRecognizer()
        _ = atLongPress.handle(frame([(1, 0, 0)], at: 0))
        XCTAssertEqual(atLongPress.tick(at: 0.60), [.rightClick(at: .zero)],
                       "exactly longPressDuration right-clicks")
    }

    /// Holding past the tap window but short of the long press should do nothing at all.
    func testHoldBetweenTapAndLongPressEmitsOnlySessionEnd() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 100, 100)], at: 0))

        XCTAssertEqual(r.handle(empty(at: 0.5)), [.sessionEnded])
    }

    /// An out-of-order report must not make a long hold look instantaneous.
    func testOutOfOrderFrameDoesNotTurnAHoldIntoATap() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 0, 0)], at: 10.0))

        XCTAssertEqual(r.handle(empty(at: 9.0)), [.sessionEnded],
                       "negative elapsed time is clamped, not treated as a fast tap")
    }
}
