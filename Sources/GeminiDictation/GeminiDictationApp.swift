import AppKit
import DictationMac

@main
struct GeminiDictationApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Menu bar only: no Dock icon (also set via LSUIElement in Info.plist).
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
