import CoreAudio
import AppKit

struct AudioDevice: Identifiable, Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var input: Bool
    var output: Bool
}
struct AudioProcess: Identifiable, Hashable {
    var id: AudioObjectID
    var pid: pid_t
    var bundle: String
    var name: String
}
enum AudioFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
func audioCheck(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure.message("\(operation) failed (\(status)). Check audio permissions and connected devices.") }
}
enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope: scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : []
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector); var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }
    static func devices() -> [AudioDevice] {
        ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).map { id in
            AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                        input: !ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty,
                        output: !ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty)
        }.filter { !$0.name.isEmpty && !$0.name.hasPrefix("Arctis Tap") }
    }
    @available(macOS 14.2, *) static func processes() -> [AudioProcess] {
        ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { id in
            var a = address(kAudioProcessPropertyPID); var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &pid) == noErr, pid != getpid() else { return nil }
            let bundle = string(id, kAudioProcessPropertyBundleID)
            let app = NSRunningApplication(processIdentifier: pid)
            return AudioProcess(id: id, pid: pid, bundle: bundle, name: app?.localizedName ?? (bundle.isEmpty ? "Process \(pid)" : bundle))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    @available(macOS 14.2, *) static func ownProcess() -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid(); var result: AudioObjectID = 0; var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &result)
        return status == noErr && result != 0 ? result : nil
    }
}
