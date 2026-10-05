# Third-party notices

hyprdarwin includes or adapts code from the projects below. Each adapted
source file names its origin in a header comment.

## HyprMac

https://github.com/zacharytgray/HyprMac (read at v0.17.0, commit f3e002a)

hyprdarwin ports these HyprMac techniques; it does not copy HyprMac's
configuration or GUI layers:

| hyprdarwin file | HyprMac origin | What was adapted |
|---|---|---|
| `Sources/HyprdarwinCore/Input/KeyMappingMerge.swift` | `HyprMac/Core/KeyRemapper.swift` | Merge rules for the Caps Lock -> F18 `UserKeyMapping` entry |
| `Sources/Hyprdarwin/Input/KeyRemapper.swift` | `HyprMac/Core/KeyRemapper.swift` | hidutil write and IOKit read of `UserKeyMapping` |
| `Sources/Hyprdarwin/Input/EventTap.swift` | `HyprMac/Core/HotkeyManager.swift` | Active session event tap on its own thread, Hypr key as a modifier, re-enable and health check |
| `Sources/Hyprdarwin/AX/AppWorker.swift` | `HyprMac/Core/Discovery/AXNotificationService.swift`, `HyprMac/Models/HyprWindow.swift` | Per-app AXObserver subscriptions, admitted window subroles, `AXEnhancedUserInterface` off around frame writes, size-move-size writes, `AXMinimumSize`/`AXMinSize` read with its 10000 sentinel (`HyprWindow.axMinimumSize()`, `MinSizeMemory.swift`) |
| `Sources/Hyprdarwin/AX/PrivateAPI.swift` | `HyprMac/PrivateAPI/CGSPrivate.h`, `HyprMac/Models/HyprWindow.swift` | `_AXUIElementGetWindow`, SkyLight focus calls |
| `Sources/HyprdarwinCore/WindowManager.swift` (`parkingOrigin`) | `HyprMac/Core/WorkspaceManager.swift` | Parking hidden windows in the outer corner of the outermost monitor |

```
MIT License

Copyright (c) 2026 Zachary Gray

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Lua 5.4.8

https://www.lua.org, vendored in `Sources/CLua` (see `Sources/CLua/LICENSE`
for the license text and the list of files left out).

Copyright (C) 1994-2025 Lua.org, PUC-Rio. MIT License.

## Hyprland

hyprdarwin follows the shape of Hyprland's Lua configuration API
(https://github.com/hyprwm/Hyprland, BSD 3-Clause). No Hyprland code is
included.
