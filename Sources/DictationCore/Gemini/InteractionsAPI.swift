import Foundation

/// Request construction for `POST /{version}/interactions`
/// (https://ai.google.dev/api/interactions-api-v1).
public struct InteractionRequestFactory: Sendable {
    /// The documented limit for inline data is 20 MB for the whole request.
    /// Stay below it with some headroom for the JSON envelope.
    public static let maxRequestBodyBytes = 19_000_000
    /// Room kept for the model, instructions and schema around the audio (about 3 KB today).
    static let envelopeAllowance = 64_000
    /// Longest wait for more data. The response starts only after the whole transcript
    /// is generated, so this also has to cover processing a 20-minute recording.
    public static let requestTimeout: TimeInterval = 180

    public init() {}

    /// True when audio of this size can be sent as it is. With 16 kHz mono WAV this
    /// holds up to about 7 minutes 20 seconds; longer recordings are compressed first.
    public static func fitsInline(audioByteCount: Int) -> Bool {
        base64Length(audioByteCount) + envelopeAllowance < maxRequestBodyBytes
    }

    static func base64Length(_ byteCount: Int) -> Int {
        (byteCount + 2) / 3 * 4
    }

    /// `max_output_tokens` for general models, thinking included. The preset models
    /// document a 65,536-token output limit, so half of it leaves room for the
    /// transcript of 20 minutes of dictation. A custom model's limit is unknown,
    /// so it keeps the smaller budget used before.
    static func maxOutputTokens(for model: GeminiModel) -> Int {
        ModelCatalog.presets.contains { $0.id == model.id } ? 32_768 : 8_192
    }

    public static func endpoint(for engine: TranscriptionEngine) -> URL {
        switch engine {
        case .generative:
            return URL(string: "https://generativelanguage.googleapis.com/v1/interactions")!
        case .transcribe:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        }
    }

    public func makeRequest(clip: AudioClip, model: GeminiModel, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            throw GeminiError.invalidAPIKeyFormat
        }
        // Base64 grows the payload by a third; reject before encoding anything large.
        guard Self.base64Length(clip.data.count) < Self.maxRequestBodyBytes else {
            throw GeminiError.audioTooLarge
        }

        let body = Self.body(clip: clip, model: model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(body)
        guard data.count < Self.maxRequestBodyBytes else {
            throw GeminiError.audioTooLarge
        }

        var request = URLRequest(url: Self.endpoint(for: model.engine), timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The key travels in a header, never in the URL, so it does not end up in URL logs.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = data
        return request
    }

    static func body(clip: AudioClip, model: GeminiModel) -> CreateInteractionBody {
        let audio = InputContent.audio(data: clip.data.base64EncodedString(), mimeType: clip.mimeType)
        switch model.engine {
        case .generative:
            return CreateInteractionBody(
                model: model.id,
                input: [audio, .text(TranscriptionPrompt.userInstruction)],
                systemInstruction: TranscriptionPrompt.systemInstruction,
                generationConfig: GenerationConfig(
                    thinkingLevel: model.thinkingLevel,
                    maxOutputTokens: maxOutputTokens(for: model),
                    transcriptionConfig: nil
                ),
                responseFormat: ResponseFormat(
                    type: "text",
                    mimeType: "application/json",
                    schema: TranscriptionPrompt.responseSchema
                ),
                store: false
            )
        case .transcribe:
            return CreateInteractionBody(
                model: model.id,
                input: [audio],
                systemInstruction: nil,
                generationConfig: GenerationConfig(
                    thinkingLevel: nil,
                    maxOutputTokens: nil,
                    transcriptionConfig: TranscriptionConfig(mode: "smart")
                ),
                responseFormat: nil,
                store: false
            )
        }
    }
}

// MARK: - Request body

struct CreateInteractionBody: Encodable {
    var model: String
    var input: [InputContent]
    var systemInstruction: String?
    var generationConfig: GenerationConfig?
    var responseFormat: ResponseFormat?
    /// Always false: do not keep the recording or transcript as a stored interaction.
    var store: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case systemInstruction = "system_instruction"
        case generationConfig = "generation_config"
        case responseFormat = "response_format"
        case store
    }
}

enum InputContent: Encodable {
    case text(String)
    case audio(data: String, mimeType: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType = "mime_type"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .audio(let data, let mimeType):
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

struct GenerationConfig: Encodable {
    var thinkingLevel: String?
    var maxOutputTokens: Int?
    var transcriptionConfig: TranscriptionConfig?

    enum CodingKeys: String, CodingKey {
        case thinkingLevel = "thinking_level"
        case maxOutputTokens = "max_output_tokens"
        case transcriptionConfig = "transcription_config"
    }
}

struct TranscriptionConfig: Encodable {
    var mode: String
}

struct ResponseFormat: Encodable {
    var type: String
    var mimeType: String
    var schema: JSONValue

    enum CodingKeys: String, CodingKey {
        case type
        case mimeType = "mime_type"
        case schema
    }
}

// MARK: - Response body

struct InteractionResponse: Decodable {
    var id: String?
    var status: String?
    var steps: [Step]?
    var errors: [APIErrorBody]?

    struct Step: Decodable {
        var type: String?
        var content: [Content]?
    }

    struct Content: Decodable {
        var type: String?
        var text: String?
    }
}

struct APIErrorEnvelope: Decodable {
    var error: APIErrorBody
}

/// `{"code": "invalid_request", "message": "..."}` in the Interactions API.
/// Older Google endpoints use a numeric `code` plus a `status` string, so both are accepted.
struct APIErrorBody: Decodable {
    var code: String?
    var message: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case status
    }

    init(code: String?, message: String?, status: String? = nil) {
        self.code = code
        self.message = message
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decodeIfPresent(String.self, forKey: .code) {
            code = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
            code = String(number)
        } else {
            code = nil
        }
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
    }
}
