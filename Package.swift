// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "hyprdarwin",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "hyprdarwin", targets: ["Hyprdarwin"]),
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
        // The menu bar app: AX window source and applier, event tap, config watcher.
        .executableTarget(
            name: "Hyprdarwin",
            dependencies: ["HyprdarwinCore", "HyprdarwinConfig"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HyprdarwinCoreTests",
            dependencies: ["HyprdarwinCore"]
        ),
        .testTarget(
            name: "HyprdarwinConfigTests",
            dependencies: ["HyprdarwinConfig", "HyprdarwinCore"]
        ),
    ]
)
