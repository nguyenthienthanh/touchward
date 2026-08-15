import CoreGraphics
import XCTest
@testable import TouchwardCore

/// Three fingers zoom. Two fingers already scroll, so spreading and pinching a third finger
/// in is the gesture left that nothing else claims.
///
/// The recognizer reports a *ratio*, not a distance: how much the hand opened since the last
/// frame. The synthesizer decides what a ratio means on this platform, exactly as it already
/// owns scroll polarity.
final class ZoomGestureTests: XCTestCase {

    private func frame(_ points: [(UInt8, CGFloat, CGFloat)], at time: TimeInterval) -> MappedFrame {
        MappedFrame(
            contacts: points.map { MappedContact(id: $0.0, point: CGPoint(x: $0.1, y: $0.2)) },
            time: time
        )
    }

    private func empty(at time: TimeInterval) -> MappedFrame {
        MappedFrame(contacts: [], time: time)
    }

    /// Three fingers on a horizontal line, `spread` apart from the middle one.
    private func hand(spread: CGFloat, centre: CGPoint = CGPoint(x: 500, y: 500),
                      at time: TimeInterval) -> MappedFrame {
        frame([
            (1, centre.x - spread, centre.y),
            (2, centre.x, centre.y),
            (3, centre.x + spread, centre.y),
        ], at: time)
    }

    private func scales(_ events: [GestureEvent]) -> [CGFloat] {
        events.compactMap { if case .pinch(let scale, _) = $0 { return scale } else { return nil } }
    }

    func testSpreadingThreeFingersZoomsIn() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 100, at: 0))

        let out = scales(r.handle(hand(spread: 150, at: 0.05)))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], 1.5, accuracy: 0.001, "the hand opened by half again")
    }

    func testPinchingThreeFingersZoomsOut() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 200, at: 0))

        let out = scales(r.handle(hand(spread: 100, at: 0.05)))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], 0.5, accuracy: 0.001)
    }

    func testTheRatioIsPerFrameNotCumulative() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 100, at: 0))

        XCTAssertEqual(scales(r.handle(hand(spread: 200, at: 0.05)))[0], 2, accuracy: 0.001)
        XCTAssertEqual(scales(r.handle(hand(spread: 400, at: 0.10)))[0], 2, accuracy: 0.001,
                       "each frame reports its own step, or the zoom would run away")
    }

    /// The whole point of measuring spread rather than movement: a hand that slides across
    /// the glass with its fingers the same distance apart is not zooming.
    func testSlidingThreeFingersWithoutSpreadingDoesNotZoom() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 120, centre: CGPoint(x: 400, y: 400), at: 0))

        let out = r.handle(hand(spread: 120, centre: CGPoint(x: 700, y: 650), at: 0.05))
        XCTAssertTrue(scales(out).isEmpty, "moved, but never opened or closed")
    }

    func testThreeFingersNeverScroll() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 120, centre: CGPoint(x: 400, y: 400), at: 0))

        let out = r.handle(hand(spread: 180, centre: CGPoint(x: 500, y: 500), at: 0.05))
        for event in out {
            if case .scroll = event {
                XCTFail("three fingers zoom; scrolling is the two-finger gesture")
            }
        }
    }

    func testAStillHandEmitsNothing() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 120, at: 0))

        XCTAssertEqual(r.handle(hand(spread: 120, at: 0.05)), [])
    }

    /// A zoom must never be mistaken for a two-finger tap on the way out — fingers leave the
    /// glass one at a time, so the hand passes through a two-finger frame every time.
    func testLiftingAfterAZoomDoesNotRightClick() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 100, at: 0))
        _ = r.handle(hand(spread: 200, at: 0.05))

        var out = r.handle(frame([(1, 400, 500), (2, 500, 500)], at: 0.10))
        out += r.handle(frame([(2, 500, 500)], at: 0.12))
        out += r.handle(empty(at: 0.14))

        XCTAssertEqual(out, [.sessionEnded])
    }

    func testAThirdFingerDuringAScrollTakesOverAsZoom() {
        var r = GestureRecognizer()
        _ = r.handle(frame([(1, 400, 500), (2, 600, 500)], at: 0))
        _ = r.handle(frame([(1, 400, 520), (2, 600, 520)], at: 0.05))

        // The third finger lands: this is now a zoom, and the frame it lands on must not
        // emit a scroll built from a centroid that just jumped.
        let landing = r.handle(hand(spread: 100, at: 0.10))
        XCTAssertTrue(scales(landing).isEmpty, "no ratio yet — there is nothing to compare to")
        for event in landing {
            if case .scroll = event { XCTFail("the contact set changed; that delta is meaningless") }
        }

        XCTAssertEqual(scales(r.handle(hand(spread: 150, at: 0.15)))[0], 1.5, accuracy: 0.001)
    }

    /// Dropping to two fingers mid-zoom and coming back must not fire a zoom step built
    /// from the spread of a different number of fingers.
    func testResumingAfterALostContactDoesNotJump() {
        var r = GestureRecognizer()
        _ = r.handle(hand(spread: 100, at: 0))
        _ = r.handle(frame([(1, 400, 500), (2, 500, 500)], at: 0.05))

        let resumed = r.handle(hand(spread: 300, at: 0.10))
        XCTAssertTrue(scales(resumed).isEmpty, "re-seed the spread instead of reporting a jump")

        XCTAssertEqual(scales(r.handle(hand(spread: 330, at: 0.15)))[0], 1.1, accuracy: 0.001)
    }

    func testAZeroSpreadHandCannotProduceAnInfiniteRatio() {
        var r = GestureRecognizer()
        // Three contacts reported at the same point: degenerate, but a controller under a
        // palm does report this, and dividing by it would emit inf and trap downstream.
        _ = r.handle(frame([(1, 500, 500), (2, 500, 500), (3, 500, 500)], at: 0))

        let out = scales(r.handle(hand(spread: 100, at: 0.05)))
        XCTAssertTrue(out.allSatisfy { $0.isFinite }, "never divide by a zero spread")
    }
}
