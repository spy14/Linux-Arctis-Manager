import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ArctisApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Arctis Settings", id: "settings") {
            TabView {
                SettingsView(model: model, headset: model.headset, profiles: model.profiles).tabItem { Label("Headset", systemImage: "headphones") }
                ChatMixView(mix: model.mix).tabItem { Label("ChatMix", systemImage: "slider.horizontal.3") }
                MicrophoneView(mic: model.microphone, models: model.voiceModels).tabItem { Label("Microphone", systemImage: "mic") }
                VoiceModelsView(models: model.voiceModels).tabItem { Label("AI Models", systemImage: "waveform") }
            }.frame(minWidth: 720, idealWidth: 800, minHeight: 740)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("Arctis", systemImage: "headphones") {
            HeadsetMenu(model: model, headset: model.headset, profiles: model.profiles)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var headset: Headset
    @ObservedObject var profiles: Profiles
    @State private var profileName = ""
    @State private var profileApplication = ""
    @State private var selectedProfile: UUID?
    @State private var pairingConfirmation = false
    private let bands = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "headphones").font(.system(size: 32)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arctis 7+").font(.title.bold())
                    Text(headset.status).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(headset.battery.map { "\($0)%" } ?? "—").font(.title2.monospacedDigit())
                    Text(headset.charging).font(.caption).foregroundStyle(.secondary)
                }
                Button { headset.connect() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reconnect and refresh status").accessibilityLabel("Reconnect")
            }
            Text("Values below are your local choices, not a readout of the headset. Apply each section when ready.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Section("Profiles") {
                    Picker("Saved profile", selection: $selectedProfile) {
                        Text("Choose a profile").tag(nil as UUID?)
                        ForEach(profiles.items) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: selectedProfile) { id in
                        if let profile = profiles.items.first(where: { $0.id == id }) { profiles.draft = profile.settings }
                    }
                    HStack {
                        Button("Apply all settings") { model.apply(profiles.draft) }.disabled(!headset.connected)
                        Button("Import…") { importProfile() }
                        Button("Export…") { exportProfile() }.disabled(selectedProfile == nil)
                        Button("Delete") {
                            if let id = selectedProfile { profiles.remove(id); selectedProfile = nil }
                        }.disabled(selectedProfile == nil)
                    }
                    TextField("New profile name", text: $profileName)
                    HStack {
                        Text(profileApplication.isEmpty ? "No linked application" : (NSWorkspace.shared.urlForApplication(withBundleIdentifier: profileApplication)?.deletingPathExtension().lastPathComponent ?? profileApplication))
                        Spacer()
                        Button("Link application…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                            if panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier { profileApplication = identifier }
                        }
                        Button("Clear") { profileApplication = "" }.disabled(profileApplication.isEmpty)
                    }
                    Button("Save as new profile") { profiles.save(name: profileName, application: profileApplication) }
                        .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Toggle("Restore last fully applied settings on reconnect", isOn: $profiles.restoreOnConnect)
                    Toggle("Apply linked profile when its app becomes active", isOn: $profiles.automaticProfiles)
                }
                Section("ChatMix dial") {
                    LabeledContent("Media", value: headset.gameMix.map { "\($0)%" } ?? "Unknown")
                    LabeledContent("Chat", value: headset.chatMix.map { "\($0)%" } ?? "Unknown")
                }
                Section("Microphone") {
                    Picker("Sidetone", selection: $profiles.draft.sidetone) {
                        Text("Off").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
                    }
                    Picker("Microphone volume", selection: $profiles.draft.micVolume) {
                        ForEach(1...7, id: \.self) { Text("\($0) of 7").tag($0) }
                    }
                    Picker("Mute LED brightness", selection: $profiles.draft.led) {
                        Text("Off").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
                    }
                    Button("Apply microphone settings") {
                        guard headset.send(ArctisProtocol.report(0x39, [UInt8(profiles.draft.sidetone)])) else { return }
                        guard headset.send(ArctisProtocol.report(0x37, [UInt8(profiles.draft.micVolume)])) else { return }
                        headset.send(ArctisProtocol.report(0xae, [UInt8(profiles.draft.led)]))
                    }.disabled(!headset.connected)
                }
                Section("Hardware equalizer") {
                    VStack(spacing: 5) {
                        ForEach(0..<10, id: \.self) { i in
                            HStack {
                                Text("\(bands[i]) Hz").frame(width: 52, alignment: .trailing)
                                Slider(value: $profiles.draft.gains[i], in: -12...12, step: 0.5)
                                    .accessibilityLabel("\(bands[i]) Hz gain")
                                Text(String(format: "%+.1f dB", profiles.draft.gains[i])).monospacedDigit().frame(width: 66, alignment: .trailing)
                            }
                        }
                        HStack {
                            Button("Flat") { profiles.draft.gains = Array(repeating: 0, count: 10) }
                            Spacer()
                            Button("Apply EQ") {
                                if headset.send(ArctisProtocol.eq(profiles.draft.gains)) { UserDefaults.standard.set(profiles.draft.gains, forKey: "eqGains") }
                            }.disabled(!headset.connected)
                        }.padding(.top, 6)
                    }
                }
                Section("Power") {
                    Picker("Turn off after inactivity", selection: $profiles.draft.timeout) {
                        Text("Never").tag(0)
                        ForEach([1, 5, 10, 15, 30, 45, 60, 75, 90], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Button("Apply power setting") { headset.send(ArctisProtocol.report(0xa3, [UInt8(profiles.draft.timeout)])) }
                        .disabled(!headset.connected)
                }
                Section("App and connection") {
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    Button("Pair a headset…") { pairingConfirmation = true }
                    Button("Stop pairing") { headset.send(ArctisProtocol.report(0x03, [0])) }
                }
            }.formStyle(.grouped)
            HStack(alignment: .center, spacing: 20) {
                Text(headset.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
                Spacer()
                Button("Save to headset") {
                    if headset.send(ArctisProtocol.report(0x09)) {
                        headset.message = "Save command sent for settings already applied."
                    }
                }.disabled(!headset.connected).help("Store settings already applied in the headset's flash memory")
            }
        }.padding(24)
        .confirmationDialog("Start pairing?", isPresented: $pairingConfirmation) {
            Button("Start pairing") { headset.send(ArctisProtocol.report(0x03, [1])) }
        } message: { Text("This puts the USB dongle into pairing mode. Put your headset into its pairing mode to connect it.") }
        .alert("Arctis Settings", isPresented: Binding(get: { model.error != nil || profiles.error != nil }, set: { if !$0 { model.error = nil; profiles.error = nil } })) {
            Button("OK") { model.error = nil; profiles.error = nil }
        } message: { Text(model.error ?? profiles.error ?? "") }
    }
    private func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try profiles.importProfile(Data(contentsOf: url)) } catch { model.error = error.localizedDescription }
        }
    }
    private func exportProfile() {
        guard let profile = profiles.items.first(where: { $0.id == selectedProfile }) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Arctis Profile.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try profiles.exportProfile(profile).write(to: url, options: .atomic) } catch { model.error = error.localizedDescription }
        }
    }
}

struct HeadsetMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @ObservedObject var headset: Headset
    @ObservedObject var profiles: Profiles
    var body: some View {
        Text(headset.status)
        if let battery = headset.battery { Text("Battery: \(battery)% · \(headset.charging)") }
        Divider()
        ForEach(profiles.items) { profile in
            Button(profile.name) { model.apply(profile.settings) }.disabled(!headset.connected)
        }
        Divider()
        Button("Open settings") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Reconnect") { headset.connect() }
        Button("Quit Arctis Settings") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
