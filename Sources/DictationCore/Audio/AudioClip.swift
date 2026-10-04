import Foundation

/// A finished recording held in memory. It is only ever sent to the Gemini API
/// and is discarded after a successful transcription, a cancel, or a dismiss.
public struct AudioClip: Sendable, Equatable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}
