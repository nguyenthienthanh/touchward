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

        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { return .failure(.managerOpenFailed(opened)) }

        guard let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = found.first else {
            return .failure(.deviceNotFound)
        }

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<HIDTouchDevice>.fromOpaque(context).takeUnretainedValue().handleRemoval()
        }, Unmanaged.passUnretained(self).toOpaque())

        // The manager needs its own run-loop scheduling: per-device scheduling below only
        // delivers input, never the removal callback.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        guard let profile = attach(device) else { return .failure(.unreadableDescriptor) }
        self.profile = profile
        return .success(profile)
    }

    private func attach(_ device: IOHIDDevice) -> DeviceProfile? {
        var options = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        if IOHIDDeviceOpen(device, options) == kIOReturnSuccess {
            isSeized = true
        } else {
            // A shared open still lets us read; the caller is told that macOS will keep
            // producing its own phantom clicks.
            options = IOOptionBits(kIOHIDOptionsTypeNone)
            guard IOHIDDeviceOpen(device, options) == kIOReturnSuccess else { return nil }
        }

        devices.append(device)
        openOptionsByDevice.append(options)

        guard let profile = readProfile(device) else { return nil }
        switchToMultitouch(device, reportID: profile.inputModeReportID)

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

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))

        if let frame = assembler.accept(usagePage: page, usage: usage,
                                        value: IOHIDValueGetIntegerValue(value), time: Clock.now()) {
            onFrame?(frame)
        }
    }

    /// Windows writes Input Mode to move the controller out of its mouse-compatibility
    /// mode; macOS never does, which is why an untouched panel behaves like a button-only
    /// pointing device. The report ID comes from the descriptor, not a constant.
    private func switchToMultitouch(_ device: IOHIDDevice, reportID: UInt8?) {
        guard let reportID else { return }

        // 2 is "multi-touch" in the Windows digitizer spec; 3 is the precision-device value
        // some controllers use instead. macOS is inconsistent about whether SetReport wants
        // the ID prefixed, so both framings are tried.
        for mode in [UInt8(0x02), UInt8(0x03)] {
            for var payload in [[mode, 0x00], [reportID, mode, 0x00]] {
                if IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                        CFIndex(reportID), &payload, payload.count) == kIOReturnSuccess {
                    inputModeSet = true
                    return
                }
            }
        }
    }

    private func handleRemoval() {
        onDisconnect?()
        stop()
    }

    /// Unschedules, closes and frees everything. Safe to call twice.
    func stop() {
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
