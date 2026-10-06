import CoreGraphics
import Foundation

/// A regex match field. Unanchored like Hyprland; "negative:" inverts it.
public struct RulePattern: @unchecked Sendable, CustomStringConvertible {
    public let source: String
    public let negated: Bool
    // NSRegularExpression is immutable and documented thread-safe
    let regex: NSRegularExpression

    public init(_ text: String) throws {
        source = text
        let body: String
        if text.hasPrefix("negative:") {
            negated = true
            body = String(text.dropFirst("negative:".count))
        } else {
            negated = false
            body = text
        }
        regex = try NSRegularExpression(pattern: body)
    }

    public func matches(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        let found = regex.firstMatch(in: value, range: range) != nil
        return found != negated
    }

    public var description: String { source }
}

public struct WindowRuleMatch: Sendable {
    public var `class`: RulePattern?
    public var title: RulePattern?
    public var initialClass: RulePattern?
    public var initialTitle: RulePattern?
    public var appName: RulePattern?
    public var role: RulePattern?
    public var subrole: RulePattern?
    public var tag: RulePattern?
    public var float: Bool?
    public var fullscreen: Bool?
    public var workspace: WorkspaceID?

    public init() {}

    public var isEmpty: Bool {
        `class` == nil && title == nil && initialClass == nil && initialTitle == nil && appName == nil
            && role == nil && subrole == nil && tag == nil && float == nil && fullscreen == nil && workspace == nil
    }

    /// Every listed field must match.
    public func matches(_ window: ManagedWindow) -> Bool {
        let info = window.info
        if let p = `class`, !p.matches(info.bundleID) { return false }
        if let p = title, !p.matches(info.title) { return false }
        if let p = initialClass, !p.matches(window.initialClass) { return false }
        if let p = initialTitle, !p.matches(window.initialTitle) { return false }
        if let p = appName, !p.matches(info.appName) { return false }
        if let p = role, !p.matches(info.role) { return false }
        if let p = subrole, !p.matches(info.subrole) { return false }
        if let p = tag {
            let hit = window.tags.contains { tag in
                let range = NSRange(tag.startIndex..., in: tag)
                return p.regex.firstMatch(in: tag, range: range) != nil
            }
            if hit == p.negated { return false }
        }
        if let float, window.isFloating != float { return false }
        if let fullscreen, (window.fullscreen != nil) != fullscreen { return false }
        if let workspace, window.workspace != workspace { return false }
        return true
    }
}

public struct WorkspaceTarget: Equatable, Sendable {
    public var workspace: WorkspaceID
    public var silent: Bool

    public init(workspace: WorkspaceID, silent: Bool) {
        self.workspace = workspace
        self.silent = silent
    }

    /// "3", "3 silent", "special:scratch silent".
    public init?(parsing text: String) {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var silent = false
        if tokens.last == "silent" {
            silent = true
            tokens.removeLast()
        }
        guard tokens.count == 1, let id = WorkspaceID(parsing: tokens[0]) else { return nil }
        self.init(workspace: id, silent: silent)
    }
}

/// Effects of one rule. nil means "this rule does not set it".
public struct WindowRuleEffects: Sendable {
    // static: applied once when the window opens
    public var float: Bool?
    public var workspace: WorkspaceTarget?
    public var monitor: MonitorSelector?
    public var size: String?
    public var move: String?
    /// Smallest tile size, "w h" expressions like `size`.
    public var minSize: String?
    public var center: Bool?
    public var fullscreen: FullscreenMode?
    public var noInitialFocus: Bool?
    public var tags: [String] = []
    // dynamic: re-applied whenever the window's title or state changes
    public var borderColor: BorderColor?
    public var borderSize: Int?

    public init() {}

    /// Later rules win per effect.
    mutating func merge(_ later: WindowRuleEffects) {
        if let v = later.float { float = v }
        if let v = later.workspace { workspace = v }
        if let v = later.monitor { monitor = v }
        if let v = later.size { size = v }
        if let v = later.move { move = v }
        if let v = later.minSize { minSize = v }
        if let v = later.center { center = v }
        if let v = later.fullscreen { fullscreen = v }
        if let v = later.noInitialFocus { noInitialFocus = v }
        tags += later.tags
        if let v = later.borderColor { borderColor = v }
        if let v = later.borderSize { borderSize = v }
    }
}

public struct WindowRule: Sendable {
    public var name: String?
    public var enabled = true
    /// Re-apply float/tile when the window's title changes (opt-in).
    public var dynamic = false
    public var match: WindowRuleMatch
    public var effects: WindowRuleEffects

    public init(name: String? = nil, match: WindowRuleMatch, effects: WindowRuleEffects) {
        self.name = name
        self.match = match
        self.effects = effects
    }
}

public enum RuleEngine {
    /// Merged effects of every enabled rule matching `window`, top to bottom.
    public static func effects(for window: ManagedWindow, rules: [WindowRule]) -> WindowRuleEffects {
        var result = WindowRuleEffects()
        for rule in rules where rule.enabled && rule.match.matches(window) {
            result.merge(rule.effects)
        }
        return result
    }

    /// Effects re-applied on title/state change and config reload: border
    /// and min_size always, float/tile only from rules marked `dynamic`.
    public static func dynamicEffects(for window: ManagedWindow, rules: [WindowRule]) -> WindowRuleEffects {
        var result = WindowRuleEffects()
        for rule in rules where rule.enabled && rule.match.matches(window) {
            var effects = WindowRuleEffects()
            effects.borderColor = rule.effects.borderColor
            effects.borderSize = rule.effects.borderSize
            effects.minSize = rule.effects.minSize
            if rule.dynamic { effects.float = rule.effects.float }
            result.merge(effects)
        }
        return result
    }
}
