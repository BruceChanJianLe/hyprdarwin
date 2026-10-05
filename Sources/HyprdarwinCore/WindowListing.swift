import Foundation

/// What one app's fresh window list changed in the model, in order.
public enum ListingChange: Equatable {
    /// A native tab switch: the new tab window took the old one's place.
    case replaced(old: WindowID, new: WindowID)
    /// No longer listed: closed, minimized, hidden or on another Space.
    case removed(WindowID, effects: [Effect])
    /// Newly managed. `isNew` when it just opened, not when it was found at
    /// startup or adopted from an app that was unmanaged.
    case added(WindowID, isNew: Bool, effects: [Effect])
}

extension WindowManager {
    /// Apply an app's complete list of manageable windows. `previous` is what
    /// it listed last time, managed or not. A window it no longer lists is
    /// gone whether or not a destroyed notification came for it, so this is
    /// also the safety net for apps that close windows without one.
    @discardableResult
    public func applyListing(_ infos: [WindowInfo], previous: Set<WindowID>, initial: Bool) -> [ListingChange] {
        var changes: [ListingChange] = []
        let current = Set(infos.map(\.id))
        var gone = previous.subtracting(current).filter { windows[$0] != nil }
        for info in infos where !previous.contains(info.id) && windows[info.id] == nil {
            // switching native tabs swaps one tab window for another at the
            // same frame: keep its place instead of closing and reopening
            guard let old = gone.sorted().first(where: { windows[$0]?.info.frame.isClose(to: info.frame, tolerance: 4) == true }) else { continue }
            gone.remove(old)
            replaceWindow(old, with: info)
            changes.append(.replaced(old: old, new: info.id))
        }
        for id in gone.sorted() {
            changes.append(.removed(id, effects: removeWindow(id)))
        }
        for info in infos {
            if windows[info.id] != nil {
                updateInfo(info)
            } else {
                // a window seen before (its app was unmanaged) is adopted, not opened
                let isNew = !initial && !previous.contains(info.id)
                let effects = addWindow(info, isNew: isNew)
                if windows[info.id] != nil { changes.append(.added(info.id, isNew: isNew, effects: effects)) }
            }
        }
        return changes
    }
}

/// Some apps close a window without Accessibility ever posting its destroyed
/// notification: Chromium browsers such as Brave can order the closed window
/// out and keep it alive, and it only drops out of the app's window list, so
/// its tile, border and focus target would linger until the next periodic
/// re-list. The window server cheaply tells that a managed window left the
/// screen; that app then re-lists its windows, and the list decides.
public struct VanishedWindowProbe {
    private var asked: Set<WindowID> = []

    public init() {}

    /// The apps to re-list, given the windows on screen now (ordered in on
    /// the current Space; parked windows count). Each window asks once when
    /// it leaves the screen, and again only after it has been back on it.
    public mutating func appsToRelist(model: WindowManager, onScreen: Set<WindowID>) -> Set<Int32> {
        let vanished = Set(model.windows.keys).subtracting(onScreen)
        let fresh = vanished.subtracting(asked)
        asked = vanished
        return Set(fresh.compactMap { model.windows[$0]?.info.pid })
    }
}
