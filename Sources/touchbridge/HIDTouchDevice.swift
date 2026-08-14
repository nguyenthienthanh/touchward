import Foundation
import IOKit
import IOKit.hid
import TouchBridgeCore

/// Owns the physical touchscreen: opens it, takes it away from macOS's default handling,
/// asks it for multitouch reports, and hands raw report bytes upward.
final class HIDTouchDevice {
    struct Identity {
        var vendorID: Int
        var productID: Int

        static let sisTouchController = Identity(vendorID: 0x0457, productID: 0x0819)
    }

    /// Digitizer Device Configuration feature report. Windows writes InputMode to switch
    /// the controller out of its mouse-compatibility mode; macOS never does, which is why
    /// the panel behaves like a button-only pointing device out of the box.
    private enum InputMode {
        static let reportID: UInt8 = 0x07
        static let mouse: UInt8 = 0x00
        static let multitouch: UInt8 = 0x02
        /// Some controllers use the Windows-precision value instead.
        static let alternate: UInt8 = 0x03
    }

    private let identity: Identity
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var buffers: [(pointer: UnsafeMutablePointer<UInt8>, capacity: Int)] = []
    private var onReport: ((UInt8, [UInt8], TimeInterval) -> Void)?
    /// Called when the panel is unplugged, so the caller can release a held button rather
    /// than leave one pressed for the rest of the login session.
    var onDisconnect: (() -> Void)?

    /// False when the device could not be seized. Callers should then expect macOS to
    /// keep producing its own phantom clicks.
    private(set) var isSeized = false

    init(identity: Identity = .sisTouchController) {
        self.identity = identity
    }

    /// Returns a human-readable failure so main can print something actionable rather
    /// than a bare IOReturn code.
    func start(onReport: @escaping (UInt8, [UInt8], TimeInterval) -> Void) -> Result<Void, StartError> {
        self.onReport = onReport

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: identity.vendorID,
            kIOHIDProductIDKey: identity.productID,
        ] as CFDictionary)

        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            return .failure(.managerOpenFailed(opened))
        }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            return .failure(.deviceNotFound)
        }

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<HIDTouchDevice>.fromOpaque(context).takeUnretainedValue().onDisconnect?()
        }, Unmanaged.passUnretained(self).toOpaque())

        for device in devices {
            attach(device)
        }
        return .success(())
    }

    private func attach(_ device: IOHIDDevice) {
        // Seizing stops macOS from turning this device's reports into its own events.
        // Without it we get a phantom click at the cursor on every touch.
        let seized = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if seized == kIOReturnSuccess {
            isSeized = true
        } else {
            // Fall back to a shared open so we can still read; the caller is told.
            _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        switchToMultitouch(device)

        // Never trust the reported size alone: IOKit writes `length` bytes into whatever
        // we hand it, and a missing property would otherwise size the buffer by guess.
        let reported = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 0
        let capacity = max(reported, 128)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        buffers.append((buffer, capacity))
        devices.append(device)

        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, capacity,
            { context, _, _, _, reportID, report, length in
                guard let context, length > 0 else { return }
                let me = Unmanaged<HIDTouchDevice>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                me.onReport?(UInt8(reportID), bytes, Date().timeIntervalSinceReferenceDate)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Best-effort: try the standard multitouch value, then the alternate, and try each
    /// both with and without a leading report-ID byte — macOS is inconsistent about
    /// whether SetReport expects one for numbered reports. A device already in digitizer
    /// mode ignores all of it harmlessly.
    @discardableResult
    private func switchToMultitouch(_ device: IOHIDDevice) -> Bool {
        for value in [InputMode.multitouch, InputMode.alternate] {
            let payloads: [[UInt8]] = [
                [value, 0x00],                      // InputMode, DeviceIndex
                [InputMode.reportID, value, 0x00],  // with the report ID prefixed
            ]
            for var payload in payloads {
                let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                                  CFIndex(InputMode.reportID), &payload, payload.count)
                if result == kIOReturnSuccess {
                    inputModeSet = true
                    return true
                }
            }
        }
        return false
    }

    /// False means the panel may still be in its mouse-compatibility mode, which reports a
    /// single contact and no gestures.
    private(set) var inputModeSet = false

    /// Unschedules, closes and frees everything. Safe to call twice.
    func stop() {
        // Unregister against the same buffer the callback was registered with, then free
        // it — IOKit must not be left holding a pointer we are about to release.
        for (device, entry) in zip(devices, buffers) {
            IOHIDDeviceRegisterInputReportCallback(device, entry.pointer, entry.capacity, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            entry.pointer.deallocate()
        }
        devices.removeAll()
        buffers.removeAll()

        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    enum StartError: Error, CustomStringConvertible {
        case managerOpenFailed(IOReturn)
        case deviceNotFound

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
                return "Không tìm thấy màn cảm ứng. Kiểm tra cáp USB rồi thử lại."
            }
        }
    }
}
