import Foundation

public enum MicrophoneAuthorization: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

/// Microphone permission. `authorizationStatus()` must never show a prompt;
/// `requestAccess()` is only called after the user explicitly starts a recording.
@MainActor
public protocol MicrophoneAuthorizing: AnyObject {
    func authorizationStatus() -> MicrophoneAuthorization
    func requestAccess() async -> Bool
}

@MainActor
public protocol AudioRecording: AnyObject {
    func startRecording() throws
    /// Stops, returns the audio and deletes any temporary file.
    func stopRecording() throws -> AudioClip
    /// Stops and throws the audio away.
    func cancelRecording()
    var elapsedTime: TimeInterval { get }
    /// Input level for the meter, 0...1.
    func normalizedLevel() -> Double
    /// Called when recording stops for a reason other than `stop` or `cancel`.
    var interruptionHandler: (@MainActor (Error) -> Void)? { get set }
}

@MainActor
public protocol APIKeyProviding: AnyObject {
    /// The key entered by the user in Settings, or `nil` when none is configured.
    func apiKey() throws -> String?
}

@MainActor
public protocol ModelProviding: AnyObject {
    var selectedModel: GeminiModel { get }
}

/// Where the text should go: the app (and, when Accessibility access is
/// available, the focused element) that was active when recording started.
public struct InsertionTarget {
    public var processID: Int32
    public var bundleIdentifier: String?
    public var appName: String
    /// Platform focus token (an `AXUIElement` on macOS). Compared by the tracker only.
    public var focusToken: AnyObject?

    public init(processID: Int32, bundleIdentifier: String?, appName: String, focusToken: AnyObject?) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.focusToken = focusToken
    }
}

public enum TargetCheck: Equatable, Sendable {
    case ok
    case noTarget
    case appChanged(String?)
    /// Keyboard focus moved to another field or to another process's panel.
    case focusChanged
    /// The focused field could not be identified, so it cannot be verified.
    case focusUnknown
    case secureField
}

@MainActor
public protocol FocusTracking: AnyObject {
    func captureTarget() async -> InsertionTarget?
    func check(_ target: InsertionTarget?) -> TargetCheck
}

public enum InsertionError: Error, Equatable, Sendable {
    case notPermitted
    case targetChanged
    case secureField
    case eventPostingFailed
    /// The current clipboard could not be copied completely, so pasting through it
    /// would risk losing the user's data.
    case clipboardNotPreservable
}

@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String, into target: InsertionTarget) async throws
}

/// Explicit, user-requested copy. Overwrites the clipboard on purpose.
@MainActor
public protocol ClipboardWriting: AnyObject {
    func copy(_ text: String)
}
