import Foundation

/// Holds what each finger slot is currently doing, across reports.
///
/// A multitouch report carries every finger collection the panel supports, but IOKit only
/// calls back for element values that *changed*. Two fingers resting mid-scroll therefore
/// send nothing but their new coordinates: no tip switch, no contact id, no contact count.
/// Anything that rebuilds a frame from one report's arrivals alone sees a finger vanish the
/// moment it stops changing — the same defect that made a sliding finger in mouse mode look
/// like a lifted one.
///
/// So state lives here, per slot, and a frame is a snapshot of it. The caller maps each
/// element to its slot once, from the device's own descriptor, and only ever pushes updates.
public struct SlotTracker: Sendable {
    public enum Field: Sendable {
        case tip
        case confidence
        case id
        case x
        case y
        case width
        case height
    }

    private struct Slot {
        var id: UInt8 = 0
        var x: Int?
        var y: Int?
        var width = 0
        var height = 0
        var tip = false
        var confident = true
    }

    private var slots: [Int: Slot] = [:]

    public init() {}

    public mutating func update(slot index: Int, field: Field, value: Int) {
        var slot = slots[index] ?? Slot()
        switch field {
        case .tip: slot.tip = value != 0
        case .confidence: slot.confident = value != 0
        case .id: slot.id = UInt8(truncatingIfNeeded: value)
        case .x: slot.x = value
        case .y: slot.y = value
        case .width: slot.width = value
        case .height: slot.height = value
        }
        slots[index] = slot
    }

    /// The fingers currently on the glass, in slot order so a frame-to-frame diff compares
    /// like with like.
    public func frame(at time: TimeInterval) -> TouchFrame {
        let contacts = slots.keys.sorted().compactMap { index -> Contact? in
            guard let slot = slots[index], slot.tip, slot.confident,
                  let x = slot.x, let y = slot.y else { return nil }
            return Contact(id: slot.id, x: x, y: y,
                           width: slot.width, height: slot.height,
                           isTouching: true, isConfident: true)
        }
        return TouchFrame(contacts: contacts, time: time)
    }

    /// Drops every finger. For unplug and sleep, where the panel will never send the
    /// tip-switch release that would otherwise clear this state.
    public mutating func releaseAll() {
        slots.removeAll()
    }
}
