import AVFoundation
import DictationCore
import Foundation

public enum RecorderError: Error, Equatable {
    case couldNotStart
    case notRecording
    case interrupted
}

/// Private scratch space for the recording in progress and its compressed copy. Files are
/// deleted as soon as the audio has been read into memory, and leftovers are purged at launch.
public enum TemporaryAudioFiles {
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GeminiDictation", isDirectory: true)
    }

    static func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func purge(_ directory: URL = directory) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["wav", "m4a"].contains(file.pathExtension) {
            remove(file)
        }
    }
}

/// Records 16 kHz mono 16-bit PCM WAV, the resolution Gemini uses for audio anyway.
/// That is 1.92 MB per minute; recordings too large to send inline are compressed first.
@MainActor
public final class SystemAudioRecorder: NSObject, AudioRecording {
    public static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    public var interruptionHandler: (@MainActor (Error) -> Void)?

    private let directory: URL
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    public init(directory: URL = TemporaryAudioFiles.directory) {
        self.directory = directory
    }

    public func startRecording() throws {
        cancelRecording()
        try TemporaryAudioFiles.prepare(directory)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            recorder.delegate = nil
            recorder.stop()
            TemporaryAudioFiles.remove(url)
            throw RecorderError.couldNotStart
        }
        self.recorder = recorder
        fileURL = url
    }

    public func stopRecording() throws -> AudioClip {
        guard let recorder, let fileURL else {
            throw RecorderError.notRecording
        }
        self.recorder = nil
        self.fileURL = nil
        recorder.delegate = nil
        recorder.stop()
        defer { TemporaryAudioFiles.remove(fileURL) }
        return AudioClip(data: try Data(contentsOf: fileURL), mimeType: "audio/wav")
    }

    public func cancelRecording() {
        guard let recorder else { return }
        recorder.delegate = nil
        recorder.stop()
        recorder.deleteRecording()
        if let fileURL {
            TemporaryAudioFiles.remove(fileURL)
        }
        self.recorder = nil
        fileURL = nil
    }

    public var elapsedTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    public func normalizedLevel() -> Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        return max(0, min(1, (decibels + 50) / 50))
    }

    private func handleUnexpectedStop(of identifier: ObjectIdentifier) {
        guard let recorder, ObjectIdentifier(recorder) == identifier else { return }
        cancelRecording()
        interruptionHandler?(RecorderError.interrupted)
    }
}

extension SystemAudioRecorder: AVAudioRecorderDelegate {
    // Normal stops clear the delegate first, so these only fire for unexpected ends
    // (for example the input device disappearing).
    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identifier = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            self?.handleUnexpectedStop(of: identifier)
        }
    }

    public nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let identifier = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            self?.handleUnexpectedStop(of: identifier)
        }
    }
}
