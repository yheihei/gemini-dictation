import Foundation

/// How a model turns the recording into text.
public enum TranscriptionEngine: String, Sendable, Equatable {
    /// A general Gemini model that follows the cleanup system instruction and
    /// returns structured JSON. Uses the stable `v1` Interactions endpoint.
    case generative
    /// The dedicated speech-to-text model in "smart" transcription mode
    /// (filler removal, self-corrections, formatting). `transcription_config`
    /// is only available on the `v1beta` Interactions endpoint.
    case transcribe
}

public struct GeminiModel: Hashable, Sendable, Identifiable {
    /// Model code sent to the API, for example `gemini-3.5-flash-lite`.
    public var id: String
    public var displayName: String
    public var engine: TranscriptionEngine
    /// `generation_config.thinking_level`. `nil` leaves the model default.
    public var thinkingLevel: String?
    /// Short Japanese description shown in Settings.
    public var note: String

    public init(id: String, displayName: String, engine: TranscriptionEngine, thinkingLevel: String?, note: String) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.thinkingLevel = thinkingLevel
        self.note = note
    }
}

/// Models offered in Settings. Checked against the official Gemini API model,
/// pricing and thinking pages on 2026-10-04; see README for the sources.
public enum ModelCatalog {
    public static let defaultModelID = "gemini-3.5-flash-lite"

    public static let presets: [GeminiModel] = [
        GeminiModel(
            id: "gemini-3.5-flash-lite",
            displayName: "Gemini 3.5 Flash-Lite（標準・低コスト）",
            engine: .generative,
            // Default thinking for this model is already "minimal"; sent explicitly to keep cost low.
            thinkingLevel: "minimal",
            note: "安定版。音声入力に対応した低コストモデル。整形ルールに沿って文字起こしします。"
        ),
        GeminiModel(
            id: "gemini-3.1-flash-lite",
            displayName: "Gemini 3.1 Flash-Lite（低コスト）",
            engine: .generative,
            thinkingLevel: nil,
            note: "安定版の低コストモデル。3.5 Flash-Liteで結果が合わないときの代替。"
        ),
        GeminiModel(
            id: "gemini-3.8-flash",
            displayName: "Gemini 3.8 Flash（高精度・高コスト）",
            engine: .generative,
            // Lowest level this model supports (it has no "minimal").
            thinkingLevel: "low",
            note: "安定版の上位モデル。精度は高めですが、料金はFlash-Liteの数倍です。"
        ),
        GeminiModel(
            id: "gemini-3.5-transcribe",
            displayName: "Gemini 3.5 Transcribe（文字起こし専用）",
            engine: .transcribe,
            thinkingLevel: nil,
            note: "音声認識専用モデルのスマートモード。フィラー除去や言い直しの整理はモデル側で行い、このアプリの整形ルールは使いません。v1beta APIを使います。"
        ),
    ]

    /// Returns the preset for `id`, or a generic entry for a custom model code.
    public static func model(for id: String) -> GeminiModel {
        if let preset = presets.first(where: { $0.id == id }) {
            return preset
        }
        let engine: TranscriptionEngine = id.contains("transcribe") ? .transcribe : .generative
        return GeminiModel(
            id: id,
            displayName: id,
            engine: engine,
            thinkingLevel: nil,
            note: "カスタムモデル。音声入力に対応したモデルを指定してください。"
        )
    }

    /// Validates a model code typed by the user. Accepts an optional `models/` prefix.
    public static func normalizedModelID(_ raw: String) -> String? {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("models/") {
            id.removeFirst("models/".count)
        }
        guard let first = id.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), id.count <= 100 else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return id
    }
}
