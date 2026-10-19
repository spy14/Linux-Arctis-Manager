import SwiftUI
import UniformTypeIdentifiers

struct ChatMixView: View {
    @ObservedObject var mix: ChatMix
    @State private var eqChannel = 0
    @State private var presetName = ""
    @State private var presetID: UUID?
    var body: some View {
        Form {
            Section("Audio routing") {
                Picker("Output", selection: $mix.outputUID) {
                    Text("Choose output").tag("")
                    ForEach(mix.devices) { Text($0.name).tag($0.uid) }
                }.disabled(mix.enabled)
                HStack {
                    Button(mix.enabled ? "Stop routing" : "Enable ChatMix") { if mix.enabled { mix.stop() } else { mix.start() } }
                    Button("Refresh apps and devices") { mix.refresh() }
                }
                Text(mix.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Balance") {
                Toggle("Follow the headset’s ChatMix dial", isOn: $mix.followDial).onChange(of: mix.followDial) { _ in mix.updateVolumes() }
                HStack {
                    Text("Media"); Slider(value: $mix.manualBalance, in: -1...1); Text("Chat")
                }.disabled(mix.followDial).onChange(of: mix.manualBalance) { _ in mix.updateVolumes() }
                Button("Center balance") { mix.manualBalance = 0; mix.updateVolumes() }.disabled(mix.followDial)
            }
            Section("Chat apps") {
                Text("Select calling apps for the chat channel. Other apps use media. Play audio in an app if it is missing here.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(Set(mix.processes.filter { !$0.bundle.isEmpty }.map(\.bundle))).sorted(), id: \.self) { bundle in
                    Toggle(mix.processes.first(where: { $0.bundle == bundle })?.name ?? bundle, isOn: Binding(
                        get: { mix.chatApps.contains(bundle) },
                        set: { enabled in
                            if enabled { mix.chatApps.insert(bundle) } else { mix.chatApps.remove(bundle) }
                            UserDefaults.standard.set(Array(mix.chatApps), forKey: "chatApps")
                            if mix.enabled { mix.start() }
                        }))
                }
            }
            Section("Software equalizer") {
                Picker("Channel", selection: $eqChannel) { Text("Media").tag(0); Text("Chat").tag(1) }.pickerStyle(.segmented)
                Picker("Bands", selection: Binding(get: { eqChannel == 0 ? mix.mediaEQ.count : mix.chatEQ.count }, set: { count in
                    if eqChannel == 0 { mix.mediaEQ = EqualizerBands.resample(mix.mediaEQ, to: count) }
                    else { mix.chatEQ = EqualizerBands.resample(mix.chatEQ, to: count) }
                })) { Text("10 bands").tag(10); Text("15 bands").tag(15) }
                Picker("Preset", selection: $presetID) {
                    Text("Custom").tag(nil as UUID?); ForEach(mix.presets) { Text($0.name).tag(Optional($0.id)) }
                }.onChange(of: presetID) { id in
                    if let preset = mix.presets.first(where: { $0.id == id }) { mix.mediaEQ = preset.media; mix.chatEQ = preset.chat }
                }
                HStack {
                    TextField("New preset name", text: $presetName)
                    Button("Save preset") { mix.savePreset(presetName) }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Delete preset") { if let id = presetID { mix.removePreset(id); presetID = nil } }.disabled(presetID == nil)
                }
                EQControls(gains: eqChannel == 0 ? $mix.mediaEQ : $mix.chatEQ)
                HStack {
                    Button("Flat") { if eqChannel == 0 { mix.mediaEQ = Array(repeating: 0, count: mix.mediaEQ.count) } else { mix.chatEQ = Array(repeating: 0, count: mix.chatEQ.count) } }
                    Button("Apply software EQ") { mix.applyEQ() }
                }
                Text("Applied only while ChatMix routing is enabled. Hardware EQ still affects both channels.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
struct EQControls: View {
    @Binding var gains: [Double]
    private var bands: [String] { EqualizerBands.frequencies(count: gains.count).map { $0 >= 1000 ? String(format: "%g kHz", $0 / 1000) : String(format: "%g Hz", $0) } }
    var body: some View {
        ForEach(0..<gains.count, id: \.self) { index in
            HStack {
                Text(bands[index]).frame(width: 58, alignment: .trailing)
                Slider(value: $gains[index], in: -12...12, step: 0.5).accessibilityLabel(bands[index])
                Text(String(format: "%+.1f dB", gains[index])).monospacedDigit().frame(width: 66)
            }
        }
    }
}
struct MicrophoneView: View {
    @ObservedObject var mic: Microphone
    @ObservedObject var models: VoiceModels
    var body: some View {
        Form {
            Section("Processed microphone") {
                Picker("Microphone", selection: $mic.inputUID) {
                    Text("Choose microphone").tag(""); ForEach(mic.inputs) { Text($0.name).tag($0.uid) }
                }.disabled(mic.running || mic.starting)
                Picker("Virtual output", selection: $mic.outputUID) {
                    Text("Choose BlackHole output").tag(""); ForEach(mic.outputs) { Text($0.name).tag($0.uid) }
                }.disabled(mic.running || mic.starting)
                HStack {
                    Button((mic.running || mic.starting) ? "Stop microphone processing" : "Start microphone processing") {
                        if mic.running || mic.starting { mic.stop() }
                        else {
                            if mic.aiEnabled {
                                do { mic.aiConfigPath = try models.configuration().path } catch { mic.message = error.localizedDescription; return }
                            }
                            mic.start()
                        }
                    }
                    Button("Refresh devices") { mic.refresh() }
                    Link("Install BlackHole", destination: URL(string: "https://github.com/ExistentialAudio/BlackHole#installation-instructions")!)
                }
                Text(mic.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                Section("Noise and dynamics") {
                    Toggle("Noise suppression (Apple voice processing)", isOn: $mic.noiseSuppression)
                    Toggle("Remove low-frequency rumble", isOn: $mic.highPass)
                    Toggle("Noise gate", isOn: $mic.gate)
                    valueSlider("Gate threshold", value: $mic.gateThreshold, range: -80 ... -10, suffix: "dB").disabled(!mic.gate)
                    Toggle("Compressor", isOn: $mic.compressor)
                    valueSlider("Compressor threshold", value: $mic.compressorThreshold, range: -40 ... 0, suffix: "dB").disabled(!mic.compressor)
                    valueSlider("Makeup gain", value: $mic.makeupGain, range: 0 ... 12, suffix: "dB")
                }
                Section("Voice effects") {
                    valueSlider("Pitch", value: $mic.pitch, range: -24 ... 24, suffix: "st")
                    valueSlider("Reverb", value: $mic.reverb, range: 0 ... 100, suffix: "%")
                    valueSlider("Delay", value: $mic.delay, range: 0 ... 100, suffix: "%")
                    valueSlider("Distortion", value: $mic.distortion, range: 0 ... 100, suffix: "%")
                    valueSlider("Chorus blend", value: $mic.chorusMix, range: 0 ... 100, suffix: "%")
                    Picker("Chorus voices", selection: $mic.chorusVoices) { ForEach(1...8, id: \.self) { Text("\($0)").tag($0) } }
                    valueSlider("Chorus delay", value: $mic.chorusDelay, range: 10 ... 40, suffix: "ms")
                    valueSlider("Chorus detune", value: $mic.chorusDetune, range: 0 ... 50, suffix: "cents")
                    valueSlider("Chorus rate", value: $mic.chorusRate, range: 0.1 ... 10, suffix: "Hz")
                    Toggle("Use AI voice conversion", isOn: $mic.aiEnabled)
                    Text("Choose and configure a voice in AI Models first. Stop processing before changing the chain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(mic.running || mic.starting)
        }.formStyle(.grouped)
    }
}
func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
    HStack {
        Text(title).frame(width: 150, alignment: .leading)
        Slider(value: value, in: range).accessibilityLabel(title)
        Text(String(format: "%.2f %@", value.wrappedValue, suffix)).monospacedDigit().frame(width: 85, alignment: .trailing)
    }
}
struct VoiceModelsView: View {
    @ObservedObject var models: VoiceModels
    @State private var installConfirmation = false
    @State private var exportConfirmation = false
    @State private var downloadFile: String?
    var body: some View {
        Form {
            Section("Setup") {
                TextField("Python 3 executable", text: $models.python)
                HStack {
                    Button("Install AI dependencies…") { installConfirmation = true }
                    Button("Download verified base models") { Task { await models.downloadBases() } }
                }
                TextField("ONNX Runtime library", text: $models.runtime)
                Button("Choose runtime library…") {
                    let p = NSOpenPanel(); p.allowsMultipleSelection = false
                    if p.runModal() == .OK, let url = p.url { models.runtime = url.path }
                }
            }.disabled(models.busy)
            Section("Voice library") {
                Picker("Model", selection: $models.selected) {
                    Text("Choose a voice").tag(""); ForEach(models.models) { Text($0.url.lastPathComponent).tag($0.id) }
                }
                HStack {
                    Button("Import model or index…") {
                        let p = NSOpenPanel(); p.allowsMultipleSelection = true
                        if p.runModal() == .OK { p.urls.forEach { models.importModel($0) } }
                    }
                    Button("Export PTH to ONNX…") { exportConfirmation = true }.disabled(!models.selected.hasSuffix(".pth"))
                    Button("Move to Trash") { models.deleteSelected() }.disabled(models.selected.isEmpty)
                }
            }.disabled(models.busy)
            Section("Conversion") {
                Toggle("Try Core ML acceleration (falls back to CPU)", isOn: $models.coreML)
                valueSlider("Pitch", value: $models.pitch, range: -24 ... 24, suffix: "st")
                valueSlider("Formant", value: $models.formant, range: 0.7 ... 1.4, suffix: "×")
                valueSlider("RMS blend", value: $models.rmsMix, range: 0 ... 1, suffix: "")
                valueSlider("Index blend", value: $models.indexRate, range: 0 ... 1, suffix: "")
                valueSlider("Input drive", value: $models.targetRMS, range: 0.01 ... 0.2, suffix: "")
                valueSlider("Limiter", value: $models.limiter, range: 0.3 ... 1, suffix: "")
                Picker("Pitch smoothing", selection: $models.filterRadius) { ForEach([1, 3, 5, 7, 9], id: \.self) { Text("\($0) frames").tag($0) } }
                Button("Render a test WAV…") { render() }.disabled(models.busy)
            }
            Section("Voice calibration") {
                HStack {
                    Button(models.recording ? "Stop recording" : "Record 10-second sample") {
                        if models.recording { models.stopRecording() } else { models.recordSample() }
                    }.disabled(models.busy)
                    Button("Render sample") { Task { await models.render(input: models.calibrationInput, output: models.calibrationOutput) } }.disabled(models.busy || models.recording)
                }
                HStack {
                    Button("Play original") { models.play(models.calibrationInput) }
                    Button("Play converted") { models.play(models.calibrationOutput) }
                }.disabled(models.recording)
                Text("Records the system default microphone. Begin with one second of silence, then speak normally.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Find models on Hugging Face") {
                SecureField("Hugging Face token (optional)", text: $models.tokenDraft)
                HStack {
                    Button("Save token in Keychain") { models.saveToken() }.disabled(models.tokenDraft.isEmpty)
                    Button("Remove saved token") { models.tokenDraft = ""; models.saveToken() }
                }
                HStack { TextField("Search", text: $models.query); Button("Search") { Task { await models.search() } } }
                Picker("Repository", selection: $models.repository) {
                    Text("Choose repository").tag(""); ForEach(models.searchResults, id: \.self) { Text($0).tag($0) }
                }
                TextField("Repository ID (owner/name)", text: $models.repository)
                Button("List model files") { Task { await models.listFiles() } }
                ForEach(models.repositoryFiles, id: \.self) { file in
                    Button("Download \(file)") { downloadFile = file }
                }
                Text("For private models, enter the repository ID below and save a token with read access.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(models.busy)
            Section {
                if models.busy { ProgressView().controlSize(.small) }
                Text(models.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Open models and logs folder") { NSWorkspace.shared.open(models.directory) }
            }
        }.formStyle(.grouped)
        .confirmationDialog("Install AI dependencies?", isPresented: $installConfirmation) {
            Button("Install") { Task { await models.installRuntime() } }
        } message: { Text("Creates a private Python environment and downloads torch, numpy, onnx, onnxruntime, and onnxscript from PyPI. This can use several gigabytes.") }
        .confirmationDialog("Export this PTH model?", isPresented: $exportConfirmation) {
            Button("Export trusted model") { Task { await models.exportSelected() } }
        } message: { Text("Only export model checkpoints from a source you trust. The exporter loads the checkpoint and validates the converted ONNX output.") }
        .confirmationDialog("Download this model?", isPresented: Binding(get: { downloadFile != nil }, set: { if !$0 { downloadFile = nil } })) {
            if let file = downloadFile { Button("Download") { downloadFile = nil; Task { await models.downloadModel(file) } } }
        } message: { Text("Review the model’s license and source in its Hugging Face repository before using it.") }
    }
    private func render() {
        let input = NSOpenPanel(); input.allowedContentTypes = [.wav]
        guard input.runModal() == .OK, let source = input.url else { return }
        let output = NSSavePanel(); output.allowedContentTypes = [.wav]; output.nameFieldStringValue = "Converted voice.wav"
        guard output.runModal() == .OK, let destination = output.url, destination != source else { return }
        Task { await models.render(input: source, output: destination) }
    }
}
