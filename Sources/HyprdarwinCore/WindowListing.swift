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

/// A window the window server has on screen (ordered in on the current
/// Space; parked windows count).
public struct ScreenWindow: Equatable, Sendable {
    public var pid: Int32
    /// 0 is the normal layer app windows live on; menus and tooltips sit higher.
    public var layer: Int

    public init(pid: Int32, layer: Int = 0) {
        self.pid = pid
        self.layer = layer
    }
}

/// Accessibility does not always say when an app's windows come and go.
/// Chromium browsers such as Brave can close a window by ordering it out and
/// keeping it alive, so no destroyed notification comes; and their new
/// windows are not yet listed when the created notification arrives. Either
/// way the window only shows up in (or drops out of) the app's window list,
/// and its tile, border and focus target would wait for the periodic
/// re-list. The window server cheaply tells when it disagrees with an app's
/// last list; that app then re-lists its windows, and the list decides.
/// A busy app may send no list, or one that still disagrees, so each
/// disagreement asks again with backoff before leaving it to the periodic
/// re-list.
public struct ListingProbe {
    /// The waits before each re-ask after the first.
    public static let retryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4]

    private struct Ask {
        var retries = 0
        var due: Date
    }

    private var asks: [WindowID: Ask] = [:]

    public init() {}

    /// The apps to re-list. `listed` holds every watched app's last window
    /// list (empty when it lists none). A listed window off screen, or a
    /// normal-layer window on screen its app did not list, asks at once,
    /// again after each of `retryDelays` while it lasts, then not until it
    /// has cleared.
    public mutating func appsToRelist(listed: [Int32: Set<WindowID>], onScreen: [WindowID: ScreenWindow], now: Date) -> Set<Int32> {
        var disagreeing: [WindowID: Int32] = [:]
        for (pid, ids) in listed {
            for id in ids where onScreen[id] == nil { disagreeing[id] = pid }
        }
        for (id, window) in onScreen where window.layer == 0 && listed[window.pid]?.contains(id) == false {
            disagreeing[id] = window.pid
        }
        asks = asks.filter { disagreeing[$0.key] != nil }
        var pids: Set<Int32> = []
        for (id, pid) in disagreeing {
            var ask = asks[id] ?? Ask(due: now)
            guard ask.retries <= Self.retryDelays.count, now >= ask.due else { continue }
            pids.insert(pid)
            if ask.retries < Self.retryDelays.count { ask.due = now.addingTimeInterval(Self.retryDelays[ask.retries]) }
            ask.retries += 1
            asks[id] = ask
        }
        return pids
    }
}
