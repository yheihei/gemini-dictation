import AVFoundation
import DictationCore
import Foundation

public enum AudioCompressionError: Error, Equatable {
    /// The input is not the 16 kHz mono 16-bit PCM WAV that the recorder writes.
    case unsupportedInput
    case encodingFailed
}

/// Compresses a long WAV recording to AAC in an M4A file. 20 minutes become about
/// 7.3 MB instead of 38.4 MB, well within the inline request limit. The file is
/// written to the private temporary folder and deleted as soon as it has been read.
public struct SystemAudioCompressor: AudioCompressing {
    /// AAC-LC at 48 kbps, the highest bit rate the encoder offers for 16 kHz mono.
    /// A constant bit rate keeps the size predictable: 6 KB per second plus the container.
    static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
        ]
    }

    private let directory: URL

    public init(directory: URL = TemporaryAudioFiles.directory) {
        self.directory = directory
    }

    public func compress(_ clip: AudioClip) async throws -> AudioClip {
        let (wav, directory) = (clip.data, self.directory)
        // Encoding 20 minutes takes about a second, so it runs off the main actor.
        let encoding = Task.detached(priority: .userInitiated) {
            try Self.encode(wav, in: directory)
        }
        let data = try await withTaskCancellationHandler {
            try await encoding.value
        } onCancel: {
            encoding.cancel()
        }
        return AudioClip(data: data, mimeType: "audio/m4a")
    }

    static func encode(_ wav: Data, in directory: URL) throws -> Data {
        let info = try WAVFile.analyze(wav)
        guard info.sampleRate == 16_000, info.channels == 1, info.bitsPerSample == 16 else {
            throw AudioCompressionError.unsupportedInput
        }
        try TemporaryAudioFiles.prepare(directory)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { TemporaryAudioFiles.remove(url) }
        try write(wav, info: info, to: url)
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw AudioCompressionError.encodingFailed }
        return data
    }

    /// Feeds the samples to the encoder one second at a time and checks for
    /// cancellation in between, so a cancel takes effect within milliseconds.
    private static func write(_ wav: Data, info: WAVInfo, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let chunk = 16_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let samples = buffer.int16ChannelData?[0] else {
            throw AudioCompressionError.encodingFailed
        }
        let frames = info.dataByteCount / 2
        try wav.withUnsafeBytes { bytes in
            var frame = 0
            while frame < frames {
                try Task.checkCancellation()
                let count = min(chunk, frames - frame)
                // WAV samples are little-endian, like the buffer on Apple platforms.
                UnsafeMutableRawPointer(samples).copyMemory(
                    from: bytes.baseAddress! + info.dataOffset + frame * 2,
                    byteCount: count * 2
                )
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                frame += count
            }
        }
        // Completes the file. Before macOS 15 this happens when `file` is released on return.
        if #available(macOS 15.0, *) {
            file.close()
        }
    }
}
