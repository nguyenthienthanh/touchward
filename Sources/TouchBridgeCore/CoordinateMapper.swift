import CoreGraphics
import Foundation

/// Trims the active touch area to a sub-rectangle of the raw range, as fractions of it.
/// Identity means "the panel reports edge to edge"; calibration shrinks or shifts that.
public struct Calibration: Equatable, Sendable {
    public var xMin, xMax, yMin, yMax: Double

    public static let identity = Calibration(xMin: 0, xMax: 1, yMin: 0, yMax: 1)

    public init(xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }
}

public struct CoordinateMapper: Sendable {
    public let logicalMax: Double
    public let displayBounds: CGRect
    public var calibration: Calibration

    public init(logicalMax: Double = 4095, displayBounds: CGRect, calibration: Calibration = .identity) {
        self.logicalMax = logicalMax
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
            x: displayBounds.origin.x + CGFloat(normalise(Double(x), min: calibration.xMin, max: calibration.xMax)) * displayBounds.width,
            y: displayBounds.origin.y + CGFloat(normalise(Double(y), min: calibration.yMin, max: calibration.yMax)) * displayBounds.height
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
    private func normalise(_ raw: Double, min lower: Double, max upper: Double) -> Double {
        let span = upper - lower
        guard span > 0, logicalMax > 0 else { return 0 }

        let fraction = (raw / logicalMax - lower) / span
        return Swift.min(Swift.max(fraction, 0), 1)
    }
}
