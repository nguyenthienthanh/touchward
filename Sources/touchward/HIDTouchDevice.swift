import Foundation
import IOKit
import IOKit.hid
import TouchwardCore

/// What the panel says about itself. Every field is read from the device's own HID
/// elements — nothing here is a constant copied off one machine.
struct DeviceProfile {
    var logicalMaxX: Double
    var logicalMaxY: Double
    var maxContacts: Int
    /// Report ID of the Digitizer Device Configuration feature, when the device has one.
    var inputModeReportID: UInt8?
    var productName: String

    var logicalMax: Double { max(logicalMaxX, logicalMaxY) }
}

/// Owns the physical touchscreen: finds it by what it declares, takes it away from macOS's
/// default handling, asks it for multitouch, and publishes decoded touch frames.
///
/// Matching is by HID usage, not vendor and product IDs: any panel that declares itself a
/// Digitizer / Touch Screen is one, whereas a VID/PID pair only ever describes the single
/// unit it was read from. Reports are consumed as decoded element values, so no byte
/// offset, contact count or report layout is assumed anywhere in this project.
final class HIDTouchDevice {

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var openOptionsByDevice: [IOOptionBits] = []
    private var assembler = TouchValueAssembler()
    private var onFrame: ((TouchFrame) -> Void)?

    private(set) var isSeized = false
    private(set) var seizedInterfaces = 0
    private var valuesSeen = 0
    private var digitizerValuesSeen = 0
    private var framesEmitted = 0
    private(set) var inputModeSet = false
    private(set) var profile: DeviceProfile?

    /// Called when the panel is unplugged, so the caller can release anything held.
    var onDisconnect: (() -> Void)?

    func start(onFrame: @escaping (TouchFrame) -> Void) -> Result<DeviceProfile, StartError> {
        self.onFrame = onFrame

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Declared usage, not VID/PID: this is what lets the driver work on a panel it has
        // never seen before.
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: Usage.Page.digitizer,
            kIOHIDDeviceUsageKey: Usage.touchScreen,
        ] as CFDictionary)

        // Enumerate WITHOUT opening the manager.
        //
        // IOHIDManagerOpen opens every matched device shared, through the same user
        // client. A later IOHIDDeviceOpen(…Seize) on that same client hits IOKit's
        // "multiple opens" guard, which returns success but never records the seize — so
        // the device stays shared, macOS keeps driving the pointer from it, and the log
        // cheerfully reports a seize that never happened. Matching alone is enough to
        // enumerate; the one and only open is the seize below.
        guard let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = found.first else {
            let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard opened == kIOReturnSuccess else { return .failure(.managerOpenFailed(opened)) }
            guard let retry = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
                  let device = retry.first else { return .failure(.deviceNotFound) }
            guard let profile = attach(device) else { return .failure(.unreadableDescriptor) }
            self.profile = profile
            return .success(profile)
        }

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<HIDTouchDevice>.fromOpaque(context).takeUnretainedValue().handleRemoval()
        }, Unmanaged.passUnretained(self).toOpaque())

        // The manager needs its own run-loop scheduling: per-device scheduling below only
        // delivers input, never the removal callback.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // If a panel splits its collections across several interfaces, the one carrying
        // Input Mode may not be the one we opened — worth knowing before blaming the write.
        if found.count > 1 {
            log("ℹ️  Có \(found.count) thiết bị khai báo Digitizer/Touch Screen; đang dùng cái đầu tiên.")
        }

        guard let profile = attach(device) else { return .failure(.unreadableDescriptor) }
        self.profile = profile
        return .success(profile)
    }

    /// This panel publishes a single IOHIDDevice carrying every top-level collection —
    /// digitizer, mouse, and device configuration alike. Because the seize is recorded on
    /// the IOHIDDevice and gates all of its interface nubs, one correct seize silences the
    /// mouse collection too; there are no siblings to chase.
    private func attach(_ device: IOHIDDevice) -> DeviceProfile? {
        var options = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        if IOHIDDeviceOpen(device, options) == kIOReturnSuccess {
            isSeized = true
        } else {
            // Close before retrying: a second open from the same client is discarded by
            // IOKit, so reopening without closing would silently keep the failed state.
            IOHIDDeviceClose(device, options)
            options = IOOptionBits(kIOHIDOptionsTypeNone)
            guard IOHIDDeviceOpen(device, options) == kIOReturnSuccess else { return nil }
        }

        devices.append(device)
        openOptionsByDevice.append(options)

        guard let profile = readProfile(device) else { return nil }
        switchToMultitouch(device, reportID: profile.inputModeReportID)
        mapFingerElements(device)

        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDTouchDevice>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, Unmanaged.passUnretained(self).toOpaque())

        // Common modes: in default mode the touch stream stalls whenever a control in our
        // own keyboard panel is tracking — precisely when a held button needs releasing.
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return profile
    }

    /// Reads ranges and capabilities straight off the descriptor the device published.
    private func readProfile(_ device: IOHIDDevice) -> DeviceProfile? {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] else {
            return nil
        }

        var maxX = 0.0
        var maxY = 0.0
        var tipSwitchCount = 0
        var inputModeReportID: UInt8?

        for element in elements {
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let logicalMax = Double(IOHIDElementGetLogicalMax(element))

            switch (page, usage) {
            case (Usage.Page.genericDesktop, Usage.x):
                maxX = max(maxX, logicalMax)
            case (Usage.Page.genericDesktop, Usage.y):
                maxY = max(maxY, logicalMax)
            case (Usage.Page.digitizer, Usage.tipSwitch):
                // One tip switch per finger collection: the contact count as declared,
                // rather than a number counted by hand off one descriptor.
                tipSwitchCount += 1
            case (Usage.Page.digitizer, Usage.inputMode):
                if IOHIDElementGetType(element) == kIOHIDElementTypeFeature {
                    inputModeReportID = UInt8(truncatingIfNeeded: IOHIDElementGetReportID(element))
                }
            default:
                break
            }
        }

        guard maxX > 0, maxY > 0 else { return nil }

        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Touchscreen"
        return DeviceProfile(logicalMaxX: maxX, logicalMaxY: maxY,
                             maxContacts: max(tipSwitchCount, 1),
                             inputModeReportID: inputModeReportID,
                             productName: name)
    }

    /// Which finger collection each element belongs to, keyed by the cookie IOKit stamps
    /// on it. Built once from the descriptor.
    ///
    /// Order of arrival cannot identify a finger: the panel re-sends only what changed, so
    /// a report where finger 2 moved and finger 1 did not carries a single pair of
    /// coordinates with nothing to say whose they are. The cookie says.
    private var fingerFields: [IOHIDElementCookie: (slot: Int, field: SlotTracker.Field)] = [:]
    private var tracker = SlotTracker()
    private var pendingSlotTime: TimeInterval?
    private var slotFlush: Timer?

    private func mapFingerElements(_ device: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] else {
            return
        }

        // A finger is a collection containing a tip switch; the slot is that collection's
        // position in the descriptor. Nothing here counts fingers or assumes a layout.
        let tipSwitches = elements.filter {
            IOHIDElementGetType($0) != kIOHIDElementTypeFeature
                && Int(IOHIDElementGetUsagePage($0)) == Usage.Page.digitizer
                && Int(IOHIDElementGetUsage($0)) == Usage.tipSwitch
        }

        for (slot, tipSwitch) in tipSwitches.enumerated() {
            guard let collection = IOHIDElementGetParent(tipSwitch),
                  let children = IOHIDElementGetChildren(collection) as? [IOHIDElement] else {
                fingerFields[IOHIDElementGetCookie(tipSwitch)] = (slot, .tip)
                continue
            }

            for child in children {
                let page = Int(IOHIDElementGetUsagePage(child))
                let usage = Int(IOHIDElementGetUsage(child))
                let field: SlotTracker.Field?
                switch (page, usage) {
                case (Usage.Page.digitizer, Usage.tipSwitch): field = .tip
                case (Usage.Page.digitizer, Usage.confidence): field = .confidence
                case (Usage.Page.digitizer, Usage.contactIdentifier): field = .id
                case (Usage.Page.digitizer, Usage.width): field = .width
                case (Usage.Page.digitizer, Usage.height): field = .height
                case (Usage.Page.genericDesktop, Usage.x): field = .x
                case (Usage.Page.genericDesktop, Usage.y): field = .y
                default: field = nil
                }
                if let field {
                    fingerFields[IOHIDElementGetCookie(child)] = (slot, field)
                }
            }
        }

        if !tipSwitches.isEmpty {
            log("   Đã lập bản đồ \(tipSwitches.count) khe ngón tay từ descriptor.")
        }
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))

        valuesSeen += 1
        if valuesSeen == 1 {
            log("📥 Nhận được dữ liệu đầu tiên từ màn cảm ứng.")
        }

        // Bounded trace of exactly what the panel sends. Guessing at the report shape is
        // what produced the last two bugs; this shows it instead.
        if valuesSeen <= 40 {
            log(String(format: "   [%02d] page=0x%02X usage=0x%02X value=%d",
                       valuesSeen, page, usage, IOHIDValueGetIntegerValue(value)))
        }

        // The mouse-mode trace above fills its 40 lines with X and Y and never shows
        // whether real digitizer reports ever start. Trace those separately, so a panel
        // that switches mode mid-session leaves evidence instead of a silence.
        if page == Usage.Page.digitizer, digitizerValuesSeen < 20 {
            digitizerValuesSeen += 1
            log(String(format: "   ⌁[%02d] digitizer usage=0x%02X value=%d",
                       digitizerValuesSeen, usage, IOHIDValueGetIntegerValue(value)))
        }

        let integer = IOHIDValueGetIntegerValue(value)

        // The value's own timestamp, not the wall clock: all values from one report share
        // it, and that shared value is exactly how a report boundary is detected.
        let time = Clock.seconds(machTime: IOHIDValueGetTimeStamp(value))

        // A finger element: the panel is speaking real multitouch, and every finger's state
        // is held per slot rather than rebuilt from whatever this one report mentioned.
        if let target = fingerFields[IOHIDElementGetCookie(element)] {
            if let pending = pendingSlotTime, pending != time {
                emitSlotFrame(at: pending)
            }
            pendingSlotTime = time
            tracker.update(slot: target.slot, field: target.field, value: integer)
            scheduleSlotFlush()
            return
        }

        // Contact count closes a digitizer report — but only when it changes, which it does
        // not while two fingers rest mid-scroll. The flush timer covers that case.
        if page == Usage.Page.digitizer, usage == Usage.contactCount, pendingSlotTime != nil {
            emitSlotFrame(at: time)
            return
        }

        // Nothing mapped: the panel is still in mouse-compatibility mode, where a single
        // contact is inferred from button 1 and the last coordinates seen.
        guard fingerFields.isEmpty || page != Usage.Page.digitizer else { return }

        if let frame = assembler.accept(usagePage: page, usage: usage,
                                        value: integer, time: time) {
            deliver(frame)
        }
    }

    /// The last report of a gesture — every finger up — changes tip switches and then the
    /// device goes quiet. Without this, that final report would sit unflushed and the touch
    /// would never end.
    private func scheduleSlotFlush() {
        slotFlush?.invalidate()
        let timer = Timer(timeInterval: 0.025, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pendingSlotTime else { return }
            self.emitSlotFrame(at: pending)
        }
        RunLoop.main.add(timer, forMode: .common)
        slotFlush = timer
    }

    private func emitSlotFrame(at time: TimeInterval) {
        pendingSlotTime = nil
        slotFlush?.invalidate()
        slotFlush = nil
        deliver(tracker.frame(at: time))
    }

    private func deliver(_ frame: TouchFrame) {
        framesEmitted += 1
        if framesEmitted <= 12 || frame.contacts.count >= 2 && framesEmitted <= 60 {
            let detail = frame.contacts
                .map { "id=\($0.id) (\($0.x),\($0.y))" }
                .joined(separator: " ")
            log("👆 Frame \(framesEmitted): \(frame.contacts.count) điểm chạm \(detail)")
        }
        onFrame?(frame)
    }

    /// Windows writes Input Mode to move the controller out of its mouse-compatibility
    /// mode; macOS never does, which is why an untouched panel behaves like a button-only
    /// pointing device.
    ///
    /// The previous version trusted `IOHIDDeviceSetReport`'s return code. That code says
    /// the write left the host, not that the controller changed mode — the log claimed
    /// multitouch was on while the panel went on sending mouse reports. Every route here
    /// is therefore verified by reading Input Mode back, and what the device actually
    /// answers is logged.
    private func switchToMultitouch(_ device: IOHIDDevice, reportID: UInt8?) {
        guard let element = inputModeElement(device) else {
            log("ℹ️  Panel không có Input Mode trong descriptor — không thể yêu cầu multitouch.")
            return
        }

        let before = readInputMode(device, element: element)
        log("   Input Mode hiện tại: \(before.map(String.init) ?? "không đọc được")")
        if before == 2 {
            inputModeSet = true
            return
        }

        // Route 1: let IOKit build the feature report from the descriptor. It knows the
        // report's length and where the field sits inside it; a hand-built buffer only
        // guesses at both.
        if let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 2) as IOHIDValue?,
           IOHIDDeviceSetValue(device, element, value) == kIOReturnSuccess,
           readInputMode(device, element: element) == 2 {
            inputModeSet = true
            log("✅ Đã bật multitouch qua element Input Mode.")
            return
        }

        // Route 2: read the feature report, change only the mode byte, write it back —
        // what hid-multitouch on Linux does. Preserving the rest matters: the report also
        // carries a device index that some controllers reject when zeroed.
        guard let reportID else { return }
        if setInputModeByReport(device, reportID: reportID),
           readInputMode(device, element: element) == 2 {
            inputModeSet = true
            log("✅ Đã bật multitouch qua feature report \(reportID).")
            return
        }

        log("""
            ⚠️  Panel từ chối chuyển sang multitouch (Input Mode vẫn là \
            \(readInputMode(device, element: element).map(String.init) ?? "?")).
                Chỉ có 1 điểm chạm, nên cuộn hai ngón không thể hoạt động.
            """)
    }

    private func inputModeElement(_ device: IOHIDDevice) -> IOHIDElement? {
        let matching = [
            kIOHIDElementUsagePageKey: Usage.Page.digitizer,
            kIOHIDElementUsageKey: Usage.inputMode,
        ] as CFDictionary
        guard let elements = IOHIDDeviceCopyMatchingElements(device, matching, 0) as? [IOHIDElement] else {
            return nil
        }
        return elements.first { IOHIDElementGetType($0) == kIOHIDElementTypeFeature }
    }

    /// Reading a feature element issues a GetReport, so this is the device's own answer
    /// rather than a cached copy of what we asked for.
    private func readInputMode(_ device: IOHIDDevice, element: IOHIDElement) -> Int? {
        // The C call writes into a non-optional out-parameter, so it needs something to
        // overwrite; this placeholder is never read.
        let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
        var value = Unmanaged.passUnretained(placeholder)
        guard IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess else { return nil }
        return IOHIDValueGetIntegerValue(value.takeUnretainedValue())
    }

    private func setInputModeByReport(_ device: IOHIDDevice, reportID: UInt8) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(buffer.count)

        // Start from what the device has, so only the mode changes. If it will not answer,
        // fall back to the shortest report the spec allows: mode plus device index.
        if IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID),
                                &buffer, &length) == kIOReturnSuccess, length > 0 {
            buffer = Array(buffer.prefix(Int(length)))
            log("   Feature report \(reportID) đọc về: \(buffer.map { String(format: "%02X", $0) }.joined(separator: " "))")
        } else {
            buffer = [0, 0]
        }

        // The mode is the report's first field. When the ID was included in the buffer the
        // device returned, it sits one byte further in.
        for modeIndex in buffer.first == reportID ? [1, 0] : [0, 1] where buffer.indices.contains(modeIndex) {
            var payload = buffer
            payload[modeIndex] = 2
            if IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID),
                                    &payload, payload.count) == kIOReturnSuccess {
                return true
            }
        }
        return false
    }

    private func handleRemoval() {
        onDisconnect?()
        stop()
    }

    /// Unschedules, closes and frees everything. Safe to call twice.
    func stop() {
        slotFlush?.invalidate()
        slotFlush = nil
        pendingSlotTime = nil
        // The panel will never send the tip-switch release once it is gone; without this
        // the next session would start with phantom fingers still down.
        tracker.releaseAll()

        for (index, device) in devices.enumerated() {
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, openOptionsByDevice.indices.contains(index)
                             ? openOptionsByDevice[index]
                             : IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices.removeAll()
        openOptionsByDevice.removeAll()

        if let manager {
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    enum StartError: Error, CustomStringConvertible {
        case managerOpenFailed(IOReturn)
        case deviceNotFound
        case unreadableDescriptor

        var description: String {
            switch self {
            case .managerOpenFailed(let code) where code == kIOReturnNotPermitted:
                return """
                Không mở được thiết bị HID: thiếu quyền Input Monitoring.
                Mở System Settings → Privacy & Security → Input Monitoring và bật cho app này.
                """
            case .managerOpenFailed(let code):
                return "Không mở được IOHIDManager (mã \(String(format: "0x%08x", code)))."
            case .deviceNotFound:
                return "Không thấy thiết bị nào khai báo là Digitizer/Touch Screen. Kiểm tra cáp USB."
            case .unreadableDescriptor:
                return "Thiết bị không khai báo dải toạ độ X/Y — không map cảm ứng bằng cách đoán."
            }
        }
    }
}
