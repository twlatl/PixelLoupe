import Foundation

/// A value parsed from a Lua table literal, as Lightroom stores develop settings, history steps,
/// snapshots and smart-collection rules.
nonisolated enum LuaValue: Equatable, Sendable {
    case table(LuaTable)
    case string(String)
    case number(Double)
    case bool(Bool)

    var table: LuaTable? {
        if case .table(let table) = self { return table }
        return nil
    }

    var string: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var number: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    var bool: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    /// The number as an `Int`, when it is a whole number.
    var int: Int? {
        guard case .number(let number) = self, number == number.rounded(), abs(number) < 9e15 else { return nil }
        return Int(number)
    }

    /// Looks up a field of a table value by name; `nil` for anything else.
    subscript(key: String) -> LuaValue? { table?[key] }
}

/// A Lua table: the sequence part (`{ 1, 2, 3 }`) and the keyed part (`{ a = 1, [4] = 2 }`).
///
/// Positional values go to `array` in order. Keyed entries go to `hash`; a numeric key such as
/// `[4]` is stored under its decimal text (`"4"`). `nil` values are dropped, as in Lua.
nonisolated struct LuaTable: Equatable, Sendable {
    var array: [LuaValue] = []
    var hash: [String: LuaValue] = [:]

    subscript(key: String) -> LuaValue? { hash[key] }

    var isEmpty: Bool { array.isEmpty && hash.isEmpty }
}
