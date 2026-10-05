import AppKit
import HyprdarwinCore
import QuartzCore

/// Hyprland-style window borders: a ring around every visible managed
/// window, `general.col.active_border` on the focused one and
/// `general.col.inactive_border` (none by default) on the rest (gradients
/// supported).
///
/// Each ring is a borderless, click-through, non-activating panel ordered
/// directly above its own window, so it never covers windows stacked above
/// that one and never takes focus or clicks. The ring sits outside the
/// window frame, in the gap, so the window itself never hides it.
final class BorderController {
    private var panels: [WindowID: BorderPanel] = [:]

    /// Draw, move and recolour the borders. `activeWindow` is the window that
    /// actually has keyboard focus (nil when an unmanaged app has it).
    func update(model: WindowManager, plan: Plan, activeWindow: WindowID?) {
        let config = model.config
        var keep: Set<WindowID> = []
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for (id, placement) in plan.placements {
            guard case .frame(let planned) = placement, let window = model.windows[id] else { continue }
            let size = window.borderSize ?? config.borderSize
            guard size > 0, window.fullscreen != .fullscreen else { continue }
            // the real frame when the window is where it belongs; the planned
            // one while it is still on its way back from the parking corner
            let actual = window.info.frame
            let frame = actual.intersects(planned) ? actual : planned
            let isActive = id == activeWindow
            guard let colors = window.borderColor ?? (isActive ? config.activeBorder : config.inactiveBorder) else { continue }

            let panel = panels[id] ?? BorderPanel()
            panels[id] = panel
            keep.insert(id)
            let width = CGFloat(size)
            let rect = NSRect(x: frame.minX - width, y: primaryHeight - frame.maxY - width,
                              width: frame.width + 2 * width, height: frame.height + 2 * width)
            panel.ring.configure(colors: colors, width: width, radius: CGFloat(config.borderRadius))
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            // directly above its own window, below anything stacked above it
            panel.order(.above, relativeTo: Int(id))
        }
        for (id, panel) in panels where !keep.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    func hideAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

private final class BorderPanel: NSPanel {
    let ring = RingView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .normal
        collectionBehavior = [.ignoresCycle, .stationary]
        contentView = ring
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RingView: NSView {
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()
    private var current: (BorderColor, CGFloat, CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.mask = mask
        mask.fillRule = .evenOdd
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(colors: BorderColor, width: CGFloat, radius: CGFloat) {
        if let current, current.0 == colors, current.1 == width, current.2 == radius { return }
        current = (colors, width, radius)
        let cgColors = colors.colors.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
        gradient.colors = cgColors.count == 1 ? [cgColors[0], cgColors[0]] : cgColors
        // Hyprland angles: 0 runs left to right, 90 bottom to top
        let radians = colors.angle * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        gradient.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
        gradient.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        mask.frame = bounds
        if let (_, width, radius) = current {
            let path = CGMutablePath()
            path.addRoundedRect(in: bounds, cornerWidth: radius + width, cornerHeight: radius + width)
            let inner = bounds.insetBy(dx: width, dy: width)
            path.addRoundedRect(in: inner, cornerWidth: min(radius, inner.width / 2), cornerHeight: min(radius, inner.height / 2))
            mask.path = path
        }
        CATransaction.commit()
    }
}
