import CoreGraphics
import Foundation
import TouchwardCore

/// Identifies a display by properties that outlive a restart or a replug.
/// `CGDirectDisplayID` itself does not, so it is never persisted.
struct DisplayFingerprint: Codable, Equatable {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
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

    /// Finds the touchscreen.
    ///
    /// There is no public API linking a USB HID device to a CGDirectDisplayID, and a
    /// display serial read off one machine is worthless on any other — so nothing about
    /// a specific panel is baked in here. The screen is inferred only when the inference
    /// is unambiguous, taken from the environment when the user states it, and otherwise
    /// reported as unknown rather than guessed at.
    static func touchDisplay() -> CGDirectDisplayID? {
        let displays = activeDisplays()

        // Named after the app. The old TOUCHBRIDGE_ name is still read because it was in
        // the log message people were told to follow.
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["TOUCHWARD_DISPLAY_ID"] ?? environment["TOUCHBRIDGE_DISPLAY_ID"],
           let requested = UInt32(raw),
           displays.contains(requested) {
            return requested
        }

        // Exactly one external display is the only case that can be inferred safely, and
        // it must never resolve to the main display: that maps every touch onto the wrong
        // monitor and makes the cursor "return home" to the screen it just left.
        let externals = displays.filter { CGDisplayIsMain($0) == 0 }
        guard externals.count == 1, externals[0] != mainDisplay() else { return nil }
        return externals[0]
    }

    /// The touchscreen, but only while touching it could mean anything.
    ///
    /// Resolved fresh every time rather than remembered: a display ID is minted anew when a
    /// panel is replugged, and a remembered one silently refers to a screen that no longer
    /// exists — which is how touches kept being mapped onto a monitor that had been
    /// switched off.
    static func usableTouchDisplay() -> CGDirectDisplayID? {
        guard let id = touchDisplay(), isUsable(id) else { return nil }
        return id
    }

    static func isUsable(_ id: CGDirectDisplayID) -> Bool {
        DisplayAvailability.isUsable(DisplayAvailability.Signals(
            isInActiveList: activeDisplays().contains(id),
            isActive: CGDisplayIsActive(id) != 0,
            isAsleep: CGDisplayIsAsleep(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0
        ))
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
            // The callback fires twice per change. The first pass happens BEFORE the
            // move, when CGDisplayBounds still reports the old geometry.
            guard !flags.contains(.beginConfigurationFlag) else { return }
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
