// Adapted from HyprMac (https://github.com/zacharytgray/HyprMac),
// HyprMac/Core/HotkeyManager.swift, MIT License, Copyright (c) 2026
// Zachary Gray: an active session event tap on a dedicated thread, the Hypr
// key as an extra modifier tracked from F18, re-enabling after a timeout and
// a health check. Generalised here to submaps and bind flags.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import HyprdarwinCore

/// Global keyboard interception for binds.
///
/// The tap is active: macOS holds every keystroke until the callback returns,
/// so it lives on its own thread and the callback does only table lookups.
/// Matched binds are reported on the main thread through `onBind` with the
/// bind's index in the config. State shared with the main thread is guarded
/// by `lock`.
final class EventTap {
    /// Index into the active config's `binds`.
    var onBind: ((Int) -> Void)?

    private struct BindKey: Hashable {
        var submap: String
        var keyCode: UInt16
        var modifiers: Modifiers
    }

    private struct Entry {
        var index: Int
        var repeating: Bool
        var release: Bool
    }

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var healthTimer: Timer?
    private let lock = NSLock()

    // guarded by lock
    private var table: [BindKey: [Entry]] = [:]
    private var submap = ""
    private var hyprKeyCode: UInt16? = KeyCodes.f18
    private var paused = false
    private var hyprDown = false
    private var consumedKeys: Set<UInt16> = []
    private var releaseBinds: [UInt16: [Int]] = [:]

    var isRunning: Bool { tap != nil }

    func update(binds: [Keybind], hyprKey: HyprKeyMode) {
        var table: [BindKey: [Entry]] = [:]
        for (index, bind) in binds.enumerated() where bind.enabled {
            let key = BindKey(submap: bind.submap ?? "", keyCode: bind.combo.keyCode, modifiers: bind.combo.modifiers)
            table[key, default: []].append(Entry(index: index, repeating: bind.repeating, release: bind.release))
        }
        lock.lock()
        self.table = table
        hyprKeyCode = hyprKey == .none ? nil : KeyCodes.f18
        releaseBinds.removeAll()
        lock.unlock()
    }

    func setSubmap(_ name: String) {
        lock.lock()
        submap = name
        lock.unlock()
    }

    func setPaused(_ isPaused: Bool) {
        lock.lock()
        paused = isPaused
        hyprDown = false
        consumedKeys.removeAll()
        releaseBinds.removeAll()
        lock.unlock()
    }

    /// Clear key state that a missed key-up could leave stuck (sleep, lock,
    /// tap timeouts).
    func resetState() {
        lock.lock()
        hyprDown = false
        consumedKeys.removeAll()
        releaseBinds.removeAll()
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: eventTapCallback, userInfo: refcon
        ) else {
            Log.error("could not create the keyboard event tap (Accessibility permission missing?)")
            return false
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "hyprdarwin.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        // a tap can stop delivering without a disable event (TCC changes, re-signing)
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            Log.info("keyboard event tap was disabled; re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            self.resetState()
        }
        Log.info("keyboard event tap started")
        return true
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        resetState()
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        resetState()
    }

    /// Tap thread. Returns nil to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        lock.lock()
        defer { lock.unlock() }
        if paused { return event }

        if let hyprKeyCode, keyCode == hyprKeyCode {
            hyprDown = type == .keyDown
            return nil
        }

        var modifiers = Modifiers()
        let flags = event.flags
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if hyprDown { modifiers.insert(.hypr) }

        if type == .keyUp {
            if let pending = releaseBinds.removeValue(forKey: keyCode) {
                fire(pending)
            }
            return consumedKeys.remove(keyCode) != nil ? nil : event
        }

        guard let entries = table[BindKey(submap: submap, keyCode: keyCode, modifiers: modifiers)] else {
            // HYPR + an unbound key types nothing rather than a bare letter
            if hyprDown {
                consumedKeys.insert(keyCode)
                return nil
            }
            return event
        }
        consumedKeys.insert(keyCode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var now: [Int] = []
        for entry in entries {
            if entry.release {
                if !isRepeat { releaseBinds[keyCode, default: []].append(entry.index) }
            } else if !isRepeat || entry.repeating {
                now.append(entry.index)
            }
        }
        fire(now)
        return nil
    }

    private func fire(_ indexes: [Int]) {
        guard !indexes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for index in indexes { self?.onBind?(index) }
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        Log.info("keyboard event tap disabled by the system; re-enabling")
        tap.reenable()
        return Unmanaged.passUnretained(event)
    case .keyDown, .keyUp:
        guard let result = tap.handle(type, event) else { return nil }
        return Unmanaged.passUnretained(result)
    default:
        return Unmanaged.passUnretained(event)
    }
}
