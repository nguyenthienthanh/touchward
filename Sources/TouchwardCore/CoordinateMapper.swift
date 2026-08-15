import CoreGraphics
import Foundation

/// Trims the active touch area to a sub-rectangle of the raw range, as fractions of it.
/// Identity means "the panel reports edge to edge"; calibration shrinks or shifts that.
public struct Calibration: Equatable, Sendable {
    /// Read-only after construction: these are `private(set)` so the validation below
    /// cannot be undone by assigning a degenerate range afterwards, which would pin every
    /// touch to one edge and read as "the touchscreen is broken".
    public private(set) var xMin, xMax, yMin, yMax: Double

    public static let identity = Calibration(xMin: 0, xMax: 1, yMin: 0, yMax: 1)

    /// An inverted or empty range would silently pin every touch to one edge, which reads
    /// as "the touchscreen is broken". Fall back to the full range instead.
    public init(xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        let x = Calibration.validate(xMin, xMax)
        let y = Calibration.validate(yMin, yMax)
        self.xMin = x.lower
        self.xMax = x.upper
        self.yMin = y.lower
        self.yMax = y.upper
    }

    /// Bounds are fractions of the raw range, so anything outside 0…1 is meaningless, and
    /// an inverted or empty range is unusable. Both fall back to the full range.
    private static func validate(_ lower: Double, _ upper: Double) -> (lower: Double, upper: Double) {
        let clampedLower = min(max(lower, 0), 1)
        let clampedUpper = min(max(upper, 0), 1)
        guard clampedUpper > clampedLower else { return (0, 1) }
        return (clampedLower, clampedUpper)
    }
}

public struct CoordinateMapper: Sendable {
    /// Per axis, because a panel may declare different ranges for X and Y. Both come from
    /// the device's own descriptor — there is no default, so a wrong value cannot hide.
    public let logicalMaxX: Double
    public let logicalMaxY: Double
    public let displayBounds: CGRect
    public var calibration: Calibration

    public init(logicalMaxX: Double, logicalMaxY: Double,
                displayBounds: CGRect, calibration: Calibration = .identity) {
        self.logicalMaxX = logicalMaxX
        self.logicalMaxY = logicalMaxY
        self.displayBounds = displayBounds
        self.calibration = calibration
    }

    /// Maps a raw digitizer coordinate into the global, top-left-origin space that
    /// CGEventPost expects.
    ///
    /// The display origin is added rather than assumed to be zero: on a multi-display
    /// Mac the touchscreen frequently sits at a negative origin, and dropping that term
    /// lands every touch on the main display instead.
    public func globalPoint(x: Int, y: Int) -> CGPoint {
        CGPoint(
            x: displayBounds.origin.x + CGFloat(normalise(Double(x), logicalMax: logicalMaxX, min: calibration.xMin, max: calibration.xMax)) * displayBounds.width,
            y: displayBounds.origin.y + CGFloat(normalise(Double(y), logicalMax: logicalMaxY, min: calibration.yMin, max: calibration.yMax)) * displayBounds.height
        )
    }

    public func map(_ frame: TouchFrame) -> MappedFrame {
        MappedFrame(
            contacts: frame.contacts.map {
                MappedContact(id: $0.id, point: globalPoint(x: $0.x, y: $0.y))
            },
            time: frame.time
        )
    }

    /// Raw value to a 0…1 fraction of the calibrated window, clamped so a touch outside
    /// the calibrated area stays on this display rather than escaping onto another one.
    private func normalise(_ raw: Double, logicalMax: Double, min lower: Double, max upper: Double) -> Double {
        let span = upper - lower
        guard span > 0, logicalMax > 0 else { return 0 }

        let fraction = (raw / logicalMax - lower) / span
        return Swift.min(Swift.max(fraction, 0), 1)
    }
}
