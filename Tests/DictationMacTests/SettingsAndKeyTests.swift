import DictationCore
import Foundation
import Security
import Testing
@testable import DictationMac

@MainActor
@Suite("Settings and API key handling")
struct SettingsAndKeyTests {
    @Test func defaultsAreSafeAndCheap() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        #expect(settings.selectedModel.id == ModelCatalog.defaultModelID)
        #expect(settings.shortcut == .fn)
        #expect(!settings.showInDock)
        #expect(settings.storeKeyInKeychain)
        #expect(!settings.keySavedInKeychain)
    }

    @Test func preferencesPersistAcrossLaunches() {
        let store = InMemoryKeyValueStore()
        let first = AppSettings(store: store)
        first.modelSelection = "gemini-3.8-flash"
        first.shortcut = .key(controlOptionD)
        first.showInDock = true
        first.storeKeyInKeychain = false

        let second = AppSettings(store: store)
        #expect(second.selectedModel.id == "gemini-3.8-flash")
        #expect(second.shortcut == .key(controlOptionD))
        #expect(second.showInDock)
        #expect(!second.storeKeyInKeychain)
    }

    @Test func customModelFallsBackUntilTheIDIsValid() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.modelSelection = AppSettings.customModelTag
        settings.customModelID = "gemini 9"
        #expect(settings.validCustomModelID == nil)
        #expect(settings.selectedModel.id == ModelCatalog.defaultModelID)

        settings.customModelID = "models/gemini-9.0-flash"
        #expect(settings.selectedModel.id == "gemini-9.0-flash")
    }

    @Test func unknownStoredModelFallsBackToTheDefault() {
        let store = InMemoryKeyValueStore()
        store.set("gemini-2.0-flash", forKey: "modelSelection")
        #expect(AppSettings(store: store).selectedModel.id == ModelCatalog.defaultModelID)
    }

    @Test func secretsNeverGoToPreferences() throws {
        let store = InMemoryKeyValueStore()
        let settings = AppSettings(store: store)
        let keys = APIKeyManager(store: InMemorySecretStore(), settings: settings)
        try keys.save("synthetic-test-secret-value", persist: true)
        settings.shortcut = .key(controlOptionD)
        settings.showInDock = true
        for key in ["modelSelection", "customModelID", "shortcut", "showInDock", "storeAPIKeyInKeychain", "apiKeySavedInKeychain"] {
            let value = store.object(forKey: key)
            let text = (value as? String) ?? (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(!text.contains("synthetic-test-secret"))
        }
        #expect(store.object(forKey: "apiKeySavedInKeychain") as? Bool == true)
    }

    @Test func keychainIsNotReadUntilAKeyIsNeededAndSaved() throws {
        let secrets = InMemorySecretStore(secret: "left-over")
        let keys = APIKeyManager(store: secrets, settings: AppSettings(store: InMemoryKeyValueStore()))
        #expect(try keys.apiKey() == nil)
        #expect(secrets.readCount == 0)
        #expect(keys.status == .notSet)
    }

    @Test func savedKeyIsReadOnceThenCached() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.keySavedInKeychain = true
        let secrets = InMemorySecretStore(secret: "stored-key")
        let keys = APIKeyManager(store: secrets, settings: settings)
        #expect(keys.status == .savedInKeychain)
        #expect(try keys.apiKey() == "stored-key")
        #expect(try keys.apiKey() == "stored-key")
        #expect(secrets.readCount == 1)
    }

    @Test func missingKeychainItemResetsTheMarker() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.keySavedInKeychain = true
        let keys = APIKeyManager(store: InMemorySecretStore(), settings: settings)
        #expect(try keys.apiKey() == nil)
        #expect(!settings.keySavedInKeychain)
    }

    @Test func persistentSaveTrimsAndStores() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let secrets = InMemorySecretStore()
        let keys = APIKeyManager(store: secrets, settings: settings)
        try keys.save("  key-123\n", persist: true)
        #expect(secrets.secret == "key-123")
        #expect(keys.status == .savedInKeychain)
        #expect(try keys.apiKey() == "key-123")
    }

    @Test func sessionOnlyKeyNeverTouchesTheKeychain() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let secrets = InMemorySecretStore()
        let keys = APIKeyManager(store: secrets, settings: settings)
        try keys.save("session-key", persist: false)
        #expect(secrets.secret == nil)
        #expect(keys.status == .sessionOnly)
        #expect(try keys.apiKey() == "session-key")
    }

    @Test func switchingToSessionOnlyDeletesTheStoredCopy() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let secrets = InMemorySecretStore()
        let keys = APIKeyManager(store: secrets, settings: settings)
        try keys.save("first", persist: true)
        try keys.save("second", persist: false)
        #expect(secrets.secret == nil)
        #expect(!settings.keySavedInKeychain)
        #expect(try keys.apiKey() == "second")
    }

    @Test func switchingOffKeepsALoadedKeyInMemoryOnly() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let secrets = InMemorySecretStore()
        let keys = APIKeyManager(store: secrets, settings: settings)
        try keys.save("key", persist: true)
        #expect(try keys.applyPersistence(false) == .keptInMemoryOnly)
        #expect(secrets.secret == nil)
        #expect(keys.status == .sessionOnly)
        #expect(try keys.apiKey() == "key")
    }

    @Test func switchingOffAnUnloadedKeyDeletesItWithoutReadingIt() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.keySavedInKeychain = true
        let secrets = InMemorySecretStore(secret: "stored")
        let keys = APIKeyManager(store: secrets, settings: settings)
        #expect(try keys.applyPersistence(false) == .removed)
        #expect(secrets.readCount == 0)
        #expect(secrets.secret == nil)
        #expect(keys.status == .notSet)
    }

    @Test func switchingOnSavesTheSessionKey() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let secrets = InMemorySecretStore()
        let keys = APIKeyManager(store: secrets, settings: settings)
        try keys.save("session", persist: false)
        #expect(try keys.applyPersistence(true) == .savedToKeychain)
        #expect(secrets.secret == "session")
        #expect(keys.status == .savedInKeychain)
    }

    @Test func switchingWithoutAKeyChangesNothing() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let secrets = InMemorySecretStore()
        let keys = APIKeyManager(store: secrets, settings: settings)
        #expect(try keys.applyPersistence(true) == .unchanged)
        #expect(try keys.applyPersistence(false) == .unchanged)
        #expect(secrets.secret == nil)
    }

    @Test func removeClearsEverything() throws {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let secrets = InMemorySecretStore()
        let keys = APIKeyManager(store: secrets, settings: settings)
        try keys.save("key", persist: true)
        try keys.remove()
        #expect(secrets.secret == nil)
        #expect(keys.status == .notSet)
        #expect(try keys.apiKey() == nil)
    }

    @Test func rejectsEmptyAndSpacedKeys() {
        let keys = APIKeyManager(store: InMemorySecretStore(), settings: AppSettings(store: InMemoryKeyValueStore()))
        #expect(throws: APIKeyInputError.empty) { try keys.save("  ", persist: false) }
        #expect(throws: APIKeyInputError.containsWhitespace) { try keys.save("ab cd", persist: false) }
        #expect(keys.status == .notSet)
    }

    /// The Keychain query is checked as data only; the real Keychain is never accessed in tests.
    @Test func keychainQueryOnlyAddressesThisAppsItem() {
        let store = KeychainSecretStore(service: AppInfo.bundleIdentifier)
        let query = store.baseQuery
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "io.github.yheihei.GeminiDictation")
        #expect(query[kSecAttrAccount as String] as? String == "gemini-api-key")
        #expect(query[kSecAttrSynchronizable as String] == nil)
        #expect(query.count == 3)
    }
}

@MainActor
final class FakePermissionProvider: PermissionStatusProviding {
    var microphone: MicrophoneAuthorization = .notDetermined
    var trusted = false
    private(set) var accessibilityChecks = 0
    private(set) var accessibilityRequests = 0
    private(set) var opened: [SystemSettingsPane] = []

    func microphoneStatus() -> MicrophoneAuthorization { microphone }
    func isAccessibilityTrusted() -> Bool {
        accessibilityChecks += 1
        return trusted
    }
    func requestAccessibility() { accessibilityRequests += 1 }
    func open(_ pane: SystemSettingsPane) { opened.append(pane) }
}

@MainActor
@Suite("Settings window model")
struct SettingsModelTests {
    func makeModel(_ permissions: FakePermissionProvider = FakePermissionProvider()) -> (SettingsModel, InMemorySecretStore) {
        let harness = ShortcutHarness()
        let secrets = InMemorySecretStore()
        let model = SettingsModel(
            settings: harness.settings,
            keys: APIKeyManager(store: secrets, settings: harness.settings),
            permissions: permissions,
            shortcuts: harness.controller
        )
        return (model, secrets)
    }

    @Test func savingClearsTheFieldAndNeverShowsTheKey() {
        let (model, secrets) = makeModel()
        model.draftKey = "secret-value"
        model.saveKey()
        #expect(model.draftKey.isEmpty)
        #expect(secrets.secret == "secret-value")
        #expect(model.keyMessageIsError == false)
        #expect(model.keyMessage?.contains("secret-value") == false)
        #expect(model.keyStatusText == "設定済み（キーチェーンに保存）")
    }

    @Test func keychainSwitchExplainsWhatHappened() {
        let (model, secrets) = makeModel()
        model.draftKey = "secret-value"
        model.saveKey()
        model.settings.storeKeyInKeychain = false
        model.keychainSwitchChanged(to: false)
        #expect(secrets.secret == nil)
        #expect(model.keyMessage == "キーチェーンから削除しました。キーはアプリを終了するまでメモリ上だけで保持します。")
        #expect(model.keyStatusText == "設定済み（このセッションのみ）")
    }

    @Test func emptyInputShowsAnError() {
        let (model, _) = makeModel()
        model.draftKey = "   "
        model.saveKey()
        #expect(model.keyMessageIsError)
        #expect(model.keyStatusText == "未設定")
    }

    @Test func openingSettingsOnlyReadsTheMicrophoneStatus() {
        let permissions = FakePermissionProvider()
        permissions.microphone = .denied
        let (model, _) = makeModel(permissions)
        model.refreshMicrophoneStatus()
        #expect(model.microphoneStatus == .denied)
        #expect(model.accessibilityTrusted == nil)
        #expect(model.accessibilityStatusText == "未確認")
        #expect(permissions.accessibilityChecks == 0)
        #expect(permissions.accessibilityRequests == 0)
    }

    @Test func explicitCheckReadsAccessibilityWithoutPrompting() {
        let permissions = FakePermissionProvider()
        let (model, _) = makeModel(permissions)
        model.checkPermissions()
        #expect(permissions.accessibilityChecks == 1)
        #expect(permissions.accessibilityRequests == 0)
        #expect(model.accessibilityTrusted == false)

        permissions.trusted = true
        model.checkPermissions()
        #expect(model.accessibilityStatusText == "許可済み（自動入力できます）")
    }

    @Test func accessibilityIsRequestedOnlyOnExplicitAction() {
        let permissions = FakePermissionProvider()
        let (model, _) = makeModel(permissions)
        model.refreshMicrophoneStatus()
        #expect(permissions.accessibilityRequests == 0)
        model.requestAccessibility()
        #expect(permissions.accessibilityRequests == 1)
        model.open(.microphone)
        #expect(permissions.opened == [.microphone])
    }
}
