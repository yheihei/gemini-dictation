import AppKit
import ApplicationServices
import AVFoundation
import DictationCore

/// Microphone permission through AVFoundation. Checking the status never prompts.
@MainActor
public final class SystemMicrophonePermission: MicrophoneAuthorizing {
    public init() {}

    public func authorizationStatus() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

public enum SystemSettingsPane: String, Sendable {
    case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    @MainActor
    public func open() {
        if let url = URL(string: rawValue) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Permission state for Settings. Reading status never shows a system prompt.
@MainActor
public protocol PermissionStatusProviding: AnyObject {
    func microphoneStatus() -> MicrophoneAuthorization
    func isAccessibilityTrusted() -> Bool
    /// Shows the system Accessibility prompt. Only called from an explicit button press.
    func requestAccessibility()
    func open(_ pane: SystemSettingsPane)
}

@MainActor
public final class SystemPermissions: PermissionStatusProviding {
    private let microphone = SystemMicrophonePermission()

    public init() {}

    public func microphoneStatus() -> MicrophoneAuthorization {
        microphone.authorizationStatus()
    }

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibility() {
        // Value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func open(_ pane: SystemSettingsPane) {
        pane.open()
    }
}
