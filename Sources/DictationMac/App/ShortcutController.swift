import DictationCore
import Foundation
import Observation

/// Owns the recording shortcut: registers it, records a new one in Settings, and
/// keeps the previous one when a new one cannot be registered.
@MainActor
@Observable
public final class ShortcutController {
    public enum Status: Equatable, Sendable {
        case active
        /// fn is selected but this app is not trusted for Accessibility yet.
        case needsAccessibility
        case registrationFailed
        /// Paused while the recorder listens.
        case paused
    }

    public struct Feedback: Equatable, Sendable {
        public var text: String
        public var isError: Bool
    }

    public private(set) var status: Status = .paused
    public private(set) var isRecording = false
    public private(set) var feedback: Feedback?
    /// True while a dictation is recording or being transcribed.
    public private(set) var changesBlocked = false

    public var shortcut: Shortcut {
        settings.shortcut
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let hotKeys: HotKeyRegistering
    @ObservationIgnored private let hotKeyID: UInt32
    @ObservationIgnored private let fnMonitor: FnKeyMonitoring
    @ObservationIgnored private let keyEvents: ShortcutKeyEventSource
    @ObservationIgnored private let systemShortcuts: SystemShortcutProviding
    @ObservationIgnored private let isTrusted: @MainActor () -> Bool
    @ObservationIgnored private let sleeper: Sleeping
    @ObservationIgnored private let permissionPollInterval: Double
    @ObservationIgnored private let onToggle: @MainActor () -> Void
    @ObservationIgnored private var recording: ShortcutRecording?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    public init(
        settings: AppSettings,
        hotKeys: HotKeyRegistering,
        hotKeyID: UInt32,
        fnMonitor: FnKeyMonitoring,
        keyEvents: ShortcutKeyEventSource,
        systemShortcuts: SystemShortcutProviding,
        isTrusted: @escaping @MainActor () -> Bool,
        sleeper: Sleeping = TaskSleeper(),
        permissionPollInterval: Double = 3,
        onToggle: @escaping @MainActor () -> Void
    ) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.hotKeyID = hotKeyID
        self.fnMonitor = fnMonitor
        self.keyEvents = keyEvents
        self.systemShortcuts = systemShortcuts
        self.isTrusted = isTrusted
        self.sleeper = sleeper
        self.permissionPollInterval = permissionPollInterval
        self.onToggle = onToggle
    }

    /// Registers the saved shortcut. Called once at launch.
    public func activate() {
        status = apply(settings.shortcut)
    }

    /// Starts listening for a new shortcut in the Settings window.
    public func startRecording() {
        guard !isRecording else { return }
        guard !changesBlocked else {
            feedback = Feedback(text: "録音中・文字起こし中はショートカットを変更できません。", isError: true)
            return
        }
        // While listening, the current shortcut must not toggle a recording.
        suspend()
        status = .paused
        isRecording = true
        recording = ShortcutRecording(systemShortcuts: systemShortcuts.enabledShortcuts())
        feedback = Feedback(text: "割り当てたいキーを押してください。fn だけを押して離すと fn になります。esc でキャンセルします。", isError: false)
        keyEvents.start { [weak self] input in
            self?.handleRecorderInput(input)
        }
    }

    public func cancelRecording() {
        guard isRecording else { return }
        endRecording()
        status = apply(settings.shortcut)
        feedback = Feedback(text: "変更をキャンセルしました。", isError: false)
    }

    /// Goes back to fn.
    public func resetToDefault() {
        guard !isRecording else { return }
        guard !changesBlocked else {
            feedback = Feedback(text: "録音中・文字起こし中はショートカットを変更できません。", isError: true)
            return
        }
        commit(.default)
    }

    /// Called on every dictation phase change.
    public func busyStateChanged(isBusy: Bool) {
        changesBlocked = isBusy
        if isBusy && isRecording {
            cancelRecording()
        }
    }

    /// Re-reads the Accessibility state (for example when the app becomes active).
    public func recheckPermission() {
        guard !isRecording, case .fn = settings.shortcut else { return }
        let trusted = isTrusted()
        if trusted != (status == .active) {
            status = apply(.fn)
        }
    }

    func handleRecorderInput(_ input: ShortcutRecording.Input) {
        guard isRecording, var session = recording else { return }
        let outcome = session.handle(input)
        recording = session
        switch outcome {
        case .none:
            break
        case .cancelled:
            cancelRecording()
        case .rejected(let reason):
            feedback = Feedback(text: reason.message, isError: true)
        case .recorded(let shortcut):
            endRecording()
            commit(shortcut)
        }
    }

    private func endRecording() {
        keyEvents.stop()
        recording = nil
        isRecording = false
    }

    /// Registers `new` first and saves it only if that worked; otherwise the
    /// previous shortcut stays registered.
    private func commit(_ new: Shortcut) {
        let previous = settings.shortcut
        let result = apply(new)
        if result == .registrationFailed {
            status = apply(previous)
            feedback = Feedback(text: ShortcutRejection.registrationFailed.message, isError: true)
            return
        }
        settings.shortcut = new
        status = result
        feedback = Feedback(text: "録音の開始／停止を「\(new.displayName)」にしました。", isError: false)
    }

    private func suspend() {
        stopPermissionPolling()
        fnMonitor.stop()
        hotKeys.unregister(id: hotKeyID)
    }

    private func apply(_ shortcut: Shortcut) -> Status {
        suspend()
        switch shortcut {
        case .fn:
            guard isTrusted() else {
                startPermissionPolling()
                return .needsAccessibility
            }
            fnMonitor.start(onTap: onToggle)
            return .active
        case .key(let combo):
            let registered = hotKeys.register(
                id: hotKeyID,
                keyCode: UInt32(combo.keyCode),
                modifiers: CarbonModifiers.from(combo.modifiers),
                handler: onToggle
            )
            return registered ? .active : .registrationFailed
        }
    }

    /// fn starts working by itself once the user allows Accessibility.
    private func startPermissionPolling() {
        guard pollTask == nil else { return }
        let sleeper = self.sleeper
        let interval = permissionPollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(seconds: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if self.isTrusted() {
                    self.pollTask = nil
                    if !self.isRecording, case .fn = self.settings.shortcut {
                        self.status = self.apply(.fn)
                    }
                    return
                }
            }
        }
    }

    private func stopPermissionPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// For tests: lets a polling cycle run.
    var isPollingForPermission: Bool {
        pollTask != nil
    }
}
