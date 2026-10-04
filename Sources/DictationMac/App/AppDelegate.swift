import AppKit
import DictationCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppComposition?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let app = AppComposition()
        self.app = app
        NSApp.mainMenu = MainMenu.make(openSettings: #selector(openSettings), target: self)
        app.start(showSettings: CommandLine.arguments.contains("--show-settings"))
    }

    public func applicationWillTerminate(_ notification: Notification) {
        app?.shutDown()
    }

    /// Opening the app again (e.g. from Finder) shows Settings, in case the menu bar icon is hidden.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        app?.showSettings()
        return false
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func openSettings() {
        app?.showSettings()
    }
}

/// Builds the object graph and wires shortcuts, menu bar, panel and Settings together.
/// Nothing here touches the microphone, the network, the Keychain or Accessibility at launch.
@MainActor
final class AppComposition {
    private enum HotKeyID {
        static let toggle: UInt32 = 1
        static let cancel: UInt32 = 2
    }

    private let settings: AppSettings
    private let keys: APIKeyManager
    private let inserter: PasteInserter
    private let controller: DictationController
    private let settingsModel: SettingsModel
    private let hotKeys = HotKeyCenter()
    private let settingsWindow: SettingsWindowController
    private var hud: HUDController?
    private var statusItem: StatusItemController?

    init() {
        let settings = AppSettings()
        let keys = APIKeyManager(store: KeychainSecretStore(service: AppInfo.bundleIdentifier), settings: settings)
        let inserter = PasteInserter(source: AppInfo.bundleIdentifier)
        self.settings = settings
        self.keys = keys
        self.inserter = inserter
        controller = DictationController(
            recorder: SystemAudioRecorder(),
            microphone: SystemMicrophonePermission(),
            apiKeys: keys,
            models: settings,
            transcriber: GeminiClient(transport: URLSessionTransport()),
            focus: SystemFocusTracker(),
            inserter: inserter,
            clipboard: SystemClipboardWriter()
        )
        settingsModel = SettingsModel(settings: settings, keys: keys, permissions: SystemPermissions())
        settingsWindow = SettingsWindowController(model: settingsModel)
    }

    func start(showSettings: Bool) {
        TemporaryAudioFiles.purge()
        hud = HUDController(
            controller: controller,
            shortcut: { [settings] in settings.hotKeyPreset.displayName },
            perform: { [weak self] action in self?.perform(action) }
        )
        statusItem = StatusItemController(
            controller: controller,
            settings: settings,
            actions: .init(
                toggle: { [weak self] in self?.toggle() },
                cancel: { [weak self] in self?.controller.cancel() },
                retry: { [weak self] in self?.controller.retry() },
                copyLast: { [weak self] in self?.controller.copyLastTranscript() },
                openSettings: { [weak self] in self?.showSettings() }
            )
        )
        controller.onPhaseChange = { [weak self] phase in
            self?.phaseDidChange(phase)
        }
        settings.onHotKeyPresetChange = { [weak self] _ in
            self?.registerToggleHotKey()
        }
        registerToggleHotKey()
        Log.app.notice("launched; key configured: \(self.keys.isConfigured, privacy: .public)")

        if showSettings || !keys.isConfigured {
            self.showSettings()
        }
    }

    func shutDown() {
        if controller.phase.isBusy {
            controller.cancel()
        }
        inserter.restorePendingNow()
        hotKeys.unregisterAll()
        TemporaryAudioFiles.purge()
    }

    func showSettings() {
        settingsWindow.show()
        Log.app.notice("settings window shown")
    }

    private func toggle() {
        Task { await controller.toggle() }
    }

    private func registerToggleHotKey() {
        let preset = settings.hotKeyPreset
        let registered = hotKeys.register(id: HotKeyID.toggle, keyCode: preset.keyCode, modifiers: preset.carbonModifiers) { [weak self] in
            self?.toggle()
        }
        settingsModel.hotKeyRegistered = registered
        Log.app.notice("shortcut \(preset.rawValue, privacy: .public) registered: \(registered, privacy: .public)")
    }

    private func phaseDidChange(_ phase: DictationPhase) {
        Log.app.info("phase \(phase.logName, privacy: .public)")
        hud?.phaseDidChange(phase)
        statusItem?.update(for: phase)
        // esc cancels only while recording or waiting for Gemini; otherwise it stays with other apps.
        if phase.isBusy {
            if !hotKeys.isRegistered(id: HotKeyID.cancel) {
                hotKeys.register(id: HotKeyID.cancel, keyCode: HotKeyCenter.escapeKeyCode, modifiers: 0) { [weak self] in
                    self?.controller.cancel()
                }
            }
        } else {
            hotKeys.unregister(id: HotKeyID.cancel)
        }
    }

    private func perform(_ action: HUDAction) {
        switch action {
        case .stop: controller.stop()
        case .cancel: controller.cancel()
        case .copy: controller.copyLastTranscript()
        case .retry: controller.retry()
        case .openSettings: showSettings()
        case .openMicrophoneSettings: SystemSettingsPane.microphone.open()
        case .openAccessibilitySettings: SystemSettingsPane.accessibility.open()
        case .dismiss: controller.dismiss()
        }
    }
}
