/// Built-in border corner radii for common apps, so the border follows the
/// window's own corners. macOS 26 rounds a window by its style and no public
/// API reads another app's radius, so these are measured: the best-fit circle
/// to the window server's alpha of each window's corners on macOS 26.6.
/// A `rounding` window rule wins over this table; `border_radius` covers
/// every other app.
public enum AppRounding {
    /// Window style radii (measured on test windows of each AppKit style).
    static let titleBar = 18.0          // title bar only, or a hidden title bar
    static let compactToolbar = 22.0    // NSToolbar .unifiedCompact
    static let toolbar = 28.0           // NSToolbar .unified, sidebar windows

    /// Bundle id -> radius of its standard windows.
    public static let table: [String: Double] = [
        // Apple toolbar and sidebar windows (Safari measured 27.9)
        "com.apple.finder": toolbar,
        "com.apple.Safari": toolbar,
        "com.apple.mail": toolbar,
        "com.apple.systempreferences": toolbar,
        "com.apple.Notes": toolbar,
        "com.apple.reminders": toolbar,
        "com.apple.iCal": toolbar,
        "com.apple.MobileSMS": toolbar,
        "com.apple.Music": toolbar,
        "com.apple.Photos": toolbar,
        "com.apple.AppStore": toolbar,
        "com.apple.Preview": toolbar,
        // Chromium browsers (Brave measured 21.7, the compact toolbar radius)
        "com.brave.Browser": compactToolbar,
        "com.google.Chrome": compactToolbar,
        "com.microsoft.edgemac": compactToolbar,
        "org.chromium.Chromium": compactToolbar,
        // Electron apps with a hidden title bar (Slack measured 17.5)
        "com.tinyspeck.slackmacgap": titleBar,
        "com.microsoft.VSCode": titleBar,
        "com.hnc.Discord": titleBar,
        // terminals
        "com.mitchellh.ghostty": 21, // measured 20.8 with macos-titlebar-style = tabs
        "net.kovidgoyal.kitty": titleBar,
        "com.googlecode.iterm2": titleBar,
        "com.apple.Terminal": titleBar,
        // Mac Catalyst toolbar window (measured 27.4)
        "net.whatsapp.WhatsApp": toolbar,
    ]

    /// The table's radius for `window`. Only standard windows: an app's
    /// dialogs and panels have other styles, so they keep `border_radius`.
    public static func radius(for window: ManagedWindow) -> Double? {
        guard window.info.subrole == "AXStandardWindow" else { return nil }
        return table[window.info.bundleID]
    }
}
