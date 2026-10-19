import AVFoundation
import AudioToolbox
import AppKit

final class Microphone: ObservableObject {
    @Published var inputs: [AudioDevice] = []
    @Published var outputs: [AudioDevice] = []
    @Published var inputUID = ""
    @Published var outputUID = ""
    @Published var running = false
    @Published var starting = false
    private var generation = 0
    @Published var message = "Send processed audio to BlackHole, then select BlackHole as your microphone in the calling app."
    @Published var noiseSuppression = false
    @Published var highPass = false
    @Published var gate = false
    @Published var gateThreshold = -42.0
    @Published var compressor = false
    @Published var compressorThreshold = -18.0
    @Published var makeupGain = 0.0
    @Published var pitch = 0.0
    @Published var reverb = 0.0
    @Published var delay = 0.0
    @Published var distortion = 0.0
    @Published var chorusMix = 0.0
    @Published var chorusVoices = 3
    @Published var chorusDelay = 20.0
    @Published var chorusDetune = 12.0
    @Published var chorusRate = 2.0
    private var chorus: Chorus?
    @Published var aiEnabled = false
    @Published var aiConfigPath = ""
    private var captureEngine: AVAudioEngine?
    private var outputEngine: AVAudioEngine?
    private var ring: OpaquePointer?
    private var captureScratch: UnsafeMutablePointer<Float>?
    private var worker: VoiceWorker?
    private var observers: [NSObjectProtocol] = []
    private var desiredStart = false

    private static let numbers: [(String, ReferenceWritableKeyPath<Microphone, Double>, ClosedRange<Double>)] = [
        ("gateThreshold", \.gateThreshold, -80 ... -10), ("compressorThreshold", \.compressorThreshold, -40 ... 0),
        ("makeupGain", \.makeupGain, 0 ... 12), ("pitch", \.pitch, -24 ... 24), ("reverb", \.reverb, 0 ... 100),
        ("delay", \.delay, 0 ... 100), ("distortion", \.distortion, 0 ... 100), ("chorusMix", \.chorusMix, 0 ... 100),
        ("chorusDelay", \.chorusDelay, 10 ... 40), ("chorusDetune", \.chorusDetune, 0 ... 50), ("chorusRate", \.chorusRate, 0.1 ... 10)
    ]
    private static let flags: [(String, ReferenceWritableKeyPath<Microphone, Bool>)] = [
        ("noiseSuppression", \.noiseSuppression), ("highPass", \.highPass), ("gate", \.gate), ("compressor", \.compressor), ("aiEnabled", \.aiEnabled)
    ]
    init() {
        let saved = UserDefaults.standard.dictionary(forKey: "microphoneSettings") ?? [:]
        for (name, path, range) in Self.numbers { if let v = saved[name] as? Double, v.isFinite, range.contains(v) { self[keyPath: path] = v } }
        for (name, path) in Self.flags { if let v = saved[name] as? Bool { self[keyPath: path] = v } }
        if let count = saved["chorusVoices"] as? Int, (1...8).contains(count) { chorusVoices = count }
        inputUID = saved["inputUID"] as? String ?? ""; outputUID = saved["outputUID"] as? String ?? ""
        refresh()
    }
    private func saveSettings() {
        var saved: [String: Any] = ["inputUID": inputUID, "outputUID": outputUID, "chorusVoices": chorusVoices]
        for (name, path, _) in Self.numbers { saved[name] = self[keyPath: path] }
        for (name, path) in Self.flags { saved[name] = self[keyPath: path] }
        UserDefaults.standard.set(saved, forKey: "microphoneSettings")
    }
    func refresh() {
        let devices = AudioHardware.devices()
        inputs = devices.filter { $0.input }; outputs = devices.filter { $0.output && $0.name.lowercased().contains("blackhole") }
        if inputUID.isEmpty { inputUID = inputs.first(where: { $0.name.contains("Arctis") })?.uid ?? "" }
        if outputUID.isEmpty { outputUID = outputs.first?.uid ?? "" }
    }
    func start() {
        guard !starting else { return }
        stop(); desiredStart = true; starting = true
        let generation = self.generation
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.desiredStart, self.generation == generation else { return }
                guard granted else { self.starting = false; self.message = "Allow microphone access in System Settings → Privacy & Security → Microphone."; return }
                self.startAuthorized()
            }
        }
    }
    private func startAuthorized() {
        defer { starting = false }
        refresh()
        guard let input = inputs.first(where: { $0.uid == inputUID }),
              let output = outputs.first(where: { $0.uid == outputUID }), input.id != output.id else {
            message = "Choose a physical microphone and install/select BlackHole 2ch as the processed output."; return
        }
        do {
            let captureEngine = AVAudioEngine(); self.captureEngine = captureEngine
            let inputNode = captureEngine.inputNode
            if noiseSuppression { try inputNode.setVoiceProcessingEnabled(true) }
            guard let inputUnit = inputNode.audioUnit else { throw AudioFailure.message("Microphone input is unavailable.") }
            var inputID = input.id
            try audioCheck(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputID, UInt32(MemoryLayout<AudioObjectID>.size)), "Select microphone")
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate >= 8000, inputFormat.channelCount > 0 else { throw AudioFailure.message("Microphone has no active audio stream.") }
            let sampleRate = aiEnabled ? 16000.0 : inputFormat.sampleRate
            guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let ring = arctis_ring_create(1, aiEnabled ? 8192 : 32768) else { throw AudioFailure.message("Cannot allocate microphone buffers.") }
            self.ring = ring
            let captureMixer = AVAudioMixerNode(); captureEngine.attach(captureMixer)
            captureEngine.connect(inputNode, to: captureMixer, format: inputFormat)
            captureEngine.connect(captureMixer, to: captureEngine.mainMixerNode, format: mono)
            captureEngine.mainMixerNode.outputVolume = 0
            captureMixer.installTap(onBus: 0, bufferSize: 2048, format: mono) { buffer, _ in
                guard let data = buffer.floatChannelData?[0] else { return }
                arctis_ring_write(ring, data, buffer.frameLength)
            }
            let outputEngine = AVAudioEngine(); self.outputEngine = outputEngine
            guard let outputUnit = outputEngine.outputNode.audioUnit else { throw AudioFailure.message("Processed output is unavailable.") }
            var outputID = output.id
            try audioCheck(AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputID, UInt32(MemoryLayout<AudioObjectID>.size)), "Select processed output")
            let source: AVAudioNode
            let format: AVAudioFormat
            if aiEnabled {
                let player = AVAudioPlayerNode(); outputEngine.attach(player)
                guard let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { throw AudioFailure.message("Unsupported AI output format.") }
                format = f; source = player
                let worker = try VoiceWorker(configPath: aiConfigPath, ring: ring, player: player, format: f) { [weak self] error in
                    DispatchQueue.main.async { self?.stop(); self?.message = error }
                }
                self.worker = worker
            } else {
                format = mono
                let node = AVAudioSourceNode(format: mono) { _, _, frames, data in
                    for buffer in UnsafeMutableAudioBufferListPointer(data) {
                        if let p = buffer.mData?.assumingMemoryBound(to: Float.self) { arctis_ring_read(ring, p, frames) }
                    }
                    return noErr
                }
                outputEngine.attach(node); source = node
            }
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 80; eq.bands[0].bypass = !highPass
            let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            let unit = dynamics.audioUnit
            for (parameter, value): (AudioUnitParameterID, Float) in [
                (kDynamicsProcessorParam_Threshold, compressor ? Float(compressorThreshold) : 0),
                (kDynamicsProcessorParam_HeadRoom, compressor ? 5 : 40),
                (kDynamicsProcessorParam_ExpansionThreshold, gate ? Float(gateThreshold) : -80),
                (kDynamicsProcessorParam_ExpansionRatio, gate ? 4 : 1),
                (kDynamicsProcessorParam_AttackTime, 0.002), (kDynamicsProcessorParam_ReleaseTime, 0.15),
                (kDynamicsProcessorParam_OverallGain, Float(makeupGain))
            ] { try audioCheck(AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0), "Configure microphone dynamics") }
            let pitchNode = AVAudioUnitTimePitch(); pitchNode.pitch = Float(pitch * 100)
            let reverbNode = AVAudioUnitReverb(); reverbNode.loadFactoryPreset(.mediumRoom); reverbNode.wetDryMix = Float(reverb)
            let delayNode = AVAudioUnitDelay(); delayNode.delayTime = 0.2; delayNode.feedback = 15; delayNode.wetDryMix = Float(delay)
            let distortionNode = AVAudioUnitDistortion(); distortionNode.loadFactoryPreset(.speechAlienChatter); distortionNode.wetDryMix = Float(distortion)
            let nodes: [AVAudioNode] = [eq, dynamics, pitchNode, delayNode, reverbNode, distortionNode]
            var previous = source
            for node in nodes { outputEngine.attach(node); outputEngine.connect(previous, to: node, format: format); previous = node }
            if chorusMix > 0 {
                let chorus = Chorus(engine: outputEngine, source: previous, format: format,
                                    wet: Float(chorusMix / 100), count: chorusVoices, delayMS: chorusDelay,
                                    detuneCents: Float(chorusDetune), rate: chorusRate)
                self.chorus = chorus; previous = chorus.output
            }
            outputEngine.connect(previous, to: outputEngine.mainMixerNode, format: format)
            try outputEngine.start()
            if let player = source as? AVAudioPlayerNode { player.play() }
            try captureEngine.start(); worker?.start()
            for engine in [captureEngine, outputEngine] {
                observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                    guard let self, self.running else { return }; self.stop(); self.message = "Audio device configuration changed. Review devices and start again."
                })
            }
            running = true; saveSettings()
            message = "Processing \(input.name) → \(output.name). Select \(output.name) as your microphone in your calling app."
        } catch { stop(); message = error.localizedDescription }
    }
    func stop() {
        desiredStart = false; running = false; starting = false; generation += 1
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        chorus?.stop(); chorus = nil
        captureEngine?.stop(); outputEngine?.stop()
        captureEngine = nil; outputEngine = nil
        // Worker takes ownership of the ring and destroys it after its queue drains.
        if let worker { worker.stop() } else if let ring { arctis_ring_destroy(ring) }
        worker = nil; ring = nil
    }
}

final class VoiceWorker {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let queue = DispatchQueue(label: "org.arctis.voice-worker", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let ring: OpaquePointer
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let onError: (String) -> Void
    private let state = NSLock()
    private var stopping = false
    private var ready = false
    private var firstHop = true
    private var stderrText = ""
    init(configPath: String, ring: OpaquePointer, player: AVAudioPlayerNode, format: AVAudioFormat, onError: @escaping (String) -> Void) throws {
        self.ring = ring; self.player = player; self.format = format; self.onError = onError
        guard !configPath.isEmpty, FileManager.default.fileExists(atPath: configPath),
              let executable = Bundle.main.url(forAuxiliaryExecutable: "arctis-voice-engine") else {
            throw AudioFailure.message("Choose an AI configuration file and build the bundled voice engine first.")
        }
        process.executableURL = executable; process.arguments = [configPath]
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.state.lock()
            self.stderrText += String(decoding: data, as: UTF8.self)
            if self.stderrText.contains("READY") { self.ready = true }
            if self.stderrText.count > 8192 { self.stderrText = String(self.stderrText.suffix(8192)) }
            self.state.unlock()
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }; self.state.lock()
            let report = !self.stopping; let detail = self.stderrText; self.state.unlock()
            if report { self.onError("AI engine stopped (\(process.terminationStatus)): \(detail)") }
        }
        try process.run()
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.state.lock(); let canRun = self.ready && !self.stopping; self.state.unlock()
            guard canRun else { return }
            if self.firstHop { arctis_ring_discard(self.ring); self.firstHop = false; return }
            if arctis_ring_available(self.ring) > 6144 {
                self.onError("AI inference cannot keep up with live audio. Stop other intensive apps or use offline rendering.")
                return
            }
            guard arctis_ring_available(self.ring) >= 2048 else { return }
            var samples = [Float](repeating: 0, count: 2048)
            arctis_ring_read(self.ring, &samples, 2048)
            do {
                try samples.withUnsafeBytes { try self.input.fileHandleForWriting.write(contentsOf: Data($0)) }
                var data = Data()
                while data.count < 6144 * 4 {
                    guard let part = try self.output.fileHandleForReading.read(upToCount: 6144 * 4 - data.count), !part.isEmpty else {
                        throw AudioFailure.message("AI engine ended its audio stream.")
                    }
                    data.append(part)
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: 6144), let channel = buffer.floatChannelData?[0] else { return }
                buffer.frameLength = 6144; _ = data.withUnsafeBytes { memcpy(channel, $0.baseAddress!, data.count) }
                self.player.scheduleBuffer(buffer)
            } catch {
                self.state.lock(); let report = !self.stopping; self.state.unlock()
                if report { self.onError(error.localizedDescription) }
            }
        }
        timer.resume()
    }
    func stop() {
        state.lock(); guard !stopping else { state.unlock(); return }; stopping = true; state.unlock()
        timer?.cancel(); timer = nil
        diagnostics.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        // Killing the process closes stdout and unblocks any pending read.
        queue.async { [self] in arctis_ring_destroy(ring); try? output.fileHandleForReading.close() }
    }
}
