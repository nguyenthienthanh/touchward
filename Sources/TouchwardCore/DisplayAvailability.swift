import Foundation

/// Whether the touchscreen is in a state where touching it means anything.
///
/// "Plugged in" is not the same as "usable", and the difference is not academic: a panel
/// whose monitor has been switched off often keeps its USB side powered, so the digitizer
/// goes on reporting contacts for a screen nobody can see. Acting on those moves the
/// cursor to coordinates on a display that is not there.
///
/// Kept pure so the rule is stated once and tested, rather than being spread across three
/// call sites that each guessed at it — which is how a keyboard ended up stranded on the
/// main display after its own screen went away.
public enum DisplayAvailability {

    /// What CoreGraphics says about a display, gathered at the call site.
    public struct Signals: Equatable, Sendable {
        /// The display is in the active list — connected and part of the desktop.
        public let isInActiveList: Bool
        /// `CGDisplayIsActive`: drawable, rather than merely connected.
        public let isActive: Bool
        /// `CGDisplayIsAsleep`: the monitor has been switched off or has dozed.
        public let isAsleep: Bool
        /// `CGDisplayIsOnline`: the link is up at all.
        public let isOnline: Bool

        public init(isInActiveList: Bool, isActive: Bool, isAsleep: Bool, isOnline: Bool) {
            self.isInActiveList = isInActiveList
            self.isActive = isActive
            self.isAsleep = isAsleep
            self.isOnline = isOnline
        }
    }

    /// Every signal has to agree. Any one of them saying no is enough to stop: there is no
    /// version of this where guessing optimistically helps the user.
    public static func isUsable(_ signals: Signals) -> Bool {
        signals.isInActiveList && signals.isActive && signals.isOnline && !signals.isAsleep
    }
}
