import AVFoundation
import Foundation
import Testing
@testable import DictationCore
@testable import DictationMac

// A synthetic recording goes through the real controller, AAC encoder, request
// builder and Gemini client. Only the HTTP transport is a mock: no microphone,
// network, Keychain or permissions are involved.

@MainActor
@Suite("Long recordings through the real encoder", .serialized)
struct LongRecordingTests {
    @Test func twentyMinutesAreSentAsOneDecodableM4AWithinTheRequestLimit() async throws {
        let run = try await dictate(seconds: 1200)
        #expect(run.phase == .inserted)
        #expect(run.inserted == ["合成音声の文字起こし"])
        #expect(run.leftoverFiles.isEmpty)

        let request = try #require(run.requests.first)
        #expect(run.requests.count == 1)
        let body = try #require(request.httpBody)
        #expect(body.count < InteractionRequestFactory.maxRequestBodyBytes)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(json["model"]?.stringValue == ModelCatalog.defaultModelID)
        #expect(json["store"]?.boolValue == false)
        let audio = try #require(json["input"]?[0])
        #expect(audio["type"]?.stringValue == "audio")
        #expect(audio["mime_type"]?.stringValue == "audio/m4a")
        let base64 = try #require(audio["data"]?.stringValue)
        let m4a = try #require(Data(base64Encoded: base64))
        // 48 kbps is 6 KB per second, plus the container.
        #expect(m4a.count > 7_000_000 && m4a.count < 7_800_000)

        let decoded = try SyntheticAudio.decode(m4a)
        #expect(decoded.sampleRate == 16_000)
        #expect(decoded.channels == 1)
        #expect(abs(decoded.duration - 1200) < 0.1)

        print("[synthetic-20min] wav=\(run.wavBytes) m4a=\(m4a.count) base64=\(base64.utf8.count) body=\(body.count) \(run.metrics)")
    }

    @Test func fiveMinutesAreStillSentAsTheRecordedWAV() async throws {
        let run = try await dictate(seconds: 300)
        #expect(run.phase == .inserted)
        #expect(run.leftoverFiles.isEmpty)

        let body = try #require(run.requests.first?.httpBody)
        let audio = try #require(try JSONDecoder().decode(JSONValue.self, from: body)["input"]?[0])
        #expect(audio["mime_type"]?.stringValue == "audio/wav")
        let base64 = try #require(audio["data"]?.stringValue)
        #expect(Data(base64Encoded: base64)?.count == run.wavBytes)

        print("[synthetic-5min] wav=\(run.wavBytes) base64=\(base64.utf8.count) body=\(body.count) \(run.metrics)")
    }

    @Test func cancellingTheEncoderStopsItPromptlyAndLeavesNoFiles() async throws {
        let directory = try SyntheticAudio.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compressor = SystemAudioCompressor(directory: directory)
        let clip = AudioClip(data: SyntheticAudio.toneWAV(seconds: 1200), mimeType: "audio/wav")
        let task = Task.detached { try await compressor.compress(clip) }
        // Cancel once the encoder has started writing its file.
        var waited = 0
        while SyntheticAudio.files(in: directory).isEmpty, waited < 2000 {
            try await Task.sleep(nanoseconds: 1_000_000)
            waited += 1
        }
        #expect(!SyntheticAudio.files(in: directory).isEmpty)

        let cancelledAt = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
        #expect(SyntheticAudio.files(in: directory).isEmpty)
    }

    @Test func inputTheRecorderNeverWritesIsRefusedWithoutLeavingFiles() async throws {
        let directory = try SyntheticAudio.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compressor = SystemAudioCompressor(directory: directory)
        let stereo = WAVFile.encodePCM16(samples: Array(repeating: 1000, count: 32_000), sampleRate: 16_000, channels: 2)
        await #expect(throws: AudioCompressionError.unsupportedInput) {
            try await compressor.compress(AudioClip(data: stereo, mimeType: "audio/wav"))
        }
        await #expect(throws: WAVError.notWAV) {
            try await compressor.compress(AudioClip(data: Data("not audio".utf8), mimeType: "audio/wav"))
        }
        #expect(SyntheticAudio.files(in: directory).isEmpty)
    }

    // MARK: - Harness

    struct Run {
        var phase: DictationPhase
        var inserted: [String]
        var requests: [URLRequest]
        var leftoverFiles: [String]
        var wavBytes: Int
        var seconds: Double
        var footprintBefore: UInt64
        /// Taken when the text has been inserted, before the test inspects the request.
        var memoryAfter: (footprint: UInt64, peakFootprint: UInt64, maxResident: UInt64, allocated: UInt64)

        /// Process-wide figures: only meaningful when this test runs on its own.
        /// `allocated-after` still includes the request body kept by the mock transport.
        var metrics: String {
            let megabytes = { (bytes: UInt64) in String(format: "%.1fMB", Double(bytes) / 1_000_000) }
            return "stop-to-insert=\(String(format: "%.2f", seconds))s footprint-before=\(megabytes(footprintBefore)) "
                + "footprint-peak=\(megabytes(memoryAfter.peakFootprint)) max-rss=\(megabytes(memoryAfter.maxResident)) "
                + "allocated-after=\(megabytes(memoryAfter.allocated))"
        }
    }

    /// Records `seconds` of synthetic tone, stops and waits for the text to be inserted.
    func dictate(seconds: Int) async throws -> Run {
        let directory = try SyntheticAudio.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let footprintBefore = MemoryUsage.current().footprint
        let recorder = SyntheticRecorder(wav: SyntheticAudio.toneWAV(seconds: seconds))
        let wavBytes = recorder.byteCount
        let transport = CapturingTransport(reply: SyntheticAudio.structuredResponse("合成音声の文字起こし"))
        let inserter = RecordingInserter()
        let controller = DictationController(
            recorder: recorder,
            microphone: AuthorizedMicrophone(),
            apiKeys: FakeAPIKey(),
            models: DefaultModel(),
            transcriber: GeminiClient(transport: transport),
            compressor: SystemAudioCompressor(directory: directory),
            focus: FixedFocus(),
            inserter: inserter,
            clipboard: UnusedClipboard(),
            configuration: .init(meterInterval: nil, noticeDuration: nil)
        )
        await controller.toggle()
        let started = Date()
        controller.stop()
        await controller.processingTask?.value
        let seconds = Date().timeIntervalSince(started)
        return Run(
            phase: controller.phase,
            inserted: inserter.texts,
            requests: transport.requests,
            leftoverFiles: SyntheticAudio.files(in: directory),
            wavBytes: wavBytes,
            seconds: seconds,
            footprintBefore: footprintBefore,
            memoryAfter: MemoryUsage.current()
        )
    }
}

// MARK: - Synthetic audio

enum SyntheticAudio {
    /// A 440 Hz tone at about -10 dBFS, built by repeating one second.
    static func toneWAV(seconds: Int, sampleRate: Int = 16_000) -> Data {
        let samples = (0..<sampleRate).map { index in
            Int16(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 0.3 * 32767)
        }
        let oneSecond = WAVFile.encodePCM16(samples: samples, sampleRate: sampleRate).dropFirst(44)
        let dataSize = oneSecond.count * seconds
        var data = WAVFile.encodePCM16(samples: [], sampleRate: sampleRate)
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian, Array.init))
        data.replaceSubrange(40..<44, with: withUnsafeBytes(of: UInt32(dataSize).littleEndian, Array.init))
        data.reserveCapacity(44 + dataSize)
        for _ in 0..<seconds {
            data.append(oneSecond)
        }
        return data
    }

    static func decode(_ m4a: Data) throws -> (sampleRate: Double, channels: Int, duration: Double) {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("decoded.m4a")
        try m4a.write(to: url)
        let file = try AVAudioFile(forReading: url)
        let rate = file.fileFormat.sampleRate
        return (rate, Int(file.fileFormat.channelCount), Double(file.length) / rate)
    }

    static func structuredResponse(_ text: String) -> Data {
        let inner = String(data: try! JSONEncoder().encode(["text": text]), encoding: .utf8)!
        let object: [String: Any] = [
            "status": "completed",
            "steps": [["type": "model_output", "content": [["type": "text", "text": inner]]]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}

enum MemoryUsage {
    /// Physical footprint now and at its highest so far, the peak resident size, and the
    /// bytes currently allocated (the footprint stays high after frees; this does not), in bytes.
    static func current() -> (footprint: UInt64, peakFootprint: UInt64, maxResident: UInt64, allocated: UInt64) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        let allocated = UInt64(statistics.size_in_use)
        guard result == 0 else { return (0, 0, UInt64(usage.ru_maxrss), allocated) }
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint, UInt64(usage.ru_maxrss), allocated)
    }
}

// MARK: - Fakes

/// Hands over its recording once, like the real recorder that reads and deletes its file.
@MainActor
final class SyntheticRecorder: AudioRecording {
    private var wav: Data?
    let byteCount: Int
    var elapsedTime: TimeInterval = 0
    var interruptionHandler: (@MainActor (Error) -> Void)?

    init(wav: Data) {
        self.wav = wav
        byteCount = wav.count
    }

    func startRecording() throws {}

    func stopRecording() throws -> AudioClip {
        defer { wav = nil }
        return AudioClip(data: wav ?? Data(), mimeType: "audio/wav")
    }

    func cancelRecording() {
        wav = nil
    }

    func normalizedLevel() -> Double { 0.5 }
}

final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private let reply: Data

    init(reply: Data) {
        self.reply = reply
    }

    var requests: [URLRequest] {
        lock.withLock { captured }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { captured.append(request) }
        return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor
final class AuthorizedMicrophone: MicrophoneAuthorizing {
    func authorizationStatus() -> MicrophoneAuthorization { .authorized }
    func requestAccess() async -> Bool { true }
}

@MainActor
final class FakeAPIKey: APIKeyProviding {
    func apiKey() throws -> String? { "TEST-KEY-not-a-real-key-123456" }
}

@MainActor
final class DefaultModel: ModelProviding {
    var selectedModel: GeminiModel { ModelCatalog.model(for: ModelCatalog.defaultModelID) }
}

@MainActor
final class FixedFocus: FocusTracking {
    func captureTarget() async -> InsertionTarget? {
        InsertionTarget(processID: 4242, bundleIdentifier: "com.example.editor", appName: "Editor", focusToken: nil)
    }

    func check(_ target: InsertionTarget?) -> TargetCheck { .ok }
}

@MainActor
final class RecordingInserter: TextInserting {
    private(set) var texts: [String] = []

    func insert(_ text: String, into target: InsertionTarget) async throws {
        texts.append(text)
    }
}

@MainActor
final class UnusedClipboard: ClipboardWriting {
    func copy(_ text: String) {}
}
