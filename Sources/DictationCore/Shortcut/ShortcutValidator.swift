import Foundation

/// Why a shortcut cannot be used.
public enum ShortcutRejection: Equatable, Sendable {
    case modifierOnly
    case needsModifier
    case fnCombination
    case reservedKey
    case appStandardShortcut
    case systemShortcut
    case registrationFailed

    public var message: String {
        switch self {
        case .modifierOnly:
            return "修飾キーだけのショートカットは使えません（fn を除く）。⌘・⌥・⌃ とほかのキーを一緒に押してください。"
        case .needsModifier:
            return "⌘・⌥・⌃ のいずれかと組み合わせてください（F1〜F20 は単独でも使えます）。"
        case .fnCombination:
            return "fn とほかのキーの組み合わせは使えません。fn だけを押して離すか、⌘・⌥・⌃ との組み合わせにしてください。"
        case .reservedKey:
            return "esc・英数・かなのキーは使えません。"
        case .appStandardShortcut:
            return "⌘ だけとの組み合わせは、ほかのアプリのショートカット（コピーやペーストなど）と重なるため使えません。"
        case .systemShortcut:
            return "macOS のショートカットと重なるため使えません。別の組み合わせを押してください。"
        case .registrationFailed:
            return "このショートカットを登録できませんでした。別の組み合わせを試してください。"
        }
    }
}

/// A key combination already taken by macOS.
public struct SystemShortcut: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum ShortcutValidator {
    /// Keys that switch input methods or that this app uses for cancel.
    static let reservedKeys: Set<UInt16> = [KeyCode.escape, KeyCode.jisEisu, KeyCode.jisKana]

    /// Combinations macOS uses by default even when they are not listed as enabled
    /// symbolic hot keys (app switching, input sources, Spotlight, screenshots, emoji).
    static let builtInSystemShortcuts: Set<SystemShortcut> = [
        SystemShortcut(keyCode: KeyCode.tab, modifiers: [.command, .shift]),
        SystemShortcut(keyCode: KeyCode.space, modifiers: [.control]),
        SystemShortcut(keyCode: KeyCode.space, modifiers: [.control, .option]),
        SystemShortcut(keyCode: KeyCode.space, modifiers: [.command, .option]),
        SystemShortcut(keyCode: KeyCode.space, modifiers: [.control, .command]),
        SystemShortcut(keyCode: KeyCode.ansi3, modifiers: [.command, .shift]),
        SystemShortcut(keyCode: KeyCode.ansi4, modifiers: [.command, .shift]),
        SystemShortcut(keyCode: KeyCode.ansi5, modifiers: [.command, .shift]),
        SystemShortcut(keyCode: KeyCode.ansi6, modifiers: [.command, .shift]),
        SystemShortcut(keyCode: KeyCode.ansiQ, modifiers: [.control, .command]),
    ]

    /// Returns why `combo` cannot be used, or `nil` if it is acceptable.
    /// `systemShortcuts` are the shortcuts currently enabled in System Settings.
    public static func validate(_ combo: KeyCombo, systemShortcuts: Set<SystemShortcut>) -> ShortcutRejection? {
        if reservedKeys.contains(combo.keyCode) {
            return .reservedKey
        }
        let primary = combo.modifiers.intersection([.command, .option, .control])
        if primary.isEmpty && !KeyCode.isFunctionKey(combo.keyCode) {
            return .needsModifier
        }
        if combo.modifiers == [.command] && !KeyCode.isFunctionKey(combo.keyCode) {
            return .appStandardShortcut
        }
        let candidate = SystemShortcut(keyCode: combo.keyCode, modifiers: combo.modifiers)
        if builtInSystemShortcuts.contains(candidate) || systemShortcuts.contains(candidate) {
            return .systemShortcut
        }
        return nil
    }
}
