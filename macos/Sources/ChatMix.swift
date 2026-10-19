import Foundation
import CoreAudio
import AVFAudio

@available(macOS 14.2, *)
final class ProcessAudioRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let engine = AVAudioEngine()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 15)
    private var ring: OpaquePointer?
    private var captureScratch: UnsafeMutablePointer<Float>?
    private var renderScratch: UnsafeMutablePointer<Float>?
    private let maximumFrames = 8192
    private var started = false

    init(processes: [AudioObjectID], excluding: Bool, output: AudioDevice, name: String) throws {
        do {
            let description = excluding ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes) : CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "Arctis \(name)"; description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try audioCheck(AudioHardwareCreateProcessTap(description, &tap), "Create \(name) audio tap")
            var a = AudioHardware.address(kAudioTapPropertyFormat)
            var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try audioCheck(AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &asbd), "Read tap format")
            guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame == 2,
                  asbd.mSampleRate >= 8000 else { throw AudioFailure.message("Unsupported audio tap format.") }
            guard let ring = arctis_ring_create(2, 32768),
                  let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: 2) else {
                throw AudioFailure.message("Could not allocate audio buffers.")
            }
            self.ring = ring
            let capture = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames * 2)
            let render = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames * 2)
            captureScratch = capture; renderScratch = render
            let maximum = maximumFrames
            let source = AVAudioSourceNode(format: format) { _, _, frames, data in
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                guard frames <= maximum else {
                    for b in buffers { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }; return noErr
                }
                arctis_ring_read(ring, render, frames)
                for (channel, buffer) in buffers.enumerated() {
                    guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    if buffer.mNumberChannels == 2 {
                        memcpy(p, render, min(Int(buffer.mDataByteSize), Int(frames) * 8))
                    } else if channel < 2 {
                        for frame in 0..<Int(frames) { p[frame] = render[frame * 2 + channel] }
                    }
                }
                return noErr
            }
            engine.attach(source); engine.attach(equalizer)
            engine.connect(source, to: equalizer, format: format)
            engine.connect(equalizer, to: engine.mainMixerNode, format: format)
            guard let unit = engine.outputNode.audioUnit else { throw AudioFailure.message("Audio output is unavailable.") }
            var device = output.id
            try audioCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioObjectID>.size)), "Select output")
            setEQ(Array(repeating: 0, count: 10))
            let spec: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Arctis Tap \(name)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try audioCheck(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "Create tap device")
            try audioCheck(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, first.mNumberChannels > 0 else { return }
                let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
                guard frames <= maximum, let pointer = first.mData?.assumingMemoryBound(to: Float.self) else { return }
                if first.mNumberChannels == 2 {
                    arctis_ring_write(ring, pointer, UInt32(frames))
                } else if buffers.count >= 2, buffers[1].mDataByteSize >= frames * 4,
                          let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    for frame in 0..<frames { capture[frame * 2] = pointer[frame]; capture[frame * 2 + 1] = right[frame] }
                    arctis_ring_write(ring, capture, UInt32(frames))
                }
            }, "Create audio callback")
            try engine.start()
            try audioCheck(AudioDeviceStart(aggregate, io), "Start audio tap")
            started = true
        } catch { stop(); throw error }
    }
    func setVolume(_ volume: Float) { engine.mainMixerNode.outputVolume = min(1, max(0, volume)) }
    func setEQ(_ gains: [Double]) {
        guard [10, 15].contains(gains.count) else { return }
        let frequencies = EqualizerBands.frequencies(count: gains.count)
        for i in 0..<15 {
            guard i < gains.count else { equalizer.bands[i].bypass = true; continue }
            let band = equalizer.bands[i]
            band.filterType = .parametric; band.frequency = Float(min(frequencies[i], engine.mainMixerNode.outputFormat(forBus: 0).sampleRate * 0.45)); band.bandwidth = 1
            band.gain = Float(min(12, max(-12, gains[i]))); band.bypass = false
        }
    }
    func stop() {
        if let io { if started { AudioDeviceStop(aggregate, io) }; AudioDeviceDestroyIOProcID(aggregate, io) }
        io = nil; started = false; engine.stop()
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let ring { arctis_ring_destroy(ring) }; ring = nil
        captureScratch?.deallocate(); captureScratch = nil; renderScratch?.deallocate(); renderScratch = nil
    }
    deinit { stop() }
}

final class ChatMix: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var processes: [AudioProcess] = []
    @Published var outputUID = ""
    @Published var chatApps: Set<String> = []
    @Published var enabled = false
    @Published var message = "Choose chat apps, then enable routing. Other apps use the media channel."
    @Published var mediaEQ = Array(repeating: 0.0, count: 10)
    @Published var chatEQ = Array(repeating: 0.0, count: 10)
    @Published var presets: [SoftwareEQPreset] = []
    @Published var followDial = true
    @Published var manualBalance = 0.0
    private var media: AnyObject?
    private var chat: AnyObject?
    private var processIDs: [AudioObjectID] = []
    private var timer: Timer?
    private var gameGain = 1.0
    private var chatGain = 1.0
    init() {
        chatApps = Set(UserDefaults.standard.stringArray(forKey: "chatApps") ?? [])
        outputUID = UserDefaults.standard.string(forKey: "mixOutput") ?? ""
        if let data = UserDefaults.standard.data(forKey: "softwareEQPresets"), let saved = try? JSONDecoder().decode([SoftwareEQPreset].self, from: data) { presets = saved.filter(\.valid) }
        if let data = UserDefaults.standard.data(forKey: "softwareEQLast"), let saved = try? JSONDecoder().decode(SoftwareEQPreset.self, from: data), saved.valid { mediaEQ = saved.media; chatEQ = saved.chat }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }; self.refresh()
            if self.enabled {
                if !self.devices.contains(where: { $0.uid == self.outputUID }) {
                    self.stop(); self.message = "Output disconnected. Reconnect it and enable routing again."
                } else if #available(macOS 14.2, *) {
                    if self.selectedIDs != self.processIDs { self.start() }
                }
            }
        }
    }
    func refresh() {
        devices = AudioHardware.devices().filter { $0.output }
        if outputUID.isEmpty { outputUID = devices.first(where: { $0.name.contains("Arctis") })?.uid ?? "" }
        if #available(macOS 14.2, *) { processes = AudioHardware.processes() }
    }
    private var selectedIDs: [AudioObjectID] { processes.filter { chatApps.contains($0.bundle) }.map(\.id).sorted() }
    func start() {
        stop()
        refresh()
        guard #available(macOS 14.2, *) else { message = "ChatMix audio routing requires macOS 14.2 or newer."; return }
        guard let output = devices.first(where: { $0.uid == outputUID }) else { message = "Choose an audio output first."; return }
        guard let own = AudioHardware.ownProcess() else { message = "Cannot identify the app's audio process. Try again."; return }
        do {
            processIDs = selectedIDs
            let media = try ProcessAudioRoute(processes: processIDs + [own], excluding: true, output: output, name: "Media")
            self.media = media
            if !processIDs.isEmpty { chat = try ProcessAudioRoute(processes: processIDs, excluding: false, output: output, name: "Chat") }
            media.setEQ(mediaEQ); (chat as? ProcessAudioRoute)?.setEQ(chatEQ)
            enabled = true; updateVolumes()
            UserDefaults.standard.set(Array(chatApps), forKey: "chatApps"); UserDefaults.standard.set(outputUID, forKey: "mixOutput")
            message = "Routing media and chat to \(output.name)."
        } catch { stop(); message = error.localizedDescription }
    }
    func stop() {
        if #available(macOS 14.2, *) { (media as? ProcessAudioRoute)?.stop(); (chat as? ProcessAudioRoute)?.stop() }
        media = nil; chat = nil; enabled = false
    }
    func dial(game: Int?, chat: Int?) {
        if let game, let chat { gameGain = Double(game) / 100; chatGain = Double(chat) / 100 }
        updateVolumes()
    }
    func updateVolumes() {
        guard #available(macOS 14.2, *) else { return }
        let game = followDial ? gameGain : min(1, 1 - manualBalance)
        let chat = followDial ? chatGain : min(1, 1 + manualBalance)
        (media as? ProcessAudioRoute)?.setVolume(Float(game)); (self.chat as? ProcessAudioRoute)?.setVolume(Float(chat))
    }
    func savePreset(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        presets.append(SoftwareEQPreset(name: name, media: mediaEQ, chat: chatEQ))
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "softwareEQPresets")
    }
    func removePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "softwareEQPresets")
    }
    func applyEQ() {
        UserDefaults.standard.set(try? JSONEncoder().encode(SoftwareEQPreset(name: "Last", media: mediaEQ, chat: chatEQ)), forKey: "softwareEQLast")
        if #available(macOS 14.2, *) { (media as? ProcessAudioRoute)?.setEQ(mediaEQ); (chat as? ProcessAudioRoute)?.setEQ(chatEQ) }
    }
}
