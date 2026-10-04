import Foundation

/// Errors from building, sending or interpreting a Gemini request.
/// Codes follow https://ai.google.dev/gemini-api/docs/api-errors.
public enum GeminiError: Error, Equatable, Sendable {
    case invalidAPIKeyFormat
    case audioTooLarge
    case authentication(String?)
    case permissionDenied(String?)
    case paymentRequired(String?)
    case modelNotFound(String?)
    case invalidRequest(String?)
    /// 400 `failed_precondition`, e.g. billing disabled or the region not supported.
    case failedPrecondition(String?)
    /// 501 `unimplemented`: the model or API version does not support the request.
    case unsupported(String?)
    case rateLimited(String?)
    case quotaExceeded(String?)
    case server(status: Int, message: String?)
    case blocked(reason: String)
    case incomplete
    case failed(code: String?, message: String?)
    case malformedResponse
    case offline
    case timedOut
    case network(code: Int)
    case http(status: Int, message: String?)

    /// Output-blocking codes from the "Generation blocked codes" table.
    static let blockedCodes: Set<String> = [
        "safety", "recitation", "language", "prohibited_content", "spii", "blocklist", "content_blocked",
    ]

    /// True when an automatic retry has a reasonable chance of success and the
    /// failed request was most likely not processed (so retrying does not double-bill).
    /// Gateway timeouts (504), client timeouts and dropped connections may have been
    /// processed already, so those are left to the user's explicit retry.
    public var isTransient: Bool {
        switch self {
        case .rateLimited:
            return true
        case .server(let status, _):
            return [408, 500, 502, 503].contains(status)
        case .network(let code):
            return Self.connectionFailureCodes.contains(code)
        default:
            return false
        }
    }

    /// Transport failures where the request never reached the API.
    static let connectionFailureCodes: Set<Int> = [
        URLError.Code.cannotFindHost.rawValue,
        URLError.Code.cannotConnectToHost.rawValue,
        URLError.Code.dnsLookupFailed.rawValue,
    ]

    /// True when the user has to change something in Settings before retrying.
    public var needsSettingsChange: Bool {
        switch self {
        case .invalidAPIKeyFormat, .authentication, .permissionDenied, .modelNotFound, .unsupported:
            return true
        default:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .invalidAPIKeyFormat:
            return "APIキーの形式が正しくありません。設定画面で入力し直してください。"
        case .audioTooLarge:
            return "録音データが大きすぎて送信できません。短く区切って録音してください。"
        case .authentication:
            return "APIキーが無効か期限切れです。設定画面でAPIキーを確認してください。"
        case .permissionDenied:
            return "このAPIキーには利用権限がありません（403）。Google AI Studioでキーとプロジェクトを確認してください。"
        case .paymentRequired:
            return "前払いクレジットの残高がありません（402）。Google AI Studioの請求設定を確認してください。"
        case .modelNotFound:
            return "指定したモデルが見つかりませんでした（404）。設定画面でモデルIDを確認するか、別のモデルを選んでください。"
        case .invalidRequest:
            return "リクエストが受け付けられませんでした（400）。設定画面で別のモデルを選ぶと解決する場合があります。"
        case .failedPrecondition:
            return "前提条件を満たしていないため処理できませんでした（400）。Google AI Studioで請求設定や利用できる地域を確認してください。"
        case .unsupported:
            return "このモデルまたはAPIでは使えない機能です（501）。設定画面で別のモデルを選んでください。"
        case .rateLimited:
            return "リクエストが多すぎます（429）。少し待ってから再試行してください。"
        case .quotaExceeded:
            return "利用上限に達しました（429）。上限がリセットされるまで待つか、Google AI Studioで上限を確認してください。"
        case .server(let status, _):
            return "Gemini APIが一時的に利用できません（\(status)）。時間をおいて再試行してください。"
        case .blocked(let reason):
            return "Gemini側のポリシーにより出力がブロックされました（\(reason)）。"
        case .incomplete:
            return "出力が途中で終わりました。再試行してください。"
        case .failed(let code, _):
            return "Gemini APIでの処理に失敗しました（\(code ?? "unknown")）。再試行してください。"
        case .malformedResponse:
            return "Gemini APIの応答を解釈できませんでした。再試行してください。"
        case .offline:
            return "インターネットに接続されていません。接続を確認して再試行してください。"
        case .timedOut:
            return "応答がタイムアウトしました。再試行してください。"
        case .network:
            return "ネットワークエラーが発生しました。接続を確認して再試行してください。"
        case .http(let status, _):
            return "Gemini APIがエラーを返しました（HTTP \(status)）。"
        }
    }

    /// The server's own explanation, if any (already redacted).
    public var serverMessage: String? {
        switch self {
        case .authentication(let message), .permissionDenied(let message), .paymentRequired(let message),
             .modelNotFound(let message), .invalidRequest(let message), .failedPrecondition(let message),
             .unsupported(let message), .rateLimited(let message), .quotaExceeded(let message):
            return message
        case .server(_, let message), .failed(_, let message), .http(_, let message):
            return message
        default:
            return nil
        }
    }

    /// Maps a non-2xx HTTP response: by the documented error `code` first, then by status.
    static func fromHTTP(status: Int, body: Data, redacting apiKey: String) -> GeminiError {
        let errorBody = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: body))?.error
        let code = normalizedCode(errorBody?.code)
        let message = redact(errorBody?.message, apiKey: apiKey)
        if let code, let mapped = fromCode(code, status: status, message: message) {
            return mapped
        }
        return fromStatus(status, message: message)
    }

    /// Codes from https://ai.google.dev/gemini-api/docs/api-errors.
    static func fromCode(_ code: String, status: Int, message: String?) -> GeminiError? {
        if blockedCodes.contains(code) {
            return .blocked(reason: code)
        }
        switch code {
        case "invalid_request", "parameter_unknown", "out_of_range":
            return fromStatus(400, message: message)
        case "failed_precondition":
            return .failedPrecondition(message)
        case "authentication":
            return .authentication(message)
        case "payment_required":
            return .paymentRequired(message)
        case "permission_denied":
            return .permissionDenied(message)
        case "model_not_found", "not_found":
            return .modelNotFound(message)
        case "rate_limit_exceeded", "too_many_requests":
            return .rateLimited(message)
        case "quota_exceeded":
            return .quotaExceeded(message)
        case "unimplemented":
            return .unsupported(message)
        case "api_error", "service_unavailable", "deadline_exceeded":
            return .server(status: status, message: message)
        default:
            return nil
        }
    }

    static func fromStatus(_ status: Int, message: String?) -> GeminiError {
        switch status {
        case 400:
            // Older endpoints report a bad key as 400 INVALID_ARGUMENT with this wording.
            if let message, message.localizedCaseInsensitiveContains("API key") {
                return .authentication(message)
            }
            return .invalidRequest(message)
        case 401:
            return .authentication(message)
        case 402:
            return .paymentRequired(message)
        case 403:
            return .permissionDenied(message)
        case 404:
            return .modelNotFound(message)
        case 408:
            return .server(status: status, message: message)
        case 429:
            return .rateLimited(message)
        case 501:
            return .unsupported(message)
        case 500...599:
            return .server(status: status, message: message)
        default:
            return .http(status: status, message: message)
        }
    }

    /// The API reference describes `code` as a URI while the error guide shows plain
    /// snake_case names; accept both by keeping the last path or fragment component.
    static func normalizedCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "#" }).last.map(String.init) ?? raw
        let code = last.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.isEmpty ? nil : code
    }

    /// Maps an error recorded on an interaction whose `status` is `failed`.
    static func fromFailedInteraction(_ body: APIErrorBody?, redacting apiKey: String) -> GeminiError {
        let code = normalizedCode(body?.code)
        let message = redact(body?.message, apiKey: apiKey)
        if let code, blockedCodes.contains(code) {
            return .blocked(reason: code)
        }
        return .failed(code: code, message: message)
    }

    /// Maps transport errors. Cancellation is reported separately as `CancellationError`.
    static func fromURLError(_ error: URLError) -> GeminiError {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        default:
            return .network(code: error.code.rawValue)
        }
    }

    /// Removes the API key from server text and caps its length.
    static func redact(_ message: String?, apiKey: String) -> String? {
        guard var message, !message.isEmpty else { return nil }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.count >= 8 {
            message = message.replacingOccurrences(of: key, with: "[redacted]")
        }
        if message.count > 300 {
            message = String(message.prefix(300)) + "…"
        }
        return message
    }
}
