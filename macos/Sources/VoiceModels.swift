import Foundation
import CryptoKit
import AVFoundation

struct VoiceModel: Identifiable, Hashable {
    var url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor final class VoiceModels: ObservableObject {
    @Published var models: [VoiceModel] = []
    @Published var selected = ""
    @Published var runtime = ""
    @Published var python = "/opt/homebrew/bin/python3"
    @Published var recording = false
    private var recorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var player: AVAudioPlayer?
    @Published var busy = false
    @Published var message = "Import an RVC v2 voice model, download the base models, and install the AI runtime."
    @Published var coreML = false
    @Published var pitch = 0.0
    @Published var formant = 1.0
    @Published var rmsMix = 0.25
    @Published var indexRate = 0.0
    @Published var targetRMS = 0.06
    @Published var limiter = 0.8
    @Published var filterRadius = 3
    @Published var tokenDraft = ""
    @Published var query = ""
    @Published var searchResults: [String] = []
    @Published var repository = ""
    @Published var repositoryFiles: [String] = []
    private let hubSession = URLSession(configuration: .ephemeral, delegate: ModelRedirectPolicy(), delegateQueue: nil)
    let directory: URL
    var environment: URL { directory.appendingPathComponent("ai-env") }
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arctis Settings/Models")
        runtime = UserDefaults.standard.string(forKey: "onnxRuntime") ?? ""
        selected = UserDefaults.standard.string(forKey: "voiceModel") ?? ""
        if let saved = UserDefaults.standard.dictionary(forKey: "voiceTuning") {
            if let v = saved["pitch"] as? Double, (-24...24).contains(v) { pitch = v }
            if let v = saved["formant"] as? Double, (0.7...1.4).contains(v) { formant = v }
            if let v = saved["rmsMix"] as? Double, (0...1).contains(v) { rmsMix = v }
            if let v = saved["indexRate"] as? Double, (0...1).contains(v) { indexRate = v }
            if let v = saved["targetRMS"] as? Double, (0.01...0.2).contains(v) { targetRMS = v }
            if let v = saved["limiter"] as? Double, (0.3...1).contains(v) { limiter = v }
            if let v = saved["filterRadius"] as? Int, [1,3,5,7,9].contains(v) { filterRadius = v }
            coreML = saved["coreML"] as? Bool ?? false
        }
        refresh()
    }
    var calibrationInput: URL { directory.appendingPathComponent("calibration-input.wav") }
    var calibrationOutput: URL { directory.appendingPathComponent("calibration-output.wav") }
    func recordSample() {
        guard !busy, !recording else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard allowed else { self.message = "Microphone permission is required to record a calibration sample."; return }
                do {
                    self.player?.stop()
                    self.recorder = try AVAudioRecorder(url: self.calibrationInput, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                    guard self.recorder?.record() == true else { throw AudioFailure.message("Could not start recording.") }
                    self.recording = true; self.message = "Recording the system default microphone. Stay quiet for one second, then speak. Stops after 10 seconds."
                    self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in Task { @MainActor in self?.stopRecording() } }
                } catch { self.message = error.localizedDescription }
            }
        }
    }
    func stopRecording() {
        recorder?.stop(); recorder = nil; recordingTimer?.invalidate(); recordingTimer = nil; recording = false
        message = "Calibration sample recorded. Render it with the selected voice, then compare both recordings."
    }
    func play(_ url: URL) {
        do { player?.stop(); player = try AVAudioPlayer(contentsOf: url); player?.play() }
        catch { message = error.localizedDescription }
    }
    func refresh() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            models = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { ["onnx", "pth"].contains($0.pathExtension) && !["rmvpe.onnx", "content_vec_best.onnx"].contains($0.lastPathComponent) }
                .map { VoiceModel(url: $0) }.sorted { $0.name < $1.name }
        } catch { message = error.localizedDescription }
    }
    func importModel(_ url: URL) {
        do {
            guard ["onnx", "pth", "index"].contains(url.pathExtension.lowercased()) else { throw AudioFailure.message("Choose an ONNX, PTH, or INDEX file.") }
            let target = directory.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw AudioFailure.message("A file with that name already exists. Rename it before importing.") }
            try FileManager.default.copyItem(at: url, to: target)
            if target.pathExtension != "index" { selected = target.path }
            refresh(); message = "Imported \(url.lastPathComponent)."
        } catch { message = error.localizedDescription }
    }
    func deleteSelected() {
        guard let model = models.first(where: { $0.id == selected }) else { return }
        do { try FileManager.default.trashItem(at: model.url, resultingItemURL: nil); selected = ""; refresh() }
        catch { message = error.localizedDescription }
    }
    private func request(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url); req.setValue("Arctis-Settings", forHTTPHeaderField: "User-Agent")
        if url.host == "huggingface.co", let token = ModelCredentials.read() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let session = url.host == "huggingface.co" ? hubSession : URLSession.shared
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AudioFailure.message("Download request failed. Check your connection or repository access.") }
        return data
    }
    func downloadBases() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            message = "Finding verified base models…"
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            struct Release: Decodable { let assets: [Asset] }
            let data = try await request(URL(string: "https://api.github.com/repos/elegos/Linux-Arctis-Manager-AI-Models/releases/latest")!)
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let manifest = release.assets.first(where: { $0.name == "checksum.onnx.sha256" }) else { throw AudioFailure.message("Base-model release has no checksum manifest.") }
            let checksums = String(decoding: try await request(manifest.browser_download_url), as: UTF8.self)
            for name in ["rmvpe.onnx", "content_vec_best.onnx"] {
                guard let asset = release.assets.first(where: { $0.name == name }),
                      let line = checksums.split(separator: "\n").first(where: { $0.split(whereSeparator: \.isWhitespace).last?.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name }),
                      let hash = line.split(whereSeparator: \.isWhitespace).first, hash.count == 64 else {
                    throw AudioFailure.message("Base-model release is missing \(name) or its checksum.")
                }
                message = "Downloading \(name)…"
                let (temporary, response) = try await URLSession.shared.download(from: asset.browser_download_url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AudioFailure.message("Could not download \(name).") }
                let actual = try await Task.detached {
                    let file = try FileHandle(forReadingFrom: temporary); defer { try? file.close() }
                    var digest = SHA256()
                    while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
                    return digest.finalize().map { String(format: "%02x", $0) }.joined()
                }.value
                guard actual == hash.lowercased() else { throw AudioFailure.message("Checksum mismatch for \(name); download was rejected.") }
                let destination = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: destination) }
            }
            message = "Base models downloaded and checksums verified."
        } catch { message = error.localizedDescription }
    }
    func installRuntime() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            message = "Creating a private Python environment…"
            try await Self.run(URL(fileURLWithPath: python), ["-m", "venv", environment.path], log: directory.appendingPathComponent("install.log"))
            message = "Installing PyTorch, ONNX and ONNX Runtime. This may take several minutes…"
            try await Self.run(environment.appendingPathComponent("bin/python"), ["-m", "pip", "install", "torch", "numpy", "onnx", "onnxruntime", "onnxscript"], log: directory.appendingPathComponent("install.log"))
            runtime = Self.findRuntime(in: environment) ?? runtime
            guard !runtime.isEmpty else { throw AudioFailure.message("Runtime installed but its dylib was not found. Choose the ONNX Runtime library manually.") }
            UserDefaults.standard.set(runtime, forKey: "onnxRuntime")
            message = "AI dependencies installed."
        } catch { message = error.localizedDescription }
    }
    nonisolated private static func findRuntime(in directory: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("libonnxruntime.") && url.pathExtension == "dylib" { return url.path }
        return nil
    }
    func exportSelected() async {
        guard !busy, let model = models.first(where: { $0.id == selected }), model.url.pathExtension == "pth" else { return }
        busy = true; defer { busy = false }
        do {
            guard let resources = Bundle.main.resourceURL?.appendingPathComponent("python") else { return }
            message = "Exporting and validating the voice model…"
            try await Self.run(environment.appendingPathComponent("bin/python"), ["-m", "linux_arctis_manager.voice_changer.rvc.export_onnx", model.url.path], log: directory.appendingPathComponent("export.log"), pythonPath: resources.path)
            selected = model.url.deletingPathExtension().appendingPathExtension("onnx").path
            refresh(); message = "Model exported and validated."
        } catch { message = error.localizedDescription }
    }
    func configuration() throws -> URL {
        guard let model = models.first(where: { $0.id == selected }), model.url.pathExtension == "onnx",
              FileManager.default.fileExists(atPath: runtime) else { throw AudioFailure.message("Choose an exported ONNX voice model and an ONNX Runtime dylib.") }
        let content = directory.appendingPathComponent("content_vec_best.onnx")
        let rmvpe = directory.appendingPathComponent("rmvpe.onnx")
        guard FileManager.default.fileExists(atPath: content.path), FileManager.default.fileExists(atPath: rmvpe.path) else { throw AudioFailure.message("Download the base models first.") }
        let index = model.url.deletingPathExtension().appendingPathExtension("index")
        var config: [String: Any] = ["runtime": runtime, "contentvec": content.path, "rmvpe": rmvpe.path, "model": model.url.path, "pitch": pitch, "coreml": coreML,
            "params": ["hubert_model": "contentvec", "vtln_alpha": formant, "rms_mix_rate": rmsMix, "filter_radius": filterRadius,
                       "target_rms": targetRMS, "limiter_thr": limiter, "index_rate": indexRate]]
        if FileManager.default.fileExists(atPath: index.path) { config["index"] = index.path }
        else if indexRate > 0 { throw AudioFailure.message("Import a matching .index file or set retrieval blend to zero.") }
        let url = directory.appendingPathComponent("session.json")
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        UserDefaults.standard.set(selected, forKey: "voiceModel"); UserDefaults.standard.set(runtime, forKey: "onnxRuntime")
        UserDefaults.standard.set(["pitch": pitch, "formant": formant, "rmsMix": rmsMix, "indexRate": indexRate, "targetRMS": targetRMS, "limiter": limiter, "filterRadius": filterRadius, "coreML": coreML], forKey: "voiceTuning")
        return url
    }
    func render(input: URL, output: URL) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let config = try configuration()
            guard let executable = Bundle.main.url(forAuxiliaryExecutable: "arctis-voice-engine") else { throw AudioFailure.message("Voice engine is missing from this build.") }
            message = "Rendering calibration audio…"
            try await Self.run(executable, [config.path, input.path, output.path], log: directory.appendingPathComponent("render.log"))
            message = "Rendered \(output.lastPathComponent). Compare it with your original recording."
        } catch { message = error.localizedDescription }
    }
    func saveToken() {
        do { try ModelCredentials.save(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)); tokenDraft = ""; message = "Hugging Face token updated in Keychain." }
        catch { message = error.localizedDescription }
    }
    func search() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            var url = URLComponents(string: "https://huggingface.co/api/models")!
            url.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "limit", value: "30")]
            struct Model: Decodable { let id: String }
            searchResults = try JSONDecoder().decode([Model].self, from: await request(url.url!)).map(\.id)
        } catch { message = error.localizedDescription }
    }
    func listFiles() async {
        guard !busy, !repository.isEmpty else { return }; busy = true; defer { busy = false }
        do {
            let url = URL(string: "https://huggingface.co/api/models/")!.appendingPathComponent(repository)
            struct File: Decodable { let rfilename: String }
            struct Repo: Decodable { let siblings: [File] }
            repositoryFiles = try JSONDecoder().decode(Repo.self, from: await request(url)).siblings.map(\.rfilename).filter { ["pth", "onnx", "index"].contains(URL(fileURLWithPath: $0).pathExtension) }
        } catch { message = error.localizedDescription }
    }
    func downloadModel(_ filename: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            message = "Downloading \(filename)…"
            let url = URL(string: "https://huggingface.co/")!.appendingPathComponent(repository).appendingPathComponent("resolve/main").appendingPathComponent(filename)
            var request = URLRequest(url: url)
            if let token = ModelCredentials.read() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (temporary, response) = try await hubSession.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AudioFailure.message("Model download failed. For private or gated repositories, check your saved Hugging Face token and account access.") }
            let target = directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw AudioFailure.message("A model with this name already exists.") }
            try FileManager.default.moveItem(at: temporary, to: target)
            selected = target.path; refresh(); message = "Model downloaded. Export PTH models before using them."
        } catch { message = error.localizedDescription }
    }
    nonisolated private static func run(_ executable: URL, _ arguments: [String], log: URL, pythonPath: String? = nil) async throws {
        try await Task.detached {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            process.standardOutput = handle; process.standardError = handle
            if let pythonPath { var env = ProcessInfo.processInfo.environment; env["PYTHONPATH"] = pythonPath; process.environment = env }
            try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 { throw AudioFailure.message("Operation failed (\(process.terminationStatus)). Details: \(log.path)") }
        }.value
    }
}

private final class ModelRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var safe = request
        // Model blobs use signed CDN URLs; the account token belongs only to the Hub.
        if safe.url?.host != "huggingface.co" { safe.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(safe)
    }
}
