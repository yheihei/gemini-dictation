import Foundation

/// Sends HTTP requests. Replaced by a mock in tests so nothing touches the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// `URLSession` transport with an ephemeral session: no cookies, cache or credential storage.
public final class URLSessionTransport: HTTPTransport {
    /// Upper limit for a whole request: uploading up to 19 MB on a slow connection,
    /// waiting for the transcript of a 20-minute recording and receiving it.
    /// The user can cancel at any time before that.
    static let resourceTimeout: TimeInterval = 600

    private let session: URLSession

    public convenience init() {
        self.init(configuration: Self.defaultConfiguration())
    }

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = InteractionRequestFactory.requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Converts recorded audio into text.
public protocol Transcribing: Sendable {
    /// Returns the cleaned-up transcript. An empty string means no speech was recognized.
    func transcribe(_ clip: AudioClip, model: GeminiModel, apiKey: String) async throws -> String
}

/// Calls the Gemini Interactions API. One call sends exactly one recording;
/// clipboard contents, surrounding text and app information are never included.
public struct GeminiClient: Transcribing {
    private let transport: HTTPTransport
    private let factory = InteractionRequestFactory()

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public func transcribe(_ clip: AudioClip, model: GeminiModel, apiKey: String) async throws -> String {
        let request = try factory.makeRequest(clip: clip, model: model, apiKey: apiKey)
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            // Only our own cancellation counts as one; anything else is a failed request.
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw GeminiError.fromURLError(error)
        }
        // A result that arrives after cancellation must not be used.
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiError.fromHTTP(status: http.statusCode, body: data, redacting: apiKey)
        }
        return try TranscriptText.transcript(fromResponseData: data, engine: model.engine, apiKey: apiKey)
    }
}

/// Automatic retry for transient failures. Anything else is left to the
/// user's explicit "retry" so a request is never silently repeated.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var delays: [Double]

    public init(maxAttempts: Int = 3, delays: [Double] = [1.0, 3.0]) {
        self.maxAttempts = maxAttempts
        self.delays = delays
    }

    /// Seconds to wait before attempt `attempt + 1`, or `nil` to give up.
    public func delay(after error: Error, attempt: Int) -> Double? {
        guard attempt < maxAttempts,
              let geminiError = error as? GeminiError,
              geminiError.isTransient,
              !delays.isEmpty else {
            return nil
        }
        return delays[min(attempt - 1, delays.count - 1)]
    }
}

/// Waits between steps. Tests substitute an instant or manually driven version.
public protocol Sleeping: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeping {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
