import AppKit
import Foundation

/// Switches between a regular app (Dock icon) and a menu-bar-only accessory app.
@MainActor
public protocol ActivationPolicyApplying: AnyObject {
    var isActive: Bool { get }
    /// Returns false if macOS refused the change.
    func setShowsDockIcon(_ show: Bool) -> Bool
    /// Re-activates this app and brings Settings back to the front.
    func reactivate()
}

/// Applies the "show in Dock" preference to the running app.
///
/// - The preference is saved immediately, but it is applied only when no dictation
///   is recording or being transcribed, so the target app keeps its focus.
/// - This app is re-activated only if it was already active with Settings visible
///   (switching policy can otherwise push Settings behind other windows). It never
///   activates itself while another app is in front.
/// - The menu bar icon stays in both modes.
@MainActor
public final class DockIconController {
    private let settings: AppSettings
    private let applier: ActivationPolicyApplying
    private let isBusy: @MainActor () -> Bool
    private let settingsVisible: @MainActor () -> Bool

    public private(set) var appliedShowsDockIcon: Bool?
    public private(set) var hasPendingChange = false

    public init(
        settings: AppSettings,
        applier: ActivationPolicyApplying,
        isBusy: @escaping @MainActor () -> Bool,
        settingsVisible: @escaping @MainActor () -> Bool
    ) {
        self.settings = settings
        self.applier = applier
        self.isBusy = isBusy
        self.settingsVisible = settingsVisible
    }

    public func applyAtLaunch() {
        apply()
    }

    public func preferenceChanged() {
        if isBusy() {
            hasPendingChange = true
        } else {
            apply()
        }
    }

    public func busyStateChanged(isBusy: Bool) {
        if !isBusy && hasPendingChange {
            apply()
        }
    }

    private func apply() {
        hasPendingChange = false
        let wanted = settings.showInDock
        guard wanted != appliedShowsDockIcon else { return }
        let wasActive = applier.isActive
        if applier.setShowsDockIcon(wanted) {
            appliedShowsDockIcon = wanted
        }
        if wasActive && settingsVisible() {
            applier.reactivate()
        }
    }
}

/// The real switch through `NSApplication.setActivationPolicy(_:)`.
@MainActor
final class SystemActivationPolicy: ActivationPolicyApplying {
    private let bringSettingsToFront: @MainActor () -> Void

    init(bringSettingsToFront: @escaping @MainActor () -> Void) {
        self.bringSettingsToFront = bringSettingsToFront
    }

    var isActive: Bool {
        NSApp.isActive
    }

    func setShowsDockIcon(_ show: Bool) -> Bool {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    func reactivate() {
        // The policy change completes asynchronously; reactivate on the next turn.
        DispatchQueue.main.async { [bringSettingsToFront] in
            NSApp.activate()
            bringSettingsToFront()
        }
    }
}

/// A simple Dock tile image (the bundle has no icon file).
enum AppIconRenderer {
    @MainActor
    static func image() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 96, yRadius: 96)
            NSGradient(starting: NSColor.systemBlue, ending: NSColor.systemIndigo)?.draw(in: tile, angle: -90)
            let configuration = NSImage.SymbolConfiguration(pointSize: 230, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }
}
