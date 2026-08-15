import Foundation

/// HID usages this driver understands. Named, not hardcoded offsets: the OS decodes each
/// report against the device's own descriptor and hands us (usage, value) pairs, so no
/// byte layout is assumed anywhere.
public enum Usage {
    public enum Page {
        public static let genericDesktop = 0x01
        public static let digitizer = 0x0D
    }

    public static let x = 0x30
    public static let y = 0x31

    public static let touchScreen = 0x04
    public static let finger = 0x22
    public static let tipSwitch = 0x42
    public static let confidence = 0x47
    public static let width = 0x48
    public static let height = 0x49
    public static let contactIdentifier = 0x51
    public static let contactCount = 0x54
    public static let contactCountMaximum = 0x55
    public static let deviceConfiguration = 0x0E
    public static let inputMode = 0x52
}

/// Rebuilds a touch frame from the stream of decoded element values IOKit delivers.
///
/// Values arrive one at a time, in descriptor order: each finger collection repeats the
/// same usages, and the report ends with a contact count. Two device-driven rules assemble
/// them, so nothing here depends on how many fingers the panel supports or how its report
/// is laid out:
///
///   * a usage that is already filled means the next finger collection has started;
///   * the contact-count usage, or a change of timestamp, closes the report.
public struct TouchValueAssembler: Sendable {

    private struct Partial {
        var id: UInt8?
        var x: Int?
        var y: Int?
        var width: Int?
        var height: Int?
        var tip: Bool?
        var confident: Bool?

        var isEmpty: Bool {
            id == nil && x == nil && y == nil && width == nil && height == nil
                && tip == nil && confident == nil
        }

        func hasValue(forPage page: Int, usage: Int) -> Bool {
            switch (page, usage) {
            case (Usage.Page.digitizer, Usage.tipSwitch): return tip != nil
            case (Usage.Page.digitizer, Usage.confidence): return confident != nil
            case (Usage.Page.digitizer, Usage.contactIdentifier): return id != nil
            case (Usage.Page.digitizer, Usage.width): return width != nil
            case (Usage.Page.digitizer, Usage.height): return height != nil
            case (Usage.Page.genericDesktop, Usage.x): return x != nil
            case (Usage.Page.genericDesktop, Usage.y): return y != nil
            default: return false
            }
        }
    }

    private var contacts: [Partial] = []
    private var current = Partial()
    private var frameTime: TimeInterval?

    public init() {}

    /// Feeds one decoded value. Returns a frame when the report is complete.
    public mutating func accept(usagePage: Int, usage: Int, value: Int, time: TimeInterval) -> TouchFrame? {
        var completed: TouchFrame?

        // A new timestamp means the previous report ended without a contact count.
        if let frameTime, frameTime != time {
            completed = flush(at: frameTime)
        }
        frameTime = time

        if usagePage == Usage.Page.digitizer && usage == Usage.contactCount {
            // The count itself closes the report; its value is not needed, because only
            // contacts the device actually sent are ever emitted.
            let frame = flush(at: time)
            frameTime = nil
            return completed ?? frame
        }

        guard isTracked(page: usagePage, usage: usage) else { return completed }

        if current.hasValue(forPage: usagePage, usage: usage) {
            contacts.append(current)
            current = Partial()
        }
        assign(page: usagePage, usage: usage, value: value)

        return completed
    }

    /// Ends the report in progress, e.g. when the device stops sending.
    public mutating func flushPending(at time: TimeInterval) -> TouchFrame? {
        let frame = flush(at: time)
        frameTime = nil
        return frame
    }

    private mutating func flush(at time: TimeInterval) -> TouchFrame? {
        if !current.isEmpty {
            contacts.append(current)
            current = Partial()
        }
        guard !contacts.isEmpty else { return nil }

        let finished = contacts.compactMap { partial -> Contact? in
            // A contact only counts while its tip switch is set. Confidence is optional:
            // some controllers only ever report it for palm rejection and others never
            // set it at all, so its absence must not mean "reject everything".
            guard partial.tip == true, partial.confident != false else { return nil }
            guard let x = partial.x, let y = partial.y else { return nil }

            return Contact(id: partial.id ?? 0, x: x, y: y,
                           width: partial.width ?? 0, height: partial.height ?? 0,
                           isTouching: true, isConfident: true)
        }

        contacts.removeAll()
        return TouchFrame(contacts: finished, time: time)
    }

    private func isTracked(page: Int, usage: Int) -> Bool {
        switch (page, usage) {
        case (Usage.Page.digitizer, Usage.tipSwitch),
             (Usage.Page.digitizer, Usage.confidence),
             (Usage.Page.digitizer, Usage.contactIdentifier),
             (Usage.Page.digitizer, Usage.width),
             (Usage.Page.digitizer, Usage.height),
             (Usage.Page.genericDesktop, Usage.x),
             (Usage.Page.genericDesktop, Usage.y):
            return true
        default:
            return false
        }
    }

    private mutating func assign(page: Int, usage: Int, value: Int) {
        switch (page, usage) {
        case (Usage.Page.digitizer, Usage.tipSwitch): current.tip = value != 0
        case (Usage.Page.digitizer, Usage.confidence): current.confident = value != 0
        case (Usage.Page.digitizer, Usage.contactIdentifier): current.id = UInt8(truncatingIfNeeded: value)
        case (Usage.Page.digitizer, Usage.width): current.width = value
        case (Usage.Page.digitizer, Usage.height): current.height = value
        case (Usage.Page.genericDesktop, Usage.x): current.x = value
        case (Usage.Page.genericDesktop, Usage.y): current.y = value
        default: break
        }
    }
}

/// Palm rejection sized against what the device actually reports, rather than a constant
/// copied from one panel. Until a real contact has been seen the filter stays open.
public struct PalmFilter: Sendable {
    /// Fraction of the digitizer's own logical range above which a contact is a palm.
    public var maxSizeFraction: Double

    private let logicalMax: Double

    public init(logicalMax: Double, maxSizeFraction: Double = 0.22) {
        self.logicalMax = logicalMax
        self.maxSizeFraction = maxSizeFraction
    }

    public func reject(_ frame: TouchFrame) -> TouchFrame {
        guard logicalMax > 0 else { return frame }
        let limit = logicalMax * maxSizeFraction

        return TouchFrame(
            contacts: frame.contacts.filter { contact in
                // Size of 0 means the device does not report contact area — not a palm.
                let width = Double(contact.width), height = Double(contact.height)
                guard width > 0 || height > 0 else { return true }
                return width <= limit && height <= limit
            },
            time: frame.time
        )
    }
}
