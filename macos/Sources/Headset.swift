import Foundation
import IOKit.hid

// Reports on macOS omit the synthetic zero report-ID byte used by Linux.
enum ArctisProtocol {
    static func report(_ command: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count < 64)
        return [command] + payload + Array(repeating: 0, count: 63 - payload.count)
    }
    static func eq(_ gains: [Double]) -> [UInt8] {
        precondition(gains.count == 10 && gains.allSatisfy { $0.isFinite && (-12...12).contains($0) })
        return report(0x33, gains.map { UInt8((2 * (12 + $0)).rounded()) })
    }
}

final class Headset: ObservableObject {
    @Published var connected = false
    @Published var status = "Looking for your dongle…"
    @Published var battery: Int?
    @Published var charging = ""
    @Published var message = "Changes are sent only when you click Apply."
    private var manager: IOHIDManager?
    private var command: IOHIDDevice?
    private var devices: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var timer: Timer?
    private var lastReport = Date.distantPast

    init(startMonitoring: Bool = true) {
        guard startMonitoring else { return }
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.command == nil || Date().timeIntervalSince(self.lastReport) > 15 { self.connect() }
            else { self.query() }
        }
    }
    func disconnect() {
        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, 0)
        }
        if let manager { IOHIDManagerClose(manager, 0) }
        devices.removeAll(); command = nil; manager = nil
        buffers.forEach { $0.deallocate() }; buffers.removeAll()
        connected = false; battery = nil; charging = ""
    }
    func connect() {
        disconnect()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatchingMultiple(manager, [0x220e, 0x2236].map {
            [kIOHIDVendorIDKey: 0x1038, kIOHIDProductIDKey: $0]
        } as CFArray)
        // Open only the vendor interfaces; never seize the consumer/audio interface.
        let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        for device in found {
            let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            guard page == 0xffc0 || page == 0xff00 else { continue }
            let result = IOHIDDeviceOpen(device, 0)
            guard result == kIOReturnSuccess else {
                message = "Cannot open dongle (\(result)). Close other headset tools and reconnect."
                continue
            }
            if page == 0xffc0 && command == nil { command = device }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffers.append(buffer); devices.append(device)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, _, bytes, length in
                guard result == kIOReturnSuccess, let context else { return }
                let owner = Unmanaged<Headset>.fromOpaque(context).takeUnretainedValue()
                owner.receive(Array(UnsafeBufferPointer(start: bytes, count: length)))
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        status = command == nil ? "Connect your Arctis 7+ USB dongle" : "Dongle found · waiting for headset"
        lastReport = Date()
        query()
    }
    func query() { if command != nil { _ = send(ArctisProtocol.report(0xb0), announce: false) } }
    func receive(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        lastReport = Date()
        switch bytes[0] {
        case 0xb0 where bytes.count >= 4:
            updateConnection(bytes[1])
            // Initial status may contain placeholders. Live events supersede it.
            if battery == nil { updateBattery(bytes[2]) }
            if charging.isEmpty { updateCharging(bytes[3]) }
        case 0xb7: updateBattery(bytes[1])
        case 0xb9: updateConnection(bytes[1])
        case 0xbb: updateCharging(bytes[1])
        default: break
        }
    }
    private func updateConnection(_ value: UInt8) {
        connected = value == 3
        status = connected ? "Headset connected" : "Dongle connected · turn on your headset"
        if !connected { battery = nil; charging = "" }
    }
    private func updateBattery(_ value: UInt8) { battery = value <= 4 ? Int(value) * 25 : nil }
    private func updateCharging(_ value: UInt8) {
        charging = [1: "Charging", 2: "Plugged in", 3: "On battery"][Int(value)] ?? ""
    }
    @discardableResult func send(_ report: [UInt8], announce: Bool = true) -> Bool {
        guard let command else { message = "Reconnect the USB dongle and try again."; return false }
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(command, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        if result != kIOReturnSuccess {
            message = "USB command failed (\(result)). Reconnect the dongle and try again."
            connected = false
            return false
        }
        if announce { message = "Sent to headset. Settings cannot be read back from this model." }
        return true
    }
}
