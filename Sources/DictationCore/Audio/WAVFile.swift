import Foundation

/// Basic facts about a RIFF/WAVE recording.
public struct WAVInfo: Sendable, Equatable {
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    /// Byte offset of the first sample in the file.
    public var dataOffset: Int
    public var dataByteCount: Int
    public var duration: TimeInterval
    /// Linear peak amplitude in 0...1. `nil` when the sample format is not 16-bit PCM.
    public var peak: Double?

    /// Peak level in dBFS (`-infinity` for digital silence).
    public var peakDecibels: Double? {
        guard let peak else { return nil }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }
}

public enum WAVError: Error, Equatable {
    case notWAV
    case missingFormatChunk
    case missingDataChunk
    case unsupportedFormat
}

public enum WAVFile {
    /// Parses the RIFF header, measures the duration and finds the peak sample.
    /// Reads the data in place: a 20-minute recording is 38.4 MB.
    public static func analyze(_ data: Data) throws -> WAVInfo {
        try data.withUnsafeBytes { try analyze($0) }
    }

    private static func analyze(_ bytes: UnsafeRawBufferPointer) throws -> WAVInfo {
        guard bytes.count >= 12,
              bytes[0..<4].elementsEqual("RIFF".utf8),
              bytes[8..<12].elementsEqual("WAVE".utf8) else {
            throw WAVError.notWAV
        }

        var format: (audioFormat: Int, channels: Int, sampleRate: Int, byteRate: Int, bitsPerSample: Int)?
        var dataRange: Range<Int>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = bytes[offset..<offset + 4]
            let declaredSize = Int(readUInt32(bytes, offset + 4))
            let bodyStart = offset + 8
            let bodyEnd = min(bytes.count, bodyStart + declaredSize)
            if chunkID.elementsEqual("fmt ".utf8), bodyEnd - bodyStart >= 16 {
                format = (
                    audioFormat: Int(readUInt16(bytes, bodyStart)),
                    channels: Int(readUInt16(bytes, bodyStart + 2)),
                    sampleRate: Int(readUInt32(bytes, bodyStart + 4)),
                    byteRate: Int(readUInt32(bytes, bodyStart + 8)),
                    bitsPerSample: Int(readUInt16(bytes, bodyStart + 14))
                )
            } else if chunkID.elementsEqual("data".utf8) {
                // Recorders that were not finalized may leave a zero or oversized length.
                let end = declaredSize == 0 ? bytes.count : bodyEnd
                dataRange = bodyStart..<end
                break
            }
            // Chunks are padded to an even number of bytes.
            offset = bodyStart + declaredSize + (declaredSize % 2)
        }

        guard let format else { throw WAVError.missingFormatChunk }
        guard let dataRange else { throw WAVError.missingDataChunk }
        guard format.channels > 0, format.sampleRate > 0, format.byteRate > 0 else {
            throw WAVError.unsupportedFormat
        }

        let isPCM = format.audioFormat == 1 || format.audioFormat == 0xFFFE
        var peak: Double?
        if isPCM && format.bitsPerSample == 16 {
            var maxMagnitude = 0
            var index = dataRange.lowerBound
            while index + 1 < dataRange.upperBound {
                let sample = Int(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
                maxMagnitude = max(maxMagnitude, abs(sample))
                index += 2
            }
            peak = Double(maxMagnitude) / 32768.0
        }

        return WAVInfo(
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitsPerSample: format.bitsPerSample,
            dataOffset: dataRange.lowerBound,
            dataByteCount: dataRange.count,
            duration: Double(dataRange.count) / Double(format.byteRate),
            peak: peak
        )
    }

    /// Builds a 16-bit little-endian PCM WAV file. Used for synthetic test fixtures.
    public static func encodePCM16(samples: [Int16], sampleRate: Int, channels: Int = 1) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&data, UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, 16)
        appendUInt16(&data, 1)
        appendUInt16(&data, UInt16(channels))
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * channels * bytesPerSample))
        appendUInt16(&data, UInt16(channels * bytesPerSample))
        appendUInt16(&data, 16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, UInt32(dataSize))
        for sample in samples {
            appendUInt16(&data, UInt16(bitPattern: sample))
        }
        return data
    }

    private static func readUInt16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
