// Adapted from HyprMac (https://github.com/zacharytgray/HyprMac),
// HyprMac/Core/KeyRemapper.swift, MIT License, Copyright (c) 2026 Zachary Gray.
// See THIRD_PARTY_NOTICES.md.

import Foundation
import HyprdarwinCore
import IOKit.hid
import IOKit.hidsystem

/// Maps Caps Lock to F18 at the HID driver level with `hidutil`, so the
/// event tap sees clean F18 key-down/key-up events (Caps Lock itself is a
/// toggle that never reaches a tap). No Karabiner needed.
///
/// This only works while Caps Lock is left on "Caps Lock" in System Settings
/// > Keyboard > Keyboard Shortcuts > Modifier Keys; that pane applies first.
enum KeyRemapper {
    /// Foreign Caps Lock mappings ours replaced, kept across launches so a
    /// crash does not lose them.
    private static let heldKey = "heldCapsLockKeyMappings"

    static func install() { update(.install) }
    static func remove() { update(.remove) }

    private static func update(_ operation: KeyMappingMerge.Operation) {
        let defaults = UserDefaults.standard
        let held = (defaults.data(forKey: heldKey)).flatMap { try? JSONDecoder().decode([HIDKeyMapping].self, from: $0) } ?? []
        guard let plan = KeyMappingMerge.plan(operation, read: readUserKeyMapping(), held: held) else {
            Log.error("UserKeyMapping \(operation.rawValue): the list has an entry hyprdarwin cannot reproduce, left unchanged")
            return
        }
        // store a new hold before writing so a crash mid-write cannot lose it
        if !plan.held.isEmpty { save(plan.held, defaults) }
        if plan.changed {
            guard write(plan.mapping) else {
                Log.error("UserKeyMapping \(operation.rawValue): hidutil failed, the mapping is unchanged")
                return
            }
        }
        save(plan.held, defaults)
        for entry in plan.displaced {
            Log.info("Caps Lock had a user mapping to 0x\(String(entry.dst, radix: 16)); it comes back when hyprdarwin quits")
        }
        Log.info("Caps Lock -> F18 \(operation == .install ? "installed" : "removed") (\(plan.mapping.count) mapping(s), \(plan.changed ? "written" : "already current"))")
    }

    private static func save(_ held: [HIDKeyMapping], _ defaults: UserDefaults) {
        if held.isEmpty {
            defaults.removeObject(forKey: heldKey)
        } else if let data = try? JSONEncoder().encode(held) {
            defaults.set(data, forKey: heldKey)
        }
    }

    /// The current list, read through the public IOKit event system client
    /// (typed, unlike parsing `hidutil property --get` output).
    private static func readUserKeyMapping() -> Any? {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return IOHIDEventSystemClientCopyProperty(client, kIOHIDUserKeyUsageMapKey as CFString)
    }

    private static func write(_ mapping: [HIDKeyMapping]) -> Bool {
        let json: [String: Any] = [kIOHIDUserKeyUsageMapKey: KeyMappingMerge.propertyList(mapping)]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", text]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            Log.error("could not launch hidutil: \(error.localizedDescription)")
            return false
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Log.error("hidutil exited with \(process.terminationStatus): \(String(decoding: message, as: UTF8.self))")
        }
        return process.terminationStatus == 0
    }
}
