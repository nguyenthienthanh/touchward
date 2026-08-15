import CoreGraphics
import Foundation

public struct GestureConfig: Sendable {
    public var tapMaxDuration: TimeInterval = 0.30
    public var longPressDuration: TimeInterval = 0.60
    /// Movement in points beyond which a touch is a drag, not a tap.
    public var moveThreshold: CGFloat = 10
    /// Backstop for a drag whose report stream died (unplug, sleep, dropped final report).
    /// Deliberately generous: a change-driven controller sends nothing while a finger rests,
    /// so a short timeout would cut legitimate slow drags short.
    public var staleDragTimeout: TimeInterval = 2.0

    public init() {}
}

/// Trackpad-shaped state machine: one finger points and drags, two fingers scroll.
/// Feed it mapped frames in order; it returns the events that frame produced.
///
/// Splitting one-finger drag from two-finger scroll avoids guessing intent from a single
/// contact's velocity, and matches the muscle memory macOS already teaches. Scroll deltas
/// are raw finger displacement — the synthesizer owns polarity so this type stays free of
/// platform conventions.
///
/// Two invariants the tests pin down, because breaking either is user-visible damage:
/// every `dragBegan` is matched by exactly one `dragEnded`, and `sessionEnded` fires
/// exactly once per physical touch session (it arms a cursor warp, so a spurious one
/// yanks the pointer away mid-touch).
public struct GestureRecognizer: Sendable {
    public var config: GestureConfig

    /// Shared by `.twoDown` and `.settling` so a scroll that momentarily drops a contact
    /// can resume, and so a tap is still classified correctly when the fingers leave one
    /// at a time — which is what actually happens on real hardware.
    private struct TwoFinger {
        var startTime: TimeInterval
        var lastCentroid: CGPoint
        var moved: Bool
        /// True when these fingers arrived during an existing gesture (e.g. a drag). Such
        /// a sequence must never be reclassified as a two-finger tap.
        var wasGesture: Bool
        var contactCount: Int
    }

    private enum State {
        case idle
        case oneDown(id: UInt8, start: CGPoint, startTime: TimeInterval)
        case dragging(id: UInt8, last: CGPoint)
        /// Right click already emitted; ignore everything until the finger lifts.
        case longPressed
        case twoDown(TwoFinger)
        /// Fewer than two fingers remain, but the hand has not left the glass.
        case settling(TwoFinger)
    }

    private var state: State = .idle
    private var lastFrameTime: TimeInterval = 0

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// True while a gesture is in flight — i.e. a pointer button may be held down.
    /// `TouchPipeline` gates its heartbeat on this, so a wrong answer here silently
    /// disables the long press and the stale-drag backstop.
    public var hasActiveGesture: Bool {
        if case .idle = state { return false }
        return true
    }

    public mutating func handle(_ frame: MappedFrame) -> [GestureEvent] {
        // Never let an out-of-order report push the staleness deadline backwards.
        lastFrameTime = max(lastFrameTime, frame.time)
        let count = frame.contacts.count

        switch state {
        case .idle:
            return begin(frame, count: count)

        case .oneDown(let id, let start, let startTime):
            if count == 0 {
                state = .idle
                return isWithinTapWindow(frame.time, since: startTime)
                    ? [.leftClick(at: start), .sessionEnded]
                    : [.sessionEnded]
            }
            if count >= 2 {
                // A second finger reclassifies the gesture; the pending tap is void.
                state = .twoDown(twoFinger(frame, wasGesture: false))
                return []
            }
            guard let point = point(of: id, in: frame) else {
                // The controller re-assigned the contact ID. The finger never left the
                // glass, so ending the session here would warp the cursor away mid-touch;
                // re-seed against the new ID instead.
                reseed(frame)
                return []
            }

            if distance(point, start) > config.moveThreshold {
                state = .dragging(id: id, last: point)
                return [.dragBegan(at: start), .dragMoved(to: point)]
            }
            if frame.time - startTime >= config.longPressDuration {
                state = .longPressed
                return [.rightClick(at: start)]
            }
            return []

        case .dragging(let id, let last):
            if count == 0 {
                state = .idle
                return [.dragEnded(at: last), .sessionEnded]
            }
            if count >= 2 {
                state = .twoDown(twoFinger(frame, wasGesture: true))
                return [.dragEnded(at: last)]
            }
            guard let point = point(of: id, in: frame) else {
                // Close the drag where it was rather than teleport it onto the new finger,
                // but keep the session alive — a finger is still down.
                reseed(frame)
                return [.dragEnded(at: last)]
            }

            guard point != last else { return [] }
            state = .dragging(id: id, last: point)
            return [.dragMoved(to: point)]

        case .longPressed:
            guard count == 0 else { return [] }
            state = .idle
            return [.sessionEnded]

        case .twoDown(var two):
            if count == 0 {
                state = .idle
                return finishTwoFinger(two, at: frame.time)
            }
            if count == 1 {
                state = .settling(two)
                return []
            }
            guard count == two.contactCount else {
                // A third finger landed (or one of three lifted). Diffing across a changed
                // contact set would emit one large bogus scroll delta.
                two.contactCount = count
                two.lastCentroid = centroid(frame)
                state = .twoDown(two)
                return []
            }

            let current = centroid(frame)
            let dx = current.x - two.lastCentroid.x
            let dy = current.y - two.lastCentroid.y
            guard dx != 0 || dy != 0 else { return [] }

            two.lastCentroid = current
            two.moved = true
            state = .twoDown(two)
            return [.scroll(dx: dx, dy: dy, at: current)]

        case .settling(var two):
            if count == 0 {
                state = .idle
                return finishTwoFinger(two, at: frame.time)
            }
            if count >= 2 {
                // The dropped contact came back — resume scrolling from a fresh centroid
                // rather than stranding the gesture until the whole hand lifts.
                two.contactCount = count
                two.lastCentroid = centroid(frame)
                state = .twoDown(two)
                return []
            }
            return []
        }
    }

    /// Clock-driven half of the machine. A perfectly still finger produces no new reports
    /// on a change-driven controller, so the long press cannot be discovered by frames
    /// alone; and a drag whose stream died must not leave the button held forever.
    public mutating func tick(at time: TimeInterval) -> [GestureEvent] {
        switch state {
        case .oneDown(_, let start, let startTime):
            guard time - startTime >= config.longPressDuration else { return [] }
            state = .longPressed
            return [.rightClick(at: start)]

        case .dragging(_, let last):
            guard time - lastFrameTime > config.staleDragTimeout else { return [] }
            // Release the button, but withhold sessionEnded: the finger may simply be
            // resting, and sessionEnded would warp the cursor off the touchscreen while
            // the user is still touching it. A real zero-contact frame, or forceRelease,
            // ends the session.
            state = .settling(TwoFinger(startTime: lastFrameTime, lastCentroid: last,
                                        moved: true, wasGesture: true, contactCount: 1))
            return [.dragEnded(at: last)]

        default:
            return []
        }
    }

    /// Unconditionally closes out whatever is in flight. Called on quit and on device
    /// removal so a pointer button is never left logically pressed.
    public mutating func forceRelease() -> [GestureEvent] {
        switch state {
        case .idle:
            return []
        case .dragging(_, let last):
            state = .idle
            return [.dragEnded(at: last), .sessionEnded]
        default:
            state = .idle
            return [.sessionEnded]
        }
    }

    // MARK: helpers

    private mutating func begin(_ frame: MappedFrame, count: Int) -> [GestureEvent] {
        switch count {
        case 0:
            return []
        case 1:
            let contact = frame.contacts[0]
            state = .oneDown(id: contact.id, start: contact.point, startTime: frame.time)
        default:
            state = .twoDown(twoFinger(frame, wasGesture: false))
        }
        return []
    }

    private mutating func reseed(_ frame: MappedFrame) {
        guard let contact = frame.contacts.first else {
            state = .idle
            return
        }
        state = .oneDown(id: contact.id, start: contact.point, startTime: frame.time)
    }

    private func twoFinger(_ frame: MappedFrame, wasGesture: Bool) -> TwoFinger {
        TwoFinger(startTime: frame.time, lastCentroid: centroid(frame),
                  moved: false, wasGesture: wasGesture, contactCount: frame.contacts.count)
    }

    private func finishTwoFinger(_ two: TwoFinger, at time: TimeInterval) -> [GestureEvent] {
        let wasTap = !two.moved && !two.wasGesture
            && isWithinTapWindow(time, since: two.startTime)
        return wasTap ? [.rightClick(at: two.lastCentroid), .sessionEnded] : [.sessionEnded]
    }

    /// A negative interval means the reports arrived out of order or the clock moved.
    /// Treating that as "elapsed 0" would classify a long hold as an instant tap and fire
    /// a click the user never asked for, so an unusable measurement is never a tap.
    private func isWithinTapWindow(_ time: TimeInterval, since start: TimeInterval) -> Bool {
        let interval = time - start
        return interval >= 0 && interval <= config.tapMaxDuration
    }

    private func point(of id: UInt8, in frame: MappedFrame) -> CGPoint? {
        frame.contacts.first { $0.id == id }?.point
    }

    private func centroid(_ frame: MappedFrame) -> CGPoint {
        guard !frame.contacts.isEmpty else { return .zero }
        let sum = frame.contacts.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.point.x, y: $0.y + $1.point.y)
        }
        let n = CGFloat(frame.contacts.count)
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
