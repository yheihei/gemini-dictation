import Foundation
import Testing
@testable import DictationCore

@Suite("WAV analysis")
struct WAVFileTests {
    @Test func measuresDurationAndPeakOfSyntheticTone() throws {
        let info = try WAVFile.analyze(Fixtures.toneWAV(seconds: 1.5, amplitude: 0.3))
        #expect(info.sampleRate == 16_000)
        #expect(info.channels == 1)
        #expect(info.bitsPerSample == 16)
        #expect(abs(info.duration - 1.5) < 0.001)
        #expect(abs((info.peak ?? 0) - 0.3) < 0.01)
        #expect(abs((info.peakDecibels ?? 0) - (-10.46)) < 0.2)
    }

    @Test func digitalSilenceHasNoPeak() throws {
        let info = try WAVFile.analyze(Fixtures.silentWAV(seconds: 1))
        #expect(info.peak == 0)
        #expect(info.peakDecibels == -.infinity)
    }

    @Test func skipsUnknownAndOddSizedChunks() throws {
        let plain = WAVFile.encodePCM16(samples: [0, 16384, -16384, 0], sampleRate: 16_000)
        // Insert a 3-byte "FLLR" chunk (plus pad byte) between "fmt " and "data".
        var data = Data(plain[0..<36])
        data.append(contentsOf: Array("FLLR".utf8))
        data.append(contentsOf: [3, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0x00])
        data.append(plain[36...])
        let info = try WAVFile.analyze(data)
        #expect(info.dataOffset == 56)
        #expect(info.dataByteCount == 8)
        #expect(abs((info.peak ?? 0) - 0.5) < 0.001)
    }

    @Test func measuresATwentyMinuteRecording() throws {
        let data = Fixtures.longToneWAV(seconds: 1200)
        #expect(data.count == 38_400_044)
        let info = try WAVFile.analyze(data)
        #expect(info.duration == 1200)
        #expect(info.dataOffset == 44)
        #expect(abs((info.peak ?? 0) - 0.3) < 0.01)
    }

    @Test func acceptsUnfinalizedDataLength() throws {
        var data = WAVFile.encodePCM16(samples: Array(repeating: 1000, count: 1600), sampleRate: 16_000)
        // Zero out the data chunk length as an interrupted writer would leave it.
        data.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        let info = try WAVFile.analyze(data)
        #expect(abs(info.duration - 0.1) < 0.001)
    }

    @Test func rejectsNonWAVData() {
        #expect(throws: WAVError.notWAV) {
            try WAVFile.analyze(Data("not audio".utf8))
        }
    }
}
