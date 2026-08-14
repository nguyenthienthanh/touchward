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
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var onReport: ((UInt8, [UInt8], TimeInterval) -> Void)?

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

        let capacity = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        buffers.append(buffer)

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

    /// Best-effort: try the standard multitouch value, then the alternate. A device that
    /// is already in digitizer mode ignores this harmlessly.
    private func switchToMultitouch(_ device: IOHIDDevice) {
        for value in [InputMode.multitouch, InputMode.alternate] {
            var payload: [UInt8] = [value, 0x00]  // InputMode, DeviceIndex
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                              CFIndex(InputMode.reportID), &payload, payload.count)
            if result == kIOReturnSuccess { return }
        }
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
