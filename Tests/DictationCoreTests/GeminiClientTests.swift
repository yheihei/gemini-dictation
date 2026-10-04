import Foundation
import Testing
@testable import DictationCore

@Suite("Gemini client and error handling")
struct GeminiClientTests {
    let model = ModelCatalog.model(for: ModelCatalog.defaultModelID)
    let clip = Fixtures.clip()

    func transcribe(_ replies: [MockTransport.Reply]) async throws -> String {
        try await GeminiClient(transport: MockTransport(replies)).transcribe(clip, model: model, apiKey: Fixtures.apiKey)
    }

    @Test func returnsTheTranscriptFromOneRequest() async throws {
        let transport = MockTransport([.response(status: 200, body: Fixtures.structured("テストです。"))])
        let text = try await GeminiClient(transport: transport).transcribe(clip, model: model, apiKey: Fixtures.apiKey)
        #expect(text == "テストです。")
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [
        (400, "invalid_request", GeminiError.invalidRequest("detail")),
        (400, "failed_precondition", GeminiError.failedPrecondition("detail")),
        (401, "authentication", GeminiError.authentication("detail")),
        (402, "payment_required", GeminiError.paymentRequired("detail")),
        (403, "permission_denied", GeminiError.permissionDenied("detail")),
        (404, "model_not_found", GeminiError.modelNotFound("detail")),
        (429, "rate_limit_exceeded", GeminiError.rateLimited("detail")),
        (429, "too_many_requests", GeminiError.rateLimited("detail")),
        (429, "quota_exceeded", GeminiError.quotaExceeded("detail")),
        (408, "request_timeout", GeminiError.server(status: 408, message: "detail")),
        (500, "api_error", GeminiError.server(status: 500, message: "detail")),
        (501, "unimplemented", GeminiError.unsupported("detail")),
        (503, "service_unavailable", GeminiError.server(status: 503, message: "detail")),
        (504, "deadline_exceeded", GeminiError.server(status: 504, message: "detail")),
        (409, "aborted", GeminiError.http(status: 409, message: "detail")),
        (404, "not_found", GeminiError.modelNotFound("detail")),
        (400, "parameter_unknown", GeminiError.invalidRequest("detail")),
        // The documented code wins over a surprising HTTP status.
        (400, "quota_exceeded", GeminiError.quotaExceeded("detail")),
        (500, "unimplemented", GeminiError.unsupported("detail")),
        (429, "https://generativelanguage.googleapis.com/errors/quota_exceeded", GeminiError.quotaExceeded("detail")),
        (400, "type.googleapis.com/errors#SAFETY", GeminiError.blocked(reason: "safety")),
        (400, "safety", GeminiError.blocked(reason: "safety")),
        (400, "spii", GeminiError.blocked(reason: "spii")),
    ])
    func mapsDocumentedErrorCodes(status: Int, code: String, expected: GeminiError) async {
        await #expect(throws: expected) {
            try await transcribe([.response(status: status, body: Fixtures.errorBody(code: code, message: "detail"))])
        }
    }

    @Test func legacyInvalidKeyResponseMeansAuthentication() async {
        let body = Fixtures.json(["error": ["code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT"]])
        await #expect(throws: GeminiError.authentication("API key not valid. Please pass a valid API key.")) {
            try await transcribe([.response(status: 400, body: body)])
        }
    }

    @Test func nonJSONErrorBodiesStillMapByStatus() async {
        await #expect(throws: GeminiError.server(status: 502, message: nil)) {
            try await transcribe([.response(status: 502, body: Data("<html>Bad Gateway</html>".utf8))])
        }
    }

    @Test func serverMessagesNeverEchoTheKey() async {
        let body = Fixtures.errorBody(code: "authentication", message: "Key \(Fixtures.apiKey) is expired")
        await #expect(throws: GeminiError.authentication("Key [redacted] is expired")) {
            try await transcribe([.response(status: 401, body: body)])
        }
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, GeminiError.offline),
        (URLError.Code.timedOut, GeminiError.timedOut),
        (URLError.Code.cannotConnectToHost, GeminiError.network(code: URLError.Code.cannotConnectToHost.rawValue)),
    ])
    func mapsTransportErrors(code: URLError.Code, expected: GeminiError) async {
        await #expect(throws: expected) {
            try await transcribe([.failure(code)])
        }
    }

    @Test func anUnrequestedCancelFromTheNetworkIsAFailure() async {
        // URLSession can report -999 without the user cancelling (e.g. a network filter).
        await #expect(throws: GeminiError.network(code: URLError.Code.cancelled.rawValue)) {
            try await transcribe([.failure(.cancelled)])
        }
    }

    @Test func cancellingTheTaskSurfacesAsCancellation() async {
        let transport = CancellingTransport()
        let client = GeminiClient(transport: transport)
        let (model, clip) = (self.model, self.clip)
        let task = Task { try await client.transcribe(clip, model: model, apiKey: Fixtures.apiKey) }
        await transport.gate.waitForArrivals(1)
        task.cancel()
        await transport.gate.open(with: Data())
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func aResponseArrivingAfterCancellationIsDiscarded() async throws {
        let transport = GatedTransport()
        let client = GeminiClient(transport: transport)
        let (model, clip) = (self.model, self.clip)
        let task = Task { try await client.transcribe(clip, model: model, apiKey: Fixtures.apiKey) }
        await transport.gate.waitForArrivals(1)
        task.cancel()
        await transport.gate.open(with: Fixtures.structured("届いてはいけない結果"))
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func malformedKeyFailsBeforeAnyNetworkCall() async {
        let transport = MockTransport([])
        await #expect(throws: GeminiError.invalidAPIKeyFormat) {
            try await GeminiClient(transport: transport).transcribe(clip, model: model, apiKey: " ")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func transientClassification() {
        #expect(GeminiError.rateLimited(nil).isTransient)
        #expect(GeminiError.server(status: 503, message: nil).isTransient)
        #expect(GeminiError.server(status: 408, message: nil).isTransient)
        #expect(GeminiError.network(code: URLError.Code.cannotConnectToHost.rawValue).isTransient)
        // These may already have been processed (and billed), so only an explicit retry resends.
        #expect(!GeminiError.server(status: 504, message: nil).isTransient)
        #expect(!GeminiError.network(code: URLError.Code.networkConnectionLost.rawValue).isTransient)
        #expect(!GeminiError.network(code: URLError.Code.cancelled.rawValue).isTransient)
        #expect(!GeminiError.unsupported(nil).isTransient)
        #expect(!GeminiError.failedPrecondition(nil).isTransient)
        #expect(!GeminiError.quotaExceeded(nil).isTransient)
        #expect(!GeminiError.timedOut.isTransient)
        #expect(!GeminiError.authentication(nil).isTransient)
        #expect(!GeminiError.network(code: URLError.Code.badServerResponse.rawValue).isTransient)
    }

    @Test func settingsRelatedErrorsAskForSettings() {
        #expect(GeminiError.authentication(nil).needsSettingsChange)
        #expect(GeminiError.modelNotFound(nil).needsSettingsChange)
        #expect(!GeminiError.rateLimited(nil).needsSettingsChange)
    }

    @Test func everyErrorHasAJapaneseMessage() {
        let all: [GeminiError] = [
            .invalidAPIKeyFormat, .audioTooLarge, .authentication(nil), .permissionDenied(nil), .paymentRequired(nil),
            .modelNotFound(nil), .invalidRequest(nil), .failedPrecondition(nil), .unsupported(nil),
            .rateLimited(nil), .quotaExceeded(nil),
            .server(status: 503, message: nil), .blocked(reason: "safety"), .incomplete, .failed(code: nil, message: nil),
            .malformedResponse, .offline, .timedOut, .network(code: -1), .http(status: 418, message: nil),
        ]
        for error in all {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.userMessage.contains(Fixtures.apiKey))
        }
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {
    let policy = RetryPolicy()

    @Test func retriesTransientErrorsTwiceWithBackoff() {
        let error = GeminiError.server(status: 503, message: nil)
        #expect(policy.delay(after: error, attempt: 1) == 1.0)
        #expect(policy.delay(after: error, attempt: 2) == 3.0)
        #expect(policy.delay(after: error, attempt: 3) == nil)
    }

    @Test func neverRetriesAutomaticallyWhenItCouldDoubleBillOrCannotHelp() {
        #expect(policy.delay(after: GeminiError.timedOut, attempt: 1) == nil)
        #expect(policy.delay(after: GeminiError.quotaExceeded(nil), attempt: 1) == nil)
        #expect(policy.delay(after: GeminiError.authentication(nil), attempt: 1) == nil)
        #expect(policy.delay(after: GeminiError.malformedResponse, attempt: 1) == nil)
        #expect(policy.delay(after: CancellationError(), attempt: 1) == nil)
    }
}
