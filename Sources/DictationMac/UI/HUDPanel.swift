import AppKit
import DictationCore
import SwiftUI

/// Floating panel that never becomes key or main, so showing it or clicking its
/// buttons does not move keyboard focus away from the user's text field.
final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isRestorable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a button act immediately in a window that is not key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reads the observable controller so elapsed time and level update live.
struct HUDRootView: View {
    var controller: DictationController
    var shortcut: () -> String
    var perform: (HUDAction) -> Void

    var body: some View {
        if let content = HUDContent.make(
            phase: controller.phase,
            elapsed: controller.elapsed,
            limit: controller.configuration.maxRecordingDuration,
            level: controller.level,
            transcript: controller.lastTranscript,
            modelName: controller.activeModel?.displayName,
            targetAppName: controller.targetAppName,
            canRetry: controller.canRetry,
            shortcut: shortcut()
        ) {
            HUDView(content: content, perform: perform)
        }
    }
}

@MainActor
final class HUDController {
    private let panel = HUDPanel()
    private let hostingView: FirstMouseHostingView<HUDRootView>

    init(controller: DictationController, shortcut: @escaping () -> String, perform: @escaping (HUDAction) -> Void) {
        hostingView = FirstMouseHostingView(rootView: HUDRootView(controller: controller, shortcut: shortcut, perform: perform))
        panel.contentView = hostingView
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func phaseDidChange(_ phase: DictationPhase) {
        if phase == .idle {
            panel.orderOut(nil)
            return
        }
        // Let SwiftUI apply the new state before measuring.
        DispatchQueue.main.async { [weak self] in
            self?.layoutAndShow()
        }
    }

    private func layoutAndShow() {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 64)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}
