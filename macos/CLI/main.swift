import Foundation
let arguments = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
func printJSON(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { fail("Cannot encode result") }
    print(text)
}
guard let command = arguments.first else {
    print("Usage: arctis-cli status | profiles | apply-profile NAME | save | pair | stop-pairing")
    exit(0)
}
let appDomain = "org.linux-arctis-manager.macos"
// Bundled executables inherit the app's preferences domain. A separate suite
// is needed only when the CLI is run outside the app bundle.
let defaults: UserDefaults
if Bundle.main.bundleIdentifier == appDomain {
    defaults = .standard
} else {
    guard let sharedDefaults = UserDefaults(suiteName: appDomain) else { fail("Cannot open app preferences") }
    defaults = sharedDefaults
}
let profiles = Profiles(defaults: defaults)
if command == "profiles" {
    printJSON(profiles.items.map { ["id": $0.id.uuidString, "name": $0.name, "application": $0.applicationBundleID] }); exit(0)
}
guard ["status", "apply-profile", "save", "pair", "stop-pairing"].contains(command) else { fail("Unknown command: \(command)") }
let headset = Headset()
RunLoop.current.run(until: Date().addingTimeInterval(2))
defer { headset.disconnect() }
switch command {
case "status":
    printJSON(["connected": headset.connected, "status": headset.status, "battery": headset.battery as Any? ?? NSNull(), "charging": headset.charging,
               "media": headset.gameMix as Any? ?? NSNull(), "chat": headset.chatMix as Any? ?? NSNull()])
case "apply-profile":
    guard arguments.count == 2, let profile = profiles.items.first(where: { $0.id.uuidString == arguments[1] || $0.name == arguments[1] }) else { fail("Specify a saved profile name or UUID") }
    guard headset.connected else { fail(headset.status) }
    for report in profile.settings.reports { guard headset.send(report) else { fail(headset.message) } }
    profiles.markApplied(profile.settings); print("Profile applied")
case "save":
    guard headset.connected, headset.send(ArctisProtocol.report(0x09)) else { fail(headset.message) }; print("Save command sent")
case "pair", "stop-pairing":
    guard headset.send(ArctisProtocol.report(0x03, [command == "pair" ? 1 : 0])) else { fail(headset.message) }; print("Pairing command sent")
default: break
}
