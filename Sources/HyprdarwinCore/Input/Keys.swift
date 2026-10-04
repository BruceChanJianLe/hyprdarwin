import CoreGraphics
import Foundation

/// Modifiers a bind can require. HYPR is hyprdarwin's own modifier: the Hypr
/// key (Caps Lock remapped to F18 by default), tracked by the event tap.
public struct Modifiers: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let hypr = Modifiers(rawValue: 1 << 0)
    public static let command = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
    public static let shift = Modifiers(rawValue: 1 << 4)

    /// Hyprland and macOS spellings. SUPER is an alias of CMD.
    public init?(name: String) {
        switch name.uppercased() {
        case "HYPR": self = .hypr
        case "CMD", "COMMAND", "SUPER", "WIN", "LOGO", "MOD4", "META": self = .command
        case "ALT", "OPT", "OPTION", "MOD1": self = .option
        case "CTRL", "CONTROL": self = .control
        case "SHIFT": self = .shift
        default: return nil
        }
    }

    public var description: String {
        var parts: [String] = []
        if contains(.hypr) { parts.append("HYPR") }
        if contains(.command) { parts.append("CMD") }
        if contains(.option) { parts.append("ALT") }
        if contains(.control) { parts.append("CTRL") }
        if contains(.shift) { parts.append("SHIFT") }
        return parts.joined(separator: " + ")
    }
}

/// A key plus required modifiers, parsed from Hyprland-style strings such
/// as "HYPR + SHIFT + left", "SUPER + Return" or "CTRL ALT code:36".
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public var modifiers: Modifiers
    /// macOS virtual key code (kVK_*).
    public var keyCode: UInt16
    public var keyName: String

    public init(modifiers: Modifiers, keyCode: UInt16, keyName: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.keyName = keyName
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownKey(String)
        case multipleKeys(String, String)
        case missingKey

        public var description: String {
            switch self {
            case .empty: return "empty key combination"
            case .unknownKey(let key): return "unknown key \"\(key)\""
            case .multipleKeys(let a, let b): return "two keys in one combination (\"\(a)\" and \"\(b)\")"
            case .missingKey: return "key combination has modifiers but no key"
            }
        }
    }

    public static func parse(_ text: String) -> Result<KeyCombo, ParseError> {
        let tokens = text
            .split(whereSeparator: { $0 == "+" || $0.isWhitespace })
            .map(String.init)
        // "HYPR + +" style: a literal plus key is spelled "plus"
        guard !tokens.isEmpty else { return .failure(.empty) }
        var modifiers: Modifiers = []
        var key: (code: UInt16, name: String)?
        for token in tokens {
            if let modifier = Modifiers(name: token) {
                modifiers.insert(modifier)
                continue
            }
            guard let code = KeyCodes.code(for: token) else { return .failure(.unknownKey(token)) }
            if let existing = key { return .failure(.multipleKeys(existing.name, token)) }
            key = (code, token)
        }
        guard let key else { return .failure(.missingKey) }
        return .success(KeyCombo(modifiers: modifiers, keyCode: key.code, keyName: key.name))
    }

    public var description: String {
        modifiers.isEmpty ? keyName : "\(modifiers) + \(keyName)"
    }
}

/// Key names to macOS virtual key codes (ANSI layout positions, as in
/// Carbon's kVK_* constants). Names are case-insensitive and accept the
/// usual Hyprland/XKB spellings.
public enum KeyCodes {
    public static func code(for name: String) -> UInt16? {
        let lower = name.lowercased()
        if lower.hasPrefix("code:"), let value = UInt16(lower.dropFirst(5)) { return value }
        return table[lower]
    }

    static let table: [String: UInt16] = {
        var t: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
            "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
            "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33,
            "escape": 0x35, "esc": 0x35, "delete": 0x75, "forwarddelete": 0x75,
            "home": 0x73, "end": 0x77, "pageup": 0x74, "prior": 0x74, "pagedown": 0x79, "next": 0x79,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "kp_enter": 0x4C, "help": 0x72,
            "minus": 0x1B, "equal": 0x18, "plus": 0x18, "bracketleft": 0x21, "bracketright": 0x1E,
            "semicolon": 0x29, "apostrophe": 0x27, "quote": 0x27, "grave": 0x32, "backslash": 0x2A,
            "comma": 0x2B, "period": 0x2F, "slash": 0x2C,
        ]
        let functionKeys: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (index, code) in functionKeys.enumerated() {
            t["f\(index + 1)"] = code
        }
        return t
    }()

    /// F18, the key the Hypr key arrives as.
    public static let f18: UInt16 = 0x4F
}
