import DictationCore
import Foundation
import Observation

/// Minimal key-value storage so tests and UI snapshots can avoid real UserDefaults.
public protocol KeyValueStoring: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStoring {}

public final class InMemoryKeyValueStore: KeyValueStoring {
    private var storage: [String: Any] = [:]

    public init() {}

    public func object(forKey key: String) -> Any? {
        storage[key]
    }

    public func set(_ value: Any?, forKey key: String) {
        storage[key] = value
    }
}

/// Non-secret preferences. The API key itself is never stored here.
@MainActor
@Observable
public final class AppSettings: ModelProviding {
    public static let customModelTag = "custom"

    enum Keys {
        static let modelSelection = "modelSelection"
        static let customModelID = "customModelID"
        static let shortcut = "shortcut"
        /// Written by version 0.1 when the user picked a preset. Read for migration only
        /// and left in place, so 0.1 keeps its choice if the user goes back to it.
        static let legacyHotKeyPreset = "hotKeyPreset"
        static let showInDock = "showInDock"
        static let storeKeyInKeychain = "storeAPIKeyInKeychain"
        static let keySavedInKeychain = "apiKeySavedInKeychain"
    }

    @ObservationIgnored private let store: KeyValueStoring

    /// A preset model ID, or `customModelTag`.
    public var modelSelection: String {
        didSet { store.set(modelSelection, forKey: Keys.modelSelection) }
    }

    public var customModelID: String {
        didSet { store.set(customModelID, forKey: Keys.customModelID) }
    }

    /// Starts and stops a recording. Changed only through `ShortcutController`,
    /// which registers the new shortcut before saving it.
    public internal(set) var shortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                store.set(data, forKey: Keys.shortcut)
            }
        }
    }

    /// Show a Dock icon (regular app) instead of running from the menu bar only.
    public var showInDock: Bool {
        didSet { store.set(showInDock, forKey: Keys.showInDock) }
    }

    /// Whether a newly saved key goes to the Keychain (otherwise memory only).
    public var storeKeyInKeychain: Bool {
        didSet { store.set(storeKeyInKeychain, forKey: Keys.storeKeyInKeychain) }
    }

    /// Marker that a key was saved to the Keychain, so the Keychain is only read
    /// when a key is actually needed (no prompt just for launching or opening Settings).
    public var keySavedInKeychain: Bool {
        didSet { store.set(keySavedInKeychain, forKey: Keys.keySavedInKeychain) }
    }

    public init(store: KeyValueStoring = UserDefaults.standard) {
        self.store = store
        modelSelection = store.object(forKey: Keys.modelSelection) as? String ?? ModelCatalog.defaultModelID
        customModelID = store.object(forKey: Keys.customModelID) as? String ?? ""
        shortcut = Self.loadShortcut(from: store)
        showInDock = store.object(forKey: Keys.showInDock) as? Bool ?? false
        storeKeyInKeychain = store.object(forKey: Keys.storeKeyInKeychain) as? Bool ?? true
        keySavedInKeychain = store.object(forKey: Keys.keySavedInKeychain) as? Bool ?? false
    }

    /// The saved shortcut; otherwise a preset the user explicitly picked in 0.1;
    /// otherwise the default (fn). 0.1 saved a preset only when the user chose one,
    /// so users who kept its old default (⌥ Space) move to fn.
    static func loadShortcut(from store: KeyValueStoring) -> Shortcut {
        if let data = store.object(forKey: Keys.shortcut) as? Data,
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            return saved
        }
        if let legacy = store.object(forKey: Keys.legacyHotKeyPreset) as? String,
           let modifiers = legacyPresetModifiers[legacy] {
            return .key(KeyCombo(keyCode: KeyCode.space, modifiers: modifiers, keyLabel: "Space"))
        }
        return .default
    }

    /// The presets offered by 0.1, all on the space bar.
    static let legacyPresetModifiers: [String: ShortcutModifiers] = [
        "optionSpace": [.option],
        "optionShiftSpace": [.option, .shift],
        "controlShiftSpace": [.control, .shift],
        "controlOptionCommandSpace": [.control, .option, .command],
    ]

    public var isCustomModel: Bool {
        modelSelection == Self.customModelTag
    }

    /// `nil` when "custom" is selected but the typed model ID is not valid.
    public var validCustomModelID: String? {
        ModelCatalog.normalizedModelID(customModelID)
    }

    public var selectedModel: GeminiModel {
        if isCustomModel {
            if let id = validCustomModelID {
                return ModelCatalog.model(for: id)
            }
        } else if let preset = ModelCatalog.presets.first(where: { $0.id == modelSelection }) {
            return preset
        }
        return ModelCatalog.model(for: ModelCatalog.defaultModelID)
    }
}
