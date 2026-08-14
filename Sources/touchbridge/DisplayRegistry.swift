import CoreGraphics
import Foundation

/// Identifies a display by properties that survive a reboot or a replug.
/// `CGDirectDisplayID` itself does not, so it is never persisted.
struct DisplayFingerprint: Codable, Equatable {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32

    /// The touchscreen on this machine, read from CGDisplay at design time.
    /// Note the main display's vendor decodes to "VSC" (ViewSonic) while the touchscreen
    /// decodes to "VSP" — matching on brand alone would pick the wrong screen.
    static let knownTouchscreen = DisplayFingerprint(vendor: 23152, model: 342, serial: 16_777_216)
}

enum DisplayRegistry {

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func fingerprint(_ id: CGDirectDisplayID) -> DisplayFingerprint {
        DisplayFingerprint(
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id)
        )
    }

    /// Finds the touchscreen. Exact fingerprint first; if the panel was swapped, fall
    /// back to the sole non-main display so the app still does something sensible.
    static func touchDisplay(matching wanted: DisplayFingerprint = .knownTouchscreen) -> CGDirectDisplayID? {
        let displays = activeDisplays()

        if let exact = displays.first(where: { fingerprint($0) == wanted }) {
            return exact
        }

        let externals = displays.filter { CGDisplayIsMain($0) == 0 }
        return externals.count == 1 ? externals[0] : nil
    }

    static func mainDisplay() -> CGDirectDisplayID? {
        activeDisplays().first { CGDisplayIsMain($0) != 0 }
    }

    static func centre(of id: CGDirectDisplayID) -> CGPoint {
        let b = CGDisplayBounds(id)
        return CGPoint(x: b.midX, y: b.midY)
    }

    /// Fires when a display is added, removed, or re-arranged, so bounds can be re-read.
    static func onReconfiguration(_ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(ReconfigBox(handler)).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            // Only react once the move has actually happened.
            guard flags.contains(.setModeFlag) || flags.contains(.addFlag)
                    || flags.contains(.removeFlag) || flags.contains(.desktopShapeChangedFlag)
            else { return }
            guard let userInfo else { return }
            Unmanaged<ReconfigBox>.fromOpaque(userInfo).takeUnretainedValue().handler()
        }, box)
    }

    private final class ReconfigBox {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }
}
