import AppKit
import HyprdarwinCore

/// Writes the model's plan to the windows and keeps them there.
///
/// The plan is the single source of truth. A window is written when its
/// target changes; when it drifts away (an app nudging itself, a drag) it is
/// re-asserted a bounded number of times, then accepted as is (apps with a
/// minimum size win). There is no read-back/rollback transaction on top of
/// AX, which is asynchronous and lossy by nature.
final class FrameApplier {
    private let source: WindowSource

    /// A tiled window was dragged by the user and released at a point.
    /// Return true when the controller rearranged the layout in response.
    var onUserDrop: ((WindowID, CGPoint) -> Bool)?
    /// The user moved or resized a floating window.
    var onFloatingMoved: ((WindowID, CGRect) -> Void)?
    /// A tiled window stayed larger than written, twice in a row: the app
    /// refuses to shrink that far. Carries the size that was asked for.
    var onSizeRefused: ((WindowID, CGSize) -> Void)?

    var isEnabled = true

    private struct Target {
        var frame: CGRect
        var pid: pid_t
        var parked: Bool
        var reasserts = 0
        var retried = false
    }

    private var targets: [WindowID: Target] = [:]
    private var lastWrite: [WindowID: Date] = [:]
    private var driftChecks: [WindowID: DispatchWorkItem] = [:]
    private var dragged: Set<WindowID> = []
    private var lastObserved: [WindowID: CGRect] = [:]

    private static let settleTime: TimeInterval = 0.25
    private static let maxReasserts = 2
    /// Larger than this past the written size is a refusal, not rounding
    /// (terminals snap to their character cells).
    static let refusalSlack = 4.0

    init(source: WindowSource) {
        self.source = source
    }

    /// Bring every window to where `plan` says it belongs.
    func apply(_ plan: Plan, model: WindowManager) {
        guard isEnabled else { return }
        var batch: [(pid: pid_t, id: WindowID, frame: CGRect, positionOnly: Bool)] = []
        for (id, placement) in plan.placements {
            guard let window = model.windows[id] else { continue }
            let frame: CGRect
            let parked: Bool
            switch placement {
            case .frame(let rect):
                frame = rect
                parked = false
            case .hidden(let origin):
                frame = CGRect(origin: origin, size: window.info.frame.size)
                parked = true
            }
            if let existing = targets[id], existing.parked == parked,
               parked ? existing.frame.origin == frame.origin : existing.frame.isClose(to: frame, tolerance: 0.5) {
                continue
            }
            targets[id] = Target(frame: frame, pid: window.info.pid, parked: parked)
            batch.append((window.info.pid, id, frame, parked))
            lastWrite[id] = Date()
        }
        for id in targets.keys where plan.placements[id] == nil {
            targets[id] = nil
            lastObserved[id] = nil
            lastWrite[id] = nil
            driftChecks.removeValue(forKey: id)?.cancel()
        }
        if !batch.isEmpty {
            Log.debug("apply: writing \(batch.count) window(s): " + batch.map { "\($0.id)\($0.positionOnly ? " park" : "")=\(Self.describe($0.frame))" }.joined(separator: ", "))
            source.setFrames(batch)
        }
    }

    /// Forget everything (pause, or the next apply must rewrite all windows).
    func reset() {
        targets.removeAll()
        lastWrite.removeAll()
        driftChecks.values.forEach { $0.cancel() }
        driftChecks.removeAll()
        dragged.removeAll()
        lastObserved.removeAll()
    }

    /// Frames read back right after a write batch.
    func applied(_ results: [WindowID: CGRect]) {
        for (id, frame) in results {
            lastWrite[id] = Date()
            guard var target = targets[id], !matches(frame, target) else { continue }
            if !target.retried {
                // some apps settle only after a second write
                target.retried = true
                targets[id] = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.rewrite(id) }
            } else {
                Log.debug("apply: accepting window \(id) at \(Self.describe(frame)), wanted \(Self.describe(target.frame))")
                if !target.parked, frame.width > target.frame.width + Self.refusalSlack || frame.height > target.frame.height + Self.refusalSlack {
                    onSizeRefused?(id, target.frame.size)
                }
            }
        }
    }

    /// A frame the window reported on its own (moved/resized notification).
    func observed(_ id: WindowID, frame: CGRect, model: WindowManager) {
        guard isEnabled, let target = targets[id], let window = model.windows[id] else { return }
        if matches(frame, target) {
            driftChecks.removeValue(forKey: id)?.cancel()
            return
        }
        if let last = lastWrite[id], Date().timeIntervalSince(last) < Self.settleTime { return }
        if !target.parked, window.isFloating, window.fullscreen == nil {
            // the user placed a floating window: that is its new home
            targets[id]?.frame = frame
            onFloatingMoved?(id, frame)
            return
        }
        lastObserved[id] = frame
        if isUserDrag(frame, target) { dragged.insert(id) }
        scheduleDriftCheck(id)
    }

    /// A drag moves the window (a resize-only change is the app snapping its
    /// size) with a button held and the cursor on the window itself.
    private func isUserDrag(_ frame: CGRect, _ target: Target) -> Bool {
        guard !target.parked, NSEvent.pressedMouseButtons != 0 else { return false }
        let moved = abs(frame.minX - target.frame.minX) > 8 || abs(frame.minY - target.frame.minY) > 8
        return moved && frame.contains(Self.cursorLocation())
    }

    private func matches(_ frame: CGRect, _ target: Target) -> Bool {
        if target.parked {
            // macOS keeps a parked window's title bar reachable by raising it a
            // little; only the horizontal position says it is off screen
            return abs(frame.minX - target.frame.minX) <= 2 && frame.minY <= target.frame.minY + 2
        }
        return frame.isClose(to: target.frame, tolerance: 2)
    }

    private func scheduleDriftCheck(_ id: WindowID) {
        driftChecks[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkDrift(id) }
        driftChecks[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func checkDrift(_ id: WindowID) {
        driftChecks[id] = nil
        guard targets[id] != nil else { return }
        if NSEvent.pressedMouseButtons != 0 {
            // a button is still held: wait for the drop before touching it
            scheduleDriftCheck(id)
            return
        }
        if dragged.remove(id) != nil {
            targets[id]?.reasserts = 0
            let point = Self.cursorLocation()
            if lastObserved[id]?.contains(point) == true, onUserDrop?(id, point) == true { return }
            rewrite(id)
            return
        }
        guard let target = targets[id], target.reasserts < Self.maxReasserts else { return }
        targets[id]?.reasserts += 1
        Log.debug("apply: window \(id) drifted, re-asserting (\(target.reasserts + 1)/\(Self.maxReasserts))")
        rewrite(id)
    }

    private func rewrite(_ id: WindowID) {
        guard isEnabled, let target = targets[id] else { return }
        lastWrite[id] = Date()
        source.setFrames([(target.pid, id, target.frame, target.parked)])
    }

    static func cursorLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }

    static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}
