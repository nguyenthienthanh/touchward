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

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Converts a HID value's own timestamp into the same monotonic seconds `now()` uses.
    ///
    /// Every value in one input report carries an identical timestamp, which is what lets
    /// the frame assembler tell one report from the next. Reading the clock per value
    /// instead would make every single value look like a new report.
    static func seconds(machTime: UInt64) -> TimeInterval {
        let nanos = Double(machTime) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }
}
