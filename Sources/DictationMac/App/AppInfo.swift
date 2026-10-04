import Foundation
import os

public enum AppInfo {
    /// Fixed so the Keychain item and logs do not depend on how the binary was launched.
    public static let bundleIdentifier = "io.github.yheihei.GeminiDictation"
    public static let displayName = "Gemini Dictation"
    public static let apiKeyURL = URL(string: "https://aistudio.google.com/apikey")!
    public static let pricingURL = URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!
    public static let termsURL = URL(string: "https://ai.google.dev/gemini-api/terms")!
}

/// Unified logging. Only states, error kinds and permission results are logged;
/// transcripts, audio, API keys and server messages are never written.
enum Log {
    static let app = Logger(subsystem: AppInfo.bundleIdentifier, category: "app")
}
