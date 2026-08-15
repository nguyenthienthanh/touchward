import CoreGraphics
import Foundation

/// One finger as reported by the digitizer, in raw HID units (0…logicalMax).
public struct Contact: Equatable, Sendable {
    public let id: UInt8
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let isTouching: Bool
    public let isConfident: Bool

    public init(id: UInt8, x: Int, y: Int, width: Int = 0, height: Int = 0,
                isTouching: Bool, isConfident: Bool = true) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isTouching = isTouching
        self.isConfident = isConfident
    }
}

/// A parsed HID report, normalised across the digitizer and mouse report layouts.
public struct TouchFrame: Equatable, Sendable {
    public let contacts: [Contact]
    public let time: TimeInterval

    public init(contacts: [Contact], time: TimeInterval) {
        self.contacts = contacts
        self.time = time
    }
}

/// A contact after mapping into global display coordinates.
public struct MappedContact: Equatable, Sendable {
    public let id: UInt8
    public let point: CGPoint

    public init(id: UInt8, point: CGPoint) {
        self.id = id
        self.point = point
    }
}

public struct MappedFrame: Equatable, Sendable {
    public let contacts: [MappedContact]
    public let time: TimeInterval

    public init(contacts: [MappedContact], time: TimeInterval) {
        self.contacts = contacts
        self.time = time
    }
}

/// What the recognizer decided happened. Deltas are finger displacement in points;
/// the synthesizer owns scroll direction so the recognizer stays free of platform polarity.
public enum GestureEvent: Equatable, Sendable {
    case leftClick(at: CGPoint)
    case rightClick(at: CGPoint)
    case dragBegan(at: CGPoint)
    case dragMoved(to: CGPoint)
    case dragEnded(at: CGPoint)
    case scroll(dx: CGFloat, dy: CGFloat, at: CGPoint)
    /// Three fingers opened or closed. `scale` is the ratio against the previous frame —
    /// 1.5 means the hand opened by half again — so it composes by multiplication and
    /// carries no notion of what zooming means on any particular platform.
    case pinch(scale: CGFloat, at: CGPoint)
    /// Every finger lifted. The cursor-return timer starts here.
    case sessionEnded
}
