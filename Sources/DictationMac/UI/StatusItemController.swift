import AppKit
import DictationCore

/// Menu bar icon and menu. Opening this menu does not activate the app, so the
/// app the user was typing in stays frontmost and remains the insertion target.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var toggle: () -> Void
        var cancel: () -> Void
        var retry: () -> Void
        var copyLast: () -> Void
        var openSettings: () -> Void
        var menuWillOpen: () -> Void = {}
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let settings: AppSettings
    private let actions: Actions

    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var toggleItem = makeItem("", #selector(toggleRecording))
    private lazy var cancelItem = makeItem("キャンセル", #selector(cancel))
    private lazy var retryItem = makeItem("再試行", #selector(retry))
    private lazy var copyItem = makeItem("最後の結果をコピー", #selector(copyLast))

    init(controller: DictationController, settings: AppSettings, actions: Actions) {
        self.controller = controller
        self.settings = settings
        self.actions = actions
        super.init()

        statusItem.button?.toolTip = AppInfo.displayName
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(cancelItem)
        menu.addItem(retryItem)
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let settingsItem = makeItem("設定…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "\(AppInfo.displayName) を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        update(for: controller.phase)
    }

    func update(for phase: DictationPhase) {
        let (symbol, tint): (String, NSColor?) = {
            switch phase {
            case .idle, .inserted, .notice: return ("mic", nil)
            case .recording: return ("mic.fill", .systemRed)
            case .processing: return ("waveform", nil)
            case .resultReady: return ("doc.on.clipboard", .systemOrange)
            case .failed: return ("exclamationmark.triangle", .systemRed)
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppInfo.displayName)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = tint
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        actions.menuWillOpen()
        let phase = controller.phase
        let shortcut = settings.shortcut.displayName
        stateItem.title = Self.stateTitle(phase, elapsed: controller.elapsed)
        switch phase {
        case .recording:
            toggleItem.title = "録音を停止して送信（\(shortcut)）"
            toggleItem.isEnabled = true
        case .processing:
            toggleItem.title = "文字起こし中…"
            toggleItem.isEnabled = false
        default:
            toggleItem.title = "録音を開始（\(shortcut)）"
            toggleItem.isEnabled = true
        }
        cancelItem.isEnabled = phase.isBusy
        retryItem.isEnabled = controller.canRetry
        copyItem.isEnabled = controller.lastTranscript != nil
    }

    static func stateTitle(_ phase: DictationPhase, elapsed: TimeInterval) -> String {
        switch phase {
        case .idle, .inserted, .notice: return "待機中"
        case .recording: return "録音中 \(formatElapsed(elapsed))"
        case .processing: return "文字起こし中…"
        case .resultReady: return "結果をコピーできます"
        case .failed: return "エラーがあります"
        }
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleRecording() { actions.toggle() }
    @objc private func cancel() { actions.cancel() }
    @objc private func retry() { actions.retry() }
    @objc private func copyLast() { actions.copyLast() }
    @objc private func openSettings() { actions.openSettings() }
}
