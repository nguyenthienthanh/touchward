import Foundation
import IOKit
import IOKit.hid

// Diagnostic: open the SiS HID Touch Controller and dump raw input reports.
let VID = 1111, PID = 2073

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID]
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
FileHandle.standardError.write("IOHIDManagerOpen -> \(String(format: "0x%08x", openRes))\n".data(using: .utf8)!)
if openRes != kIOReturnSuccess {
    print("OPEN_FAILED \(String(format: "0x%08x", openRes)) (0xe00002c2 = not permitted / needs Input Monitoring)")
    exit(2)
}

guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
    print("NO_DEVICE_MATCHED"); exit(3)
}
print("matched devices: \(set.count)")

var buffers: [UnsafeMutablePointer<UInt8>] = []
for dev in set {
    let maxLen = (IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
    let usagePage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
    let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
    print("device usagePage=\(usagePage) usage=\(usage) maxInputReport=\(maxLen)")
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: maxLen)
    buffers.append(buf)
    IOHIDDeviceRegisterInputReportCallback(dev, buf, maxLen, { _, _, _, type, reportID, report, len in
        var hex = ""
        for i in 0..<min(len, 40) { hex += String(format: "%02x", report[i]) }
        print("REPORT id=\(reportID) type=\(type.rawValue) len=\(len) : \(hex)")
        fflush(stdout)
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
}

print("Listening 12s — TOUCH THE SCREEN NOW")
fflush(stdout)
let deadline = Date().addingTimeInterval(12)
while Date() < deadline {
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.2, true)
}
print("done")
