// Adapted from HyprMac (https://github.com/zacharytgray/HyprMac),
// HyprMac/Core/KeyRemapper.swift, MIT License, Copyright (c) 2026 Zachary Gray.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// One `UserKeyMapping` entry. Both sides are HID usages packed as
/// `page << 32 | usage`, the form hidutil takes.
public struct HIDKeyMapping: Codable, Equatable, Sendable {
    public let src: UInt64
    public let dst: UInt64

    public init(src: UInt64, dst: UInt64) {
        self.src = src
        self.dst = dst
    }
}

/// Pure rules for hyprdarwin's one entry (Caps Lock -> F18) in the
/// system-wide `UserKeyMapping` list, which may also hold mappings the user
/// set with hidutil themselves.
///
/// - Install adds Caps Lock -> F18 once. Every other entry stays, in order.
/// - A foreign entry whose source is Caps Lock (say Caps Lock -> Escape) cannot
///   coexist with ours: ours takes its place while hyprdarwin runs and the
///   foreign entry is held, to go back on remove.
/// - Remove takes out only ours. A held entry goes back where ours was,
///   unless something else has mapped Caps Lock since.
/// - A list with an entry this cannot reproduce exactly makes `plan` return
///   nil, and nothing is written.
public enum KeyMappingMerge {
    public enum Operation: String, Sendable {
        case install, remove
    }

    public struct Plan: Equatable, Sendable {
        /// The full list to write.
        public let mapping: [HIDKeyMapping]
        /// False when the list already matches and the write can be skipped.
        public let changed: Bool
        /// Foreign Caps Lock entries to put back on a later remove.
        public let held: [HIDKeyMapping]
        /// Foreign entries this install took out.
        public let displaced: [HIDKeyMapping]
        /// Held entries this remove put back.
        public let restored: [HIDKeyMapping]
    }

    public static let capsLock: UInt64 = 0x7_0000_0039
    public static let f18: UInt64 = 0x7_0000_006D
    public static let ours = HIDKeyMapping(src: capsLock, dst: f18)

    // IOHIDProperties.h kIOHIDKeyboardModifierMappingSrcKey / DstKey
    public static let srcKey = "HIDKeyboardModifierMappingSrc"
    public static let dstKey = "HIDKeyboardModifierMappingDst"

    /// nil means the read cannot be trusted and nothing may be written.
    public static func plan(_ operation: Operation, read raw: Any?, held: [HIDKeyMapping]) -> Plan? {
        guard let current = parse(raw) else { return nil }
        switch operation {
        case .install: return install(current, held: held)
        case .remove: return remove(current, held: held)
        }
    }

    /// A missing property (nothing set since boot) is an empty list.
    /// Anything but plain src/dst pairs is nil.
    public static func parse(_ raw: Any?) -> [HIDKeyMapping]? {
        guard let raw else { return [] }
        guard let items = raw as? [Any] else { return nil }
        var result: [HIDKeyMapping] = []
        for item in items {
            // an extra key would be lost on the write, so it counts as unreadable
            guard let entry = item as? [String: Any], entry.count == 2,
                  let src = usage(entry[srcKey]),
                  let dst = usage(entry[dstKey]) else { return nil }
            result.append(HIDKeyMapping(src: src, dst: dst))
        }
        return result
    }

    // a whole, non-negative number, or nil: 1.5 or -1 would change on the write
    private static func usage(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              number == NSNumber(value: number.uint64Value) else { return nil }
        return number.uint64Value
    }

    public static func propertyList(_ mapping: [HIDKeyMapping]) -> [[String: UInt64]] {
        mapping.map { [srcKey: $0.src, dstKey: $0.dst] }
    }

    static func install(_ current: [HIDKeyMapping], held: [HIDKeyMapping]) -> Plan {
        var mapping: [HIDKeyMapping] = []
        var displaced: [HIDKeyMapping] = []
        var hadOurs = false
        var placed = false
        for entry in current {
            if entry == ours {
                hadOurs = true
            } else if entry.src == capsLock {
                displaced.append(entry)
            } else {
                mapping.append(entry)
                continue
            }
            // ours sits where the first Caps Lock entry was; later copies drop
            if !placed {
                mapping.append(ours)
                placed = true
            }
        }
        if !placed { mapping.append(ours) }

        // a fresh displacement is the user's current choice; ours already in
        // place keeps the earlier hold; otherwise the list was reset and an
        // old hold is stale
        let nextHeld = !displaced.isEmpty ? displaced : (hadOurs ? held : [])
        return Plan(mapping: mapping, changed: mapping != current, held: nextHeld, displaced: displaced, restored: [])
    }

    static func remove(_ current: [HIDKeyMapping], held: [HIDKeyMapping]) -> Plan {
        var mapping: [HIDKeyMapping] = []
        var slot: Int?
        for entry in current {
            if entry == ours {
                if slot == nil { slot = mapping.count }
            } else {
                mapping.append(entry)
            }
        }
        // none of ours: the list was reset since the install, the hold is stale
        guard let slot else {
            return Plan(mapping: current, changed: false, held: [], displaced: [], restored: [])
        }
        var restored: [HIDKeyMapping] = []
        if !mapping.contains(where: { $0.src == capsLock }) {
            restored = held
            mapping.insert(contentsOf: held, at: slot)
        }
        return Plan(mapping: mapping, changed: true, held: [], displaced: [], restored: restored)
    }
}
