import Foundation

/// Report IDs declared by the SiS HID Touch Controller (VID 0x0457 / PID 0x0819).
public enum ReportID {
    /// Digitizer: 5 finger collections of 10 bytes, then contact count and scan time.
    public static let digitizer: UInt8 = 0x91
    /// Fallback Mouse collection: buttons byte, then absolute X and Y.
    public static let mouse: UInt8 = 0x03
}

/// The controller declares both a digitizer and a mouse collection, and may emit both.
/// Mixing them corrupts the gesture state machine: a mouse report carries at most one
/// contact, so an interleaved one reads as "a finger lifted" in the middle of a scroll.
///
/// Rule: whichever collection first produces a real contact owns the session.
public struct ReportStreamLatch: Sendable {
    private var latched: UInt8?

    public init() {}

    public var latchedReportID: UInt8? { latched }

    public mutating func accepts(reportID: UInt8, hasContacts: Bool) -> Bool {
        if let latched {
            return reportID == latched
        }
        if hasContacts {
            latched = reportID
        }
        return true
    }

    public mutating func reset() {
        latched = nil
    }
}

public enum HIDReportParser {
    public static let maxContacts = 5
    public static let bytesPerContact = 10
    public static let contactCountOffset = maxContacts * bytesPerContact  // 50
    public static let digitizerBodyLength = contactCountOffset + 1
    public static let mouseBodyLength = 5

    /// Contacts wider or taller than this in raw units are a palm or forearm, not a finger.
    public static let defaultMaxContactSize = 900

    /// Parses a raw input report. Returns nil for reports this driver does not own, so the
    /// caller can ignore them without knowing the descriptor layout.
    ///
    /// Tolerates the report ID still being present as byte 0: IOKit strips it for some
    /// devices and not others, and getting that wrong shifts every field by one.
    public static func parse(
        reportID: UInt8,
        bytes: [UInt8],
        time: TimeInterval,
        maxContactSize: Int = defaultMaxContactSize
    ) -> TouchFrame? {
        switch reportID {
        case ReportID.digitizer:
            return parseDigitizer(stripPrefix(bytes, reportID: reportID), time: time, maxContactSize: maxContactSize)
        case ReportID.mouse:
            return parseMouse(stripPrefix(bytes, reportID: reportID), time: time)
        default:
            return nil
        }
    }

    /// The digitizer's first body byte holds only the tip and confidence bits, so any value
    /// above 0x03 there can only be the report ID. The mouse body is a fixed 5 bytes, so an
    /// extra leading byte is detectable by length instead — its buttons byte can legitimately
    /// equal 0x03.
    private static func stripPrefix(_ bytes: [UInt8], reportID: UInt8) -> [UInt8] {
        guard let first = bytes.first, first == reportID else { return bytes }

        switch reportID {
        case ReportID.digitizer where first > 0x03:
            return Array(bytes.dropFirst())
        case ReportID.mouse where bytes.count > mouseBodyLength:
            return Array(bytes.dropFirst())
        default:
            return bytes
        }
    }

    private static func parseDigitizer(_ bytes: [UInt8], time: TimeInterval, maxContactSize: Int) -> TouchFrame? {
        guard bytes.count >= digitizerBodyLength else { return nil }

        // Slots past the reported count hold stale data whose tip bit is often still set.
        let reported = Int(bytes[contactCountOffset])
        let slots = min(max(reported, 0), maxContacts)

        var contacts: [Contact] = []
        contacts.reserveCapacity(slots)

        for slot in 0..<slots {
            let o = slot * bytesPerContact
            let flags = bytes[o]

            guard flags & 0x01 != 0, flags & 0x02 != 0 else { continue }

            let width = littleEndian16(bytes, o + 6)
            let height = littleEndian16(bytes, o + 8)
            guard width <= maxContactSize, height <= maxContactSize else { continue }

            contacts.append(Contact(
                id: bytes[o + 1],
                x: littleEndian16(bytes, o + 2),
                y: littleEndian16(bytes, o + 4),
                width: width,
                height: height,
                isTouching: true,
                isConfident: true
            ))
        }

        return TouchFrame(contacts: contacts, time: time)
    }

    /// The controller may never leave mouse mode. That report carries one absolute
    /// position and the button state, which is still enough to drive a pointer.
    private static func parseMouse(_ bytes: [UInt8], time: TimeInterval) -> TouchFrame? {
        guard bytes.count >= mouseBodyLength else { return nil }

        guard bytes[0] & 0x01 != 0 else {
            return TouchFrame(contacts: [], time: time)
        }

        let contact = Contact(
            id: 0,
            x: littleEndian16(bytes, 1),
            y: littleEndian16(bytes, 3),
            isTouching: true,
            isConfident: true
        )
        return TouchFrame(contacts: [contact], time: time)
    }

    private static func littleEndian16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }
}
