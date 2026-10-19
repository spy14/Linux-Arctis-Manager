import Foundation
let flat = ArctisProtocol.eq(Array(repeating: 0, count: 10))
assert(flat.count == 64 && flat[0] == 0x33)
assert(Array(flat[1...10]) == Array(repeating: 24, count: 10))
let limits = ArctisProtocol.eq([-12, 12, -0.5, 0.5, 0, 0, 0, 0, 0, 0])
assert(Array(limits[1...4]) == [0, 48, 23, 25])
assert(ArctisProtocol.report(0x39, [3])[0...2] == [0x39, 3, 0])
let headset = Headset(startMonitoring: false)
headset.receive([0xb7, 2]); assert(headset.battery == 50)
headset.receive([0xbb, 3]); assert(headset.charging == "On battery")
headset.receive([0xb9, 3]); assert(headset.connected)
headset.receive([0xb7, 255]); assert(headset.battery == nil)
headset.receive([0xb9, 2]); assert(!headset.connected && headset.battery == nil)
headset.receive([0xb0, 2, 4, 3, 100, 100])
assert(!headset.connected && headset.battery == nil && headset.charging.isEmpty)
headset.receive([0xb0, 3, 2, 3, 100, 75])
assert(headset.connected && headset.gameMix == 100 && headset.chatMix == 75)
headset.receive([0x45, 25, 100])
assert(headset.gameMix == 25 && headset.chatMix == 100)
headset.receive([0xb0, 3, 2, 3, 255, 255])
assert(headset.gameMix == 25 && headset.chatMix == 100)
headset.receive([0x45, 50]) // Truncated input cannot change the dial state.
assert(headset.gameMix == 25 && headset.chatMix == 100)
headset.receive([0xb9, 2])
assert(headset.gameMix == nil && headset.chatMix == nil)
print("Protocol and status tests passed")
if CommandLine.arguments.contains("--hardware") {
    headset.connect()
    RunLoop.current.run(until: Date().addingTimeInterval(4))
    print("Hardware: \(headset.status), battery: \(String(describing: headset.battery)), \(headset.charging)")
    assert(headset.connected, "Expected connected headset")
}
headset.disconnect()
let suite = "arctis-tests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let profiles = Profiles(defaults: defaults)
profiles.draft.sidetone = 3
profiles.save(name: "Test", application: "com.example.chat")
assert(profiles.items.count == 1)
let exported = try profiles.exportProfile(profiles.items[0])
try profiles.importProfile(exported)
assert(profiles.items.count == 2 && profiles.items[0].id != profiles.items[1].id)
var invalid = profiles.items[0]; invalid.settings.gains = [0]
do { try profiles.importProfile(JSONEncoder().encode(invalid)); assertionFailure("Accepted malformed EQ") } catch {}
profiles.markApplied(profiles.draft)
let restored = Profiles(defaults: defaults)
assert(restored.lastApplied?.sidetone == 3 && restored.items.count == 2)
assert(!restored.restoreOnConnect && !restored.automaticProfiles)
var bad = HeadsetSettings(); bad.micVolume = 256
assert(!bad.valid && bad.reports.isEmpty)
print("Profile validation and persistence tests passed")
let flat15 = EqualizerBands.resample(Array(repeating: 3.0, count: 10), to: 15)
assert(flat15 == Array(repeating: 3.0, count: 15))
let ramp = EqualizerBands.resample([-12,-10,-8,-6,-4,-2,0,2,4,6], to: 15)
assert(ramp.count == 15 && zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 })
assert(!SoftwareEQPreset(name: "Invalid", media: [0], chat: Array(repeating: 0, count: 10)).valid)
print("Software EQ resampling tests passed")
