// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GeminiDictation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GeminiDictation", targets: ["GeminiDictation"]),
    ],
    targets: [
        // Platform-independent logic: Gemini request/response handling, the
        // transcript contract, retry policy and the dictation state machine.
        .target(name: "DictationCore"),
        // macOS implementations (audio, hotkey, Keychain, focus tracking,
        // clipboard paste) and the AppKit/SwiftUI user interface.
        .target(name: "DictationMac", dependencies: ["DictationCore"]),
        // The menu bar app itself.
        .executableTarget(name: "GeminiDictation", dependencies: ["DictationMac"]),
        // Development tool that renders the UI to PNG files without
        // microphone, network, Keychain or other permissions.
        .executableTarget(name: "UISnapshots", dependencies: ["DictationMac"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
        .testTarget(name: "DictationMacTests", dependencies: ["DictationMac"]),
    ]
)
