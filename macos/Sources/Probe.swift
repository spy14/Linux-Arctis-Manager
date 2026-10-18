import Foundation
import IOKit.hid
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1038, kIOHIDProductIDKey: 0x220e] as CFDictionary)
let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("Manager open: \(result)")
let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
for device in devices {
    for key in [kIOHIDProductKey, kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey, kIOHIDMaxInputReportSizeKey, kIOHIDMaxOutputReportSizeKey] {
        print("\(key): \(String(describing: IOHIDDeviceGetProperty(device, key as CFString)))")
    }
}
print("Interfaces: \(devices.count)")
let buffers = devices.map { device -> UnsafeMutablePointer<UInt8> in
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { _, result, _, _, reportID, report, length in
        print("INPUT result=\(result) id=\(reportID) " + UnsafeBufferPointer(start: report, count: length).map { String(format: "%02x", $0) }.joined(separator: " "))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    return buffer
}
for device in devices where (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) == 0xffc0 {
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 0xb0
    print("Status query: \(IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &report, report.count))")
}
RunLoop.current.run(until: Date().addingTimeInterval(3))
IOHIDManagerClose(manager, 0)
