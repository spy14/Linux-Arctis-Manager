import AVFAudio

// Parallel detuned voices with short delays. Apple Audio Units own the real-time DSP;
// the main-thread timer only updates their modulation parameters.
final class Chorus {
    let output = AVAudioMixerNode()
    private var timer: Timer?
    private var voices: [AVAudioUnitTimePitch] = []
    init(engine: AVAudioEngine, source: AVAudioNode, format: AVAudioFormat,
         wet: Float, count: Int, delayMS: Double, detuneCents: Float, rate: Double) {
        engine.attach(output)
        let dry = AVAudioMixerNode(); engine.attach(dry); dry.outputVolume = 1 - wet
        var points = [AVAudioConnectionPoint(node: dry, bus: 0)]
        engine.connect(dry, to: output, fromBus: 0, toBus: 0, format: format)
        for i in 0..<count {
            let delay = AVAudioUnitDelay(); delay.delayTime = delayMS / 1000 + Double(i) * 0.001
            delay.feedback = 0; delay.wetDryMix = 100
            let pitch = AVAudioUnitTimePitch()
            let volume = AVAudioMixerNode(); volume.outputVolume = wet / Float(count)
            for node in [delay as AVAudioNode, pitch, volume] { engine.attach(node) }
            points.append(AVAudioConnectionPoint(node: delay, bus: 0))
            engine.connect(delay, to: pitch, format: format); engine.connect(pitch, to: volume, format: format)
            engine.connect(volume, to: output, fromBus: 0, toBus: AVAudioNodeBus(i + 1), format: format)
            voices.append(pitch)
        }
        engine.connect(source, to: points, fromBus: 0, format: format)
        let started = ProcessInfo.processInfo.systemUptime
        let voices = self.voices
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { _ in
            let t = ProcessInfo.processInfo.systemUptime - started
            for (i, voice) in voices.enumerated() {
                voice.pitch = detuneCents * Float(sin(2 * Double.pi * (t * rate + Double(i) / Double(count))))
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }
}
