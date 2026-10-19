import Foundation

struct HeadsetSettings: Codable, Equatable {
    var sidetone = 0
    var micVolume = 5
    var led = 2
    var timeout = 30
    var gains = Array(repeating: 0.0, count: 10)

    var valid: Bool {
        (0...3).contains(sidetone) && (1...7).contains(micVolume) &&
        (0...3).contains(led) && (0...255).contains(timeout) &&
        gains.count == 10 && gains.allSatisfy { $0.isFinite && (-12...12).contains($0) }
    }
    var reports: [[UInt8]] {
        guard valid else { return [] }
        return [ArctisProtocol.report(0x39, [UInt8(sidetone)]),
                ArctisProtocol.report(0x37, [UInt8(micVolume)]),
                ArctisProtocol.report(0xae, [UInt8(led)]),
                ArctisProtocol.report(0xa3, [UInt8(timeout)]), ArctisProtocol.eq(gains)]
    }
}

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: HeadsetSettings
    var applicationBundleID = ""
}

final class Profiles: ObservableObject {
    @Published var items: [Profile] = []
    @Published var draft = HeadsetSettings()
    @Published var error: String?
    @Published var restoreOnConnect = false { didSet { defaults.set(restoreOnConnect, forKey: "restoreOnConnect") } }
    @Published var automaticProfiles = false { didSet { defaults.set(automaticProfiles, forKey: "automaticProfiles") } }
    private(set) var lastApplied: HeadsetSettings?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "profiles") {
            do {
                let decoded = try JSONDecoder().decode([Profile].self, from: data)
                guard decoded.allSatisfy({ $0.settings.valid }) else { throw ProfileError.invalid }
                items = decoded
            } catch { self.error = "Saved profiles could not be loaded: \(error.localizedDescription)" }
        }
        if let data = defaults.data(forKey: "lastApplied"),
           let value = try? JSONDecoder().decode(HeadsetSettings.self, from: data), value.valid {
            lastApplied = value; draft = value
        } else {
            for (key, range) in [("sidetone", 0...3), ("micVolume", 1...7), ("led", 0...3), ("timeout", 0...255)] {
                guard defaults.object(forKey: key) != nil else { continue }
                let v = defaults.integer(forKey: key)
                guard range.contains(v) else { continue }
                switch key { case "sidetone": draft.sidetone = v; case "micVolume": draft.micVolume = v
                case "led": draft.led = v; default: draft.timeout = v }
            }
            if let gains = defaults.array(forKey: "eqGains") as? [Double], gains.count == 10,
               gains.allSatisfy({ $0.isFinite && (-12...12).contains($0) }) { draft.gains = gains }
        }
        restoreOnConnect = defaults.bool(forKey: "restoreOnConnect")
        automaticProfiles = defaults.bool(forKey: "automaticProfiles")
    }
    func markApplied(_ value: HeadsetSettings) {
        guard value.valid else { return }
        lastApplied = value
        defaults.set(try? JSONEncoder().encode(value), forKey: "lastApplied")
    }
    func save(name: String, application: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, draft.valid else { error = "Enter a name and valid settings."; return }
        let profile = Profile(name: name, settings: draft, applicationBundleID: application.trimmingCharacters(in: .whitespacesAndNewlines))
        items.append(profile); persist()
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; persist() }
    func importProfile(_ data: Data) throws {
        guard data.count < 1_000_000 else { throw ProfileError.invalid }
        var profile = try JSONDecoder().decode(Profile.self, from: data)
        guard profile.settings.valid, !profile.name.isEmpty, profile.name.count <= 100 else { throw ProfileError.invalid }
        profile.id = UUID()
        items.append(profile); persist()
    }
    func exportProfile(_ profile: Profile) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(items), forKey: "profiles") }
    enum ProfileError: LocalizedError {
        case invalid
        var errorDescription: String? { "The profile contains invalid or unsupported settings." }
    }
}
