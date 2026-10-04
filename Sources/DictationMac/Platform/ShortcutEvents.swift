import AppKit
import Carbon.HIToolbox
import DictationCore

/// Converts AppKit key events into the small amount of information the shortcut
/// logic needs: key code, modifier keys and a printable key name.
enum KeyEventTranslation {
    /// ⌘⌥⌃⇧ only. Caps Lock, fn and the numeric-pad flag are deliberately ignored.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "↩",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "esc",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_Help): "Help",
        UInt16(kVK_JIS_Eisu): "英数",
        UInt16(kVK_JIS_Kana): "かな",
    ]

    /// Name shown for a key, using the current layout's character when it is printable.
    static func label(keyCode: UInt16, characters: String?) -> String {
        if let name = KeyCode.functionKeyNames[keyCode] ?? specialKeyNames[keyCode] {
            return name
        }
        let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if !text.isEmpty {
            return text.uppercased()
        }
        return "Key \(keyCode)"
    }

    static func recordingInput(from event: NSEvent) -> ShortcutRecording.Input? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.type {
        case .keyDown:
            return .keyDown(
                keyCode: event.keyCode,
                modifiers: modifiers(flags),
                label: label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers),
                isRepeat: event.isARepeat
            )
        case .flagsChanged:
            return .flagsChanged(keyCode: event.keyCode, modifiers: modifiers(flags), fnDown: flags.contains(.function))
        default:
            return nil
        }
    }
}

// MARK: - fn / Globe tap monitor

@MainActor
public protocol FnKeyMonitoring: AnyObject {
    var isRunning: Bool { get }
    func start(onTap: @escaping @MainActor () -> Void)
    func stop()
}

/// Watches fn / Globe by observing modifier-change events only (no typed characters).
///
/// - A global monitor sees events sent to other apps. Per Apple's documentation,
///   key-related events reach it only while this app is trusted for Accessibility.
/// - A local monitor covers this app's own windows.
/// - Monitors only observe: macOS still performs its own fn / Globe action.
/// - Whether another key, click or scroll happened during the press comes from
///   `CGEventSource.secondsSinceLastEventType`, which reports only elapsed time.
@MainActor
public final class FnKeyMonitor: FnKeyMonitoring {
    private var monitors: [Any] = []
    private var detector = FnTapDetector()
    private var onTap: (@MainActor () -> Void)?
    private var confirmTask: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool {
        !monitors.isEmpty
    }

    public func start(onTap: @escaping @MainActor () -> Void) {
        stop()
        self.onTap = onTap
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let change = FlagsChange(event)
            Self.onMain { self?.handle(change) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let change = FlagsChange(event)
            Self.onMain { self?.handle(change) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    public func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        confirmTask?.cancel()
        confirmTask = nil
        detector.reset()
        onTap = nil
    }

    /// The parts of a modifier-change event the detector needs.
    struct FlagsChange: Sendable {
        var keyCode: UInt16
        var fnDown: Bool
        var otherModifiers: ShortcutModifiers
        var timestamp: TimeInterval

        init(keyCode: UInt16, fnDown: Bool, otherModifiers: ShortcutModifiers, timestamp: TimeInterval) {
            self.keyCode = keyCode
            self.fnDown = fnDown
            self.otherModifiers = otherModifiers
            self.timestamp = timestamp
        }

        init(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self.init(
                keyCode: event.keyCode,
                fnDown: flags.contains(.function),
                otherModifiers: KeyEventTranslation.modifiers(flags),
                timestamp: event.timestamp
            )
        }
    }

    private func handle(_ change: FlagsChange) {
        let input: FnTapDetector.Input
        if change.keyCode == KeyCode.function {
            input = change.fnDown
                ? .fnDown(otherModifiers: change.otherModifiers, at: change.timestamp)
                : .fnUp(otherModifiers: change.otherModifiers, at: change.timestamp, lastOtherInputAt: Self.lastOtherInputTime())
        } else {
            input = .modifiersChanged(otherModifiers: change.otherModifiers, at: change.timestamp)
        }
        perform(detector.handle(input))
    }

    private func perform(_ action: FnTapDetector.Action) {
        switch action {
        case .none:
            break
        case .fire:
            onTap?()
        case .confirmAt(let time):
            confirmTask?.cancel()
            let delay = max(0, time - ProcessInfo.processInfo.systemUptime)
            confirmTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.perform(self.detector.confirm(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    /// When the most recent key press, click or scroll happened (uptime clock).
    static func lastOtherInputTime() -> TimeInterval? {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let ages = types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
        guard let youngest = ages.min() else { return nil }
        return ProcessInfo.processInfo.systemUptime - youngest
    }

    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }
}

// MARK: - Recorder input

/// Delivers key presses made in this app's own windows while the recorder listens.
@MainActor
public protocol ShortcutKeyEventSource: AnyObject {
    func start(_ handler: @escaping @MainActor (ShortcutRecording.Input) -> Void)
    func stop()
}

/// A local monitor only: it never sees typing in other apps and is removed as soon
/// as recording ends. Key presses are swallowed so they do not reach the window.
@MainActor
public final class LocalShortcutKeyEventSource: ShortcutKeyEventSource {
    private var monitor: Any?

    public init() {}

    public func start(_ handler: @escaping @MainActor (ShortcutRecording.Input) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard let input = KeyEventTranslation.recordingInput(from: event) else { return event }
            MainActor.assumeIsolated { handler(input) }
            return event.type == .keyDown ? nil : event
        }
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - macOS shortcuts

@MainActor
public protocol SystemShortcutProviding: AnyObject {
    func enabledShortcuts() -> Set<SystemShortcut>
}

/// The system-wide shortcuts enabled in System Settings > Keyboard > Keyboard Shortcuts,
/// through Carbon `CopySymbolicHotKeys`. Read only when the recorder starts.
@MainActor
public final class CarbonSystemShortcuts: SystemShortcutProviding {
    public init() {}

    public func enabledShortcuts() -> Set<SystemShortcut> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        var result: Set<SystemShortcut> = []
        for entry in array {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  code >= 0, code < 0xFFFF,
                  let bits = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.intValue else {
                continue
            }
            result.insert(SystemShortcut(keyCode: UInt16(code), modifiers: CarbonModifiers.toShortcutModifiers(bits)))
        }
        return result
    }
}
