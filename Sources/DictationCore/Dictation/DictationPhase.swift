import Foundation

public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case processing(attempt: Int)
    /// Text was pasted into the original target.
    case inserted
    /// A transcript exists but was not inserted automatically; offer copy instead.
    case resultReady(ResultReason)
    case failed(DictationFailure)
    case notice(DictationNotice)

    public var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    public var isBusy: Bool {
        self == .recording || isProcessing
    }
}

public enum ResultReason: Equatable, Sendable {
    case noTarget
    case appChanged(String?)
    case focusChanged
    case focusUnknown
    case secureField
    case accessibilityNotGranted
    case clipboardNotPreservable
    case insertionFailed

    public var message: String {
        switch self {
        case .noTarget:
            return "貼り付け先のアプリがないため、自動入力しませんでした。"
        case .appChanged(let name):
            if let name {
                return "録音開始後に前面のアプリが変わったため（現在: \(name)）、自動入力しませんでした。"
            }
            return "録音開始後に前面のアプリが変わったため、自動入力しませんでした。"
        case .focusChanged:
            return "録音開始後に入力欄のフォーカスが変わったため、自動入力しませんでした。"
        case .focusUnknown:
            return "入力欄を特定できず、同じ欄か確かめられないため、自動入力しませんでした。"
        case .secureField:
            return "パスワード欄には自動入力しません。"
        case .accessibilityNotGranted:
            return "自動入力にはアクセシビリティの許可が必要です（設定画面から許可できます）。"
        case .clipboardNotPreservable:
            return "今のクリップボードの内容を完全には退避できないため、自動入力しませんでした。クリップボードはそのままです。"
        case .insertionFailed:
            return "自動入力に失敗しました。"
        }
    }

    init(_ error: InsertionError) {
        switch error {
        case .notPermitted: self = .accessibilityNotGranted
        case .targetChanged: self = .focusChanged
        case .secureField: self = .secureField
        case .eventPostingFailed: self = .insertionFailed
        case .clipboardNotPreservable: self = .clipboardNotPreservable
        }
    }
}

public enum DictationFailure: Equatable, Sendable {
    case missingAPIKey
    case apiKeyUnavailable
    case microphoneDenied
    case recordingFailed
    /// A long recording could not be compressed for sending. The original is kept for a retry.
    case audioConversionFailed
    case transcription(GeminiError)
    case unexpected(String)

    public var message: String {
        switch self {
        case .missingAPIKey:
            return "Gemini APIキーが設定されていません。設定画面で入力してください。"
        case .apiKeyUnavailable:
            return "キーチェーンからAPIキーを読み込めませんでした。設定画面で入力し直してください。"
        case .microphoneDenied:
            return "マイクの使用が許可されていません。システム設定の「プライバシーとセキュリティ」>「マイク」で許可してください。"
        case .recordingFailed:
            return "録音を開始または継続できませんでした。入力デバイスを確認してください。"
        case .audioConversionFailed:
            return "録音を送信用に圧縮できませんでした。再試行してください。"
        case .transcription(let error):
            return error.userMessage
        case .unexpected(let detail):
            return "予期しないエラーが発生しました（\(detail)）。"
        }
    }

    public var detail: String? {
        if case .transcription(let error) = self { return error.serverMessage }
        return nil
    }

    public var needsSettings: Bool {
        switch self {
        case .missingAPIKey, .apiKeyUnavailable:
            return true
        case .transcription(let error):
            return error.needsSettingsChange
        default:
            return false
        }
    }

    public var needsMicrophoneSettings: Bool {
        self == .microphoneDenied
    }
}

public enum DictationNotice: Equatable, Sendable {
    /// Cancelled while recording: the audio was discarded and never sent.
    case recordingDiscarded
    /// Cancelled while waiting for Gemini: any late result is ignored.
    case processingCancelled
    case microphoneGranted
    case tooShort
    case silence
    case noSpeechRecognized
    case copied

    public var message: String {
        switch self {
        case .recordingDiscarded:
            return "録音を破棄しました。音声は送信していません。"
        case .processingCancelled:
            return "キャンセルしました。結果は入力しません。"
        case .microphoneGranted:
            return "マイクが許可されました。もう一度ショートカットを押すと録音を開始します。"
        case .tooShort:
            return "録音が短すぎるため送信しませんでした。"
        case .silence:
            return "音声が検出されなかったため送信しませんでした。マイクの入力を確認してください。"
        case .noSpeechRecognized:
            return "音声を認識できませんでした。"
        case .copied:
            return "クリップボードにコピーしました。"
        }
    }
}
