// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "hyprdarwin",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "hyprdarwin", targets: ["Hyprdarwin"]),
        .executable(name: "hyprdarwinctl", targets: ["hyprdarwinctl"]),
    ],
    targets: [
        // Lua 5.4, vendored (see Sources/CLua/LICENSE), plus the Swift shim.
        .target(
            name: "CLua",
            exclude: ["LICENSE"],
            cSettings: [
                .define("LUA_USE_POSIX"),
            ]
        ),
        // Pure model: workspaces, layouts, rules, binds, dispatchers. No AppKit.
        .target(
            name: "HyprdarwinCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Lua config runtime: hl.* API subset -> Config snapshot.
        .target(
            name: "HyprdarwinConfig",
            dependencies: ["CLua", "HyprdarwinCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // IPC transport: socket paths, the request and event socket servers and
        // the client. Foundation only, so hyprdarwinctl stays small.
        .target(
            name: "HyprdarwinIPC",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // What the sockets and the settings window say about the model and
        // the config: hyprctl-style queries (text and JSON), config report.
        .target(
            name: "HyprdarwinControl",
            dependencies: ["HyprdarwinCore", "HyprdarwinConfig", "HyprdarwinIPC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The menu bar app: AX window source and applier, event tap, config
        // watcher, IPC sockets, settings window.
        .executableTarget(
            name: "Hyprdarwin",
            dependencies: ["HyprdarwinCore", "HyprdarwinConfig", "HyprdarwinIPC", "HyprdarwinControl"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The hyprctl-style command line client, shipped inside the app bundle.
        .executableTarget(
            name: "hyprdarwinctl",
            dependencies: ["HyprdarwinIPC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HyprdarwinCoreTests",
            dependencies: ["HyprdarwinCore"]
        ),
        .testTarget(
            name: "HyprdarwinConfigTests",
            dependencies: ["HyprdarwinConfig", "HyprdarwinCore"]
        ),
        .testTarget(
            name: "HyprdarwinIPCTests",
            dependencies: ["HyprdarwinIPC"]
        ),
        .testTarget(
            name: "HyprdarwinControlTests",
            dependencies: ["HyprdarwinControl", "HyprdarwinConfig", "HyprdarwinCore", "HyprdarwinIPC"]
        ),
    ]
)
