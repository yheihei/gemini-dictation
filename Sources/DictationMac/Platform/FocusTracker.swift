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

    public func captureTarget() async -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownProcessID else {
            // Our own Settings window is in front: there is nothing to type into.
            return nil
        }
        let trusted = AXIsProcessTrusted()
        var element = trusted ? Self.focusedInput(in: app.processIdentifier) : nil
        if trusted, element == nil {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.5)
            let window = Self.elementAttribute(kAXFocusedWindowAttribute, of: application)
            // Electron exposes its full web accessibility tree only after this request.
            // Native apps that do not implement the attribute are left alone.
            let manual = "AXManualAccessibility" as CFString
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(application, manual, &settable) == .success,
               settable.boolValue,
               Self.attribute(manual, of: application) as? Bool != true,
               AXUIElementSetAttributeValue(application, manual, kCFBooleanTrue) == .success {
                // Electron debounces accessibility activation for two seconds.
                try? await Task.sleep(nanoseconds: 2_100_000_000)
            }
            if !Task.isCancelled,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
               Self.sameOptionalElement(window, Self.elementAttribute(kAXFocusedWindowAttribute, of: application)) {
                element = Self.focusedInput(in: app.processIdentifier)
            }
        }
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
        let rawFocus = trustedNow ? Self.systemFocusedElement() : nil
        let current = trustedNow ? Self.focusedInput(in: target.processID, systemFocus: rawFocus) : nil
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
            // Web content can belong to a renderer process. The resolver proves
            // ownership through the app's focus and parent chains before accepting it.
            focusedProcessID: current != nil ? target.processID : rawFocus.flatMap(Self.processID(of:)),
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
        return elementAttribute(kAXFocusedUIElementAttribute, of: systemWide)
    }

    static func focusedInput(in processID: pid_t, systemFocus: AXUIElement? = nil) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        // Reading the application role also activates Chromium's native AX support.
        _ = role(of: application)
        let resolver = FocusedInputResolver<AXUIElement>(
            same: { CFEqual($0, $1) },
            owner: Self.processID(of:),
            parent: { Self.elementAttribute(kAXParentAttribute, of: $0) },
            focusedChild: { Self.elementAttribute(kAXFocusedUIElementAttribute, of: $0) },
            isInput: { element in
                let role = Self.role(of: element)
                if FocusDecision.isTextInput(role: role, hasEditableText: false) { return true }
                return FocusDecision.isTextInput(role: role, hasEditableText: Self.hasEditableText(element))
            },
            children: { element in
                let visible = Self.attribute(kAXVisibleChildrenAttribute as CFString, of: element)
                let value = visible ?? Self.attribute(kAXChildrenAttribute as CFString, of: element)
                return value as? [AXUIElement] ?? []
            },
            isFocused: { Self.attribute(kAXFocusedAttribute as CFString, of: $0) as? Bool == true }
        )
        return resolver.resolve(
            systemFocus: systemFocus ?? Self.systemFocusedElement(),
            applicationFocus: Self.elementAttribute(kAXFocusedUIElementAttribute, of: application),
            appProcessID: processID
        )
    }

    static func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name as CFString, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func sameOptionalElement(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return CFEqual(first, second)
    }

    static func hasEditableText(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names = names as? [String], names.contains(kAXSelectedTextRangeAttribute) else { return false }
        if attribute("AXEditable" as CFString, of: element) as? Bool == true { return true }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
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

/// Uses focus chains or an input explicitly marked focused. It never chooses an arbitrary input.
struct FocusedInputResolver<Element> {
    var same: (Element, Element) -> Bool
    var owner: (Element) -> pid_t?
    var parent: (Element) -> Element?
    var focusedChild: (Element) -> Element?
    var isInput: (Element) -> Bool
    var children: (Element) -> [Element] = { _ in [] }
    var isFocused: (Element) -> Bool = { _ in false }

    func resolve(systemFocus: Element?, applicationFocus: Element?, appProcessID: pid_t) -> Element? {
        guard let systemFocus else { return nil }
        let systemLeaf = chain(from: systemFocus, next: focusedChild).last ?? systemFocus
        let appLeaf = applicationFocus.flatMap { chain(from: $0, next: focusedChild).last }
        var leaf = systemLeaf
        if let appLeaf, !same(appLeaf, systemLeaf) {
            if chain(from: appLeaf, next: parent).contains(where: { same($0, systemLeaf) }) {
                leaf = appLeaf
            } else if !chain(from: systemLeaf, next: parent).contains(where: { same($0, appLeaf) }) {
                // A launcher or another field has focus; the app's cached focus is stale.
                return nil
            }
        }
        let directlyOwned = owner(leaf) == appProcessID || (appLeaf.map { same($0, leaf) } == true)
        if directlyOwned, isInput(leaf) { return leaf }
        let ancestors = chain(from: leaf, next: parent)
        let belongsToApp = directlyOwned || ancestors.contains { owner($0) == appProcessID }
        guard belongsToApp else { return nil }
        if let input = ancestors.first(where: isInput) { return input }
        // Some web views expose only the container as AXFocusedUIElement, while
        // the editor itself exposes AXFocused=true among its visible descendants.
        return focusedDescendant(in: leaf)
    }

    private func focusedDescendant(in element: Element) -> Element? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var queue = children(element)
        var visited = [element]
        var input: Element?
        var index = 0
        while index < queue.count {
            guard visited.count < 200, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let node = queue[index]
            index += 1
            guard !visited.contains(where: { same($0, node) }) else { continue }
            visited.append(node)
            if isFocused(node), isInput(node) {
                // Multiple focused inputs are ambiguous; do not guess which one receives ⌘V.
                guard input == nil else { return nil }
                input = node
            } else {
                queue.append(contentsOf: children(node))
            }
        }
        return input
    }

    private func chain(from element: Element, next: (Element) -> Element?) -> [Element] {
        var result = [element]
        // Bound IPC and protect against a broken accessibility parent/focus cycle.
        while result.count < 16, let last = result.last, let node = next(last),
              !result.contains(where: { same($0, node) }) {
            result.append(node)
        }
        return result
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
        return isTextInput(role: role, hasEditableText: false)
    }

    static func isTextInput(role: String?, hasEditableText: Bool) -> Bool {
        guard let role else { return false }
        if textInputRoles.contains(role) { return true }
        // Some contenteditable controls expose AXGroup instead of AXTextArea.
        return role == "AXGroup" && hasEditableText
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
