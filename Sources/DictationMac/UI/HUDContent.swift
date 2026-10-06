import DictationCore
import Foundation

public enum HUDAction: String, Hashable, Sendable, Identifiable {
    case stop
    case cancel
    case copy
    case retry
    case openSettings
    case openMicrophoneSettings
    case openAccessibilitySettings
    case dismiss

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stop: return "停止して送信"
        case .cancel: return "キャンセル"
        case .copy: return "コピー"
        case .retry: return "再試行"
        case .openSettings: return "設定を開く"
        case .openMicrophoneSettings: return "マイク設定"
        case .openAccessibilitySettings: return "アクセシビリティ設定"
        case .dismiss: return "閉じる"
        }
    }

    public var isPrimary: Bool {
        self == .stop || self == .copy || self == .retry
    }
}

/// What the floating status panel shows. Derived from the controller state only.
public struct HUDContent: Equatable {
    public enum Tone: Equatable {
        case recording
        case working
        case success
        case info
        case warning
        case error
    }

    public var tone: Tone
    public var title: String
    public var message: String?
    public var detail: String?
    public var transcript: String?
    public var elapsed: TimeInterval?
    public var limit: TimeInterval?
    public var level: Double?
    public var hint: String?
    public var actions: [HUDAction]

    public var isCompact: Bool {
        tone == .recording || tone == .working
    }

    public init(
        tone: Tone,
        title: String,
        message: String? = nil,
        detail: String? = nil,
        transcript: String? = nil,
        elapsed: TimeInterval? = nil,
        limit: TimeInterval? = nil,
        level: Double? = nil,
        hint: String? = nil,
        actions: [HUDAction] = []
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.detail = detail
        self.transcript = transcript
        self.elapsed = elapsed
        self.limit = limit
        self.level = level
        self.hint = hint
        self.actions = actions
    }

    /// `nil` hides the panel.
    public static func make(
        phase: DictationPhase,
        elapsed: TimeInterval,
        limit: TimeInterval,
        level: Double,
        transcript: String?,
        modelName: String?,
        targetAppName: String?,
        canRetry: Bool,
        shortcut: String
    ) -> HUDContent? {
        switch phase {
        case .idle:
            return nil
        case .recording:
            return HUDContent(tone: .recording, title: "録音中")
        case .processing(let attempt):
            return HUDContent(
                tone: .working,
                title: attempt > 1 ? "再試行中" : "文字起こし中"
            )
        case .inserted:
            return nil
        case .resultReady(let reason):
            var actions: [HUDAction] = [.dismiss]
            if reason == .accessibilityNotGranted {
                actions.append(.openAccessibilitySettings)
            }
            actions.append(.copy)
            return HUDContent(
                tone: .warning,
                title: "結果をコピーして使ってください",
                message: reason.message,
                transcript: transcript,
                actions: actions
            )
        case .failed(let failure):
            var actions: [HUDAction] = [.dismiss]
            if failure.needsMicrophoneSettings {
                actions.append(.openMicrophoneSettings)
            }
            if failure.needsSettings {
                actions.append(.openSettings)
            }
            if canRetry {
                actions.append(.retry)
            }
            return HUDContent(
                tone: .error,
                title: "うまくいきませんでした",
                message: failure.message,
                detail: failure.detail,
                actions: actions
            )
        case .notice(let notice):
            switch notice {
            case .copied, .recordingDiscarded, .processingCancelled:
                return nil
            default:
                return HUDContent(tone: .info, title: notice.message)
            }
        }
    }
}

extension DictationPhase {
    /// Short state name for logs. Never includes transcript text or server messages.
    public var logName: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing(let attempt): return "processing(\(attempt))"
        case .inserted: return "inserted"
        case .resultReady(let reason): return "resultReady(\(reason.logName))"
        case .failed(let failure): return "failed(\(failure.logName))"
        case .notice(let notice): return "notice(\(notice))"
        }
    }
}

extension ResultReason {
    var logName: String {
        switch self {
        case .noTarget: return "noTarget"
        case .appChanged: return "appChanged"
        case .focusChanged: return "focusChanged"
        case .focusUnknown: return "focusUnknown"
        case .secureField: return "secureField"
        case .accessibilityNotGranted: return "accessibilityNotGranted"
        case .clipboardNotPreservable: return "clipboardNotPreservable"
        case .insertionFailed: return "insertionFailed"
        }
    }
}

extension DictationFailure {
    var logName: String {
        switch self {
        case .missingAPIKey: return "missingAPIKey"
        case .apiKeyUnavailable: return "apiKeyUnavailable"
        case .microphoneDenied: return "microphoneDenied"
        case .recordingFailed: return "recordingFailed"
        case .audioConversionFailed: return "audioConversionFailed"
        case .unexpected: return "unexpected"
        case .transcription(let error):
            switch error {
            case .server(let status, _): return "server(\(status))"
            case .http(let status, _): return "http(\(status))"
            case .network(let code): return "network(\(code))"
            case .blocked(let reason): return "blocked(\(reason))"
            case .failed(let code, _): return "failed(\(code ?? "-"))"
            default: return String(describing: error).components(separatedBy: "(").first ?? "error"
            }
        }
    }
}

public func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}
