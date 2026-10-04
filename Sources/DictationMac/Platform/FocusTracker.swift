import AppKit
import ApplicationServices
import DictationCore

/// What was known about keyboard focus when recording started. Opaque to the core.
final class FocusSnapshot {
    let accessibilityTrusted: Bool
    let element: AXUIElement?

    init(accessibilityTrusted: Bool, element: AXUIElement?) {
        self.accessibilityTrusted = accessibilityTrusted
        self.element = element
    }
}

/// Remembers the frontmost app and the system-wide focused element when recording
/// starts, and checks that keyboard focus is still exactly there before typing.
@MainActor
public final class SystemFocusTracker: FocusTracking {
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    public func captureTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownProcessID else {
            // Our own Settings window is in front: there is nothing to type into.
            return nil
        }
        let trusted = AXIsProcessTrusted()
        // Keep the element only if it is a text input of the frontmost app. A coarse
        // container such as a whole web view can stay the same object while the user
        // switches channels or documents inside it, so it cannot verify the target.
        let element = trusted ? Self.systemFocusedElement().flatMap { element -> AXUIElement? in
            FocusDecision.isVerifiableInput(
                ownerProcessID: Self.processID(of: element),
                frontmostProcessID: app.processIdentifier,
                role: Self.role(of: element)
            ) ? element : nil
        } : nil
        return InsertionTarget(
            processID: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "不明なアプリ",
            focusToken: FocusSnapshot(accessibilityTrusted: trusted, element: element)
        )
    }

    public func check(_ target: InsertionTarget?) -> TargetCheck {
        guard let target else { return .noTarget }
        let front = NSWorkspace.shared.frontmostApplication
        let snapshot = target.focusToken as? FocusSnapshot
        let trustedNow = AXIsProcessTrusted()
        let current = trustedNow ? Self.systemFocusedElement() : nil
        var sameElement = false
        if let original = snapshot?.element, let current {
            sameElement = CFEqual(original, current)
        }
        return FocusDecision.evaluate(
            targetProcessID: target.processID,
            frontmostProcessID: front?.processIdentifier,
            frontmostName: front?.localizedName,
            trustedAtCapture: snapshot?.accessibilityTrusted ?? false,
            elementCaptured: snapshot?.element != nil,
            trustedNow: trustedNow,
            focusedProcessID: current.flatMap(Self.processID(of:)),
            sameElement: sameElement,
            focusedIsSecure: current.map(Self.isSecureTextField) ?? false
        )
    }

    /// The element with keyboard focus anywhere on the system. Unlike the frontmost
    /// app's focused element, this also reflects panels of other processes that take
    /// keyboard focus without activating their app (for example launcher panels).
    static func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // Do not hang on an unresponsive app.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func processID(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        return AXUIElementGetPid(element, &processID) == .success ? processID : nil
    }

    static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func isSecureTextField(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? String) == kAXSecureTextFieldSubrole
    }
}

/// The decision behind `SystemFocusTracker.check`, separated so it can be tested
/// without Accessibility access.
enum FocusDecision {
    /// Values of `kAXTextFieldRole`, `kAXTextAreaRole` and `kAXComboBoxRole`.
    /// Search and password fields are text fields with a subrole.
    static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Only an editable text element of the frontmost app can identify the target.
    static func isVerifiableInput(ownerProcessID: pid_t?, frontmostProcessID: pid_t, role: String?) -> Bool {
        guard ownerProcessID == frontmostProcessID, let role else { return false }
        return textInputRoles.contains(role)
    }

    static func evaluate(
        targetProcessID: pid_t,
        frontmostProcessID: pid_t?,
        frontmostName: String?,
        trustedAtCapture: Bool,
        elementCaptured: Bool,
        trustedNow: Bool,
        focusedProcessID: pid_t?,
        sameElement: Bool,
        focusedIsSecure: Bool
    ) -> TargetCheck {
        guard frontmostProcessID == targetProcessID else {
            return .appChanged(frontmostName)
        }
        // Without Accessibility access the paste itself is refused afterwards,
        // which leads to the copy panel as well.
        guard trustedNow else { return .ok }
        // Access was granted mid-dictation, or the field could not be identified at
        // the start or now: there is nothing to compare, so do not guess.
        guard trustedAtCapture, elementCaptured, let focusedProcessID else {
            return .focusUnknown
        }
        // Keyboard focus is in another process, such as a launcher panel.
        guard focusedProcessID == targetProcessID, sameElement else {
            return .focusChanged
        }
        if focusedIsSecure {
            return .secureField
        }
        return .ok
    }
}
