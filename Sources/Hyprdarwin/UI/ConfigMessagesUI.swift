import AppKit
import HyprdarwinConfig

/// A slim banner at the top of the main screen, like Hyprland's config error
/// bar. Red for errors (stays until the config loads cleanly), amber for
/// warnings (fades after a few seconds). Clicking it opens the messages.
final class ErrorBanner {
    var onClick: (() -> Void)?

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(error: String, extra: Int) {
        present(text: "hyprdarwin config error: \(error)" + (extra > 0 ? "  (+\(extra) more)" : ""),
                color: NSColor(calibratedRed: 0.78, green: 0.16, blue: 0.18, alpha: 0.97), autoHide: false)
    }

    func show(warning: String, extra: Int) {
        present(text: "hyprdarwin config warning: \(warning)" + (extra > 0 ? "  (+\(extra) more)" : ""),
                color: NSColor(calibratedRed: 0.80, green: 0.52, blue: 0.05, alpha: 0.97), autoHide: true)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private func present(text: String, color: NSColor, autoHide: Bool) {
        hideWork?.cancel()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let label = panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first
        label?.stringValue = text
        panel.contentView?.layer?.backgroundColor = color.cgColor

        let width = min(screen.visibleFrame.width - 40, 960)
        let height: CGFloat = 30
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - height - 8, width: width, height: height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        if autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let content = ClickView(frame: .zero)
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.onClick = { [weak self] in self?.onClick?() }
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        return panel
    }

    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}

/// Read-only window listing the latest config errors, warnings and notes.
final class MessagesWindow {
    private var window: NSWindow?
    private var textView: NSTextView?

    func show(messages: [ConfigMessage], path: String) {
        let window = self.window ?? makeWindow()
        self.window = window
        let text = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        text.append(NSAttributedString(string: "Config: \(path)\n\n", attributes: [.font: bold, .foregroundColor: NSColor.labelColor]))
        if messages.isEmpty {
            text.append(NSAttributedString(string: "No errors or warnings.\n", attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for severity in [ConfigMessage.Severity.error, .warning, .info] {
            let group = messages.filter { $0.severity == severity }
            guard !group.isEmpty else { continue }
            let heading: String
            let color: NSColor
            switch severity {
            case .error: heading = "Errors (the previous config stays active)"; color = .systemRed
            case .warning: heading = "Warnings"; color = .systemOrange
            case .info: heading = "Notes (Hyprland features ignored on macOS, print output)"; color = .secondaryLabelColor
            }
            text.append(NSAttributedString(string: "\(heading)\n", attributes: [.font: bold, .foregroundColor: color]))
            for message in group {
                text.append(NSAttributedString(string: "  \(message.text)\n", attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
            }
            text.append(NSAttributedString(string: "\n"))
        }
        textView?.textStorage?.setAttributedString(text)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "hyprdarwin config messages"
        window.isReleasedWhenClosed = false
        window.center()
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        window.contentView?.addSubview(scroll)
        textView = text
        return window
    }
}
