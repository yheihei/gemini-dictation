import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
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
            self.window = window
        }
        model.refreshMicrophoneStatus()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
