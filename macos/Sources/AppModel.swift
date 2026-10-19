import AppKit
import Combine
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    let headset = Headset()
    let profiles = Profiles()
    let mix = ChatMix()
    let microphone = Microphone()
    let voiceModels = VoiceModels()
    private var mixSubscription: AnyCancellable?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?
    private var observers: [NSObjectProtocol] = []
    private var connection: AnyCancellable?

    init() {
        mixSubscription = Publishers.CombineLatest(headset.$gameMix, headset.$chatMix).sink { [weak self] game, chat in
            self?.mix.dial(game: game, chat: chat)
        }
        connection = headset.$connected.removeDuplicates().sink { [weak self] connected in
            guard let self, connected else { return }
            // @Published fires before assigning the value. Wait until the status
            // callback completes before applying an opted-in restoration.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.headset.connected, self.profiles.restoreOnConnect,
                      let last = self.profiles.lastApplied else { return }
                self.apply(last)
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
            guard let self, self.profiles.automaticProfiles,
                  let bundle,
                  let profile = self.profiles.items.first(where: { !$0.applicationBundleID.isEmpty && $0.applicationBundleID == bundle }),
                  self.headset.connected else { return }
            self.apply(profile.settings)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.mix.stop(); self?.microphone.stop(); self?.headset.disconnect() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.headset.connect() } })
    }
    @discardableResult func apply(_ settings: HeadsetSettings) -> Bool {
        guard settings.valid, headset.connected else { error = "Connect the headset before applying a profile."; return false }
        for report in settings.reports { guard headset.send(report) else { return false } }
        profiles.markApplied(settings)
        return true
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { error = "Allow Arctis Settings in System Settings → General → Login Items." }
        } catch { self.error = error.localizedDescription }
    }
    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
