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
    private let shortcuts: ShortcutController
    private let settingsWindow: SettingsWindowController
    private var dock: DockIconController?
    private var hud: HUDController?
    private var statusItem: StatusItemController?
    private var observers: [NSObjectProtocol] = []

    init() {
        let settings = AppSettings()
        let keys = APIKeyManager(store: KeychainSecretStore(service: AppInfo.bundleIdentifier), settings: settings)
        let inserter = PasteInserter(source: AppInfo.bundleIdentifier)
        self.settings = settings
        self.keys = keys
        self.inserter = inserter
        let controller = DictationController(
            recorder: SystemAudioRecorder(),
            microphone: SystemMicrophonePermission(),
            apiKeys: keys,
            models: settings,
            transcriber: GeminiClient(transport: URLSessionTransport()),
            compressor: SystemAudioCompressor(),
            focus: SystemFocusTracker(),
            inserter: inserter,
            clipboard: SystemClipboardWriter()
        )
        self.controller = controller
        let shortcuts = ShortcutController(
            settings: settings,
            hotKeys: hotKeys,
            hotKeyID: HotKeyID.toggle,
            fnMonitor: FnKeyMonitor(),
            keyEvents: LocalShortcutKeyEventSource(),
            systemShortcuts: CarbonSystemShortcuts(),
            isTrusted: { AXIsProcessTrusted() },
            onToggle: { Task { await controller.toggle() } }
        )
        self.shortcuts = shortcuts
        settingsModel = SettingsModel(
            settings: settings,
            keys: keys,
            permissions: SystemPermissions(),
            shortcuts: shortcuts
        )
        let settingsWindow = SettingsWindowController(model: settingsModel)
        self.settingsWindow = settingsWindow
        let dock = DockIconController(
            settings: settings,
            applier: SystemActivationPolicy(bringSettingsToFront: { settingsWindow.bringToFront() }),
            isBusy: { controller.phase.isBusy },
            settingsVisible: { settingsWindow.isVisible }
        )
        self.dock = dock
        settingsModel.onDockPreferenceChange = { dock.preferenceChanged() }
    }

    func start(showSettings: Bool) {
        TemporaryAudioFiles.purge()
        NSApp.applicationIconImage = AppIconRenderer.image()
        dock?.applyAtLaunch()
        hud = HUDController(
            controller: controller,
            shortcut: { [settings] in settings.shortcut.displayName },
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
                openSettings: { [weak self] in self?.showSettings() },
                menuWillOpen: { [weak self] in self?.shortcuts.recheckPermission() }
            )
        )
        controller.onPhaseChange = { [weak self] phase in
            self?.phaseDidChange(phase)
        }
        shortcuts.activate()
        // fn starts working as soon as Accessibility is allowed; re-check when the user comes back.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shortcuts.recheckPermission() }
        })
        Log.app.notice("launched; key configured: \(self.keys.isConfigured, privacy: .public); shortcut \(self.shortcutKind, privacy: .public): \(self.shortcutStatusName, privacy: .public); dock: \(self.settings.showInDock, privacy: .public)")

        // Also open Settings when the shortcut cannot work yet (e.g. fn without
        // Accessibility after switching builds), so the reason is visible.
        if showSettings || !keys.isConfigured || shortcuts.status != .active {
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

    /// For logs: only the kind of shortcut, never key details or typing.
    private var shortcutKind: String {
        if case .fn = settings.shortcut { return "fn" }
        return "key"
    }

    private var shortcutStatusName: String {
        switch shortcuts.status {
        case .active: return "active"
        case .needsAccessibility: return "needsAccessibility"
        case .registrationFailed: return "registrationFailed"
        case .paused: return "paused"
        }
    }

    private func phaseDidChange(_ phase: DictationPhase) {
        Log.app.info("phase \(phase.logName, privacy: .public)")
        hud?.phaseDidChange(phase)
        statusItem?.update(for: phase)
        shortcuts.busyStateChanged(isBusy: phase.isBusy, isRecording: phase == .recording)
        dock?.busyStateChanged(isBusy: phase.isBusy)
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
