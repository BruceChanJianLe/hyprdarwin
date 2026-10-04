import AppKit
import HyprdarwinConfig

/// The menu bar item: status, current workspace, Reload, Open Config,
/// Show Errors, Pause and Quit.
final class MenuBarController: NSObject {
    enum Status: Equatable {
        case waitingForAccessibility
        case running
        case paused
        case configError
    }

    struct State: Equatable {
        var status = Status.waitingForAccessibility
        var workspace = "1"
        var special: String?
        var submap = ""
        var messages: [ConfigMessage] = []
        var configPath = ""
    }

    var onReload: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onShowMessages: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var state = State()

    override init() {
        super.init()
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        render()
    }

    func update(_ newState: State) {
        guard newState != state else { return }
        state = newState
        render()
    }

    private func render() {
        let symbol: String
        switch state.status {
        case .waitingForAccessibility: symbol = "lock.rectangle"
        case .running: symbol = "rectangle.split.2x2"
        case .paused: symbol = "pause.rectangle"
        case .configError: symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "hyprdarwin")
        image?.isTemplate = true
        item.button?.image = image
        var title = state.status == .waitingForAccessibility ? "" : state.workspace
        if let special = state.special { title += " · \(special)" }
        if !state.submap.isEmpty { title += " [\(state.submap)]" }
        item.button?.title = title.isEmpty ? "" : " \(title)"
        item.button?.toolTip = "hyprdarwin"

        menu.removeAllItems()
        let statusText: String
        switch state.status {
        case .waitingForAccessibility: statusText = "Waiting for Accessibility permission"
        case .running: statusText = "hyprdarwin is running"
        case .paused: statusText = "hyprdarwin is paused"
        case .configError: statusText = "Running, but the config has errors"
        }
        menu.addItem(disabled(statusText))
        if state.status != .waitingForAccessibility {
            var workspace = "Workspace \(state.workspace)"
            if let special = state.special { workspace += " (special:\(special) open)" }
            menu.addItem(disabled(workspace))
            if !state.submap.isEmpty { menu.addItem(disabled("Submap: \(state.submap)")) }
        }
        menu.addItem(.separator())
        if state.status == .waitingForAccessibility {
            menu.addItem(action("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        menu.addItem(action("Reload Config", #selector(reload), key: "r"))
        let open = action("Open Config", #selector(openConfig), key: "o")
        open.toolTip = state.configPath
        menu.addItem(open)
        let errors = state.messages.filter { $0.severity == .error }.count
        let warnings = state.messages.filter { $0.severity == .warning }.count
        var messagesTitle = "Show Errors…"
        if errors + warnings > 0 {
            messagesTitle = "Show Errors (\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s"))…"
        }
        let messages = action(messagesTitle, #selector(showMessages), key: "e")
        messages.isEnabled = !state.messages.isEmpty
        menu.addItem(messages)
        menu.addItem(.separator())
        let pause = action(state.status == .paused ? "Resume" : "Pause", #selector(togglePause), key: "p")
        pause.isEnabled = state.status != .waitingForAccessibility
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(action("Quit hyprdarwin", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func reload() { onReload?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func showMessages() { onShowMessages?() }
    @objc private func togglePause() { onTogglePause?() }
    @objc private func openAccessibility() { onOpenAccessibilitySettings?() }
    @objc private func quit() { onQuit?() }
}
