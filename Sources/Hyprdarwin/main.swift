import AppKit
import HyprdarwinConfig

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print("hyprdarwin \(BuildInfo.current)")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// a menu bar app: no Dock icon, no main menu
app.setActivationPolicy(.accessory)
app.run()
