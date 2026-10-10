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
