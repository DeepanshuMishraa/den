import Foundation

enum TOMLValue: Equatable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])
}

struct TOMLError: Error, Equatable, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "line \(line): \(message)" }
}

/// The TOML Den's config needs: comments, `[table]`, `[[array.of.tables]]`,
/// dotted keys, basic and literal strings, numbers, booleans, and
/// single-line arrays and inline tables. Multi-line strings and dates are
/// rejected with an error rather than misread.
enum TOML {
    typealias Table = [String: TOMLValue]

    static func parse(_ text: String) -> Result<Table, TOMLError> {
        var root: Table = [:]
        var current: [String] = []
        do throws(TOMLError) {
            for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                var cursor = Cursor(Array(line), line: index + 1)
                cursor.skipSpace()
                if cursor.atLineEnd { continue }
                if cursor.peek == "[" {
                    current = try header(&cursor, root: &root)
                } else {
                    let key = try cursor.key()
                    cursor.skipSpace()
                    try cursor.expect("=")
                    cursor.skipSpace()
                    let value = try cursor.value()
                    try cursor.finishLine()
                    try set(value, at: current + key, in: &root, line: cursor.line)
                }
            }
        } catch {
            return .failure(error)
        }
        return .success(root)
    }

    /// Reads `[a.b]` or `[[a.b]]`, creates the table, and returns its path.
    private static func header(_ cursor: inout Cursor, root: inout Table) throws(TOMLError) -> [String] {
        try cursor.expect("[")
        let isArray = cursor.peek == "["
        if isArray { cursor.advance() }
        cursor.skipSpace()
        let path = try cursor.key()
        cursor.skipSpace()
        try cursor.expect("]")
        if isArray { try cursor.expect("]") }
        try cursor.finishLine()
        let line = cursor.line
        guard let last = path.last else { throw TOMLError(line: line, message: "empty table name") }
        try descend(&root, path.dropLast()[...], line: line) { (table: inout Table) throws(TOMLError) in
            switch (table[last], isArray) {
            case (nil, false): table[last] = .table([:])
            case (.table, false): break
            case (nil, true): table[last] = .array([.table([:])])
            case (.array(var items), true) where items.allSatisfy({ if case .table = $0 { true } else { false } }):
                items.append(.table([:]))
                table[last] = .array(items)
            default:
                throw TOMLError(line: line, message: "“\(path.joined(separator: "."))” is already defined as a value")
            }
        }
        return path
    }

    private static func set(_ value: TOMLValue, at path: [String], in root: inout Table, line: Int) throws(TOMLError) {
        guard let last = path.last else { return }
        try descend(&root, path.dropLast()[...], line: line) { (table: inout Table) throws(TOMLError) in
            guard table[last] == nil else {
                throw TOMLError(line: line, message: "“\(path.joined(separator: "."))” is set twice")
            }
            table[last] = value
        }
    }

    /// Runs `body` on the table at `path`, creating missing tables and
    /// entering the latest element of an array of tables.
    private static func descend(_ table: inout Table, _ path: ArraySlice<String>, line: Int,
                                _ body: (inout Table) throws(TOMLError) -> Void) throws(TOMLError) {
        guard let key = path.first else { return try body(&table) }
        let rest = path.dropFirst()
        switch table[key] {
        case nil:
            var child: Table = [:]
            try descend(&child, rest, line: line, body)
            table[key] = .table(child)
        case .table(var child):
            try descend(&child, rest, line: line, body)
            table[key] = .table(child)
        case .array(var items):
            guard case .table(var child)? = items.last else {
                throw TOMLError(line: line, message: "“\(key)” is an array of values, not tables")
            }
            try descend(&child, rest, line: line, body)
            items[items.count - 1] = .table(child)
            table[key] = .array(items)
        default:
            throw TOMLError(line: line, message: "“\(key)” is a value, not a table")
        }
    }
}

private struct Cursor {
    let chars: [Character]
    let line: Int
    var index = 0

    init(_ chars: [Character], line: Int) {
        self.chars = chars
        self.line = line
    }

    var peek: Character? { index < chars.count ? chars[index] : nil }
    var atLineEnd: Bool { peek == nil || peek == "#" }

    mutating func advance() { index += 1 }

    mutating func skipSpace() {
        while peek == " " || peek == "\t" { advance() }
    }

    func fail(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

    mutating func expect(_ c: Character) throws(TOMLError) {
        guard peek == c else { throw fail("expected “\(c)”, found \(peek.map { "“\($0)”" } ?? "end of line")") }
        advance()
    }

    mutating func finishLine() throws(TOMLError) {
        skipSpace()
        guard atLineEnd else { throw fail("unexpected “\(String(chars[index...]))” after the value") }
    }

    /// A dotted key: `a`, `a.b`, `"quoted key".c`.
    mutating func key() throws(TOMLError) -> [String] {
        var parts: [String] = []
        while true {
            skipSpace()
            switch peek {
            case "\"": advance(); parts.append(try basicString())
            case "'": advance(); parts.append(try literalString())
            default:
                let start = index
                while let c = peek, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" { advance() }
                guard index > start else { throw fail("expected a key name, found \(peek.map { "“\($0)”" } ?? "end of line")") }
                parts.append(String(chars[start ..< index]))
            }
            skipSpace()
            guard peek == "." else { return parts }
            advance()
        }
    }

    mutating func value() throws(TOMLError) -> TOMLValue {
        switch peek {
        case "\"":
            if chars[index...].starts(with: "\"\"\"") { throw fail("multi-line strings aren't supported; use a single-line string") }
            advance()
            return .string(try basicString())
        case "'":
            if chars[index...].starts(with: "'''") { throw fail("multi-line strings aren't supported; use a single-line string") }
            advance()
            return .string(try literalString())
        case "[":
            advance()
            var items: [TOMLValue] = []
            while true {
                skipSpace()
                if peek == "]" { advance(); return .array(items) }
                items.append(try value())
                skipSpace()
                if peek == "," { advance() } else if peek != "]" { throw fail("expected “,” or “]” in the array (arrays must fit on one line)") }
            }
        case "{":
            advance()
            var table: TOML.Table = [:]
            skipSpace()
            if peek == "}" { advance(); return .table(table) }
            while true {
                let path = try key()
                try expect("=")
                skipSpace()
                let v = try value()
                guard let last = path.last, path.count == 1, table[last] == nil else { throw fail("inline tables take unique, undotted keys") }
                table[last] = v
                skipSpace()
                if peek == "}" { advance(); return .table(table) }
                try expect(",")
            }
        default:
            return try scalar()
        }
    }

    private mutating func scalar() throws(TOMLError) -> TOMLValue {
        let start = index
        while let c = peek, !" \t,]}#".contains(c) { advance() }
        let word = String(chars[start ..< index])
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "": throw fail("expected a value")
        default: break
        }
        let digits = word.replacingOccurrences(of: "_", with: "")
        if let int = Int(digits) { return .integer(int) }
        if digits.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let float = Double(digits) { return .float(float) }
        throw fail("“\(word)” isn't a valid value; quote strings, e.g. \"\(word)\"")
    }

    /// After the opening quote; handles TOML's escapes plus `\e`.
    private mutating func basicString() throws(TOMLError) -> String {
        var out = ""
        while let c = peek {
            advance()
            switch c {
            case "\"": return out
            case "\\":
                guard let e = peek else { break }
                advance()
                switch e {
                case "b": out.append("\u{08}")
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "f": out.append("\u{0C}")
                case "r": out.append("\r")
                case "e": out.append("\u{1B}")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u", "U":
                    let count = e == "u" ? 4 : 8
                    guard index + count <= chars.count,
                          let code = UInt32(String(chars[index ..< index + count]), radix: 16),
                          let scalar = Unicode.Scalar(code) else { throw fail("invalid \\\(e) escape") }
                    index += count
                    out.unicodeScalars.append(scalar)
                default:
                    throw fail("unknown escape “\\\(e)” in a double-quoted string; use single quotes for raw text, e.g. 'text:\\x1ba'")
                }
            default: out.append(c)
            }
        }
        throw fail("unterminated string")
    }

    private mutating func literalString() throws(TOMLError) -> String {
        let start = index
        while let c = peek {
            advance()
            if c == "'" { return String(chars[start ..< index - 1]) }
        }
        throw fail("unterminated string")
    }
}
