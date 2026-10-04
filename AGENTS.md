# Project agent memory

hyprdarwin: a personal, Hyprland-inspired tiling window manager for macOS (target: the owner's Mac only, macOS 26 on Apple Silicon; never requires disabling SIP). Lua config in a subset of Hyprland's `hl.*` API. README.md is the user-facing reference (config API, build, signing, permissions).

## Build and test

- `swift build`, `swift test` (SwiftPM; Swift Testing only, no XCTest: the Mac has Command Line Tools, not Xcode).
- With only Command Line Tools, `swift test` can fail with "plugin for module 'TestingMacros' not found". Workaround: `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`. CI (Xcode) does not need it.
- The authoritative build is GitHub Actions (`.github/workflows/build.yml`, macOS arm64): tests with warnings as errors, then `scripts/build-app.sh` produces the signed `hyprdarwin-app` artifact. Do not install tools on the owner's Mac; verify by downloading the CI artifact.
- Signing: `scripts/build-app.sh` signs with identity `hyprdarwin-local` if present, else ad-hoc. CI uses secrets `HYPRDARWIN_SIGNING_P12`/`HYPRDARWIN_SIGNING_PASSWORD` via `scripts/ci-signing-keychain.sh`, else a throwaway identity. codesign refuses untrusted self-signed identities, hence the trust step in both scripts.

## Architecture

- `Sources/HyprdarwinCore`: pure model, no AppKit. `WindowManager` takes window/monitor/config/dispatch inputs and returns a `Plan` (frame or park point per window), `Effect`s and Hyprland-named `WMEvent`s. Layouts (`Layout/`), rules (`Rules/`), keys (`Input/`). Keep it system-free and unit-tested.
- `Sources/HyprdarwinConfig`: Lua runtime (`LuaConfigRuntime`) building an immutable `Config`; fresh sandboxed state per load; dispatchers parsed in `DispatcherParser`, options/rules in `ConfigBuilder`. `Sources/CLua` is vendored Lua 5.4.8 plus `hd_shim.c`: Swift must never be unwound by `lua_error`, so builtins return `HD_RAISE` and the C trampoline raises; read user tables with raw access only.
- `Sources/Hyprdarwin`: the app. `AppController` wires `WindowSource`/`AppWorker` (one thread + AXObserver per app) -> model -> `FrameApplier` (writes plan, bounded drift re-assert, no rollback) plus `EventTap` (binds), `KeyRemapper` (Caps Lock -> F18 via hidutil), `ConfigWatcher` (FSEvents on the config directory).
- Next milestone seams: `AppController.onEvent` (event socket, border overlay), model queries (request socket), `activeConfig`/`messages` (read-only settings window).
- Code adapted from HyprMac carries a file header and is listed in THIRD_PARTY_NOTICES.md; keep both when porting more.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
