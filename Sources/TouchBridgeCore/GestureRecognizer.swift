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
public struct GestureRecognizer: Sendable {
    public var config: GestureConfig

    private enum State {
        case idle
        case oneDown(id: UInt8, start: CGPoint, startTime: TimeInterval)
        case dragging(id: UInt8, last: CGPoint)
        /// Right click already emitted; ignore everything until the finger lifts.
        case longPressed
        case twoDown(startTime: TimeInterval, lastCentroid: CGPoint, moved: Bool)
        /// Gesture is over but fingers are still down.
        case settling
    }

    private var state: State = .idle
    private var lastFrameTime: TimeInterval = 0

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// True while a gesture is in flight — i.e. a pointer button may be held down.
    public var hasActiveGesture: Bool {
        if case .idle = state { return false }
        return true
    }

    public mutating func handle(_ frame: MappedFrame) -> [GestureEvent] {
        lastFrameTime = frame.time
        let count = frame.contacts.count

        switch state {
        case .idle:
            return begin(frame, count: count)

        case .oneDown(let id, let start, let startTime):
            if count == 0 {
                state = .idle
                let wasTap = frame.time - startTime <= config.tapMaxDuration
                return wasTap ? [.leftClick(at: start), .sessionEnded] : [.sessionEnded]
            }
            if count >= 2 {
                // A second finger reclassifies the gesture; the pending tap is void.
                state = .twoDown(startTime: frame.time, lastCentroid: centroid(frame), moved: false)
                return []
            }
            guard let point = point(of: id, in: frame) else {
                // A different finger than the one we were tracking. Continuing would
                // charge this tap to the wrong location.
                state = .idle
                return [.sessionEnded]
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
                state = .twoDown(startTime: frame.time, lastCentroid: centroid(frame), moved: false)
                return [.dragEnded(at: last)]
            }
            guard let point = point(of: id, in: frame) else {
                // Tracked finger vanished and a different one is down: end the drag here
                // rather than teleport it onto whatever the new finger is over.
                state = .idle
                return [.dragEnded(at: last), .sessionEnded]
            }

            guard point != last else { return [] }
            state = .dragging(id: id, last: point)
            return [.dragMoved(to: point)]

        case .longPressed:
            guard count == 0 else { return [] }
            state = .idle
            return [.sessionEnded]

        case .twoDown(let startTime, let lastCentroid, let moved):
            if count == 0 {
                state = .idle
                let wasTap = !moved && frame.time - startTime <= config.tapMaxDuration
                return wasTap ? [.rightClick(at: lastCentroid), .sessionEnded] : [.sessionEnded]
            }
            if count == 1 {
                // One finger lifted mid-scroll: stop scrolling rather than lurch to a
                // single-contact centroid, and wait for the hand to leave the glass.
                state = .settling
                return []
            }

            let current = centroid(frame)
            let dx = current.x - lastCentroid.x
            let dy = current.y - lastCentroid.y
            guard dx != 0 || dy != 0 else { return [] }

            state = .twoDown(startTime: startTime, lastCentroid: current, moved: true)
            return [.scroll(dx: dx, dy: dy, at: current)]

        case .settling:
            guard count == 0 else { return [] }
            state = .idle
            return [.sessionEnded]
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
            state = .idle
            return [.dragEnded(at: last), .sessionEnded]

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

    private mutating func begin(_ frame: MappedFrame, count: Int) -> [GestureEvent] {
        switch count {
        case 0:
            return []
        case 1:
            let contact = frame.contacts[0]
            state = .oneDown(id: contact.id, start: contact.point, startTime: frame.time)
        default:
            state = .twoDown(startTime: frame.time, lastCentroid: centroid(frame), moved: false)
        }
        return []
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
