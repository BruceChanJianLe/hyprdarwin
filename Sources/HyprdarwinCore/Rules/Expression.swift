import CoreGraphics
import Foundation

/// Arithmetic used by the `size` and `move` window rules, e.g.
/// "monitor_w-500 40", "50% 50%", "(monitor_w - window_w) / 2 monitor_h*0.1".
/// Supports numbers, + - * /, parentheses, unary minus, a trailing "%"
/// (percent of the monitor dimension for that axis) and variables.
public enum RuleExpression {
    public struct Variables: Sendable {
        public var monitorW: Double
        public var monitorH: Double
        public var windowW: Double
        public var windowH: Double
        public var cursorX: Double
        public var cursorY: Double

        public init(monitorW: Double, monitorH: Double, windowW: Double, windowH: Double, cursorX: Double = 0, cursorY: Double = 0) {
            self.monitorW = monitorW
            self.monitorH = monitorH
            self.windowW = windowW
            self.windowH = windowH
            self.cursorX = cursorX
            self.cursorY = cursorY
        }

        func value(of name: String) -> Double? {
            switch name {
            case "monitor_w": return monitorW
            case "monitor_h": return monitorH
            case "window_w": return windowW
            case "window_h": return windowH
            case "cursor_x": return cursorX
            case "cursor_y": return cursorY
            default: return nil
            }
        }
    }

    public struct EvaluationError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// Split "A B" into the two axis expressions. Spaces inside an expression
    /// are allowed when they sit next to an operator or a parenthesis.
    public static func splitPair(_ text: String) -> (String, String)? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var groups: [String] = []
        var current = ""
        var depth = 0
        func endsWithOperator(_ s: String) -> Bool { s.last.map { "+-*/(".contains($0) } ?? true }
        func startsWithOperator(_ s: String) -> Bool { s.first.map { "+-*/)".contains($0) } ?? false }
        for token in tokens {
            if current.isEmpty {
                current = token
            } else if depth > 0 || endsWithOperator(current) || startsWithOperator(token) {
                current += token
            } else {
                groups.append(current)
                current = token
            }
            depth += token.filter { $0 == "(" }.count - token.filter { $0 == ")" }.count
        }
        if !current.isEmpty { groups.append(current) }
        guard groups.count == 2 else { return nil }
        return (groups[0], groups[1])
    }

    /// Evaluate one axis. `axis` picks what "%" refers to (true = horizontal).
    public static func evaluate(_ text: String, horizontal: Bool, variables: Variables) -> Result<Double, EvaluationError> {
        var parser = Parser(text: text, horizontal: horizontal, variables: variables)
        do {
            let value = try parser.parseExpression()
            parser.skipSpaces()
            guard parser.isAtEnd else { throw EvaluationError(message: "unexpected \"\(parser.rest)\" in \"\(text)\"") }
            guard value.isFinite else { throw EvaluationError(message: "\"\(text)\" is not a finite number") }
            return .success(value)
        } catch let error as EvaluationError {
            return .failure(error)
        } catch {
            return .failure(EvaluationError(message: "\(error)"))
        }
    }

    /// Validate syntax and variable names without real values.
    public static func validatePair(_ text: String) -> String? {
        guard let (x, y) = splitPair(text) else { return "expected two values like \"480 270\", got \"\(text)\"" }
        let probe = Variables(monitorW: 1000, monitorH: 1000, windowW: 100, windowH: 100, cursorX: 1, cursorY: 1)
        for (part, horizontal) in [(x, true), (y, false)] {
            if case .failure(let error) = evaluate(part, horizontal: horizontal, variables: probe) {
                return error.message
            }
        }
        return nil
    }

    struct Parser {
        let chars: [Character]
        var index = 0
        let horizontal: Bool
        let variables: Variables
        let text: String

        init(text: String, horizontal: Bool, variables: Variables) {
            self.text = text
            self.chars = Array(text)
            self.horizontal = horizontal
            self.variables = variables
        }

        var isAtEnd: Bool { index >= chars.count }
        var rest: String { String(chars[index...]) }

        mutating func skipSpaces() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while true {
                skipSpaces()
                guard index < chars.count, chars[index] == "+" || chars[index] == "-" else { return value }
                let op = chars[index]
                index += 1
                let rhs = try parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
        }

        mutating func parseTerm() throws -> Double {
            var value = try parseFactor()
            while true {
                skipSpaces()
                guard index < chars.count, chars[index] == "*" || chars[index] == "/" else { return value }
                let op = chars[index]
                index += 1
                let rhs = try parseFactor()
                if op == "/" {
                    guard rhs != 0 else { throw EvaluationError(message: "division by zero in \"\(text)\"") }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
        }

        mutating func parseFactor() throws -> Double {
            skipSpaces()
            guard index < chars.count else { throw EvaluationError(message: "incomplete expression \"\(text)\"") }
            let c = chars[index]
            if c == "-" {
                index += 1
                return -(try parseFactor())
            }
            if c == "(" {
                index += 1
                let value = try parseExpression()
                skipSpaces()
                guard index < chars.count, chars[index] == ")" else { throw EvaluationError(message: "missing \")\" in \"\(text)\"") }
                index += 1
                return value
            }
            if c.isNumber || c == "." {
                let start = index
                while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
                guard let number = Double(String(chars[start..<index])) else {
                    throw EvaluationError(message: "bad number in \"\(text)\"")
                }
                if index < chars.count, chars[index] == "%" {
                    index += 1
                    return number / 100 * (horizontal ? variables.monitorW : variables.monitorH)
                }
                return number
            }
            if c.isLetter || c == "_" {
                let start = index
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { index += 1 }
                let name = String(chars[start..<index])
                guard let value = variables.value(of: name) else {
                    throw EvaluationError(message: "unknown variable \"\(name)\" (use monitor_w, monitor_h, window_w, window_h, cursor_x, cursor_y)")
                }
                return value
            }
            throw EvaluationError(message: "unexpected \"\(c)\" in \"\(text)\"")
        }
    }
}
