import AppKit
import DictationCore
import DictationMac
import SwiftUI

/// Renders the Settings window and each status panel state to PNG files.
/// Uses in-memory settings and fake permission state: no UserDefaults, Keychain,
/// microphone, network or screen-recording access is involved.
@main
struct UISnapshots {
    @MainActor
    static func main() {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/ui-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        var written: [String] = []
        func save<V: View>(_ name: String, _ view: V) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let url = output.appendingPathComponent("\(name)-\(suffix).png")
                if Renderer.render(view, appearance: appearance, to: url) {
                    written.append(url.lastPathComponent)
                } else {
                    FileHandle.standardError.write(Data("failed: \(url.lastPathComponent)\n".utf8))
                }
            }
        }

        func makeSettingsModel() -> SettingsModel {
            let settings = AppSettings(store: InMemoryKeyValueStore())
            let shortcuts = ShortcutController(
                settings: settings,
                hotKeys: InertHotKeys(),
                hotKeyID: 1,
                fnMonitor: InertFnMonitor(),
                keyEvents: InertKeyEvents(),
                systemShortcuts: InertSystemShortcuts(),
                isTrusted: { false },
                sleeper: NeverSleeper(),
                onToggle: {}
            )
            shortcuts.activate()
            return SettingsModel(
                settings: settings,
                keys: APIKeyManager(store: InMemorySecretStore(), settings: settings),
                permissions: FakePermissions(),
                shortcuts: shortcuts
            )
        }
        // Taller than the real window so the whole scrolling form is visible in one image.
        save("settings", SettingsView(model: makeSettingsModel(), height: 1500))
        let recordingModel = makeSettingsModel()
        recordingModel.shortcuts.startRecording()
        save("settings-recording-shortcut", SettingsView(model: recordingModel, height: 1500))

        for (name, content) in Samples.hudStates {
            save("hud-\(name)", HUDView(content: content, perform: { _ in }).padding(20))
        }

        print("Wrote \(written.count) files to \(output.path):")
        written.sorted().forEach { print("  \($0)") }
    }
}

// Stand-ins that never register hot keys, install event monitors or ask macOS anything.
@MainActor
final class InertHotKeys: HotKeyRegistering {
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping HotKeyCenter.Handler) -> Bool { true }
    func unregister(id: UInt32) {}
    func isRegistered(id: UInt32) -> Bool { false }
}

@MainActor
final class InertFnMonitor: FnKeyMonitoring {
    var allowsTap = false
    var isRunning: Bool { false }
    func start(onHold: @escaping @MainActor () -> Void) {}
    func stop() {}
}

@MainActor
final class InertKeyEvents: ShortcutKeyEventSource {
    func start(_ handler: @escaping @MainActor (ShortcutRecording.Input) -> Void) {}
    func stop() {}
}

@MainActor
final class InertSystemShortcuts: SystemShortcutProviding {
    func enabledShortcuts() -> Set<SystemShortcut> { [] }
}

struct NeverSleeper: Sleeping {
    func sleep(seconds: Double) async throws {
        throw CancellationError()
    }
}

@MainActor
final class FakePermissions: PermissionStatusProviding {
    func microphoneStatus() -> MicrophoneAuthorization { .notDetermined }
    func isAccessibilityTrusted() -> Bool { false }
    func requestAccessibility() {}
    func open(_ pane: SystemSettingsPane) {}
}

@MainActor
enum Samples {
    static let model = ModelCatalog.model(for: ModelCatalog.defaultModelID)

    static func content(_ phase: DictationPhase, transcript: String? = nil, canRetry: Bool = false) -> HUDContent {
        HUDContent.make(
            phase: phase,
            elapsed: 12,
            limit: 300,
            level: 0.55,
            transcript: transcript,
            modelName: model.displayName,
            targetAppName: "テキストエディット",
            canRetry: canRetry,
            shortcut: Shortcut.default.displayName
        )!
    }

    static var hudStates: [(String, HUDContent)] {
        [
            ("recording", content(.recording)),
            ("processing", content(.processing(attempt: 1))),
            ("retrying", content(.processing(attempt: 2))),
            ("result-focus-changed", content(.resultReady(.focusChanged), transcript: "来週の打ち合わせは水曜日の14時からに変更します。資料は前日までに共有してください。")),
            ("result-no-accessibility", content(.resultReady(.accessibilityNotGranted), transcript: "テストの文字起こし結果です。")),
            ("failed-missing-key", content(.failed(.missingAPIKey))),
            ("failed-auth-retry", content(.failed(.transcription(.authentication("API key expired."))), canRetry: true)),
            ("failed-microphone", content(.failed(.microphoneDenied))),
            ("notice-too-short", content(.notice(.tooShort))),
        ]
    }
}

@MainActor
enum Renderer {
    /// Lays the view out in an offscreen window and draws it into a bitmap.
    static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return false }
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
