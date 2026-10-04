import Foundation

/// One run of the shortcut recorder in Settings. It sees only the key presses made
/// while the recorder is listening in this app's own window.
public struct ShortcutRecording: Sendable {
    public enum Input: Equatable, Sendable {
        case keyDown(keyCode: UInt16, modifiers: ShortcutModifiers, label: String, isRepeat: Bool)
        /// A modifier key changed. `fnDown` reports whether fn / Globe is held after the change.
        case flagsChanged(keyCode: UInt16, modifiers: ShortcutModifiers, fnDown: Bool)
    }

    public enum Outcome: Equatable, Sendable {
        /// Keep listening.
        case none
        case recorded(Shortcut)
        case cancelled
        /// Show the reason and keep listening.
        case rejected(ShortcutRejection)
    }

    private let systemShortcuts: Set<SystemShortcut>
    private var fnHeld = false
    private var fnAlone = false
    private var keyPressedDuringFn = false
    private var heldModifiers: ShortcutModifiers = []
    private var keyPressedWithModifiers = false

    public init(systemShortcuts: Set<SystemShortcut>) {
        self.systemShortcuts = systemShortcuts
    }

    public mutating func handle(_ input: Input) -> Outcome {
        switch input {
        case .flagsChanged(let keyCode, let modifiers, let fnDown):
            if keyCode == KeyCode.function {
                if fnDown && !fnHeld {
                    fnHeld = true
                    fnAlone = modifiers.isEmpty
                    keyPressedDuringFn = false
                    return .none
                }
                if !fnDown && fnHeld {
                    fnHeld = false
                    let alone = fnAlone && modifiers.isEmpty
                    fnAlone = false
                    if alone {
                        return .recorded(.fn)
                    }
                    // A key press already explained itself; fn with ⌘/⌥/⌃/⇧ did not.
                    return keyPressedDuringFn ? .none : .rejected(.fnCombination)
                }
                return .none
            }

            if fnHeld {
                fnAlone = false
            }
            if !modifiers.isEmpty {
                heldModifiers.formUnion(modifiers)
                return .none
            }
            // Every modifier is up again.
            defer {
                heldModifiers = []
                keyPressedWithModifiers = false
            }
            if !heldModifiers.isEmpty && !keyPressedWithModifiers && !fnHeld {
                return .rejected(.modifierOnly)
            }
            return .none

        case .keyDown(let keyCode, let modifiers, let label, let isRepeat):
            guard !isRepeat else { return .none }
            keyPressedWithModifiers = true
            if fnHeld {
                fnAlone = false
                keyPressedDuringFn = true
                // fn + F-key is how many Mac keyboards type F1–F20, so keep those.
                if !KeyCode.isFunctionKey(keyCode) {
                    return .rejected(.fnCombination)
                }
            } else if keyCode == KeyCode.escape && modifiers.isEmpty {
                return .cancelled
            }
            let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
            if let rejection = ShortcutValidator.validate(combo, systemShortcuts: systemShortcuts) {
                return .rejected(rejection)
            }
            return .recorded(.key(combo))
        }
    }
}
