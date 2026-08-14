import Foundation

/// Report IDs declared by the SiS HID Touch Controller (VID 0x0457 / PID 0x0819).
public enum ReportID {
    /// Digitizer: 5 finger collections of 10 bytes, then contact count and scan time.
    public static let digitizer: UInt8 = 0x91
    /// Fallback Mouse collection: buttons byte, then absolute X and Y.
    public static let mouse: UInt8 = 0x03
}

public enum HIDReportParser {
    public static let maxContacts = 5
    public static let bytesPerContact = 10
    public static let digitizerBodyLength = maxContacts * bytesPerContact + 1  // + contact count
    public static let mouseBodyLength = 5

    /// Contacts wider or taller than this in raw units are a palm or forearm, not a finger.
    public static let defaultMaxContactSize = 900

    /// Parses a raw input report. `bytes` must already have the report ID stripped,
    /// which is what `IOHIDDeviceRegisterInputReportCallback` hands back.
    ///
    /// Returns nil for reports this driver does not own, so the caller can ignore them
    /// without having to know the descriptor layout.
    public static func parse(
        reportID: UInt8,
        bytes: [UInt8],
        time: TimeInterval,
        maxContactSize: Int = defaultMaxContactSize
    ) -> TouchFrame? {
        switch reportID {
        case ReportID.digitizer:
            return parseDigitizer(bytes, time: time, maxContactSize: maxContactSize)
        case ReportID.mouse:
            return parseMouse(bytes, time: time)
        default:
            return nil
        }
    }

    private static func parseDigitizer(_ bytes: [UInt8], time: TimeInterval, maxContactSize: Int) -> TouchFrame? {
        guard bytes.count >= digitizerBodyLength else { return nil }

        var contacts: [Contact] = []
        contacts.reserveCapacity(maxContacts)

        for slot in 0..<maxContacts {
            let o = slot * bytesPerContact
            let flags = bytes[o]
            let isTouching = flags & 0x01 != 0
            let isConfident = flags & 0x02 != 0

            // A clear tip switch means the slot is stale, not a finger resting at (0,0).
            guard isTouching, isConfident else { continue }

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
