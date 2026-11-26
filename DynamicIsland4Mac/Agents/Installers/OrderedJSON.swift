import Foundation

/// A JSON value that remembers key order and the exact text of numbers.
///
/// Why not `JSONSerialization`? It loses key order and may rewrite numbers (`1.0` → `1`), so
/// writing a user's `settings.json` back would reorder and reformat things that aren't ours.
/// The installers promise to change *only* the entries they add, so they parse and print with
/// this instead.
indirect enum JSONValue: Equatable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The number exactly as written.
    case number(String)
    case bool(Bool)
    case null

    struct Member: Equatable {
        var key: String
        var value: JSONValue
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var objectMembers: [Member]? { if case .object(let m) = self { m } else { nil } }

    /// Sets (replacing in place, keeping position) or appends a key.
    mutating func set(_ key: String, _ value: JSONValue) {
        guard case .object(var members) = self else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(Member(key: key, value: value))
        }
        self = .object(members)
    }

    mutating func remove(_ key: String) {
        guard case .object(var members) = self else { return }
        members.removeAll { $0.key == key }
        self = .object(members)
    }
}

// MARK: - Parsing

enum OrderedJSON {
    struct ParseError: LocalizedError {
        var message: String
        var offset: Int
        var errorDescription: String? { "Invalid JSON at character \(offset): \(message)" }
    }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.scalars.count else { throw ParseError(message: "Unexpected trailing characters", offset: parser.index) }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func skipWhitespace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        func fail(_ message: String) -> ParseError { ParseError(message: message, offset: index) }

        mutating func parseValue() throws -> JSONValue {
            guard index < scalars.count else { throw fail("Unexpected end") }
            switch scalars[index] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            for s in word.unicodeScalars {
                guard index < scalars.count, scalars[index] == s else { throw fail("Expected \(word)") }
                index += 1
            }
        }

        mutating func parseObject() throws -> JSONValue {
            index += 1
            var members: [JSONValue.Member] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < scalars.count, scalars[index] == "\"" else { throw fail("Expected key") }
                let key = try parseString()
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else { throw fail("Expected ':'") }
                index += 1
                skipWhitespace()
                members.append(JSONValue.Member(key: key, value: try parseValue()))
                skipWhitespace()
                guard index < scalars.count else { throw fail("Unexpected end") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(members) }
                throw fail("Expected ',' or '}'")
            }
        }

        mutating func parseArray() throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard index < scalars.count else { throw fail("Unexpected end") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(items) }
                throw fail("Expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                switch c {
                case "\"":
                    return String(result)
                case "\\":
                    guard index < scalars.count else { throw fail("Bad escape") }
                    let e = scalars[index]
                    index += 1
                    switch e {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u":
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        result.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: throw fail("Bad escape")
                    }
                default:
                    result.append(c)
                }
            }
            throw fail("Unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw fail("Bad \\u escape") }
            let text = String(String.UnicodeScalarView(scalars[index..<index + 4]))
            guard let value = UInt32(text, radix: 16) else { throw fail("Bad \\u escape") }
            index += 4
            return value
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            while index < scalars.count, "-+.eE0123456789".unicodeScalars.contains(scalars[index]) { index += 1 }
            guard index > start else { throw fail("Unexpected character") }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            guard Double(text) != nil else { throw fail("Bad number") }
            return .number(text)
        }
    }

    // MARK: - Printing

    /// Pretty-prints with the given indent (default two spaces, as Claude Code and most
    /// editors write). Use `detectIndent` to match an existing file.
    static func print(_ value: JSONValue, indent: String = "  ") -> String {
        var out = ""
        write(value, indent: indent, level: 0, into: &out)
        return out + "\n"
    }

    /// The indent unit used by an existing file (first indented line), or nil.
    static func detectIndent(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            if !prefix.isEmpty { return String(prefix) }
        }
        return nil
    }

    private static func write(_ value: JSONValue, indent: String, level: Int, into out: inout String) {
        let pad = String(repeating: indent, count: level)
        let inner = String(repeating: indent, count: level + 1)
        switch value {
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, member) in members.enumerated() {
                out += inner + quote(member.key) + ": "
                write(member.value, indent: indent, level: level + 1, into: &out)
                out += i < members.count - 1 ? ",\n" : "\n"
            }
            out += pad + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += inner
                write(item, indent: indent, level: level + 1, into: &out)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += pad + "]"
        case .string(let s): out += quote(s)
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
