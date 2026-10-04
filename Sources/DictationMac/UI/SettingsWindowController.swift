import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(model: SettingsModel) {
        self.model = model
        // The recorder listens only in this window; stop it when the user leaves.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.shortcuts.cancelRecording() }
        })
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.displayName) 設定"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.center()
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.shortcuts.cancelRecording() }
            })
            self.window = window
        }
        model.refreshMicrophoneStatus()
        model.shortcuts.recheckPermission()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Used after a Dock setting change when Settings was already in front.
    func bringToFront() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
    }
}
