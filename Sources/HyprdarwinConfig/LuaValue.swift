import CLua
import Foundation

/// A Lua value copied into Swift. Tables are read with raw access only, so
/// reading never runs config code (no metamethods) and can never raise.
indirect enum LuaValue: Equatable {
    case none
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case table(LuaTable)
    case function
    /// A value built by hl.dsp.*; the payload indexes LuaConfigRuntime.dispatchers.
    case dispatcher(Int)
    case other(String)

    var typeName: String {
        switch self {
        case .none: return "nil"
        case .bool: return "boolean"
        case .integer, .number: return "number"
        case .string: return "string"
        case .table: return "table"
        case .function: return "function"
        case .dispatcher: return "dispatcher"
        case .other(let name): return name
        }
    }

    var double: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .number(let value) where value.rounded() == value: return Int(value)
        case .string(let text): return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Booleans, plus Hyprland's string/number spellings ("on", "yes", 1...).
    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .integer(let value) where value == 0 || value == 1: return value == 1
        case .string(let text):
            switch text.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Strings, and numbers rendered as text (workspace = 3 -> "3").
    var text: String? {
        switch self {
        case .string(let text): return text
        case .integer(let value): return String(value)
        case .number(let value): return value.rounded() == value ? String(Int64(value)) : String(value)
        default: return nil
        }
    }

    var tableValue: LuaTable? {
        if case .table(let table) = self { return table }
        return nil
    }
}

struct LuaTable: Equatable {
    var array: [LuaValue] = []
    /// String keys; iterate `sortedKeys` for a stable order.
    var fields: [String: LuaValue] = [:]

    subscript(key: String) -> LuaValue { fields[key] ?? .none }

    var sortedKeys: [String] { fields.keys.sorted() }
}

enum Lua {
    static func typeName(_ L: OpaquePointer, _ index: Int32) -> String {
        String(cString: lua_typename(L, lua_type(L, index)))
    }

    static func string(_ L: OpaquePointer, _ index: Int32) -> String? {
        guard lua_type(L, index) == LUA_TSTRING, let pointer = lua_tolstring(L, index, nil) else { return nil }
        return String(cString: pointer)
    }

    static func push(_ L: OpaquePointer, _ text: String) {
        lua_pushstring(L, text)
    }

    /// "file.lua:12:" for the Lua code that called the running builtin.
    static func location(_ L: OpaquePointer) -> String {
        luaL_where(L, 1)
        defer { hd_pop(L, 1) }
        return (string(L, -1) ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func read(_ L: OpaquePointer, _ index: Int32, depth: Int = 0) -> LuaValue {
        let index = lua_absindex(L, index)
        switch lua_type(L, index) {
        case LUA_TNIL, LUA_TNONE:
            return .none
        case LUA_TBOOLEAN:
            return .bool(lua_toboolean(L, index) != 0)
        case LUA_TNUMBER:
            if lua_isinteger(L, index) != 0 { return .integer(lua_tointegerx(L, index, nil)) }
            return .number(lua_tonumberx(L, index, nil))
        case LUA_TSTRING:
            return .string(string(L, index) ?? "")
        case LUA_TFUNCTION:
            return .function
        case LUA_TTABLE:
            if let dispatcher = dispatcherIndex(L, index) { return .dispatcher(dispatcher) }
            guard depth < 16 else { return .other("table (nested too deeply)") }
            var table = LuaTable()
            var indexed: [Int: LuaValue] = [:]
            lua_pushnil(L)
            while lua_next(L, index) != 0 {
                // key at -2, value at -1; never convert the key in place
                switch lua_type(L, -2) {
                case LUA_TSTRING:
                    if let key = string(L, -2) { table.fields[key] = read(L, -1, depth: depth + 1) }
                case LUA_TNUMBER where lua_isinteger(L, -2) != 0:
                    let key = Int(lua_tointegerx(L, -2, nil))
                    if key >= 1 { indexed[key] = read(L, -1, depth: depth + 1) }
                default:
                    break
                }
                hd_pop(L, 1)
            }
            if !indexed.isEmpty, let maximum = indexed.keys.max() {
                table.array = (1...maximum).map { indexed[$0] ?? .none }
            }
            return .table(table)
        default:
            return .other(typeName(L, index))
        }
    }

    /// The runtime index stored in a dispatcher table, if `index` is one.
    static func dispatcherIndex(_ L: OpaquePointer, _ index: Int32) -> Int? {
        let index = lua_absindex(L, index)
        guard lua_type(L, index) == LUA_TTABLE else { return nil }
        lua_pushstring(L, LuaConfigRuntime.dispatcherKey)
        lua_rawget(L, index)
        defer { hd_pop(L, 1) }
        guard lua_type(L, -1) == LUA_TNUMBER else { return nil }
        return Int(lua_tointegerx(L, -1, nil))
    }
}
