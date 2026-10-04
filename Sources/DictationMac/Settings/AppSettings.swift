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
        static let hotKeyPreset = "hotKeyPreset"
        static let storeKeyInKeychain = "storeAPIKeyInKeychain"
        static let keySavedInKeychain = "apiKeySavedInKeychain"
    }

    @ObservationIgnored private let store: KeyValueStoring
    @ObservationIgnored public var onHotKeyPresetChange: (@MainActor (HotKeyPreset) -> Void)?

    /// A preset model ID, or `customModelTag`.
    public var modelSelection: String {
        didSet { store.set(modelSelection, forKey: Keys.modelSelection) }
    }

    public var customModelID: String {
        didSet { store.set(customModelID, forKey: Keys.customModelID) }
    }

    public var hotKeyPreset: HotKeyPreset {
        didSet {
            store.set(hotKeyPreset.rawValue, forKey: Keys.hotKeyPreset)
            if hotKeyPreset != oldValue { onHotKeyPresetChange?(hotKeyPreset) }
        }
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
        hotKeyPreset = (store.object(forKey: Keys.hotKeyPreset) as? String).flatMap(HotKeyPreset.init(rawValue:)) ?? .optionSpace
        storeKeyInKeychain = store.object(forKey: Keys.storeKeyInKeychain) as? Bool ?? true
        keySavedInKeychain = store.object(forKey: Keys.keySavedInKeychain) as? Bool ?? false
    }

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
