import Foundation

/// Monotonic time source for everything the gesture layer measures.
///
/// `Date()` is wall-clock: an NTP correction can step it backwards, which would make a
/// held drag's staleness check go negative and silently disable the only backstop that
/// releases a stuck mouse button. It can also jump forwards and cut a live drag short.
/// `systemUptime` never does either.
enum Clock {
    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
