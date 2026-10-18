import SwiftUI
import AppKit

@main
struct ArctisApp: App {
    @StateObject private var headset = Headset()
    var body: some Scene {
        WindowGroup("Arctis Settings") {
            SettingsView(headset: headset)
                .frame(minWidth: 600, idealWidth: 660, minHeight: 700)
        }
        .windowResizability(.contentSize)
    }
}

struct SettingsView: View {
    @ObservedObject var headset: Headset
    @AppStorage("sidetone") private var sidetone = 0
    @AppStorage("micVolume") private var micVolume = 5
    @AppStorage("led") private var led = 2
    @AppStorage("timeout") private var timeout = 30
    @State private var gains = Array(repeating: 0.0, count: 10)
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
                Section("Microphone") {
                    Picker("Sidetone", selection: $sidetone) {
                        Text("Off").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
                    }
                    Picker("Microphone volume", selection: $micVolume) {
                        ForEach(1...7, id: \.self) { Text("\($0) of 7").tag($0) }
                    }
                    Picker("Mute LED brightness", selection: $led) {
                        Text("Off").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
                    }
                    Button("Apply microphone settings") {
                        guard headset.send(ArctisProtocol.report(0x39, [UInt8(sidetone)])) else { return }
                        guard headset.send(ArctisProtocol.report(0x37, [UInt8(micVolume)])) else { return }
                        headset.send(ArctisProtocol.report(0xae, [UInt8(led)]))
                    }.disabled(!headset.connected)
                }
                Section("Hardware equalizer") {
                    VStack(spacing: 5) {
                        ForEach(0..<10, id: \.self) { i in
                            HStack {
                                Text("\(bands[i]) Hz").frame(width: 52, alignment: .trailing)
                                Slider(value: $gains[i], in: -12...12, step: 0.5)
                                    .accessibilityLabel("\(bands[i]) Hz gain")
                                Text(String(format: "%+.1f dB", gains[i])).monospacedDigit().frame(width: 66, alignment: .trailing)
                            }
                        }
                        HStack {
                            Button("Flat") { gains = Array(repeating: 0, count: 10) }
                            Spacer()
                            Button("Apply EQ") {
                                if headset.send(ArctisProtocol.eq(gains)) { UserDefaults.standard.set(gains, forKey: "eqGains") }
                            }.disabled(!headset.connected)
                        }.padding(.top, 6)
                    }
                }
                Section("Power") {
                    Picker("Turn off after inactivity", selection: $timeout) {
                        Text("Never").tag(0)
                        ForEach([1, 5, 10, 15, 30, 45, 60, 75, 90], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Button("Apply power setting") { headset.send(ArctisProtocol.report(0xa3, [UInt8(timeout)])) }
                        .disabled(!headset.connected)
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
        .onAppear {
            if let saved = UserDefaults.standard.array(forKey: "eqGains") as? [Double], saved.count == 10,
               saved.allSatisfy({ $0.isFinite && (-12...12).contains($0) }) { gains = saved }
        }
    }
}
