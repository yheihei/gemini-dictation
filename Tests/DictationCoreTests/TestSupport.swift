import Foundation
@testable import DictationCore

// MARK: - Synthetic fixtures (no recorded audio is used anywhere in the tests)

enum Fixtures {
    static let apiKey = "TEST-KEY-not-a-real-key-123456"

    /// A sine tone. amplitude 0.3 ≈ -10 dBFS peak.
    static func toneWAV(seconds: Double, amplitude: Double = 0.3, sampleRate: Int = 16_000) -> Data {
        let count = Int(seconds * Double(sampleRate))
        let samples = (0..<count).map { index -> Int16 in
            let value = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * amplitude
            return Int16(max(-1, min(1, value)) * 32767)
        }
        return WAVFile.encodePCM16(samples: samples, sampleRate: sampleRate)
    }

    static func silentWAV(seconds: Double, sampleRate: Int = 16_000) -> Data {
        WAVFile.encodePCM16(samples: Array(repeating: 0, count: Int(seconds * Double(sampleRate))), sampleRate: sampleRate)
    }

    static func clip(seconds: Double = 1.0, amplitude: Double = 0.3) -> AudioClip {
        AudioClip(data: toneWAV(seconds: seconds, amplitude: amplitude), mimeType: "audio/wav")
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A completed interaction whose final step carries `modelText`.
    static func interaction(modelText: String, status: String? = "completed", extraSteps: [[String: Any]] = []) -> Data {
        var object: [String: Any] = [
            "id": "v1_test",
            "object": "interaction",
            "steps": extraSteps + [["type": "model_output", "content": [["type": "text", "text": modelText]]]],
        ]
        if let status { object["status"] = status }
        return json(object)
    }

    /// A completed interaction for a general model, i.e. `{"text": ...}` serialized as text.
    static func structured(_ text: String) -> Data {
        let inner = String(data: json(["text": text]), encoding: .utf8)!
        return interaction(modelText: inner)
    }

    static func errorBody(code: String, message: String) -> Data {
        json(["error": ["code": code, "message": message]])
    }
}

func decodeJSON(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data ?? Data())
}

// MARK: - HTTP transport mock

final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: Reply = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? .failure(.badServerResponse) : replies.removeFirst()
        }
        switch reply {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (body, response)
        case .failure(let code):
            throw URLError(code)
        }
    }
}

/// Waits until the test opens it, ignoring task cancellation (like a response that
/// is already on its way back when the user cancels).
actor Gate<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []
    private var arrivals = 0
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async -> Value {
        arrivals += 1
        let ready = arrivalWaiters.filter { $0.count <= arrivals }
        arrivalWaiters.removeAll { $0.count <= arrivals }
        ready.forEach { $0.continuation.resume() }
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func open(with value: Value) {
        self.value = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    /// Returns once `count` callers have reached `wait()`.
    func waitForArrivals(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }
}

final class GatedTransport: HTTPTransport, @unchecked Sendable {
    let gate = Gate<Data>()

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body = await gate.wait()
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Behaves like URLSession when its task is cancelled: fails with URLError.cancelled.
final class CancellingTransport: HTTPTransport, @unchecked Sendable {
    let gate = Gate<Data>()

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        _ = await gate.wait()
        throw URLError(.cancelled)
    }
}

/// Throws CancellationError without the calling task having been cancelled.
struct SpuriouslyCancellingTranscriber: Transcribing {
    func transcribe(_ clip: AudioClip, model: GeminiModel, apiKey: String) async throws -> String {
        throw CancellationError()
    }
}

// MARK: - Transcriber mocks

struct TranscribeCall: Sendable, Equatable {
    var modelID: String
    var apiKey: String
    var audio: Data
}

actor ScriptedTranscriber: Transcribing {
    private var results: [Result<String, GeminiError>]
    private(set) var calls: [TranscribeCall] = []

    init(_ results: [Result<String, GeminiError>]) {
        self.results = results
    }

    func transcribe(_ clip: AudioClip, model: GeminiModel, apiKey: String) async throws -> String {
        calls.append(TranscribeCall(modelID: model.id, apiKey: apiKey, audio: clip.data))
        guard !results.isEmpty else { throw GeminiError.malformedResponse }
        return try results.removeFirst().get()
    }
}

/// Holds the result until the test releases it.
final class GatedTranscriber: Transcribing, @unchecked Sendable {
    let gate = Gate<Result<String, GeminiError>>()

    func transcribe(_ clip: AudioClip, model: GeminiModel, apiKey: String) async throws -> String {
        try await gate.wait().get()
    }
}

// MARK: - Platform mocks

@MainActor
final class MockRecorder: AudioRecording {
    var clip = Fixtures.clip()
    var startError: Error?
    var stopError: Error?
    var elapsedTime: TimeInterval = 0
    var level = 0.5
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    var interruptionHandler: (@MainActor (Error) -> Void)?

    func startRecording() throws {
        if let startError { throw startError }
        startCount += 1
    }

    func stopRecording() throws -> AudioClip {
        if let stopError { throw stopError }
        stopCount += 1
        return clip
    }

    func cancelRecording() {
        cancelCount += 1
    }

    func normalizedLevel() -> Double {
        level
    }
}

@MainActor
final class MockMicrophone: MicrophoneAuthorizing {
    var status: MicrophoneAuthorization = .authorized
    var grantOnRequest = true
    private(set) var statusChecks = 0
    private(set) var requests = 0

    func authorizationStatus() -> MicrophoneAuthorization {
        statusChecks += 1
        return status
    }

    func requestAccess() async -> Bool {
        requests += 1
        if grantOnRequest { status = .authorized }
        return grantOnRequest
    }
}

struct KeychainReadError: Error {}

@MainActor
final class MockAPIKeys: APIKeyProviding {
    var key: String? = Fixtures.apiKey
    var error: Error?

    func apiKey() throws -> String? {
        if let error { throw error }
        return key
    }
}

@MainActor
final class MockModels: ModelProviding {
    var selectedModel = ModelCatalog.model(for: ModelCatalog.defaultModelID)
}

@MainActor
final class MockFocus: FocusTracking {
    var captureGate: Gate<Bool>?
    var captured: InsertionTarget? = InsertionTarget(processID: 4242, bundleIdentifier: "com.example.editor", appName: "Editor", focusToken: nil)
    var checkResult: TargetCheck = .ok
    private(set) var captureCount = 0
    private(set) var checkCount = 0

    func captureTarget() async -> InsertionTarget? {
        captureCount += 1
        if let captureGate { _ = await captureGate.wait() }
        return captured
    }

    func check(_ target: InsertionTarget?) -> TargetCheck {
        checkCount += 1
        return target == nil ? .noTarget : checkResult
    }
}

@MainActor
final class MockInserter: TextInserting {
    var error: InsertionError?
    private(set) var inserted: [(text: String, processID: Int32)] = []

    func insert(_ text: String, into target: InsertionTarget) async throws {
        if let error { throw error }
        inserted.append((text, target.processID))
    }
}

@MainActor
final class MockClipboard: ClipboardWriting {
    private(set) var copied: [String] = []

    func copy(_ text: String) {
        copied.append(text)
    }
}

/// Returns immediately but records requested delays and honours cancellation.
final class RecordingSleeper: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var delays: [Double] {
        lock.withLock { recorded }
    }

    func sleep(seconds: Double) async throws {
        lock.withLock { recorded.append(seconds) }
        try Task.checkCancellation()
        await Task.yield()
    }
}

// MARK: - Controller harness

@MainActor
struct Harness {
    let recorder = MockRecorder()
    let microphone = MockMicrophone()
    let apiKeys = MockAPIKeys()
    let models = MockModels()
    let focus = MockFocus()
    let inserter = MockInserter()
    let clipboard = MockClipboard()
    let sleeper = RecordingSleeper()
    let controller: DictationController

    init(transcriber: Transcribing, configuration: DictationController.Configuration = .init(meterInterval: nil, noticeDuration: nil)) {
        controller = DictationController(
            recorder: recorder,
            microphone: microphone,
            apiKeys: apiKeys,
            models: models,
            transcriber: transcriber,
            focus: focus,
            inserter: inserter,
            clipboard: clipboard,
            sleeper: sleeper,
            configuration: configuration
        )
    }

    /// Records, stops and waits for the transcription task to finish.
    func dictate() async {
        await controller.toggle()
        await controller.toggle()
        await controller.processingTask?.value
    }
}
