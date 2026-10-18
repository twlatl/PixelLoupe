import Foundation

nonisolated struct LuaParseError: Error, Equatable, CustomStringConvertible {
    var message: String
    /// Byte offset into the UTF-8 text.
    var offset: Int

    var description: String { "Lua parse error at byte \(offset): \(message)" }
}

/// Parses the Lua table literals Lightroom stores in its catalogs.
///
/// The accepted text is `name = { ... }` or a bare `{ ... }` (the result is the table). Inside a table:
/// `key = value`, `["key"] = value`, `[number] = value` and positional values, separated by `,` or
/// `;`. Values are tables, quoted strings (`"…"` or `'…'`, with Lua escapes), long strings
/// (`[[…]]`, `[=[…]=]`), numbers (signed, decimal, exponent, hex) and `true`/`false`/`nil`.
/// Comments (`-- …` and `--[[ … ]]`) are skipped.
///
/// The parser walks the UTF-8 bytes directly and builds only the values it returns, since a large
/// catalog holds about 100 MB of settings text. It is synchronous and thread-safe; use
/// ``parseInBackground(_:)`` to keep it off the calling actor.
nonisolated enum LuaTableParser {
    static func parse(_ text: String) throws -> LuaValue {
        var text = text
        return try text.withUTF8 { try parse(bytes: $0) }
    }

    static func parse(_ data: Data) throws -> LuaValue {
        try data.withUnsafeBytes { try parse(bytes: $0.bindMemory(to: UInt8.self)) }
    }

    @concurrent
    static func parseInBackground(_ text: String) async throws -> LuaValue {
        try parse(text)
    }

    static func parse(bytes: UnsafeBufferPointer<UInt8>) throws -> LuaValue {
        var reader = Reader(bytes: bytes)
        reader.skipTrivia()
        // Optional `name =` prefix, as in `s = { ... }`.
        if reader.peekIsIdentifierStart {
            let save = reader.position
            _ = reader.readIdentifier()
            reader.skipTrivia()
            if reader.peek == UInt8(ascii: "=") {
                reader.position += 1
                reader.skipTrivia()
            } else {
                reader.position = save
            }
        }
        let value = try reader.readValue(depth: 0)
        reader.skipTrivia()
        if reader.position < bytes.count {
            throw reader.error("unexpected trailing text")
        }
        return value
    }

    /// Guards against pathological input blowing the stack.
    private static let maximumDepth = 200

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

        var peekIsIdentifierStart: Bool {
            guard let byte = peek else { return false }
            return Self.isIdentifierStart(byte)
        }

        func error(_ message: String) -> LuaParseError {
            LuaParseError(message: message, offset: position)
        }

        static func isIdentifierStart(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == UInt8(ascii: "_")
        }

        static func isIdentifierPart(_ byte: UInt8) -> Bool {
            isIdentifierStart(byte) || isDigit(byte)
        }

        static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

        static func hexValue(_ byte: UInt8) -> Int? {
            switch byte {
            case 0x30...0x39: Int(byte) - 0x30
            case 0x41...0x46: Int(byte) - 0x41 + 10
            case 0x61...0x66: Int(byte) - 0x61 + 10
            default: nil
            }
        }

        mutating func skipTrivia() {
            while let byte = peek {
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    position += 1
                } else if byte == UInt8(ascii: "-"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "-") {
                    position += 2
                    if let level = longBracketLevel() {
                        _ = try? readLongString(level: level)
                    } else {
                        while let next = peek, next != 0x0A { position += 1 }
                    }
                } else {
                    return
                }
            }
        }

        mutating func readIdentifier() -> String {
            let start = position
            while let byte = peek, Self.isIdentifierPart(byte) { position += 1 }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
        }

        mutating func readValue(depth: Int) throws -> LuaValue {
            skipTrivia()
            guard let byte = peek else { throw error("unexpected end of text") }
            switch byte {
            case UInt8(ascii: "{"):
                return .table(try readTable(depth: depth + 1))
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                return .string(try readQuotedString())
            case UInt8(ascii: "["):
                guard let level = longBracketLevel() else { throw error("unexpected '['") }
                return .string(try readLongString(level: level))
            case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), 0x30...0x39:
                return .number(try readNumber())
            default:
                if Self.isIdentifierStart(byte) {
                    let word = readIdentifier()
                    switch word {
                    case "true": return .bool(true)
                    case "false": return .bool(false)
                    case "nil": return .nilMarker
                    case "inf": return .number(.infinity)
                    case "nan": return .number(.nan)
                    default: throw error("unexpected identifier '\(word)'")
                    }
                }
                throw error("unexpected character")
            }
        }

        mutating func readTable(depth: Int) throws -> LuaTable {
            guard depth <= LuaTableParser.maximumDepth else { throw error("tables nested too deeply") }
            position += 1  // {
            var table = LuaTable()
            while true {
                skipTrivia()
                guard let byte = peek else { throw error("unterminated table") }
                if byte == UInt8(ascii: "}") {
                    position += 1
                    return table
                }

                if Self.isIdentifierStart(byte) {
                    // `name = value`, or a positional `true`/`false`/`nil`.
                    let save = position
                    let name = readIdentifier()
                    skipTrivia()
                    if peek == UInt8(ascii: "="), !(position + 1 < bytes.count && bytes[position + 1] == UInt8(ascii: "=")) {
                        position += 1
                        let value = try readValue(depth: depth)
                        store(value, forKey: name, in: &table)
                    } else {
                        position = save
                        append(try readValue(depth: depth), to: &table)
                    }
                } else if byte == UInt8(ascii: "["), longBracketLevel() == nil {
                    position += 1
                    skipTrivia()
                    let key = try readValue(depth: depth)
                    skipTrivia()
                    guard peek == UInt8(ascii: "]") else { throw error("expected ']'") }
                    position += 1
                    skipTrivia()
                    guard peek == UInt8(ascii: "=") else { throw error("expected '=' after key") }
                    position += 1
                    let value = try readValue(depth: depth)
                    switch key {
                    case .string(let name): store(value, forKey: name, in: &table)
                    case .number(let number): store(value, forKey: Self.keyText(number), in: &table)
                    default: throw error("unsupported table key")
                    }
                } else {
                    append(try readValue(depth: depth), to: &table)
                }

                skipTrivia()
                if let separator = peek, separator == UInt8(ascii: ",") || separator == UInt8(ascii: ";") {
                    position += 1
                } else if peek != UInt8(ascii: "}") {
                    throw error("expected ',' or '}'")
                }
            }
        }

        private static func keyText(_ number: Double) -> String {
            if number == number.rounded(), abs(number) < 9e15 { return String(Int(number)) }
            return String(number)
        }

        private func append(_ value: LuaValue, to table: inout LuaTable) {
            if value == .nilMarker { return }
            table.array.append(value)
        }

        private func store(_ value: LuaValue, forKey key: String, in table: inout LuaTable) {
            if value == .nilMarker { return }
            table.hash[key] = value
        }

        mutating func readNumber() throws -> Double {
            let start = position
            if peek == UInt8(ascii: "-") || peek == UInt8(ascii: "+") { position += 1 }
            // `inf` / `nan` after a sign (as `-inf`, which Lua's %g formatting can produce).
            if peekIsIdentifierStart {
                let word = readIdentifier()
                let negative = bytes[start] == UInt8(ascii: "-")
                if word == "inf" { return negative ? -.infinity : .infinity }
                if word == "nan" { return .nan }
                throw error("invalid number")
            }
            // Hexadecimal integer.
            if peek == UInt8(ascii: "0"), position + 1 < bytes.count,
               bytes[position + 1] == UInt8(ascii: "x") || bytes[position + 1] == UInt8(ascii: "X") {
                position += 2
                var value = 0.0
                var digits = 0
                while let byte = peek, let digit = Self.hexValue(byte) {
                    value = value * 16 + Double(digit)
                    digits += 1
                    position += 1
                }
                guard digits > 0 else { throw error("invalid hexadecimal number") }
                return bytes[start] == UInt8(ascii: "-") ? -value : value
            }

            while let byte = peek, Self.isDigit(byte) || byte == UInt8(ascii: ".") { position += 1 }
            if let byte = peek, byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                position += 1
                if let sign = peek, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { position += 1 }
                while let digit = peek, Self.isDigit(digit) { position += 1 }
            }
            let slice = UnsafeBufferPointer(rebasing: bytes[start..<position])
            // strtod needs a NUL-terminated string; numbers are short, so copy to a small stack buffer.
            let value: Double? = withUnsafeTemporaryAllocation(of: CChar.self, capacity: slice.count + 1) { buffer in
                for (index, byte) in slice.enumerated() { buffer[index] = CChar(bitPattern: byte) }
                buffer[slice.count] = 0
                var end: UnsafeMutablePointer<CChar>?
                let result = strtod(buffer.baseAddress!, &end)
                return end == buffer.baseAddress! + slice.count ? result : nil
            }
            guard let value else {
                position = start
                throw error("invalid number")
            }
            return value
        }

        mutating func readQuotedString() throws -> String {
            let quote = bytes[position]
            position += 1
            var buffer: [UInt8] = []
            let runStart = position
            // Fast path: no escapes.
            while let byte = peek, byte != quote, byte != UInt8(ascii: "\\"), byte != 0x0A {
                position += 1
            }
            buffer.append(contentsOf: bytes[runStart..<position])
            while true {
                guard let byte = peek, byte != 0x0A else { throw error("unterminated string") }
                position += 1
                if byte == quote {
                    return String(decoding: buffer, as: UTF8.self)
                }
                if byte != UInt8(ascii: "\\") {
                    buffer.append(byte)
                    continue
                }
                guard let escape = peek else { throw error("unterminated string") }
                position += 1
                switch escape {
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "a"): buffer.append(0x07)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "v"): buffer.append(0x0B)
                case UInt8(ascii: "\\"), UInt8(ascii: "\""), UInt8(ascii: "'"): buffer.append(escape)
                case 0x0A: buffer.append(0x0A)  // backslash-newline
                case UInt8(ascii: "x"):
                    guard let high = peek.flatMap(Self.hexValue) else { throw error("invalid \\x escape") }
                    position += 1
                    guard let low = peek.flatMap(Self.hexValue) else { throw error("invalid \\x escape") }
                    position += 1
                    buffer.append(UInt8(high * 16 + low))
                case 0x30...0x39:
                    // Up to three decimal digits.
                    var value = Int(escape) - 0x30
                    var count = 1
                    while count < 3, let digit = peek, Self.isDigit(digit) {
                        value = value * 10 + Int(digit) - 0x30
                        position += 1
                        count += 1
                    }
                    guard value <= 255 else { throw error("decimal escape too large") }
                    buffer.append(UInt8(value))
                default:
                    throw error("invalid escape sequence")
                }
                // Resume the fast path after an escape.
                let resume = position
                while let next = peek, next != quote, next != UInt8(ascii: "\\"), next != 0x0A { position += 1 }
                buffer.append(contentsOf: bytes[resume..<position])
            }
        }

        /// At a `[`, the level of a long bracket (`[[` is 0, `[=[` is 1…), or `nil` if it isn't one.
        func longBracketLevel() -> Int? {
            guard peek == UInt8(ascii: "[") else { return nil }
            var index = position + 1
            var level = 0
            while index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                level += 1
                index += 1
            }
            return index < bytes.count && bytes[index] == UInt8(ascii: "[") ? level : nil
        }

        mutating func readLongString(level: Int) throws -> String {
            position += level + 2
            // A newline straight after the opening bracket is dropped.
            if peek == 0x0D { position += 1 }
            if peek == 0x0A { position += 1 }
            let start = position
            while position < bytes.count {
                if bytes[position] == UInt8(ascii: "]") {
                    var index = position + 1
                    var closing = 0
                    while index < bytes.count, bytes[index] == UInt8(ascii: "="), closing < level {
                        closing += 1
                        index += 1
                    }
                    if closing == level, index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
                        position = index + 1
                        return text
                    }
                }
                position += 1
            }
            throw error("unterminated long string")
        }
    }
}

nonisolated private extension LuaValue {
    /// Stands in for a Lua `nil` while parsing. Never escapes the parser: tables drop it.
    static let nilMarker = LuaValue.string("\u{0}nil\u{0}")
}
