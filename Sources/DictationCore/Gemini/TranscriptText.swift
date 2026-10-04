import Foundation

/// Turns an Interactions API response into the text that will be typed.
///
/// Contract:
/// - Only the final `model_output` step is used; `thought` and other steps are ignored.
/// - General models must return `{"text": "..."}`. Anything else is rejected rather than
///   inserted, so stray commentary from the model never reaches the user's document.
/// - The only local change to the text is line-ending normalization and trimming of
///   surrounding whitespace. Words, numbers and names are never rewritten here.
/// - An empty result means "no speech" and is not inserted.
public enum TranscriptText {
    static func transcript(fromResponseData data: Data, engine: TranscriptionEngine, apiKey: String) throws -> String {
        guard let response = try? JSONDecoder().decode(InteractionResponse.self, from: data) else {
            throw GeminiError.malformedResponse
        }
        switch response.status {
        case "completed", nil:
            break
        case "incomplete":
            throw GeminiError.incomplete
        case "failed":
            throw GeminiError.fromFailedInteraction(response.errors?.first, redacting: apiKey)
        default:
            // in_progress / requires_action / cancelled are not expected for a
            // synchronous, tool-free request.
            throw GeminiError.failed(code: response.status, message: nil)
        }
        guard response.status != nil || response.steps != nil else {
            throw GeminiError.malformedResponse
        }

        let raw = outputText(of: response) ?? ""
        let text: String
        switch engine {
        case .generative:
            // "No speech" from a general model is `{"text": ""}`. A missing or empty
            // output is unexpected, so report it and keep the audio for a retry.
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GeminiError.malformedResponse
            }
            text = try decodeStructuredText(raw)
        case .transcribe:
            // The speech-to-text model returns no text when nothing was said.
            text = raw
        }
        return finalize(text)
    }

    /// Joins the text blocks of the last `model_output` step.
    static func outputText(of response: InteractionResponse) -> String? {
        guard let step = response.steps?.last(where: { $0.type == "model_output" }) else {
            return nil
        }
        let texts = (step.content ?? []).compactMap { block -> String? in
            guard block.type == nil || block.type == "text" else { return nil }
            return block.text
        }
        return texts.joined()
    }

    /// Reads `{"text": "..."}`. Tolerates a Markdown code fence around the JSON.
    public static func decodeStructuredText(_ raw: String) throws -> String {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return ""
        }
        if body.hasPrefix("```") {
            var lines = body.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            body = lines.joined(separator: "\n")
        }
        guard let data = body.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw GeminiError.malformedResponse
        }
        if let text = value["text"]?.stringValue {
            return text
        }
        throw GeminiError.malformedResponse
    }

    /// Normalizes line endings and trims surrounding whitespace. Nothing else.
    public static func finalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
