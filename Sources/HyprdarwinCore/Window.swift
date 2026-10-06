import CoreGraphics
import Foundation

/// What the window source knows about a window when it reports it.
public struct WindowInfo: Equatable, Sendable {
    public var id: WindowID
    public var pid: Int32
    /// Bundle identifier: Hyprland's `class`.
    public var bundleID: String
    /// Localized application name.
    public var appName: String
    public var title: String
    /// AX role and subrole, e.g. "AXWindow" / "AXStandardWindow" or "AXDialog".
    public var role: String
    public var subrole: String
    public var frame: CGRect
    /// False when the app does not let Accessibility resize the window.
    public var isResizable: Bool
    /// The smallest size the app allows, when it says so (AXMinimumSize).
    public var minSize: CGSize?

    public init(
        id: WindowID, pid: Int32, bundleID: String, appName: String, title: String,
        role: String = "AXWindow", subrole: String = "AXStandardWindow",
        frame: CGRect, isResizable: Bool = true, minSize: CGSize? = nil
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.isResizable = isResizable
        self.minSize = minSize
    }
}

public enum FullscreenMode: String, Sendable {
    /// Fills the monitor's visible area, ignoring gaps.
    case fullscreen
    /// Fills the visible area inside gaps_out.
    case maximized
}

/// A window under management.
public struct ManagedWindow: Equatable, Sendable {
    public var info: WindowInfo
    public var workspace: WorkspaceID
    public var isFloating: Bool
    public var fullscreen: FullscreenMode?
    /// Where the window sits while floating, in global coordinates.
    public var floatingFrame: CGRect
    /// `class` and `title` when the window first appeared.
    public var initialClass: String
    public var initialTitle: String
    public var tags: Set<String> = []
    /// Dynamic rule results, kept for the border overlay.
    public var borderColor: BorderColor?
    public var borderSize: Int?
    /// A min_size window rule.
    public var ruleMinSize: CGSize?
    /// The smallest size the app was seen to accept (it refused anything
    /// smaller), per axis; zero while unknown.
    public var learnedMinSize = CGSize.zero
    /// Order of arrival: the newest windows give way when minimums do not fit.
    public var sequence = 0

    public init(info: WindowInfo, workspace: WorkspaceID, isFloating: Bool) {
        self.info = info
        self.workspace = workspace
        self.isFloating = isFloating
        self.floatingFrame = info.frame
        self.initialClass = info.bundleID
        self.initialTitle = info.title
    }

    public var id: WindowID { info.id }

    /// What tiling must give the window: the largest of what the app
    /// reports, what it was seen to refuse and what a rule asks for.
    public var minimumSize: CGSize {
        let sizes = [info.minSize ?? .zero, learnedMinSize, ruleMinSize ?? .zero]
        return CGSize(width: sizes.map(\.width).max()!, height: sizes.map(\.height).max()!)
    }
}
