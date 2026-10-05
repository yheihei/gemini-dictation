import Foundation

/// Modifier keys that can be part of a key shortcut. fn / Globe is handled separately.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// Symbols in the order macOS menus use: ⌃⌥⇧⌘.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// macOS virtual key codes (values of the `kVK_*` constants in HIToolbox `Events.h`).
public enum KeyCode {
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let grave: UInt16 = 0x32
    public static let escape: UInt16 = 0x35
    /// fn / Globe. Reported only through modifier-change events, never as a key press.
    public static let function: UInt16 = 0x3F
    public static let ansi3: UInt16 = 0x14
    public static let ansi4: UInt16 = 0x15
    public static let ansi6: UInt16 = 0x16
    public static let ansi5: UInt16 = 0x17
    public static let ansiQ: UInt16 = 0x0C
    public static let jisEisu: UInt16 = 0x66
    public static let jisKana: UInt16 = 0x68

    public static let functionKeyNames: [UInt16: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeyNames[keyCode] != nil
    }
}

/// A key plus modifiers, registered as a Carbon hot key.
public struct KeyCombo: Hashable, Sendable, Codable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    /// Key name captured when the shortcut was recorded (it depends on the keyboard
    /// layout at that moment), for example "Space", "D" or "F13".
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var displayName: String {
        modifiers.isEmpty ? keyLabel : "\(modifiers.symbols) \(keyLabel)"
    }
}

/// What starts and stops a recording.
public enum Shortcut: Hashable, Sendable {
    /// fn / Globe を0.5秒長押しして開始する。録音中は短押しでも停止する。
    case fn
    case key(KeyCombo)

    public static let `default` = Shortcut.fn

    public var displayName: String {
        switch self {
        case .fn: return "fn 長押し"
        case .key(let combo): return combo.displayName
        }
    }
}

extension Shortcut: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case combo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "fn":
            self = .fn
        case "key":
            self = .key(try container.decode(KeyCombo.self, forKey: .combo))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown shortcut kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fn:
            try container.encode("fn", forKey: .kind)
        case .key(let combo):
            try container.encode("key", forKey: .kind)
            try container.encode(combo, forKey: .combo)
        }
    }
}
