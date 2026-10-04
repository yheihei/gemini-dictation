import Foundation
import Testing
@testable import DictationCore

@Suite("Transcript formatting contract")
struct TranscriptContractTests {
    func generative(_ data: Data) throws -> String {
        try TranscriptText.transcript(fromResponseData: data, engine: .generative, apiKey: Fixtures.apiKey)
    }

    @Test func readsTheTextFieldOfTheFinalModelOutput() throws {
        let data = Fixtures.structured("明日の会議は10時からです。")
        #expect(try generative(data) == "明日の会議は10時からです。")
    }

    @Test func ignoresThoughtSteps() throws {
        let inner = String(data: Fixtures.json(["text": "了解です。"]), encoding: .utf8)!
        let data = Fixtures.interaction(modelText: inner, extraSteps: [["type": "thought", "signature": "abc"]])
        #expect(try generative(data) == "了解です。")
    }

    @Test func usesOnlyTheLastModelOutputAndJoinsItsTextBlocks() throws {
        let data = Fixtures.json([
            "status": "completed",
            "steps": [
                ["type": "model_output", "content": [["type": "text", "text": "{\"text\": \"old\"}"]]],
                ["type": "model_output", "content": [
                    ["type": "text", "text": "{\"text\": \"新しい"],
                    ["type": "text", "text": "結果\"}"],
                ]],
            ],
        ])
        #expect(try generative(data) == "新しい結果")
    }

    @Test func toleratesACodeFenceAroundTheJSON() throws {
        let data = Fixtures.interaction(modelText: "```json\n{\"text\": \"OKです。\"}\n```")
        #expect(try generative(data) == "OKです。")
    }

    @Test func passesNumbersNamesAndPunctuationThroughUnchanged() throws {
        let text = "2026年10月4日、Gemini APIの料金は$0.30/1Mトークンです。担当は佐藤さん（sato@example.com）。"
        #expect(try generative(Fixtures.structured(text)) == text)
    }

    @Test func onlyNormalizesLineEndingsAndSurroundingWhitespace() throws {
        let data = Fixtures.structured("\n  一行目です。\r\n二行目です。\r三行目です。  \n")
        #expect(try generative(data) == "一行目です。\n二行目です。\n三行目です。")
    }

    @Test func emptyOrBlankTextMeansNoSpeech() throws {
        #expect(try generative(Fixtures.structured("")) == "")
        #expect(try generative(Fixtures.structured(" \n　")) == "")
    }

    @Test func missingOutputFromAGeneralModelIsAnErrorNotSilence() {
        // A general model says "no speech" with {"text": ""}; no output at all is unexpected
        // and must stay retryable instead of silently discarding the recording.
        let data = Fixtures.json(["status": "completed", "steps": [["type": "thought"]]])
        #expect(throws: GeminiError.malformedResponse) {
            try generative(data)
        }
        #expect(throws: GeminiError.malformedResponse) {
            try generative(Fixtures.interaction(modelText: "  "))
        }
    }

    @Test func transcribeModelWithoutOutputMeansNoSpeech() throws {
        let data = Fixtures.json(["status": "completed", "steps": [] as [Any]])
        #expect(try TranscriptText.transcript(fromResponseData: data, engine: .transcribe, apiKey: Fixtures.apiKey) == "")
    }

    /// Commentary instead of the JSON object must never be typed into the user's document.
    @Test(arguments: [
        "Here is the transcript: 明日は晴れです。",
        "{\"transcript\": \"明日は晴れです。\"}",
        "{\"text\": 42}",
        "[\"明日は晴れです。\"]",
    ])
    func rejectsOutputThatBreaksTheSchema(modelText: String) {
        #expect(throws: GeminiError.malformedResponse) {
            try generative(Fixtures.interaction(modelText: modelText))
        }
    }

    @Test func rejectsANonJSONResponseBody() {
        #expect(throws: GeminiError.malformedResponse) {
            try generative(Data("<html>oops</html>".utf8))
        }
        #expect(throws: GeminiError.malformedResponse) {
            try generative(Fixtures.json(["id": "x"]))
        }
    }

    @Test func incompleteInteractionIsAnError() {
        #expect(throws: GeminiError.incomplete) {
            try generative(Fixtures.interaction(modelText: "{\"text\": \"途中", status: "incomplete"))
        }
    }

    @Test func failedInteractionWithABlockCodeIsReportedAsBlocked() {
        let data = Fixtures.json(["status": "failed", "errors": [["code": "SAFETY", "message": "blocked"]]])
        #expect(throws: GeminiError.blocked(reason: "safety")) {
            try generative(data)
        }
    }

    @Test func failedInteractionKeepsItsCode() {
        let data = Fixtures.json(["status": "failed", "errors": [["code": "api_error", "message": "boom"]]])
        #expect(throws: GeminiError.failed(code: "api_error", message: "boom")) {
            try generative(data)
        }
    }

    @Test(arguments: ["in_progress", "requires_action", "cancelled"])
    func unexpectedStatusesAreErrors(status: String) {
        #expect(throws: GeminiError.failed(code: status, message: nil)) {
            try generative(Fixtures.interaction(modelText: "{\"text\": \"x\"}", status: status))
        }
    }

    @Test func transcribeEngineReturnsPlainText() throws {
        let data = Fixtures.interaction(modelText: "  会議は水曜日の14時に変更します。\n")
        let text = try TranscriptText.transcript(fromResponseData: data, engine: .transcribe, apiKey: Fixtures.apiKey)
        #expect(text == "会議は水曜日の14時に変更します。")
    }
}
