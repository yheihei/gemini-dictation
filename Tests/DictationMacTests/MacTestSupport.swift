import DictationCore
import Foundation
@testable import DictationMac

// Fakes for the shortcut and Dock code. None of them registers hot keys, installs
// event monitors, changes the activation policy or asks macOS for permissions.

@MainActor
final class FakeHotKeys: HotKeyRegistering {
    struct Registration: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    var refusedKeyCodes: Set<UInt32> = []
    private(set) var registrations: [UInt32: Registration] = [:]
    private var handlers: [UInt32: HotKeyCenter.Handler] = [:]
    private(set) var registerCount = 0

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping HotKeyCenter.Handler) -> Bool {
        registerCount += 1
        guard !refusedKeyCodes.contains(keyCode) else { return false }
        registrations[id] = Registration(keyCode: keyCode, modifiers: modifiers)
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        registrations[id] = nil
        handlers[id] = nil
    }

    func isRegistered(id: UInt32) -> Bool {
        registrations[id] != nil
    }

    /// Simulates the user pressing the registered combination.
    func press(id: UInt32) {
        handlers[id]?()
    }
}

@MainActor
final class FakeFnMonitor: FnKeyMonitoring {
    var allowsTap = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onHold: (@MainActor () -> Void)?

    var isRunning: Bool {
        onHold != nil
    }

    func start(onHold: @escaping @MainActor () -> Void) {
        startCount += 1
        self.onHold = onHold
    }

    func stop() {
        stopCount += 1
        onHold = nil
    }

    /// 長押しの確定を再現する。
    func hold() {
        onHold?()
    }
}

@MainActor
final class FakeKeyEvents: ShortcutKeyEventSource {
    private var handler: (@MainActor (ShortcutRecording.Input) -> Void)?

    var isListening: Bool {
        handler != nil
    }

    func start(_ handler: @escaping @MainActor (ShortcutRecording.Input) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func send(_ input: ShortcutRecording.Input) {
        handler?(input)
    }

    func pressKey(_ keyCode: UInt16, _ modifiers: ShortcutModifiers, label: String) {
        send(.keyDown(keyCode: keyCode, modifiers: modifiers, label: label, isRepeat: false))
    }

    func tapFn() {
        send(.flagsChanged(keyCode: KeyCode.function, modifiers: [], fnDown: true))
        send(.flagsChanged(keyCode: KeyCode.function, modifiers: [], fnDown: false))
    }
}

@MainActor
final class FakeSystemShortcuts: SystemShortcutProviding {
    var shortcuts: Set<SystemShortcut> = []
    private(set) var readCount = 0

    func enabledShortcuts() -> Set<SystemShortcut> {
        readCount += 1
        return shortcuts
    }
}

/// Returns at once (so polling loops advance) and honours cancellation.
final class YieldingSleeper: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var sleepCount: Int {
        lock.withLock { count }
    }

    func sleep(seconds: Double) async throws {
        lock.withLock { count += 1 }
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
    }
}

@MainActor
final class FakeActivationPolicy: ActivationPolicyApplying {
    var isActive = false
    var refuse = false
    private(set) var changes: [Bool] = []
    private(set) var reactivations = 0

    func setShowsDockIcon(_ show: Bool) -> Bool {
        guard !refuse else { return false }
        changes.append(show)
        return true
    }

    func reactivate() {
        reactivations += 1
    }
}

@MainActor
struct ShortcutHarness {
    let settings: AppSettings
    let hotKeys = FakeHotKeys()
    let fnMonitor = FakeFnMonitor()
    let keyEvents = FakeKeyEvents()
    let systemShortcuts = FakeSystemShortcuts()
    let sleeper = YieldingSleeper()
    let trust: TrustFlag
    let toggles: ToggleCounter
    let controller: ShortcutController

    static let toggleID: UInt32 = 1

    @MainActor
    final class TrustFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    @MainActor
    final class ToggleCounter {
        var count = 0
    }

    init(store: KeyValueStoring = InMemoryKeyValueStore(), trusted: Bool = true) {
        let settings = AppSettings(store: store)
        let trust = TrustFlag(trusted)
        let toggles = ToggleCounter()
        self.settings = settings
        self.trust = trust
        self.toggles = toggles
        controller = ShortcutController(
            settings: settings,
            hotKeys: hotKeys,
            hotKeyID: Self.toggleID,
            fnMonitor: fnMonitor,
            keyEvents: keyEvents,
            systemShortcuts: systemShortcuts,
            isTrusted: { trust.value },
            sleeper: sleeper,
            permissionPollInterval: 0,
            onToggle: { toggles.count += 1 }
        )
    }
}

let optionSpace = KeyCombo(keyCode: KeyCode.space, modifiers: [.option], keyLabel: "Space")
let controlOptionD = KeyCombo(keyCode: 0x02, modifiers: [.control, .option], keyLabel: "D")
