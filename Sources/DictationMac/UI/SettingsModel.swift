import DictationCore
import Foundation
import Observation

/// State and actions behind the Settings window.
@MainActor
@Observable
public final class SettingsModel {
    public let settings: AppSettings
    public let keys: APIKeyManager
    @ObservationIgnored private let permissions: PermissionStatusProviding

    /// Text typed into the key field. Cleared after saving; the stored key is never shown.
    public var draftKey = ""
    public private(set) var keyMessage: String?
    public private(set) var keyMessageIsError = false
    public private(set) var microphoneStatus: MicrophoneAuthorization = .notDetermined
    /// `nil` until the user asks for a check. Querying Accessibility trust can make
    /// macOS list the app (switched off) in System Settings, so opening Settings alone
    /// does not do it.
    public private(set) var accessibilityTrusted: Bool?
    public var hotKeyRegistered = true

    public init(settings: AppSettings, keys: APIKeyManager, permissions: PermissionStatusProviding) {
        self.settings = settings
        self.keys = keys
        self.permissions = permissions
    }

    /// Reads the microphone status (a preflight that never prompts). Used when Settings opens.
    public func refreshMicrophoneStatus() {
        microphoneStatus = permissions.microphoneStatus()
    }

    /// Explicit "check" button: reads both permissions. Never shows a system prompt.
    public func checkPermissions() {
        refreshMicrophoneStatus()
        accessibilityTrusted = permissions.isAccessibilityTrusted()
    }

    public func saveKey() {
        let persist = settings.storeKeyInKeychain
        do {
            try keys.save(draftKey, persist: persist)
            draftKey = ""
            setKeyMessage(persist ? "キーチェーンに保存しました。" : "アプリを終了するまでメモリ上だけで保持します。", isError: false)
        } catch APIKeyInputError.empty {
            setKeyMessage("APIキーを入力してください。", isError: true)
        } catch APIKeyInputError.containsWhitespace {
            setKeyMessage("APIキーに空白や改行が含まれています。", isError: true)
        } catch let error as KeychainError {
            setKeyMessage("キーチェーンに保存できませんでした（OSStatus \(error.status)）。", isError: true)
        } catch {
            setKeyMessage("APIキーを保存できませんでした。", isError: true)
        }
    }

    /// Called when the "store in Keychain" switch changes.
    public func keychainSwitchChanged(to persist: Bool) {
        do {
            switch try keys.applyPersistence(persist) {
            case .unchanged:
                break
            case .savedToKeychain:
                setKeyMessage("キーチェーンに保存しました。", isError: false)
            case .keptInMemoryOnly:
                setKeyMessage("キーチェーンから削除しました。キーはアプリを終了するまでメモリ上だけで保持します。", isError: false)
            case .removed:
                setKeyMessage("キーチェーンから削除しました。APIキーをもう一度入力してください。", isError: false)
            }
        } catch let error as KeychainError {
            setKeyMessage("キーチェーンを更新できませんでした（OSStatus \(error.status)）。", isError: true)
        } catch {
            setKeyMessage("キーチェーンを更新できませんでした。", isError: true)
        }
    }

    public func removeKey() {
        do {
            try keys.remove()
            setKeyMessage("APIキーを削除しました。", isError: false)
        } catch let error as KeychainError {
            setKeyMessage("キーチェーンから削除できませんでした（OSStatus \(error.status)）。", isError: true)
        } catch {
            setKeyMessage("APIキーを削除できませんでした。", isError: true)
        }
    }

    /// Explicit user action: shows the system Accessibility prompt.
    public func requestAccessibility() {
        permissions.requestAccessibility()
        checkPermissions()
    }

    public func open(_ pane: SystemSettingsPane) {
        permissions.open(pane)
    }

    public var keyStatusText: String {
        switch keys.status {
        case .notSet: return "未設定"
        case .sessionOnly: return "設定済み（このセッションのみ）"
        case .savedInKeychain: return "設定済み（キーチェーンに保存）"
        }
    }

    public var microphoneStatusText: String {
        switch microphoneStatus {
        case .authorized: return "許可済み"
        case .notDetermined: return "未確認（最初の録音時に確認します）"
        case .denied: return "拒否されています"
        case .restricted: return "制限されています"
        }
    }

    public var accessibilityStatusText: String {
        switch accessibilityTrusted {
        case .none: return "未確認"
        case .some(true): return "許可済み（自動入力できます）"
        case .some(false): return "未許可（結果はコピーで受け取ります）"
        }
    }

    private func setKeyMessage(_ message: String, isError: Bool) {
        keyMessage = message
        keyMessageIsError = isError
    }
}
